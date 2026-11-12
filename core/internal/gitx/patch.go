package gitx

// Partial staging: a file's diff is parsed into hunks and lines, and a
// patch with only the selected lines is built and applied to the index
// (stage), reversed onto the index (unstage) or reversed onto the working
// tree (discard).

import (
	"context"
	"errors"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
)

// Diff is one file's unified diff.
type Diff struct {
	Header []string // "diff --git", "index", "---", "+++" and mode lines
	Hunks  []Hunk
}

type Hunk struct {
	OldStart, OldLines int
	NewStart, NewLines int
	Section            string   // text after the second @@
	Lines              []string // each starts with ' ', '+', '-' or '\'
}

// LineRef points at a line of a hunk.
type LineRef struct{ Hunk, Line int }

// IsChange reports whether line is an added or removed line.
func IsChange(line string) bool {
	return strings.HasPrefix(line, "+") || strings.HasPrefix(line, "-")
}

var hunkRe = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$`)

// ParseDiff reads `git diff` output for a single file (no colour).
func ParseDiff(out string) Diff {
	var d Diff
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	for _, l := range lines {
		if m := hunkRe.FindStringSubmatch(l); m != nil {
			h := Hunk{Section: m[5]}
			h.OldStart, _ = strconv.Atoi(m[1])
			h.OldLines = 1
			if m[2] != "" {
				h.OldLines, _ = strconv.Atoi(m[2])
			}
			h.NewStart, _ = strconv.Atoi(m[3])
			h.NewLines = 1
			if m[4] != "" {
				h.NewLines, _ = strconv.Atoi(m[4])
			}
			d.Hunks = append(d.Hunks, h)
			continue
		}
		if len(d.Hunks) == 0 {
			if l != "" {
				d.Header = append(d.Header, l)
			}
			continue
		}
		h := &d.Hunks[len(d.Hunks)-1]
		h.Lines = append(h.Lines, l)
	}
	return d
}

// FileDiff returns the parsed diff of path: staged (index vs HEAD) or
// unstaged (working tree vs index).
func FileDiff(ctx context.Context, dir, path string, staged bool) (Diff, error) {
	args := []string{"diff", "--no-color", "--no-ext-diff", "-U3"}
	if staged {
		args = append(args, "--cached")
	}
	out, err := run(ctx, kRead, dir, nil, append(args, "--", path)...)
	if err != nil {
		return Diff{}, err
	}
	return ParseDiff(out), nil
}

// IntentToAdd records an untracked file in the index (empty), so its
// content shows up as an unstaged diff that can be staged line by line.
func IntentToAdd(ctx context.Context, dir, path string) error {
	_, err := run(ctx, kWrite, dir, nil, "add", "--intent-to-add", "--", path)
	return err
}

// BuildPatch makes a patch containing only the selected change lines of d.
// For a patch that will be applied as is (staging, discarding with
// reverse=false semantics of the source diff) unselected removals become
// context and unselected additions disappear; when the patch is applied in
// reverse (unstaging from the staged diff) it is the other way round.
// Returns "" when nothing is selected.
func BuildPatch(d Diff, sel map[LineRef]bool, reverse bool) string {
	var b strings.Builder
	delta := 0 // how far new-side line numbers move because of earlier hunks
	any := false
	for hi, h := range d.Hunks {
		out, oldN, newN, changes := buildHunk(hi, h, sel, reverse)
		if changes == 0 {
			continue
		}
		any = true
		newStart := h.OldStart + delta
		if oldN == 0 { // pure addition after line OldStart
			newStart++
		}
		if newN == 0 {
			newStart = max(0, newStart-1)
		}
		fmt.Fprintf(&b, "@@ -%d,%d +%d,%d @@%s\n", h.OldStart, oldN, newStart, newN, h.Section)
		for _, l := range out {
			b.WriteString(l + "\n")
		}
		delta += newN - oldN
	}
	if !any {
		return ""
	}
	return strings.Join(d.Header, "\n") + "\n" + b.String()
}

// pline is a diff line with an optional "\ No newline at end of file" marker.
type pline struct {
	text   string
	noEOL  string
	picked bool
}

// buildHunk rewrites one hunk keeping only the selected changes. Changes
// come in blocks (removals, then additions). The side the patch is checked
// against must keep every line in order: removals going forward (staging
// onto the index, unselected ones become context), additions in reverse
// (unselected ones become context). Selected lines of the other side are
// paired by position: the i-th addition goes right after the i-th removal
// (going forward), the i-th removal right before the i-th addition (in
// reverse), like git add -p.
func buildHunk(hi int, h Hunk, sel map[LineRef]bool, reverse bool) (out []string, oldN, newN, changes int) {
	emit := func(l pline, as byte) {
		out = append(out, string(as)+l.text[1:])
		if l.noEOL != "" {
			out = append(out, l.noEOL)
		}
		switch as {
		case ' ':
			oldN++
			newN++
		case '-':
			oldN++
			changes++
		case '+':
			newN++
			changes++
		}
	}
	lines := h.Lines
	for i := 0; i < len(lines); {
		l := lines[i]
		if l == "" {
			l = " "
		}
		if !IsChange(l) {
			pl := pline{text: l}
			if i+1 < len(lines) && strings.HasPrefix(lines[i+1], "\\") {
				pl.noEOL = lines[i+1]
				i++
			}
			if l[0] == ' ' {
				emit(pl, ' ')
			}
			i++
			continue
		}
		var rem, add []pline
		for i < len(lines) && IsChange(lines[i]) {
			pl := pline{text: lines[i], picked: sel[LineRef{hi, i}]}
			if i+1 < len(lines) && strings.HasPrefix(lines[i+1], "\\") {
				pl.noEOL = lines[i+1]
				i++
			}
			if pl.text[0] == '-' {
				rem = append(rem, pl)
			} else {
				add = append(add, pl)
			}
			i++
		}
		if !reverse {
			for k := 0; k < max(len(rem), len(add)); k++ {
				if k < len(rem) {
					emit(rem[k], map[bool]byte{true: '-', false: ' '}[rem[k].picked])
				}
				if k < len(add) && add[k].picked {
					emit(add[k], '+')
				}
			}
		} else {
			for k := 0; k < max(len(rem), len(add)); k++ {
				if k < len(rem) && rem[k].picked {
					emit(rem[k], '-')
				}
				if k < len(add) {
					emit(add[k], map[bool]byte{true: '+', false: ' '}[add[k].picked])
				}
			}
		}
	}
	return out, oldN, newN, changes
}

// ApplyPatch applies patch to the index (cached) or the working tree,
// optionally in reverse. --recount lets git verify the line counts.
func ApplyPatch(ctx context.Context, dir, patch string, cached, reverse bool) error {
	if patch == "" {
		return errors.New("nothing selected")
	}
	f, err := os.CreateTemp("", "gitnest-*.patch")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err := f.WriteString(patch); err != nil {
		f.Close()
		return err
	}
	f.Close()
	args := []string{"apply", "--recount", "--whitespace=nowarn"}
	if cached {
		args = append(args, "--cached")
	}
	if reverse {
		args = append(args, "--reverse")
	}
	_, err = run(ctx, kWrite, dir, nil, append(args, f.Name())...)
	return err
}

// StageLines stages the selected lines of the unstaged diff d.
func StageLines(ctx context.Context, dir string, d Diff, sel map[LineRef]bool) error {
	return ApplyPatch(ctx, dir, BuildPatch(d, sel, false), true, false)
}

// UnstageLines removes the selected lines of the staged diff d from the index.
func UnstageLines(ctx context.Context, dir string, d Diff, sel map[LineRef]bool) error {
	return ApplyPatch(ctx, dir, BuildPatch(d, sel, true), true, true)
}

// DiscardLines reverts the selected lines of the unstaged diff d in the
// working tree.
func DiscardLines(ctx context.Context, dir string, d Diff, sel map[LineRef]bool) error {
	return ApplyPatch(ctx, dir, BuildPatch(d, sel, true), false, true)
}
