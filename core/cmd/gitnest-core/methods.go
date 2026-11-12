package main

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"strings"
	"sync"

	"github.com/Paksonite/gitnest-view/core/internal/config"
	"github.com/Paksonite/gitnest-view/core/internal/gitx"
	"github.com/Paksonite/gitnest-view/core/internal/rpc"
	"github.com/Paksonite/gitnest-view/core/internal/scan"
	"github.com/Paksonite/gitnest-view/core/internal/state"
	"github.com/Paksonite/gitnest-view/core/internal/workflow"
)

// Repo is one repository as the app sees it.
type Repo struct {
	Path         string `json:"path"`
	Name         string `json:"name"`
	Branch       string `json:"branch"`
	Detached     bool   `json:"detached"`
	HasUpstream  bool   `json:"hasUpstream"`
	UpstreamGone bool   `json:"upstreamGone"`
	Ahead        int    `json:"ahead"`
	Behind       int    `json:"behind"`
	Changes      int    `json:"changes"`
	Conflicts    bool   `json:"conflicts"`
	Stashes      int    `json:"stashes"`
	State        string `json:"state"` // "" or "merging", "rebasing", ...
	LastCommit   int64  `json:"lastCommit"`
	LastUsed     int64  `json:"lastUsed"`
	Remote       Remote `json:"remote"`
}

// Remote is where a repository lives on a forge, read from its remote URL.
// Owner and Repo are empty when the URL does not look like host/owner/repo.
type Remote struct {
	URL   string `json:"url"` // credentials redacted
	Host  string `json:"host"`
	Owner string `json:"owner"`
	Repo  string `json:"repo"`
	Web   string `json:"web"`
}

func remoteOf(url string) Remote {
	r := Remote{URL: gitx.Redact(url), Host: gitx.RemoteHost(url), Web: gitx.WebURL(url)}
	if r.Host == "" {
		return r
	}
	path := strings.TrimPrefix(r.Web, "https://"+r.Host)
	path = strings.Trim(path, "/")
	if i := strings.LastIndex(path, "/"); i > 0 {
		r.Owner, r.Repo = path[:i], path[i+1:]
	}
	return r
}

func repoOf(r scan.Repo) Repo {
	st := ""
	if r.State != gitx.StateNone {
		st = r.State.String()
	}
	return Repo{
		Path: r.Path, Name: r.Name, Branch: r.Branch, Detached: r.Detached,
		HasUpstream: r.Upstream, UpstreamGone: r.UpstreamGone,
		Ahead: r.Ahead, Behind: r.Behind, Changes: r.Changes, Conflicts: r.Conflicts,
		Stashes: r.Stashes, State: st, LastCommit: r.LastUnix, LastUsed: r.Used,
		Remote: remoteOf(r.RemoteURL),
	}
}

// engine keeps what must survive between calls: the scanner remembers
// directory mtimes, so every scan after the first is incremental.
type engine struct {
	mu      sync.Mutex
	opts    string // the scanner's options, to notice when they change
	scanner *scan.Scanner
}

// scannerFor returns the scanner for the given working directories (the
// app's setting). Without any, the folders of the terminal gitnest's
// configuration are used.
func (e *engine) scannerFor(roots []string) (*scan.Scanner, error) {
	cfg := config.Default()
	if len(roots) > 0 {
		cfg.Roots = roots
	} else {
		loaded, _, err := config.Load()
		if err != nil {
			return nil, err
		}
		cfg = loaded
	}
	opts := scan.FromConfig(cfg)
	key, _ := json.Marshal(opts)
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.scanner == nil || e.opts != string(key) {
		e.scanner = scan.NewScanner(opts)
		e.opts = string(key)
	}
	return e.scanner, nil
}

const jobs = 8

// Auth is an access token for git over HTTPS, used for one call only.
type Auth struct {
	Host  string `json:"host"`
	User  string `json:"user"`
	Token string `json:"token"`
}

func (a *Auth) with(ctx context.Context) context.Context {
	if a == nil {
		return ctx
	}
	return gitx.WithEnv(ctx, gitx.TokenEnv(a.Host, a.User, a.Token))
}

