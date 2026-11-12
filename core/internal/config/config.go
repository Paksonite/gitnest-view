// Package config loads ~/.config/gitnest/config.yaml and generates it for `gitnest init`.
package config

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

type Theme struct {
	Mode   string `yaml:"mode"`   // auto (default), dark or light
	Dark   string `yaml:"dark"`   // theme used on dark backgrounds
	Light  string `yaml:"light"`  // theme used on light backgrounds
	Diff   string `yaml:"diff"`   // "theme" colours diffs with the theme, "git" keeps git's colours
	Accent string `yaml:"accent"` // overrides the theme's accent colour
}

type Config struct {
	Roots          []string `yaml:"roots"`
	Depth          int      `yaml:"depth"`
	Exclude        []string `yaml:"exclude"`
	SkipHidden     bool     `yaml:"skip_hidden"`
	Nested         bool     `yaml:"nested"`
	FollowSymlinks bool     `yaml:"follow_symlinks"`
	RescanInterval int      `yaml:"rescan_interval"` // seconds, 0 disables
	StatusInterval int      `yaml:"status_interval"` // seconds, 0 disables
	FetchInterval  int      `yaml:"fetch_interval"`  // seconds, 0 disables
	Jobs           int      `yaml:"jobs"`
	Editor         string   `yaml:"editor"`
	Icons          string   `yaml:"icons"` // "symbols", "nerd" (needs a Nerd Font) or "plain"
	Theme          Theme    `yaml:"theme"`
	UpdateCheck    *bool    `yaml:"update_check"` // nil means on
	Start          string   `yaml:"start"`        // "dashboard" (default) or "list"
	Mouse          *bool    `yaml:"mouse"`        // nil means on
}

const template = `# gitnest configuration
# Directories scanned for git repositories. Manage them with:
#   gitnest roots add ~/repos    gitnest roots rm ~/repos    gitnest roots
roots: %s
# How many directory levels below each root to search.
depth: 4
# Directory names that are never descended into.
exclude: [node_modules, vendor, .terraform, .venv, Library, .Trash]
# Skip directories starting with "." (the roots themselves are always scanned).
skip_hidden: true
# Also look for repositories inside other repositories (submodules excluded).
nested: false
# Follow symlinked directories while scanning.
follow_symlinks: false
# Seconds between background scans for new or removed repositories (0 = off).
rescan_interval: 60
# Seconds between status refreshes of the repositories on screen (0 = off).
status_interval: 15
# Seconds between background fetches of every repository, so commits to
# pull show up (↓) without pressing f (0 = off; the first runs soon after start).
fetch_interval: 300
# Parallel git processes used for scanning, fetch and pull.
jobs: 8
# Editor used by "e" (empty = $VISUAL, then $EDITOR, then vi).
editor: ""
# Icons for files, folders, branches and tags: "symbols" uses Unicode
# symbols every font has, "nerd" Nerd Font glyphs (needs a Nerd Font in the
# terminal, e.g. MesloLGS NF), "plain" none. T then i in the app switches.
icons: symbols
# Check GitHub every 6 hours for a new gitnest release and say so in the
# header ("gitnest update" installs it). GITNEST_NO_UPDATE_CHECK=1 also turns it off.
update_check: true
# What gitnest opens with: "last" (whichever was shown when it last quit),
# "dashboard" (activity, what needs attention) or "list" (the repositories).
# H switches between them.
start: last
# Click and scroll with the mouse. While it is on, select text in the
# terminal with shift (or option on macOS) held down.
mouse: true
theme:
  # auto follows the terminal background; set dark or light if it guesses wrong.
  mode: auto
  # Themes for dark and light backgrounds: press T in the app to pick one,
  # "gitnest theme list" shows them all; custom ones live in themes/*.yaml.
  dark: gitnest-dark
  light: gitnest-light
  # "theme" colours diffs with the theme; "git" keeps your git colours.
  diff: theme
  # Overrides the theme's accent colour; empty keeps the theme's.
  accent: ""
`

// Dir returns the gitnest config directory (~/.config/gitnest, or $XDG_CONFIG_HOME/gitnest).
func Dir() string {
	if x := os.Getenv("XDG_CONFIG_HOME"); x != "" {
		return filepath.Join(x, "gitnest")
	}
	h, _ := os.UserHomeDir()
	return filepath.Join(h, ".config", "gitnest")
}

