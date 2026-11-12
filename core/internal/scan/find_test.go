package scan

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

// mkrepo creates dir/rel with an empty .git directory (enough for discovery).
func mkrepo(t *testing.T, dir, rel string) string {
	t.Helper()
	p := filepath.Join(dir, rel)
	if err := os.MkdirAll(filepath.Join(p, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func mkfile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func opts(root string) Options {
	return Options{Roots: []string{root}, Depth: 4, Exclude: []string{"node_modules"}, SkipHidden: true}
}

func rel(root string, paths []string) []string {
	out := []string{}
	for _, p := range paths {
		r, _ := filepath.Rel(root, p)
		out = append(out, r)
	}
	return out
}

// tree builds a root with repositories in and out of scope.
func tree(t *testing.T) string {
	root := t.TempDir()
	mkrepo(t, root, "a")
	mkrepo(t, root, "a/inner")          // nested in a
	mkrepo(t, root, "g/b")              // depth 2
	mkrepo(t, root, "g/x/y/edge")       // depth 4: found
	mkrepo(t, root, "g/x/y/z/too-deep") // depth 5: not found
	mkrepo(t, root, "node_modules/dep") // excluded
	mkrepo(t, root, ".hidden/h")        // hidden
	mkfile(t, filepath.Join(root, "wt/.git"), "gitdir: /src/main/.git/worktrees/wt\n")
	mkfile(t, filepath.Join(root, "a/mod/.git"), "gitdir: ../.git/modules/mod\n") // submodule of a
	mkfile(t, filepath.Join(root, "notes.txt"), "not a dir")
	backdate(t, root)
	return root
}

// backdate sets every mtime under root to an hour ago, so the scanner
// trusts them (it reads directories changed in the last moments again).
func backdate(t *testing.T, root string) {
	t.Helper()
	old := time.Now().Add(-time.Hour)
	err := filepath.Walk(root, func(p string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chtimes(p, old, old)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestScanFindsRepositories(t *testing.T) {
	root := tree(t)
	got, _ := NewScanner(opts(root)).Scan(false)
	want := []string{"a", "g/b", "g/x/y/edge", "wt"}
	if !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("got %v, want %v", rel(root, got), want)
	}
}

func TestScanNested(t *testing.T) {
	root := tree(t)
	o := opts(root)
	o.Nested = true
	got, _ := NewScanner(o).Scan(false)
	want := []string{"a", "a/inner", "g/b", "g/x/y/edge", "wt"} // a/mod is a submodule
	if !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("got %v, want %v", rel(root, got), want)
	}
}

func TestScanOptions(t *testing.T) {
	root := tree(t)
	o := opts(root)
	o.SkipHidden, o.Exclude, o.Depth = false, nil, 5
	got, _ := NewScanner(o).Scan(false)
	want := []string{".hidden/h", "a", "g/b", "g/x/y/edge", "g/x/y/z/too-deep", "node_modules/dep", "wt"}
	if !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("got %v, want %v", rel(root, got), want)
	}

	// A root that is itself a repository, and a missing root.
	repo := mkrepo(t, t.TempDir(), "solo")
	got, _ = NewScanner(Options{Roots: []string{repo, filepath.Join(root, "missing")}, Depth: 2}).Scan(false)
	if !reflect.DeepEqual(got, []string{repo}) {
		t.Fatalf("root repo: got %v", got)
	}
}

func TestIncrementalScan(t *testing.T) {
	root := tree(t)
	s := NewScanner(opts(root))
	first, st := s.Scan(false)
	if st.Read == 0 || st.Read != st.Visited {
		t.Fatalf("first scan stats = %+v, want every dir read", st)
	}

	again, st := s.Scan(false)
	if !reflect.DeepEqual(again, first) || st.Read != 0 {
		t.Fatalf("unchanged tree: %v, stats %+v; want same repos and no reads", rel(root, again), st)
	}

	// A new clone deep in the tree is found by reading only its parent and itself.
	mkrepo(t, root, "g/x/fresh")
	got, st := s.Scan(false)
	if want := append([]string{}, "a", "g/b", "g/x/fresh", "g/x/y/edge", "wt"); !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("after clone: %v", rel(root, got))
	}
	if st.Read != 2 {
		t.Errorf("after clone read %d dirs, want 2 (g/x and g/x/fresh)", st.Read)
	}

	// Removing a repository and a whole subtree.
	if err := os.RemoveAll(filepath.Join(root, "g")); err != nil {
		t.Fatal(err)
	}
	got, _ = s.Scan(false)
	if want := []string{"a", "wt"}; !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("after removal: %v", rel(root, got))
	}

	// A directory turned into a repository with git init.
	mkrepo(t, root, "plain")
	got, _ = s.Scan(false)
	if want := []string{"a", "plain", "wt"}; !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("after init: %v", rel(root, got))
	}

	// Full scans ignore the cache.
	_, st = s.Scan(true)
	if st.Read != st.Visited {
		t.Errorf("full scan stats = %+v", st)
	}
}

