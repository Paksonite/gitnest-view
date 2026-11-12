package gitx

// Additions for GitNest View (not in the terminal gitnest): credentials for
// one call, and cloning.

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type envKey struct{}

// WithEnv makes every git command run with ctx get the extra environment.
func WithEnv(ctx context.Context, env []string) context.Context {
	if len(env) == 0 {
		return ctx
	}
	return context.WithValue(ctx, envKey{}, env)
}

func envFrom(ctx context.Context) []string {
	env, _ := ctx.Value(envKey{}).([]string)
	return env
}

// TokenEnv is the environment that lets git reach https://host with an
// access token, for this one command: nothing is written to the
// repository's configuration, a credential helper or the remote URL.
func TokenEnv(host, user, token string) []string {
	if host == "" || token == "" {
		return nil
	}
	if user == "" {
		user = "token"
	}
	basic := base64.StdEncoding.EncodeToString([]byte(user + ":" + token))
	return []string{
		"GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=http.https://" + host + "/.extraheader",
		"GIT_CONFIG_VALUE_0=Authorization: Basic " + basic,
	}
}

// CloneTimeout limits a clone; big repositories on slow links take a while.
var CloneTimeout = 30 * time.Minute

// Clone clones url into dest, which must not exist yet (or be empty). The
// directories above dest are created.
func Clone(ctx context.Context, url, dest string) error {
	if url == "" || dest == "" {
		return errors.New("clone needs a URL and a destination")
	}
	if entries, err := os.ReadDir(dest); err == nil && len(entries) > 0 {
		return errors.New("the destination already exists and is not empty: " + dest)
	}
	parent := filepath.Dir(dest)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return err
	}
	unlock, err := lockRepo(ctx, dest)
	if err != nil {
		return err
	}
	defer unlock()
	ctx, cancel := context.WithTimeout(ctx, CloneTimeout)
	defer cancel()

	args := []string{"clone", "--quiet", "--", url, dest}
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = parent
	cmd.Env = append(baseEnv(kNet), envFrom(ctx)...)
	setProcGroup(cmd)
	cmd.WaitDelay = 2 * time.Second
	var errb bytes.Buffer
	cmd.Stderr = &errb
	if err := cmd.Run(); err != nil {
		ge := &Error{Args: []string{"clone", Redact(url)}, Err: err, Output: Redact(strings.TrimSpace(errb.String()))}
		switch {
		case errors.Is(ctx.Err(), context.DeadlineExceeded):
			ge.Timeout = CloneTimeout
		case errors.Is(ctx.Err(), context.Canceled):
			ge.Canceled = true
		}
		// git leaves a half-made directory behind when it is killed.
		if entries, rerr := os.ReadDir(dest); rerr == nil && !hasGitDir(entries) {
			_ = os.RemoveAll(dest)
		}
		return ge
	}
	return nil
}

func hasGitDir(entries []os.DirEntry) bool {
	for _, e := range entries {
		if e.Name() == ".git" {
			return true
		}
	}
	return false
}

// ShowPlain is one commit as plain text: its header, message, the files it
// changed and the patch, without colours.
func ShowPlain(ctx context.Context, dir, rev string) (string, error) {
	// A merge shows what it brought into the branch (against its first parent).
	return run(ctx, kRead, dir, nil, "show", "--no-color", "--no-ext-diff", "--stat", "--patch", "--diff-merges=first-parent",
		"--format=%H%n%an <%ae>%n%ad%n%n%B", "--date=format:%Y-%m-%d %H:%M", rev)
}

// NewBranchFrom creates and checks out name at base without tracking it:
// a branch made from origin/develop must not push into develop.
func NewBranchFrom(ctx context.Context, dir, name, base string) error {
	args := []string{"checkout", "--no-track", "-b", name}
	if base != "" {
		args = append(args, base)
	}
	_, err := run(ctx, kWrite, dir, nil, args...)
	return err
}

// GrepMatch is one line that matched.
type GrepMatch struct {
	File string `json:"file"`
	Line int    `json:"line"`
	Text string `json:"text"`
}

// Grep finds text in the tracked files of the working tree (git grep), at
// most max lines. fixed searches for the text as is; otherwise it is a
// regular expression. Case is ignored when ignoreCase.
func Grep(ctx context.Context, dir, text string, fixed, ignoreCase bool, max int) ([]GrepMatch, error) {
	args := []string{"grep", "-n", "-I", "--no-color", "--full-name", "-e", text}
	if fixed {
		args = append(args[:1], append([]string{"-F"}, args[1:]...)...)
	}
	if ignoreCase {
		args = append(args[:1], append([]string{"-i"}, args[1:]...)...)
	}
	out, err := run(ctx, kRead, dir, nil, args...)
	if err != nil {
		// git grep exits 1 when nothing matches.
		var ge *Error
		if errors.As(err, &ge) && ge.Output == "" {
			return nil, nil
		}
		return nil, err
	}
	var matches []GrepMatch
	for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if len(matches) >= max {
			break
		}
		file, rest, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		num, body, ok := strings.Cut(rest, ":")
		if !ok {
			continue
		}
		n, err := strconv.Atoi(num)
		if err != nil {
			continue
		}
		if len(body) > 400 {
			body = body[:400] + "…"
		}
		matches = append(matches, GrepMatch{File: file, Line: n, Text: body})
	}
	return matches, nil
}

// BlockCommit is one commit that changed a block of a file.
type BlockCommit struct {
	SHA     string `json:"sha"`
	Short   string `json:"short"`
	Author  string `json:"author"`
	When    string `json:"when"`
	Subject string `json:"subject"`
}

// BlockEnd finds the line that closes the block opened at line `start`
// (1-based) of text: the first line where the braces balance again. A
// line without braces is its own block.
func BlockEnd(text string, start int) int {
	lines := strings.Split(text, "\n")
	depth, opened := 0, false
	for i := start - 1; i >= 0 && i < len(lines); i++ {
		line := lines[i]
		if c := strings.Index(line, "#"); c >= 0 && !strings.Contains(line[:c], "\"") {
			line = line[:c]
		}
		depth += strings.Count(line, "{") - strings.Count(line, "}")
		if strings.Contains(line, "{") {
			opened = true
		}
		if opened && depth <= 0 {
			return i + 1
		}
		if !opened && i > start-1 {
			break
		}
	}
	return start
}

// BlockHistory lists the commits that changed lines start..end of file,
// newest first, following the lines back through earlier versions.
func BlockHistory(ctx context.Context, dir, file string, start, end, max int) ([]BlockCommit, error) {
	if end < start {
		end = start
	}
	out, err := run(ctx, kRead, dir, nil, "log", "--no-color", "--date=relative",
		"--format=%x01%H%x1f%h%x1f%an%x1f%ad%x1f%s", fmt.Sprintf("-n%d", max),
		fmt.Sprintf("-L%d,%d:%s", start, end, file))
	if err != nil {
		return nil, err
	}
	var commits []BlockCommit
	for _, line := range strings.Split(out, "\n") {
		if !strings.HasPrefix(line, "\x01") {
			continue // the patch text
		}
		f := strings.Split(line[1:], "\x1f")
		if len(f) == 5 {
			commits = append(commits, BlockCommit{f[0], f[1], f[2], f[3], f[4]})
		}
	}
	return commits, nil
}

// ShowFile returns a file as it is in a revision.
func ShowFile(ctx context.Context, dir, rev, file string) (string, error) {
	return run(ctx, kRead, dir, nil, "show", rev+":"+file)
}
