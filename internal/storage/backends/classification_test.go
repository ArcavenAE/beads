package backends_test

import (
	"testing"

	"github.com/steveyegge/beads/internal/configfile"
	"github.com/steveyegge/beads/internal/storage/backends"
)

// These tests pin the classification contract in internal/configfile: a name
// registered in the backend registry is honored by GetBackend as-is (this is
// what lets an out-of-tree registrant's name dispatch without editing shared
// files), while unregistered unknown names keep the historical fail-safe
// fallback to Dolt.

func TestRegisteredCustomNameIsHonored(t *testing.T) {
	const name = "customkv"
	cfg := &configfile.Config{Backend: name}
	if got := cfg.GetBackend(); got != configfile.BackendDolt {
		t.Fatalf("unregistered custom name should keep the historical Dolt fallback, got %q", got)
	}

	backends.Register(name, fakeBackend())
	t.Cleanup(func() { backends.Deregister(name) })

	if got := cfg.GetBackend(); got != name {
		t.Errorf("GetBackend() = %q, want registered name %q", got, name)
	}
}

func TestDeregisteredNameRevertsToDoltFallback(t *testing.T) {
	const name = "customkv-transient"
	backends.Register(name, fakeBackend())
	cfg := &configfile.Config{Backend: name}
	if got := cfg.GetBackend(); got != name {
		t.Fatalf("registered name must be honored, got %q", got)
	}
	backends.Deregister(name)
	if got := cfg.GetBackend(); got != configfile.BackendDolt {
		t.Errorf("GetBackend() after deregistration = %q, want Dolt fallback", got)
	}
}

func TestBuiltinNamesNeedNoRegistration(t *testing.T) {
	// The built-in SQL-family names classify by the literal switch, not the
	// registry: configfile's own tests (and any importer that doesn't blank-
	// import the registrants) must see identical classification to cmd/bd.
	for _, name := range []string{configfile.BackendPostgres, configfile.BackendMySQL, configfile.BackendSQLite} {
		cfg := &configfile.Config{Backend: name}
		if got := cfg.GetBackend(); got != name {
			t.Errorf("GetBackend(%q) = %q, want the name itself without registration", name, got)
		}
	}
}
