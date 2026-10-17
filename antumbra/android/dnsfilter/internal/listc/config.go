// Package listc compiles the block list of antumbra-dnsfilter from
// third-party sources and Antumbra's own lists, as described by a sources
// file (lists/sources.conf).
package listc

import (
	"bufio"
	"fmt"
	"io"
	"path/filepath"
	"strconv"
	"strings"

	"antumbra/dnsfilter/internal/blocklist"
)

// Config is a parsed sources file.
//
// One record per line; fields are separated by spaces or tabs; blank lines
// and lines starting with '#' are ignored.
//
//	block   NAME FORMAT MIN WHERE   a source of blocked domains
//	ipv4    NAME MIN WHERE          a source of IPv4 addresses (DoH servers)
//	exclude NAME FILE               entries of source NAME to leave out
//	allow   FILE                    domains never blocked (with their subdomains)
//	guard   DOMAIN...               domains that must not end up blocked
//	licence NAME TEXT...            licence note for source NAME
//
// WHERE is an https:// URL, which fetch-lists.sh downloads to
// DOWNLOADS/NAME, or a file name relative to the sources file. FORMAT is
// "domains" (one domain per line; hosts-file lines, "*.domain" and
// "||domain^" are accepted too) or "etip" (the Exodus Privacy tracker
// list in JSON). MIN is the least number of usable entries the source
// must give; fewer means a broken download and stops the build.
type Config struct {
	Dir     string // directory of the sources file
	Block   []Source
	IPv4    []Source
	Exclude map[string][]string // source name -> files
	Allow   []string            // files
	Guard   []string            // canonical domains
	Licence map[string]string   // source name -> note
}

// Source is one "block" or "ipv4" record.
type Source struct {
	Name   string
	Format string // "domains", "etip" or "ipv4"
	Min    int
	Where  string // URL or file name
}

// Remote reports whether the source is downloaded.
func (s Source) Remote() bool { return strings.HasPrefix(s.Where, "https://") }

// Path returns the file that holds the source's data: the download for a
// remote source, else the file next to the sources file.
func (c *Config) Path(s Source, downloads string) string {
	if s.Remote() {
		return filepath.Join(downloads, s.Name)
	}
	return c.file(s.Where)
}

func (c *Config) file(name string) string {
	if filepath.IsAbs(name) {
		return name
	}
	return filepath.Join(c.Dir, name)
}

// ParseConfig reads a sources file. Dir is the directory relative file
// names are resolved against.
func ParseConfig(r io.Reader, dir string) (*Config, error) {
	c := &Config{Dir: dir, Exclude: map[string][]string{}, Licence: map[string]string{}}
	names := map[string]bool{}
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || line[0] == '#' {
			continue
		}
		f := strings.Fields(line)
		bad := func(why string) error { return fmt.Errorf("sources line %d: %s", n, why) }
		switch f[0] {
		case "block", "ipv4":
			want := 5
			if f[0] == "ipv4" {
				want = 4
			}
			if len(f) != want {
				return nil, bad(fmt.Sprintf("%q takes %d fields", f[0], want-1))
			}
			s := Source{Name: f[1], Format: "ipv4", Where: f[len(f)-1]}
			minField := f[2]
			if f[0] == "block" {
				s.Format, minField = f[2], f[3]
				if s.Format != "domains" && s.Format != "etip" {
					return nil, bad("format must be domains or etip")
				}
			}
			m, err := strconv.Atoi(minField)
			if err != nil || m < 0 {
				return nil, bad("MIN must be a number")
			}
			s.Min = m
			if !validName(s.Name) {
				return nil, bad("NAME may use only a-z, 0-9, '-' and '.'")
			}
			if names[s.Name] {
				return nil, bad("source name used twice")
			}
			names[s.Name] = true
			if strings.Contains(s.Where, "://") && !s.Remote() {
				return nil, bad("only https:// URLs are allowed")
			}
			if f[0] == "block" {
				c.Block = append(c.Block, s)
			} else {
				c.IPv4 = append(c.IPv4, s)
			}
		case "exclude":
			if len(f) != 3 {
				return nil, bad(`"exclude" takes NAME FILE`)
			}
			c.Exclude[f[1]] = append(c.Exclude[f[1]], c.file(f[2]))
		case "allow":
			if len(f) != 2 {
				return nil, bad(`"allow" takes FILE`)
			}
			c.Allow = append(c.Allow, c.file(f[1]))
		case "guard":
			for _, d := range f[1:] {
				d = blocklist.Canonical(d)
				if !blocklist.ValidDomain(d) {
					return nil, bad("guard entry is not a valid domain")
				}
				c.Guard = append(c.Guard, d)
			}
		case "licence":
			if len(f) < 3 {
				return nil, bad(`"licence" takes NAME TEXT`)
			}
			c.Licence[f[1]] = strings.Join(f[2:], " ")
		default:
			return nil, bad(fmt.Sprintf("unknown record %q", f[0]))
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}
	for name := range c.Exclude {
		if !names[name] {
			return nil, fmt.Errorf("exclude names unknown source %q", name)
		}
	}
	for name := range c.Licence {
		if !names[name] {
			return nil, fmt.Errorf("licence names unknown source %q", name)
		}
	}
	return c, nil
}

func validName(s string) bool {
	if s == "" || len(s) > 64 || s[0] == '.' || s[0] == '-' {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !('a' <= c && c <= 'z' || '0' <= c && c <= '9' || c == '-' || c == '.') {
			return false
		}
	}
	return true
}
