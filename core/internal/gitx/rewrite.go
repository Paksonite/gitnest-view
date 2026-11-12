package gitx

// History-rewriting operations. Each one is checked up front, records an
// undo point before touching anything, and targets commits by hash.

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Actions accepted by CheckRewrite and RebaseAction.
const (
	ActionDrop   = "drop"
	ActionReword = "reword"
	ActionSquash = "squash" // meld into the parent, combining messages
	ActionFixup  = "fixup"  // meld into the parent, keeping the parent's message
	ActionAmend  = "amend"  // any change to HEAD only (amend, undo commit)
)

// CheckRewrite reports whether commit rev can be rewritten with action. On
// success it returns the remote-tracking branches that already contain an
// affected commit: rewriting those will require a force push.
func CheckRewrite(ctx context.Context, dir, rev, action string) (onRemotes []string, err error) {
	if err := requireNoOperation(ctx, dir); err != nil {
		return nil, err
	}
	hash, err := resolve(ctx, dir, rev)
	if err != nil {
		return nil, err
	}
	head, err := resolve(ctx, dir, "HEAD")
	if err != nil {
		return nil, err
	}
	if !isAncestor(ctx, dir, hash, head) {
		return nil, fmt.Errorf("commit %s is not on the current branch", short(hash))
	}

	oldest := hash // the oldest commit whose hash changes
	switch action {
	case ActionSquash, ActionFixup:
		parent, err := resolve(ctx, dir, hash+"^")
		if err != nil {
			return nil, fmt.Errorf("commit %s has no parent to %s into", short(hash), action)
		}
		oldest = parent
	case ActionAmend:
		if hash != head {
			return nil, errors.New("only HEAD can be amended")
		}
	case ActionDrop, ActionReword:
	default:
		return nil, fmt.Errorf("unknown rewrite action %q", action)
	}

	// Amending HEAD (including reword of HEAD) doesn't replay anything.
	if action != ActionAmend && !(action == ActionReword && hash == head) {
		if hasMerges(ctx, dir, oldest) {
			return nil, fmt.Errorf("the history from %s to HEAD contains merge commits; "+
				"rewriting across merges is not supported", short(oldest))
		}
	}
	return remotesContaining(ctx, dir, oldest), nil
}

// CheckRebaseOnto validates rebasing the current branch onto `onto` and returns
// the remote-tracking branches that already contain commits it would rewrite.
func CheckRebaseOnto(ctx context.Context, dir, onto string) (onRemotes []string, err error) {
	if err := requireNoOperation(ctx, dir); err != nil {
		return nil, err
	}
	out, err := run(ctx, kRead, dir, nil, "rev-list", "--reverse", onto+"..HEAD")
	if err != nil {
		return nil, err
	}
	commits := strings.Fields(out)
	if len(commits) == 0 {
		return nil, nil // fast-forward: nothing is rewritten
	}
	return remotesContaining(ctx, dir, commits[0]), nil
}

// RebaseAction applies action (drop, reword, squash, fixup) to one commit via
// `git rebase -i`, editing the todo line that matches the commit's hash.
// msg is the new message for reword.
func RebaseAction(ctx context.Context, dir, rev, action, msg string) error {
	if action == ActionAmend {
		return errors.New("use Reword or AmendNoEdit to change HEAD")
	}
	if _, err := CheckRewrite(ctx, dir, rev, action); err != nil {
		return err
	}
	hash, err := resolve(ctx, dir, rev)
	if err != nil {
		return err
	}
	base := hash + "^"
	if action == ActionSquash || action == ActionFixup {
		base = hash + "^^"
	}
	args := []string{"rebase", "-i", "--autostash"}
	if _, err := resolve(ctx, dir, base); err != nil {
		args = append(args, "--root")
	} else {
		args = append(args, base)
	}
	env := []string{
		"GITNEST_HASH=" + hash,
		"GITNEST_ACTION=" + action,
		"GITNEST_AWK=" + todoAwk,
		"GIT_SEQUENCE_EDITOR=" + todoEditor,
	}
	if action == ActionReword {
		env = append(env,
			"GITNEST_MSG="+msg,
			`GIT_EDITOR=sh -c 'printf "%s\n" "$GITNEST_MSG" > "$1"' sh`)
	}
	if err := savePoint(ctx, dir, action+" "+short(hash)); err != nil {
		return err
	}
	_, err = run(ctx, kWrite, dir, env, args...)
	return err
}