// ThemesDir holds user themes (*.yaml).
func ThemesDir() string { return filepath.Join(Dir(), "themes") }

// Path returns the config file path.
func Path() string { return filepath.Join(Dir(), "config.yaml") }

// rootCandidates are common project directories under $HOME. The home
// directory itself is never used: scanning it is slow and on macOS triggers
// privacy prompts for Desktop, Documents and Downloads.
var rootCandidates = []string{"code", "dev", "Developer", "projects", "Projects", "src", "work", "workspace", "repos", "git"}

// DetectRoots returns the candidate project directories that exist.
func DetectRoots() []string {
	h, _ := os.UserHomeDir()
	var roots []string
	seen := map[string]bool{}
	for _, n := range rootCandidates {
		p := filepath.Join(h, n)
		st, err := os.Stat(p)
		if err != nil || !st.IsDir() {
			continue
		}
		// APFS is case-insensitive by default: Projects and projects are one dir.
		key := strings.ToLower(p)
		if real, err := filepath.EvalSymlinks(p); err == nil {
			key = strings.ToLower(real)
		}
		if !seen[key] {
			seen[key] = true
			roots = append(roots, p)
		}
	}
	return roots
}

// Default returns the built-in configuration.
func Default() Config {
	return Config{
		Roots:          DetectRoots(),
		Depth:          4,
		Exclude:        []string{"node_modules", "vendor", ".terraform", ".venv", "Library", ".Trash"},
		SkipHidden:     true,
		RescanInterval: 60,
		StatusInterval: 15,
		FetchInterval:  300,
		Jobs:           8,
		Theme:          Theme{Mode: "auto", Dark: "gitnest-dark", Light: "gitnest-light", Diff: "theme"},
	}
}

// Expand turns "~" and "~/x" into absolute paths under $HOME and cleans the result.
func Expand(p string) string {
	if p == "~" || strings.HasPrefix(p, "~/") {
		h, _ := os.UserHomeDir()
		p = filepath.Join(h, strings.TrimPrefix(p, "~"))
	}
	return filepath.Clean(p)
}

// Abbrev is the inverse of Expand: paths under $HOME are written with "~".
func Abbrev(p string) string {
	h, _ := os.UserHomeDir()
	if h != "" && (p == h || strings.HasPrefix(p, h+string(filepath.Separator))) {
		return "~" + strings.TrimPrefix(p, h)
	}
	return p
}

// Load reads the config file. The bool reports whether a file existed;
// when it did not, defaults (with detected roots) are returned.
func Load() (Config, bool, error) {
	cfg := Default()
	b, err := os.ReadFile(Path())
	if err != nil {
		if os.IsNotExist(err) {
			return cfg, false, nil
		}
		return cfg, false, err
	}
	cfg.Roots = nil // an existing file is authoritative, even with no roots
	if err := yaml.Unmarshal(b, &cfg); err != nil {
		return cfg, true, fmt.Errorf("%s: %w", Path(), err)
	}
	if cfg.Depth <= 0 {
		cfg.Depth = 4
	}
	if cfg.Jobs <= 0 {
		cfg.Jobs = 8
	}
	if cfg.RescanInterval < 0 {
		cfg.RescanInterval = 0
	}
	if cfg.FetchInterval < 0 {
		cfg.FetchInterval = 0
	}
	if cfg.StatusInterval < 0 {
		cfg.StatusInterval = 0
	}
	for i, r := range cfg.Roots {
		cfg.Roots[i] = Expand(r)
	}
	return cfg, true, nil
}

// Init writes a commented config.yaml. It returns os.ErrExist (with the path)
// when the file already exists and force is false.
func Init(force bool) (string, error) {
	path := Path()
	if _, err := os.Stat(path); err == nil && !force {
		return path, os.ErrExist
	}
	return path, writeTemplate(DetectRoots())
}

