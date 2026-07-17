package sqlite

import (
	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// The SQLite backend registers itself at init time. Additional backends
// follow the same pattern: one registrant file like this one, plus a blank
// import in cmd/bd/backends_builtin.go — no shared dispatch code changes.
func init() {
	backends.Register(configfile.BackendSQLite, backends.Backend{
		Open: NewFromConfig,
		// SQLite is file-based with no distinct read-only open path; the
		// same config-driven open serves read-only commands.
		OpenReadOnly: NewFromConfig,
		Provision:    Provision,
		// The SQLite database lives directly in the .beads directory
		// (default beads.db): the workspace IS the .beads dir, with no
		// separately discoverable Dolt database directory.
		WorkspaceIsBeadsDir: true,
	})
}
