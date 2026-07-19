package issueops

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"fmt"
	"strings"
	"time"

	"github.com/steveyegge/beads/internal/storage"
	"github.com/steveyegge/beads/internal/types"
)

// DefaultLeaseTTL is how long a fresh claim stays valid without a heartbeat.
// A worker is expected to call HeartbeatIssueInTx well within this window
// (heartbeat cadence ≫ claim cadence; see the commit-bloat note on bd heartbeat)
// so a live claim's lease_expires_at always sits in the future. A worker that
// dies stops heartbeating, its lease_expires_at goes stale, and bd reclaim
// reverts the issue to ready. Tunable per-claim via WithLeaseTTL on the
// context, falling back to this default.
const DefaultLeaseTTL = 5 * time.Minute

// leaseTTLContextKey overrides DefaultLeaseTTL for a single claim. Used by tests
// (short TTLs) and callers that know their work cadence; unset in normal use.
type leaseTTLContextKey struct{}

// WithLeaseTTL returns a context whose claims use ttl instead of DefaultLeaseTTL.
func WithLeaseTTL(ctx context.Context, ttl time.Duration) context.Context {
	return context.WithValue(ctx, leaseTTLContextKey{}, ttl)
}

// leaseTTL resolves the lease TTL for the current claim/heartbeat.
func leaseTTL(ctx context.Context) time.Duration {
	if ttl, ok := ctx.Value(leaseTTLContextKey{}).(time.Duration); ok && ttl > 0 {
		return ttl
	}
	return DefaultLeaseTTL
}

// explicitLeaseTTL reports whether the caller explicitly requested a lease
// for this claim (WithLeaseTTL) — the opt-in that stamps a lease even when
// automatic stamping is disarmed.
func explicitLeaseTTL(ctx context.Context) (time.Duration, bool) {
	ttl, ok := ctx.Value(leaseTTLContextKey{}).(time.Duration)
	return ttl, ok && ttl > 0
}

// LeaseAutoConfigKey is the store config key governing automatic lease
// stamping on claim. Default (unset/"on") preserves the shipped semantics:
// every claim stamps a DefaultLeaseTTL lease and a supervisor `bd reclaim`
// recovers dead workers. "off" disarms automatic stamping for deployments
// whose recovery authority lives elsewhere (an orchestrator with its own
// liveness evidence): claims carry no lease row — invisible to reclaim —
// and only explicitly requested leases (WithLeaseTTL / --lease-ttl) are
// ever reclaimable. See `bd lease disarm`.
const LeaseAutoConfigKey = "lease.auto"

// autoLeaseEnabled reads the lease.auto store config inside the claim's
// transaction. Unset and unrecognized values default to on (upstream
// semantics unchanged); only an explicit off/false/0 (case-insensitive)
// disarms. A config-read failure is propagated, never guessed: lease.auto is
// a safety knob, and silently arming on a disarmed store would re-create the
// unrequested reclaim exposure disarming removes (while eating the
// serialization aborts withRetryTx exists to replay).
func autoLeaseEnabled(ctx context.Context, tx DBTX) (bool, error) {
	v, err := GetConfigInTx(ctx, tx, LeaseAutoConfigKey)
	if err != nil {
		return false, fmt.Errorf("read %s: %w", LeaseAutoConfigKey, err)
	}
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "off", "false", "0":
		return false, nil
	}
	return true, nil
}

