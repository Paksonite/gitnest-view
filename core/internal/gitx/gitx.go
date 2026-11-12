// Package gitx wraps the git CLI. Shelling out keeps behaviour
// identical to what the user's own git config would do.
package gitx

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Toplevel returns the repository root containing dir.
func Toplevel(ctx context.Context, dir string) (string, error) {
	out, err := run(ctx, kRead, dir, nil, "rev-parse", "--show-toplevel")
	return strings.TrimSpace(out), err
}

// ---------------------------------------------------------------- repo info

type Info struct {
	Branch   string
	Detached bool
	Upstream bool
	// UpstreamGone: the branch tracks an upstream that no longer exists
	// (deleted on the remote and pruned); Upstream is false then.
	UpstreamGone bool
	Ahead        int
	Behind       int
	Changes      int
	Conflicts    bool
	LastUnix     int64
	LastRel      string
	State        State
	RemoteURL    string // origin's URL, or the first remote's; empty without remotes
	Stashes      int
}

func GetInfo(ctx context.Context, dir string) (Info, error) {
	out, err := run(ctx, kRead, dir, nil, "status", "--porcelain=v2", "--branch")
	if err != nil {
		return Info{}, err
	}
	in := parseStatusV2(out)
	if o, err := run(ctx, kRead, dir, nil, "log", "-1", "--format=%ct%x1f%cr"); err == nil {
		parts := strings.SplitN(strings.TrimSpace(o), "\x1f", 2)
		if len(parts) == 2 {
			in.LastUnix, _ = strconv.ParseInt(parts[0], 10, 64)
			in.LastRel = parts[1]
		}
	}
	// State and remote come from files in the git dir when it can be found
	// directly: two git processes per repository instead of four.
	if gitDir, common, ok := gitDirs(dir); ok {
		in.State = stateIn(gitDir)
		in.RemoteURL = remoteFromConfig(filepath.Join(common, "config"))
		in.Stashes = fileLines(filepath.Join(common, "logs", "refs", "stash"))
		return in, nil
	}
	if o, err := run(ctx, kRead, dir, nil, "stash", "list"); err == nil {
		in.Stashes = countLines(o)
	}
	in.State, _ = GetState(ctx, dir)
	if o, err := run(ctx, kRead, dir, nil, "config", "--get-regexp", `^remote\..*\.url$`); err == nil {
		in.RemoteURL = pickRemote(o)
	}
	return in, nil
}

func parseStatusV2(out string) Info {
	var in Info
	for _, l := range strings.Split(out, "\n") {
		switch {
		case l == "":
		case strings.HasPrefix(l, "# branch.head "):
			in.Branch = strings.TrimPrefix(l, "# branch.head ")
			in.Detached = in.Branch == "(detached)"
		case strings.HasPrefix(l, "# branch.upstream "):
			in.UpstreamGone = true // until branch.ab shows it exists
		case strings.HasPrefix(l, "# branch.ab "):
			in.Upstream, in.UpstreamGone = true, false
			fmt.Sscanf(strings.TrimPrefix(l, "# branch.ab "), "+%d -%d", &in.Ahead, &in.Behind)
		case strings.HasPrefix(l, "#"):
		default:
			in.Changes++
			if strings.HasPrefix(l, "u ") {
				in.Conflicts = true
			}
		}
	}
	return in
}

// gitDirs finds the git dir of the repository rooted at dir, and the common
// dir that holds its config (they differ for linked worktrees), without
// running git. ok is false when dir has no .git entry it understands.
func gitDirs(dir string) (gitDir, common string, ok bool) {
	dotgit := filepath.Join(dir, ".git")
	st, err := os.Stat(dotgit)
	if err != nil {
		return "", "", false
	}
	if st.IsDir() {
		return dotgit, dotgit, true
	}
	b, err := os.ReadFile(dotgit)
	if err != nil {
		return "", "", false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	gd, found := strings.CutPrefix(strings.TrimSpace(line), "gitdir:")
	if !found {
		return "", "", false
	}
	gitDir = strings.TrimSpace(gd)
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(dir, gitDir)
	}
	common = gitDir
	if c, err := os.ReadFile(filepath.Join(gitDir, "commondir")); err == nil {
		common = strings.TrimSpace(string(c))
		if !filepath.IsAbs(common) {
			common = filepath.Join(gitDir, common)
		}
	}
	return gitDir, filepath.Clean(common), true
}

// remoteFromConfig reads remote URLs from a git config file: origin's, or
// the first one. Includes are not followed; this only feeds display labels.
func remoteFromConfig(path string) string {
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	var remote, first string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "[") {
			remote = ""
			if name, ok := strings.CutPrefix(line, "[remote \""); ok {
				remote, _, _ = strings.Cut(name, "\"")
			}
			continue
		}
		key, val, ok := strings.Cut(line, "=")
		if remote == "" || !ok || !strings.EqualFold(strings.TrimSpace(key), "url") {
			continue
		}
		val = strings.Trim(strings.TrimSpace(val), "\"")
		if remote == "origin" {
			return val
		}
		if first == "" {
			first = val
		}
	}
	return first
}

// pickRemote chooses origin's URL from `git config --get-regexp remote.*.url`
// output, falling back to the first remote listed.
func pickRemote(out string) string {
	first := ""
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		key, url, ok := strings.Cut(l, " ")
		if !ok {
			continue
		}
		if key == "remote.origin.url" {
			return url
		}
		if first == "" {
			first = url
		}
	}
	return first
}

