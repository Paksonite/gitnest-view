package gitx

// Integration tests for the everyday operations: files, branches, stash, remotes.

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

var ansi = regexp.MustCompile("\x1b\\[[0-9;]*m")

func stripANSI(s string) string { return ansi.ReplaceAllString(s, "") }

func TestBasicFileOps(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	writeFile(t, dir, "a.txt", "changed\n")
	writeFile(t, dir, "new.txt", "new\n")
	files, err := Files(bg, dir)
	if err != nil || len(files) != 2 {
		t.Fatalf("Files = %+v %v", files, err)
	}
	if d := DiffFile(bg, dir, files[0]); !strings.Contains(stripANSI(d), "+changed") {
		t.Errorf("diff: %q", d)
	}
	if d := DiffFile(bg, dir, File{Path: "new.txt", X: '?', Y: '?'}); !strings.Contains(stripANSI(d), "+new") {
		t.Errorf("untracked diff: %q", d)
	}
	if err := Stage(bg, dir, "a.txt"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "diff", "--cached", "--name-only"); got != "a.txt" {
		t.Errorf("staged: %q", got)
	}
	if err := Unstage(bg, dir, "a.txt"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "diff", "--cached", "--name-only"); got != "" {
		t.Errorf("after unstage: %q", got)
	}
	if err := StageAll(bg, dir); err != nil {
		t.Fatal(err)
	}
	if err := UnstageAll(bg, dir); err != nil {
		t.Fatal(err)
	}
	if err := Discard(bg, dir, File{Path: "a.txt", X: ' ', Y: 'M'}); err != nil {
		t.Fatal(err)
	}
	if err := Discard(bg, dir, File{Path: "new.txt", X: '?', Y: '?'}); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "status", "--porcelain"); got != "" {
		t.Errorf("after discard: %q", got)
	}
	cs, err := Log(bg, dir, 10)
	if err != nil || len(cs) != 1 || cs[0].Subject != "first" {
		t.Errorf("Log = %+v %v", cs, err)
	}
	if s := Show(bg, dir, cs[0].Hash); !strings.Contains(s, "first") {
		t.Errorf("Show: %q", s)
	}
	if d := RepoDetails(bg, dir, 5); len(d.Commits) != 1 || d.Commits[0].Subject != "first" {
		t.Errorf("RepoDetails: %+v", d)
	}
}

func TestRepoDetails(t *testing.T) {
	dir, _ := cloneRepo(t)
	readme := "# Title\n\n[![badge](x)](y)\n\n```sh\nmake\n```\n\nInfrastructure and tooling for our platform.\n\nMore.\n"
	commit(t, dir, "README.md", readme, "add readme")
	git(t, dir, "tag", "v1.2.0")
	commit(t, dir, "b.txt", "b\n", "second")
	for i := 0; i < 10; i++ {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("new%d.txt", i)), []byte("x"), 0o644)
	}
	d := RepoDetails(context.Background(), dir, 2)
	if d.Upstream != "origin/main" || d.Tag != "v1.2.0" || d.Description != "Infrastructure and tooling for our platform." {
		t.Errorf("details: upstream %q tag %q description %q", d.Upstream, d.Tag, d.Description)
	}
	if len(d.Commits) != 2 || d.Commits[0].Subject != "second" || d.Commits[0].Author == "" || d.Commits[0].Unix == 0 {
		t.Errorf("commits: %+v", d.Commits)
	}
	if len(d.Changes) != maxChanges || d.More != 2 || !strings.HasPrefix(d.Changes[0], "?? ") {
		t.Errorf("changes: %v +%d", d.Changes, d.More)
	}
}

