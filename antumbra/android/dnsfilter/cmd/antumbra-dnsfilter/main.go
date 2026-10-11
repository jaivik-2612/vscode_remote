// Command antumbra-dnsfilter is the tracker-blocking DNS filter of the
// Antumbra module. It listens on 127.0.0.1:5353 (UDP and TCP), where the
// firewall redirects every DNS query on the phone; answers blocked names
// and local names itself; and forwards everything else to tor's DNSPort
// on 127.0.0.1:9053. If tor does not answer, the query fails (SERVFAIL):
// there is no other server. A read-only status page is served on
// http://127.0.0.1:5380/status.
//
// It runs as uid/gid 2951 with every capability dropped, and refuses to
// start as root or with capabilities (see -insecure-allow-privileged).
// Query names are never logged unless -debug-log-queries is given.
//
// Signals: SIGHUP reloads the block list (the old one stays in use if the
// new one does not load); SIGINT and SIGTERM stop the filter.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/dnsfilter"
	"antumbra/dnsfilter/internal/status"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

// Defaults from the shared contract (antumbra/android/docs).
const (
	defaultListen       = "127.0.0.1:5353"
	defaultStatus       = "127.0.0.1:5380"
	defaultUpstream     = "127.0.0.1:9053"
	defaultUpstreamUID  = 2950 // tor
	defaultList         = "/data/adb/antumbra/lists/dnsfilter.list"
	defaultModuleStatus = "/data/adb/antumbra/run/status.json"
)

type listFlag struct {
	paths []string
	set   bool
}

func (l *listFlag) String() string { return strings.Join(l.paths, ",") }
func (l *listFlag) Set(s string) error {
	if !l.set {
		l.paths, l.set = nil, true
	}
	l.paths = append(l.paths, s)
	return nil
}

type options struct {
	listen, statusListen, upstream, upstreamNet string
	upstreamTimeout                             time.Duration
	upstreamUID                                 int
	lists                                       listFlag
	allowNoList                                 bool
	blockedAnswer, aaaa                         string
	blockedTTL                                  uint
	localNames                                  bool
	rate                                        float64
	burst, maxInflight, maxTCPConns             int
	moduleStatus                                string
	statusRefresh, bindWait                     time.Duration
	debugQueries, allowPrivileged               bool
	selfTest, showVersion                       bool
	checkList                                   string

	// onReady, if set, is called with the bound addresses once the filter
	// answers (tests).
	onReady func(dns netip.AddrPort, status net.Addr)
}

func parseFlags(args []string) (*options, error) {
	o := &options{lists: listFlag{paths: []string{defaultList}}}
	fs := flag.NewFlagSet("antumbra-dnsfilter", flag.ContinueOnError)
	fs.StringVar(&o.listen, "listen", defaultListen, "UDP and TCP address to answer on (IPv4 loopback only)")
	fs.StringVar(&o.statusListen, "status-listen", defaultStatus, `address of the status page (loopback only; "" turns it off)`)
	fs.StringVar(&o.upstream, "upstream", defaultUpstream, "tor's DNSPort (IPv4 loopback only)")
	fs.StringVar(&o.upstreamNet, "upstream-net", "udp", "udp or tcp: how to reach the upstream (tor's DNSPort is UDP only)")
	fs.DurationVar(&o.upstreamTimeout, "upstream-timeout", 4*time.Second, "how long to wait for tor before answering SERVFAIL")
	fs.IntVar(&o.upstreamUID, "upstream-uid", defaultUpstreamUID, "uid that must own every socket on the upstream port; -1 skips the check")
	fs.Var(&o.lists, "list", "block list file; repeat to give fallbacks, the first that loads is used (default "+defaultList+")")
	fs.BoolVar(&o.allowNoList, "allow-no-list", false, "start without a block list if none loads (development only; default is to exit)")
	fs.StringVar(&o.blockedAnswer, "blocked-answer", "nxdomain", "answer for blocked names: nxdomain, or zero (0.0.0.0 and ::)")
	fs.UintVar(&o.blockedTTL, "blocked-ttl", 60, "TTL in seconds of answers made by the filter itself")
	fs.StringVar(&o.aaaa, "aaaa", "empty", "AAAA queries: empty (no IPv6 addresses; IPv6 is off) or forward")
	fs.BoolVar(&o.localNames, "local-names", true, "answer local names (.local, .lan, home.arpa, private reverse zones) here instead of asking tor")
	fs.Float64Var(&o.rate, "rate", 20, "queries per second allowed per client port; 0 turns the limit off")
	fs.IntVar(&o.burst, "burst", 40, "burst size of the per-client-port limit")
	fs.IntVar(&o.maxInflight, "max-inflight", 128, "queries that may wait for tor at once; more get SERVFAIL")
	fs.IntVar(&o.maxTCPConns, "max-tcp-conns", 64, "open TCP connections allowed at once")
	fs.StringVar(&o.moduleStatus, "module-status", defaultModuleStatus, "module status file shown under \"module\" on the status page")
	fs.DurationVar(&o.statusRefresh, "status-refresh", time.Minute, "show the status page's counters and upstream state afresh at most this often (every app can read the page); 0 shows them live")
	fs.DurationVar(&o.bindWait, "bind-wait", 10*time.Second, "keep trying to bind the listening ports this long")
	fs.BoolVar(&o.debugQueries, "debug-log-queries", false, "log every query name and decision (opt-in debug mode; names are never logged otherwise)")
	fs.BoolVar(&o.allowPrivileged, "insecure-allow-privileged", false, "allow running as root or with capabilities (tests only)")
	fs.BoolVar(&o.selfTest, "self-test", false, "run a self-test on loopback with a fake upstream, then exit")
	fs.StringVar(&o.checkList, "check-list", "", "verify a block list file, print its summary, then exit")
	fs.BoolVar(&o.showVersion, "version", false, "print the version, then exit")
	if err := fs.Parse(args); err != nil {
		return nil, err
	}
	if fs.NArg() > 0 {
		return nil, fmt.Errorf("unexpected argument %q", fs.Arg(0))
	}
	return o, nil
}

