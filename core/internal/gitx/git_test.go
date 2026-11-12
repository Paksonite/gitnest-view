package gitx

// Integration tests: they run the real git binary against throwaway repositories.

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var bg = context.Background()

// TestMain isolates git from the developer's own configuration.
func TestMain(m *testing.M) {
	home, err := os.MkdirTemp("", "gitnest-test-home")
	if err != nil {
		panic(err)
	}
	for k, v := range map[string]string{
		"HOME":                home,
		"XDG_CONFIG_HOME":     filepath.Join(home, ".config"),
		"GIT_CONFIG_NOSYSTEM": "1",
		"GIT_CONFIG_GLOBAL":   os.DevNull,
		"GIT_AUTHOR_NAME":     "Test",
		"GIT_AUTHOR_EMAIL":    "test@example.com",
		"GIT_COMMITTER_NAME":  "Test",
		"GIT_COMMITTER_EMAIL": "test@example.com",
	} {
		os.Setenv(k, v)
	}
	code := m.Run()
	os.RemoveAll(home)
	os.Exit(code)
}

// git runs a setup command and fails the test if it errors.
func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_EDITOR=true")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func newRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	git(t, dir, "init", "-q", "-b", "main")
	return dir
}

func writeFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// commit writes name and commits it with msg, returning the new HEAD hash.
func commit(t *testing.T, dir, name, content, msg string) string {
	t.Helper()
	writeFile(t, dir, name, content)
	git(t, dir, "add", name)
	git(t, dir, "commit", "-q", "-m", msg)
	return git(t, dir, "rev-parse", "HEAD")
}

// conflictRepo returns a repo whose `main` and `other` branches change f.txt
// differently, with `main` checked out. otherHash is the tip of `other`.
func conflictRepo(t *testing.T) (dir, otherHash string) {
	t.Helper()
	dir = newRepo(t)
	commit(t, dir, "f.txt", "base\n", "base")
	git(t, dir, "checkout", "-q", "-b", "other")
	otherHash = commit(t, dir, "f.txt", "other\n", "other change")
	git(t, dir, "checkout", "-q", "main")
	commit(t, dir, "f.txt", "main\n", "main change")
	return dir, otherHash
}

func mustState(t *testing.T, dir string, want State) {
	t.Helper()
	got, err := GetState(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("state = %q, want %q", got, want)
	}
}

func TestRewordHeadKeepsStagedChangesAndBody(t *testing.T) {
	dir := newRepo(t)
	head := commit(t, dir, "a.txt", "a\n", "old subject\n\nbody stays\n")
	writeFile(t, dir, "staged.txt", "not part of the commit\n")
	git(t, dir, "add", "staged.txt")

	if err := RewordMessage(bg, dir, head, "new subject\n\nbody stays"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "log", "-1", "--format=%B"); got != "new subject\n\nbody stays" {
		t.Errorf("message = %q", got)
	}
	if got := git(t, dir, "diff", "--cached", "--name-only"); got != "staged.txt" {
		t.Errorf("staged files = %q, want staged.txt still staged", got)
	}
	if got := git(t, dir, "show", "--name-only", "--format=", "HEAD"); got != "a.txt" {
		t.Errorf("HEAD files = %q, want only a.txt", got)
	}
}

func TestRewordOlderCommit(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	mid := commit(t, dir, "b.txt", "b\n", "second\n\nmiddle body\n")
	commit(t, dir, "c.txt", "c\n", "third")

	if err := RewordMessage(bg, dir, mid, "second, reworded\n\nmiddle body"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "log", "--format=%s", "-3"); got != "third\nsecond, reworded\nfirst" {
		t.Errorf("subjects = %q", got)
	}
	if got := git(t, dir, "log", "-1", "--format=%B", "HEAD~1"); got != "second, reworded\n\nmiddle body" {
		t.Errorf("message = %q", got)
	}
	mustState(t, dir, StateNone)
}

func TestRewordRejectsBadSubject(t *testing.T) {
	dir := newRepo(t)
	head := commit(t, dir, "a.txt", "a\n", "subject")
	for _, s := range []string{"", "  ", "\n \n"} {
		if err := RewordMessage(bg, dir, head, s); err == nil {
			t.Errorf("Reword(%q) succeeded", s)
		}
	}
}

