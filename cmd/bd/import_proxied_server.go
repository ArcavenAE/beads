package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/steveyegge/beads/internal/storage/domain"
	"github.com/steveyegge/beads/internal/storage/uow"
	"github.com/steveyegge/beads/internal/types"
)

// runImportProxiedServer imports a JSONL stream through the proxied-server
// unit-of-work stack.
//
// Refusing import here left no bulk way to seed a database opened in this
// mode from another workspace's export, since federation is unavailable in
// proxied-server mode too (#5081). Ordinary server mode has neither refusal,
// so this closes a gap specific to this mode rather than adding a new
// capability. That JSONL is an interchange surface and not canonical storage
// (#4225) is exactly why this is an explicit operator-run command and not an
// auto-import path.
//
// The wire parse, the stale/tie guard, and the memory-record handling are the
// same code the store-backed path runs (parseImportJSONL,
// filterStaleImportIssues, classifyDryRunImport), so the two modes cannot
// drift on import semantics. What differs is the write: the unit of work has
// no batch upsert, so rows are partitioned into creates and updates and
// applied through IssueUseCase, all inside one transaction that commits once.
func runImportProxiedServer(ctx context.Context, r io.Reader, source string) error {
	if uowProvider == nil {
		return HandleError("proxied-server UOW provider not initialized")
	}

	issues, memories, err := parseImportJSONL(r)
	if err != nil {
		return HandleError("%v", err)
	}

	result := importResultJSON{Source: source, DryRun: importDryRun}

	if importDryRun {
		classification, cerr := uow.RunTxRead(ctx, uowProvider, func(ctx context.Context, uw uow.UnitOfWork) (*ImportResult, error) {
			return classifyDryRunImport(ctx, uw.IssueUseCase(), issues, importAllowStale)
		})
		if cerr != nil {
			return HandleError("dry-run: %v", cerr)
		}
		result.Memories = len(memories)
		result.Created = classification.Created
		result.Updated = classification.Updated
		result.Unchanged = classification.Unchanged
		result.Skipped = classification.Skipped
		result.IDs = classification.ImportedIDs
		result.StaleSkippedIDs = classification.StaleSkippedIDs
		result.UpdatedIssues = classification.UpdatedIssues
		result.TieKeptLocalIDs = classification.TieKeptLocalIDs

		if jsonOutput {
			return outputJSON(result)
		}
		considered := result.Created + result.Updated + result.Unchanged
		fmt.Fprintf(os.Stderr, "Would import %d issues (%d new, %d updated, %d unchanged) and %d memories from %s",
			considered, result.Created, result.Updated, result.Unchanged, len(memories), source)
		if len(result.StaleSkippedIDs) > 0 {
			fmt.Fprintf(os.Stderr, " (%d stale skipped)", len(result.StaleSkippedIDs))
		}
		fmt.Fprintln(os.Stderr)
		return nil
	}

	applied, err := uow.RunTxResult(ctx, uowProvider, func(ctx context.Context, uw uow.UnitOfWork) (*ImportResult, string, error) {
		res, aerr := applyProxiedImport(ctx, uw, issues, memories, importAllowStale)
		if aerr != nil {
			return nil, "", aerr
		}
		msg := fmt.Sprintf("bd import: %d issues", res.Created)
		if res.Updated > 0 {
			msg += fmt.Sprintf(", %d updated", res.Updated)
		}
		if len(memories) > 0 {
			msg += fmt.Sprintf(", %d memories", len(memories))
		}
		return res, msg + " from " + source, nil
	})
	if err != nil {
		return HandleError("import failed: %v", err)
	}

	result.Created = applied.Created
	result.Updated = applied.Updated
	result.Unchanged = applied.Unchanged
	result.Skipped = applied.Skipped
	result.Memories = len(memories)
	result.IDs = applied.ImportedIDs
	result.UpdatedIssues = applied.UpdatedIssues
	result.TieKeptLocalIDs = applied.TieKeptLocalIDs
	result.StaleSkippedIDs = applied.StaleSkippedIDs

	if jsonOutput {
		return outputJSON(result)
	}

	fmt.Fprintf(os.Stderr, "Imported %d issues", result.Created)
	if result.Updated > 0 {
		fmt.Fprintf(os.Stderr, ", updated %d", result.Updated)
	}
	if result.Unchanged > 0 {
		fmt.Fprintf(os.Stderr, ", %d unchanged", result.Unchanged)
	}
	if result.Memories > 0 {
		fmt.Fprintf(os.Stderr, " and %d memories", result.Memories)
	}
	fmt.Fprintf(os.Stderr, " from %s", source)
	if len(result.StaleSkippedIDs) > 0 {
		fmt.Fprintf(os.Stderr, " (%d stale skipped; use --allow-stale to restore older rows)", len(result.StaleSkippedIDs))
	}
	fmt.Fprintln(os.Stderr)
	if len(result.TieKeptLocalIDs) > 0 {
		fmt.Fprintf(os.Stderr, "Kept local state for %d issue(s) with the same updated_at but different content (use --allow-stale to overwrite): %s\n",
			len(result.TieKeptLocalIDs), strings.Join(result.TieKeptLocalIDs, ", "))
	}
	return nil
}

