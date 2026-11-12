package main

// The methods that change a repository (staging, commits, branches,
// stashes, history) and the ones that work across repositories (pull all,
// activity). They are thin: the work is gitnest's own gitx code.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/Paksonite/gitnest-view/core/internal/gitx"
	"github.com/Paksonite/gitnest-view/core/internal/hcl"
	"github.com/Paksonite/gitnest-view/core/internal/rpc"
	"github.com/Paksonite/gitnest-view/core/internal/scan"
)

// ------------------------------------------------------------------ diffs

// DiffLine is one line of a hunk, with its numbers in the old and new file.
type DiffLine struct {
	Kind string `json:"kind"` // "+", "-", " " or "\\"
	Text string `json:"text"`
	Old  int    `json:"old"` // 0 when the line is not in the old file
	New  int    `json:"new"` // 0 when the line is not in the new file
}

type DiffHunk struct {
	Header string     `json:"header"`
	Lines  []DiffLine `json:"lines"`
}

// FileDiff is what the app shows for one changed file.
type FileDiff struct {
	Path      string     `json:"path"`
	Staged    bool       `json:"staged"`
	Hunks     []DiffHunk `json:"hunks"`
	Binary    bool       `json:"binary"`
	Truncated bool       `json:"truncated"`
	// Digest identifies the diff the app saw; line staging refuses to apply
	// to a diff that changed meanwhile.
	Digest string `json:"digest"`
}

const maxDiffLines = 6000

