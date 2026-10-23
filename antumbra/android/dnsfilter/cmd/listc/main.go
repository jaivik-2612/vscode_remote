// Command listc compiles antumbra-dnsfilter's block list, and the
// firewall's list of DNS-over-HTTPS server addresses, from the sources
// named in a sources file (lists/sources.conf). It runs in CI after
// fetch-lists.sh has downloaded the remote sources; it never downloads
// anything itself.
//
//	listc -config lists/sources.conf -downloads DIR -version V \
//	      -o OUT/dnsfilter.list [-doh-out OUT/doh-ipv4.txt]
//	listc -check FILE
//
// The output depends only on the inputs and -version: the same inputs
// give the same bytes.
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"antumbra/dnsfilter/internal/blocklist"
	"antumbra/dnsfilter/internal/listc"
)

func main() {
	config := flag.String("config", "", "sources file")
	downloads := flag.String("downloads", "", "directory holding the downloaded sources, one file per source name")
	version := flag.String("version", "", "version string written into the outputs (for example 20261011)")
	out := flag.String("o", "", "block list to write")
	dohOut := flag.String("doh-out", "", "DoH server address list to write (from the ipv4 sources)")
	check := flag.String("check", "", "verify a compiled block list and print its summary")
	flag.Parse()
	if flag.NArg() > 0 {
		fail("unexpected argument %q", flag.Arg(0))
	}
	if *check != "" {
		l, err := blocklist.Load(*check)
		if err != nil {
			fail("%v", err)
		}
		fmt.Printf("ok %s version=%s entries=%d exceptions=%d sha256=%s\n",
			*check, l.Version(), l.Size(), l.Exceptions(), l.SHA256())
		return
	}
	if *config == "" || *version == "" || *out == "" {
		fail("-config, -version and -o are required (or -check FILE)")
	}
	f, err := os.Open(*config)
	if err != nil {
		fail("%v", err)
	}
	cfg, err := listc.ParseConfig(f, filepath.Dir(*config))
	f.Close()
	if err != nil {
		fail("%s: %v", *config, err)
	}
	for _, s := range append(append([]listc.Source(nil), cfg.Block...), cfg.IPv4...) {
		if s.Remote() && *downloads == "" {
			fail("source %s is remote: -downloads is required", s.Name)
		}
	}

	data, rep, err := listc.Compile(cfg, *downloads, *version)
	if err != nil {
		fail("%v", err)
	}
	if err := writeFile(*out, data); err != nil {
		fail("%v", err)
	}
	fmt.Fprintf(os.Stderr, "%s:\n%s", *out, rep)

	if *dohOut != "" {
		data, rep, err := listc.CompileIPv4(cfg, *downloads, *version)
		if err != nil {
			fail("%v", err)
		}
		if err := writeFile(*dohOut, data); err != nil {
			fail("%v", err)
		}
		fmt.Fprintf(os.Stderr, "%s:\n%s", *dohOut, rep)
	}
}

// writeFile writes through a temporary file and a rename, so a reader
// never sees half a list.
func writeFile(path string, data []byte) error {
	tmp, err := os.CreateTemp(filepath.Dir(path), ".listc-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "listc: "+format+"\n", args...)
	os.Exit(1)
}