func TestMergeConflictContinue(t *testing.T) {
	dir, _ := conflictRepo(t)
	if err := Merge(bg, dir, "other"); err == nil {
		t.Fatal("merge should conflict")
	}
	mustState(t, dir, StateMerging)
	info, err := GetInfo(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if info.State != StateMerging || !info.Conflicts {
		t.Fatalf("info = %+v", info)
	}
	if err := Skip(bg, dir, StateMerging); err == nil {
		t.Error("skip should be refused while merging")
	}

	writeFile(t, dir, "f.txt", "resolved\n")
	git(t, dir, "add", "f.txt")
	if err := Continue(bg, dir, StateMerging); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
	if parents := strings.Fields(git(t, dir, "log", "-1", "--format=%P")); len(parents) != 2 {
		t.Errorf("HEAD parents = %v, want a merge commit", parents)
	}
}

func TestMergeConflictAbort(t *testing.T) {
	dir, _ := conflictRepo(t)
	before := git(t, dir, "rev-parse", "HEAD")
	_ = Merge(bg, dir, "other")
	mustState(t, dir, StateMerging)
	if err := Abort(bg, dir, StateMerging); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
	if after := git(t, dir, "rev-parse", "HEAD"); after != before {
		t.Errorf("HEAD moved: %s -> %s", before, after)
	}
}

func TestCherryPickConflictSkip(t *testing.T) {
	dir, other := conflictRepo(t)
	if _, err := run(bg, kWrite, dir, nil, "cherry-pick", other); err == nil {
		t.Fatal("cherry-pick should conflict")
	}
	mustState(t, dir, StateCherryPicking)
	if err := Skip(bg, dir, StateCherryPicking); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
}

func TestRevertConflictAbort(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "one\n", "one")
	target := commit(t, dir, "f.txt", "two\n", "two")
	commit(t, dir, "f.txt", "three\n", "three")
	if err := Revert(bg, dir, target); err == nil {
		t.Fatal("revert should conflict")
	}
	mustState(t, dir, StateReverting)
	if err := Abort(bg, dir, StateReverting); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
}

func TestRebaseConflictContinue(t *testing.T) {
	dir, _ := conflictRepo(t)
	if err := RebaseOnto(bg, dir, "other"); err == nil {
		t.Fatal("rebase should conflict")
	}
	mustState(t, dir, StateRebasing)

	writeFile(t, dir, "f.txt", "resolved\n")
	git(t, dir, "add", "f.txt")
	if err := Continue(bg, dir, StateRebasing); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
	if got := git(t, dir, "log", "--format=%s", "-3"); got != "main change\nother change\nbase" {
		t.Errorf("history = %q", got)
	}
}

func TestBisectAbort(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "a")
	git(t, dir, "bisect", "start")
	mustState(t, dir, StateBisecting)
	if err := Continue(bg, dir, StateBisecting); err == nil {
		t.Error("continue should be refused while bisecting")
	}
	if err := Abort(bg, dir, StateBisecting); err != nil {
		t.Fatal(err)
	}
	mustState(t, dir, StateNone)
}

func TestStateInLinkedWorktree(t *testing.T) {
	dir, _ := conflictRepo(t)
	wt := filepath.Join(t.TempDir(), "wt")
	git(t, dir, "worktree", "add", "-q", "-b", "wt-branch", wt, "main")
	if err := Merge(bg, wt, "other"); err == nil {
		t.Fatal("merge should conflict")
	}
	mustState(t, wt, StateMerging)
	mustState(t, dir, StateNone) // the main worktree is unaffected
}

func TestTimeoutKillsHooks(t *testing.T) {
	dir := newRepo(t)
	hooks := filepath.Join(dir, "hooks")
	if err := os.MkdirAll(hooks, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(hooks, "pre-commit"), []byte("#!/bin/sh\nsleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "config", "core.hooksPath", hooks)
	writeFile(t, dir, "a.txt", "a\n")
	git(t, dir, "add", "a.txt")

	old := WriteTimeout
	WriteTimeout = 300 * time.Millisecond
	defer func() { WriteTimeout = old }()

	start := time.Now()
	err := CommitMsg(bg, dir, "msg")
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("commit took %s; the hook was not killed", elapsed)
	}
	var ge *Error
	if !errors.As(err, &ge) || ge.Timeout != WriteTimeout {
		t.Fatalf("err = %#v, want *Error with Timeout", err)
	}
	if !strings.Contains(err.Error(), "git commit timed out") {
		t.Errorf("message = %q", err.Error())
	}
}

func TestCanceledContext(t *testing.T) {
	dir := newRepo(t)
	ctx, cancel := context.WithCancel(bg)
	cancel()
	err := StageAll(ctx, dir)
	var ge *Error
	if !errors.As(err, &ge) || !ge.Canceled {
		t.Fatalf("err = %#v, want canceled *Error", err)
	}
}

func TestErrorKeepsFullOutput(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "a")
	err := Checkout(bg, dir, Branch{Name: "does-not-exist"})
	var ge *Error
	if !errors.As(err, &ge) {
		t.Fatalf("err = %#v, want *Error", err)
	}
	if !strings.Contains(ge.Output, "does-not-exist") || subcommand(ge.Args) != "checkout" {
		t.Errorf("error = %+v", ge)
	}
}

