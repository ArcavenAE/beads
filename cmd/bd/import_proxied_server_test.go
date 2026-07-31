package main

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/steveyegge/beads/internal/types"
)

// fakeIssuesByIDReader answers GetIssuesByIDs from a fixed set, which is the
// only capability the import classification path needs.
type fakeIssuesByIDReader struct {
	stored map[string]*types.Issue
	calls  int
}

func (f *fakeIssuesByIDReader) GetIssuesByIDs(_ context.Context, ids []string) ([]*types.Issue, error) {
	f.calls++
	out := make([]*types.Issue, 0, len(ids))
	for _, id := range ids {
		if issue, ok := f.stored[id]; ok {
			out = append(out, issue)
		}
	}
	return out, nil
}

func ts(s string) time.Time {
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return t
}

// TestExistingImportIDs_DecidesCreateVsUpdateByExistence locks in the fix for
// the create/update misclassification: filterStaleImportIssues only records a
// row in its change plan when the content differs, so an identical re-import
// leaves surviving rows absent from Updates. Inferring "new" from that absence
// reported every row of a converged re-import as created. Existence must come
// from the database.
func TestExistingImportIDs_DecidesCreateVsUpdateByExistence(t *testing.T) {
	reader := &fakeIssuesByIDReader{stored: map[string]*types.Issue{
		"bd-exists": {ID: "bd-exists", Title: "stored", UpdatedAt: ts("2026-07-01T10:00:00Z")},
	}}

	incoming := []*types.Issue{
		{ID: "bd-exists", Title: "stored", UpdatedAt: ts("2026-07-01T10:00:00Z")},
		{ID: "bd-new", Title: "fresh", UpdatedAt: ts("2026-07-01T10:00:00Z")},
	}

	existing, err := existingImportIDs(context.Background(), reader, incoming)
	if err != nil {
		t.Fatalf("existingImportIDs: %v", err)
	}
	if _, ok := existing["bd-exists"]; !ok {
		t.Error("bd-exists should be reported as already present")
	}
	if _, ok := existing["bd-new"]; ok {
		t.Error("bd-new must not be reported as present")
	}
	if len(existing) != 1 {
		t.Errorf("existing = %d entries, want 1", len(existing))
	}
}

// TestExistingImportIDs_DedupesAndSkipsBlankIDs guards the lookup against a
// JSONL batch that repeats an ID or carries title-only rows: neither should
// produce duplicate lookup keys or a query for the empty string.
func TestExistingImportIDs_DedupesAndSkipsBlankIDs(t *testing.T) {
	reader := &fakeIssuesByIDReader{stored: map[string]*types.Issue{}}
	incoming := []*types.Issue{
		{ID: "bd-dup", Title: "one"},
		{ID: "bd-dup", Title: "one again"},
		{ID: "", Title: "no id at all"},
		nil,
	}

	existing, err := existingImportIDs(context.Background(), reader, incoming)
	if err != nil {
		t.Fatalf("existingImportIDs: %v", err)
	}
	if len(existing) != 0 {
		t.Errorf("existing = %d, want 0 (store is empty)", len(existing))
	}
	if reader.calls != 1 {
		t.Errorf("GetIssuesByIDs called %d times, want 1", reader.calls)
	}
}

// TestExistingImportIDs_EmptyBatchSkipsTheQuery keeps a no-op import from
// issuing a pointless lookup.
func TestExistingImportIDs_EmptyBatchSkipsTheQuery(t *testing.T) {
	reader := &fakeIssuesByIDReader{stored: map[string]*types.Issue{}}
	existing, err := existingImportIDs(context.Background(), reader, nil)
	if err != nil {
		t.Fatalf("existingImportIDs: %v", err)
	}
	if len(existing) != 0 {
		t.Errorf("existing = %d, want 0", len(existing))
	}
	if reader.calls != 0 {
		t.Errorf("GetIssuesByIDs called %d times for an empty batch, want 0", reader.calls)
	}
}

