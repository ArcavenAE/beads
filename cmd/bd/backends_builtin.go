package main

// Built-in registry-dispatched storage backends. Each blank import runs the
// package's init(), which registers the backend by name in
// internal/storage/backends. To add a backend, add its registrant package
// here (or in an equivalent file) — no other shared files change.
//
// The Dolt family (embedded, server, proxied-server) is not registered; it
// stays on the hand-written dispatch in store_factory*.go and main.go.
import (
	// MySQL: server backend, isolation by database.
	_ "github.com/steveyegge/beads/internal/storage/mysql"
	// PostgreSQL: server backend, isolation by schema.
	_ "github.com/steveyegge/beads/internal/storage/postgres"
	// SQLite: pure-Go, file-based local backend.
	_ "github.com/steveyegge/beads/internal/storage/sqlite"
)