// RemoteHost extracts the host from a git remote URL: https://host/x,
// ssh://user@host:port/x, user@host:x (scp-like). Local paths give "".
func RemoteHost(url string) string {
	if i := strings.Index(url, "://"); i >= 0 {
		rest := url[i+3:]
		if url[:i] == "file" {
			return ""
		}
		rest, _, _ = strings.Cut(rest, "/")
		if j := strings.LastIndex(rest, "@"); j >= 0 {
			rest = rest[j+1:]
		}
		host, _, _ := strings.Cut(rest, ":")
		return strings.ToLower(host)
	}
	if strings.HasPrefix(url, "/") || strings.HasPrefix(url, ".") {
		return ""
	}
	before, _, ok := strings.Cut(url, ":")
	if !ok || strings.Contains(before, "/") {
		return ""
	}
	if j := strings.LastIndex(before, "@"); j >= 0 {
		before = before[j+1:]
	}
	return strings.ToLower(before)
}

// credentials matches the password or token in a URL's user info:
// https://user:token@host.
var credentials = regexp.MustCompile(`([a-zA-Z][a-zA-Z0-9+.-]*://[^/\s:@]+):[^/\s@]+@`)

// Redact hides passwords and tokens in URLs anywhere in s (a remote URL,
// git's output), so they never reach the screen: https://user:token@host
// becomes https://user:***@host.
func Redact(s string) string { return credentials.ReplaceAllString(s, "$1:***@") }

// WebURL guesses the web page of a remote: https://host/owner/repo for
// https, ssh:// and scp-like (git@host:owner/repo.git) remotes. Local paths
// and empty URLs give "".
func WebURL(url string) string {
	host := RemoteHost(url)
	if host == "" {
		return ""
	}
	path := url
	if i := strings.Index(url, "://"); i >= 0 {
		_, path, _ = strings.Cut(url[i+3:], "/")
	} else {
		_, path, _ = strings.Cut(url, ":")
	}
	path = strings.TrimSuffix(strings.Trim(path, "/"), ".git")
	if path == "" {
		return "https://" + host
	}
	return "https://" + host + "/" + path
}

// RemoteGroup splits a remote URL into the host and the owner path, without
// the repository's own name: git@github.com:ann/api.git gives
// [github.com ann], https://gitlab.com/platform/infra/dns gives
// [gitlab.com platform infra]. Local paths and empty URLs give nil.
func RemoteGroup(url string) []string {
	host := RemoteHost(url)
	if host == "" {
		return nil
	}
	path := url
	if i := strings.Index(url, "://"); i >= 0 {
		_, path, _ = strings.Cut(url[i+3:], "/")
	} else {
		_, path, _ = strings.Cut(url, ":")
	}
	parts := []string{host}
	segs := strings.Split(strings.Trim(path, "/"), "/")
	for _, s := range segs[:max(0, len(segs)-1)] { // the last one is the repository
		if s != "" && s != "~" {
			parts = append(parts, s)
		}
	}
	return parts
}

// Sync returns a compact plain-text summary like "↑1 ↓2 ~3".
func (i Info) Sync() string {
	var p []string
	if i.Upstream {
		if i.Ahead > 0 {
			p = append(p, fmt.Sprintf("↑%d", i.Ahead))
		}
		if i.Behind > 0 {
			p = append(p, fmt.Sprintf("↓%d", i.Behind))
		}
	} else if i.UpstreamGone {
		p = append(p, "✗ gone")
	} else if !i.Detached {
		p = append(p, "∅")
	}
	if i.Changes > 0 {
		p = append(p, fmt.Sprintf("~%d", i.Changes))
	}
	return strings.Join(p, " ")
}

// ------------------------------------------------------------------- files

type File struct {
	Path, Orig string
	X, Y       byte
}

func (f File) Untracked() bool { return f.X == '?' }
func (f File) Staged() bool    { return f.X != ' ' && f.X != '?' }
func (f File) Unstaged() bool  { return f.Y != ' ' }
func (f File) Conflict() bool {
	return f.X == 'U' || f.Y == 'U' || (f.X == 'A' && f.Y == 'A') || (f.X == 'D' && f.Y == 'D')
}

func Files(ctx context.Context, dir string) ([]File, error) {
	out, err := run(ctx, kRead, dir, nil, "status", "--porcelain=v1", "-z", "-uall")
	if err != nil {
		return nil, err
	}
	files := parseFiles(out)
	// git lists untracked files after tracked ones; sort by path so staging
	// a new file doesn't move it.
	sort.SliceStable(files, func(i, j int) bool { return files[i].Path < files[j].Path })
	return files, nil
}

func parseFiles(out string) []File {
	parts := strings.Split(out, "\x00")
	var files []File
	for i := 0; i < len(parts); i++ {
		p := parts[i]
		if len(p) < 4 {
			continue
		}
		f := File{X: p[0], Y: p[1], Path: p[3:]}
		if (f.X == 'R' || f.X == 'C') && i+1 < len(parts) {
			f.Orig = parts[i+1]
			i++
		}
		files = append(files, f)
	}
	return files
}

func DiffFile(ctx context.Context, dir string, f File) string {
	var b strings.Builder
	if f.Untracked() {
		out, _ := run(ctx, kRead, dir, nil, colored("diff", "--no-index", "--", "/dev/null", f.Path)...)
		return limitOutput(out)
	}
	if f.Staged() {
		if o, _ := run(ctx, kRead, dir, nil, colored("diff", "--cached", "--", f.Path)...); o != "" {
			b.WriteString("── staged ──\n" + o)
		}
	}
	if f.Unstaged() {
		if o, _ := run(ctx, kRead, dir, nil, colored("diff", "--", f.Path)...); o != "" {
			b.WriteString("── unstaged ──\n" + o)
		}
	}
	if b.Len() == 0 {
		return "(no diff)"
	}
	return limitOutput(b.String())
}