type repoParams struct {
	Path string `json:"path"`
	Auth *Auth  `json:"auth"`
}

// decode reads a request's params and checks that path is a repository.
func (p *repoParams) decode(raw json.RawMessage) error {
	if err := rpc.Params(raw, p); err != nil {
		return err
	}
	return checkRepo(p.Path)
}

func checkRepo(path string) error {
	if path == "" {
		return errors.New("path is required")
	}
	if !scan.IsRepo(path) {
		return errors.New("not a git repository: " + path)
	}
	return nil
}

func statusOf(ctx context.Context, paths []string) []Repo {
	found := scan.Status(ctx, paths, jobs, state.Load().Snapshot())
	repos := make([]Repo, 0, len(found))
	for _, r := range found {
		repos = append(repos, repoOf(r))
	}
	return repos
}

// Branch is a local or remote branch.
type Branch struct {
	Name     string `json:"name"`
	Upstream string `json:"upstream"`
	Current  bool   `json:"current"`
	Remote   bool   `json:"remote"`
	Ahead    int    `json:"ahead"`
	Behind   int    `json:"behind"`
	Gone     bool   `json:"gone"`
	Updated  string `json:"updated"`
	Subject  string `json:"subject"`
}

func branchOf(b gitx.Branch) Branch {
	ahead, behind, gone := b.AheadBehind()
	return Branch{Name: b.Name, Upstream: b.Upstream, Current: b.Current, Remote: b.Remote,
		Ahead: ahead, Behind: behind, Gone: gone, Updated: b.Rel, Subject: b.Subject}
}

