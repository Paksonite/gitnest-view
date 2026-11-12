package gitx

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestCloneAndTokenEnv(t *testing.T) {
	ctx := context.Background()
	src := t.TempDir()
	for _, args := range [][]string{{"init", "-q", "-b", "main"}, {"commit", "-q", "--allow-empty", "-m", "first"}} {
		if _, err := run(ctx, kWrite, src, []string{"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com"}, args...); err != nil {
			t.Fatal(err)
		}
	}
	dest := filepath.Join(t.TempDir(), "owner", "name")
	if err := Clone(ctx, src, dest); err != nil {
		t.Fatal(err)
	}
	info, err := GetInfo(ctx, dest)
	if err != nil || info.Branch != "main" {
		t.Fatalf("clone: %+v %v", info, err)
	}
	if err := Clone(ctx, src, dest); err == nil || !strings.Contains(err.Error(), "not empty") {
		t.Errorf("cloning over an existing clone must be refused, got %v", err)
	}

	missing := filepath.Join(t.TempDir(), "gone")
	if err := Clone(ctx, filepath.Join(src, "nope"), missing); err == nil {
		t.Error("cloning a missing repository must fail")
	}
	if _, err := os.Stat(missing); !os.IsNotExist(err) {
		t.Error("a failed clone must not leave its directory behind")
	}

	env := TokenEnv("forge.example.com", "ann", "s3cret")
	if len(env) != 3 || !strings.Contains(env[1], "http.https://forge.example.com/.extraheader") || strings.Contains(strings.Join(env, " "), "s3cret") {
		t.Errorf("token env: %v", env)
	}
	if TokenEnv("forge.example.com", "ann", "") != nil {
		t.Error("no token, no environment")
	}
	// The environment reaches git: the header shows up in its configuration.
	out, err := run(WithEnv(ctx, env), kRead, dest, nil, "config", "--get", "http.https://forge.example.com/.extraheader")
	if err != nil || !strings.HasPrefix(out, "Authorization: Basic ") {
		t.Errorf("git did not see the header: %q %v", out, err)
	}
}
