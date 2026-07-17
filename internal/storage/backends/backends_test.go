package backends_test

import (
	"context"
	"errors"
	"maps"
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

func TestProvisionContract(t *testing.T) {
	const name = "provision-fixture"
	wantPersist := map[string]string{"dsn": "fixture://server/db", "schema": "beads_ws"}
	var got backends.ProvisionRequest
	b := fakeBackend()
	b.Provision = func(_ context.Context, req backends.ProvisionRequest) (map[string]string, error) {
		got = req
		return wantPersist, nil
	}
	backends.Register(name, b)
	t.Cleanup(func() { backends.Deregister(name) })

	reg, ok := backends.Lookup(name)
	if !ok || reg.Provision == nil {
		t.Fatalf("Lookup(%q) lost the Provision hook", name)
	}
	req := backends.ProvisionRequest{
		BeadsDir: "/ws/.beads",
		Options:  map[string]string{"schema": "beads_ws"},
	}
	persist, err := reg.Provision(context.Background(), req)
	if err != nil {
		t.Fatalf("Provision: %v", err)
	}
	if got.BeadsDir != req.BeadsDir {
		t.Errorf("ProvisionRequest.BeadsDir = %q, want %q", got.BeadsDir, req.BeadsDir)
	}
	if !maps.Equal(got.Options, req.Options) {
		t.Errorf("ProvisionRequest.Options = %v, want %v", got.Options, req.Options)
	}
	if !maps.Equal(persist, wantPersist) {
		t.Errorf("persist = %v, want %v", persist, wantPersist)
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