func register(srv *rpc.Server) {
	e := &engine{}
	registerWork(srv)

	srv.Handle("core.info", func(ctx context.Context, _ json.RawMessage) (any, error) {
		git, err := gitx.GitVersion(ctx)
		gitErr := ""
		if err != nil {
			gitErr = err.Error()
		}
		methods := srv.Methods()
		sort.Strings(methods)
		return map[string]any{"version": version, "git": git, "gitError": gitErr,
			"config": config.Path(), "methods": methods}, nil
	})

	// repos.scan finds the repositories under roots and reads each one's
	// status. full forces every directory to be read again.
	srv.Handle("repos.scan", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Roots []string `json:"roots"`
			Full  bool     `json:"full"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		for i, r := range p.Roots {
			p.Roots[i] = config.Expand(r)
		}
		scanner, err := e.scannerFor(p.Roots)
		if err != nil {
			return nil, err
		}
		paths, _ := scanner.Scan(p.Full)
		found := scan.Gather(ctx, paths, jobs, state.Load().Snapshot())
		repos := make([]Repo, 0, len(found))
		for _, r := range found {
			repos = append(repos, repoOf(r))
		}
		return map[string]any{"repos": repos}, nil
	})

	// repos.status reads the status of the given repositories only: the
	// cheap refresh between scans.
	srv.Handle("repos.status", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Paths []string `json:"paths"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		return map[string]any{"repos": statusOf(ctx, p.Paths)}, nil
	})

	// repo.clone clones url into dest and answers with the new clone's status.
	srv.Handle("repo.clone", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			URL  string `json:"url"`
			Dest string `json:"dest"`
			Auth *Auth  `json:"auth"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		dest := config.Expand(p.Dest)
		if err := gitx.Clone(p.Auth.with(ctx), p.URL, dest); err != nil {
			return nil, err
		}
		return map[string]any{"repos": statusOf(ctx, []string{dest})}, nil
	})

	srv.Handle("repo.fetch", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		return nil, gitx.Fetch(p.Auth.with(ctx), p.Path)
	})

	// repo.pull pulls the current branch the way the user's git is set up
	// (pull.rebase / pull.ff), fast-forward only when nothing is set.
	srv.Handle("repo.pull", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			repoParams
			// Mode overrides the user's git setting: "rebase" or "merge"
			// (for a branch that diverged); empty follows the setting.
			Mode string `json:"mode"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		if err := checkRepo(p.Path); err != nil {
			return nil, err
		}
		ctx = p.Auth.with(ctx)
		mode := gitx.PullSetting(ctx, p.Path)
		switch p.Mode {
		case gitx.PullRebase, gitx.PullMerge:
			mode = p.Mode
		case "":
		default:
			return nil, errors.New("unknown pull mode: " + p.Mode)
		}
		err := gitx.PullWith(ctx, p.Path, mode)
		if err != nil && mode == gitx.PullUnset && strings.Contains(err.Error(), "fast-forward") {
			return nil, &rpc.Error{Code: -32011, Message: "The branch and the server both have new commits. Pull with a rebase or a merge."}
		}
		return nil, err
	})

	srv.Handle("repo.branches", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		local, remote, err := gitx.Branches(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		out := map[string][]Branch{"local": {}, "remote": {}}
		for _, b := range local {
			out["local"] = append(out["local"], branchOf(b))
		}
		for _, b := range remote {
			out["remote"] = append(out["remote"], branchOf(b))
		}
		return out, nil
	})

	// repo.checkout switches to a branch; a remote branch (origin/x) gets a
	// local one tracking it.
	srv.Handle("repo.checkout", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path   string `json:"path"`
			Name   string `json:"name"`
			Remote bool   `json:"remote"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		if err := checkRepo(p.Path); err != nil {
			return nil, err
		}
		if p.Name == "" || strings.HasPrefix(p.Name, "-") {
			return nil, errors.New("not a branch name: " + p.Name)
		}
		return nil, gitx.Checkout(ctx, p.Path, gitx.Branch{Name: p.Name, Remote: p.Remote})
	})

	// repo.files lists what differs from HEAD: staged, unstaged, untracked.
	srv.Handle("repo.files", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p repoParams
		if err := p.decode(raw); err != nil {
			return nil, err
		}
		files, err := gitx.Files(ctx, p.Path)
		if err != nil {
			return nil, err
		}
		type file struct {
			Path      string `json:"path"`
			Orig      string `json:"orig"`
			Staged    bool   `json:"staged"`
			Unstaged  bool   `json:"unstaged"`
			Untracked bool   `json:"untracked"`
			Conflict  bool   `json:"conflict"`
			Code      string `json:"code"`
		}
		out := make([]file, 0, len(files))
		for _, f := range files {
			out = append(out, file{Path: f.Path, Orig: f.Orig, Staged: f.Staged(), Unstaged: f.Unstaged(),
				Untracked: f.Untracked(), Conflict: f.Conflict(), Code: string([]byte{f.X, f.Y})})
		}
		return map[string]any{"files": out}, nil
	})

	// workflow.parse reads an Actions workflow file given as text: its name
	// and the inputs of its manual trigger.
	srv.Handle("workflow.parse", func(_ context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Content string `json:"content"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		return workflow.Parse([]byte(p.Content))
	})

	srv.Handle("repo.log", func(ctx context.Context, raw json.RawMessage) (any, error) {
		var p struct {
			Path  string `json:"path"`
			Limit int    `json:"limit"`
		}
		if err := rpc.Params(raw, &p); err != nil {
			return nil, err
		}
		if err := checkRepo(p.Path); err != nil {
			return nil, err
		}
		if p.Limit <= 0 || p.Limit > 500 {
			p.Limit = 30
		}
		commits, err := gitx.Log(ctx, p.Path, p.Limit)
		if err != nil {
			return nil, err
		}
		type commit struct {
			SHA     string `json:"sha"`
			Short   string `json:"short"`
			Author  string `json:"author"`
			When    string `json:"when"`
			Subject string `json:"subject"`
			Refs    string `json:"refs"`
		}
		out := make([]commit, 0, len(commits))
		for _, c := range commits {
			out = append(out, commit{SHA: c.Hash, Short: c.Short, Author: c.Author, When: c.Rel, Subject: c.Subject, Refs: c.Refs})
		}
		return map[string]any{"commits": out}, nil
	})
}
