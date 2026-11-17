//go:build unix

package gitx

import (
	"os/exec"
	"syscall"
)

// setProcGroup runs git in its own process group and kills the whole group on
// cancellation, so hooks and ssh started by git don't outlive it.
func setProcGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
	}
}

// lowerPriority makes a long, heavy git (a clone unpacking a big pack on
// every core) yield to the app: nice 10 for its group, inherited by the
// index-pack and checkout it starts.
func lowerPriority(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Setpriority(syscall.PRIO_PGRP, cmd.Process.Pid, 10)
	}
}
