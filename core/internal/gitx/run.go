package gitx

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf8"
)

// kind classifies a git invocation; it selects the timeout and whether the
// repository's write lock is taken.
type kind int

const (
	kRead  kind = iota // queries: status, log, diff, show
	kWrite             // local mutations; may run hooks
	kNet               // talks to a remote (fetch, pull, push)
)

// Time limits per kind of git command. Zero disables the limit.
var (
	ReadTimeout  = 30 * time.Second
	WriteTimeout = 10 * time.Minute // commit/rebase hooks can be slow
	NetTimeout   = 2 * time.Minute
)

func timeoutFor(k kind) time.Duration {
	switch k {
	case kWrite:
		return WriteTimeout
	case kNet:
		return NetTimeout
	}
	return ReadTimeout
}

// Error is returned when git fails. Error() is a short summary; Output holds
// everything git printed so the UI can show it in full.
type Error struct {
	Args     []string
	Output   string        // stderr, or stdout when stderr was empty
	Timeout  time.Duration // non-zero when git was killed for exceeding it
	Canceled bool          // the caller's context was canceled
	Err      error
}

func (e *Error) Error() string {
	switch {
	case e.Timeout > 0:
		return fmt.Sprintf("git %s timed out after %s", subcommand(e.Args), e.Timeout)
	case e.Canceled:
		return fmt.Sprintf("git %s canceled", subcommand(e.Args))
	case e.Output != "":
		return firstLines(e.Output, 3)
	}
	return fmt.Sprintf("git %s: %v", subcommand(e.Args), e.Err)
}

func (e *Error) Unwrap() error { return e.Err }

// subcommand returns the git subcommand in args, skipping global options.
func subcommand(args []string) string {
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "-c" || a == "-C":
			i++
		case !strings.HasPrefix(a, "-"):
			return a
		}
	}
	return "git"
}

// repoLocks serialises mutating git commands per repository, so two
// operations started from the UI never race on the index or refs.
var repoLocks sync.Map // cleaned dir -> chan struct{} (capacity 1)

func lockRepo(ctx context.Context, dir string) (func(), error) {
	v, _ := repoLocks.LoadOrStore(filepath.Clean(dir), make(chan struct{}, 1))
	ch := v.(chan struct{})
	select {
	case ch <- struct{}{}:
		return func() { <-ch }, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func baseEnv(k kind) []string {
	e := append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_EDITOR=true", "LC_MESSAGES=C")
	if k == kRead {
		e = append(e, "GIT_OPTIONAL_LOCKS=0")
	}
	if os.Getenv("GIT_SSH_COMMAND") == "" {
		// No password prompts, and an unreachable host fails in seconds, not minutes.
		e = append(e, "GIT_SSH_COMMAND=ssh -o BatchMode=yes -o ConnectTimeout=10")
	}
	return e
}

// run executes git in dir. env entries are appended last, so they override
// the defaults. Write and network commands hold the repository lock.
// alwaysArgs go before every git command: gitnest's own refs (the undo
// point) never decorate commits. git 2.39 and newer leave such refs out of
// decorations anyway; older ones need telling.
var alwaysArgs = []string{"-c", "log.excludeDecoration=refs/worktree/gitnest/*"}

func run(ctx context.Context, k kind, dir string, env []string, args ...string) (string, error) {
	if k != kRead {
		unlock, err := lockRepo(ctx, dir)
		if err != nil {
			return "", &Error{Args: args, Canceled: true, Err: err}
		}
		defer unlock()
	}
	limit := timeoutFor(k)
	if limit > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, limit)
		defer cancel()
	}

	cmd := exec.CommandContext(ctx, "git", append(alwaysArgs, args...)...)
	cmd.Dir = dir
	cmd.Env = append(append(baseEnv(k), env...), envFrom(ctx)...)
	setProcGroup(cmd)
	// Children (ssh, hooks) may keep the pipes open after git is killed.
	cmd.WaitDelay = 2 * time.Second
	var out, errb bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		ge := &Error{Args: args, Err: err}
		switch {
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			ge.Timeout = limit
		case errors.Is(ctx.Err(), context.Canceled):
			ge.Canceled = true
		}
		ge.Output = strings.TrimSpace(errb.String())
		if ge.Output == "" {
			ge.Output = strings.TrimSpace(out.String())
		}
		return out.String(), ge
	}
	return out.String(), nil
}

// colorConfig holds extra "-c key=value" settings for coloured output, set
// from the colour theme (see SetColors).
var colorConfig atomic.Value // []string

// SetColors makes diffs, logs and status use the given git colours, e.g.
// {"color.diff.new": "#a6e3a1"}. Empty values are skipped; nil restores
// the user's own git colours.
func SetColors(colors map[string]string) {
	var args []string
	keys := make([]string, 0, len(colors))
	for k := range colors {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if colors[k] != "" {
			args = append(args, "-c", k+"="+colors[k])
		}
	}
	colorConfig.Store(args)
}

// colored prefixes a git command with forced colour and the theme's colours.
func colored(args ...string) []string {
	out := []string{"-c", "color.ui=always"}
	if extra, _ := colorConfig.Load().([]string); len(extra) > 0 {
		out = append(out, extra...)
	}
	return append(out, args...)
}

func firstLines(s string, n int) string {
	lines := strings.Split(s, "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	return strings.Join(lines, " ")
}

// Output shown in the UI is cut at maxShownLines lines or maxShownBytes
// bytes, whichever comes first: a minified file can be megabytes on a
// single line.
const (
	maxShownLines = 5000
	maxShownBytes = 1 << 20
)

// limitOutput cuts s to the limits above, at a line end when one is close
// enough and otherwise at a character boundary, and says so.
func limitOutput(s string) string {
	cut := len(s)
	if n := strings.Count(s, "\n"); n > maxShownLines {
		cut = 0
		for i := 0; i < maxShownLines; i++ {
			cut += strings.IndexByte(s[cut:], '\n') + 1
		}
		cut-- // drop the last newline
	}
	if cut > maxShownBytes {
		cut = maxShownBytes
		if nl := strings.LastIndexByte(s[:cut], '\n'); nl > cut/2 {
			cut = nl
		} else {
			for cut > 0 && !utf8.RuneStart(s[cut]) {
				cut--
			}
		}
	}
	if cut >= len(s) {
		return s
	}
	// \x1b[m ends a colour left open by the cut.
	return s[:cut] + "\x1b[m\n… (truncated)"
}