func TestRepoLockSerializesWrites(t *testing.T) {
	dir := t.TempDir()
	unlock, err := lockRepo(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(bg, 50*time.Millisecond)
	defer cancel()
	if _, err := lockRepo(ctx, dir+"/"); err == nil {
		t.Fatal("second lock on the same repo should wait")
	}
	if other, err := lockRepo(bg, t.TempDir()); err != nil {
		t.Fatal("a different repo should not be blocked")
	} else {
		other()
	}
	unlock()
	again, err := lockRepo(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	again()
}

func TestBranches(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	git(t, dir, "branch", "feature/x")
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare")
	git(t, dir, "remote", "add", "origin", remote)
	git(t, dir, "push", "-q", "-u", "origin", "main")
	commit(t, dir, "b.txt", "b\n", "second")

	local, remotes, err := Branches(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(local) != 2 {
		t.Fatalf("local = %+v", local)
	}
	byName := map[string]Branch{}
	for _, b := range local {
		byName[b.Name] = b
	}
	main, feat := byName["main"], byName["feature/x"]
	if !main.Current || main.Upstream != "origin/main" || main.Track != "[ahead 1]" || main.Subject != "second" {
		t.Errorf("main = %+v", main)
	}
	if feat.Current || feat.Upstream != "" || feat.Subject != "first" {
		t.Errorf("feature/x = %+v", feat)
	}
	if len(remotes) != 1 || remotes[0].Name != "origin/main" || !remotes[0].Remote {
		t.Errorf("remote = %+v", remotes)
	}
}

// A branch whose upstream was deleted on the remote (and pruned) shows as
// gone, as in the Branches panel, not as one without an upstream.
func TestGetInfoUpstreamGone(t *testing.T) {
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	git(t, dir, "remote", "add", "origin", remote)
	git(t, dir, "push", "-q", "-u", "origin", "main")
	git(t, dir, "checkout", "-q", "-b", "topic")
	git(t, dir, "push", "-q", "-u", "origin", "topic")
	if in, _ := GetInfo(bg, dir); !in.Upstream || in.UpstreamGone {
		t.Fatalf("pushed: %+v", in)
	}
	git(t, remote, "branch", "-D", "topic")
	git(t, dir, "fetch", "-q", "--prune")
	in, err := GetInfo(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	if in.Upstream || !in.UpstreamGone || in.Sync() != "✗ gone" {
		t.Fatalf("gone: %+v (%q)", in, in.Sync())
	}
	bs, _, err := Branches(bg, dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range bs {
		if b.Name == "topic" {
			if _, _, gone := b.AheadBehind(); !gone {
				t.Errorf("the Branches panel should agree: %+v", b)
			}
		}
	}
}

// Fetching (what gitnest does on its own) only updates the remote-tracking
// branches: the local branch, the index and the files stay as they are,
// and the commits to pull show as "behind".
func TestFetchLeavesLocalBranchesAlone(t *testing.T) {
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	git(t, dir, "remote", "add", "origin", remote)
	git(t, dir, "push", "-q", "-u", "origin", "main")
	other := filepath.Join(t.TempDir(), "other")
	git(t, filepath.Dir(other), "clone", "-q", remote, other)
	commit(t, other, "b.txt", "b\n", "theirs")
	git(t, other, "push", "-q", "origin", "main")
	writeFile(t, dir, "a.txt", "local edit\n")

	head := git(t, dir, "rev-parse", "HEAD")
	if err := Fetch(bg, dir); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "rev-parse", "HEAD"); got != head {
		t.Errorf("fetch moved HEAD: %s → %s", head, got)
	}
	if _, err := os.Stat(filepath.Join(dir, "b.txt")); err == nil {
		t.Error("fetch brought their file into the working tree")
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "a.txt")); string(b) != "local edit\n" {
		t.Errorf("fetch touched a local edit: %q", b)
	}
	if in, _ := GetInfo(bg, dir); in.Behind != 1 || in.Ahead != 0 {
		t.Errorf("after fetch: %+v", in)
	}
}

// divergedRepo returns a clone whose main has one commit of its own and
// one new commit on origin (fetched), each in file ours/theirs.
func divergedRepo(t *testing.T, ours, theirs string) string {
	t.Helper()
	remote := t.TempDir()
	git(t, remote, "init", "-q", "--bare", "-b", "main")
	dir := newRepo(t)
	commit(t, dir, "base.txt", "base\n", "base")
	git(t, dir, "remote", "add", "origin", remote)
	git(t, dir, "push", "-q", "-u", "origin", "main")
	other := filepath.Join(t.TempDir(), "other")
	git(t, filepath.Dir(other), "clone", "-q", remote, other)
	commit(t, other, theirs, "theirs\n", "theirs")
	git(t, other, "push", "-q", "origin", "main")
	commit(t, dir, ours, "ours\n", "ours")
	git(t, dir, "fetch", "-q")
	return dir
}

func TestPullSetting(t *testing.T) {
	dir := divergedRepo(t, "a.txt", "b.txt")
	for _, c := range []struct {
		config [][2]string
		want   string
	}{
		{nil, PullUnset},
		{[][2]string{{"pull.rebase", "true"}}, PullRebase},
		{[][2]string{{"pull.rebase", "merges"}}, PullRebase},
		{[][2]string{{"pull.rebase", "false"}}, PullMerge},
		{[][2]string{{"pull.ff", "only"}}, PullFFOnly},
		{[][2]string{{"pull.ff", "true"}}, PullMerge},
		{[][2]string{{"pull.rebase", "true"}, {"branch.main.rebase", "false"}}, PullMerge}, // the branch wins
	} {
		for _, k := range []string{"pull.rebase", "pull.ff", "branch.main.rebase"} {
			exec.Command("git", "-C", dir, "config", "--unset", k).Run()
		}
		for _, kv := range c.config {
			git(t, dir, "config", kv[0], kv[1])
		}
		if got := PullSetting(bg, dir); got != c.want {
			t.Errorf("%v: %q, want %q", c.config, got, c.want)
		}
	}
}

func TestUpstreamConflicts(t *testing.T) {
	if v, _ := GitVersion(bg); !VersionAtLeast(v, "2.38") {
		// Too old for merge-tree --write-tree: it says it couldn't check.
		if files, checked := UpstreamConflicts(bg, divergedRepo(t, "a.txt", "b.txt")); checked || files != nil {
			t.Errorf("git %s: %v checked=%v", v, files, checked)
		}
		return
	}
	clean := divergedRepo(t, "a.txt", "b.txt")
	if files, checked := UpstreamConflicts(bg, clean); !checked || len(files) != 0 {
		t.Errorf("different files: %v checked=%v", files, checked)
	}
	clash := divergedRepo(t, "same.txt", "same.txt")
	if files, checked := UpstreamConflicts(bg, clash); !checked || len(files) != 1 || files[0] != "same.txt" {
		t.Errorf("same file: %v checked=%v", files, checked)
	}
	// Nothing was touched by the check.
	if out := git(t, clash, "status", "--porcelain"); out != "" {
		t.Errorf("the check changed the working tree: %q", out)
	}
}

// A rebasing pull of a diverged branch puts the local commit on top and
// keeps uncommitted changes.
func TestPullWithRebaseKeepsLocalChanges(t *testing.T) {
	dir := divergedRepo(t, "a.txt", "b.txt")
	writeFile(t, dir, "base.txt", "edited, not committed\n")
	if err := PullWith(bg, dir, PullFFOnly); err == nil {
		t.Fatal("a fast-forward-only pull of a diverged branch should fail")
	}
	if err := PullWith(bg, dir, PullRebase); err != nil {
		t.Fatal(err)
	}
	in, _ := GetInfo(bg, dir)
	if in.Ahead != 1 || in.Behind != 0 {
		t.Errorf("after the rebase: %+v", in)
	}
	if got := git(t, dir, "log", "--format=%s", "-3"); got != "ours\ntheirs\nbase" {
		t.Errorf("history: %q", got)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "base.txt")); string(b) != "edited, not committed\n" {
		t.Errorf("uncommitted change lost: %q", b)
	}
}