// todoAwk rewrites the single `pick` line whose abbreviated hash is a prefix
// of $GITNEST_HASH and fails unless exactly one line matched, which makes git
// abort the rebase before anything is changed.
const todoAwk = `($1 == "pick" || $1 == "p") && length($2) >= 4 && index(h, $2) == 1 { $1 = a; n++ }
{ print }
END { if (n != 1) exit 3 }`

const todoEditor = `sh -c 'awk -v h="$GITNEST_HASH" -v a="$GITNEST_ACTION" "$GITNEST_AWK" "$1" > "$1.gitnest" && mv "$1.gitnest" "$1"' sh`

// RewordMessage replaces the whole message of commit rev. HEAD is amended
// with --only, so staged changes stay staged instead of being folded into the
// commit; older commits go through an interactive rebase.
func RewordMessage(ctx context.Context, dir, rev, msg string) error {
	msg = CleanMessage(msg)
	if msg == "" {
		return errors.New("reword: the message is empty")
	}
	hash, err := resolve(ctx, dir, rev)
	if err != nil {
		return err
	}
	head, err := resolve(ctx, dir, "HEAD")
	if err != nil {
		return err
	}
	if hash != head {
		return RebaseAction(ctx, dir, hash, ActionReword, msg)
	}
	if _, err := CheckRewrite(ctx, dir, hash, ActionReword); err != nil {
		return err
	}
	if err := savePoint(ctx, dir, "reword "+short(hash)); err != nil {
		return err
	}
	_, err = run(ctx, kWrite, dir, nil, "commit", "--amend", "--only", "--allow-empty", "-m", msg)
	return err
}

// CleanMessage trims trailing spaces from every line and drops blank lines
// at the start and end of a commit message.
func CleanMessage(msg string) string {
	lines := strings.Split(strings.ReplaceAll(msg, "\r\n", "\n"), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimRight(l, " \t")
	}
	return strings.Trim(strings.Join(lines, "\n"), "\n")
}

// AmendNoEdit folds the staged changes into HEAD, keeping its message.
func AmendNoEdit(ctx context.Context, dir string) error {
	if err := savePoint(ctx, dir, "amend"); err != nil {
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "commit", "--amend", "--no-edit")
	return err
}

// UndoCommit removes the last commit and keeps its changes staged. Undoing
// the first commit leaves the branch without commits, as before it.
func UndoCommit(ctx context.Context, dir string) error {
	if err := savePoint(ctx, dir, "undo commit"); err != nil {
		return err
	}
	if _, err := resolve(ctx, dir, "HEAD~1"); err != nil {
		// The first commit: delete the branch ref, HEAD stays on it.
		branch, err := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "HEAD")
		if err != nil {
			return errors.New("the first commit can only be undone on a branch")
		}
		_, err = run(ctx, kWrite, dir, nil, "update-ref", "-d", strings.TrimSpace(branch))
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "reset", "--soft", "HEAD~1")
	return err
}

func Revert(ctx context.Context, dir, hash string) error {
	if err := savePoint(ctx, dir, "revert "+short(hash)); err != nil {
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "revert", "--no-edit", hash)
	return err
}

func Merge(ctx context.Context, dir, name string) error {
	if err := savePoint(ctx, dir, "merge "+name); err != nil {
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "merge", "--no-edit", name)
	return err
}

func RebaseOnto(ctx context.Context, dir, name string) error {
	if err := savePoint(ctx, dir, "rebase onto "+name); err != nil {
		return err
	}
	_, err := run(ctx, kWrite, dir, nil, "rebase", "--autostash", name)
	return err
}

// ------------------------------------------------------- interactive rebase

