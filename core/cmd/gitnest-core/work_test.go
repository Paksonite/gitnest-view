package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/Paksonite/gitnest-view/core/internal/rpc"
)

// call runs one request through a fresh server, as the app would.
func call(t *testing.T, method string, params any) (json.RawMessage, *rpc.Error) {
	t.Helper()
	srv := rpc.NewServer()
	register(srv)
	req, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	var out bytes.Buffer
	if err := srv.Serve(context.Background(), bytes.NewReader(append(req, '\n')), &out); err != nil {
		t.Fatal(err)
	}
	var resp struct {
		Result json.RawMessage `json:"result"`
		Error  *rpc.Error      `json:"error"`
	}
	if err := json.Unmarshal(out.Bytes(), &resp); err != nil {
		t.Fatalf("%s: %v (%s)", method, err, out.String())
	}
	return resp.Result, resp.Error
}

func must(t *testing.T, method string, params any, into any) {
	t.Helper()
	res, err := call(t, method, params)
	if err != nil {
		t.Fatalf("%s: %s", method, err.Message)
	}
	if into != nil {
		if err := json.Unmarshal(res, into); err != nil {
			t.Fatalf("%s: %v", method, err)
		}
	}
}

func git(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com", "GIT_CONFIG_GLOBAL=/dev/null")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func write(t *testing.T, dir, name, text string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o644); err != nil {
		t.Fatal(err)
	}
}

// newRepo makes a repository with a bare "origin" it tracks.
func newRepo(t *testing.T) (dir, origin string) {
	t.Helper()
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_AUTHOR_NAME", "t")
	t.Setenv("GIT_AUTHOR_EMAIL", "t@example.com")
	t.Setenv("GIT_COMMITTER_NAME", "t")
	t.Setenv("GIT_COMMITTER_EMAIL", "t@example.com")
	root := t.TempDir()
	origin = filepath.Join(root, "origin.git")
	dir = filepath.Join(root, "work")
	git(t, root, "init", "-q", "--bare", "-b", "main", origin)
	git(t, root, "clone", "-q", origin, dir)
	write(t, dir, "a.txt", "one\ntwo\nthree\n")
	git(t, dir, "add", "a.txt")
	git(t, dir, "commit", "-q", "-m", "first")
	git(t, dir, "push", "-q", "-u", "origin", "main")
	return dir, origin
}

func TestStagingAndCommit(t *testing.T) {
	dir, _ := newRepo(t)
	write(t, dir, "a.txt", "one\nTWO\nthree\nfour\n")
	write(t, dir, "new.txt", "hello\nworld\n")

	var d FileDiff
	must(t, "repo.diff", map[string]any{"path": dir, "file": map[string]any{"path": "a.txt", "code": " M"}}, &d)
	if len(d.Hunks) != 1 || d.Digest == "" {
		t.Fatalf("diff: %+v", d)
	}
	// Stage only "+four" (the last line of the hunk).
	var target int
	for i, l := range d.Hunks[0].Lines {
		if l.Kind == "+" && l.Text == "four" {
			target = i
			if l.New != 4 {
				t.Errorf("new line number: %d", l.New)
			}
		}
	}
	must(t, "repo.lines", map[string]any{"path": dir, "file": map[string]any{"path": "a.txt"}, "action": "stage",
		"digest": d.Digest, "lines": []map[string]int{{"Hunk": 0, "Line": target}}}, nil)
	if got := git(t, dir, "diff", "--cached", "--no-color"); !strings.Contains(got, "+four") || strings.Contains(got, "TWO") {
		t.Fatalf("staged:\n%s", got)
	}
	// A stale digest is refused.
	if _, err := call(t, "repo.lines", map[string]any{"path": dir, "file": map[string]any{"path": "a.txt"}, "action": "stage",
		"digest": d.Digest, "lines": []map[string]int{{"Hunk": 0, "Line": 0}}}); err == nil || !strings.Contains(err.Message, "changed") {
		t.Errorf("a stale diff must be refused, got %v", err)
	}

	var nd FileDiff
	must(t, "repo.diff", map[string]any{"path": dir, "file": map[string]any{"path": "new.txt", "untracked": true, "code": "??"}}, &nd)
	if len(nd.Hunks) != 1 || len(nd.Hunks[0].Lines) != 2 || nd.Hunks[0].Lines[1].Text != "world" {
		t.Fatalf("untracked diff: %+v", nd)
	}
	must(t, "repo.stage", map[string]any{"path": dir, "files": []string{"new.txt"}}, nil)
	if _, err := call(t, "repo.commit", map[string]any{"path": dir, "message": "  \n"}); err == nil {
		t.Error("an empty message must be refused")
	}
	must(t, "repo.commit", map[string]any{"path": dir, "message": "feat: add four and new\n\nbody"}, nil)
	if got := git(t, dir, "log", "-1", "--format=%s"); got != "feat: add four and new" {
		t.Errorf("subject %q", got)
	}
	if got := git(t, dir, "status", "--porcelain"); got != "M a.txt" {
		t.Errorf("TWO must stay unstaged, status %q", got)
	}
	must(t, "repo.commit", map[string]any{"path": dir, "message": "feat: better subject", "amend": true}, nil)
	if got := git(t, dir, "log", "-1", "--format=%s"); got != "feat: better subject" {
		t.Errorf("amended subject %q", got)
	}

	must(t, "repo.discard", map[string]any{"path": dir, "files": []map[string]any{{"path": "a.txt", "code": " M"}}}, nil)
	if got := git(t, dir, "status", "--porcelain"); got != "" {
		t.Errorf("after discard: %q", got)
	}
}

