package main

// Extension-contract tests for the backend registry: registering a backend
// by name (one additive registrant file in a real extension) is enough for
// the metadata-driven store factories and the workspace-discovery predicate
// to dispatch to it, with no edits to shared dispatch code.

import (
	"context"
	"errors"
	"maps"
	"testing"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/storage/backends"
	"github.com/steveyegge/beads/internal/storage/sqlite"
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

// TestRegisteredBackendProvisionOptionsAndPersistRoundTrip pins the generic
// provisioning contract: options reach the registrant's Provision hook via
// ProvisionRequest untouched, and the persist entries it returns land in
// metadata.json's backend_config map and survive a reload.
func TestRegisteredBackendProvisionOptionsAndPersistRoundTrip(t *testing.T) {
	const name = "contractkv-provision"
	wantPersist := map[string]string{"dsn": "contract://server/db", "schema": "beads_ws"}
	var got backends.ProvisionRequest
	b := backends.Backend{
		Open: func(context.Context, string) (storage.DoltStorage, error) {
			return nil, errContractOpen
		},
		OpenReadOnly: func(context.Context, string) (storage.DoltStorage, error) {
			return nil, errContractOpenReadOnly
		},
		Provision: func(_ context.Context, req backends.ProvisionRequest) (map[string]string, error) {
			got = req
			return wantPersist, nil
		},
	}
	backends.Register(name, b)
	t.Cleanup(func() { backends.Deregister(name) })

	beadsDir := t.TempDir()
	options := map[string]string{"dsn": "contract://server/db", "schema": "beads_ws"}

	reg, ok := backends.Lookup(name)
	if !ok || reg.Provision == nil {
		t.Fatalf("Lookup(%q) lost the Provision hook", name)
	}
	persist, err := reg.Provision(t.Context(), backends.ProvisionRequest{BeadsDir: beadsDir, Options: options})
	if err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if got.BeadsDir != beadsDir {
		t.Errorf("ProvisionRequest.BeadsDir = %q, want %q", got.BeadsDir, beadsDir)
	}
	if !maps.Equal(got.Options, options) {
		t.Errorf("ProvisionRequest.Options = %v, want %v", got.Options, options)
	}

	// Persist plumbing: init records the returned entries via
	// applyBackendPersist; they must round-trip through metadata.json.
	cfg := configfile.DefaultConfig()
	cfg.Backend = name
	applyBackendPersist(cfg, name, persist)
	if err := cfg.Save(beadsDir); err != nil {
		t.Fatalf("save metadata.json: %v", err)
	}
	loaded, err := configfile.Load(beadsDir)
	if err != nil {
		t.Fatalf("reload metadata.json: %v", err)
	}
	if !maps.Equal(loaded.GetBackendConfig(), wantPersist) {
		t.Errorf("backend_config round-trip = %v, want %v", loaded.GetBackendConfig(), wantPersist)
	}
	if loaded.SQLitePath != "" {
		t.Errorf("non-sqlite persist leaked into legacy sqlite_path: %q", loaded.SQLitePath)
	}
}

// TestApplyBackendPersistSQLiteLegacyPath pins the compatibility mapping: the
// sqlite backend's path entry is persisted in the legacy sqlite_path field
// (not backend_config) so existing workspaces and older bd versions keep
// reading the same location.
func TestApplyBackendPersistSQLiteLegacyPath(t *testing.T) {
	cfg := configfile.DefaultConfig()
	applyBackendPersist(cfg, configfile.BackendSQLite, map[string]string{sqlite.ProvisionOptionPath: "custom.db"})
	if cfg.SQLitePath != "custom.db" {
		t.Errorf("SQLitePath = %q, want %q", cfg.SQLitePath, "custom.db")
	}
	if len(cfg.BackendConfig) != 0 {
		t.Errorf("sqlite path entry leaked into backend_config: %v", cfg.BackendConfig)
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
		// The DSN-redacting dedicated init paths are the secrets guarantee
		// for postgres/mysql: metadata.json only ever gets password-free
		// DSNs. Any future registry Provision hook for them must redact
		// before returning persist entries — until then, nil is the pin.
		if name != configfile.BackendSQLite && b.Provision != nil {
			t.Errorf("built-in backend %q must not have a registry Provision hook (provisioning goes through its dedicated DSN-redacting init path)", name)
		}
	}
}
