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
