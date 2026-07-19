package issueops

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/steveyegge/beads/internal/storage"
)

// RenewLeasesInTx renews the leases named by refs, each keyed on (id, fence),
// in the caller's transaction, returning a typed outcome per ref (in refs
// order). A renewal renews only while the row is in_progress, still leased,
// and its claim_fence still equals the ref's fence — so a claim whose
// ownership moved since the caller's snapshot is reported lost, not silently
// renewed, and an unleased claim is reported unleased rather than armed.
// Tier-aware: each ref routes to issues or wisps for the fence/status check;
// the renewal itself writes only the ephemeral leases table (no Dolt commit,
// see UpsertLeaseInTx), where a racing reclaim contends on the same lease row
// and conflicts.
//
// The caller owns Dolt versioning and chunking (see the store-level
// RenewLeasesChunked, which bounds the per-transaction write set).
func RenewLeasesInTx(ctx context.Context, tx DBTX, refs []storage.LeaseRef, ttl time.Duration) ([]storage.LeaseRenewalResult, error) {
	now := time.Now().UTC()
	if ttl <= 0 {
		ttl = DefaultLeaseTTL
	}

	out := make([]storage.LeaseRenewalResult, 0, len(refs))
	for _, ref := range refs {
		isWisp := IsActiveWispInTx(ctx, tx, ref.ID)
		issueTable, _, _, _ := WispTableRouting(isWisp)

		// Read the row's fence/status in the same transaction. A read error is
		// PROPAGATED, never mapped to an outcome: reporting not_found on a
		// transient/schema-skew read failure would tell the orchestrator a
		// live claim is gone — inviting it to drop or reassign the claim
		// (duplicate execution, the exact failure fencing exists to prevent).
		// The outer write path replays transients via withRetryTx.
		var status string
		var fence int64
		//nolint:gosec // G201: issueTable is a hardcoded routing constant
		err := tx.QueryRowContext(ctx, fmt.Sprintf(
			`SELECT status, claim_fence FROM %s WHERE id = ?`, issueTable), ref.ID).
			Scan(&status, &fence)
		if errors.Is(err, sql.ErrNoRows) {
			out = append(out, storage.LeaseRenewalResult{ID: ref.ID, Outcome: storage.LeaseRenewalNotFound})
			continue
		}
		if err != nil {
			return nil, fmt.Errorf("renew %s: %w", ref.ID, err)
		}
		if fence != ref.Fence || status != "in_progress" {
			out = append(out, storage.LeaseRenewalResult{ID: ref.ID, Outcome: storage.LeaseRenewalLost})
			continue
		}

		res, err := tx.ExecContext(ctx, `
			UPDATE leases SET lease_expires_at = ?, heartbeat_at = ?
			WHERE issue_id = ?
		`, now.Add(ttl), now, ref.ID)
		if err != nil {
			return nil, fmt.Errorf("renew %s: %w", ref.ID, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("renew %s rows affected: %w", ref.ID, err)
		}
		if n == 0 {
			// Either no lease row (unleased claim — never armed here) or a
			// same-second renewal writing identical values (0 changed rows).
			var leased int
			if err := tx.QueryRowContext(ctx,
				`SELECT COUNT(*) FROM leases WHERE issue_id = ?`, ref.ID).Scan(&leased); err != nil {
				return nil, fmt.Errorf("renew %s disambiguation: %w", ref.ID, err)
			}
			if leased == 0 {
				out = append(out, storage.LeaseRenewalResult{ID: ref.ID, Outcome: storage.LeaseRenewalUnleased})
				continue
			}
		}
		out = append(out, storage.LeaseRenewalResult{ID: ref.ID, Outcome: storage.LeaseRenewed})
	}
	return out, nil
}

// CountActiveClaimsByOwnerInTx counts in_progress claims held by owner across
// both tiers.
func CountActiveClaimsByOwnerInTx(ctx context.Context, tx DBTX, owner string) (int, error) {
	total := 0
	for _, table := range []string{"issues", "wisps"} {
		var n int
		//nolint:gosec // G201: table is a hardcoded tier constant
		err := tx.QueryRowContext(ctx, fmt.Sprintf(
			`SELECT COUNT(*) FROM %s WHERE status = 'in_progress' AND assignee = ?`, table), owner).Scan(&n)
		if err != nil {
			return 0, fmt.Errorf("count claims in %s: %w", table, err)
		}
		total += n
	}
	return total, nil
}
