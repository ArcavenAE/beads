package backends_test

import (
	"context"
	"errors"
	"testing"

	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/storage/backends"
)

var errFakeOpen = errors.New("fake backend open")

// fakeBackend returns a minimal registrable backend whose open functions
// fail with a recognizable sentinel, proving dispatch without a real store.
func fakeBackend() backends.Backend {
	open := func(ctx context.Context, beadsDir string) (storage.DoltStorage, error) {
		return nil, errFakeOpen
	}
	return backends.Backend{Open: open, OpenReadOnly: open}
}

func TestRegisterAndLookup(t *testing.T) {
	const name = "lookup-fixture"
	backends.Register(name, fakeBackend())
	t.Cleanup(func() { backends.Deregister(name) })

	b, ok := backends.Lookup(name)
	if !ok {
		t.Fatalf("Lookup(%q) = _, false; want registered backend", name)
	}
	if _, err := b.Open(context.Background(), t.TempDir()); !errors.Is(err, errFakeOpen) {
		t.Fatalf("Open dispatched to wrong backend: err = %v, want %v", err, errFakeOpen)
	}
	if !backends.Registered(name) {
		t.Fatalf("Registered(%q) = false, want true", name)
	}
}

func TestLookupUnknownName(t *testing.T) {
	if _, ok := backends.Lookup("no-such-backend"); ok {
		t.Fatal("Lookup of unregistered name unexpectedly succeeded")
	}
	if backends.Registered("no-such-backend") {
		t.Fatal("Registered() reported an unregistered name")
	}
}

func TestDeregister(t *testing.T) {
	const name = "deregister-fixture"
	backends.Register(name, fakeBackend())
	if !backends.Deregister(name) {
		t.Fatalf("Deregister(%q) = false, want true", name)
	}
	if backends.Registered(name) {
		t.Fatalf("backend %q still registered after Deregister", name)
	}
	if backends.Deregister(name) {
		t.Fatalf("second Deregister(%q) = true, want false", name)
	}
}

func TestRegisterPanics(t *testing.T) {
	mustPanic := func(t *testing.T, register func()) {
		t.Helper()
		defer func() {
			if recover() == nil {
				t.Fatal("Register did not panic")
			}
		}()
		register()
	}

	t.Run("duplicate name", func(t *testing.T) {
		const name = "duplicate-fixture"
		backends.Register(name, fakeBackend())
		t.Cleanup(func() { backends.Deregister(name) })
		mustPanic(t, func() { backends.Register(name, fakeBackend()) })
	})

	t.Run("empty name", func(t *testing.T) {
		mustPanic(t, func() { backends.Register("", fakeBackend()) })
	})

	t.Run("reserved dolt name", func(t *testing.T) {
		mustPanic(t, func() { backends.Register("dolt", fakeBackend()) })
	})

	t.Run("missing open functions", func(t *testing.T) {
		mustPanic(t, func() { backends.Register("nil-open-fixture", backends.Backend{}) })
	})
}
