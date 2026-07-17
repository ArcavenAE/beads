package sqlite

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// The registrant's Provision hook resolves the database file from the generic
// options contract (default beads.db, relative paths anchored at the beads
// dir) and returns the persist entries bd init records in metadata.json.
func TestProvisionWorkspaceOptions(t *testing.T) {
	ctx := context.Background()

	t.Run("default path", func(t *testing.T) {
		beadsDir := t.TempDir()
		persist, err := provisionWorkspace(ctx, backends.ProvisionRequest{BeadsDir: beadsDir})
		if err != nil {
			t.Fatalf("provisionWorkspace: %v", err)
		}
		if got := persist[ProvisionOptionPath]; got != "beads.db" {
			t.Errorf("persist[%q] = %q, want %q", ProvisionOptionPath, got, "beads.db")
		}
		if _, err := os.Stat(filepath.Join(beadsDir, "beads.db")); err != nil {
			t.Errorf("default database file not created: %v", err)
		}
	})

	t.Run("relative path option", func(t *testing.T) {
		beadsDir := t.TempDir()
		persist, err := provisionWorkspace(ctx, backends.ProvisionRequest{
			BeadsDir: beadsDir,
			Options:  map[string]string{ProvisionOptionPath: "custom.db"},
		})
		if err != nil {
			t.Fatalf("provisionWorkspace: %v", err)
		}
		if got := persist[ProvisionOptionPath]; got != "custom.db" {
			t.Errorf("persist[%q] = %q, want %q (relative spelling preserved)", ProvisionOptionPath, got, "custom.db")
		}
		if _, err := os.Stat(filepath.Join(beadsDir, "custom.db")); err != nil {
			t.Errorf("database file not created at option path: %v", err)
		}
	})

	t.Run("absolute path option", func(t *testing.T) {
		abs := filepath.Join(t.TempDir(), "abs.db")
		persist, err := provisionWorkspace(ctx, backends.ProvisionRequest{
			BeadsDir: t.TempDir(),
			Options:  map[string]string{ProvisionOptionPath: abs},
		})
		if err != nil {
			t.Fatalf("provisionWorkspace: %v", err)
		}
		if got := persist[ProvisionOptionPath]; got != abs {
			t.Errorf("persist[%q] = %q, want %q", ProvisionOptionPath, got, abs)
		}
		if _, err := os.Stat(abs); err != nil {
			t.Errorf("database file not created at absolute path: %v", err)
		}
	})

	t.Run("empty path rejected", func(t *testing.T) {
		_, err := provisionWorkspace(ctx, backends.ProvisionRequest{
			BeadsDir: t.TempDir(),
			Options:  map[string]string{ProvisionOptionPath: ""},
		})
		if err == nil || !strings.Contains(err.Error(), "must not be empty") {
			t.Errorf("empty path option: err = %v, want non-empty rejection", err)
		}
	})

	t.Run("unknown option rejected", func(t *testing.T) {
		_, err := provisionWorkspace(ctx, backends.ProvisionRequest{
			BeadsDir: t.TempDir(),
			Options:  map[string]string{"paht": "typo.db"},
		})
		if err == nil || !strings.Contains(err.Error(), "unknown provisioning option") {
			t.Errorf("unknown option: err = %v, want unknown-option rejection", err)
		}
	})
}

// NewFromConfig resolves the database file from the legacy sqlite_path field
// first (existing workspaces), then the generic backend_config path entry.
func TestNewFromConfigBackendConfigFallback(t *testing.T) {
	ctx := context.Background()

	open := func(t *testing.T, cfg *configfile.Config) (string, error) {
		t.Helper()
		beadsDir := t.TempDir()
		if err := cfg.Save(beadsDir); err != nil {
			t.Fatalf("save metadata.json: %v", err)
		}
		st, err := NewFromConfig(ctx, beadsDir)
		if err != nil {
			return beadsDir, err
		}
		if err := st.Close(); err != nil {
			t.Errorf("close store: %v", err)
		}
		return beadsDir, nil
	}

	t.Run("backend_config path used when legacy field empty", func(t *testing.T) {
		beadsDir, err := open(t, &configfile.Config{
			Backend:       configfile.BackendSQLite,
			BackendConfig: map[string]string{ProvisionOptionPath: "fromgeneric.db"},
		})
		if err != nil {
			t.Fatalf("NewFromConfig: %v", err)
		}
		if _, err := os.Stat(filepath.Join(beadsDir, "fromgeneric.db")); err != nil {
			t.Errorf("database not opened at backend_config path: %v", err)
		}
	})

	t.Run("legacy sqlite_path wins over backend_config", func(t *testing.T) {
		beadsDir, err := open(t, &configfile.Config{
			Backend:       configfile.BackendSQLite,
			SQLitePath:    "legacy.db",
			BackendConfig: map[string]string{ProvisionOptionPath: "ignored.db"},
		})
		if err != nil {
			t.Fatalf("NewFromConfig: %v", err)
		}
		if _, err := os.Stat(filepath.Join(beadsDir, "legacy.db")); err != nil {
			t.Errorf("database not opened at legacy sqlite_path: %v", err)
		}
		if _, err := os.Stat(filepath.Join(beadsDir, "ignored.db")); !os.IsNotExist(err) {
			t.Errorf("backend_config path used despite legacy field: stat err = %v", err)
		}
	})
}