func TestBranchesStashesAndPush(t *testing.T) {
	dir, origin := newRepo(t)
	if _, err := call(t, "repo.branch.create", map[string]any{"path": dir, "name": "bad name"}); err == nil {
		t.Error("a name with a space must be refused")
	}
	must(t, "repo.branch.create", map[string]any{"path": dir, "name": "feat/x"}, nil)
	write(t, dir, "b.txt", "b\n")
	git(t, dir, "add", "b.txt")
	git(t, dir, "commit", "-q", "-m", "b")
	must(t, "repo.push", map[string]any{"path": dir}, nil)
	if got := git(t, origin, "branch", "--list", "feat/x"); !strings.Contains(got, "feat/x") {
		t.Errorf("push did not create the branch: %q", got)
	}
	if got := git(t, dir, "rev-parse", "--abbrev-ref", "@{upstream}"); got != "origin/feat/x" {
		t.Errorf("upstream %q", got)
	}
	must(t, "repo.branch.rename", map[string]any{"path": dir, "old": "feat/x", "name": "feat/y"}, nil)

	// A branch made from a remote branch must not track it (a push would go there).
	must(t, "repo.branch.create", map[string]any{"path": dir, "name": "feat/z", "base": "origin/main"}, nil)
	if out, err := exec.Command("git", "-C", dir, "rev-parse", "--abbrev-ref", "feat/z@{upstream}").CombinedOutput(); err == nil {
		t.Errorf("feat/z must not track anything, tracks %s", out)
	}
	git(t, dir, "checkout", "-q", "feat/y")

	write(t, dir, "a.txt", "changed\n")
	must(t, "repo.stash", map[string]any{"path": dir, "action": "push", "message": "wip"}, nil)
	var st struct {
		Stashes []struct{ Ref, Message string } `json:"stashes"`
	}
	must(t, "repo.stashes", map[string]any{"path": dir}, &st)
	if len(st.Stashes) != 1 || !strings.Contains(st.Stashes[0].Message, "wip") {
		t.Fatalf("stashes: %+v", st)
	}
	must(t, "repo.stash", map[string]any{"path": dir, "action": "pop", "ref": st.Stashes[0].Ref}, nil)
	if got := git(t, dir, "status", "--porcelain"); got != "M a.txt" {
		t.Errorf("after pop: %q", got)
	}
}

func TestHistoryRewriteAsksAboutPushedCommits(t *testing.T) {
	dir, _ := newRepo(t)
	for i := 2; i <= 3; i++ {
		write(t, dir, "a.txt", fmt.Sprintf("v%d\n", i))
		git(t, dir, "commit", "-q", "-am", fmt.Sprintf("change %d", i))
	}
	git(t, dir, "push", "-q")
	write(t, dir, "a.txt", "v4\n")
	git(t, dir, "commit", "-q", "-am", "change 4")

	var h struct {
		Commits []struct {
			SHA, Subject string
			Unpushed     bool
		} `json:"commits"`
		Undo string `json:"undo"`
	}
	must(t, "repo.history", map[string]any{"path": dir}, &h)
	if len(h.Commits) != 4 || !h.Commits[0].Unpushed || h.Commits[1].Unpushed {
		t.Fatalf("history: %+v", h.Commits)
	}
	// Rewording a pushed commit needs a second yes.
	var r struct {
		NeedsConfirm bool     `json:"needsConfirm"`
		Remotes      []string `json:"remotes"`
	}
	must(t, "repo.rewrite", map[string]any{"path": dir, "action": "reword", "sha": h.Commits[1].SHA, "message": "change three"}, &r)
	if !r.NeedsConfirm || len(r.Remotes) == 0 {
		t.Fatalf("expected a confirmation request, got %+v", r)
	}
	must(t, "repo.rewrite", map[string]any{"path": dir, "action": "reword", "sha": h.Commits[1].SHA, "message": "change three", "confirm": true}, nil)
	if got := git(t, dir, "log", "-1", "--skip=1", "--format=%s"); got != "change three" {
		t.Errorf("reworded subject %q", got)
	}
	// The unpushed one is squashed without asking; then undo brings it back.
	must(t, "repo.history", map[string]any{"path": dir}, &h)
	must(t, "repo.rewrite", map[string]any{"path": dir, "action": "fixup", "sha": h.Commits[0].SHA}, nil)
	if got := git(t, dir, "rev-list", "--count", "HEAD"); got != "3" {
		t.Errorf("after fixup: %s commits", got)
	}
	must(t, "repo.history", map[string]any{"path": dir}, &h)
	if h.Undo == "" {
		t.Error("the rewrite must leave an undo point")
	}
	must(t, "repo.rewrite", map[string]any{"path": dir, "action": "undo"}, nil)
	if got := git(t, dir, "rev-list", "--count", "HEAD"); got != "4" {
		t.Errorf("after undo: %s commits", got)
	}
	var show struct{ Text string }
	must(t, "repo.show", map[string]any{"path": dir, "sha": h.Commits[0].SHA}, &show)
	if !strings.Contains(show.Text, "a.txt") {
		t.Errorf("show: %q", show.Text)
	}
}

