// Package state persists "recently used" timestamps and locates the scan cache.
package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"time"
)

func dir(env, fallback string) string {
	if x := os.Getenv(env); x != "" {
		return filepath.Join(x, "gitnest")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, fallback, "gitnest")
}

func statePath() string { return filepath.Join(dir("XDG_STATE_HOME", ".local/state"), "recent.json") }

// StatusCachePath holds the last known status of every repository, shown
// at startup until fresh status arrives.
func StatusCachePath() string { return filepath.Join(dir("XDG_CACHE_HOME", ".cache"), "status.json") }

// UpdateCachePath remembers the last release check, so GitHub is asked at
// most every update.CheckEvery.
func UpdateCachePath() string { return filepath.Join(dir("XDG_CACHE_HOME", ".cache"), "update.json") }

// DevUpdateCachePath remembers the last check for gitnest-dev builds.
func DevUpdateCachePath() string {
	return filepath.Join(dir("XDG_CACHE_HOME", ".cache"), "update-dev.json")
}

// ScanCachePath is where the repository scanner keeps its directory listings.
func ScanCachePath() string { return filepath.Join(dir("XDG_CACHE_HOME", ".cache"), "scan.json") }

// State is what gitnest remembers between runs. It lives in two files:
// recent.json (what every version knows) and settings.json (what newer
// versions added, which older ones would drop when they rewrite
// recent.json). Every change rewrites only its own key in the file as it is
// on disk now, so several gitnests running at once (a pane in another
// terminal, the released gitnest next to gitnest-dev, the copy still
// running after an update) don't undo each other's changes.
type State struct {
	Recent     map[string]int64 `json:"recent"`
	ListTree   bool             `json:"list_tree"`   // repository list grouped (by directory or remote)
	PaneLayout string           `json:"pane_layout"` // grid, side by side or stacked
	Collapsed  []string         `json:"collapsed"`   // folded directories of the list tree
	// In settings.json:
	ListGroup string   `json:"list_group"` // "folders" (default) or "remote"
	Screen    string   `json:"screen"`     // "dashboard" or "list": where gitnest was last
	Favorites []string `json:"favorites"`  // starred repositories (*)
	ListView  ListView `json:"list_view"`  // the list's sort order (v)
	// Unfolded folders of the file browser (B), by repository.
	BrowseOpen map[string][]string `json:"browse_open"`
}

// ListView is how the repository list is sorted, as chosen in the view
// menu; empty is the default (recently used). gitnest 2.0.7 also saved the
// filters here (status, host, favorites_only); later versions ignore them.
type ListView struct {
	Sort string `json:"sort,omitempty"` // "name", "last commit", "status"
}

func settingsPath() string {
	return filepath.Join(dir("XDG_STATE_HOME", ".local/state"), "settings.json")
}

// SetScreen remembers whether the dashboard or the list was shown last.
func (s *State) SetScreen(screen string) {
	s.Screen = screen
	_ = setKey(settingsPath(), "screen", screen)
}

// SetListGroup remembers how the list tree groups repositories.
func (s *State) SetListGroup(group string) {
	s.ListGroup = group
	_ = setKey(settingsPath(), "list_group", group)
}

// SetListView remembers the list's sort order and filters.
func (s *State) SetListView(v ListView) {
	s.ListView = v
	_ = setKey(settingsPath(), "list_view", v)
}

// SetFavorites remembers the starred repositories.
func (s *State) SetFavorites(paths []string) {
	sort.Strings(paths)
	s.Favorites = paths
	_ = setKey(settingsPath(), "favorites", paths)
}

// SetBrowseOpen remembers which folders of the file browser are unfolded
// in a repository; none forgets the repository.
func (s *State) SetBrowseOpen(repo string, dirs []string) {
	if s.BrowseOpen == nil {
		s.BrowseOpen = map[string][]string{}
	}
	if len(dirs) == 0 {
		delete(s.BrowseOpen, repo)
	} else {
		sort.Strings(dirs)
		s.BrowseOpen[repo] = dirs
	}
	_ = setKey(settingsPath(), "browse_open", s.BrowseOpen)
}

// SetCollapsed remembers which directories of the list tree are folded.
func (s *State) SetCollapsed(dirs []string) {
	s.Collapsed = dirs
	_ = setKey(statePath(), "collapsed", dirs)
}

// SetPaneLayout remembers how panes are arranged.
func (s *State) SetPaneLayout(name string) {
	s.PaneLayout = name
	_ = setKey(statePath(), "pane_layout", name)
}

// SetListTree remembers the repository list layout for the next start.
func (s *State) SetListTree(on bool) {
	s.ListTree = on
	_ = setKey(statePath(), "list_tree", on)
}

// Load reads both files; settings.json wins for the keys it has (older
// versions of gitnest kept them in recent.json).
func Load() *State {
	s := &State{Recent: map[string]int64{}}
	for _, p := range []string{statePath(), settingsPath()} {
		if b, err := os.ReadFile(p); err == nil {
			_ = json.Unmarshal(b, s)
		}
	}
	if s.Recent == nil {
		s.Recent = map[string]int64{}
	}
	return s
}

// Snapshot returns a copy of the recent map (safe to hand to goroutines).
func (s *State) Snapshot() map[string]int64 {
	m := make(map[string]int64, len(s.Recent))
	for k, v := range s.Recent {
		m[k] = v
	}
	return m
}

// maxRecent is how many repositories' last use is remembered.
const maxRecent = 1000

// Touch marks a repo as used now and saves it, merged with what other
// gitnests recorded meanwhile.
func (s *State) Touch(path string) {
	now := time.Now().Unix()
	s.Recent[path] = now
	recent := map[string]int64{}
	if b, err := os.ReadFile(statePath()); err == nil {
		var disk struct {
			Recent map[string]int64 `json:"recent"`
		}
		if json.Unmarshal(b, &disk) == nil && disk.Recent != nil {
			recent = disk.Recent
		}
	}
	for k, v := range s.Recent {
		if v > recent[k] {
			recent[k] = v
		}
	}
	for len(recent) > maxRecent {
		var oldest string
		var ot int64 = 1 << 62
		for k, v := range recent {
			if v < ot {
				oldest, ot = k, v
			}
		}
		delete(recent, oldest)
	}
	s.Recent = recent
	_ = setKey(statePath(), "recent", recent)
}

// setKey sets one key of the JSON object in file p, keeping every other
// key as it is on disk (including ones this version doesn't know), and
// replaces the file in one rename.
func setKey(p, key string, value any) error {
	obj := map[string]json.RawMessage{}
	if b, err := os.ReadFile(p); err == nil {
		_ = json.Unmarshal(b, &obj)
	}
	v, err := json.Marshal(value)
	if err != nil {
		return err
	}
	obj[key] = v
	b, err := json.Marshal(obj)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(p), ".state-*")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o644); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), p)
}
