package main

import (
	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// registeredBackendWorkspaceIsBeadsDir reports whether metadata selects a
// registered backend whose workspace IS the .beads directory itself (no
// separately discoverable database directory) — the WorkspaceIsBeadsDir
// discovery capability. Unregistered names, including the Dolt family,
// report false.
func registeredBackendWorkspaceIsBeadsDir(cfg *configfile.Config) bool {
	b, ok := backends.Lookup(cfg.GetBackend())
	return ok && b.WorkspaceIsBeadsDir
}
