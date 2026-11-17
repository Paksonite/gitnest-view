//go:build !unix

package gitx

import "os/exec"

func setProcGroup(*exec.Cmd) {}

func lowerPriority(*exec.Cmd) {}
