package gitx

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestParseStatusV2(t *testing.T) {
	out := "# branch.oid 1234\n" +
		"# branch.head main\n" +
		"# branch.upstream origin/main\n" +
		"# branch.ab +2 -1\n" +
		"1 .M N... 100644 100644 100644 aaa bbb a.txt\n" +
		"u UU N... 100644 100644 100644 100644 aaa bbb ccc c.txt\n" +
		"? new.txt\n"
	got := parseStatusV2(out)
	want := Info{Branch: "main", Upstream: true, Ahead: 2, Behind: 1, Changes: 3, Conflicts: true}
	if got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}

	// An upstream without branch.ab: deleted on the remote.
	got = parseStatusV2("# branch.oid 1234\n# branch.head topic\n# branch.upstream origin/topic\n")
	if !got.UpstreamGone || got.Upstream || got.Sync() != "✗ gone" {
		t.Fatalf("gone: got %+v (%q)", got, got.Sync())
	}

	got = parseStatusV2("# branch.oid 1234\n# branch.head (detached)\n")
	if !got.Detached || got.Upstream || got.Changes != 0 {
		t.Fatalf("detached: got %+v", got)
	}
}

func TestInfoSync(t *testing.T) {
	cases := []struct {
		in   Info
		want string
	}{
		{Info{Upstream: true}, ""},
		{Info{Upstream: true, Ahead: 1, Behind: 2, Changes: 3}, "↑1 ↓2 ~3"},
		{Info{}, "∅"},
		{Info{UpstreamGone: true, Changes: 2}, "✗ gone ~2"},
		{Info{Detached: true, Changes: 1}, "~1"},
	}
	for _, c := range cases {
		if got := c.in.Sync(); got != c.want {
			t.Errorf("%+v: got %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseFiles(t *testing.T) {
	out := " M a.txt\x00R  new name.txt\x00old name.txt\x00?? dir/u.txt\x00UU c.txt\x00"
	got := parseFiles(out)
	want := []File{
		{Path: "a.txt", X: ' ', Y: 'M'},
		{Path: "new name.txt", Orig: "old name.txt", X: 'R', Y: ' '},
		{Path: "dir/u.txt", X: '?', Y: '?'},
		{Path: "c.txt", X: 'U', Y: 'U'},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
	if !got[2].Untracked() || got[2].Staged() {
		t.Error("untracked file flags")
	}
	if !got[1].Staged() || got[1].Unstaged() {
		t.Error("renamed file flags")
	}
	if !got[3].Conflict() {
		t.Error("conflict flag")
	}
}

func TestParseLog(t *testing.T) {
	out := "*   \x1eh1\x1fs1\x1fAnn\x1f2 days ago\x1fsubject one\x1fHEAD -> main\x1fp1 p2\n" +
		"|\\  \n" +
		"| * \x1eh2\x1fs2\x1fBob\x1f3 days ago\x1fsubject two\x1f\x1fp3\n" +
		"* \x1eh3\x1fs3\x1fBob\x1f4 days ago\x1finitial\x1f\x1f\n" +
		"garbage\n"
	got := parseLog(out)
	want := []Commit{
		{Hash: "h1", Short: "s1", Author: "Ann", Rel: "2 days ago", Subject: "subject one", Refs: "HEAD -> main", Merge: true, Parents: []string{"p1", "p2"}},
		{Hash: "h2", Short: "s2", Author: "Bob", Rel: "3 days ago", Subject: "subject two", Parents: []string{"p3"}},
		{Hash: "h3", Short: "s3", Author: "Bob", Rel: "4 days ago", Subject: "initial", Root: true, Parents: []string{}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v\nwant %+v", got, want)
	}
}

func TestParseBranches(t *testing.T) {
	out := "*\x1fmain\x1forigin/main\x1f[ahead 1]\x1f1 day ago\x1fs\n" +
		" \x1ffeature\x1f\x1f\x1f2 days ago\x1fs\n"
	got := parseBranches(out, false)
	if len(got) != 2 || !got[0].Current || got[0].Track != "[ahead 1]" || got[1].Current {
		t.Fatalf("local: %+v", got)
	}

	remote := " \x1forigin/HEAD\x1f\x1f\x1fx\x1fs\n" +
		" \x1forigin\x1f\x1f\x1fx\x1fs\n" +
		" \x1forigin/main\x1f\x1f\x1fx\x1fs\n"
	got = parseBranches(remote, true)
	if len(got) != 1 || got[0].Name != "origin/main" || !got[0].Remote {
		t.Fatalf("remote: %+v", got)
	}
}

func TestParseStashes(t *testing.T) {
	got := parseStashes("stash@{0}\x1fWIP on main: abc\x1f5 minutes ago\n\n")
	want := []Stash{{Ref: "stash@{0}", Msg: "WIP on main: abc", Rel: "5 minutes ago"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
}

func TestSubcommand(t *testing.T) {
	cases := map[string][]string{
		"diff":   {"-c", "color.ui=always", "diff", "--cached"},
		"status": {"status", "-sb"},
		"log":    {"-C", "/x", "log"},
		"git":    {"-c", "a=b"},
	}
	for want, args := range cases {
		if got := subcommand(args); got != want {
			t.Errorf("subcommand(%q) = %q, want %q", args, got, want)
		}
	}
}

func TestSequencerState(t *testing.T) {
	dir := t.TempDir()
	todo := filepath.Join(dir, "todo")
	if got := sequencerState(todo); got != StateNone {
		t.Fatalf("missing todo: %v", got)
	}
	write := func(s string) {
		if err := os.WriteFile(todo, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("# comment\n\npick abc subject\n")
	if got := sequencerState(todo); got != StateCherryPicking {
		t.Errorf("pick: %v", got)
	}
	write("revert abc subject\n")
	if got := sequencerState(todo); got != StateReverting {
		t.Errorf("revert: %v", got)
	}
}

func TestRemoteHost(t *testing.T) {
	cases := map[string]string{
		"git@gitea.devops.example.com:Example-GCP/org-core-dns.git":      "gitea.devops.example.com",
		"ssh://git@forgejo.int.example.com/Ansible/role.git":             "forgejo.int.example.com",
		"ssh://git@Host.Example:2222/x.git":                              "host.example",
		"https://github.com/GoogleCloudPlatform/cloud-foundation-fabric": "github.com",
		"https://user:pw@gitlab.com/a/b.git":                             "gitlab.com",
		"/srv/git/x.git":                                                 "",
		"../other":                                                       "",
		"file:///srv/git/x.git":                                          "",
		"":                                                               "",
	}
	for url, want := range cases {
		if got := RemoteHost(url); got != want {
			t.Errorf("RemoteHost(%q) = %q, want %q", url, got, want)
		}
	}
}

func TestPickRemote(t *testing.T) {
	out := "remote.upstream.url https://a/x\nremote.origin.url git@b:x\n"
	if got := pickRemote(out); got != "git@b:x" {
		t.Errorf("got %q", got)
	}
	if got := pickRemote("remote.upstream.url https://a/x\n"); got != "https://a/x" {
		t.Errorf("fallback: %q", got)
	}
	if got := pickRemote(""); got != "" {
		t.Errorf("empty: %q", got)
	}
}

func TestLimitOutput(t *testing.T) {
	if got := limitOutput("a\nb\n"); got != "a\nb\n" {
		t.Errorf("short output changed: %q", got)
	}
	lines := strings.Repeat("x\n", maxShownLines+10)
	got := limitOutput(lines)
	if n := strings.Count(got, "x"); n != maxShownLines || !strings.HasSuffix(got, "… (truncated)") {
		t.Errorf("lines: %d kept, ends %q", n, got[len(got)-20:])
	}
	// One huge line is cut at a character boundary.
	long := strings.Repeat("ż", maxShownBytes)
	got = limitOutput(long)
	if len(got) > maxShownBytes+40 || !utf8.ValidString(got) || !strings.HasSuffix(got, "… (truncated)") {
		t.Errorf("long line: %d bytes, valid %v", len(got), utf8.ValidString(got))
	}
}
