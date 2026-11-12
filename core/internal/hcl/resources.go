// Package hcl finds what a Terraform / OpenTofu configuration declares —
// resources, data sources, modules, and Terragrunt units — by reading the
// files, without running terraform or touching any state.
package hcl

import (
	"bufio"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Item is one declaration.
type Item struct {
	Kind   string `json:"kind"` // resource, data, module, unit
	Type   string `json:"type"` // google_dns_record_set; empty for modules and units
	Name   string `json:"name"`
	File   string `json:"file"` // relative to the repository
	Line   int    `json:"line"`
	Source string `json:"source"` // modules and units
	Many   bool   `json:"many"`   // count or for_each
}

// Address is how terraform names the item in a plan.
func (i Item) Address() string {
	switch i.Kind {
	case "resource":
		return i.Type + "." + i.Name
	case "data":
		return "data." + i.Type + "." + i.Name
	case "module":
		return "module." + i.Name
	}
	return i.Name
}

var (
	blockRe  = regexp.MustCompile(`^\s*(resource|data)\s+"([^"]+)"\s+"([^"]+)"`)
	moduleRe = regexp.MustCompile(`^\s*module\s+"([^"]+)"`)
	sourceRe = regexp.MustCompile(`^\s*source\s*=\s*"([^"]+)"`)
	manyRe   = regexp.MustCompile(`^\s*(count|for_each)\s*=`)
)

// skipDirs are never read: provider caches and Terragrunt's work folders.
var skipDirs = map[string]bool{".git": true, ".terraform": true, ".terragrunt-cache": true, "node_modules": true}

// Scan reads every .tf file (and terragrunt.hcl) under root, at most
// maxFiles of them.
func Scan(root string, maxFiles int) ([]Item, error) {
	var items []Item
	files := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // unreadable: skip, keep going
		}
		if d.IsDir() {
			if path != root && (skipDirs[d.Name()] || strings.HasPrefix(d.Name(), ".")) {
				return filepath.SkipDir
			}
			return nil
		}
		name := d.Name()
		if !strings.HasSuffix(name, ".tf") && name != "terragrunt.hcl" {
			return nil
		}
		if files >= maxFiles {
			return filepath.SkipAll
		}
		files++
		rel, _ := filepath.Rel(root, path)
		found, err := scanFile(path, rel, name == "terragrunt.hcl")
		if err == nil {
			items = append(items, found...)
		}
		return nil
	})
	sort.SliceStable(items, func(a, b int) bool {
		if items[a].File != items[b].File {
			return items[a].File < items[b].File
		}
		return items[a].Line < items[b].Line
	})
	return items, err
}

func scanFile(path, rel string, terragrunt bool) ([]Item, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var items []Item
	// The block being read: its source and count/for_each come after it.
	current := -1
	depth := 0
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64<<10), 1<<20)
	line := 0
	if terragrunt {
		// A Terragrunt unit is the folder; its source is in terraform { }.
		items = append(items, Item{Kind: "unit", Name: filepath.Dir(rel), File: rel, Line: 1})
		current = 0
		depth = 1
	}
	for sc.Scan() {
		line++
		text := sc.Text()
		if i := strings.Index(text, "#"); i >= 0 && !strings.Contains(text[:i], `"`) {
			text = text[:i]
		}
		if depth == 0 || terragrunt {
			if m := blockRe.FindStringSubmatch(text); m != nil && !terragrunt {
				items = append(items, Item{Kind: m[1], Type: m[2], Name: m[3], File: rel, Line: line})
				current = len(items) - 1
			} else if m := moduleRe.FindStringSubmatch(text); m != nil && !terragrunt {
				items = append(items, Item{Kind: "module", Name: m[1], File: rel, Line: line})
				current = len(items) - 1
			}
		}
		if current >= 0 && depth <= 2 {
			if m := sourceRe.FindStringSubmatch(text); m != nil && items[current].Source == "" &&
				(items[current].Kind == "module" || items[current].Kind == "unit") {
				items[current].Source = m[1]
			}
			if depth == 1 && manyRe.MatchString(text) {
				items[current].Many = true
			}
		}
		depth += strings.Count(text, "{") - strings.Count(text, "}")
		if depth < 0 {
			depth = 0
		}
		if depth == 0 && !terragrunt {
			current = -1
		}
	}
	return items, sc.Err()
}
