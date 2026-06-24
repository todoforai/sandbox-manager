package main

import (
	"log"
	"syscall"
)

// minFileLimit is the floor below which we refuse to run: each running microVM
// holds several fds, so the default soft limit of 1024 lets the host exhaust
// descriptors — new VMs fail with "too many open files" and live Firecracker
// procs die, which the reconcile loop then cascade-deletes as dead devices
// (live-debugged on prod). Better to fail startup loudly than to boot into that.
const minFileLimit = 65536

// raiseFileLimit lifts the open-file soft limit to the hard limit and aborts if
// the result is still unsafe. Self-raising here makes the limit independent of
// how we're launched (PM2/sudo/systemd) — a process may raise its soft limit up
// to the inherited hard limit without privilege.
func raiseFileLimit() {
	var lim syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &lim); err != nil {
		log.Fatalf("rlimit: get RLIMIT_NOFILE failed: %v", err)
	}
	if lim.Cur < lim.Max {
		want := lim
		want.Cur = want.Max
		if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &want); err != nil {
			log.Printf("rlimit: raise RLIMIT_NOFILE %d->%d failed: %v", lim.Cur, want.Cur, err)
		} else {
			log.Printf("rlimit: raised RLIMIT_NOFILE soft %d -> %d", lim.Cur, want.Cur)
			lim = want
		}
	}
	if lim.Cur < minFileLimit {
		log.Fatalf("rlimit: open-file soft limit %d below safe minimum %d (raise the launcher's hard limit, e.g. systemd LimitNOFILE)", lim.Cur, minFileLimit)
	}
}
