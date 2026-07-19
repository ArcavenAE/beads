---
title: Upgrading
description: Upgrade the bd binary, refresh git hooks, run schema migrations, and handle remote-backed and cross-era databases
---

How to upgrade bd and keep your projects in sync.

## Checking for Updates

```bash
# Current version
bd version

# What's new in recent versions
bd info --whats-new
bd info --whats-new --json  # Machine-readable
```

## Short Version

1. With your current `bd`, sync remote-backed databases before installing the
   new binary:
   `bd dolt push`
   `bd dolt pull`
2. Back up before migration:
   `bd export --all -o .beads/backup/pre-migrate-$(date +%Y%m%d).jsonl`
3. Upgrade using the command that matches your install method.
4. After upgrading:
   `bd info --whats-new`
   `bd hooks install`
   `bd version`
5. If crossing a schema migration on a remote-backed database, only the
   designated migrator runs:
   `bd migrate --force`
   `bd dolt push`

Other clones should install the new binary and run `bd bootstrap`, not
independently migrate. The full procedure is below.

## Upgrading

Use the command that matches your install method.

| Install method | Platforms | Command |
|---|---|---|
| Quick install script | macOS, Linux, FreeBSD | `curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh \| bash` |
| PowerShell installer | Windows | `irm https://raw.githubusercontent.com/gastownhall/beads/main/install.ps1 \| iex` |
| Homebrew | macOS, Linux | `brew upgrade beads` |
| go install (server-mode only) | macOS, Linux, FreeBSD, Windows | `CGO_ENABLED=0 go install github.com/steveyegge/beads/cmd/bd@latest` |
| go install (embedded-capable) | macOS, Linux, Windows | `CGO_ENABLED=1 GOFLAGS=-tags=gms_pure_go go install github.com/steveyegge/beads/cmd/bd@latest` |
| npm | macOS, Linux, Windows | `npm update -g @beads/bd` |
| bun | macOS, Linux, Windows | `bun install -g --trust @beads/bd` |
| From source (Unix shell) | macOS, Linux, FreeBSD | `git pull && make build` |

### Quick install script (macOS/Linux/FreeBSD)

```bash
curl -fsSL https://raw.githubusercontent.com/gastownhall/beads/main/scripts/install.sh | bash
```

### PowerShell installer (Windows)

```pwsh
irm https://raw.githubusercontent.com/gastownhall/beads/main/install.ps1 | iex
```

### Homebrew

```bash
brew upgrade beads
```

{/* Canonical Homebrew tap-migration snippet. The installation page links
    here; keep the two in sync. */}
If you still have the old tap formula installed as `bd`, switch to the
Homebrew core formula:

```bash
brew uninstall bd
brew untap gastownhall/beads 2>/dev/null || true
brew untap steveyegge/beads 2>/dev/null || true
brew install beads
```

### go install

```bash
# Server-mode only
CGO_ENABLED=0 go install github.com/steveyegge/beads/cmd/bd@latest

# Embedded-capable
CGO_ENABLED=1 GOFLAGS=-tags=gms_pure_go go install github.com/steveyegge/beads/cmd/bd@latest
```

### From Source

```bash
cd beads
git pull
make build
sudo mv bd /usr/local/bin/
```

## After Upgrading

**Important:** After upgrading, update your hooks:

```bash
# 1. Check what changed
bd info --whats-new

# 2. Update git hooks to match new version
bd hooks install

# 3. Check for any outdated hooks
bd info  # Shows warnings if hooks are outdated

# 4. If using Dolt backend, restart the server
bd dolt stop && bd dolt start
```

**Why update hooks?** Git hooks are versioned with bd. Outdated hooks may miss export refresh, legacy fallback, or safety fixes.

## Database Migrations

After major upgrades, check for database migrations:

```bash
# Inspect migration plan (AI agents)
bd migrate --inspect --json

# Preview migration changes
bd migrate --dry-run

# Apply migrations
bd migrate

# Migrate and clean up old files
bd migrate --yes
```

### Remote-backed databases and multiple clones