// freshRowLock returns a random non-zero int64 for the row_lock cell.
//
// row_lock is the keystone of dead-worker recovery on Dolt. Dolt has no real
// row locking and merges concurrent commits cell-by-cell, so two transactions
// that touch DIFFERENT cells of the same issue row (a reclaim writing status,
// a close writing closed_at) merge silently instead of conflicting — which
// would let a reclaim quietly revert an issue the owner just closed. By having
// every status/ownership-mutating path rewrite this one shared cell to a fresh
// random value, those writers always collide on row_lock, surfacing the
// 1213/1205 serialization conflict that withRetryTx replays. The value's only
// job is to differ from whatever a concurrent writer wrote, so any source of
// entropy works; we use crypto/rand to avoid seeding concerns. Never 0 (the
// column default) so a freshly-claimed row is always distinguishable from a
// never-touched one.
//
// INVARIANT: any path that mutates status, assignee, or started_at on an
// in_progress issue MUST rewrite row_lock — that is the set the reclaim/close
// races care about (claim, close, updateIssueInTx, reclaim, unclaim all do).
// Paths that touch only orthogonal cells (is_blocked, compaction_level,
// dependency metadata, rename, or reopen — which acts on closed rows) are safe
// to merge with a reclaim and intentionally do NOT rewrite it. Heartbeats and
// lease renewals no longer touch the issues/wisps row at all (bd-lrgn1): the
// lease lives in the ephemeral leases table, where a racing heartbeat and
// reclaim contend on the SAME lease row and conflict without any help. Adding
// a new path that sets status/assignee outside updateIssueInTx without
// rewriting row_lock would silently reintroduce the zombie-merge bug.
func freshRowLock() int64 {
	var b [8]byte
	if _, err := rand.Read(b[:]); err != nil {
		// crypto/rand failing is catastrophic and ~never happens; fall back to a
		// timestamp so the row_lock still changes rather than wedging the write.
		return time.Now().UnixNano() | 1
	}
	v := int64(binary.LittleEndian.Uint64(b[:]))
	if v == 0 {
		v = 1
	}
	return v
}

// RowLockClause returns the SET-clause fragment and arg that rewrite row_lock
// to a fresh value. Append to any UPDATE that mutates status/assignee/
// started_at on an issues row (see the freshRowLock invariant). Exported for
// the proxied-server (uow) claim path in internal/storage/domain/db, which
// builds its own claim UPDATE rather than calling ClaimIssueInTx.
func RowLockClause() (string, []interface{}) {
	return "row_lock = ?", []interface{}{freshRowLock()}
}

// LeaseTTL is the exported form of leaseTTL: it resolves the lease TTL for the
// current claim from the context (WithLeaseTTL) or falls back to
// DefaultLeaseTTL.
func LeaseTTL(ctx context.Context) time.Duration {
	return leaseTTL(ctx)
}

// UpsertLeaseInTx grants or re-grants the lease on an issue to holder: a
// future expiry, a now heartbeat. The lease row lives in the ephemeral leases
// table (dolt_ignored on the Dolt backend, bd-lrgn1), NOT on the issues row,
// so granting or renewing it mints no Dolt commit and no history. Leases are
// deliberately node-local: they are only enforceable on the replica that
// granted them; cross-machine claim VISIBILITY rides status/assignee on the
// issues row, which still commits.
//
// INVARIANT: a leases row exists if and only if its issue is a live claim
// (in_progress with the row's holder as assignee) on this node. Every path
// that ends or transfers a claim — close, unclaim, reclaim, delete, a generic
// update that changes status/assignee, an import that accepts a newer
// non-claimed snapshot — must delete the lease row (DeleteLeaseInTx). Leases
// are tier-complete: wisp-table rows (durable no_history work) lease through
// this same table, keyed on their id.
func UpsertLeaseInTx(ctx context.Context, tx DBTX, id, holder string, now time.Time, ttl time.Duration) error {
	_, err := tx.ExecContext(ctx, `
		INSERT INTO leases (issue_id, holder, granted_at, lease_expires_at, heartbeat_at)
		VALUES (?, ?, ?, ?, ?)
		ON DUPLICATE KEY UPDATE
			holder = VALUES(holder),
			granted_at = VALUES(granted_at),
			lease_expires_at = VALUES(lease_expires_at),
			heartbeat_at = VALUES(heartbeat_at)
	`, id, holder, now, now.Add(ttl), now)
	if err != nil {
		return fmt.Errorf("upsert lease for %s: %w", id, err)
	}
	return nil
}

