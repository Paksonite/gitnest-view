package scan

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/Paksonite/gitnest-view/core/internal/config"
)

// Options control which directories are searched for repositories.
type Options struct {
	Roots          []string `json:"roots"`
	Depth          int      `json:"depth"` // levels below each root; a repo at exactly Depth is found
	Exclude        []string `json:"exclude"`
	SkipHidden     bool     `json:"skip_hidden"`
	Nested         bool     `json:"nested"` // look inside repositories too (submodules excluded)
	FollowSymlinks bool     `json:"follow_symlinks"`
}

// dirInfo is what the scanner remembers about one visited directory. While
// the directory's mtime is unchanged its entries are known without reading it:
// creating or removing an entry (e.g. cloning a repo into it) bumps the mtime.
type dirInfo struct {
	Mod    int64    `json:"m"`           // mtime in ns when Subdirs/Repo were computed
	Repo   bool     `json:"r,omitempty"` // contains a .git entry (and is not a submodule)
	Subdir []string `json:"s,omitempty"` // names of subdirectories worth descending into
}

// Stats describe the work done by one scan.
type Stats struct {
	Visited int // directories stat'ed
	Read    int // directories whose entries had to be listed
}

// Scanner finds repositories under the configured roots. Repeated scans only
// list directories whose mtime changed since the previous scan, so detecting
// a new clone costs one stat per known directory. Safe for concurrent use.
type Scanner struct {
	mu   sync.Mutex
	opts Options
	dirs map[string]*dirInfo
}

func NewScanner(opts Options) *Scanner {
	roots := make([]string, len(opts.Roots))
	for i, r := range opts.Roots {
		roots[i] = filepath.Clean(r)
	}
	opts.Roots = roots
	return &Scanner{opts: opts, dirs: map[string]*dirInfo{}}
}

// Scan walks the roots and returns the sorted repository paths. With full
// set, cached directory listings are ignored.
func (s *Scanner) Scan(full bool) ([]string, Stats) {
	s.mu.Lock()
	defer s.mu.Unlock()
	w := walker{s: s, full: full, seen: map[string]*dirInfo{}, real: map[string]bool{}, ex: map[string]bool{}}
	for _, e := range s.opts.Exclude {
		w.ex[e] = true
	}
	for _, root := range s.opts.Roots {
		w.visit(root, 0)
	}
	s.dirs = w.seen // forget directories that no longer exist or are out of scope
	sort.Strings(w.repos)
	return w.repos, w.stats
}

// Repos returns the repositories known from the last scan (or loaded cache)
// without touching the disk.
func (s *Scanner) Repos() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for p, d := range s.dirs {
		if d.Repo {
			out = append(out, p)
		}
	}
	sort.Strings(out)
	return out
}

type walker struct {
	s     *Scanner
	full  bool
	seen  map[string]*dirInfo
	real  map[string]bool // resolved paths visited this scan (symlink loop guard)
	ex    map[string]bool
	repos []string
	stats Stats
}

func (w *walker) visit(dir string, depth int) {
	if _, dup := w.seen[dir]; dup {
		return
	}
	st, err := os.Stat(dir)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		// There, but not readable just now: keep what the last scan found
		// (and look again next time) instead of forgetting it.
		if old := w.s.dirs[dir]; old != nil {
			kept := *old
			kept.Mod = 0
			w.keep(dir, &kept, depth)
		}
		return
	}
	if err != nil || !st.IsDir() {
		return
	}
	w.stats.Visited++
	if w.s.opts.FollowSymlinks {
		real, err := filepath.EvalSymlinks(dir)
		if err != nil || w.real[real] {
			return
		}
		w.real[real] = true
	}
	mod := st.ModTime().UnixNano()
	info := w.s.dirs[dir]
	if w.full || info == nil || info.Mod != mod {
		info = w.read(dir, mod)
	} else if info.Repo && !hasGit(dir) {
		info = w.read(dir, mod) // .git removed without touching the dir's mtime (unlikely)
	}
	w.keep(dir, info, depth)
}

// keep records what is known about dir and goes on below it.
func (w *walker) keep(dir string, info *dirInfo, depth int) {
	w.seen[dir] = info
	if info.Repo {
		w.repos = append(w.repos, dir)
	}
	if depth >= w.s.opts.Depth {
		return
	}
	for _, name := range info.Subdir {
		w.visit(filepath.Join(dir, name), depth+1)
	}
}