func TestScanCache(t *testing.T) {
	root := tree(t)
	cache := filepath.Join(t.TempDir(), "sub", "scan.json")
	s := NewScanner(opts(root))
	first, _ := s.Scan(false)
	if err := s.Save(cache); err != nil {
		t.Fatal(err)
	}

	restored := NewScanner(opts(root))
	if !restored.Load(cache) {
		t.Fatal("cache not loaded")
	}
	if got := restored.Repos(); !reflect.DeepEqual(got, first) {
		t.Fatalf("Repos() from cache = %v", rel(root, got))
	}
	if _, st := restored.Scan(false); st.Read != 0 {
		t.Errorf("scan after restoring the cache read %d dirs", st.Read)
	}

	other := opts(root)
	other.Depth = 2
	if NewScanner(other).Load(cache) {
		t.Error("cache written with other options was accepted")
	}
	if NewScanner(opts(root)).Load(filepath.Join(t.TempDir(), "none.json")) {
		t.Error("missing cache reported as loaded")
	}
}

func TestScanSymlinks(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	mkrepo(t, outside, "proj/linked")
	if err := os.Symlink(filepath.Join(outside, "proj"), filepath.Join(root, "proj")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(root, filepath.Join(root, "loop")); err != nil {
		t.Fatal(err)
	}
	mkrepo(t, root, "real")

	got, _ := NewScanner(opts(root)).Scan(false)
	if want := []string{"real"}; !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("without follow: %v", rel(root, got))
	}
	o := opts(root)
	o.FollowSymlinks = true
	got, _ = NewScanner(o).Scan(false)
	if want := []string{"proj/linked", "real"}; !reflect.DeepEqual(rel(root, got), want) {
		t.Fatalf("with follow: %v", rel(root, got))
	}
}

func TestDiff(t *testing.T) {
	added, removed := Diff([]string{"a", "b", "d"}, []string{"b", "c", "d", "e"})
	if !reflect.DeepEqual(added, []string{"c", "e"}) || !reflect.DeepEqual(removed, []string{"a"}) {
		t.Fatalf("added %v removed %v", added, removed)
	}
	if a, r := Diff(nil, nil); a != nil || r != nil {
		t.Fatalf("empty: %v %v", a, r)
	}
}

func TestStatusCache(t *testing.T) {
	path := filepath.Join(t.TempDir(), "status.json")
	if got := Cached(path, []string{"/r/a"}, nil); len(got) != 1 || got[0].Name != "a" {
		t.Fatalf("no cache: %+v", got)
	}
	saved := []Repo{{Path: "/r/a", Name: "a"}, {Path: "/r/gone", Name: "gone"}}
	saved[0].Branch, saved[0].Changes = "main", 2
	if err := SaveStatus(path, saved); err != nil {
		t.Fatal(err)
	}
	got := Cached(path, []string{"/r/a", "/r/new"}, map[string]int64{"/r/new": 5})
	if len(got) != 2 || got[0].Branch != "main" || got[0].Changes != 2 || got[1].Name != "new" || got[1].Used != 5 {
		t.Fatalf("cached = %+v", got)
	}
}

// A directory that changed but can't be read just now keeps what was found
// below it, and is read again on the next scan, instead of losing its
// whole subtree until it changes once more.
func TestUnreadableDirectoryKeepsItsRepositories(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every directory")
	}
	root := t.TempDir()
	mkrepo(t, root, "github.com/a")
	mkrepo(t, root, "github.com/b")
	s := NewScanner(opts(root))
	time.Sleep(racyWindow + 100*time.Millisecond) // not "racily" recent
	if got, _ := s.Scan(false); len(got) != 2 {
		t.Fatalf("first scan: %v", rel(root, got))
	}
	gh := filepath.Join(root, "github.com")
	mkfile(t, filepath.Join(gh, "notes.txt"), "x") // the directory changes…
	os.Chmod(gh, 0o000)                            // …and can't be read for a moment
	t.Cleanup(func() { os.Chmod(gh, 0o755) })
	if got, _ := s.Scan(false); !reflect.DeepEqual(rel(root, got), []string{"github.com/a", "github.com/b"}) {
		t.Fatalf("while unreadable: %v", rel(root, got))
	}
	os.Chmod(gh, 0o755)
	mkrepo(t, root, "github.com/c")
	os.Chtimes(gh, time.Now().Add(-time.Hour), time.Now().Add(-time.Hour)) // as if read back later, unchanged
	if got, _ := s.Scan(false); len(got) != 3 {
		t.Fatalf("readable again: %v (it should be read again)", rel(root, got))
	}
}