func TestFetchAllAndFastForward(t *testing.T) {
	dir, origin := newRepo(t)
	other := filepath.Join(t.TempDir(), "other")
	git(t, filepath.Dir(other), "clone", "-q", origin, other)
	write(t, other, "a.txt", "upstream\n")
	git(t, other, "commit", "-q", "-am", "upstream change")
	git(t, other, "push", "-q")

	var res struct {
		Results []repoResult `json:"results"`
		Rows    []PullRow    `json:"rows"`
	}
	missing := filepath.Join(t.TempDir(), "nope")
	must(t, "repos.fetchAll", map[string]any{"repos": []map[string]any{{"path": dir}, {"path": missing}}}, &res)
	if len(res.Results) != 2 || len(res.Rows) != 1 || !res.Rows[0].OK || res.Rows[0].Behind != 1 {
		t.Fatalf("fetchAll: %+v", res)
	}
	var failed int
	for _, r := range res.Results {
		if r.Error != "" {
			failed++
		}
	}
	if failed != 1 {
		t.Errorf("one repository must fail: %+v", res.Results)
	}
	var ff struct {
		Results []struct{ Path, Branch, Error string } `json:"results"`
	}
	must(t, "repos.fastForward", map[string]any{"items": []map[string]any{{"path": dir, "branch": "main"}}}, &ff)
	if len(ff.Results) != 1 || ff.Results[0].Error != "" {
		t.Fatalf("fastForward: %+v", ff)
	}
	if got := git(t, dir, "log", "-1", "--format=%s"); got != "upstream change" {
		t.Errorf("not pulled: %q", got)
	}

	var act struct {
		Commits []struct{ Subject string } `json:"commits"`
	}
	must(t, "repos.activity", map[string]any{"paths": []string{dir}, "days": 3}, &act)
	if len(act.Commits) != 2 || act.Commits[0].Subject != "upstream change" {
		t.Errorf("activity: %+v", act.Commits)
	}
}

func TestPullDivergedNeedsAMode(t *testing.T) {
	dir, origin := newRepo(t)
	other := filepath.Join(t.TempDir(), "other")
	git(t, filepath.Dir(other), "clone", "-q", origin, other)
	write(t, other, "b.txt", "server\n")
	git(t, other, "add", "b.txt")
	git(t, other, "commit", "-q", "-m", "server")
	git(t, other, "push", "-q")
	write(t, dir, "c.txt", "local\n")
	git(t, dir, "add", "c.txt")
	git(t, dir, "commit", "-q", "-m", "local")
	git(t, dir, "fetch", "-q")

	if _, err := call(t, "repo.pull", map[string]any{"path": dir}); err == nil || !strings.Contains(err.Message, "rebase or a merge") {
		t.Fatalf("a diverged pull without a mode must explain, got %v", err)
	}
	must(t, "repo.pull", map[string]any{"path": dir, "mode": "rebase"}, nil)
	if got := git(t, dir, "log", "--format=%s", "-3"); got != "local\nserver\nfirst" {
		t.Errorf("after rebase:\n%s", got)
	}
}

