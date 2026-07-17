// Package backendnames is a leaf package holding the set of registered
// storage-backend names. It exists so internal/configfile can classify
// backend names without importing internal/storage/backends (and through it
// the whole storage interface surface): configfile needs only string
// membership, not the typed Backend contract.
//
// The set is written exclusively by internal/storage/backends
// Register/Deregister; nothing else may mutate it, which keeps it in
// lockstep with the typed registry. This package must import nothing but
// the standard library.
package backendnames

import "sync"

var (
	mu    sync.RWMutex
	names = make(map[string]struct{})
)

// Add records name as a registered backend. Called only by
// internal/storage/backends.Register.
func Add(name string) {
	mu.Lock()
	defer mu.Unlock()
	names[name] = struct{}{}
}

// Remove drops name from the set. Called only by
// internal/storage/backends.Deregister.
func Remove(name string) {
	mu.Lock()
	defer mu.Unlock()
	delete(names, name)
}

// Has reports whether a backend is registered under name.
func Has(name string) bool {
	mu.RLock()
	defer mu.RUnlock()
	_, ok := names[name]
	return ok
}
