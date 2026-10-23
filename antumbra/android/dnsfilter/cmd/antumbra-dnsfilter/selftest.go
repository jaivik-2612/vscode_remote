package main

import (
	"bytes"
	"fmt"
	"net/netip"
	"os"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/dnsfilter"
	"antumbra/dnsfilter/internal/fakedns"
)

// selfTest checks the whole filter on loopback, with a fake tor DNSPort,
// without root and without touching the real ports. It is meant for a
// first run on new hardware (for example in Termux on the phone, or under
// qemu-user for the arm64 build). With -list, it also loads those lists
// and times lookups in them.
func selfTest(lists []string, listsGiven bool) int {
	failed := 0
	check := func(what string, err error) {
		if err != nil {
			failed++
			fmt.Printf("FAIL %s: %v\n", what, err)
			return
		}
		fmt.Printf("ok   %s\n", what)
	}

	var buf bytes.Buffer
	err := blocklist.Write(&buf, blocklist.Header{Version: "self-test"},
		[]string{"blocked.example", "tracker.example.org"}, []string{"ok.blocked.example"})
	check("write a block list", err)
	list, err := blocklist.Parse(buf.Bytes())
	check("load it back", err)
	if err != nil {
		return 1
	}

	fake, err := fakedns.Start(true)
	check("start a fake tor DNSPort", err)
	if err != nil {
		return 1
	}
	defer fake.Close()

	owner := os.Getuid()
	if _, err := os.ReadFile("/proc/net/udp"); err != nil {
		// Android does not let apps (Termux) read /proc/net.
		fmt.Println("note /proc/net/udp is not readable here; the upstream owner check is skipped")
		owner = -1
	}
	up, err := dnsfilter.NewLoopback(fake.Addr(), "udp", 2*time.Second, owner)
	check("upstream on loopback only", err)
	if err != nil {
		return 1
	}
	_, err = dnsfilter.NewLoopback(netip.MustParseAddrPort("192.0.2.1:53"), "udp", time.Second, -1)
	check("an upstream off the phone is refused", expectErr(err))

	stats := &dnsfilter.Stats{}
	h := dnsfilter.NewHandler(dnsfilter.Config{
		List: func() *blocklist.List { return list }, Upstream: up,
		BlockedTTL: 60, FilterAAAA: true, LocalNames: true, MaxInflight: 16, Stats: stats,
	})
	srv, err := dnsfilter.Listen(netip.MustParseAddrPort("127.0.0.1:0"),
		dnsfilter.ServerConfig{Handler: h, Stats: stats, Limiter: dnsfilter.NewLimiter(1000, 1000, 64)})
	check("listen on 127.0.0.1 (udp, tcp)", err)
	if err != nil {
		return 1
	}
	srv.Serve()
	defer srv.Close()
	addr := srv.Addr()

	ask := func(network, name string, t dnsmessage.Type) (*dnsmessage.Message, error) {
		return fakedns.Ask(network, addr, name, t, 5*time.Second)
	}
	expect := func(network, name string, t dnsmessage.Type, rcode dnsmessage.RCode, answers int) error {
		m, err := ask(network, name, t)
		if err != nil {
			return err
		}
		if m.RCode != rcode || len(m.Answers) != answers {
			return fmt.Errorf("got %v with %d answers, want %v with %d", m.RCode, len(m.Answers), rcode, answers)
		}
		return nil
	}

	before := fake.Queries()
	check("A for an allowed name is forwarded (udp)", expect("udp", "allowed.example", dnsmessage.TypeA, dnsmessage.RCodeSuccess, 1))
	check("A for an allowed name is forwarded (tcp)", expect("tcp", "allowed.example", dnsmessage.TypeA, dnsmessage.RCodeSuccess, 1))
	check("a blocked name gets NXDOMAIN", expect("udp", "blocked.example", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0))
	check("a subdomain of a blocked name gets NXDOMAIN", expect("udp", "a.b.Tracker.Example.org", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0))
	check("an allowlisted subdomain is forwarded", expect("udp", "ok.blocked.example", dnsmessage.TypeA, dnsmessage.RCodeSuccess, 1))
	check("AAAA gets an empty answer", expect("udp", "allowed.example", dnsmessage.TypeAAAA, dnsmessage.RCodeSuccess, 0))
	check("ANY is refused", expect("udp", "allowed.example", dnsmessage.TypeALL, dnsmessage.RCodeRefused, 0))
	check("AXFR is refused", expect("tcp", "allowed.example", dnsmessage.TypeAXFR, dnsmessage.RCodeRefused, 0))
	check("a .local name stays on the phone", expect("udp", "printer.local", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0))
	// tor reads names as C strings: "x.blocked.example\x00" would reach it
	// as x.blocked.example. Names with such bytes are never forwarded.
	check("a name with a NUL byte gets NXDOMAIN", expect("udp", "x.blocked.example\x00", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0))
	check("a name with a control byte gets NXDOMAIN", expect("tcp", "allowed.exa\x01mple", dnsmessage.TypeA, dnsmessage.RCodeNameError, 0))
	if got := stats.BadName.Load(); got != 2 {
		check("bad names are counted", fmt.Errorf("bad_name=%d, want 2", got))
	}
	if got := fake.Queries() - before; got != 3 {
		check("only allowed names reach tor", fmt.Errorf("fake tor saw %d queries, want 3", got))
	} else {
		check("only allowed names reach tor", nil)
	}

	fake.Close()
	check("tor down: SERVFAIL (fail closed)", expect("udp", "other.example", dnsmessage.TypeA, dnsmessage.RCodeServerFailure, 0))

	if listsGiven {
		for _, p := range lists {
			start := time.Now()
			l, err := blocklist.Load(p)
			check("load "+p, err)
			if err != nil {
				continue
			}
			loaded := time.Since(start)
			const n = 100000
			names := []string{"a.b.c.allowed-name.example.com", "x.doubleclick.net", "www.wikipedia.org"}
			start = time.Now()
			for i := 0; i < n; i++ {
				l.Match(names[i%len(names)])
			}
			per := time.Since(start) / n
			fmt.Printf("     version=%s entries=%d exceptions=%d load=%s lookup=%s\n",
				l.Version(), l.Size(), l.Exceptions(), loaded.Round(time.Millisecond), per)
		}
	}
	if failed > 0 {
		fmt.Printf("self-test: %d check(s) FAILED\n", failed)
		return 1
	}
	fmt.Println("self-test: PASS")
	return 0
}

func expectErr(err error) error {
	if err == nil {
		return fmt.Errorf("no error")
	}
	return nil
}