// DiffDir shows the staged and unstaged changes below directory path, and
// lists its untracked files.
func DiffDir(ctx context.Context, dir, path string, untracked []string) string {
	var b strings.Builder
	if o, _ := run(ctx, kRead, dir, nil, colored("diff", "--cached", "--", path)...); o != "" {
		b.WriteString("── staged ──\n" + o)
	}
	if o, _ := run(ctx, kRead, dir, nil, colored("diff", "--", path)...); o != "" {
		b.WriteString("── unstaged ──\n" + o)
	}
	if len(untracked) > 0 {
		b.WriteString("── untracked ──\n" + strings.Join(untracked, "\n") + "\n")
	}
	if b.Len() == 0 {
		return "(no diff)"
	}
	return limitOutput(b.String())
}

// Stage adds a file or a whole directory to the index.
func Stage(ctx context.Context, dir, path string) error {
	_, err := run(ctx, kWrite, dir, nil, "add", "--", path)
	return err
}

func Unstage(ctx context.Context, dir, path string) error {
	_, err := run(ctx, kWrite, dir, nil, "restore", "--staged", "--", path)
	if err != nil { // e.g. repository without commits
		_, err = run(ctx, kWrite, dir, nil, "rm", "--cached", "-q", "--", path)
	}
	return err
}

func StageAll(ctx context.Context, dir string) error {
	_, err := run(ctx, kWrite, dir, nil, "add", "-A")
	return err
}

func UnstageAll(ctx context.Context, dir string) error {
	_, err := run(ctx, kWrite, dir, nil, "reset", "-q")
	return err
}

func Discard(ctx context.Context, dir string, f File) error {
	var err error
	switch {
	case f.Untracked():
		_, err = run(ctx, kWrite, dir, nil, "clean", "-fd", "--", f.Path)
	case f.X == 'A':
		_, err = run(ctx, kWrite, dir, nil, "rm", "-f", "-q", "--", f.Path)
	default:
		paths := []string{f.Path}
		if f.Orig != "" { // a rename: bring the old name back too
			paths = append(paths, f.Orig)
		}
		_, err = run(ctx, kWrite, dir, nil, append([]string{"restore", "--source=HEAD", "--staged", "--worktree", "--"}, paths...)...)
	}
	return err
}

// ---------------------------------------------------------------- commits

type Commit struct {
	Hash, Short, Author, Rel, Subject, Refs string
	Merge                                   bool     // more than one parent
	Root                                    bool     // no parent
	Parents                                 []string // full hashes, first parent first
}

// CommitKind classifies a commit for its icon.
type CommitKind int

const (
	KindCommit CommitKind = iota
	KindMerge
	KindRevert
	KindFixup // fixup!, squash! or amend! commit waiting for an autosquash
	KindRoot
)

// Kind tells what sort of change the commit is.
func (c Commit) Kind() CommitKind {
	switch {
	case c.Merge:
		return KindMerge
	case strings.HasPrefix(c.Subject, "Revert \""):
		return KindRevert
	case strings.HasPrefix(c.Subject, "fixup! "), strings.HasPrefix(c.Subject, "squash! "), strings.HasPrefix(c.Subject, "amend! "):
		return KindFixup
	case c.Root:
		return KindRoot
	}
	return KindCommit
}

// logFormat starts every commit line with a record separator, so anything
// before it (e.g. a --graph drawing) can be split off.
const logFormat = "--format=%x1e%H%x1f%h%x1f%an%x1f%ar%x1f%s%x1f%D%x1f%P"

func Log(ctx context.Context, dir string, n int) ([]Commit, error) {
	// Topological order keeps a branch's commits together, which the
	// commit graph needs.
	out, err := run(ctx, kRead, dir, nil, "log", "--topo-order", "-n", strconv.Itoa(n), logFormat)
	if err != nil {
		return nil, err
	}
	return parseLog(out), nil
}

// parseLog reads logFormat output; lines without a commit are skipped.
func parseLog(out string) []Commit {
	var cs []Commit
	for _, l := range strings.Split(out, "\n") {
		_, rest, ok := strings.Cut(l, "\x1e")
		if !ok {
			continue
		}
		f := strings.Split(rest, "\x1f")
		if len(f) < 7 {
			continue
		}
		parents := strings.Fields(f[6])
		cs = append(cs, Commit{Hash: f[0], Short: f[1], Author: f[2], Rel: f[3],
			Subject: f[4], Refs: f[5], Merge: len(parents) > 1, Root: len(parents) == 0, Parents: parents})
	}
	return cs
}

// ------------------------------------------------------------------ reflog

// RefEntry is one entry of HEAD's reflog: a step that moved HEAD.
type RefEntry struct {
	Hash, Short string
	Selector    string // HEAD@{3}
	Action      string // "commit (amend)", "rebase (finish)", "checkout", "merge feature"…
	Message     string // the rest: commit subject, "moving from a to b"…
	Rel         string
}

// RefKind groups reflog actions for their icons.
type RefKind int

const (
	RefOther RefKind = iota
	RefCommit
	RefAmend
	RefMerge
	RefRebase
	RefReset
	RefCheckout
	RefPull
	RefCherryPick
	RefRevert
	RefInitial
)

// Kind classifies the entry by its action.
func (e RefEntry) Kind() RefKind {
	word, _, _ := strings.Cut(e.Action, " ")
	switch {
	case e.Action == "commit (amend)":
		return RefAmend
	case e.Action == "commit (initial)" || word == "clone":
		return RefInitial
	case e.Action == "commit (merge)" || word == "merge":
		return RefMerge
	case word == "commit":
		return RefCommit
	case word == "rebase" || strings.HasPrefix(e.Action, "pull --rebase"):
		return RefRebase
	case word == "reset":
		return RefReset
	case word == "checkout" || word == "switch":
		return RefCheckout
	case word == "pull":
		return RefPull
	case word == "cherry-pick":
		return RefCherryPick
	case word == "revert":
		return RefRevert
	}
	return RefOther
}

