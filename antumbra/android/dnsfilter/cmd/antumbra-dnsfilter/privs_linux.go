//go:build linux

package main

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// privileged reports why the process is more privileged than the filter
// needs: root, or any permitted, effective or ambient capability. The
// filter binds only ports above 1024 and needs no capability at all; with
// CAP_NET_ADMIN a bug in it could change the firewall.
func privileged() (string, bool) {
	if os.Getuid() == 0 || os.Geteuid() == 0 {
		return "running as root", true
	}
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return "cannot read /proc/self/status to check capabilities", true
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), ":")
		if !ok || (k != "CapPrm" && k != "CapEff" && k != "CapAmb") {
			continue
		}
		n, err := strconv.ParseUint(strings.TrimSpace(v), 16, 64)
		if err != nil {
			return "cannot parse " + k, true
		}
		if n != 0 {
			return k + " is " + strings.TrimSpace(v) + " (capabilities not dropped)", true
		}
	}
	if err := sc.Err(); err != nil {
		return "cannot read /proc/self/status to check capabilities", true
	}
	return "", false
}

// setNoNewPrivs sets PR_SET_NO_NEW_PRIVS: nothing this process could ever
// execute gains privileges through set-uid bits or file capabilities.
func setNoNewPrivs() {
	const prSetNoNewPrivs = 38
	syscall.RawSyscall6(syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0, 0, 0, 0)
}
