//go:build cgo

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func bdProxiedImport(t *testing.T, bd, dir string, args ...string) string {
	t.Helper()
	fullArgs := append([]string{"import"}, args...)
	stdout, stderr, err := bdProxiedRunBuffers(t, bd, dir, fullArgs...)
	if err != nil {
		t.Fatalf("bd import %s failed: %v\nstdout:\n%s\nstderr:\n%s",
			strings.Join(args, " "), err, stdout, stderr)
	}
	// import reports on stderr and emits JSON on stdout.
	return stdout + stderr
}

func writeImportFixture(t *testing.T, name string, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
		t.Fatalf("write fixture %s: %v", name, err)
	}
	return path
}

type importJSONReport struct {
	Created         int      `json:"created"`
	Updated         int      `json:"updated"`
	Unchanged       int      `json:"unchanged"`
	Skipped         int      `json:"skipped"`
	Memories        int      `json:"memories"`
	StaleSkippedIDs []string `json:"stale_skipped_ids"`
}

func bdProxiedImportJSON(t *testing.T, bd, dir string, args ...string) importJSONReport {
	t.Helper()
	fullArgs := append([]string{"import", "--json"}, args...)
	stdout, stderr, err := bdProxiedRunBuffers(t, bd, dir, fullArgs...)
	if err != nil {
		t.Fatalf("bd import --json %s failed: %v\nstdout:\n%s\nstderr:\n%s",
			strings.Join(args, " "), err, stdout, stderr)
	}
	var report importJSONReport
	if uerr := json.Unmarshal([]byte(stdout), &report); uerr != nil {
		t.Fatalf("parse import --json output: %v\nstdout:\n%s", uerr, stdout)
	}
	return report
}

// TestProxiedServerImport covers `bd import` on the proxied-server route.
//
// Federation is unavailable in this mode too (#5081), so with `import`
// refusing there was no bulk path for seeding a database opened here from
// another workspace's export. Ordinary server mode has neither refusal; these
// cases pin the proxied route to the same import semantics.
func TestProxiedServerImport(t *testing.T) {
	requireSharedProxiedServer(t)
	t.Parallel()

	bd := buildEmbeddedBD(t)

	t.Run("creates_rows_preserving_ids_and_timestamps", func(t *testing.T) {
		t.Parallel()
		p := newSharedProxiedProject(t, bd, "im")
		fixture := writeImportFixture(t, "seed.jsonl",
			`{"id":"im-seed1","title":"Imported epic","issue_type":"epic","priority":1,"status":"open","labels":["imported"],"created_at":"2026-07-01T10:00:00Z","updated_at":"2026-07-01T10:00:00Z"}`,
			`{"id":"im-seed2","title":"Imported task","priority":2,"status":"open","created_at":"2026-07-02T11:00:00Z","updated_at":"2026-07-02T11:00:00Z","dependencies":[{"issue_id":"im-seed2","depends_on_id":"im-seed1","type":"blocks"}]}`,
			`{"_type":"memory","key":"im-note","value":"imported memory"}`,
		)

		report := bdProxiedImportJSON(t, bd, p.dir, fixture)
		if report.Created != 2 {
			t.Errorf("created = %d, want 2", report.Created)
		}
		if report.Memories != 1 {
			t.Errorf("memories = %d, want 1", report.Memories)
		}

		// The IDs from the JSONL must survive rather than being re-minted:
		// this is what makes an export from another workspace round-trip.
		show := bdProxiedList(t, bd, p)
		for _, want := range []string{"im-seed1", "im-seed2"} {
			if !strings.Contains(show, want) {
				t.Errorf("bd list output missing %s:\n%s", want, show)
			}
		}
	})

	t.Run("reimport_of_identical_snapshot_is_a_no_op", func(t *testing.T) {
		t.Parallel()
		p := newSharedProxiedProject(t, bd, "iq")
		fixture := writeImportFixture(t, "converge.jsonl",
			`{"id":"iq-one","title":"Converge","priority":2,"status":"open","created_at":"2026-07-01T10:00:00Z","updated_at":"2026-07-01T10:00:00Z"}`,
		)

		first := bdProxiedImportJSON(t, bd, p.dir, fixture)
		if first.Created != 1 {
			t.Fatalf("first import created = %d, want 1", first.Created)
		}

		// Re-importing the same snapshot must converge: nothing created,
		// nothing updated. Reporting these as created is the bug this locks
		// down — the stale guard only lists content changes, so absence from
		// its change plan must not be read as "new".
		second := bdProxiedImportJSON(t, bd, p.dir, fixture)
		if second.Created != 0 {
			t.Errorf("second import created = %d, want 0", second.Created)
		}
		if second.Updated != 0 {
			t.Errorf("second import updated = %d, want 0", second.Updated)
		}
		if second.Unchanged != 1 {
			t.Errorf("second import unchanged = %d, want 1", second.Unchanged)
		}
	})

	t.Run("older_rows_are_stale_skipped_unless_allow_stale", func(t *testing.T) {
		t.Parallel()
		p := newSharedProxiedProject(t, bd, "is")
		newer := writeImportFixture(t, "newer.jsonl",
			`{"id":"is-row","title":"Newer title","priority":0,"status":"open","created_at":"2026-07-01T10:00:00Z","updated_at":"2026-07-20T10:00:00Z"}`,
		)
		older := writeImportFixture(t, "older.jsonl",
			`{"id":"is-row","title":"Older title","priority":3,"status":"open","created_at":"2026-07-01T10:00:00Z","updated_at":"2026-07-01T10:00:00Z"}`,
		)

		if got := bdProxiedImportJSON(t, bd, p.dir, newer); got.Created != 1 {
			t.Fatalf("seed import created = %d, want 1", got.Created)
		}

		// Default: the older row loses and is reported, not silently applied.
		stale := bdProxiedImportJSON(t, bd, p.dir, older)
		if stale.Updated != 0 {
			t.Errorf("stale import updated = %d, want 0", stale.Updated)
		}
		if len(stale.StaleSkippedIDs) != 1 || stale.StaleSkippedIDs[0] != "is-row" {
			t.Errorf("stale_skipped_ids = %v, want [is-row]", stale.StaleSkippedIDs)
		}
		if out := bdProxiedList(t, bd, p); !strings.Contains(out, "Newer title") {
			t.Errorf("stale import must not overwrite the newer row:\n%s", out)
		}

		// --allow-stale is the documented restore-an-older-snapshot path.
		restored := bdProxiedImportJSON(t, bd, p.dir, "--allow-stale", older)
		if restored.Updated != 1 {
			t.Errorf("--allow-stale updated = %d, want 1", restored.Updated)
		}
		if out := bdProxiedList(t, bd, p); !strings.Contains(out, "Older title") {
			t.Errorf("--allow-stale should restore the older row:\n%s", out)
		}
	})

	t.Run("dry_run_writes_nothing", func(t *testing.T) {
		t.Parallel()
		p := newSharedProxiedProject(t, bd, "id")
		fixture := writeImportFixture(t, "dry.jsonl",
			`{"id":"id-ghost","title":"Never written","priority":2,"status":"open","created_at":"2026-07-01T10:00:00Z","updated_at":"2026-07-01T10:00:00Z"}`,
		)

		report := bdProxiedImportJSON(t, bd, p.dir, "--dry-run", fixture)
		if report.Created != 1 {
			t.Errorf("dry-run created = %d, want 1 (the would-create count)", report.Created)
		}
		if out := bdProxiedList(t, bd, p); strings.Contains(out, "id-ghost") {
			t.Errorf("dry-run must not write rows:\n%s", out)
		}
	})
}
