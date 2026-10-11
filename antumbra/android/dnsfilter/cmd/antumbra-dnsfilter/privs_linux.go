//go:build linux

package main

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
)

// privilegedGroups are groups that give a process more than the filter
// needs: root's group, and Android's AID_NET_RAW (3004, raw sockets) and
// AID_NET_ADMIN (3005, network configuration), which carry those powers on
// kernels built with CONFIG_ANDROID_PARANOID_NETWORK, as the phone's 4.14
// vendor kernel may be. The filter needs only AID_INET (3003) there, which
// the module gives it.
var privilegedGroups = map[int]string{0: "root", 3004: "net_raw", 3005: "net_admin"}

// privileged reports why the process is more privileged than the filter
// needs: root as any of its real, effective, saved or file-system uid or
// gid, a privileged supplementary group, or any permitted, effective or
// ambient capability. The filter binds only ports above 1024 and needs no
// capability at all; with CAP_NET_ADMIN a bug in it could change the
// firewall.
func privileged() (string, bool) {
	if os.Getuid() == 0 || os.Geteuid() == 0 {
		return "running as root", true
	}
	f, err := os.Open("/proc/self/status")
	if err != nil {
		return "cannot read /proc/self/status to check credentials", true
	}
	defer f.Close()
	return privilegedStatus(f)
}

// privilegedStatus checks the Uid, Gid, Groups and Cap* lines of a
// /proc/<pid>/status file. A line that is missing or cannot be parsed
// counts as privileged.
func privilegedStatus(r io.Reader) (string, bool) {
	seen := map[string]bool{}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), ":")
		if !ok {
			continue
		}
		v = strings.TrimSpace(v)
		switch k {
		case "CapPrm", "CapEff", "CapAmb":
			n, err := strconv.ParseUint(v, 16, 64)
			if err != nil {
				return "cannot parse " + k, true
			}
			if n != 0 {
				return k + " is " + v + " (capabilities not dropped)", true
			}
		case "Uid", "Gid":
			// real, effective, saved and file-system ids: a saved uid of 0
			// would let the process become root again.
			ids := strings.Fields(v)
			if len(ids) != 4 {
				return "cannot parse " + k, true
			}
			for _, s := range ids {
				id, err := strconv.Atoi(s)
				if err != nil {
					return "cannot parse " + k, true
				}
				if id == 0 {
					return k + " is " + strings.Join(ids, " ") + " (root)", true
				}
			}
		case "Groups":
			for _, s := range strings.Fields(v) {
				id, err := strconv.Atoi(s)
				if err != nil {
					return "cannot parse " + k, true
				}
				if name, bad := privilegedGroups[id]; bad {
					return fmt.Sprintf("in group %d (%s)", id, name), true
				}
			}
		default:
			continue
		}
		seen[k] = true
	}
	if err := sc.Err(); err != nil {
		return "cannot read /proc/self/status to check credentials", true
	}
	// CapAmb is missing before Linux 4.3; the phone runs 4.14.
	for _, k := range []string{"Uid", "Gid", "Groups", "CapPrm", "CapEff"} {
		if !seen[k] {
			return "no " + k + " line in /proc/self/status", true
		}
	}
	return "", false
}

// setNoNewPrivs sets PR_SET_NO_NEW_PRIVS: nothing this process could ever
// execute gains privileges through set-uid bits or file capabilities.
func setNoNewPrivs() {
	const prSetNoNewPrivs = 38
	syscall.RawSyscall6(syscall.SYS_PRCTL, prSetNoNewPrivs, 1, 0, 0, 0, 0)
}