func TestBranchOps(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	if err := NewBranch(bg, dir, "feat", "main"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "branch", "--show-current"); got != "feat" {
		t.Errorf("current %q", got)
	}
	commit(t, dir, "b.txt", "b\n", "feat work")
	git(t, dir, "checkout", "-q", "main")
	if err := RenameBranch(bg, dir, "feat", "feature"); err != nil {
		t.Fatal(err)
	}
	if err := DeleteBranch(bg, dir, "feature", false); err == nil {
		t.Error("unmerged branch deleted without force")
	}
	if err := DeleteBranch(bg, dir, "feature", true); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "branch", "--list", "feature"); got != "" {
		t.Errorf("still there: %q", got)
	}
}

func TestStashOps(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	for _, c := range []string{"one\n", "two\n"} {
		writeFile(t, dir, "a.txt", c)
		if err := StashPush(bg, dir, "wip "+strings.TrimSpace(c)); err != nil {
			t.Fatal(err)
		}
	}
	ss, err := Stashes(bg, dir)
	if err != nil || len(ss) != 2 || !strings.Contains(ss[0].Msg, "wip two") {
		t.Fatalf("Stashes = %+v %v", ss, err)
	}
	if s := StashShow(bg, dir, "stash@{1}"); !strings.Contains(stripANSI(s), "+one") {
		t.Errorf("StashShow: %q", s)
	}
	if err := StashApply(bg, dir, "stash@{1}"); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "checkout", "-q", "--", "a.txt")
	if err := StashPop(bg, dir, "stash@{0}"); err != nil {
		t.Fatal(err)
	}
	git(t, dir, "checkout", "-q", "--", "a.txt")
	if err := StashDrop(bg, dir, "stash@{0}"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "stash", "list"); got != "" {
		t.Errorf("stashes left: %q", got)
	}
}

func TestRemoteOps(t *testing.T) {
	seed := newRepo(t)
	commit(t, seed, "a.txt", "a\n", "first")
	origin := t.TempDir()
	git(t, origin, "clone", "-q", "--bare", seed, ".")
	dir := t.TempDir()
	git(t, dir, "clone", "-q", origin, ".")
	commit(t, dir, "c.txt", "c\n", "local")
	if err := Push(bg, dir, false, true); err != nil {
		t.Fatal(err)
	}
	if got, want := git(t, origin, "rev-parse", "main"), git(t, dir, "rev-parse", "HEAD"); got != want {
		t.Errorf("origin main %s, want %s", got, want)
	}
	git(t, dir, "checkout", "-q", "-b", "topic")
	commit(t, dir, "t.txt", "t\n", "topic")
	if err := Push(bg, dir, false, false); err != nil { // sets the upstream
		t.Fatal(err)
	}
	if got := git(t, dir, "rev-parse", "--abbrev-ref", "topic@{u}"); got != "origin/topic" {
		t.Errorf("upstream %q", got)
	}
	other := t.TempDir()
	git(t, other, "clone", "-q", origin, ".")
	tip := commit(t, other, "o.txt", "o\n", "remote work")
	git(t, other, "push", "-q", "origin", "main")
	git(t, dir, "checkout", "-q", "main")
	if err := Fetch(bg, dir); err != nil {
		t.Fatal(err)
	}
	if err := Pull(bg, dir, false); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "rev-parse", "HEAD"); got != tip {
		t.Errorf("after pull HEAD %s want %s", got, tip)
	}
	if err := DeleteRemoteBranch(bg, dir, "origin/topic"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, origin, "branch", "--list", "topic"); got != "" {
		t.Errorf("remote branch left: %q", got)
	}
}