func main() {
	log.SetFlags(log.LUTC | log.Ldate | log.Ltime)
	log.SetPrefix("antumbra-dnsfilter: ")
	o, err := parseFlags(os.Args[1:])
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			os.Exit(0)
		}
		log.Print(err)
		os.Exit(2)
	}
	switch {
	case o.showVersion:
		fmt.Println("antumbra-dnsfilter", version)
		return
	case o.checkList != "":
		os.Exit(checkList(o.checkList))
	case o.selfTest:
		os.Exit(selfTest(o.lists.paths, o.lists.set))
	}
	sig := make(chan os.Signal, 4)
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGINT, syscall.SIGTERM)
	if err := run(o, sig); err != nil {
		log.Print(err)
		os.Exit(1)
	}
}

func checkList(path string) int {
	start := time.Now()
	l, err := blocklist.Load(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL %v\n", err)
		return 1
	}
	fmt.Printf("ok %s version=%s entries=%d exceptions=%d sha256=%s load=%s\n",
		path, l.Version(), l.Size(), l.Exceptions(), l.SHA256(), time.Since(start).Round(time.Millisecond))
	return 0
}

// listState holds the list in use and what the status page says about it.
type listState struct {
	cur      atomic.Pointer[blocklist.List]
	mu       sync.Mutex
	loadedAt time.Time
	path     string
	errText  string
}

func (s *listState) get() *blocklist.List { return s.cur.Load() }

// load tries each path in order and keeps the first list that loads. On
// failure the current list stays in use.
func (s *listState) load(paths []string) error {
	var errs []string
	for _, p := range paths {
		l, err := blocklist.Load(p)
		if err != nil {
			errs = append(errs, err.Error())
			continue
		}
		s.cur.Store(l)
		s.mu.Lock()
		s.loadedAt, s.path, s.errText = time.Now(), p, ""
		s.mu.Unlock()
		// Give the file buffer and any previous list back to the system
		// now rather than at the next collection (several megabytes).
		debug.FreeOSMemory()
		return nil
	}
	err := errors.New("no block list loaded: " + strings.Join(errs, "; "))
	s.mu.Lock()
	s.errText = "no list loaded"
	s.mu.Unlock()
	return err
}