// ClaimLeaseUpsert grants the lease for a claim that just won its CAS,
// honoring the lease.auto config (see LeaseAutoConfigKey): an explicitly
// requested lease (WithLeaseTTL / --lease-ttl) is always granted with its
// TTL; otherwise automatic stamping grants DefaultLeaseTTL when armed. On a
// disarmed store an unrequested claim gets NO lease — but any stale lease
// row left by a legacy release path is scrubbed, so a later reclaim can
// never key on leftovers. Both claim dispatch layers (issueops.
// ClaimIssueInTx and the proxied-server path in internal/storage/domain/db)
// call this one helper so the grant policy cannot drift between them.
func ClaimLeaseUpsert(ctx context.Context, tx DBTX, id, holder string, now time.Time) error {
	if ttl, explicit := explicitLeaseTTL(ctx); explicit {
		return UpsertLeaseInTx(ctx, tx, id, holder, now, ttl)
	}
	auto, err := autoLeaseEnabled(ctx, tx)
	if err != nil {
		return err
	}
	if auto {
		return UpsertLeaseInTx(ctx, tx, id, holder, now, DefaultLeaseTTL)
	}
	return DeleteLeaseInTx(ctx, tx, id)
}

// DeleteLeaseInTx removes the lease row for an issue, if any. Call from every
// path that ends or transfers a claim (see the UpsertLeaseInTx invariant).
// Deleting a lease that does not exist is a no-op, so callers may invoke it
// unconditionally.
func DeleteLeaseInTx(ctx context.Context, tx DBTX, id string) error {
	if _, err := tx.ExecContext(ctx, `DELETE FROM leases WHERE issue_id = ?`, id); err != nil {
		return fmt.Errorf("delete lease for %s: %w", id, err)
	}
	return nil
}

// RestoreLeaseOnImportInTx reconciles an issue's lease row after an import or
// upsert wrote the issue row. It restores a live claim's lease row when the
// imported snapshot carried one, and drops orphaned local lease rows when the
// accepted state ended or transferred the claim.
func RestoreLeaseOnImportInTx(ctx context.Context, tx DBTX, issue *types.Issue, isNew bool) error {
	now := time.Now().UTC()

	if issue.LeaseExpiresAt != nil {
		var status, assignee string
		err := tx.QueryRowContext(ctx,
			"SELECT status, COALESCE(assignee, '') FROM issues WHERE id = ?", issue.ID,
		).Scan(&status, &assignee)
		if err != nil {
			return fmt.Errorf("read stored row for lease restore of %s: %w", issue.ID, err)
		}
		if status == string(types.StatusInProgress) && assignee != "" {
			grantedAt := now
			heartbeatAt := now
			if issue.HeartbeatAt != nil {
				grantedAt = *issue.HeartbeatAt
				heartbeatAt = *issue.HeartbeatAt
			}
			// Assignment order matters: lease_expires_at is the liveness
			// comparison column and ON DUPLICATE KEY UPDATE assignments are
			// evaluated in order, so it must be reassigned LAST.
			_, err := tx.ExecContext(ctx, `
				INSERT INTO leases (issue_id, holder, granted_at, lease_expires_at, heartbeat_at)
				VALUES (?, ?, ?, ?, ?)
				ON DUPLICATE KEY UPDATE
					holder = IF(leases.lease_expires_at >= ?, leases.holder, VALUES(holder)),
					granted_at = IF(leases.lease_expires_at >= ?, leases.granted_at, VALUES(granted_at)),
					heartbeat_at = IF(leases.lease_expires_at >= ?, leases.heartbeat_at, VALUES(heartbeat_at)),
					lease_expires_at = IF(leases.lease_expires_at >= ?, leases.lease_expires_at, VALUES(lease_expires_at))
			`, issue.ID, assignee, grantedAt, *issue.LeaseExpiresAt, heartbeatAt,
				now, now, now, now)
			if err != nil {
				return fmt.Errorf("restore lease for %s: %w", issue.ID, err)
			}
		}
	}

	if !isNew {
		_, err := tx.ExecContext(ctx, `
			DELETE FROM leases WHERE issue_id = ?
			  AND NOT EXISTS (
				SELECT 1 FROM issues i
				WHERE i.id = ? AND i.status = 'in_progress' AND i.assignee = leases.holder
			  )
		`, issue.ID, issue.ID)
		if err != nil {
			return fmt.Errorf("reconcile lease for %s: %w", issue.ID, err)
		}
	}
	return nil
}