// PlanStep is one line of an interactive rebase plan.
type PlanStep struct {
	Hash    string
	Action  string // pick, reword, edit, squash, fixup, drop
	Message string // new message for reword
}

// ErrStopped reports that a plan with "edit" stopped at a commit; continue
// the rebase when done.
var ErrStopped = errors.New("stopped for editing")

// RebasePlan rewrites the commits from steps[0] (the oldest) up to HEAD as
// planned: in the given order, each with its action. steps must list
// exactly those commits. Reword messages are applied with an exec step
// right after the pick, so no editor is needed. Returns ErrStopped when an
// edit step paused the rebase.
func RebasePlan(ctx context.Context, dir string, steps []PlanStep) error {
	if len(steps) == 0 {
		return errors.New("empty plan")
	}
	switch steps[0].Action {
	case ActionSquash, ActionFixup:
		return errors.New("the first commit has nothing to " + steps[0].Action + " into")
	}
	// Check the range (merges, operation in progress) from the oldest commit.
	oldest := ""
	want, err := run(ctx, kRead, dir, nil, "rev-list", "--reverse", "HEAD")
	if err != nil {
		return err
	}
	all := strings.Fields(want)
	inPlan := map[string]bool{}
	for _, st := range steps {
		h, err := resolve(ctx, dir, st.Hash)
		if err != nil {
			return err
		}
		inPlan[h] = true
	}
	if len(all) > 0 && !inPlan[all[len(all)-1]] {
		// HEAD isn't in the plan: commits were made (or the branch moved)
		// after the plan was put together.
		return errors.New("the branch moved since the plan was made — open it again with i")
	}
	for i, h := range all {
		if inPlan[h] {
			oldest = h
			if len(all)-i != len(steps) {
				return fmt.Errorf("the plan must list every commit from %s to HEAD", short(h))
			}
			for _, x := range all[i:] {
				if !inPlan[x] {
					return fmt.Errorf("the plan must list every commit from %s to HEAD", short(h))
				}
			}
			break
		}
	}
	if oldest == "" {
		return errors.New("the planned commits are not on the current branch")
	}
	if _, err := CheckRewrite(ctx, dir, oldest, ActionDrop); err != nil {
		return err
	}

	tmp, err := os.MkdirTemp("", "gitnest-plan")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	var todo strings.Builder
	edits := false
	for i, st := range steps {
		switch st.Action {
		case "pick", ActionDrop, "edit", ActionSquash, ActionFixup:
			fmt.Fprintf(&todo, "%s %s\n", st.Action, st.Hash)
			edits = edits || st.Action == "edit"
		case ActionReword:
			msg := CleanMessage(st.Message)
			if msg == "" {
				return fmt.Errorf("reword %s: the message is empty", short(st.Hash))
			}
			f := filepath.Join(tmp, fmt.Sprintf("msg-%d", i))
			if err := os.WriteFile(f, []byte(msg+"\n"), 0o600); err != nil {
				return err
			}
			fmt.Fprintf(&todo, "pick %s\nexec git commit --amend --only --allow-empty --no-verify -q -F '%s'\n", st.Hash, f)
		default:
			return fmt.Errorf("unknown plan action %q", st.Action)
		}
	}
	todoFile := filepath.Join(tmp, "todo")
	if err := os.WriteFile(todoFile, []byte(todo.String()), 0o600); err != nil {
		return err
	}
	args := []string{"rebase", "-i", "--autostash"}
	if _, err := resolve(ctx, dir, oldest+"^"); err != nil {
		args = append(args, "--root")
	} else {
		args = append(args, oldest+"^")
	}
	if err := savePoint(ctx, dir, fmt.Sprintf("rebase plan (%d commits)", len(steps))); err != nil {
		return err
	}
	env := []string{"GIT_SEQUENCE_EDITOR=cp '" + todoFile + "'"}
	if _, err := run(ctx, kWrite, dir, env, args...); err != nil {
		return err
	}
	if edits {
		if st, _ := GetState(ctx, dir); st == StateRebasing {
			return ErrStopped
		}
	}
	return nil
}

// ------------------------------------------------------------- cherry-pick