func TestUpstreamSeenLocally(t *testing.T) {
	seed := newRepo(t)
	commit(t, seed, "a.txt", "a\n", "first")
	origin := t.TempDir()
	git(t, origin, "clone", "-q", "--bare", seed, ".")
	dir := t.TempDir()
	git(t, dir, "clone", "-q", origin, ".")
	commit(t, dir, "b.txt", "b\n", "pushed work")
	git(t, dir, "push", "-q")
	// A clone has origin/HEAD; it must not be reported as a branch named "origin".
	if got, _ := CheckRewrite(bg, dir, "HEAD", ActionReword); len(got) != 1 || got[0] != "origin/main" {
		t.Errorf("pushed to %v, want [origin/main]", got)
	}

	// Reword the pushed commit: diverged, but only through our own rewrite.
	if err := RewordMessage(bg, dir, "HEAD", "pushed work, reworded"); err != nil {
		t.Fatal(err)
	}
	if seen, err := UpstreamSeenLocally(bg, dir); err != nil || !seen {
		t.Fatalf("after reword: seen=%v err=%v", seen, err)
	}
	if err := Push(bg, dir, false, true); err == nil || !PushRejected(err) {
		t.Fatalf("plain push after rewrite: err=%v", err)
	}
	if err := Push(bg, dir, true, true); err != nil {
		t.Fatalf("force push with lease: %v", err)
	}

	// Someone else pushes; after a fetch the remote has a commit we never had.
	other := t.TempDir()
	git(t, other, "clone", "-q", origin, ".")
	commit(t, other, "c.txt", "c\n", "their work")
	git(t, other, "push", "-q")
	git(t, dir, "fetch", "-q")
	if seen, err := UpstreamSeenLocally(bg, dir); err != nil || seen {
		t.Fatalf("after their push: seen=%v err=%v", seen, err)
	}
}

func TestTags(t *testing.T) {
	seed := newRepo(t)
	commit(t, seed, "a.txt", "a\n", "first")
	origin := t.TempDir()
	git(t, origin, "clone", "-q", "--bare", seed, ".")
	dir := t.TempDir()
	git(t, dir, "clone", "-q", origin, ".")
	if err := CreateTag(bg, dir, "v1.0.0", "", "Release 1.0"); err != nil {
		t.Fatal(err)
	}
	if err := CreateTag(bg, dir, "light", "HEAD", ""); err != nil {
		t.Fatal(err)
	}
	ts, err := Tags(bg, dir)
	if err != nil || len(ts) != 2 {
		t.Fatalf("Tags = %+v %v", ts, err)
	}
	byName := map[string]Tag{}
	for _, tg := range ts {
		byName[tg.Name] = tg
	}
	if !byName["v1.0.0"].Annotated || byName["v1.0.0"].Subject != "Release 1.0" || byName["light"].Annotated {
		t.Errorf("tags: %+v", ts)
	}
	if s := TagInfo(bg, dir, "v1.0.0"); !strings.Contains(stripANSI(s), "Release 1.0") {
		t.Errorf("TagInfo: %q", s)
	}
	if err := PushTag(bg, dir, "v1.0.0"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, origin, "tag", "--list"); got != "v1.0.0" {
		t.Errorf("remote tags: %q", got)
	}
	if err := DeleteRemoteTag(bg, dir, "v1.0.0"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, origin, "tag", "--list"); got != "" {
		t.Errorf("remote tags after delete: %q", got)
	}
	if err := DeleteTag(bg, dir, "light"); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "tag", "--list"); got != "v1.0.0" {
		t.Errorf("local tags: %q", got)
	}
}

func TestActivity(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "first")
	commit(t, dir, "b.txt", "b\n", "second")
	git(t, dir, "checkout", "-q", "-b", "side")
	commit(t, dir, "c.txt", "c\n", "on a branch")
	cs, err := Activity(context.Background(), dir, time.Now().Add(-time.Hour), 10)
	subjects := map[string]bool{}
	for _, c := range cs {
		subjects[c.Subject] = c.Unix > 0 && c.Author != ""
	}
	if err != nil || len(cs) != 3 || !subjects["on a branch"] || !subjects["first"] { // every local branch
		t.Fatalf("Activity = %+v, %v", cs, err)
	}
	if cs, _ := Activity(context.Background(), dir, time.Now().Add(-time.Hour), 2); len(cs) != 2 {
		t.Errorf("max: %d", len(cs))
	}
	if cs, _ := Activity(context.Background(), dir, time.Now().Add(time.Hour), 10); len(cs) != 0 {
		t.Errorf("since the future: %d", len(cs))
	}
}
