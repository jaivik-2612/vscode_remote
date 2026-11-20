//go:build !linux

package main

import "os"

// privileged: on systems other than Linux (development builds only) just
// refuse root.
func privileged() (string, bool) {
	if os.Getuid() == 0 || os.Geteuid() == 0 {
		return "running as root", true
	}
	return "", false
}

func setNoNewPrivs() {}