// HeartbeatIssueInTx proves the lease owner is still alive: it pushes
// lease_expires_at forward by the TTL and stamps heartbeat_at = now on the
// issue's lease row. Only the current holder may heartbeat — a heartbeat from
// anyone else, or on an issue whose lease is gone (closed, unclaimed,
// reclaimed), affects no rows and returns storage.ErrNotClaimable /
// ErrAlreadyClaimed so the caller learns its lease is gone.
//
// The write touches ONLY the leases table (ephemeral, dolt_ignored): a
// heartbeat mints no Dolt commit and no history, and deliberately does NOT
// stamp issues.updated_at. Leases are tier-complete: wisp-table claims renew
// through the same lease row, and the disambiguation read routes to the
// correct tier.
//
// Heartbeat is a RENEWAL, not an arming path, on a disarmed store (lease.auto
// off): an owned in_progress row without a lease row is rejected with
// storage.ErrUnleased there — arming a lease as a heartbeat side effect would
// silently re-create the unrequested reclaim exposure disarming exists to
// remove. Under the shipped default (lease.auto on) an owned unleased row is
// a legacy claim from before the lease stack, and the heartbeat arms it,
// converging it into the lease regime (preserved upstream behavior).
//
//nolint:gosec // G201: table names come from WispTableRouting (hardcoded constants)
func HeartbeatIssueInTx(ctx context.Context, tx DBTX, id, actor string) error {
	now := time.Now().UTC()
	result, err := tx.ExecContext(ctx, `
		UPDATE leases SET lease_expires_at = ?, heartbeat_at = ?
		WHERE issue_id = ? AND holder = ?
	`, now.Add(leaseTTL(ctx)), now, id, actor)
	if err != nil {
		return fmt.Errorf("failed to heartbeat issue: %w", err)
	}
	rows, err := result.RowsAffected()
	if err != nil {
		return fmt.Errorf("failed to get rows affected: %w", err)
	}
	if rows == 0 {
		// No lease row changed. Disambiguate from the issue row: gone
		// (closed/reopened/reclaimed), not-found, owned by someone else, or
		// owned-but-unleased.
		isWisp := IsActiveWispInTx(ctx, tx, id)
		issueTable, _, _, _ := WispTableRouting(isWisp)
		var assignee, status string
		qerr := tx.QueryRowContext(ctx,
			fmt.Sprintf("SELECT COALESCE(assignee, ''), status FROM %s WHERE id = ?", issueTable), id,
		).Scan(&assignee, &status)
		if qerr != nil {
			return fmt.Errorf("%w: %s", storage.ErrNotClaimable, id)
		}
		if assignee != "" && assignee != actor {
			return fmt.Errorf("%w by %s", storage.ErrAlreadyClaimed, assignee)
		}
		if assignee == actor && status == string(types.StatusInProgress) {
			// The caller genuinely holds the claim. Either its lease row exists
			// but the UPDATE reported 0 changed rows (a same-second renewal
			// writing identical values), or there is no lease row at all.
			var leased int
			if err := tx.QueryRowContext(ctx,
				"SELECT COUNT(*) FROM leases WHERE issue_id = ? AND holder = ?", id, actor,
			).Scan(&leased); err != nil {
				return fmt.Errorf("read lease row for %s: %w", id, err)
			}
			if leased > 0 {
				// Live lease: renew through the upsert (idempotent).
				return UpsertLeaseInTx(ctx, tx, id, actor, now, leaseTTL(ctx))
			}
			auto, aerr := autoLeaseEnabled(ctx, tx)
			if aerr != nil {
				return aerr
			}
			if !auto {
				return fmt.Errorf("%w: %s", storage.ErrUnleased, id)
			}
			// Legacy unleased claim under lease.auto on: arm it.
			return UpsertLeaseInTx(ctx, tx, id, actor, now, leaseTTL(ctx))
		}
		return fmt.Errorf("%w: %s status %s", storage.ErrNotClaimable, id, status)
	}
	return nil
}

