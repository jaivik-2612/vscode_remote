//go:build linux

package main

import (
	"strings"
	"testing"
)

func TestPrivilegedStatus(t *testing.T) {
	// What the module's launcher gives the filter: uid/gid 2951, group
	// inet (3003), no capabilities.
	good := map[string]string{
		"Uid":    "2951\t2951\t2951\t2951",
		"Gid":    "2951\t2951\t2951\t2951",
		"Groups": "3003 ",
		"CapInh": "0000000000000000",
		"CapPrm": "0000000000000000",
		"CapEff": "0000000000000000",
		"CapBnd": "000001ffffffffff",
		"CapAmb": "0000000000000000",
	}
	order := []string{"Name", "Umask", "State", "Tgid", "Pid", "Uid", "Gid", "FDSize", "Groups", "VmPeak",
		"CapInh", "CapPrm", "CapEff", "CapBnd", "CapAmb", "NoNewPrivs", "Seccomp"}
	status := func(change map[string]string) string {
		var b strings.Builder
		for _, k := range order {
			v, ok := change[k]
			if !ok {
				v, ok = good[k]
			}
			if !ok {
				v = "x"
			}
			if v == "-" { // drop the line
				continue
			}
			b.WriteString(k + ":\t" + v + "\n")
		}
		return b.String()
	}
	if why, bad := privilegedStatus(strings.NewReader(status(nil))); bad {
		t.Errorf("the module's credentials refused: %s", why)
	}
	if why, bad := privilegedStatus(strings.NewReader(status(map[string]string{"Groups": ""}))); bad {
		t.Errorf("no supplementary groups refused: %s", why)
	}
	for name, change := range map[string]map[string]string{
		"gid 0":           {"Gid": "0\t0\t0\t0"},
		"egid 0":          {"Gid": "2951\t0\t2951\t0"},
		"saved uid 0":     {"Uid": "2951\t2951\t0\t2951"},
		"fs gid 0":        {"Gid": "2951\t2951\t2951\t0"},
		"group root":      {"Groups": "0 3003"},
		"group net_raw":   {"Groups": "3003 3004"},
		"group net_admin": {"Groups": "3005"},
		"CapEff":          {"CapEff": "0000000000001000"},
		"CapPrm":          {"CapPrm": "0000000000001000"},
		"CapAmb":          {"CapAmb": "0000000000000400"},
		"no Uid line":     {"Uid": "-"},
		"no Groups line":  {"Groups": "-"},
		"no CapEff line":  {"CapEff": "-"},
		"garbled Gid":     {"Gid": "2951 x 2951 2951"},
		"short Uid":       {"Uid": "2951"},
		"garbled Groups":  {"Groups": "3003 net"},
		"garbled CapPrm":  {"CapPrm": "zz"},
	} {
		if _, bad := privilegedStatus(strings.NewReader(status(change))); !bad {
			t.Errorf("%s: not refused", name)
		}
	}
}