func digestOf(d gitx.Diff) string {
	h := sha256.New()
	for _, l := range d.Header {
		h.Write([]byte(l + "\n"))
	}
	for _, hk := range d.Hunks {
		fmt.Fprintf(h, "@@ %d %d %d %d\n", hk.OldStart, hk.OldLines, hk.NewStart, hk.NewLines)
		for _, l := range hk.Lines {
			h.Write([]byte(l + "\n"))
		}
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

func toFileDiff(path string, staged bool, d gitx.Diff) FileDiff {
	out := FileDiff{Path: path, Staged: staged, Hunks: []DiffHunk{}, Digest: digestOf(d)}
	for _, h := range d.Header {
		if strings.HasPrefix(h, "Binary files") || strings.HasPrefix(h, "GIT binary patch") {
			out.Binary = true
		}
	}
	count := 0
	for _, hk := range d.Hunks {
		old, nw := hk.OldStart, hk.NewStart
		dh := DiffHunk{Header: fmt.Sprintf("@@ -%d,%d +%d,%d @@%s", hk.OldStart, hk.OldLines, hk.NewStart, hk.NewLines, hk.Section)}
		for _, l := range hk.Lines {
			if count >= maxDiffLines {
				out.Truncated = true
				break
			}
			count++
			kind, text := " ", l
			if l != "" {
				kind, text = l[:1], l[1:]
			}
			if !utf8.ValidString(text) {
				text = strings.ToValidUTF8(text, "�")
			}
			line := DiffLine{Kind: kind, Text: text}
			switch kind {
			case "+":
				line.New = nw
				nw++
			case "-":
				line.Old = old
				old++
			case " ":
				line.Old, line.New = old, nw
				old++
				nw++
			}
			dh.Lines = append(dh.Lines, line)
		}
		out.Hunks = append(out.Hunks, dh)
		if out.Truncated {
			break
		}
	}
	return out
}

// untrackedDiff shows a new file as all added lines, without touching the
// index (git diff shows nothing for untracked files).
func untrackedDiff(dir, path string) (FileDiff, error) {
	full := filepath.Join(dir, path)
	info, err := os.Stat(full)
	if err != nil {
		return FileDiff{}, err
	}
	out := FileDiff{Path: path, Hunks: []DiffHunk{}}
	if info.IsDir() {
		return out, nil
	}
	const limit = 2 << 20
	f, err := os.Open(full)
	if err != nil {
		return FileDiff{}, err
	}
	defer f.Close()
	buf := make([]byte, min(info.Size(), limit))
	n, _ := f.Read(buf)
	buf = buf[:n]
	if strings.ContainsRune(string(buf[:min(len(buf), 8000)]), 0) {
		out.Binary = true
		return out, nil
	}
	text := strings.TrimSuffix(string(buf), "\n")
	lines := strings.Split(text, "\n")
	if text == "" {
		lines = nil
	}
	h := DiffHunk{Header: fmt.Sprintf("@@ -0,0 +1,%d @@", len(lines))}
	for i, l := range lines {
		if i >= maxDiffLines {
			out.Truncated = true
			break
		}
		h.Lines = append(h.Lines, DiffLine{Kind: "+", Text: strings.ToValidUTF8(l, "�"), New: i + 1})
	}
	if info.Size() > limit {
		out.Truncated = true
	}
	out.Hunks = append(out.Hunks, h)
	out.Digest = "untracked"
	return out, nil
}

// ------------------------------------------------------------------ files

type fileRef struct {
	Path      string `json:"path"`
	Orig      string `json:"orig"`
	Untracked bool   `json:"untracked"`
	Code      string `json:"code"` // the two-letter status, e.g. "M ", "??"
}

func (f fileRef) gitFile() gitx.File {
	g := gitx.File{Path: f.Path, Orig: f.Orig, X: ' ', Y: ' '}
	if len(f.Code) == 2 {
		g.X, g.Y = f.Code[0], f.Code[1]
	}
	if f.Untracked {
		g.X, g.Y = '?', '?'
	}
	return g
}

// ------------------------------------------------------------------ pull all

// PullRow is one local branch that is behind its upstream.
type PullRow struct {
	Path    string `json:"path"`
	Branch  string `json:"branch"`
	Current bool   `json:"current"`
	Behind  int    `json:"behind"`
	Ahead   int    `json:"ahead"`
	// OK: it can be fast-forwarded; Note says why not, or what to know.
	OK   bool   `json:"ok"`
	Note string `json:"note"`
}

type repoAuth struct {
	Path string `json:"path"`
	Auth *Auth  `json:"auth"`
}

type repoResult struct {
	Path  string `json:"path"`
	Error string `json:"error,omitempty"`
}

// behindRows mirrors the terminal gitnest's pull all: every local branch with
// an upstream that has new commits; diverged branches and branches in the
// middle of an operation are listed but not pulled.
func behindRows(ctx context.Context, dir string) []PullRow {
	info, err := gitx.GetInfo(ctx, dir)
	if err != nil {
		return nil
	}
	local, _, err := gitx.Branches(ctx, dir)
	if err != nil {
		return nil
	}
	var rows []PullRow
	for _, b := range local {
		if b.Upstream == "" {
			continue
		}
		ahead, behind, _ := b.AheadBehind()
		if behind == 0 {
			continue
		}
		r := PullRow{Path: dir, Branch: b.Name, Current: b.Current, Behind: behind, Ahead: ahead, OK: true}
		switch {
		case ahead > 0:
			commits := "commit"
			if ahead > 1 {
				commits = "commits"
			}
			r.OK, r.Note = false, fmt.Sprintf("diverged: %d local %s not pushed — pull it inside the repository", ahead, commits)
		case b.Current && info.State != gitx.StateNone:
			r.OK, r.Note = false, strings.ToLower(info.State.String())+" in progress"
		case b.Current && info.Changes > 0:
			r.Note = fmt.Sprintf("checked out, %d changed files", info.Changes)
		case b.Current:
			r.Note = "checked out"
		}
		rows = append(rows, r)
	}
	return rows
}

// ------------------------------------------------------------------ register

func registerWork(srv *rpc.Server) {
	decodeRepo := func(raw json.RawMessage, v any, path *string) error {
		if err := rpc.Params(raw, v); err != nil {
			return err
		}
		return checkRepo(*path)
	}

	// repo.diff: the diff of one file, staged or not.
	srv.Handle("repo.diff", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path   string  `json:"path"`
			File   fileRef `json:"file"`
			Staged bool    `json:"staged"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.File.Untracked && !p.Staged {
			return untrackedDiff(p.Path, p.File.Path)
		}
		d, err := gitx.FileDiff(ctx, p.Path, p.File.Path, p.Staged)
		if err != nil {
			return nil, err
		}
		return toFileDiff(p.File.Path, p.Staged, d), nil
	})

	srv.Handle("repo.stage", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string   `json:"path"`
			Files []string `json:"files"`
			All   bool     `json:"all"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.All {
			return nil, gitx.StageAll(ctx, p.Path)
		}
		for _, f := range p.Files {
			if err := gitx.Stage(ctx, p.Path, f); err != nil {
				return nil, err
			}
		}
		return nil, nil
	})

	srv.Handle("repo.unstage", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string   `json:"path"`
			Files []string `json:"files"`
			All   bool     `json:"all"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.All {
			return nil, gitx.UnstageAll(ctx, p.Path)
		}
		for _, f := range p.Files {
			if err := gitx.Unstage(ctx, p.Path, f); err != nil {
				return nil, err
			}
		}
		return nil, nil
	})

	// repo.discard throws away the changes of whole files (no undo).
	srv.Handle("repo.discard", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string    `json:"path"`
			Files []fileRef `json:"files"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		for _, f := range p.Files {
			if err := gitx.Discard(ctx, p.Path, f.gitFile()); err != nil {
				return nil, err
			}
		}
		return nil, nil
	})

	// repo.lines stages, unstages or discards chosen lines of one file.
	// Lines are {hunk, line} indexes into the diff the app showed; digest
	// must match that diff.
	srv.Handle("repo.lines", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path   string         `json:"path"`
			File   fileRef        `json:"file"`
			Action string         `json:"action"` // stage, unstage, discard
			Digest string         `json:"digest"`
			Lines  []gitx.LineRef `json:"lines"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if len(p.Lines) == 0 {
			return nil, errors.New("no lines chosen")
		}
		staged := p.Action == "unstage"
		if p.File.Untracked {
			if p.Action != "stage" {
				return nil, errors.New("a new file has nothing staged yet: discard the whole file instead")
			}
			// git can stage parts of a new file once it knows the path.
			if err := gitx.IntentToAdd(ctx, p.Path, p.File.Path); err != nil {
				return nil, err
			}
		}
		d, err := gitx.FileDiff(ctx, p.Path, p.File.Path, staged)
		if err != nil {
			return nil, err
		}
		if !p.File.Untracked && digestOf(d) != p.Digest {
			return nil, errors.New("the file changed since it was shown; look at it again and choose the lines once more")
		}
		sel := map[gitx.LineRef]bool{}
		for _, l := range p.Lines {
			sel[gitx.LineRef{Hunk: l.Hunk, Line: l.Line}] = true
		}
		switch p.Action {
		case "stage":
			return nil, gitx.StageLines(ctx, p.Path, d, sel)
		case "unstage":
			return nil, gitx.UnstageLines(ctx, p.Path, d, sel)
		case "discard":
			return nil, gitx.DiscardLines(ctx, p.Path, d, sel)
		}
		return nil, errors.New("unknown action: " + p.Action)
	})

	srv.Handle("repo.commit", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path    string `json:"path"`
			Message string `json:"message"`
			Amend   bool   `json:"amend"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		msg := gitx.CleanMessage(p.Message)
		if p.Amend {
			if msg == "" {
				return nil, gitx.AmendNoEdit(ctx, p.Path)
			}
			return nil, gitx.RewordMessage(ctx, p.Path, "HEAD", msg)
		}
		if msg == "" {
			return nil, errors.New("write a commit message")
		}
		return nil, gitx.CommitMsg(ctx, p.Path, msg)
	})

	srv.Handle("repo.message", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path string `json:"path"`
			Rev  string `json:"rev"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.Rev == "" {
			p.Rev = "HEAD"
		}
		msg, err := gitx.Message(ctx, p.Path, p.Rev)
		return map[string]string{"message": msg}, err
	})

	// repo.push pushes the current branch; a branch without an upstream gets
	// one on the default remote.
	srv.Handle("repo.push", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string `json:"path"`
			Force bool   `json:"force"`
			Auth  *Auth  `json:"auth"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		info, err := gitx.GetInfo(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		err = gitx.Push(p.Auth.with(ctx), p.Path, p.Force, info.Upstream)
		if err != nil && gitx.PushRejected(err) {
			return nil, &rpc.Error{Code: -32010, Message: "The server has commits this branch does not: pull first, or force push if you rewrote history."}
		}
		return nil, err
	})

	srv.Handle("repo.branch.create", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path string `json:"path"`
			Name string `json:"name"`
			Base string `json:"base"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if err := validBranch(p.Name); err != nil {
			return nil, err
		}
		if strings.HasPrefix(p.Base, "-") {
			return nil, errors.New("not a starting point: " + p.Base)
		}
		return nil, gitx.NewBranchFrom(ctx, p.Path, p.Name, p.Base)
	})

	srv.Handle("repo.branch.delete", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path   string `json:"path"`
			Name   string `json:"name"`
			Force  bool   `json:"force"`
			Remote bool   `json:"remote"`
			Auth   *Auth  `json:"auth"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.Remote {
			return nil, gitx.DeleteRemoteBranch(p.Auth.with(ctx), p.Path, p.Name)
		}
		return nil, gitx.DeleteBranch(ctx, p.Path, p.Name, p.Force)
	})

	srv.Handle("repo.branch.rename", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path string `json:"path"`
			Old  string `json:"old"`
			Name string `json:"name"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if err := validBranch(p.Name); err != nil {
			return nil, err
		}
		return nil, gitx.RenameBranch(ctx, p.Path, p.Old, p.Name)
	})

	srv.Handle("repo.stashes", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		list, err := gitx.Stashes(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		type stash struct {
			Ref     string `json:"ref"`
			Message string `json:"message"`
			When    string `json:"when"`
		}
		out := make([]stash, 0, len(list))
		for _, s := range list {
			out = append(out, stash{s.Ref, s.Msg, s.Rel})
		}
		return map[string]any{"stashes": out}, nil
	})

	srv.Handle("repo.stash", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path    string `json:"path"`
			Action  string `json:"action"` // push, pop, apply, drop
			Ref     string `json:"ref"`
			Message string `json:"message"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		switch p.Action {
		case "push":
			return nil, gitx.StashPush(ctx, p.Path, p.Message)
		case "pop":
			return nil, gitx.StashPop(ctx, p.Path, p.Ref)
		case "apply":
			return nil, gitx.StashApply(ctx, p.Path, p.Ref)
		case "drop":
			return nil, gitx.StashDrop(ctx, p.Path, p.Ref)
		}
		return nil, errors.New("unknown stash action: " + p.Action)
	})

	// repo.history: commits of HEAD with what the app needs to draw them and
	// to know which ones are already on the server.
	srv.Handle("repo.history", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string `json:"path"`
			Limit int    `json:"limit"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.Limit <= 0 || p.Limit > 1000 {
			p.Limit = 100
		}
		commits, err := gitx.Log(ctx, p.Path, p.Limit)
		if err != nil {
			return nil, err
		}
		unpushed := gitx.Unpushed(ctx, p.Path)
		type commit struct {
			SHA      string   `json:"sha"`
			Short    string   `json:"short"`
			Author   string   `json:"author"`
			When     string   `json:"when"`
			Subject  string   `json:"subject"`
			Refs     string   `json:"refs"`
			Parents  []string `json:"parents"`
			Merge    bool     `json:"merge"`
			Unpushed bool     `json:"unpushed"`
		}
		out := make([]commit, 0, len(commits))
		for _, c := range commits {
			parents := c.Parents
			if parents == nil {
				parents = []string{}
			}
			out = append(out, commit{c.Hash, c.Short, c.Author, c.Rel, c.Subject, c.Refs, parents, c.Merge, unpushed[c.Hash]})
		}
		undo, _ := gitx.LastUndo(ctx, p.Path)
		var undoLabel string
		if undo != nil {
			undoLabel = undo.Label
		}
		return map[string]any{"commits": out, "undo": undoLabel}, nil
	})

	// repo.show: one commit's patch, plain text.
	srv.Handle("repo.show", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path string `json:"path"`
			SHA  string `json:"sha"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.SHA == "" || strings.HasPrefix(p.SHA, "-") {
			return nil, errors.New("not a commit: " + p.SHA)
		}
		out, err := gitx.ShowPlain(ctx, p.Path, p.SHA)
		if len(out) > 1<<20 {
			out = out[:1<<20] + "\n… (cut at 1 MB)"
		}
		return map[string]string{"text": out}, err
	})

	// repo.rewrite changes history: reword, squash, fixup or drop one
	// commit, revert it, or undo the last rewrite. Without confirm, a rewrite
	// of commits that are already on a remote is refused with the remotes
	// listed, so the app can ask a second time.
	srv.Handle("repo.rewrite", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path    string `json:"path"`
			Action  string `json:"action"` // reword, squash, fixup, drop, revert, undo
			SHA     string `json:"sha"`
			Message string `json:"message"`
			Confirm bool   `json:"confirm"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		switch p.Action {
		case "undo":
			return nil, gitx.Undo(ctx, p.Path)
		case "revert":
			return nil, gitx.Revert(ctx, p.Path, p.SHA)
		case "reword", "squash", "fixup", "drop":
		default:
			return nil, errors.New("unknown history action: " + p.Action)
		}
		if p.SHA == "" || strings.HasPrefix(p.SHA, "-") {
			return nil, errors.New("not a commit: " + p.SHA)
		}
		onRemotes, err := gitx.CheckRewrite(ctx, p.Path, p.SHA, p.Action)
		if err != nil {
			return nil, err
		}
		if len(onRemotes) > 0 && !p.Confirm {
			return map[string]any{"needsConfirm": true, "remotes": onRemotes}, nil
		}
		if p.Action == "reword" {
			return map[string]any{}, gitx.RewordMessage(ctx, p.Path, p.SHA, gitx.CleanMessage(p.Message))
		}
		return map[string]any{}, gitx.RebaseAction(ctx, p.Path, p.SHA, p.Action, "")
	})

	// repo.operation finishes or abandons a merge, rebase, cherry-pick or
	// revert that stopped on conflicts.
	srv.Handle("repo.operation", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path   string `json:"path"`
			Action string `json:"action"` // continue, abort, skip
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		st, err := gitx.GetState(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		if st == gitx.StateNone {
			return nil, errors.New("nothing is in progress")
		}
		switch p.Action {
		case "continue":
			return nil, gitx.Continue(ctx, p.Path, st)
		case "abort":
			return nil, gitx.Abort(ctx, p.Path, st)
		case "skip":
			if !st.CanSkip() {
				return nil, errors.New("this operation cannot skip")
			}
			return nil, gitx.Skip(ctx, p.Path, st)
		}
		return nil, errors.New("unknown action: " + p.Action)
	})

	// repos.fetchAll fetches many repositories at once and says which ones
	// failed, and which local branches are now behind (what pull all offers).
	srv.Handle("repos.fetchAll", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Repos []repoAuth `json:"repos"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		var mu sync.Mutex
		results := make([]repoResult, 0, len(p.Repos))
		rows := []PullRow{}
		scan.ForEach(len(p.Repos), jobs, func(i int) {
			r := p.Repos[i]
			res := repoResult{Path: r.Path}
			if err := checkRepo(r.Path); err != nil {
				res.Error = err.Error()
			} else if err := gitx.Fetch(r.Auth.with(ctx), r.Path); err != nil {
				res.Error = err.Error()
			}
			found := behindRows(ctx, r.Path)
			mu.Lock()
			results = append(results, res)
			rows = append(rows, found...)
			mu.Unlock()
		})
		sort.Slice(rows, func(i, j int) bool {
			if rows[i].Path != rows[j].Path {
				return rows[i].Path < rows[j].Path
			}
			return rows[i].Branch < rows[j].Branch
		})
		sort.Slice(results, func(i, j int) bool { return results[i].Path < results[j].Path })
		return map[string]any{"results": results, "rows": rows}, nil
	})

	// repos.fastForward brings the chosen branches up to their upstreams.
	srv.Handle("repos.fastForward", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Items []struct {
				Path   string `json:"path"`
				Branch string `json:"branch"`
				Auth   *Auth  `json:"auth"`
			} `json:"items"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		// One repository at a time per path (its lock serialises anyway);
		// different repositories in parallel.
		byRepo := map[string][]int{}
		var order []string
		for i, it := range p.Items {
			if _, ok := byRepo[it.Path]; !ok {
				order = append(order, it.Path)
			}
			byRepo[it.Path] = append(byRepo[it.Path], i)
		}
		type result struct {
			Path   string `json:"path"`
			Branch string `json:"branch"`
			Error  string `json:"error,omitempty"`
		}
		var mu sync.Mutex
		out := []result{}
		scan.ForEach(len(order), jobs, func(i int) {
			path := order[i]
			local, _, err := gitx.Branches(ctx, path)
			for _, idx := range byRepo[path] {
				it := p.Items[idx]
				res := result{Path: path, Branch: it.Branch}
				if err != nil {
					res.Error = err.Error()
				} else if b, ok := findBranch(local, it.Branch); !ok {
					res.Error = "no branch " + it.Branch
				} else if ferr := gitx.FastForward(it.Auth.with(ctx), path, b); ferr != nil {
					res.Error = ferr.Error()
				}
				mu.Lock()
				out = append(out, res)
				mu.Unlock()
			}
		})
		return map[string]any{"results": out}, nil
	})

	srv.Handle("repo.tags", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		tags, err := gitx.Tags(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		type tag struct {
			Name      string `json:"name"`
			Short     string `json:"short"`
			Subject   string `json:"subject"`
			When      string `json:"when"`
			Annotated bool   `json:"annotated"`
		}
		out := make([]tag, 0, len(tags))
		for _, t := range tags {
			out = append(out, tag{t.Name, t.Short, t.Subject, t.Rel, t.Annotated})
		}
		return map[string]any{"tags": out}, nil
	})

	// repo.tag creates, pushes or deletes a tag (locally or on the server).
	srv.Handle("repo.tag", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path    string `json:"path"`
			Action  string `json:"action"` // create, push, delete, deleteRemote
			Name    string `json:"name"`
			Rev     string `json:"rev"`
			Message string `json:"message"`
			Auth    *Auth  `json:"auth"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.Name == "" || strings.HasPrefix(p.Name, "-") || strings.ContainsAny(p.Name, " ~^:?*[\\") {
			return nil, errors.New("not a tag name: " + p.Name)
		}
		switch p.Action {
		case "create":
			if strings.HasPrefix(p.Rev, "-") {
				return nil, errors.New("not a commit: " + p.Rev)
			}
			return nil, gitx.CreateTag(ctx, p.Path, p.Name, p.Rev, p.Message)
		case "push":
			return nil, gitx.PushTag(p.Auth.with(ctx), p.Path, p.Name)
		case "delete":
			return nil, gitx.DeleteTag(ctx, p.Path, p.Name)
		case "deleteRemote":
			return nil, gitx.DeleteRemoteTag(p.Auth.with(ctx), p.Path, p.Name)
		}
		return nil, errors.New("unknown tag action: " + p.Action)
	})

	// repo.resources: what the Terraform / OpenTofu configuration declares.
	srv.Handle("repo.resources", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		items, err := hcl.Scan(p.Path, 3000)
		if items == nil {
			items = []hcl.Item{}
		}
		type item struct {
			hcl.Item
			Address string `json:"address"`
		}
		out := make([]item, 0, len(items))
		for _, i := range items {
			out = append(out, item{i, i.Address()})
		}
		return map[string]any{"items": out}, err
	})

	// repo.blockHistory: the commits that changed the block declared at a
	// line of a file (a resource, a module call).
	srv.Handle("repo.blockHistory", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path string `json:"path"`
			File string `json:"file"`
			Line int    `json:"line"`
		}
		if err := decodeRepo(raw, &p, &p.Path); err != nil {
			return nil, err
		}
		if p.Line < 1 || p.File == "" || strings.HasPrefix(p.File, "-") || strings.Contains(p.File, "..") {
			return nil, errors.New("a file inside the repository and a line are required")
		}
		// The committed version is what git log -L reads.
		text, err := gitx.ShowFile(ctx, p.Path, "HEAD", p.File)
		if err != nil {
			return map[string]any{"commits": []gitx.BlockCommit{}, "start": p.Line, "end": p.Line}, nil
		}
		end := gitx.BlockEnd(text, p.Line)
		commits, err := gitx.BlockHistory(ctx, p.Path, p.File, p.Line, end, 40)
		if commits == nil {
			commits = []gitx.BlockCommit{}
		}
		return map[string]any{"commits": commits, "start": p.Line, "end": end}, err
	})

	// repos.grep finds text in every given repository at once.
	srv.Handle("repos.grep", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Paths      []string `json:"paths"`
			Text       string   `json:"text"`
			Regex      bool     `json:"regex"`
			IgnoreCase bool     `json:"ignoreCase"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		if strings.TrimSpace(p.Text) == "" {
			return nil, errors.New("nothing to search for")
		}
		type hit struct {
			Path    string           `json:"path"`
			Matches []gitx.GrepMatch `json:"matches"`
			Error   string           `json:"error,omitempty"`
		}
		var mu sync.Mutex
		out := []hit{}
		scan.ForEach(len(p.Paths), jobs, func(i int) {
			matches, err := gitx.Grep(ctx, p.Paths[i], p.Text, !p.Regex, p.IgnoreCase, 200)
			if err == nil && len(matches) == 0 {
				return
			}
			h := hit{Path: p.Paths[i], Matches: matches}
			if h.Matches == nil {
				h.Matches = []gitx.GrepMatch{}
			}
			if err != nil {
				h.Error = err.Error()
			}
			mu.Lock()
			out = append(out, h)
			mu.Unlock()
		})
		sort.Slice(out, func(i, j int) bool { return len(out[i].Matches) > len(out[j].Matches) })
		return map[string]any{"results": out}, nil
	})

	// repos.modules: the module sources (and Terragrunt units) of many
	// repositories, to see which use a module and at which version.
	srv.Handle("repos.modules", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Paths []string `json:"paths"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		type use struct {
			Path string   `json:"path"`
			Item hcl.Item `json:"item"`
		}
		var mu sync.Mutex
		out := []use{}
		scan.ForEach(len(p.Paths), jobs, func(i int) {
			items, _ := hcl.Scan(p.Paths[i], 3000)
			mu.Lock()
			for _, it := range items {
				if (it.Kind == "module" || it.Kind == "unit") && it.Source != "" {
					out = append(out, use{p.Paths[i], it})
				}
			}
			mu.Unlock()
		})
		return map[string]any{"uses": out}, nil
	})

	// repos.activity: commits of the last days across repositories, for the
	// dashboard.
	srv.Handle("repos.activity", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Paths []string `json:"paths"`
			Days  int      `json:"days"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		if p.Days <= 0 || p.Days > 365 {
			p.Days = 14
		}
		since := time.Now().AddDate(0, 0, -p.Days)
		type commit struct {
			Path    string `json:"path"`
			Unix    int64  `json:"unix"`
			Short   string `json:"short"`
			Author  string `json:"author"`
			Subject string `json:"subject"`
		}
		var mu sync.Mutex
		out := []commit{}
		scan.ForEach(len(p.Paths), jobs, func(i int) {
			cs, err := gitx.Activity(ctx, p.Paths[i], since, 500)
			if err != nil {
				return
			}
			mu.Lock()
			for _, c := range cs {
				out = append(out, commit{p.Paths[i], c.Unix, c.Short, c.Author, c.Subject})
			}
			mu.Unlock()
		})
		sort.Slice(out, func(i, j int) bool { return out[i].Unix > out[j].Unix })
		return map[string]any{"commits": out}, nil
	})
}

func findBranch(list []gitx.Branch, name string) (gitx.Branch, bool) {
	for _, b := range list {
		if b.Name == name {
			return b, true
		}
	}
	return gitx.Branch{}, false
}

// validBranch refuses names git would refuse, with a readable reason.
func validBranch(name string) error {
	switch {
	case strings.TrimSpace(name) == "":
		return errors.New("a branch needs a name")
	case strings.HasPrefix(name, "-"), strings.HasPrefix(name, "/"), strings.HasSuffix(name, "/"),
		strings.HasSuffix(name, ".lock"), strings.HasSuffix(name, "."), strings.Contains(name, ".."),
		strings.Contains(name, "@{"), strings.Contains(name, "//"):
		return errors.New("git does not allow this branch name: " + name)
	case strings.ContainsAny(name, " ~^:?*[\\\t\n"):
		return errors.New("a branch name cannot contain spaces or any of ~ ^ : ? * [ \\")
	}
	return nil
}