// run starts the filter and serves until SIGINT or SIGTERM arrives on sig.
// SIGHUP reloads the block list.
func run(o *options, sig <-chan os.Signal) error {
	if why, bad := privileged(); bad && !o.allowPrivileged {
		return fmt.Errorf("refusing to run: %s; start as uid 2951 with every capability dropped", why)
	}
	setNoNewPrivs()

	listenAddr, err := netip.ParseAddrPort(o.listen)
	if err != nil {
		return fmt.Errorf("-listen: %v", err)
	}
	upAddr, err := netip.ParseAddrPort(o.upstream)
	if err != nil {
		return fmt.Errorf("-upstream: %v", err)
	}
	up, err := dnsfilter.NewLoopback(upAddr, o.upstreamNet, o.upstreamTimeout, o.upstreamUID)
	if err != nil {
		return err
	}
	var mode dnsfilter.BlockMode
	switch o.blockedAnswer {
	case "nxdomain":
		mode = dnsfilter.BlockNXDOMAIN
	case "zero":
		mode = dnsfilter.BlockZero
	default:
		return fmt.Errorf("-blocked-answer must be nxdomain or zero")
	}
	if o.aaaa != "empty" && o.aaaa != "forward" {
		return fmt.Errorf("-aaaa must be empty or forward")
	}
	if o.blockedTTL > 86400 {
		return fmt.Errorf("-blocked-ttl must be at most 86400")
	}

	lists := &listState{}
	if err := lists.load(o.lists.paths); err != nil {
		if !o.allowNoList {
			// Fail closed: without its list the filter does not answer at
			// all, so DNS stops instead of running unfiltered.
			return err
		}
		log.Printf("%v; continuing without a list (-allow-no-list)", err)
	} else {
		l := lists.get()
		log.Printf("block list %s: version %s, %d entries, %d exceptions", lists.path, l.Version(), l.Size(), l.Exceptions())
	}

	stats := &dnsfilter.Stats{}
	cfg := dnsfilter.Config{
		List:        lists.get,
		Upstream:    up,
		BlockMode:   mode,
		BlockedTTL:  uint32(o.blockedTTL),
		FilterAAAA:  o.aaaa == "empty",
		LocalNames:  o.localNames,
		MaxInflight: o.maxInflight,
		Stats:       stats,
	}
	if o.debugQueries {
		log.Print("debug mode: query names will be logged")
		cfg.Debugf = log.Printf
	}
	handler := dnsfilter.NewHandler(cfg)
	scfg := dnsfilter.ServerConfig{
		Handler:     handler,
		Limiter:     dnsfilter.NewLimiter(o.rate, o.burst, 4096),
		Stats:       stats,
		MaxTCPConns: o.maxTCPConns,
		Logf:        log.Printf,
	}
	var srv *dnsfilter.Server
	deadline := time.Now().Add(o.bindWait)
	for {
		srv, err = dnsfilter.Listen(listenAddr, scfg)
		if err == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(500 * time.Millisecond)
	}
	if err != nil {
		return fmt.Errorf("listen %s: %v", listenAddr, err)
	}
	srv.Serve()
	log.Printf("answering on %s (udp, tcp); upstream %s/%s, owner uid %d", srv.Addr(), up.Network(), up.Addr(), up.OwnerUID())

	started := time.Now()
	snapshot := status.Coarsen(func() status.Snapshot {
		return makeSnapshot(started, stats, lists, up, cfg)
	}, o.statusRefresh)
	var statusAddr net.Addr
	if o.statusListen != "" {
		hs, addr, err := status.Serve(o.statusListen, status.Handler(snapshot, o.moduleStatus), log.Printf)
		if err != nil {
			srv.Close()
			return fmt.Errorf("status page %s: %v", o.statusListen, err)
		}
		defer hs.Close()
		statusAddr = addr
		log.Printf("status page on http://%s/status", addr)
	}
	if o.onReady != nil {
		o.onReady(srv.Addr(), statusAddr)
	}

	for s := range sig {
		if s == syscall.SIGHUP {
			if err := lists.load(o.lists.paths); err != nil {
				log.Printf("reload: %v; keeping the current list", err)
				continue
			}
			l := lists.get()
			log.Printf("reloaded block list %s: version %s, %d entries", lists.path, l.Version(), l.Size())
			continue
		}
		log.Printf("stopping on %v", s)
		break
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	done := make(chan struct{})
	go func() { srv.Close(); close(done) }()
	select {
	case <-done:
	case <-ctx.Done():
	}
	return nil
}

func makeSnapshot(started time.Time, st *dnsfilter.Stats, lists *listState, up *dnsfilter.Loopback, cfg dnsfilter.Config) status.Snapshot {
	s := status.Snapshot{
		Service:       "antumbra-dnsfilter",
		Version:       version,
		UptimeSeconds: int64(time.Since(started).Seconds()),
		Counters: status.Counters{
			Queries:        st.Queries.Load(),
			Blocked:        st.Blocked.Load(),
			Forwarded:      st.Forwarded.Load(),
			Local:          st.Local.Load(),
			ServFail:       st.ServFail.Load(),
			Refused:        st.Refused.Load(),
			FormErr:        st.FormErr.Load(),
			NotImp:         st.NotImp.Load(),
			BadName:        st.BadName.Load(),
			RateLimited:    st.RateLimited.Load(),
			Dropped:        st.Dropped.Load(),
			UpstreamErrors: st.UpstreamErrors.Load(),
		},
		Policy: status.PolicyInfo{
			BlockedAnswer: cfg.BlockMode.String(),
			FilterAAAA:    cfg.FilterAAAA,
			LocalNames:    cfg.LocalNames,
		},
		Upstream: status.UpstreamInfo{
			Address:  up.Addr().String(),
			Network:  up.Network(),
			OwnerUID: up.OwnerUID(),
			State:    "unknown",
		},
	}
	if l := lists.get(); l != nil {
		lists.mu.Lock()
		s.List = status.ListInfo{Loaded: true, Version: l.Version(), Size: l.Size(),
			Exceptions: l.Exceptions(), SHA256: l.SHA256(),
			LoadedAt: lists.loadedAt.UTC().Format(time.RFC3339), ReloadError: lists.errText}
		lists.mu.Unlock()
	}
	if known, ok, code, when := st.Upstream(); known {
		s.Upstream.State = "error"
		if ok {
			s.Upstream.State = "ok"
		}
		s.Upstream.LastError = code
		s.Upstream.LastSeen = when.UTC().Format(time.RFC3339)
	}
	return s
}
