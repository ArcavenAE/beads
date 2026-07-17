package main

// Extension-contract tests for the backend registry: registering a backend
// by name (one additive registrant file in a real extension) is enough for
// the metadata-driven store factories and the workspace-discovery predicate
// to dispatch to it, with no edits to shared dispatch code.

import (
	"context"
	"errors"
	"testing"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/storage/backends"
)

var (
	errContractOpen         = errors.New("contract backend: read-write open")
	errContractOpenReadOnly = errors.New("contract backend: read-only open")
)

// registerContractBackend registers a fixture backend whose open functions
// fail with recognizable sentinels, proving dispatch reached the registrant
// without standing up a real store.
func registerContractBackend(t *testing.T, name string) {
	t.Helper()
	backends.Register(name, backends.Backend{
		Open: func(context.Context, string) (storage.DoltStorage, error) {
			return nil, errContractOpen
		},
		OpenReadOnly: func(context.Context, string) (storage.DoltStorage, error) {
			return nil, errContractOpenReadOnly
		},
		WorkspaceIsBeadsDir: true,
	})
	t.Cleanup(func() { backends.Deregister(name) })
}

func writeBackendWorkspace(t *testing.T, backend string) string {
	t.Helper()
	beadsDir := t.TempDir()
	if err := (&configfile.Config{Backend: backend}).Save(beadsDir); err != nil {
		t.Fatalf("save metadata.json: %v", err)
	}
	return beadsDir
}

func TestRegisteredBackendDispatchesThroughStoreFactories(t *testing.T) {
	const name = "contractkv"
	registerContractBackend(t, name)
	beadsDir := writeBackendWorkspace(t, name)

	if _, err := newDoltStoreFromConfig(t.Context(), beadsDir); !errors.Is(err, errContractOpen) {
		t.Errorf("newDoltStoreFromConfig dispatched wrong: err = %v, want %v", err, errContractOpen)
	}
	if _, err := newReadOnlyStoreFromConfig(t.Context(), beadsDir); !errors.Is(err, errContractOpenReadOnly) {
		t.Errorf("newReadOnlyStoreFromConfig dispatched wrong: err = %v, want %v", err, errContractOpenReadOnly)
	}
}

func TestRegisteredBackendDrivesWorkspaceDiscovery(t *testing.T) {
	const name = "contractkv-discovery"
	registerContractBackend(t, name)

	if !registeredBackendWorkspaceIsBeadsDir(&configfile.Config{Backend: name}) {
		t.Error("registered backend with WorkspaceIsBeadsDir must drive discovery")
	}
	// The Dolt family and unregistered names never claim the .beads dir.
	if registeredBackendWorkspaceIsBeadsDir(&configfile.Config{Backend: configfile.BackendDolt}) {
		t.Error("dolt must not claim the .beads dir as workspace")
	}
	if registeredBackendWorkspaceIsBeadsDir(&configfile.Config{Backend: "contract-unregistered"}) {
		t.Error("unregistered name must not claim the .beads dir as workspace")
	}
}

func TestBuiltinBackendsAreRegistered(t *testing.T) {
	// backends_builtin.go's blank imports must register all three SQL-family
	// backends in the bd binary; losing one silently reroutes its workspaces
	// to the Dolt arms.
	for _, name := range []string{configfile.BackendSQLite, configfile.BackendPostgres, configfile.BackendMySQL} {
		b, ok := backends.Lookup(name)
		if !ok {
			t.Errorf("built-in backend %q is not registered", name)
			continue
		}
		if b.Open == nil || b.OpenReadOnly == nil {
			t.Errorf("built-in backend %q missing open functions", name)
		}
		if !b.WorkspaceIsBeadsDir {
			t.Errorf("built-in backend %q must report WorkspaceIsBeadsDir for discovery", name)
		}
	}
}