const reflogFormat = "--format=%H%x1f%h%x1f%gd%x1f%gs%x1f%ar"

// Reflog lists the latest n moves of HEAD, newest first.
func Reflog(ctx context.Context, dir string, n int) ([]RefEntry, error) {
	out, err := run(ctx, kRead, dir, nil, "reflog", "-n", strconv.Itoa(n), reflogFormat)
	if err != nil {
		return nil, err
	}
	return parseReflog(out), nil
}

func parseReflog(out string) []RefEntry {
	var es []RefEntry
	for _, l := range strings.Split(out, "\n") {
		f := strings.Split(l, "\x1f")
		if len(f) < 5 {
			continue
		}
		action, msg, ok := strings.Cut(f[3], ": ")
		if !ok {
			action, msg = strings.TrimSuffix(f[3], ":"), ""
		}
		es = append(es, RefEntry{Hash: f[0], Short: f[1], Selector: f[2], Action: action, Message: msg, Rel: f[4]})
	}
	return es
}

// ReflogChanges shows what a reflog step changed: the commits only in the
// state before it (<) and only in the state after it (>), as a graph, and
// the files that differ. prev is the entry before (older); empty for the
// oldest entry.
func ReflogChanges(ctx context.Context, dir string, e RefEntry, prev string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s  %s: %s  (%s)\n\n", e.Selector, e.Action, e.Message, e.Rel)
	if prev == "" || prev == e.Hash {
		b.WriteString("HEAD stayed on the same commit.\n\n")
		out, _ := run(ctx, kRead, dir, nil, colored("log", "--graph", "--oneline", "--decorate", "-n", "20", e.Hash)...)
		b.WriteString(out)
		return limitOutput(b.String())
	}
	graph, _ := run(ctx, kRead, dir, nil, colored("log", "--graph", "--oneline", "--decorate", "--left-right", "--boundary",
		"-n", "200", prev+"..."+e.Hash)...)
	b.WriteString("< only before   > only after   - shared base\n\n")
	b.WriteString(graph)
	if stat, _ := run(ctx, kRead, dir, nil, colored("diff", "--stat", prev, e.Hash)...); stat != "" {
		b.WriteString("\n" + stat)
	}
	return limitOutput(b.String())
}

// ResetHard moves the current branch (and the working tree) to rev, after
// recording an undo point. It refuses with uncommitted changes to tracked
// files or while an operation is in progress.
func ResetHard(ctx context.Context, dir, rev, label string) error {
	if err := requireNoOperation(ctx, dir); err != nil {
		return err
	}
	dirty, err := run(ctx, kRead, dir, nil, "status", "--porcelain", "--untracked-files=no")
	if err != nil {
		return err
	}
	if strings.TrimSpace(dirty) != "" {
		return errors.New("commit or stash your changes before resetting")
	}
	if err := savePoint(ctx, dir, label); err != nil {
		return err
	}
	_, err = run(ctx, kWrite, dir, nil, "reset", "--hard", "-q", rev)
	return err
}

// CheckoutDetached checks out rev without a branch (detached HEAD).
func CheckoutDetached(ctx context.Context, dir, rev string) error {
	_, err := run(ctx, kWrite, dir, nil, "checkout", "--detach", rev)
	return err
}

// MainBranch names the repository's main line: the remote's default branch
// (origin/HEAD), else a local main or master. Empty when there is none.
func MainBranch(ctx context.Context, dir string) string {
	if out, err := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "--short", "refs/remotes/origin/HEAD"); err == nil {
		return strings.TrimSpace(out)
	}
	for _, b := range []string{"main", "master"} {
		if _, err := run(ctx, kRead, dir, nil, "show-ref", "--verify", "-q", "refs/heads/"+b); err == nil {
			return b
		}
	}
	return ""
}

// NotOnMain returns the commits of HEAD that the main line doesn't contain
// (at most n), or nil when there is no main line.
func NotOnMain(ctx context.Context, dir string, n int) map[string]bool {
	main := MainBranch(ctx, dir)
	if main == "" {
		return nil
	}
	out, err := run(ctx, kRead, dir, nil, "rev-list", "-n", strconv.Itoa(n), "HEAD", "^"+main)
	if err != nil {
		return nil
	}
	m := map[string]bool{}
	for _, h := range strings.Fields(out) {
		m[h] = true
	}
	return m
}

// Unpushed returns the set of commit hashes not on the upstream (nil if no upstream).
func Unpushed(ctx context.Context, dir string) map[string]bool {
	out, err := run(ctx, kRead, dir, nil, "rev-list", "@{u}..HEAD")
	if err != nil {
		return nil
	}
	m := map[string]bool{}
	for _, h := range strings.Fields(out) {
		m[h] = true
	}
	return m
}

func Show(ctx context.Context, dir, hash string) string {
	out, _ := run(ctx, kRead, dir, nil, colored("show", "--stat", "--patch", hash)...)
	return limitOutput(out)
}

func CommitMsg(ctx context.Context, dir, msg string) error {
	msg = CleanMessage(msg)
	if msg == "" {
		return errors.New("commit: the message is empty")
	}
	_, err := run(ctx, kWrite, dir, nil, "commit", "-m", msg)
	return err
}

// Message returns the full commit message of rev.
func Message(ctx context.Context, dir, rev string) (string, error) {
	return run(ctx, kRead, dir, nil, "log", "-1", "--format=%B", rev)
}

// ---------------------------------------------------------------- branches

