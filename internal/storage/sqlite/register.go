package sqlite

import (
	"context"
	"fmt"
	"path/filepath"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// ProvisionOptionPath is this backend's provisioning option (and persist key)
// for the database file location: relative paths are anchored at the beads
// dir, absolute paths are used as-is. Empty means the default (beads.db).
const ProvisionOptionPath = "path"

// The SQLite backend registers itself at init time. Additional backends
// follow the same pattern: one registrant file like this one, plus a blank
// import in cmd/bd/backends_builtin.go — no shared dispatch code changes.
func init() {
	backends.Register(configfile.BackendSQLite, backends.Backend{
		Open: NewFromConfig,
		// SQLite is file-based with no distinct read-only open path; the
		// same config-driven open serves read-only commands.
		OpenReadOnly: NewFromConfig,
		Provision:    provisionWorkspace,
		// The SQLite database lives directly in the .beads directory
		// (default beads.db): the workspace IS the .beads dir, with no
		// separately discoverable Dolt database directory.
		WorkspaceIsBeadsDir: true,
	})
}

// provisionWorkspace is the backend registry's Provision hook. It resolves
// the database file from the request options (default beads.db; relative
// paths anchored at the beads dir — the same defaulting bd init applied
// before the options contract existed), creates and initializes the
// database, and returns the config entries to persist for later opens.
func provisionWorkspace(ctx context.Context, req backends.ProvisionRequest) (map[string]string, error) {
	relPath := "beads.db"
	for key, value := range req.Options {
		switch key {
		case ProvisionOptionPath:
			if value == "" {
				return nil, fmt.Errorf("sqlite: provisioning option %q must not be empty", key)
			}
			relPath = value
		default:
			return nil, fmt.Errorf("sqlite: unknown provisioning option %q (supported: %s)", key, ProvisionOptionPath)
		}
	}
	dbPath := relPath
	if !filepath.IsAbs(dbPath) {
		dbPath = filepath.Join(req.BeadsDir, dbPath)
	}
	store, err := Provision(ctx, dbPath)
	if err != nil {
		return nil, err
	}
	_ = store.Close()
	return map[string]string{ProvisionOptionPath: relPath}, nil
}
