package main

// End-to-end coverage for registry-dispatched backends through the real bd
// binary: init provisions through the registry Provision hook, a write
// command exercises Backend.Open, a read-only command exercises
// Backend.OpenReadOnly, and running from a subdirectory exercises the
// workspace-discovery predicate (WorkspaceIsBeadsDir).
//
// This file deliberately carries NO cgo build tag: the sqlite backend is
// pure Go, so the same test runs under CGO_ENABLED=0 and executes the
// registry dispatch in the nocgo build flavor (see the pure-Go subset in
// .github/workflows/pr.yml), not just compile-checks it.

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// registryE2EEnv strips beads-specific variables like initBackendTestEnv but
// does NOT pin BEADS_DIR: workspace discovery from the working directory is
// exactly what the subdirectory case exercises.
func registryE2EEnv() []string {
	var env []string
	for _, e := range os.Environ() {
		if strings.HasPrefix(e, "BEADS_") || strings.HasPrefix(e, "BD_") {
			continue
		}
		env = append(env, e)
	}
	return env
}

func TestRegistryBackendEndToEndSQLite(t *testing.T) {
	bd := buildBDForInitTests(t)
	tmpDir := t.TempDir()
	beadsDir := filepath.Join(tmpDir, ".beads")

	// run returns stdout and stderr separately: JSON output must be parsed
	// from stdout alone (bd prints advisory warnings on stderr).
	run := func(dir string, args ...string) (stdout, stderr []byte, err error) {
		cmd := exec.Command(bd, args...)
		cmd.Dir = dir
		cmd.Env = registryE2EEnv()
		var outBuf, errBuf bytes.Buffer
		cmd.Stdout = &outBuf
		cmd.Stderr = &errBuf
		err = cmd.Run()
		return outBuf.Bytes(), errBuf.Bytes(), err
	}

	if out, errOut, err := run(tmpDir, "init", "--backend", "sqlite", "--prefix", "e2e", "--quiet", "--skip-hooks", "--skip-agents"); err != nil {
		t.Fatalf("bd init --backend=sqlite: %v\n%s%s", err, out, errOut)
	}
	if _, err := os.Stat(filepath.Join(beadsDir, "beads.db")); err != nil {
		t.Fatalf("sqlite database not provisioned: %v", err)
	}

	// Write path: bd create dispatches through Backend.Open.
	if out, errOut, err := run(tmpDir, "create", "registry e2e issue", "--json"); err != nil {
		t.Fatalf("bd create (Backend.Open): %v\n%s%s", err, out, errOut)
	}

	// Read-only path: bd list is a readOnlyCommands member, so
	// PersistentPreRun dispatches through Backend.OpenReadOnly.
	assertListed := func(dir, label string) {
		t.Helper()
		out, errOut, err := run(dir, "list", "--json")
		if err != nil {
			t.Fatalf("bd list from %s (Backend.OpenReadOnly): %v\n%s%s", label, err, out, errOut)
		}
		var issues []map[string]any
		if jsonErr := json.Unmarshal(out, &issues); jsonErr != nil {
			t.Fatalf("bd list from %s: unparseable JSON: %v\n%s", label, jsonErr, out)
		}
		if len(issues) != 1 {
			t.Fatalf("bd list from %s = %d issues, want 1\n%s", label, len(issues), out)
		}
		if title, _ := issues[0]["title"].(string); title != "registry e2e issue" {
			t.Errorf("bd list from %s: title = %q, want %q", label, title, "registry e2e issue")
		}
	}
	assertListed(tmpDir, "workspace root")

	// Discovery: from a subdirectory with no BEADS_DIR and no local Dolt
	// database, finding the workspace at all requires the registry's
	// WorkspaceIsBeadsDir capability in the discovery predicate.
	subDir := filepath.Join(tmpDir, "sub", "dir")
	if err := os.MkdirAll(subDir, 0o755); err != nil {
		t.Fatalf("mkdir subdir: %v", err)
	}
	assertListed(subDir, "subdirectory")
}