`bd` refuses to silently apply pending schema migrations to a database that has
a Dolt remote configured. Migrating more than one clone of a shared remote
independently forks the schema, after which `bd dolt pull` can no longer merge —
the break is silent and, across a primary-key-reshaping migration, unrecoverable
([#4259](https://github.com/gastownhall/beads/issues/4259)). The supported flow
is: one machine migrates and publishes; every other clone re-clones the migrated
database.

This applies to **every** upgrade that crosses a pending migration on a
remote-backed database — the same procedure whether you are moving to a
prerelease or to a stable release.

The gate is **state-aware by default**
([#4516](https://github.com/gastownhall/beads/issues/4516)): before blocking,
`bd` consults the remote's *cached* schema state and

- **auto-migrates** when the remote is at the same schema version as this
  clone — no one has migrated yet, so this clone is a safe first-mover
  (concurrent first-movers converge to identical tables). It reminds you to
  `bd dolt push` afterwards.
- **stops and directs you to adopt** (`bd bootstrap`) when the remote has
  already been migrated by another clone.
- **stops for a human decision** when this clone and the remote applied
  different content for the same migration (a genuine fork), or when the
  remote's schema state cannot be read from the cached ref.

Set `BD_SMART_GATE=0` to opt out and make the gate block unconditionally.
The recipes below are the explicit path and work the same in either mode.

**Important ordering:** once the new binary is installed, a database with
pending migrations is gated on **every** open — `bd dolt push` and `bd dolt
pull` are refused too, not just `bd migrate`. So do all syncing with your
**current** binary, *before* you install the new one.

**Back up before you migrate.** Schema migrations assume the database matches
the shape the previous migrations left behind; real databases sometimes drift
(interrupted writes, tooling bugs, very old bootstraps). A JSONL export is
cheap, issue-complete, and importable by any bd version:

```bash
bd export --all -o .beads/backup/pre-migrate-$(date +%Y%m%d).jsonl
```

`bd export` captures issues, not Dolt history or config — for a full snapshot
also copy the `.beads` directory (or `dolt backup` in server mode) while no
`bd` command is running.

**Single clone (including a solo user with a remote):**

```bash
bd dolt push                              # 1. CURRENT binary: publish all local work
bd export --all -o .beads/backup/pre-migrate.jsonl   # 2. backup (see above)
# 3. install the new binary (see Upgrading above)
bd migrate --force                        # 4. migrate as the designated migrator
bd dolt push                              # 5. publish the migrated schema
bd version                                # 6. confirm the new version is active
```

`--force` confirms you are the single designated migrator so this run may
migrate the remote-backed database. For scripted or CI use,
`BD_ALLOW_REMOTE_MIGRATE=1 bd migrate` is the env-var equivalent.

**Multiple clones sharing one remote:**

```bash
# 1. With your CURRENT (old) binary, on EVERY clone: publish all work and get in
#    sync, then stop editing until the upgrade is done.
bd dolt push
bd dolt pull

# 2. Designated migrator ONLY: back up, install the new binary, then migrate
#    and publish.
bd export --all -o .beads/backup/pre-migrate.jsonl
bd migrate --force
bd dolt push

# 3. Every OTHER clone: install the new binary, then ADOPT the migrated database.
#    (bd dolt pull is refused here — the clone still has pending migrations — so
#    re-clone instead. Safe because step 1 already pushed all work.)
bd bootstrap
```

`bd bootstrap` replaces the local database, so any work not pushed in step 1 is
lost — that is why step 1 publishes everything first. If a clone was instead
migrated independently and `bd dolt pull` later fails with `cannot merge because
table dependencies has different primary keys in its common ancestor`, the
schema has already forked — follow the recovery playbook:
[the pk-fork-refused runbook](/recovery/init-safety#pk-fork-refused).

<Note>
`bd doctor` includes a migration-content-skew check that flags a forked
schema against the cached remote ref — a useful post-upgrade verification.
It runs in both server and embedded modes.
</Note>

## Cross-era Upgrades

If you're upgrading from a much older version of bd, your project may use a different storage backend. bd has gone through several storage eras:

Identify your installation's era by what lives under `.beads/`:

| Era | Storage layout |
|---|---|
| SQLite (default through v0.49.x; selectable later) | `.beads/beads.db` |
| Dolt server (common/default in v0.50.x-v0.62.x) | `.beads/dolt/` |
| Embedded Dolt (selectable earlier; default from v0.63.x) | `.beads/embeddeddolt/` |

Route by the observed storage layout, not the version alone. Some historical
releases allowed more than one backend.

### From v0.63.3+ embedded-Dolt workspaces

Upgrade the binary and run:

```bash
bd migrate
```

The pinned embedded-era qualification begins at the official v0.63.3 release.
For an embedded layout created by an earlier binary, preserve the matching
binary and a complete `.beads` backup rather than assuming this direct path is
qualified.

If the project was initialized before `bd init` automatically wired git origin
as the Dolt remote, verify the remote after upgrading:

```bash
bd dolt remote list
```

When the list is empty, fix it on the machine whose local database is
authoritative:

```bash
bd export -o .beads/issues.pre-remote.jsonl   # optional issue audit export
bd dolt remote add origin git+ssh://git@github.com/org/repo.git
bd dolt push
```

Commit the resulting `.beads/config.yaml` change so other clones can run
`bd bootstrap` or `bd dolt pull`.

### From v0.50.x-v0.62.x Dolt-server workspaces

Releases in this range commonly used an external Dolt SQL server, including
v0.59-v0.62. Current `bd` refuses to open this storage layout until an explicit
version-specific bridge is used; an ordinary command such as `bd list` will not
convert it automatically.

The refusal is intentional. Opening the server-era layout directly can rewrite
version markers or storage state before the old data has been exported. Do not
delete `.beads/dolt`, remove metadata, or run `bd init` over the only copy.

Before changing binaries:

1. Keep the matching historical `bd` binary and Dolt runtime available.
2. Stop all writes and stop the historical server.
3. Preserve and verify a byte-for-byte copy of the complete `.beads` directory
   before running any extraction command.
4. Restart the historical stack only against a separate working copy, then make
   the release-specific export and any supplemental per-issue snapshots there.
5. Revalidate the sealed rollback copy, and retain it until issue counts,
   fields, comments, labels, and dependency edges have been verified.

#### Qualified v0.62.0 bridge (Linux)

The repository now includes a user-facing bridge for one deliberately narrow
v0.62.0 shape. It accepts exactly the five-record qualification corpus covering
eight features: epic, task, bug, dependency, standalone rich fields, closed
state, label, and comment. A different record count, an unsupported top-level
or nested field, a different historical release, or an unsafe layout is refused
before cutover. This is not yet a general converter for arbitrary v0.62 data.

Stop the historical server and every writer first. Keep checksum-verified copies
of the exact v0.62.0 `bd` binary and Dolt 1.84.0 runtime, then inspect without
workspace effects:

```bash
workspace=$(realpath /path/to/project)
target_bd=$(realpath /path/to/current/bd)
source_bd=$(realpath /path/to/bd-v0.62.0)
source_dolt=$(realpath /path/to/dolt-1.84.0)

./scripts/migrate-v062-server-to-current.sh \
  --inspect --json \
  --workspace "$workspace" \
  --target-bd "$target_bd" \
  --source-bd "$source_bd" \
  --source-dolt "$source_dolt" \
  > /tmp/beads-v062-plan.json

plan=$(jq -er '.plan.digest' /tmp/beads-v062-plan.json)
```

Review the plan, keep the historical server stopped, and explicitly apply that
exact digest:

```bash
./scripts/migrate-v062-server-to-current.sh \
  --apply --yes --json --expect-plan "$plan" \
  --workspace "$workspace" \
  --target-bd "$target_bd" \
  --source-bd "$source_bd" \
  --source-dolt "$source_dolt"
```

Apply retains the complete historical source at
`.beads-v0.62.0-rollback` and publishes the verified embedded target at
`.beads`. It is never automatic. Re-running the same consent-bound plan after
success verifies the receipt-backed target and returns a no-op; an authenticated
interrupted cutover is recovered on retry, while ambiguous state is preserved
for manual recovery.

For other v0.50.x-v0.62.x shapes, keep using the matching historical binary.
The migration CI recipes are qualification infrastructure, not supported
commands for arbitrary databases. A generic `list --json` export is not a
lossless substitute because historical release shapes can omit comments,
labels, or dependency details.

### From v0.30.x-v0.50.x SQLite workspaces

The old binary stored data in SQLite. The new binary uses Dolt.

**Recommended: use the migration script** (requires `sqlite3` and `jq`):

```bash
# Download the script from the beads repo
curl -fsSLO https://raw.githubusercontent.com/gastownhall/beads/main/scripts/migrate-sqlite-to-current.sh
chmod +x migrate-sqlite-to-current.sh

# Run it in your project directory
./migrate-sqlite-to-current.sh
```

The script exports issues, dependencies, and labels from SQLite, handles type normalization, and imports everything into the new Dolt backend.

**Alternative: manual export with the old binary.** Old binaries are always available on [GitHub Releases](https://github.com/gastownhall/beads/releases). Download the version that matches your project, then:

```bash
# 1. Export with the old binary
./bd-old list --json -n 0 --all > .beads/issues.jsonl

# 2. Import with the current binary
bd init --from-jsonl --quiet

# 3. Verify
bd list --all
```

> **Note:** The manual export preserves issue content but not dependencies or labels. Use the migration script for a more complete transfer.

## Troubleshooting Upgrades

### Hooks out of date

```bash
bd hooks install
```

### Database schema changed

```bash
bd migrate --dry-run
bd migrate
```

### Recovery after upgrade

If you need to restore from a backup:

```bash
bd init
bd backup restore [path] --force
```

Or pull from a Dolt remote:

```bash
bd dolt pull
```
