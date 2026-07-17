package main

import (
	"context"
	"fmt"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/storage/backends"
	"github.com/steveyegge/beads/internal/storage/dolt"
)

// This file holds the build-agnostic metadata-driven store selection shared
// by CGO and non-CGO builds. Registered backends (SQLite, PostgreSQL, MySQL —
// see backends_builtin.go) dispatch through the backend registry; the Dolt
// family stays literal below. The proxied-server arm is special-cased because
// it must produce a unit-of-work provider, not a store — the registry is for
// storage.DoltStorage-returning backends only. Only the embedded-Dolt open
// differs per build: see openEmbeddedStoreFromConfig /
// openEmbeddedReadOnlyStoreFromConfig in store_factory.go (CGO) and
// store_factory_nocgo.go (non-CGO).
//
// Unknown backend names keep their historical semantics: GetBackend resolves
// them to the Dolt default, so a name nobody registered falls through to the
// Dolt arms exactly as before the registry existed.

// newDoltStoreFromConfig creates a storage backend from the beads directory's
// persisted metadata.json configuration. Uses embedded Dolt by default;
// connects to dolt sql-server when dolt_mode is "server".
func newDoltStoreFromConfig(ctx context.Context, beadsDir string) (storage.DoltStorage, error) {
	cfg, err := configfile.Load(beadsDir)
	if err != nil {
		// A present-but-unloadable metadata.json must not degrade to the
		// embedded default: on server-mode deployments the embedded
		// directory is an empty relic, and opening it silently turns every
		// query into an empty result set with exit 0 (false-empty). Absent
		// metadata.json (cfg == nil, err == nil) keeps the embedded default.
		return nil, fmt.Errorf("load %s: %w (refusing to fall back to the embedded store)", configfile.ConfigPath(beadsDir), err)
	}
	if b, ok := backends.Lookup(cfg.GetBackend()); ok {
		return b.Open(ctx, beadsDir)
	}
	if cfg != nil && cfg.IsDoltProxiedServerMode() {
		// TODO: this needs to be uow provider
		return nil, fmt.Errorf("proxy server store should be uow provider")
	}
	if cfg != nil && cfg.IsDoltServerMode() {
		return dolt.NewFromConfig(ctx, beadsDir)
	}
	return openEmbeddedStoreFromConfig(ctx, beadsDir, cfg)
}

// newReadOnlyStoreFromConfig creates a read-only storage backend from the beads
// directory's persisted metadata.json configuration.
func newReadOnlyStoreFromConfig(ctx context.Context, beadsDir string) (storage.DoltStorage, error) {
	cfg, err := configfile.Load(beadsDir)
	if err != nil {
		// Same contract as newDoltStoreFromConfig: a present-but-unloadable
		// metadata.json is a hard error, not a silent embedded fallback —
		// and the error must name the real cause rather than the downstream
		// "database not found" the embedded open would produce.
		return nil, fmt.Errorf("load %s: %w (refusing to fall back to the embedded store)", configfile.ConfigPath(beadsDir), err)
	}
	if b, ok := backends.Lookup(cfg.GetBackend()); ok {
		return b.OpenReadOnly(ctx, beadsDir)
	}
	if cfg != nil && cfg.IsDoltProxiedServerMode() {
		// TODO: this needs to be uow provider
		return nil, fmt.Errorf("proxy server store needs to be uow provider")
	}
	if cfg != nil && cfg.IsDoltServerMode() {
		return dolt.NewFromConfigWithOptions(ctx, beadsDir, &dolt.Config{ReadOnly: true})
	}
	return openEmbeddedReadOnlyStoreFromConfig(ctx, beadsDir, cfg)
}
