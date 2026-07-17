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
// Backend classification in internal/configfile consults the registered
// name set through the backendnames leaf package (mirrored by
// Register/Deregister below), so configfile never imports this package or
// the storage interface surface behind it. Registrants typically import
// internal/configfile for the name constants, so imports here must stay
// light (internal/storage and stdlib) to keep that edge acyclic.
package backends

import (
	"context"
	"fmt"
	"sort"
	"sync"

	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/storage/backendnames"
)

// ProvisionRequest carries the inputs to a backend's Provision hook. It is
// deliberately backend-agnostic: whatever a backend needs beyond the
// workspace location (a file path, a DSN, a schema name, …) arrives as
// options, and their keys and meanings are owned by the backend.
type ProvisionRequest struct {
	// BeadsDir is the workspace's .beads directory.
	BeadsDir string

	// Options are backend-specific provisioning options, typically from
	// repeated `bd init --backend-opt key=value` flags. May be nil.
	Options map[string]string
}

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

	// Provision creates and initializes the backend's database for bd init,
	// resolving whatever it needs from the request options. persist is the
	// set of backend-specific config entries the backend wants recorded in
	// metadata.json for later opens; empty/nil is fine. May be nil for
	// backends that bd init cannot provision.
	//
	// persist entries are written to metadata.json, which is typically
	// committed to git: they must NEVER contain credentials. A backend whose
	// options carry a credentialed DSN must redact it before returning (the
	// dedicated postgres/mysql init paths persist password-free DSNs and
	// resolve secrets from the environment at open time — same rule here).
	Provision func(ctx context.Context, req ProvisionRequest) (persist map[string]string, err error)

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
	// Mirror the name into the leaf name-set so internal/configfile can
	// classify without importing this package (and the storage interface
	// surface behind it). Register/Deregister are the only writers, so the
	// set cannot drift from the registry.
	backendnames.Add(name)
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
	backendnames.Remove(name)
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

// Provisionable returns the sorted names of registered backends that have a
// Provision hook — the set `bd init` can provision through the registry.
// Callers use it to keep user-facing guidance truthful as registrants come
// and go, instead of hardcoding backend names.
func Provisionable() []string {
	mu.RLock()
	defer mu.RUnlock()
	var names []string
	for name, b := range registry {
		if b.Provision != nil {
			names = append(names, name)
		}
	}
	sort.Strings(names)
	return names
}