// applyProxiedImport writes one import batch inside an open unit of work.
//
// Ordering matters: every create runs before any dependency edge is added, so
// a batch whose rows reference each other does not depend on JSONL line order.
// Dependency targets missing from both the batch and the database are reported
// as skipped rather than failing the import, matching the store-backed path's
// SkipDependencyValidationErrors behavior.
func applyProxiedImport(ctx context.Context, uw uow.UnitOfWork, issues []*types.Issue, memories []memoryRecord, allowStale bool) (*ImportResult, error) {
	res := &ImportResult{}

	for _, mem := range memories {
		if err := uw.ConfigUseCase().SetConfig(ctx, kvPrefix+memoryPrefix+mem.Key, mem.Value); err != nil {
			return nil, fmt.Errorf("import memory %q: %w", mem.Key, err)
		}
	}

	if len(issues) == 0 {
		return res, nil
	}

	// Stale/tie guard, shared with the store-backed path. Without
	// --allow-stale, rows older than the stored copy are dropped here and
	// reported; equal-timestamp rows keep local columns (bd-hj85c).
	plan := importChangePlan{}
	if !allowStale {
		filtered, staleSkipped, p, err := filterStaleImportIssues(ctx, uw.IssueUseCase(), issues)
		if err != nil {
			return nil, err
		}
		issues = filtered
		res.StaleSkippedIDs = staleSkipped
		res.Skipped = len(staleSkipped)
		res.TieKeptLocalIDs = p.TieKeptLocal
		plan = p
		if len(issues) == 0 {
			return res, nil
		}
	}

	// Create-vs-update must be decided by existence, not by plan.Updates.
	// filterStaleImportIssues only records a row in Updates when its content
	// actually differs, so an identical re-import leaves surviving rows absent
	// from Updates — treating that absence as "new" would re-create every row
	// (and, on a store that upserts, silently report a fresh import as
	// created). Ask the database which IDs it already has.
	existing, err := existingImportIDs(ctx, uw.IssueUseCase(), issues)
	if err != nil {
		return nil, err
	}

	// Rows whose content is unchanged are neither created nor updated; they
	// are reported as unchanged so a converged re-import reads as a no-op.
	// --allow-stale deliberately skips the guard that computes the change
	// list, so in that mode every existing row is rewritten unconditionally —
	// that is the point of restoring a snapshot over newer local state.
	changedByID := make(map[string]struct{}, len(plan.Updates))
	if allowStale {
		for id := range existing {
			changedByID[id] = struct{}{}
		}
	}
	for _, change := range plan.Updates {
		changedByID[change.ID] = struct{}{}
	}
	tieKept := make(map[string]struct{}, len(res.TieKeptLocalIDs))
	for _, id := range res.TieKeptLocalIDs {
		tieKept[id] = struct{}{}
	}

	actor := getActorWithGit()
	inBatch := make(map[string]struct{}, len(issues))
	for _, issue := range issues {
		if issue != nil && issue.ID != "" {
			inBatch[issue.ID] = struct{}{}
		}
	}

	// Pass 1: rows only. Dependencies come after every row exists.
	for _, issue := range issues {
		if issue == nil {
			continue
		}
		if _, exists := existing[issue.ID]; exists {
			// A tie keeps every stored column by contract (bd-hj85c), and an
			// unchanged row has nothing to write: both are no-ops on the row
			// itself, but their aux data still merges in later passes.
			if _, tied := tieKept[issue.ID]; tied {
				res.Unchanged++
				continue
			}
			if _, changed := changedByID[issue.ID]; !changed {
				res.Unchanged++
				continue
			}
			if err := applyProxiedImportUpdate(ctx, uw, issue, actor); err != nil {
				return nil, fmt.Errorf("update %s: %w", issue.ID, err)
			}
			res.Updated++
			continue
		}
		params := domain.CreateIssueParams{
			Issue:                issue,
			ExplicitID:           issue.ID,
			Labels:               issue.Labels,
			ForcePrefix:          true,
			DiscoveredFromParent: "",
		}
		if _, err := uw.IssueUseCase().CreateIssue(ctx, params, actor); err != nil {
			return nil, fmt.Errorf("create %s: %w", issue.ID, err)
		}
		res.Created++
		res.ImportedIDs = append(res.ImportedIDs, issue.ID)
	}

	// Pass 2: dependency edges, now that every row in the batch exists.
	for _, issue := range issues {
		if issue == nil || len(issue.Dependencies) == 0 {
			continue
		}
		for _, dep := range issue.Dependencies {
			target := dep.DependsOnID
			if target == "" {
				continue
			}
			if _, batched := inBatch[target]; !batched {
				if _, err := uw.IssueUseCase().GetIssue(ctx, target); err != nil {
					res.SkippedDependencies = append(res.SkippedDependencies,
						fmt.Sprintf("%s -> %s: target not found", issue.ID, target))
					continue
				}
			}
			depType := dep.Type
			if depType == "" {
				depType = types.DepBlocks
			}
			edge := &types.Dependency{IssueID: issue.ID, DependsOnID: target, Type: depType}
			if err := uw.DependencyUseCase().AddDependency(ctx, edge, actor); err != nil {
				// An edge that already exists is not an import failure:
				// re-importing a snapshot must converge, not error.
				if isAlreadyExistsError(err) {
					continue
				}
				return nil, fmt.Errorf("dependency %s -> %s: %w", issue.ID, target, err)
			}
		}
	}

	// Pass 3: comments, after rows exist so authorship attaches to a real issue.
	for _, issue := range issues {
		if issue == nil || len(issue.Comments) == 0 {
			continue
		}
		for _, c := range issue.Comments {
			if c.Text == "" {
				continue
			}
			author := c.Author
			if author == "" {
				author = actor
			}
			if _, err := uw.CommentUseCase().AddCommentToIssue(ctx, issue.ID, author, c.Text); err != nil {
				return nil, fmt.Errorf("comment on %s: %w", issue.ID, err)
			}
		}
	}

	res.UpdatedIssues = plan.Updates
	return res, nil
}

