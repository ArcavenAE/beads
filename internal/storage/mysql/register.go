package mysql

import (
	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// The MySQL backend registers itself at init time; cmd/bd pulls it in via a
// blank import in backends_builtin.go. See internal/storage/backends for the
// registrant pattern.
func init() {
	backends.Register(configfile.BackendMySQL, backends.Backend{
		Open: NewFromConfig,
		// MySQL has no distinct read-only open mode; a normal open is fine
		// (reads don't mutate, and isolation is by database).
		OpenReadOnly: NewFromConfig,
		// Provisioning stays on bd init's dedicated MySQL path
		// (--mysql-url/--mysql-database): it validates the DSN, provisions
		// the database, and redacts credentials before persisting. Nil here
		// means the registry cannot provision this backend.
		Provision: nil,
		// The workspace is the .beads directory itself (metadata.json plus
		// a remote server); there is no local database directory to
		// discover.
		WorkspaceIsBeadsDir: true,
	})
}