type Branch struct {
	Name, Upstream, Track, Rel, Subject string
	Current, Remote                     bool
}

// for-each-ref spells the unit separator %1f (git log uses %x1f).
const branchFormat = "%(HEAD)%1f%(refname:short)%1f%(upstream:short)%1f%(upstream:track)%1f%(committerdate:relative)%1f%(subject)"

// AheadBehind reads how many commits a local branch has that its upstream
// lacks, and the other way round, from Track ("[ahead 1, behind 2]").
// Gone reports an upstream that was deleted.
func (b Branch) AheadBehind() (ahead, behind int, gone bool) {
	track := strings.Trim(b.Track, "[]")
	if track == "gone" {
		return 0, 0, true
	}
	for _, part := range strings.Split(track, ", ") {
		if n, ok := strings.CutPrefix(part, "ahead "); ok {
			ahead, _ = strconv.Atoi(n)
		} else if n, ok := strings.CutPrefix(part, "behind "); ok {
			behind, _ = strconv.Atoi(n)
		}
	}
	return ahead, behind, false
}

func parseBranches(out string, remote bool) []Branch {
	var bs []Branch
	for _, l := range strings.Split(out, "\n") {
		f := strings.Split(l, "\x1f")
		if len(f) < 6 {
			continue
		}
		if remote && (!strings.Contains(f[1], "/") || strings.HasSuffix(f[1], "/HEAD")) {
			continue
		}
		bs = append(bs, Branch{Current: strings.TrimSpace(f[0]) == "*", Name: f[1], Upstream: f[2],
			Track: f[3], Rel: f[4], Subject: f[5], Remote: remote})
	}
	return bs
}

func Branches(ctx context.Context, dir string) (local, remote []Branch, err error) {
	out, err := run(ctx, kRead, dir, nil, "for-each-ref", "--sort=-committerdate", "--format="+branchFormat, "refs/heads")
	if err != nil {
		return nil, nil, err
	}
	local = parseBranches(out, false)
	if out, err = run(ctx, kRead, dir, nil, "for-each-ref", "--sort=-committerdate", "--format="+branchFormat, "refs/remotes"); err == nil {
		remote = parseBranches(out, true)
	}
	return local, remote, nil
}

func BranchLog(ctx context.Context, dir, name string) string {
	out, _ := run(ctx, kRead, dir, nil, colored("log", "--graph", "--oneline", "--decorate", "-n", "60", name)...)
	return out
}

// Checkout switches to branch b. For a remote branch it checks out the local
// branch of the same name, creating it to track the remote one if needed.
func Checkout(ctx context.Context, dir string, b Branch) error {
	if !b.Remote {
		_, err := run(ctx, kWrite, dir, nil, "checkout", b.Name)
		return err
	}
	_, local, ok := strings.Cut(b.Name, "/")
	if !ok {
		return errors.New("not a remote branch: " + b.Name)
	}
	if _, err := run(ctx, kRead, dir, nil, "show-ref", "--verify", "-q", "refs/heads/"+local); err == nil {
		_, err = run(ctx, kWrite, dir, nil, "checkout", local)
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "checkout", "--track", b.Name)
	return err
}

// SetUpstream makes local branch track upstream (e.g. "origin/main").
func SetUpstream(ctx context.Context, dir, branch, upstream string) error {
	_, err := run(ctx, kWrite, dir, nil, "branch", "--set-upstream-to="+upstream, branch)
	return err
}

// UnsetUpstream removes the tracking configuration of a local branch.
func UnsetUpstream(ctx context.Context, dir, branch string) error {
	_, err := run(ctx, kWrite, dir, nil, "branch", "--unset-upstream", branch)
	return err
}

// FastForward updates local branch b to its upstream without checking it
// out. The checked-out branch is pulled with --ff-only instead. Branches that
// have diverged are left alone (git refuses the non-fast-forward update).
func FastForward(ctx context.Context, dir string, b Branch) error {
	if b.Remote {
		return errors.New("fast-forward works on local branches")
	}
	if b.Upstream == "" {
		return fmt.Errorf("%s has no upstream (set one with u)", b.Name)
	}
	if b.Current {
		return Pull(ctx, dir, false)
	}
	remote, err := run(ctx, kRead, dir, nil, "config", "--get", "branch."+b.Name+".remote")
	if err != nil {
		return err
	}
	merge, err := run(ctx, kRead, dir, nil, "config", "--get", "branch."+b.Name+".merge")
	if err != nil {
		return err
	}
	_, err = run(ctx, kNet, dir, nil, "fetch", "-q", strings.TrimSpace(remote),
		strings.TrimSpace(merge)+":refs/heads/"+b.Name)
	return err
}

func NewBranch(ctx context.Context, dir, name, base string) error {
	args := []string{"checkout", "-b", name}
	if base != "" {
		args = append(args, base)
	}
	_, err := run(ctx, kWrite, dir, nil, args...)
	return err
}

func DeleteBranch(ctx context.Context, dir, name string, force bool) error {
	flag := "-d"
	if force {
		flag = "-D"
	}
	_, err := run(ctx, kWrite, dir, nil, "branch", flag, name)
	return err
}

func DeleteRemoteBranch(ctx context.Context, dir, name string) error {
	i := strings.Index(name, "/")
	if i < 0 {
		return errors.New("not a remote branch: " + name)
	}
	_, err := run(ctx, kNet, dir, nil, "push", name[:i], "--delete", name[i+1:])
	return err
}

func RenameBranch(ctx context.Context, dir, old, name string) error {
	_, err := run(ctx, kWrite, dir, nil, "branch", "-m", old, name)
	return err
}

// -------------------------------------------------------------------- tags