// racyWindow is how recent an mtime must be to be read again next time.
const racyWindow = 2 * time.Second

// read lists dir and decides whether it is a repository and which
// subdirectories to descend into.
func (w *walker) read(dir string, mod int64) *dirInfo {
	w.stats.Read++
	info := &dirInfo{Mod: mod}
	// A directory changed just before this read may change again within
	// the same tick of its file system's clock (coarse on some: network
	// drives, containers) without its mtime moving. Don't trust such a
	// recent mtime next time: read the directory again (as git does with
	// "racily clean" files).
	if time.Since(time.Unix(0, mod)) < racyWindow {
		info.Mod = 0
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		// Unreadable just now (too many open files, a busy disk, a
		// permission being changed): keep what the last scan found below
		// it, rather than dropping a whole subtree until the directory
		// changes, and read it again next time.
		if old := w.s.dirs[dir]; old != nil {
			kept := *old
			kept.Mod = 0
			return &kept
		}
		info.Mod = 0
		return info
	}
	for _, e := range entries {
		if e.Name() == ".git" {
			info.Repo = !isSubmodule(filepath.Join(dir, ".git"), e)
			break
		}
	}
	if info.Repo && !w.s.opts.Nested {
		return info
	}
	for _, e := range entries {
		name := e.Name()
		if name == ".git" || w.ex[name] || (w.s.opts.SkipHidden && strings.HasPrefix(name, ".")) {
			continue
		}
		switch {
		case e.IsDir():
		case e.Type()&fs.ModeSymlink != 0 && w.s.opts.FollowSymlinks:
			if st, err := os.Stat(filepath.Join(dir, name)); err != nil || !st.IsDir() {
				continue
			}
		default:
			continue
		}
		info.Subdir = append(info.Subdir, name)
	}
	return info
}

// IsRepo reports whether dir still holds a repository (a .git entry).
func IsRepo(dir string) bool { return hasGit(dir) }

func hasGit(dir string) bool {
	_, err := os.Lstat(filepath.Join(dir, ".git"))
	return err == nil
}

// isSubmodule reports whether a .git entry is a submodule's gitlink
// ("gitdir: ../.git/modules/x"). Linked worktrees also use a .git file
// ("gitdir: …/.git/worktrees/x") and do count as repositories.
func isSubmodule(path string, e fs.DirEntry) bool {
	if e.IsDir() {
		return false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	gitdir := strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(string(b)), "gitdir:"))
	return strings.Contains(filepath.ToSlash(gitdir), "/modules/")
}

// ------------------------------------------------------------------ cache

type cacheFile struct {
	Options Options             `json:"options"`
	Dirs    map[string]*dirInfo `json:"dirs"`
}

// Load restores directory listings saved by Save. The cache is ignored when
// it was written with different options or can't be read.
func (s *Scanner) Load(path string) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var c cacheFile
	if json.Unmarshal(b, &c) != nil || c.Dirs == nil {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	want, _ := json.Marshal(s.opts)
	got, _ := json.Marshal(c.Options)
	if string(want) != string(got) {
		return false
	}
	s.dirs = c.Dirs
	return true
}

// Save writes the directory listings for the next run.
func (s *Scanner) Save(path string) error {
	s.mu.Lock()
	b, err := json.Marshal(cacheFile{Options: s.opts, Dirs: s.dirs})
	s.mu.Unlock()
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

// Diff returns the paths added to and removed from old to get new; both
// inputs must be sorted.
func Diff(old, new []string) (added, removed []string) {
	i, j := 0, 0
	for i < len(old) || j < len(new) {
		switch {
		case j == len(new) || (i < len(old) && old[i] < new[j]):
			removed = append(removed, old[i])
			i++
		case i == len(old) || new[j] < old[i]:
			added = append(added, new[j])
			j++
		default:
			i++
			j++
		}
	}
	return added, removed
}

// FromConfig returns the scan options set in the user's configuration.
func FromConfig(cfg config.Config) Options {
	return Options{
		Roots:          cfg.Roots,
		Depth:          cfg.Depth,
		Exclude:        cfg.Exclude,
		SkipHidden:     cfg.SkipHidden,
		Nested:         cfg.Nested,
		FollowSymlinks: cfg.FollowSymlinks,
	}
}
