// Package scan discovers git repositories and gathers their status in parallel.
package scan

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"github.com/Paksonite/gitnest-view/core/internal/gitx"
)

type Repo struct {
	Path string
	Name string
	gitx.Info
	Used int64 // unix time the repo was last opened in gitnest (0 = never)
}

// ForEach runs fn(i) for i in [0,n) with at most jobs running at once.
func ForEach(n, jobs int, fn func(i int)) {
	if jobs < 1 {
		jobs = 1
	}
	sem := make(chan struct{}, jobs)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func(i int) {
			defer wg.Done()
			defer func() { <-sem }()
			fn(i)
		}(i)
	}
	wg.Wait()
}

// Gather collects status for every path and sorts the result with Sort.
func Gather(ctx context.Context, paths []string, jobs int, recent map[string]int64) []Repo {
	out := Status(ctx, paths, jobs, recent)
	Sort(out)
	return out
}

// Status collects status for every path in parallel, keeping the input order.
// Paths that are no longer repositories are left out.
func Status(ctx context.Context, paths []string, jobs int, recent map[string]int64) []Repo {
	res := make([]Repo, len(paths))
	ok := make([]bool, len(paths))
	ForEach(len(paths), jobs, func(i int) {
		info, err := gitx.GetInfo(ctx, paths[i])
		if err != nil {
			return
		}
		res[i] = Repo{Path: paths[i], Name: filepath.Base(paths[i]), Info: info, Used: recent[paths[i]]}
		ok[i] = true
	})
	out := make([]Repo, 0, len(paths))
	for i := range res {
		if ok[i] {
			out = append(out, res[i])
		}
	}
	return out
}

// Sort orders repos: recently opened in gitnest first, then newest commit, then name.
func Sort(repos []Repo) {
	sort.SliceStable(repos, func(i, j int) bool {
		a, b := repos[i], repos[j]
		if a.Used != b.Used {
			return a.Used > b.Used
		}
		if a.LastUnix != b.LastUnix {
			return a.LastUnix > b.LastUnix
		}
		return a.Name < b.Name
	})
}

// SaveStatus writes repos to path so the next start can show them at once.
func SaveStatus(path string, repos []Repo) error {
	b, err := json.Marshal(repos)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Cached returns a Repo for every path, filled from the status cache at
// path when it has one (possibly stale) and with just the name otherwise.
func Cached(path string, paths []string, recent map[string]int64) []Repo {
	known := map[string]Repo{}
	if b, err := os.ReadFile(path); err == nil {
		var repos []Repo
		if json.Unmarshal(b, &repos) == nil {
			for _, r := range repos {
				known[r.Path] = r
			}
		}
	}
	out := make([]Repo, len(paths))
	for i, p := range paths {
		r, ok := known[p]
		if !ok {
			r = Repo{Path: p, Name: filepath.Base(p)}
		}
		r.Used = recent[p]
		out[i] = r
	}
	return out
}