// CherryPick applies commits from repository src onto the current branch of
// dst, oldest first. Within one repository (or another worktree of it) this
// is git cherry-pick; across repositories the commits travel as patches
// (format-patch + am -3), keeping authors, dates and messages. Conflicts
// leave a cherry-pick or am in progress, which the usual continue / skip /
// abort keys handle. An undo point is recorded first.
func CherryPick(ctx context.Context, dst, src string, hashes []string) error {
	if len(hashes) == 0 {
		return errors.New("nothing to cherry-pick")
	}
	if err := requireNoOperation(ctx, dst); err != nil {
		return err
	}
	if err := savePoint(ctx, dst, fmt.Sprintf("cherry-pick %d commit(s)", len(hashes))); err != nil {
		return err
	}
	if sameRepository(dst, src) {
		_, err := run(ctx, kWrite, dst, nil, append([]string{"cherry-pick", "--allow-empty"}, hashes...)...)
		return err
	}
	tmp, err := os.MkdirTemp("", "gitnest-patches")
	if err != nil {
		return err
	}
	defer os.RemoveAll(tmp)
	var patches []string
	for i, h := range hashes {
		parents, err := run(ctx, kRead, src, nil, "rev-list", "--parents", "-n", "1", h)
		if err != nil {
			return err
		}
		if len(strings.Fields(parents)) > 2 {
			return fmt.Errorf("%s is a merge commit; merges can't be copied between repositories", short(h))
		}
		out, err := run(ctx, kRead, src, nil, "format-patch", "-k", "--binary", "--no-signature",
			"--start-number", strconv.Itoa(i+1), "-o", tmp, "-1", h)
		if err != nil {
			return err
		}
		patches = append(patches, strings.Fields(out)...)
	}
	_, err = run(ctx, kWrite, dst, nil, append([]string{"am", "-3", "-k", "--keep-cr"}, patches...)...)
	return err
}

// sameRepository reports whether two worktrees share one repository.
func sameRepository(a, b string) bool {
	if filepath.Clean(a) == filepath.Clean(b) {
		return true
	}
	_, ca, ok1 := gitDirs(a)
	_, cb, ok2 := gitDirs(b)
	return ok1 && ok2 && ca == cb
}

// ------------------------------------------------------------- undo points

// UndoPoint is the state recorded before the last history-changing operation.
type UndoPoint struct {
	Label  string `json:"label"`  // e.g. "squash 1a2b3c4"
	Head   string `json:"head"`   // HEAD before the operation
	Branch string `json:"branch"` // checked-out branch, empty when detached
	Time   int64  `json:"time"`
}

// undoRef keeps the saved commit reachable (safe from gc). refs/worktree/ is
// private to each worktree, like the metadata file next to it.
const undoRef = "refs/worktree/gitnest/undo"

func undoFile(gitDir string) string { return filepath.Join(gitDir, "gitnest-undo.json") }

// savePoint records HEAD so the next operation can be undone. A repository
// without commits has nothing to record.
func savePoint(ctx context.Context, dir, label string) error {
	head, err := resolve(ctx, dir, "HEAD")
	if err != nil {
		return nil
	}
	gitDir, err := absGitDir(ctx, dir)
	if err != nil {
		return err
	}
	branch, _ := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "--short", "HEAD")
	if _, err := run(ctx, kWrite, dir, nil, "update-ref", "-m", "gitnest: "+label, undoRef, head); err != nil {
		return fmt.Errorf("saving undo point: %w", err)
	}
	b, _ := json.Marshal(UndoPoint{Label: label, Head: head, Branch: strings.TrimSpace(branch), Time: time.Now().Unix()})
	if err := os.WriteFile(undoFile(gitDir), b, 0o644); err != nil {
		return fmt.Errorf("saving undo point: %w", err)
	}
	return nil
}