// DisarmLeaseConfigInTx flips the store's lease.auto config to off. Pair with
// ClearArmedLeasesInTx per table inside the same transaction so turning
// stamping off and removing the existing reclaim exposure land together; run
// ClearArmedLeasesInTx again in follow-up transactions until it clears zero
// rows — a claim transaction that read lease.auto before the flip committed
// can stamp a lease that the first sweep's snapshot never saw (disjoint rows,
// so nothing forces a conflict), and the bounded re-sweep is what closes
// that window.
func DisarmLeaseConfigInTx(ctx context.Context, tx DBTX) error {
	if err := SetConfigInTx(ctx, tx, LeaseAutoConfigKey, "off"); err != nil {
		return fmt.Errorf("set %s=off: %w", LeaseAutoConfigKey, err)
	}
	return nil
}

// ClearArmedLeasesInTx deletes the lease row of every in_progress claim in
// the given table without releasing anything: status/assignee are untouched
// and the fence does not move — disarming is lease bookkeeping, not an
// ownership transition. It cannot distinguish explicitly requested leases
// from auto-stamped ones; every armed lease in the table is cleared. A racing
// heartbeat/reclaim contends on the same lease row being deleted and
// conflicts rather than cell-merging.
//
//nolint:gosec // G201: table names come from WispTableRouting (hardcoded constants)
func ClearArmedLeasesInTx(ctx context.Context, tx DBTX, issueTable string) (int64, error) {
	res, err := tx.ExecContext(ctx, fmt.Sprintf(`
		DELETE FROM leases
		WHERE issue_id IN (SELECT id FROM %s WHERE status = 'in_progress')
	`, issueTable))
	if err != nil {
		return 0, fmt.Errorf("disarm leases in %s: %w", issueTable, err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("disarm rows affected: %w", err)
	}
	return n, nil
}

// ReclaimExpiredLeasesInTx reverts in_progress issues whose lease has gone stale
// back to ready: the lease row is deleted, then status → open, assignee cleared,
// started_at cleared, claim_fence bumped, and a fresh row_lock so the reclaim
// conflicts with a racing close/update on the same issues row (see
// freshRowLock). An issue is stale when its lease row's lease_expires_at is
// strictly before cutoff. Callers pass cutoff = now - graceWindow (the
// supervisor uses graceWindow = 2×TTL) so only leases that expired a safe
// margin ago — i.e. workers that are almost certainly dead — are reclaimed.
//
// Leases are node-local (the leases table is dolt_ignored and does not
// replicate), so a reclaim can only recover claims granted through this node —
// which is the only place the lease was ever enforceable anyway.
//
// Reclaim is tier-complete: it sweeps both the permanent issues table and the
// wisps table (which holds durable no_history work), recording recovery
// events in the tier's own event table. Only rows carrying a lease row are
// ever touched — with requested-lease semantics (lease.auto off), unleased
// claims are invisible to the reaper regardless of tier. Each result reports
// the tier and the row's post-bump claim_fence so the previous holder is
// fenced out and callers can project recovery correctly. The caller owns Dolt
// versioning.
func ReclaimExpiredLeasesInTx(ctx context.Context, tx DBTX, cutoff time.Time, actor string) ([]types.ReclaimedLease, error) {
	var reclaimed []types.ReclaimedLease
	for _, tier := range []struct{ issueTable, eventTable string }{
		{"issues", "events"},
		{"wisps", "wisp_events"},
	} {
		got, err := reclaimExpiredInTable(ctx, tx, tier.issueTable, tier.eventTable, cutoff, actor)
		if err != nil {
			return nil, err
		}
		reclaimed = append(reclaimed, got...)
	}
	return reclaimed, nil
}

//nolint:gosec // G201: table names are the hardcoded tier constants above
func reclaimExpiredInTable(ctx context.Context, tx DBTX, issueTable, eventTable string, cutoff time.Time, actor string) ([]types.ReclaimedLease, error) {
	// Snapshot the stale set first so we can report exactly which issues we
	// reverted and record per-issue recovery events. The DELETE below repeats
	// the expiry predicate, so an issue that a concurrent heartbeat rescued
	// between the SELECT and the DELETE is simply skipped (0 rows) — it never
	// appears as reclaimed.
	rows, err := tx.QueryContext(ctx, fmt.Sprintf(`
		SELECT l.issue_id, COALESCE(t.assignee, '') FROM leases l
		JOIN %s t ON t.id = l.issue_id
		WHERE t.status = 'in_progress'
		  AND l.lease_expires_at < ?
	`, issueTable), cutoff)
	if err != nil {
		return nil, fmt.Errorf("scan for stale leases in %s: %w", issueTable, err)
	}
	var stale []types.ReclaimedLease
	for rows.Next() {
		var r types.ReclaimedLease
		if err := rows.Scan(&r.ID, &r.PreviousOwner); err != nil {
			_ = rows.Close()
			return nil, fmt.Errorf("scan stale lease row: %w", err)
		}
		r.Tier = issueTable
		stale = append(stale, r)
	}
	if err := rows.Err(); err != nil {
		_ = rows.Close()
		return nil, fmt.Errorf("iterate stale leases: %w", err)
	}
	if err := rows.Close(); err != nil {
		return nil, fmt.Errorf("close stale lease rows: %w", err)
	}
	if len(stale) == 0 {
		return nil, nil
	}

	var reclaimed []types.ReclaimedLease
	for i := range stale {
		r := &stale[i]
		// Re-check the expiry inside the DELETE so a heartbeat that landed
		// after the snapshot (pushing lease_expires_at back into the future)
		// cannot be clobbered: heartbeat and reclaim contend on this same lease
		// row, so one of a racing pair is forced to retry, and a winning
		// rescuer's pushed-out expiry makes this DELETE match nothing.
		res, err := tx.ExecContext(ctx, `
			DELETE FROM leases WHERE issue_id = ? AND lease_expires_at < ?
		`, r.ID, cutoff)
		if err != nil {
			return nil, fmt.Errorf("reclaim %s: %w", r.ID, err)
		}
		n, err := res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("reclaim %s rows affected: %w", r.ID, err)
		}
		if n == 0 {
			continue // rescued by a concurrent heartbeat — leave it be
		}
		// Revert the issue itself. status is re-checked so a row that stopped
		// being in_progress under us (closed) is left alone; row_lock makes a
		// concurrent close/update conflict at commit time rather than
		// cell-merge with this write. The reclaim is an ownership transition,
		// so it bumps claim_fence (fence⇒row_lock pairing satisfied in the
		// same statement).
		res, err = tx.ExecContext(ctx, fmt.Sprintf(`
			UPDATE %s
			SET status = 'open', assignee = NULL, started_at = NULL,
			    claim_fence = claim_fence + 1,
			    updated_at = ?, row_lock = ?
			WHERE id = ? AND status = 'in_progress'
		`, issueTable), time.Now().UTC(), freshRowLock(), r.ID)
		if err != nil {
			return nil, fmt.Errorf("reclaim %s: %w", r.ID, err)
		}
		n, err = res.RowsAffected()
		if err != nil {
			return nil, fmt.Errorf("reclaim %s rows affected: %w", r.ID, err)
		}
		if n == 0 {
			continue // no longer in_progress — its lease row was stale anyway
		}
		// Report the post-bump fence so the caller holds the value that fences
		// out the previous holder.
		if err := tx.QueryRowContext(ctx, fmt.Sprintf(
			`SELECT claim_fence FROM %s WHERE id = ?`, issueTable), r.ID).Scan(&r.Fence); err != nil {
			return nil, fmt.Errorf("read post-reclaim fence for %s: %w", r.ID, err)
		}
		if err := RecordFullEventInTable(ctx, tx, eventTable, r.ID, types.EventLeaseReclaimed, actor,
			r.PreviousOwner, ""); err != nil {
			return nil, fmt.Errorf("record reclaim event for %s: %w", r.ID, err)
		}
		reclaimed = append(reclaimed, *r)
	}
	return reclaimed, nil
}