func TestTags(t *testing.T) {
	dir, origin := newRepo(t)
	if _, err := call(t, "repo.tag", map[string]any{"path": dir, "action": "create", "name": "bad name"}); err == nil {
		t.Error("a tag name with a space must be refused")
	}
	must(t, "repo.tag", map[string]any{"path": dir, "action": "create", "name": "v1.0.0", "message": "first release"}, nil)
	must(t, "repo.tag", map[string]any{"path": dir, "action": "push", "name": "v1.0.0"}, nil)
	if got := git(t, origin, "tag", "--list"); got != "v1.0.0" {
		t.Errorf("tags on the server: %q", got)
	}
	var list struct {
		Tags []struct {
			Name      string
			Annotated bool
			Subject   string
		} `json:"tags"`
	}
	must(t, "repo.tags", map[string]any{"path": dir}, &list)
	if len(list.Tags) != 1 || !list.Tags[0].Annotated {
		t.Fatalf("tags: %+v", list.Tags)
	}
	must(t, "repo.tag", map[string]any{"path": dir, "action": "deleteRemote", "name": "v1.0.0"}, nil)
	must(t, "repo.tag", map[string]any{"path": dir, "action": "delete", "name": "v1.0.0"}, nil)
	if got := git(t, origin, "tag", "--list"); got != "" {
		t.Errorf("tag still on the server: %q", got)
	}
}

func TestGrepAcrossRepositories(t *testing.T) {
	one, _ := newRepo(t)
	two, _ := newRepo(t)
	write(t, one, "fw.tf", "cidr = \"10.10.0.0/16\"\nother = 1\n")
	git(t, one, "add", "fw.tf")
	write(t, two, "x.tf", "nothing here\n")
	git(t, two, "add", "x.tf")
	var res struct {
		Results []struct {
			Path    string
			Matches []struct {
				File string
				Line int
				Text string
			}
		} `json:"results"`
	}
	must(t, "repos.grep", map[string]any{"paths": []string{one, two}, "text": "10.10.0.0/16"}, &res)
	if len(res.Results) != 1 || res.Results[0].Path != one || len(res.Results[0].Matches) != 1 {
		t.Fatalf("grep: %+v", res)
	}
	if m := res.Results[0].Matches[0]; m.File != "fw.tf" || m.Line != 1 {
		t.Errorf("match: %+v", m)
	}
	must(t, "repos.grep", map[string]any{"paths": []string{one}, "text": "OTHER", "ignoreCase": true}, &res)
	if len(res.Results) != 1 {
		t.Errorf("case-insensitive grep: %+v", res)
	}
	must(t, "repos.grep", map[string]any{"paths": []string{one, two}, "text": "absent-text"}, &res)
	if len(res.Results) != 0 {
		t.Errorf("no match must give no results: %+v", res)
	}
}

func TestBlockHistory(t *testing.T) {
	dir, _ := newRepo(t)
	write(t, dir, "main.tf", "resource \"x\" \"a\" {\n  name = \"a\"\n}\n\nresource \"x\" \"b\" {\n  name = \"b\"\n  tags = {\n    k = \"v\"\n  }\n}\n")
	git(t, dir, "add", "main.tf")
	git(t, dir, "commit", "-q", "-m", "add a and b")
	write(t, dir, "main.tf", "resource \"x\" \"a\" {\n  name = \"a2\"\n}\n\nresource \"x\" \"b\" {\n  name = \"b\"\n  tags = {\n    k = \"v\"\n  }\n}\n")
	git(t, dir, "commit", "-q", "-am", "rename a")
	write(t, dir, "main.tf", "resource \"x\" \"a\" {\n  name = \"a2\"\n}\n\nresource \"x\" \"b\" {\n  name = \"b\"\n  tags = {\n    k = \"v2\"\n  }\n}\n")
	git(t, dir, "commit", "-q", "-am", "retag b")

	var out struct {
		Commits []struct{ Subject string } `json:"commits"`
		Start   int                        `json:"start"`
		End     int                        `json:"end"`
	}
	must(t, "repo.blockHistory", map[string]any{"path": dir, "file": "main.tf", "line": 5}, &out)
	if out.End != 10 {
		t.Errorf("block b ends at %d, want 10 (nested braces)", out.End)
	}
	if len(out.Commits) != 2 || out.Commits[0].Subject != "retag b" || out.Commits[1].Subject != "add a and b" {
		t.Errorf("history of b: %+v", out.Commits)
	}
	must(t, "repo.blockHistory", map[string]any{"path": dir, "file": "main.tf", "line": 1}, &out)
	if out.End != 3 || len(out.Commits) != 2 || out.Commits[0].Subject != "rename a" {
		t.Errorf("history of a: end %d, %+v", out.End, out.Commits)
	}
	if _, err := call(t, "repo.blockHistory", map[string]any{"path": dir, "file": "../x", "line": 1}); err == nil {
		t.Error("a path outside the repository must be refused")
	}
}