type Tag struct {
	Name, Short, Subject, Rel string
	Annotated                 bool
}

const tagFormat = "%(refname:short)%1f%(objectname:short)%1f%(contents:subject)%1f%(creatordate:relative)%1f%(objecttype)"

// Tags lists tags, newest first.
func Tags(ctx context.Context, dir string) ([]Tag, error) {
	out, err := run(ctx, kRead, dir, nil, "for-each-ref", "--sort=-creatordate", "--format="+tagFormat, "refs/tags")
	if err != nil {
		return nil, err
	}
	return parseTags(out), nil
}

func parseTags(out string) []Tag {
	var ts []Tag
	for _, l := range strings.Split(out, "\n") {
		f := strings.Split(l, "\x1f")
		if len(f) < 5 {
			continue
		}
		ts = append(ts, Tag{Name: f[0], Short: f[1], Subject: f[2], Rel: f[3], Annotated: f[4] == "tag"})
	}
	return ts
}

// CreateTag tags rev; with a message the tag is annotated.
func CreateTag(ctx context.Context, dir, name, rev, msg string) error {
	args := []string{"tag"}
	if msg != "" {
		args = append(args, "-a", "-m", msg)
	}
	args = append(args, "--", name)
	if rev != "" {
		args = append(args, rev)
	}
	_, err := run(ctx, kWrite, dir, nil, args...)
	return err
}

func DeleteTag(ctx context.Context, dir, name string) error {
	_, err := run(ctx, kWrite, dir, nil, "tag", "-d", "--", name)
	return err
}

// ErrNoRemote is returned by pushes in a repository without remotes.
var ErrNoRemote = errors.New("no remote to push to — add one with: git remote add origin <url>")

// defaultRemote is origin, or the first remote.
func defaultRemote(ctx context.Context, dir string) (string, error) {
	o, err := run(ctx, kRead, dir, nil, "remote")
	if err != nil {
		return "", err
	}
	f := strings.Fields(o)
	for _, r := range f {
		if r == "origin" {
			return r, nil
		}
	}
	if len(f) == 0 {
		return "", ErrNoRemote
	}
	return f[0], nil
}

func PushTag(ctx context.Context, dir, name string) error {
	remote, err := defaultRemote(ctx, dir)
	if err != nil {
		return err
	}
	_, err = run(ctx, kNet, dir, nil, "push", remote, "refs/tags/"+name)
	return err
}

func DeleteRemoteTag(ctx context.Context, dir, name string) error {
	remote, err := defaultRemote(ctx, dir)
	if err != nil {
		return err
	}
	_, err = run(ctx, kNet, dir, nil, "push", remote, "--delete", "refs/tags/"+name)
	return err
}

// TagInfo shows a tag: its annotation (if any) and the tagged commit.
func TagInfo(ctx context.Context, dir, name string) string {
	out, _ := run(ctx, kRead, dir, nil, colored("show", "--stat", "refs/tags/"+name)...)
	return limitOutput(out)
}

// ------------------------------------------------------------ remote sync

func Fetch(ctx context.Context, dir string) error {
	_, err := run(ctx, kNet, dir, nil, "fetch", "--all", "--prune", "-q")
	return err
}

// Pull pulls the current branch: rebasing, or only fast-forwarding.
func Pull(ctx context.Context, dir string, rebase bool) error {
	if rebase {
		return PullWith(ctx, dir, PullRebase)
	}
	return PullWith(ctx, dir, PullFFOnly)
}

// How a pull brings in commits when the branch has diverged from its
// upstream (both sides have commits of their own).
const (
	PullUnset  = ""        // nothing configured: gitnest asks
	PullRebase = "rebase"  // put the local commits on top of the upstream's
	PullMerge  = "merge"   // a merge commit
	PullFFOnly = "ff-only" // refuse; only fast-forwards
)

// PullSetting reads how git is configured to pull the current branch, as
// git itself decides: branch.<name>.rebase, then pull.rebase, then pull.ff.
func PullSetting(ctx context.Context, dir string) string {
	get := func(key string) string {
		out, err := run(ctx, kRead, dir, nil, "config", "--get", key)
		if err != nil {
			return ""
		}
		return strings.ToLower(strings.TrimSpace(out))
	}
	rebase := ""
	if b, err := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "--short", "HEAD"); err == nil {
		rebase = get("branch." + strings.TrimSpace(b) + ".rebase")
	}
	if rebase == "" {
		rebase = get("pull.rebase")
	}
	switch rebase {
	case "true", "merges", "interactive", "i", "m", "yes", "on", "1":
		return PullRebase
	case "false", "no", "off", "0":
		return PullMerge
	}
	switch get("pull.ff") {
	case "only":
		return PullFFOnly
	case "true", "false":
		return PullMerge
	}
	return PullUnset
}

// PullWith pulls the current branch: rebasing (uncommitted changes are put
// aside and back), merging, or only fast-forwarding (PullFFOnly or
// PullUnset).
func PullWith(ctx context.Context, dir, mode string) error {
	args := []string{"pull", "-q"}
	switch mode {
	case PullRebase:
		args = append(args, "--rebase", "--autostash")
	case PullMerge:
		args = append(args, "--no-rebase", "--no-edit", "--autostash")
	default:
		args = append(args, "--ff-only")
	}
	_, err := run(ctx, kNet, dir, nil, args...)
	return err
}