// TestFilterStaleImportIssues_ThroughNarrowedReader is the regression guard for
// narrowing filterStaleImportIssues from storage.DoltStorage to
// issuesByIDReader: the proxied-server path reuses this guard through its unit
// of work, so the stale/tie semantics must hold when driven by a reader that is
// not a full store.
func TestFilterStaleImportIssues_ThroughNarrowedReader(t *testing.T) {
	local := ts("2026-07-10T10:00:00Z")
	reader := &fakeIssuesByIDReader{stored: map[string]*types.Issue{
		"bd-older":   {ID: "bd-older", Title: "stored", Priority: 1, UpdatedAt: local},
		"bd-newer":   {ID: "bd-newer", Title: "stored", Priority: 1, UpdatedAt: local},
		"bd-tie":     {ID: "bd-tie", Title: "stored", Priority: 1, UpdatedAt: local},
		"bd-samerow": {ID: "bd-samerow", Title: "identical", Priority: 1, UpdatedAt: local},
	}}

	incoming := []*types.Issue{
		// older than stored: dropped and reported stale
		{ID: "bd-older", Title: "incoming", Priority: 2, UpdatedAt: local.Add(-time.Hour)},
		// strictly newer with different content: an update
		{ID: "bd-newer", Title: "incoming", Priority: 2, UpdatedAt: local.Add(time.Hour)},
		// equal timestamp, different content: local wins the tie
		{ID: "bd-tie", Title: "incoming", Priority: 2, UpdatedAt: local},
		// equal timestamp, identical content: neither update nor tie
		{ID: "bd-samerow", Title: "identical", Priority: 1, UpdatedAt: local},
	}

	filtered, staleSkipped, plan, err := filterStaleImportIssues(context.Background(), reader, incoming)
	if err != nil {
		t.Fatalf("filterStaleImportIssues: %v", err)
	}

	if len(staleSkipped) != 1 || staleSkipped[0] != "bd-older" {
		t.Errorf("staleSkipped = %v, want [bd-older]", staleSkipped)
	}
	for _, issue := range filtered {
		if issue.ID == "bd-older" {
			t.Error("bd-older must not survive the filter")
		}
	}
	if len(plan.Updates) != 1 || plan.Updates[0].ID != "bd-newer" {
		t.Errorf("plan.Updates = %+v, want one entry for bd-newer", plan.Updates)
	}
	if len(plan.TieKeptLocal) != 1 || plan.TieKeptLocal[0] != "bd-tie" {
		t.Errorf("plan.TieKeptLocal = %v, want [bd-tie]", plan.TieKeptLocal)
	}
	// The identical row is in neither list: it is the "unchanged" case the
	// proxied path reports separately from created and updated.
	for _, change := range plan.Updates {
		if change.ID == "bd-samerow" {
			t.Error("an identical row must not be classified as an update")
		}
	}
}

// TestParseImportJSONL_SharedWireSemantics locks in the extraction of the
// parser: the proxied path must consume exactly the semantics the store-backed
// path always had — provenance header skipped, memory records split out,
// tombstones dropped, the legacy wisp alias honored.
func TestParseImportJSONL_SharedWireSemantics(t *testing.T) {
	in := strings.Join([]string{
		`{"_schema":"beads-jsonl/1","_dolt_branch":"main","_sort":"stable-v1"}`,
		`{"_type":"memory","key":"note","value":"remembered"}`,
		`{"id":"bd-1","title":"kept"}`,
		`{"id":"bd-dead","title":"gone","status":"tombstone"}`,
		`{"id":"bd-wisp","title":"legacy wisp","wisp":true}`,
		``,
	}, "\n")

	issues, memories, err := parseImportJSONL(strings.NewReader(in))
	if err != nil {
		t.Fatalf("parseImportJSONL: %v", err)
	}

	if len(memories) != 1 || memories[0].Key != "note" || memories[0].Value != "remembered" {
		t.Errorf("memories = %+v, want one note/remembered record", memories)
	}
	if len(issues) != 2 {
		t.Fatalf("issues = %d, want 2 (header, tombstone excluded)", len(issues))
	}
	byID := map[string]*types.Issue{}
	for _, issue := range issues {
		byID[issue.ID] = issue
	}
	if _, ok := byID["bd-dead"]; ok {
		t.Error("tombstone row must be dropped")
	}
	if got, ok := byID["bd-wisp"]; !ok || !got.Ephemeral {
		t.Errorf(`legacy "wisp":true must set Ephemeral, got %+v`, got)
	}
	if _, ok := byID["bd-1"]; !ok {
		t.Error("bd-1 should be parsed")
	}
}

// TestParseImportJSONL_RejectsMalformedLines keeps the parser loud: a corrupt
// line must fail the import rather than silently importing a partial batch.
func TestParseImportJSONL_RejectsMalformedLines(t *testing.T) {
	_, _, err := parseImportJSONL(strings.NewReader("{not json}\n"))
	if err == nil {
		t.Fatal("expected an error for a malformed JSONL line")
	}
	if !strings.Contains(err.Error(), "failed to parse JSONL line") {
		t.Errorf("error = %v, want a JSONL parse failure", err)
	}
}