func writeTemplate(roots []string) error {
	if err := os.MkdirAll(Dir(), 0o755); err != nil {
		return err
	}
	list := "[]"
	if len(roots) > 0 {
		var b strings.Builder
		for _, r := range roots {
			fmt.Fprintf(&b, "\n  - %q", Abbrev(r))
		}
		list = b.String()
	}
	return os.WriteFile(Path(), []byte(fmt.Sprintf(template, list)), 0o644)
}

// SetRoots replaces the roots in the config file, keeping everything else
// (including comments). It creates the file from the template if needed.
func SetRoots(roots []string) error {
	b, err := os.ReadFile(Path())
	if os.IsNotExist(err) {
		return writeTemplate(roots)
	}
	if err != nil {
		return err
	}
	seq := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, r := range roots {
		seq.Content = append(seq.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: Abbrev(r), Style: yaml.DoubleQuotedStyle})
	}
	return editFile(b, []string{"roots"}, seq)
}

// SetValue sets a string at a key path (e.g. "theme", "dark") in the config
// file, keeping everything else including comments. It creates the file
// from the template, and missing mappings, as needed.
func SetValue(path []string, value string) error {
	if _, err := os.Stat(Path()); os.IsNotExist(err) {
		if err := writeTemplate(DetectRoots()); err != nil {
			return err
		}
	}
	b, err := os.ReadFile(Path())
	if err != nil {
		return err
	}
	return editFile(b, path, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: value})
}

func editFile(b []byte, path []string, value *yaml.Node) error {
	var doc yaml.Node
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return fmt.Errorf("%s: %w", Path(), err)
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 || doc.Content[0].Kind != yaml.MappingNode {
		return fmt.Errorf("%s: expected a YAML mapping", Path())
	}
	m := doc.Content[0]
	for i, key := range path {
		var found *yaml.Node
		idx := -1
		for j := 0; j+1 < len(m.Content); j += 2 {
			if m.Content[j].Value == key {
				found, idx = m.Content[j+1], j+1
				break
			}
		}
		last := i == len(path)-1
		switch {
		case last && found != nil:
			value.LineComment, value.FootComment = found.LineComment, found.FootComment
			m.Content[idx] = value
		case last:
			m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, value)
		case found == nil || found.Kind != yaml.MappingNode:
			next := &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			if found != nil {
				m.Content[idx] = next
			} else {
				m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, next)
			}
			m = next
		default:
			m = found
		}
	}
	var out bytes.Buffer
	enc := yaml.NewEncoder(&out)
	enc.SetIndent(2)
	if err := enc.Encode(&doc); err != nil {
		return err
	}
	return os.WriteFile(Path(), out.Bytes(), 0o644)
}

// Icons decides the icon set, "symbols", "nerd" or "plain", and where that
// came from: GITNEST_ICONS overrides the config; without either it is
// symbols, which any font can show. "unicode", the name before symbols
// existed (and the old default), means symbols.
func Icons(cfg Config) (mode, source string) {
	for _, c := range []struct{ v, src string }{{os.Getenv("GITNEST_ICONS"), "GITNEST_ICONS"}, {cfg.Icons, "config"}} {
		switch strings.ToLower(strings.TrimSpace(c.v)) {
		case "nerd":
			return "nerd", c.src
		case "symbols", "unicode":
			return "symbols", c.src
		case "plain", "none":
			return "plain", c.src
		}
	}
	return "symbols", "default"
}

// UpdateCheck reports whether gitnest may look for new releases: on unless
// update_check is false or GITNEST_NO_UPDATE_CHECK is set.
func UpdateCheck(cfg Config) bool {
	if v := strings.ToLower(os.Getenv("GITNEST_NO_UPDATE_CHECK")); v != "" && v != "0" && v != "false" {
		return false
	}
	return cfg.UpdateCheck == nil || *cfg.UpdateCheck
}

// StartScreen is what gitnest opens with: "dashboard", "list", or "last"
// (the default: whichever was shown when gitnest last quit).
func StartScreen(cfg Config) string {
	switch v := strings.ToLower(strings.TrimSpace(cfg.Start)); v {
	case "dashboard", "list":
		return v
	}
	return "last"
}

// MouseOn reports whether the mouse is used (mouse: true, the default).
func MouseOn(cfg Config) bool { return cfg.Mouse == nil || *cfg.Mouse }
