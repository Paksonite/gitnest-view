package config

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// sandbox points HOME and XDG_CONFIG_HOME at temporary directories.
func sandbox(t *testing.T) (home string) {
	t.Helper()
	home = t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(home, ".config"))
	return home
}

func TestDetectRootsNeverUsesHome(t *testing.T) {
	home := sandbox(t)
	if got := DetectRoots(); len(got) != 0 {
		t.Fatalf("no project dirs: got %v, want none", got)
	}
	for _, d := range []string{"repos", "code", "Documents"} {
		if err := os.Mkdir(filepath.Join(home, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	want := []string{filepath.Join(home, "code"), filepath.Join(home, "repos")}
	if got := DetectRoots(); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestExpandAbbrev(t *testing.T) {
	home := sandbox(t)
	if got := Expand("~/repos/"); got != filepath.Join(home, "repos") {
		t.Errorf("Expand = %q", got)
	}
	if got := Expand("/abs/x/../y"); got != "/abs/y" {
		t.Errorf("Expand = %q", got)
	}
	if got := Abbrev(filepath.Join(home, "repos")); got != "~/repos" {
		t.Errorf("Abbrev = %q", got)
	}
	if got := Abbrev(home + "other"); got != home+"other" {
		t.Errorf("Abbrev of a sibling = %q", got)
	}
}

func TestLoadWithoutFile(t *testing.T) {
	home := sandbox(t)
	os.Mkdir(filepath.Join(home, "src"), 0o755)
	cfg, existed, err := Load()
	if err != nil || existed {
		t.Fatalf("existed=%v err=%v", existed, err)
	}
	if !reflect.DeepEqual(cfg.Roots, []string{filepath.Join(home, "src")}) || cfg.RescanInterval != 60 || cfg.StatusInterval != 15 {
		t.Fatalf("defaults = %+v", cfg)
	}
}

func TestInitAndSetRoots(t *testing.T) {
	home := sandbox(t)
	if _, err := Init(false); err != nil {
		t.Fatal(err)
	}
	if _, err := Init(false); !os.IsExist(err) {
		t.Fatalf("second Init: err = %v, want ErrExist", err)
	}
	cfg, existed, err := Load()
	if err != nil || !existed || len(cfg.Roots) != 0 {
		t.Fatalf("fresh config: %+v existed=%v err=%v", cfg.Roots, existed, err)
	}

	// Edit another setting by hand, then change the roots.
	b, _ := os.ReadFile(Path())
	edited := strings.Replace(string(b), "depth: 4", "depth: 6 # mine", 1)
	os.WriteFile(Path(), []byte(edited), 0o644)

	roots := []string{filepath.Join(home, "repos"), "/opt/src"}
	if err := SetRoots(roots); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(Path())
	text := string(out)
	for _, s := range []string{"# gitnest configuration", "gitnest roots add", "depth: 6 # mine", `- "~/repos"`, `- "/opt/src"`, "rescan_interval: 60"} {
		if !strings.Contains(text, s) {
			t.Errorf("config lost %q:\n%s", s, text)
		}
	}
	cfg, _, err = Load()
	if err != nil || !reflect.DeepEqual(cfg.Roots, roots) || cfg.Depth != 6 {
		t.Fatalf("reloaded: roots=%v depth=%d err=%v", cfg.Roots, cfg.Depth, err)
	}

	if err := SetRoots(nil); err != nil {
		t.Fatal(err)
	}
	if cfg, _, _ = Load(); len(cfg.Roots) != 0 {
		t.Fatalf("roots after clearing: %v", cfg.Roots)
	}
}

func TestSetRootsCreatesFile(t *testing.T) {
	sandbox(t)
	if err := SetRoots([]string{"/srv/git"}); err != nil {
		t.Fatal(err)
	}
	cfg, existed, err := Load()
	if err != nil || !existed || !reflect.DeepEqual(cfg.Roots, []string{"/srv/git"}) {
		t.Fatalf("cfg=%+v existed=%v err=%v", cfg.Roots, existed, err)
	}
}

func TestSetValueNested(t *testing.T) {
	sandbox(t)
	if err := SetValue([]string{"theme", "dark"}, "nord"); err != nil { // creates the file
		t.Fatal(err)
	}
	if err := SetValue([]string{"new", "deep", "key"}, "v"); err != nil {
		t.Fatal(err)
	}
	cfg, _, err := Load()
	if err != nil || cfg.Theme.Dark != "nord" || cfg.Theme.Light != "gitnest-light" {
		t.Fatalf("theme = %+v err=%v", cfg.Theme, err)
	}
	b, _ := os.ReadFile(Path())
	for _, want := range []string{"# Themes for dark and light backgrounds", "dark: nord", "deep:\n    key: v"} {
		if !strings.Contains(string(b), want) {
			t.Errorf("config lacks %q:\n%s", want, b)
		}
	}
}

func TestIconsResolution(t *testing.T) {
	sandbox(t)
	t.Setenv("GITNEST_ICONS", "")
	if mode, src := Icons(Config{}); mode != "symbols" || src != "default" {
		t.Errorf("default: %s %s", mode, src)
	}
	if mode, src := Icons(Config{Icons: "nerd"}); mode != "nerd" || src != "config" {
		t.Errorf("config: %s %s", mode, src)
	}
	for v, want := range map[string]string{"unicode": "symbols", "Symbols": "symbols", "plain": "plain", "none": "plain"} {
		if mode, _ := Icons(Config{Icons: v}); mode != want {
			t.Errorf("icons: %s gives %s, want %s", v, mode, want)
		}
	}
	t.Setenv("GITNEST_ICONS", "nerd")
	if mode, src := Icons(Config{Icons: "symbols"}); mode != "nerd" || src != "GITNEST_ICONS" {
		t.Errorf("env: %s %s", mode, src)
	}
}

func TestUpdateCheck(t *testing.T) {
	off := false
	t.Setenv("GITNEST_NO_UPDATE_CHECK", "")
	if !UpdateCheck(Config{}) || UpdateCheck(Config{UpdateCheck: &off}) {
		t.Fatal("update_check from config")
	}
	t.Setenv("GITNEST_NO_UPDATE_CHECK", "1")
	if UpdateCheck(Config{}) {
		t.Fatal("GITNEST_NO_UPDATE_CHECK=1 must turn checks off")
	}
}
