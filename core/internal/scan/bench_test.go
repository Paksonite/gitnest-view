package scan

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// BenchmarkGather measures collecting the status of many repositories, the
// work done at startup and on "r". Run with: go test -bench Gather ./internal/scan
func BenchmarkGather(b *testing.B) {
	root := b.TempDir()
	env := append(os.Environ(), "GIT_CONFIG_GLOBAL="+os.DevNull, "GIT_CONFIG_NOSYSTEM=1",
		"GIT_AUTHOR_NAME=b", "GIT_AUTHOR_EMAIL=b@b", "GIT_COMMITTER_NAME=b", "GIT_COMMITTER_EMAIL=b@b")
	var paths []string
	for i := 0; i < 100; i++ {
		p := filepath.Join(root, fmt.Sprintf("repo-%03d", i))
		for _, args := range [][]string{{"init", "-q", "-b", "main", p}, {"-C", p, "commit", "-q", "--allow-empty", "-m", "x"}} {
			cmd := exec.Command("git", args...)
			cmd.Env = env
			if out, err := cmd.CombinedOutput(); err != nil {
				b.Fatalf("%v: %s", err, out)
			}
		}
		paths = append(paths, p)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if got := Gather(context.Background(), paths, 8, nil); len(got) != len(paths) {
			b.Fatalf("got %d repos", len(got))
		}
	}
}