// LastUndo returns the most recent undo point, or nil when there is none.
func LastUndo(ctx context.Context, dir string) (*UndoPoint, error) {
	gitDir, err := absGitDir(ctx, dir)
	if err != nil {
		return nil, err
	}
	b, err := os.ReadFile(undoFile(gitDir))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var p UndoPoint
	if err := json.Unmarshal(b, &p); err != nil || p.Head == "" {
		return nil, nil
	}
	if ref, err := resolve(ctx, dir, undoRef); err != nil || ref != p.Head {
		return nil, nil // ref deleted or moved by someone else: don't trust the file
	}
	return &p, nil
}

// Undo resets the branch to the last undo point. It refuses while an
// operation is in progress, with uncommitted changes to tracked files, or on
// a different branch than the one the point was recorded on. The current
// HEAD becomes the new undo point, so a second Undo redoes.
func Undo(ctx context.Context, dir string) error {
	p, err := LastUndo(ctx, dir)
	if err != nil {
		return err
	}
	if p == nil {
		return errors.New("nothing to undo")
	}
	if err := requireNoOperation(ctx, dir); err != nil {
		return err
	}
	branch, _ := run(ctx, kRead, dir, nil, "symbolic-ref", "-q", "--short", "HEAD")
	if b := strings.TrimSpace(branch); b != p.Branch {
		return fmt.Errorf("undo point is for %s, but %s is checked out", orDetached(p.Branch), orDetached(b))
	}
	dirty, err := run(ctx, kRead, dir, nil, "status", "--porcelain", "--untracked-files=no")
	if err != nil {
		return err
	}
	if strings.TrimSpace(dirty) != "" {
		return errors.New("commit or stash your changes before undoing")
	}
	if err := savePoint(ctx, dir, "undo of "+p.Label); err != nil {
		return err
	}
	_, err = run(ctx, kWrite, dir, nil, "reset", "--hard", "-q", p.Head)
	return err
}

// ----------------------------------------------------------------- helpers

func resolve(ctx context.Context, dir, rev string) (string, error) {
	out, err := run(ctx, kRead, dir, nil, "rev-parse", "--verify", "-q", rev+"^{commit}")
	if err != nil {
		return "", fmt.Errorf("unknown revision %s", rev)
	}
	return strings.TrimSpace(out), nil
}

func isAncestor(ctx context.Context, dir, a, b string) bool {
	_, err := run(ctx, kRead, dir, nil, "merge-base", "--is-ancestor", a, b)
	return err == nil
}

// hasMerges reports whether any commit from oldest (inclusive) to HEAD is a merge.
func hasMerges(ctx context.Context, dir, oldest string) bool {
	rng := oldest + "^..HEAD"
	if _, err := resolve(ctx, dir, oldest+"^"); err != nil {
		rng = "HEAD" // oldest is a root commit
	}
	out, err := run(ctx, kRead, dir, nil, "rev-list", "--min-parents=2", "-n", "1", rng)
	return err != nil || strings.TrimSpace(out) != ""
}

func remotesContaining(ctx context.Context, dir, hash string) []string {
	// Full names: refs/remotes/origin/HEAD shortens to just "origin".
	out, err := run(ctx, kRead, dir, nil, "for-each-ref", "--contains", hash, "--format=%(refname)", "refs/remotes")
	if err != nil {
		return nil
	}
	var refs []string
	for _, r := range strings.Fields(out) {
		if !strings.HasSuffix(r, "/HEAD") {
			refs = append(refs, strings.TrimPrefix(r, "refs/remotes/"))
		}
	}
	return refs
}

func requireNoOperation(ctx context.Context, dir string) error {
	st, err := GetState(ctx, dir)
	if err != nil {
		return err
	}
	if st != StateNone {
		return fmt.Errorf("finish or abort the %s in progress first", strings.ToLower(st.String()))
	}
	return nil
}

func absGitDir(ctx context.Context, dir string) (string, error) {
	out, err := run(ctx, kRead, dir, nil, "rev-parse", "--absolute-git-dir")
	return strings.TrimSpace(out), err
}

func short(hash string) string {
	if len(hash) > 7 {
		return hash[:7]
	}
	return hash
}

func orDetached(branch string) string {
	if branch == "" {
		return "detached HEAD"
	}
	return branch
}