// UpstreamConflicts says which files would conflict when the current
// branch and its upstream are brought together, without touching anything
// (git merge-tree, git 2.38+). checked is false when git can't tell.
func UpstreamConflicts(ctx context.Context, dir string) (files []string, checked bool) {
	out, err := run(ctx, kRead, dir, nil, "merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", "@{upstream}")
	if err == nil {
		return nil, true
	}
	var ge *Error
	if !errors.As(err, &ge) {
		return nil, false
	}
	var ee *exec.ExitError
	if !errors.As(ge.Err, &ee) || ee.ExitCode() != 1 {
		return nil, false // older git, no upstream…
	}
	// Exit 1: conflicts. The tree's id, then the conflicted files.
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for _, l := range lines[1:] {
		if l = strings.TrimSpace(l); l != "" {
			files = append(files, l)
		}
	}
	return files, true
}

// Push pushes the current branch; without an upstream it pushes to origin
// (or the only remote) and sets the upstream.
func Push(ctx context.Context, dir string, force, hasUpstream bool) error {
	args := []string{"push"}
	if force {
		args = append(args, "--force-with-lease")
	}
	if !hasUpstream {
		if _, err := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "HEAD"); err != nil {
			return errors.New("HEAD is detached: check out a branch to push")
		}
		remote, err := defaultRemote(ctx, dir)
		if err != nil {
			return err
		}
		args = append(args, "-u", remote, "HEAD")
	}
	_, err := run(ctx, kNet, dir, nil, args...)
	return err
}

// UpstreamSeenLocally reports whether every commit on the current branch's
// upstream was at some point part of the local branch (per its reflog).
// After rewriting commits that were already pushed this is true, and a
// force push loses nothing; when someone else pushed new commits it is false.
func UpstreamSeenLocally(ctx context.Context, dir string) (bool, error) {
	branch, err := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "--short", "HEAD")
	if err != nil {
		return false, errors.New("not on a branch")
	}
	refl, err := run(ctx, kRead, dir, nil, "log", "-g", "--format=%H", "-n", "500", "refs/heads/"+strings.TrimSpace(branch))
	if err != nil {
		return false, err
	}
	args := []string{"rev-list", "-n", "1", "@{u}", "--not", "HEAD"}
	seen := map[string]bool{}
	for _, h := range strings.Fields(refl) {
		if !seen[h] {
			seen[h] = true
			args = append(args, h)
		}
	}
	out, err := run(ctx, kRead, dir, nil, args...)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(out) == "", nil
}

// PushRejected reports whether err is git refusing a non-fast-forward push.
func PushRejected(err error) bool {
	var ge *Error
	if !errors.As(err, &ge) {
		return false
	}
	return strings.Contains(ge.Output, "non-fast-forward") || strings.Contains(ge.Output, "fetch first") ||
		strings.Contains(ge.Output, "[rejected]")
}

// ------------------------------------------------------------------ stash

type Stash struct{ Ref, Msg, Rel string }

func Stashes(ctx context.Context, dir string) ([]Stash, error) {
	out, err := run(ctx, kRead, dir, nil, "stash", "list", "--format=%gd%x1f%s%x1f%cr")
	if err != nil {
		return nil, err
	}
	return parseStashes(out), nil
}

func parseStashes(out string) []Stash {
	var ss []Stash
	for _, l := range strings.Split(out, "\n") {
		f := strings.Split(l, "\x1f")
		if len(f) >= 3 {
			ss = append(ss, Stash{Ref: f[0], Msg: f[1], Rel: f[2]})
		}
	}
	return ss
}

func StashPush(ctx context.Context, dir, msg string) error {
	args := []string{"stash", "push", "-u"}
	if msg != "" {
		args = append(args, "-m", msg)
	}
	_, err := run(ctx, kWrite, dir, nil, args...)
	return err
}

func StashApply(ctx context.Context, dir, ref string) error {
	_, err := run(ctx, kWrite, dir, nil, "stash", "apply", ref)
	return err
}

func StashPop(ctx context.Context, dir, ref string) error {
	_, err := run(ctx, kWrite, dir, nil, "stash", "pop", ref)
	return err
}

// StashStaged stashes only the staged changes (git 2.35+).
func StashStaged(ctx context.Context, dir, msg string) error {
	args := []string{"stash", "push", "--staged"}
	if msg != "" {
		args = append(args, "-m", msg)
	}
	_, err := run(ctx, kWrite, dir, nil, args...)
	return err
}

// StashBranch creates branch name at the stash's base commit, checks it out
// and applies the stash there (dropping it on success).
func StashBranch(ctx context.Context, dir, name, ref string) error {
	_, err := run(ctx, kWrite, dir, nil, "stash", "branch", name, ref)
	return err
}

func StashDrop(ctx context.Context, dir, ref string) error {
	_, err := run(ctx, kWrite, dir, nil, "stash", "drop", ref)
	return err
}

func StashShow(ctx context.Context, dir, ref string) string {
	out, _ := run(ctx, kRead, dir, nil, colored("stash", "show", "-p", ref)...)
	return limitOutput(out)
}

// ---------------------------------------------------------------- preview

// Details is what the repository list's preview card shows about the
// selected repository, besides its status.
type Details struct {
	Upstream    string          // e.g. origin/main; empty without one
	Tag         string          // the latest tag reachable from HEAD
	Description string          // the first line of prose in the README
	Changes     []string        // git status --short, at most maxChanges lines
	More        int             // changes beyond those
	Commits     []DetailsCommit // the latest commits, newest first
}

type DetailsCommit struct {
	Short, Subject, Author, Refs string
	Unix                         int64
}

const maxChanges = 8

