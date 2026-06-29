//go:build !windows

package main

import "os"

func privilegeWarning() string {
	if os.Geteuid() != 0 {
		return "edge normally requires root or CAP_NET_ADMIN"
	}
	return ""
}
