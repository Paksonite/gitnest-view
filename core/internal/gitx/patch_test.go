package gitx

import (
	"strings"
	"testing"
)

// selectChanges selects change lines of d whose text (without prefix) is in want.
func selectChanges(d Diff, want ...string) map[LineRef]bool {
	sel := map[LineRef]bool{}
	for hi, h := range d.Hunks {
		for li, l := range h.Lines {
			if !IsChange(l) {
				continue
			}
			for _, w := range want {
				if l[1:] == w {
					sel[LineRef{hi, li}] = true
				}
			}
		}
	}
	return sel
}

func TestParseDiff(t *testing.T) {
	d := ParseDiff("diff --git a/f b/f\nindex 1..2 100644\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@ func x\n a\n-b\n+B\n c\n@@ -10 +10,2 @@\n z\n+y\n\\ No newline at end of file\n")
	if len(d.Header) != 4 || len(d.Hunks) != 2 {
		t.Fatalf("diff: %+v", d)
	}
	h := d.Hunks[1]
	if h.OldStart != 10 || h.OldLines != 1 || h.NewLines != 2 || d.Hunks[0].Section != " func x" || len(h.Lines) != 3 {
		t.Errorf("hunks: %+v", d.Hunks)
	}
}

func TestStageAndUnstageLines(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl\n", "base")
	// two hunks: b->B and c->C near the top, k->K at the bottom
	writeFile(t, dir, "f.txt", "a\nB\nC\nd\ne\nf\ng\nh\ni\nj\nK\nl\n")
	d, err := FileDiff(bg, dir, "f.txt", false)
	if err != nil || len(d.Hunks) != 2 {
		t.Fatalf("diff %+v %v", d, err)
	}

	// Stage only "b -> B": the c->C change and the second hunk stay unstaged.
	if err := StageLines(bg, dir, d, selectChanges(d, "b", "B")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":f.txt"); got != "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nk\nl" {
		t.Errorf("index after staging one line:\n%s", got)
	}

	// Stage the second hunk (only its addition: k stays removed? no — both lines).
	d, _ = FileDiff(bg, dir, "f.txt", false)
	if err := StageLines(bg, dir, d, selectChanges(d, "k", "K")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":f.txt"); got != "a\nB\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl" {
		t.Errorf("index after staging the second hunk:\n%s", got)
	}

	// Unstage "b -> B" again from the staged diff.
	sd, _ := FileDiff(bg, dir, "f.txt", true)
	if err := UnstageLines(bg, dir, sd, selectChanges(sd, "b", "B")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":f.txt"); got != "a\nb\nc\nd\ne\nf\ng\nh\ni\nj\nK\nl" {
		t.Errorf("index after unstaging:\n%s", got)
	}
	// The working tree never changed.
	if got := git(t, dir, "diff", "--no-color", "--stat"); !strings.Contains(got, "f.txt") {
		t.Errorf("working tree lost changes: %q", got)
	}
}

func TestStageOnlyAnAddition(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "a\nb\n", "base")
	writeFile(t, dir, "f.txt", "a\nnew1\nnew2\nb\n")
	d, _ := FileDiff(bg, dir, "f.txt", false)
	if err := StageLines(bg, dir, d, selectChanges(d, "new2")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":f.txt"); got != "a\nnew2\nb" {
		t.Errorf("index:\n%s", got)
	}
}

func TestDiscardLines(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "a\nb\nc\n", "base")
	writeFile(t, dir, "f.txt", "a\nB\nc\nextra\n")
	d, _ := FileDiff(bg, dir, "f.txt", false)
	if err := DiscardLines(bg, dir, d, selectChanges(d, "extra")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":f.txt"); got != "a\nb\nc" {
		t.Errorf("index touched: %q", got)
	}
	b := git(t, dir, "diff", "--no-color")
	if strings.Contains(b, "extra") || !strings.Contains(b, "+B") {
		t.Errorf("worktree diff after discard:\n%s", b)
	}
}

func TestStageLinesOfNewFile(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "a.txt", "a\n", "base")
	writeFile(t, dir, "new.txt", "one\ntwo\nthree\n")
	if err := IntentToAdd(bg, dir, "new.txt"); err != nil {
		t.Fatal(err)
	}
	d, _ := FileDiff(bg, dir, "new.txt", false)
	if err := StageLines(bg, dir, d, selectChanges(d, "one", "three")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "show", ":new.txt"); got != "one\nthree" {
		t.Errorf("index:\n%q", got)
	}
}

func TestNoNewlineAtEnd(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "a\nb", "base") // no trailing newline
	writeFile(t, dir, "f.txt", "a\nB")
	d, _ := FileDiff(bg, dir, "f.txt", false)
	if err := StageLines(bg, dir, d, selectChanges(d, "b", "B")); err != nil {
		t.Fatal(err)
	}
	if got := git(t, dir, "diff", "--cached", "--no-color"); !strings.Contains(got, "+B") {
		t.Errorf("staged:\n%s", got)
	}
	if BuildPatch(d, nil, false) != "" {
		t.Error("an empty selection should build no patch")
	}
}

// Every single change line, and every pair, of a messy diff can be staged
// and then unstaged again without git rejecting the patch.
func TestAnySelectionApplies(t *testing.T) {
	dir := newRepo(t)
	commit(t, dir, "f.txt", "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n", "base")
	writeFile(t, dir, "f.txt", "1\nA\nB\n3\n4\nnew\n5\n6\n8\n9\n10\nX\nY\nZ\n14\n15\nend\n")
	base := git(t, dir, "write-tree")
	d, _ := FileDiff(bg, dir, "f.txt", false)
	var refs []LineRef
	for hi, h := range d.Hunks {
		for li, l := range h.Lines {
			if IsChange(l) {
				refs = append(refs, LineRef{hi, li})
			}
		}
	}
	try := func(sel map[LineRef]bool) {
		t.Helper()
		git(t, dir, "read-tree", base)
		if err := StageLines(bg, dir, d, sel); err != nil {
			t.Fatalf("stage %v: %v\n%s", sel, err, BuildPatch(d, sel, false))
		}
		sd, _ := FileDiff(bg, dir, "f.txt", true)
		all := map[LineRef]bool{}
		for hi, h := range sd.Hunks {
			for li, l := range h.Lines {
				if IsChange(l) {
					all[LineRef{hi, li}] = true
				}
			}
		}
		if err := UnstageLines(bg, dir, sd, all); err != nil {
			t.Fatalf("unstage after %v: %v", sel, err)
		}
		if got := git(t, dir, "diff", "--cached", "--name-only"); got != "" {
			t.Fatalf("still staged after unstaging everything: %q", got)
		}
	}
	for i := range refs {
		try(map[LineRef]bool{refs[i]: true})
		for j := i + 1; j < len(refs); j++ {
			try(map[LineRef]bool{refs[i]: true, refs[j]: true})
		}
	}
}