// RepoDetails collects Details with three git processes.
func RepoDetails(ctx context.Context, dir string, commits int) Details {
	var d Details
	if o, err := run(ctx, kRead, dir, nil, "status", "--porcelain=v1", "--branch"); err == nil {
		for _, l := range strings.Split(strings.TrimRight(o, "\n"), "\n") {
			switch {
			case strings.HasPrefix(l, "## "):
				if _, up, ok := strings.Cut(strings.TrimPrefix(l, "## "), "..."); ok {
					d.Upstream, _, _ = strings.Cut(up, " ")
				}
			case l == "":
			case len(d.Changes) < maxChanges:
				d.Changes = append(d.Changes, l)
			default:
				d.More++
			}
		}
	}
	if o, err := run(ctx, kRead, dir, nil, "log", "-n", strconv.Itoa(commits), "--format=%h%x1f%s%x1f%an%x1f%ct%x1f%D"); err == nil {
		for _, l := range strings.Split(strings.TrimSpace(o), "\n") {
			f := strings.Split(l, "\x1f")
			if len(f) < 5 {
				continue
			}
			unix, _ := strconv.ParseInt(f[3], 10, 64)
			d.Commits = append(d.Commits, DetailsCommit{Short: f[0], Subject: f[1], Author: f[2], Unix: unix, Refs: f[4]})
		}
	}
	if o, err := run(ctx, kRead, dir, nil, "describe", "--tags", "--abbrev=0"); err == nil {
		d.Tag = strings.TrimSpace(o)
	}
	d.Description = readmeLine(dir)
	return d
}

// readmeLine is the first line of prose in dir's README: not a heading,
// badge, image, HTML, list or table.
func readmeLine(dir string) string {
	for _, name := range []string{"README.md", "README", "README.markdown", "README.rst", "README.txt", "readme.md"} {
		b, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			continue
		}
		if len(b) > 64<<10 {
			b = b[:64<<10]
		}
		inCode := false
		for _, l := range strings.Split(string(b), "\n") {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "```") {
				inCode = !inCode
				continue
			}
			if inCode || l == "" || strings.ContainsAny(l[:1], "#![<|>-=*_:.`") || strings.HasPrefix(l, "+") {
				continue
			}
			return l
		}
		return ""
	}
	return ""
}

// RefsFingerprint changes whenever a branch, tag, remote branch, HEAD or
// the stash moves — in gitnest or anywhere else (another terminal, an
// IDE). One git process, plus reading HEAD and the stash's reflog.
func RefsFingerprint(ctx context.Context, dir string) string {
	out, err := run(ctx, kRead, dir, nil, "for-each-ref", "--format=%(objectname) %(refname)")
	if err != nil {
		return ""
	}
	fp := out
	if gitDir, common, ok := gitDirs(dir); ok {
		head, _ := os.ReadFile(filepath.Join(gitDir, "HEAD"))
		fp += "HEAD " + string(head) + fmt.Sprintf("stash %d", fileLines(filepath.Join(common, "logs", "refs", "stash")))
	} else if h, err := run(ctx, kRead, dir, nil, "rev-parse", "HEAD"); err == nil {
		fp += "HEAD " + h
	}
	return fp
}

// ActivityCommit is one commit for the activity dashboard.
type ActivityCommit struct {
	Unix                   int64
	Short, Subject, Author string
}

// Activity lists the commits on the local branches since since, newest
// first, at most max of them.
func Activity(ctx context.Context, dir string, since time.Time, max int) ([]ActivityCommit, error) {
	out, err := run(ctx, kRead, dir, nil, "log", "--branches", "--no-merges",
		"--since="+strconv.FormatInt(since.Unix(), 10), "-n", strconv.Itoa(max), "--format=%ct%x1f%h%x1f%an%x1f%s")
	if err != nil {
		return nil, err
	}
	var cs []ActivityCommit
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		f := strings.SplitN(l, "\x1f", 4)
		if len(f) < 4 {
			continue
		}
		unix, _ := strconv.ParseInt(f[0], 10, 64)
		cs = append(cs, ActivityCommit{Unix: unix, Short: f[1], Author: f[2], Subject: f[3]})
	}
	return cs, nil
}

// ListFiles lists the repository's files: tracked ones and untracked ones
// that aren't ignored, as slash paths relative to dir.
func ListFiles(ctx context.Context, dir string) ([]string, error) {
	out, err := run(ctx, kRead, dir, nil, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	var files []string
	for _, f := range strings.Split(out, "\x00") {
		if f != "" && !seen[f] { // a conflicted file is listed once per stage
			seen[f] = true
			files = append(files, f)
		}
	}
	return files, nil
}

// MinGitVersion is the oldest git gitnest is tested with (Debian 12 ships
// 2.39, macOS 2.39+). Older versions mostly work; stashing only staged
// changes needs 2.35.
const MinGitVersion = "2.35"

// GitVersion returns the installed git's version, e.g. "2.39.5".
func GitVersion(ctx context.Context) (string, error) {
	out, err := run(ctx, kRead, "", nil, "version")
	if err != nil {
		return "", err
	}
	f := strings.Fields(out) // git version 2.39.5 (Apple Git-154)
	if len(f) < 3 {
		return "", fmt.Errorf("unexpected output %q", out)
	}
	return f[2], nil
}

// VersionAtLeast compares dotted version numbers: VersionAtLeast("2.39.5", "2.35").
func VersionAtLeast(have, want string) bool {
	h, w := strings.Split(have, "."), strings.Split(want, ".")
	for i := 0; i < len(w); i++ {
		var a, b int
		if i < len(h) {
			a, _ = strconv.Atoi(strings.TrimFunc(h[i], func(r rune) bool { return r < '0' || r > '9' }))
		}
		b, _ = strconv.Atoi(w[i])
		if a != b {
			return a > b
		}
	}
	return true
}

// countLines counts the non-empty text's lines.
func countLines(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

// fileLines counts a file's lines (0 when it doesn't exist). The stash's
// reflog has one per stash, on every git version (status --show-stash
// only reports the count from git 2.35).
func fileLines(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	return countLines(string(b))
}
