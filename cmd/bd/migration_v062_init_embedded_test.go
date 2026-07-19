//go:build cgo

package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/steveyegge/beads/internal/beads"
	"github.com/steveyegge/beads/internal/configfile"
)

const migrationV062ProjectIDFlagNameForTest = "migration-v062-project-id"
const migrationV062RepositoryRootFlagNameForTest = "migration-v062-repository-root"

func TestMigrationV062ProjectIDInitFlagIsHidden(t *testing.T) {
	for _, name := range []string{
		migrationV062ProjectIDFlagNameForTest,
		migrationV062RepositoryRootFlagNameForTest,
	} {
		flag := initCmd.Flags().Lookup(name)
		if flag == nil {
			t.Fatalf("init command does not register hidden --%s", name)
		}
		if !flag.Hidden {
			t.Fatalf("--%s must be hidden from init help", name)
		}
	}
}

func TestMigrationV062ProjectIDInitEmbedded(t *testing.T) {
	bd := buildEmbeddedBD(t)

	t.Run("preserves_authenticated_identity", func(t *testing.T) {
		const projectID = "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"
		dir := t.TempDir()
		initGitRepoAt(t, dir)

		cmd := exec.Command(bd,
			"init",
			"--quiet",
			"--non-interactive",
			"--skip-hooks",
			"--skip-agents",
			"--prefix", "legacy",
			"--database", "smoke",
			"--backend=dolt",
			"--"+migrationV062ProjectIDFlagNameForTest, projectID,
		)
		cmd.Dir = dir
		cmd.Env = bdEnv(dir)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("migration identity init failed: %v\n%s", err, out)
		}

		beadsDir := filepath.Join(dir, ".beads")
		cfg, err := configfile.Load(beadsDir)
		if err != nil {
			t.Fatalf("load metadata.json: %v", err)
		}
		if cfg == nil {
			t.Fatal("metadata.json was not created")
		}
		if cfg.Backend != configfile.BackendDolt {
			t.Fatalf("metadata backend = %q, want %q", cfg.Backend, configfile.BackendDolt)
		}
		if cfg.DoltMode != configfile.DoltModeEmbedded {
			t.Fatalf("metadata Dolt mode = %q, want %q", cfg.DoltMode, configfile.DoltModeEmbedded)
		}
		if cfg.DoltDatabase != "smoke" {
			t.Fatalf("metadata Dolt database = %q, want authenticated source database %q", cfg.DoltDatabase, "smoke")
		}
		if cfg.ProjectID != projectID {
			t.Fatalf("metadata project_id = %q, want authenticated v0.62 identity %q", cfg.ProjectID, projectID)
		}
		if got := readBack(t, beadsDir, "smoke", "_project_id", true); got != projectID {
			t.Fatalf("database _project_id = %q, want authenticated v0.62 identity %q", got, projectID)
		}
		if got := readBack(t, beadsDir, "smoke", "issue_prefix", false); got != "legacy" {
			t.Fatalf("database issue_prefix = %q, want authenticated source prefix %q", got, "legacy")
		}
	})

	tests := []struct {
		name       string
		args       []string
		wantErrors []string
		untouched  []string
	}{
		{
			name:       "rejects_invalid_uuid",
			args:       []string{"--backend=dolt", "--" + migrationV062ProjectIDFlagNameForTest, "not-a-uuid"},
			wantErrors: []string{"uuid"},
		},
		{
			name:       "requires_explicit_dolt_backend",
			args:       []string{"--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"explicit", "backend=dolt"},
		},
		{
			name:       "rejects_server_selector",
			args:       []string{"--backend=dolt", "--server", "--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"--server"},
		},
		{
			name:       "rejects_non_dolt_backend",
			args:       []string{"--backend=sqlite", "--sqlite-path", "provider.db", "--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"backend=dolt"},
			untouched:  []string{"provider.db"},
		},
		{
			name:       "rejects_reinit",
			args:       []string{"--backend=dolt", "--reinit-local", "--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"--reinit-local"},
		},
		{
			name:       "rejects_from_jsonl",
			args:       []string{"--backend=dolt", "--from-jsonl", "--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"--from-jsonl"},
		},
		{
			name:       "rejects_remote",
			args:       []string{"--backend=dolt", "--remote", "https://example.invalid/legacy.git", "--" + migrationV062ProjectIDFlagNameForTest, "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},
			wantErrors: []string{"--remote"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			initGitRepoAt(t, dir)
			args := append([]string{
				"init",
				"--quiet",
				"--non-interactive",
				"--skip-hooks",
				"--skip-agents",
				"--prefix", "legacy",
			}, tt.args...)
			cmd := exec.Command(bd, args...)
			cmd.Dir = dir
			cmd.Env = bdEnv(dir)
			out, err := cmd.CombinedOutput()
			if err == nil {
				t.Fatalf("unsafe migration identity init unexpectedly succeeded:\n%s", out)
			}

			message := strings.ToLower(string(out))
			if strings.Contains(message, "unknown flag") {
				t.Fatalf("migration identity flag is not implemented; wanted an admission refusal:\n%s", out)
			}
			if !strings.Contains(message, "--"+migrationV062ProjectIDFlagNameForTest) {
				t.Fatalf("refusal does not identify --%s:\n%s", migrationV062ProjectIDFlagNameForTest, out)
			}
			for _, want := range tt.wantErrors {
				if !strings.Contains(message, strings.ToLower(want)) {
					t.Fatalf("refusal does not mention %q:\n%s", want, out)
				}
			}

			assertMigrationV062InitUntouched(t, dir, tt.untouched...)
		})
	}
}

func TestMigrationV062StagedInitPublishesFinalRepositoryIdentity(t *testing.T) {
	bd := buildEmbeddedBD(t)
	finalWorkspace := t.TempDir()
	initGitRepoAt(t, finalWorkspace)

	stagedTarget := filepath.Join(
		finalWorkspace, ".beads-v0.62.0-staging", "target",
	)
	if err := os.MkdirAll(stagedTarget, 0o700); err != nil {
		t.Fatalf("create staged target: %v", err)
	}
	initGitRepoAt(t, stagedTarget)
	runBDInit(t, bd, stagedTarget,
		"--non-interactive",
		"--skip-hooks",
		"--skip-agents",
		"--prefix", "legacy",
		"--database", "smoke",
		"--backend=dolt",
		"--"+migrationV062ProjectIDFlagNameForTest,
		"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6",
		"--"+migrationV062RepositoryRootFlagNameForTest,
		finalWorkspace,
	)

	publishedBeads := filepath.Join(finalWorkspace, ".beads")
	if err := os.Rename(filepath.Join(stagedTarget, ".beads"), publishedBeads); err != nil {
		t.Fatalf("publish staged .beads: %v", err)
	}

	wantRepoID, err := beads.ComputeRepoIDForPath(finalWorkspace)
	if err != nil {
		t.Fatalf("compute final workspace repo_id: %v", err)
	}
	wantCloneID, err := beads.GetCloneIDForPath(finalWorkspace)
	if err != nil {
		t.Fatalf("compute final workspace clone_id: %v", err)
	}
	if got := readBack(t, publishedBeads, "smoke", "repo_id", true); got != wantRepoID {
		t.Errorf("published repo_id = %q, want final workspace identity %q", got, wantRepoID)
	}
	if got := readBack(t, publishedBeads, "smoke", "clone_id", true); got != wantCloneID {
		t.Errorf("published clone_id = %q, want final workspace identity %q", got, wantCloneID)
	}
}

func TestMigrationV062RepositoryRootAdmission(t *testing.T) {
	bd := buildEmbeddedBD(t)
	const projectID = "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"

	tests := []struct {
		name      string
		rootArg   func(t *testing.T, target string) string
		projectID bool
		wantError string
	}{
		{
			name:      "requires_project_id",
			rootArg:   func(_ *testing.T, target string) string { return target },
			wantError: "Error: --migration-v062-repository-root requires --migration-v062-project-id\n",
		},
		{
			name:      "rejects_explicit_empty_root",
			rootArg:   func(_ *testing.T, _ string) string { return "" },
			projectID: true,
			wantError: "Error: --migration-v062-repository-root requires an absolute physical Git workspace\n",
		},
		{
			name:      "rejects_relative_root",
			rootArg:   func(_ *testing.T, _ string) string { return "." },
			projectID: true,
			wantError: "Error: --migration-v062-repository-root requires an absolute physical Git workspace\n",
		},
		{
			name: "rejects_symlink_root",
			rootArg: func(t *testing.T, target string) string {
				symlink := filepath.Join(t.TempDir(), "workspace-link")
				if err := os.Symlink(target, symlink); err != nil {
					t.Fatalf("create repository-root symlink: %v", err)
				}
				return symlink
			},
			projectID: true,
			wantError: "Error: --migration-v062-repository-root requires an existing canonical physical Git workspace\n",
		},
		{
			name:      "rejects_non_git_root_before_init",
			rootArg:   func(t *testing.T, _ string) string { return t.TempDir() },
			projectID: true,
			wantError: "Error: --migration-v062-repository-root requires an existing canonical physical Git workspace\n",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			target := t.TempDir()
			initGitRepoAt(t, target)
			args := []string{
				"init", "--quiet", "--non-interactive", "--skip-hooks",
				"--skip-agents", "--prefix", "legacy", "--database", "smoke",
				"--backend=dolt",
			}
			if tt.projectID {
				args = append(args,
					"--"+migrationV062ProjectIDFlagNameForTest, projectID,
				)
			}
			root := tt.rootArg(t, target)
			args = append(args,
				"--"+migrationV062RepositoryRootFlagNameForTest+"="+root,
			)
			snapshotPaths := []string{target}
			if root != "" {
				rootPath := root
				if !filepath.IsAbs(rootPath) {
					rootPath = filepath.Join(target, rootPath)
				}
				if info, err := os.Lstat(rootPath); err == nil && info.Mode()&os.ModeSymlink != 0 {
					rootPath = filepath.Dir(rootPath)
				}
				if filepath.Clean(rootPath) != filepath.Clean(target) {
					snapshotPaths = append(snapshotPaths, rootPath)
				}
			}
			before := make(map[string][sha256.Size]byte, len(snapshotPaths))
			for _, path := range snapshotPaths {
				before[path] = snapshotMigrationV062Tree(t, path)
			}

			cmd := exec.Command(bd, args...)
			cmd.Dir = target
			cmd.Env = bdEnv(target)
			out, err := cmd.CombinedOutput()
			if err == nil {
				t.Fatalf("unsafe migration repository root unexpectedly succeeded:\n%s", out)
			}
			if !strings.Contains(string(out), tt.wantError) {
				t.Fatalf("refusal = %q, want exact line %q", out, tt.wantError)
			}
			for _, path := range snapshotPaths {
				if after := snapshotMigrationV062Tree(t, path); after != before[path] {
					t.Errorf("rejected migration init changed tree %s", path)
				}
			}
			assertMigrationV062InitUntouched(t, target)
		})
	}
}

func snapshotMigrationV062Tree(t *testing.T, root string) [sha256.Size]byte {
	t.Helper()
	hash := sha256.New()
	err := filepath.WalkDir(root, func(path string, _ os.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		_, _ = fmt.Fprintf(hash, "%s\x00%s\x00", rel, info.Mode())
		switch {
		case info.Mode()&os.ModeSymlink != 0:
			target, err := os.Readlink(path)
			if err != nil {
				return err
			}
			_, _ = fmt.Fprintf(hash, "%s\x00", target)
		case info.Mode().IsRegular():
			file, err := os.Open(path)
			if err != nil {
				return err
			}
			_, copyErr := io.Copy(hash, file)
			closeErr := file.Close()
			if copyErr != nil {
				return copyErr
			}
			if closeErr != nil {
				return closeErr
			}
			_, _ = hash.Write([]byte{0})
		}
		return nil
	})
	if err != nil {
		t.Fatalf("snapshot tree %s: %v", root, err)
	}
	var digest [sha256.Size]byte
	copy(digest[:], hash.Sum(nil))
	return digest
}

func assertMigrationV062InitUntouched(t *testing.T, dir string, extra ...string) {
	t.Helper()
	paths := append([]string{
		".beads",
		".dolt",
		".gitignore",
		"AGENTS.md",
		".agents",
		".codex",
	}, extra...)
	for _, rel := range paths {
		path := filepath.Join(dir, rel)
		if _, err := os.Lstat(path); err == nil {
			t.Errorf("rejected migration identity init changed %s", path)
		} else if !os.IsNotExist(err) {
			t.Errorf("stat rejected-init path %s: %v", path, err)
		}
	}
}