// existingImportIDs returns the subset of the batch's IDs that already exist,
// so create-vs-update is decided by the database rather than inferred from the
// stale guard's change list.
func existingImportIDs(ctx context.Context, reader issuesByIDReader, issues []*types.Issue) (map[string]struct{}, error) {
	ids := make([]string, 0, len(issues))
	seen := make(map[string]struct{}, len(issues))
	for _, issue := range issues {
		if issue == nil || issue.ID == "" {
			continue
		}
		if _, ok := seen[issue.ID]; ok {
			continue
		}
		seen[issue.ID] = struct{}{}
		ids = append(ids, issue.ID)
	}
	existing := make(map[string]struct{}, len(ids))
	if len(ids) == 0 {
		return existing, nil
	}
	local, err := reader.GetIssuesByIDs(ctx, ids)
	if err != nil {
		return nil, fmt.Errorf("check existing issues before import: %w", err)
	}
	for _, issue := range local {
		if issue != nil && issue.ID != "" {
			existing[issue.ID] = struct{}{}
		}
	}
	return existing, nil
}

// applyProxiedImportUpdate rewrites an existing row from an incoming JSONL
// issue. The guard upstream of this call already decided the row should be
// rewritten; this maps the wire fields onto an UpdateSpec.
func applyProxiedImportUpdate(ctx context.Context, uw uow.UnitOfWork, issue *types.Issue, actor string) error {
	fields := map[string]any{
		"title":       issue.Title,
		"description": issue.Description,
		"status":      string(issue.Status),
		"priority":    issue.Priority,
		"issue_type":  string(issue.IssueType),
	}
	if issue.Design != "" {
		fields["design"] = issue.Design
	}
	if issue.AcceptanceCriteria != "" {
		fields["acceptance_criteria"] = issue.AcceptanceCriteria
	}
	if issue.Notes != "" {
		fields["notes"] = issue.Notes
	}
	if issue.Assignee != "" {
		fields["assignee"] = issue.Assignee
	}
	if issue.Owner != "" {
		fields["owner"] = issue.Owner
	}
	// updated_at is deliberately NOT set: the domain update path force-stamps
	// it to now (db.Update appends its own SET updated_at) and its allow-list
	// rejects the column outright. So a row rewritten by import here carries a
	// fresh updated_at rather than the JSONL value, which differs from the
	// store-backed batch upsert. The divergence is confined to the rewrite
	// path — creates preserve created_at/updated_at exactly, which is what the
	// bootstrap-an-empty-database case relies on — and it is convergent: the
	// next import of the same snapshot classifies the row as stale-skipped
	// rather than silently reapplying it. Preserving the incoming timestamp
	// would mean writing the column outside the domain layer.

	spec := domain.UpdateSpec{Fields: fields}
	if len(issue.Labels) > 0 {
		labels := issue.Labels
		spec.SetLabels = &labels
	}
	_, err := uw.IssueUseCase().ApplyUpdate(ctx, issue.ID, spec, actor)
	return err
}

// isAlreadyExistsError reports whether err is a benign "row/edge is already
// there" result, which makes a repeated import converge instead of failing.
func isAlreadyExistsError(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "already exists") || strings.Contains(msg, "duplicate")
}
