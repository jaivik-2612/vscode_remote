// Package status serves antumbra-dnsfilter's read-only status page:
// GET http://127.0.0.1:5380/status returns one JSON object.
package status

import (
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"golang.org/x/net/netutil"
)

// MaxModuleStatus is the largest module status file that is passed on.
const MaxModuleStatus = 64 << 10

// Snapshot is the filter's part of the status document. Its JSON field
// names are the interface the Welcome app and the tests rely on.
type Snapshot struct {
	Service       string `json:"service"` // always "antumbra-dnsfilter"
	Version       string `json:"version"` // the program's version
	UptimeSeconds int64  `json:"uptime_seconds"`

	Queries        uint64 `json:"queries"`
	Blocked        uint64 `json:"blocked"`
	Forwarded      uint64 `json:"forwarded"`
	Local          uint64 `json:"local"`
	ServFail       uint64 `json:"servfail"`
	Refused        uint64 `json:"refused"`
	FormErr        uint64 `json:"formerr"`
	NotImp         uint64 `json:"notimp"`
	RateLimited    uint64 `json:"rate_limited"`
	Dropped        uint64 `json:"dropped"`
	UpstreamErrors uint64 `json:"upstream_errors"`

	List     ListInfo     `json:"list"`
	Upstream UpstreamInfo `json:"upstream"`
	Policy   PolicyInfo   `json:"policy"`
}

// ListInfo describes the block list in use.
type ListInfo struct {
	Loaded     bool   `json:"loaded"`
	Version    string `json:"version"`
	Size       int    `json:"size"`       // blocked domains
	Exceptions int    `json:"exceptions"` // allowlist entries
	SHA256     string `json:"sha256"`
	LoadedAt   string `json:"loaded_at,omitempty"` // RFC 3339, UTC
	// ReloadError is the last failed reload's reason, if the latest reload
	// failed (the previous list then stays in use).
	ReloadError string `json:"reload_error,omitempty"`
}

// UpstreamInfo describes tor's DNSPort as the filter last saw it.
type UpstreamInfo struct {
	Address  string `json:"address"`
	Network  string `json:"network"`
	OwnerUID int    `json:"owner_uid"` // -1: not checked
	// State is "unknown" before the first forwarded query, then "ok" or
	// "error"; LastError is a short code: refused, timeout, owner,
	// owner-unknown, malformed, io or overload.
	State     string `json:"state"`
	LastError string `json:"last_error,omitempty"`
	LastSeen  string `json:"last_seen,omitempty"` // RFC 3339, UTC
}

// PolicyInfo shows the answering policy.
type PolicyInfo struct {
	BlockedAnswer string `json:"blocked_answer"` // "nxdomain" or "zero"
	FilterAAAA    bool   `json:"filter_aaaa"`
	LocalNames    bool   `json:"local_names"`
}

// document is the whole reply: the snapshot's fields, then the module's
// status file as it is, under "module".
type document struct {
	Snapshot
	Module      json.RawMessage `json:"module"`
	ModuleError string          `json:"module_error,omitempty"`
}

// Handler returns the HTTP handler. snapshot is called once per request;
// modulePath is the module's status.json (written by service.sh).
func Handler(snapshot func() Snapshot, modulePath string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		if !localHost(r.Host) {
			// A web page that made its own name resolve to 127.0.0.1 (DNS
			// rebinding) would send its own name here; only the phone's
			// own names are answered.
			http.Error(w, "misdirected request", http.StatusMisdirectedRequest)
			return
		}
		if r.URL.Path != "/status" {
			http.NotFound(w, r)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			h.Set("Allow", "GET, HEAD")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		doc := document{Snapshot: snapshot(), Module: json.RawMessage("null")}
		doc.Module, doc.ModuleError = readModule(modulePath)
		body, err := json.Marshal(doc)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		body = append(body, '\n')
		h.Set("Content-Type", "application/json; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		if r.Method == http.MethodGet {
			w.Write(body)
		}
	})
}

func readModule(path string) (json.RawMessage, string) {
	null := json.RawMessage("null")
	if path == "" {
		return null, ""
	}
	f, err := os.Open(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return null, ""
		}
		return null, "unreadable"
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, MaxModuleStatus+1))
	switch {
	case err != nil:
		return null, "unreadable"
	case len(data) > MaxModuleStatus:
		return null, "too large"
	case !json.Valid(data):
		return null, "invalid JSON"
	}
	return json.RawMessage(strings.TrimSpace(string(data))), ""
}

func localHost(host string) bool {
	if h, _, err := net.SplitHostPort(host); err == nil {
		host = h
	}
	host = strings.Trim(host, "[]")
	switch strings.ToLower(host) {
	case "127.0.0.1", "localhost", "::1":
		return true
	}
	return false
}

// Serve listens on addr (which must be a loopback address) and serves the
// handler until the listener is closed. It returns the server so that the
// caller can close it.
func Serve(addr string, handler http.Handler, logf func(string, ...any)) (*http.Server, net.Addr, error) {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, nil, err
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return nil, nil, errors.New("status address must be a loopback address")
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, nil, err
	}
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       5 * time.Second,
		WriteTimeout:      5 * time.Second,
		IdleTimeout:       30 * time.Second,
		MaxHeaderBytes:    4096,
	}
	go func() {
		// At most 16 connections at a time; the page is tiny.
		if err := srv.Serve(netutil.LimitListener(ln, 16)); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logf("status server: %v", err)
		}
	}()
	return srv, ln.Addr(), nil
}
