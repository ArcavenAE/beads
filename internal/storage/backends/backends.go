// Package backends provides a name-keyed registry of storage backends.
//
// Additional backends register themselves at init time from their own
// package — one additive registrant file plus a blank import in cmd/bd
// (see cmd/bd/backends_builtin.go) — so adding a backend requires no edits
// to shared dispatch code.
//
// The registry covers backends whose open returns a storage.DoltStorage
// directly (e.g. SQLite). The Dolt family (embedded, server, proxied-server)
// is deliberately not registered: its dispatch involves connection modes,
// credentials, and — for proxied-server — a unit-of-work provider rather
// than a store, so it stays hand-written in cmd/bd.
//
// This package must stay import-light (internal/storage and stdlib only):
// internal/configfile consults the registry for backend classification, and
// registrants typically import internal/configfile, so any heavier imports
// here would create cycles.
package backends

import (
	"context"
	"fmt"
	"sync"

	"github.com/steveyegge/beads/internal/storage"
)

// Backend describes a registered storage backend. All paths receive the
// workspace's .beads directory and resolve backend-specific configuration
// themselves (typically from metadata.json).
type Backend struct {
	// Open opens the workspace's store read-write.
	Open func(ctx context.Context, beadsDir string) (storage.DoltStorage, error)

	// OpenReadOnly opens the workspace's store for read-only commands.
	// File-based backends without a distinct read-only open path may use
	// the same function as Open.
	OpenReadOnly func(ctx context.Context, beadsDir string) (storage.DoltStorage, error)

	// Provision creates and initializes the backend's database for bd init.
	// dbPath is the resolved absolute database location. May be nil for
	// backends that bd init cannot provision.
	Provision func(ctx context.Context, dbPath string) (storage.DoltStorage, error)

	// WorkspaceIsBeadsDir reports that the .beads directory itself is the
	// workspace: there is no separately discoverable database directory, so
	// workspace discovery must treat the .beads directory as the database
	// path instead of searching for one.
	WorkspaceIsBeadsDir bool
}

// doltName is the backend name reserved for the hand-written Dolt dispatch
// in cmd/bd. Registering it would hijack the primary open path.
const doltName = "dolt"

var (
	mu       sync.RWMutex
	registry = make(map[string]Backend)
)

// Register adds a backend under name. It is intended to be called from a
// registrant package's init(). It panics on an empty or reserved name, a
// duplicate registration, or a backend missing its open functions — all of
// which are wiring bugs that must fail at process start, not at first use.
func Register(name string, b Backend) {
	if name == "" {
		panic("backends: Register called with empty backend name")
	}
	if name == doltName {
		panic(fmt.Sprintf("backends: backend name %q is reserved for the built-in Dolt dispatch", name))
	}
	if b.Open == nil || b.OpenReadOnly == nil {
		panic(fmt.Sprintf("backends: backend %q registered without Open/OpenReadOnly", name))
	}
	mu.Lock()
	defer mu.Unlock()
	if _, dup := registry[name]; dup {
		panic(fmt.Sprintf("backends: backend %q registered twice", name))
	}
	registry[name] = b
}

// Deregister removes name from the registry, reporting whether it was
// present. It exists so tests can restore registry state after registering
// fixture backends; production registrants register once from init() and
// never deregister.
func Deregister(name string) bool {
	mu.Lock()
	defer mu.Unlock()
	_, ok := registry[name]
	delete(registry, name)
	return ok
}

// Lookup returns the backend registered under name.
func Lookup(name string) (Backend, bool) {
	mu.RLock()
	defer mu.RUnlock()
	b, ok := registry[name]
	return b, ok
}

// Registered reports whether a backend is registered under name.
func Registered(name string) bool {
	mu.RLock()
	defer mu.RUnlock()
	_, ok := registry[name]
	return ok
}
