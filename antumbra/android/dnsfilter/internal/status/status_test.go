package status

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func snap() Snapshot {
	return Snapshot{Service: "antumbra-dnsfilter", Version: "test", Queries: 10, Blocked: 3, ServFail: 1,
		List:     ListInfo{Loaded: true, Version: "20261011", Size: 195887, SHA256: "ab"},
		Upstream: UpstreamInfo{Address: "127.0.0.1:9053", Network: "udp", OwnerUID: 2950, State: "ok"},
		Policy:   PolicyInfo{BlockedAnswer: "nxdomain", FilterAAAA: true, LocalNames: true}}
}

func get(t *testing.T, h http.Handler, method, host, path string) (*http.Response, map[string]any) {
	t.Helper()
	req := httptest.NewRequest(method, "http://"+host+path, nil)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	res := w.Result()
	body, _ := io.ReadAll(res.Body)
	var doc map[string]any
	if res.StatusCode == http.StatusOK && method == http.MethodGet {
		if err := json.Unmarshal(body, &doc); err != nil {
			t.Fatalf("body is not JSON: %v\n%s", err, body)
		}
	}
	return res, doc
}

func TestStatusDocument(t *testing.T) {
	dir := t.TempDir()
	mod := filepath.Join(dir, "status.json")
	if err := os.WriteFile(mod, []byte(`{"fw":{"armed":"1a2b"},"tor":"bootstrapping"}`+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := Handler(snap, mod)
	res, doc := get(t, h, http.MethodGet, "127.0.0.1:5380", "/status")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status %d", res.StatusCode)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Errorf("content type %q", ct)
	}
	if res.Header.Get("Cache-Control") != "no-store" || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Errorf("headers %v", res.Header)
	}
	for k, want := range map[string]any{"service": "antumbra-dnsfilter", "queries": 10.0, "blocked": 3.0, "servfail": 1.0} {
		if doc[k] != want {
			t.Errorf("%s = %v, want %v", k, doc[k], want)
		}
	}
	list := doc["list"].(map[string]any)
	if list["version"] != "20261011" || list["size"] != 195887.0 {
		t.Errorf("list %v", list)
	}
	module := doc["module"].(map[string]any)
	if module["tor"] != "bootstrapping" {
		t.Errorf("module %v", module)
	}
	if _, ok := doc["module_error"]; ok {
		t.Error("module_error set for a good file")
	}
}

func TestStatusModuleFile(t *testing.T) {
	dir := t.TempDir()
	cases := map[string]struct {
		content *string
		errText string
	}{
		"missing":   {nil, ""},
		"invalid":   {ptr(`{"half":`), "invalid JSON"},
		"too large": {ptr(`"` + strings.Repeat("x", MaxModuleStatus) + `"`), "too large"},
	}
	for name, c := range cases {
		p := filepath.Join(dir, name+".json")
		if c.content != nil {
			os.WriteFile(p, []byte(*c.content), 0o644)
		}
		_, doc := get(t, Handler(snap, p), http.MethodGet, "localhost", "/status")
		if doc["module"] != nil {
			t.Errorf("%s: module = %v, want null", name, doc["module"])
		}
		got, _ := doc["module_error"].(string)
		if got != c.errText {
			t.Errorf("%s: module_error = %q, want %q", name, got, c.errText)
		}
	}
	// A directory where the file should be cannot be read as JSON.
	_, doc := get(t, Handler(snap, dir), http.MethodGet, "localhost", "/status")
	if doc["module_error"] == nil {
		t.Error("no module_error for a directory")
	}
	// No path: no module part.
	_, doc = get(t, Handler(snap, ""), http.MethodGet, "localhost", "/status")
	if doc["module"] != nil || doc["module_error"] != nil {
		t.Errorf("no path: %v %v", doc["module"], doc["module_error"])
	}
}

func ptr(s string) *string { return &s }

func TestStatusRefusals(t *testing.T) {
	h := Handler(snap, "")
	cases := []struct {
		method, host, path string
		code               int
	}{
		{http.MethodGet, "evil.example:5380", "/status", http.StatusMisdirectedRequest}, // DNS rebinding
		{http.MethodGet, "127.0.0.2:5380", "/status", http.StatusMisdirectedRequest},
		{http.MethodGet, "127.0.0.1:5380", "/", http.StatusNotFound},
		{http.MethodGet, "127.0.0.1:5380", "/status/", http.StatusNotFound},
		{http.MethodPost, "127.0.0.1:5380", "/status", http.StatusMethodNotAllowed},
		{http.MethodPut, "127.0.0.1:5380", "/status", http.StatusMethodNotAllowed},
		{http.MethodHead, "127.0.0.1:5380", "/status", http.StatusOK},
		{http.MethodGet, "[::1]:5380", "/status", http.StatusOK},
		{http.MethodGet, "LOCALHOST:5380", "/status", http.StatusOK},
	}
	for _, c := range cases {
		res, _ := get(t, h, c.method, c.host, c.path)
		if res.StatusCode != c.code {
			t.Errorf("%s %s%s: %d, want %d", c.method, c.host, c.path, res.StatusCode, c.code)
		}
	}
}

func TestServeLoopbackOnly(t *testing.T) {
	if _, _, err := Serve("0.0.0.0:0", Handler(snap, ""), t.Logf); err == nil {
		t.Error("served on 0.0.0.0")
	}
	if _, _, err := Serve("localhost:0", Handler(snap, ""), t.Logf); err == nil {
		t.Error("served on a host name (must be an address)")
	}
	srv, addr, err := Serve("127.0.0.1:0", Handler(snap, ""), t.Logf)
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	res, err := http.Get("http://" + addr.String() + "/status")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Errorf("status %d", res.StatusCode)
	}
}
