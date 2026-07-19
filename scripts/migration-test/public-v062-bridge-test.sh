#!/usr/bin/env bash
set -euo pipefail

# Test coverage scope
# -------------------
# This harness drives the public v0.62 bridge's apply / crash-injection /
# rollback / idempotency / losslessness matrix against deterministic bash+jq
# fakes (make_fake_bd, make_fake_source_bd, make_fake_source_dolt) that stand in
# for source-bd, source-dolt, and the target-bd. Because the fakes emit real
# ".beads" layouts, the matrix genuinely exercises the bridge's control flow,
# refusal codes, and, most importantly, its filesystem transaction (atomic
# ".beads" renames + inode journal) and crash-recovery behavior. It does NOT
# run a real Dolt import, so a real-Dolt losslessness regression (a dropped
# field, or a mid-cutover real-engine crash) would not turn this matrix red.
#
# Real-Dolt import losslessness is guarded elsewhere, not by this suite:
#   - run.sh's server->embedded strict lane (run_public_v062_bridge) drives the
#     bridge end to end against the real current bd and a real pinned dolt. That
#     lane is happy-path only (no failpoint/SIGKILL injection) and is SKIP-gated
#     when a real dolt runtime is unavailable.
#   - The production bridge fails closed on a lossy real import at runtime: after
#     importing into the embedded target it runs semantics_match against the
#     source and rolls back on mismatch (see migrate-v062-server-to-current.sh),
#     so end users are protected regardless of this suite's mock realism.
#
# Do not read the fake-target assertions below as real-Dolt coverage.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRIDGE="$REPO_ROOT/scripts/migrate-v062-server-to-current.sh"

fail() {
    printf 'public-v062-bridge-test: %s\n' "$*" >&2
    exit 1
}

[ -x "$BRIDGE" ] || fail "missing executable public bridge: $BRIDGE"
command -v jq >/dev/null || fail "jq is required"
command -v script >/dev/null || fail "script is required"

if grep -Fq '"$RM_BIN" -rf -- "$RUNTIME_SCRATCH"' "$BRIDGE" ||
    grep -Fq '"$RM_BIN" -rf -- "$TRANSACTION_ROOT"' "$BRIDGE"; then
    fail "private runtime cleanup must not recursively delete an unauthenticated pathname"
fi

assert_function_has_no_signal_command() {
    local function_name="$1" body
    body=$(awk -v signature="$function_name() {" '
        $0 == signature { capture = 1 }
        capture { print }
        capture && $0 == "}" { exit }
    ' "$BRIDGE") || fail "could not inspect $function_name"
    [ -n "$body" ] || fail "could not find $function_name"
    if grep -Eq '(^|[^[:alnum:]_])kill([[:space:]]|$)' <<< "$body"; then
        fail "$function_name must use identity-aware cooperative waiting, not process signals"
    fi
}

assert_function_has_no_signal_command stop_runtime_guardian
assert_function_has_no_signal_command stop_transaction_guardian

if [ -n "${PUBLIC_V062_REAL_TARGET_BD:-}" ]; then
    REAL_TARGET_BD=$(realpath -e -- "$PUBLIC_V062_REAL_TARGET_BD") ||
        fail "PUBLIC_V062_REAL_TARGET_BD cannot be resolved"
else
    (cd "$REPO_ROOT" && make build >/dev/null) ||
        fail "could not build the real current bd target"
    REAL_TARGET_BD="$REPO_ROOT/bd"
fi
[ -f "$REAL_TARGET_BD" ] && [ -x "$REAL_TARGET_BD" ] ||
    fail "real current bd target is not executable: $REAL_TARGET_BD"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/bd-public-v062-bridge.XXXXXX")

pid_is_running() {
    local pid="$1" stat rest state
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    kill -0 "$pid" 2>/dev/null || return 1
    stat=$(/usr/bin/cat -- "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat#*) }
    state=${rest%% *}
    [ "$state" != Z ]
}

pid_start_time() {
    local pid="$1" stat rest
    local -a fields
    stat=$(/usr/bin/cat -- "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    read -r -a fields <<< "$rest" || return 1
    [ "${#fields[@]}" -ge 20 ] && [ "${fields[0]}" != Z ] || return 1
    printf '%s\n' "${fields[19]}"
}

pid_identity_is_running() {
    local pid="$1" expected_start="$2" actual_start
    pid_is_running "$pid" || return 1
    actual_start=$(pid_start_time "$pid") || return 1
    [ "$actual_start" = "$expected_start" ]
}

terminate_pid_bounded() {
    local pid="$1" attempt
    if ! pid_is_running "$pid"; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    kill -TERM -- "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        pid_is_running "$pid" || break
        sleep 0.025
    done
    if pid_is_running "$pid"; then
        kill -KILL -- "$pid" 2>/dev/null || true
        for ((attempt = 0; attempt < 100; attempt++)); do
            pid_is_running "$pid" || break
            sleep 0.025
        done
    fi
    pid_is_running "$pid" && return 1
    wait "$pid" 2>/dev/null || true
}

terminate_pid_identity_bounded() {
    local pid="$1" start="$2" attempt
    pid_identity_is_running "$pid" "$start" || return 0
    kill -TERM -- "$pid" 2>/dev/null || true
    for ((attempt = 0; attempt < 100; attempt++)); do
        pid_identity_is_running "$pid" "$start" || break
        sleep 0.025
    done
    if pid_identity_is_running "$pid" "$start"; then
        kill -KILL -- "$pid" 2>/dev/null || true
    fi
    pid_identity_is_running "$pid" "$start" && return 1
    wait "$pid" 2>/dev/null || true
}

cleanup() {
    local pids_file identity_file pid start command_line
    if [ -n "${GUARDIAN_TEST_PHASE_DIR:-}" ] &&
        [ -d "$GUARDIAN_TEST_PHASE_DIR" ]; then
        touch \
            "$GUARDIAN_TEST_PHASE_DIR/transaction_guardian_resource_removed.continue" \
            "$GUARDIAN_TEST_PHASE_DIR/runtime_guardian_resource_removed.continue" \
            2>/dev/null || true
    fi
    while IFS= read -r identity_file; do
        while IFS=' ' read -r pid start; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] &&
                [[ "$start" =~ ^[0-9]+$ ]] || continue
            terminate_pid_identity_bounded "$pid" "$start" || true
        done < "$identity_file"
    done < <(find -P "$tmp" -type f \
        -name 'workspace-lock-child.identities*' -print 2>/dev/null)
    if [ -n "${JOURNAL_ZOMBIE_HOLDER_PID:-}" ]; then
        kill -TERM -- "$JOURNAL_ZOMBIE_HOLDER_PID" 2>/dev/null || true
        wait "$JOURNAL_ZOMBIE_HOLDER_PID" 2>/dev/null || true
        JOURNAL_ZOMBIE_HOLDER_PID=""
    fi
    if [ -n "${ASYNC_BRIDGE_PID:-}" ]; then
        terminate_pid_bounded "$ASYNC_BRIDGE_PID" || true
    fi
    for pids_file in "$tmp"/*.pid "$tmp"/*.pids; do
        [ -s "$pids_file" ] || continue
        while IFS= read -r pid; do
            [[ "$pid" =~ ^[1-9][0-9]*$ ]] || continue
            command_line=$(
                /usr/bin/cat -- "/proc/$pid/cmdline" 2>/dev/null |
                    tr '\0' ' ' || true
            )
            if { [[ "$command_line" == *"$tmp/fake-dolt-"* ]] &&
                    [[ "$command_line" == *sql-server* ]]; } ||
                { [[ "$command_line" == /tmp/bd-v062-runtime.*/source-dolt* ]] &&
                    [[ "$command_line" == *sql-server* ]]; } ||
                { [[ "$command_line" == "$tmp"/*/source-dolt* ]] &&
                    [[ "$command_line" == *sql-server* ]]; } ||
                [[ "$command_line" == *"$tmp/fake-bd-timeout-target"* ]]; then
                terminate_pid_bounded "$pid" || true
            fi
        done < "$pids_file"
    done
    rm -rf -- "$tmp"
}
trap cleanup EXIT
mkdir -p "$tmp/home"

POISON_BIN="$tmp/poison-bin"
POISON_BASH_MARKER="$tmp/poison-bash-invoked"
POISON_BASH_ENV_MARKER="$tmp/poison-bash-env-invoked"
POISON_PATH_MARKER="$tmp/poison-path-command-invoked"
POISON_BASH_ENV="$tmp/poison-bash-env"
POISON_GIT_DIR="$tmp/poison-git-dir"
POISON_GIT_WORK_TREE="$tmp/poison-git-work-tree"
POISON_GIT_TEMPLATE="$tmp/poison-git-template"
mkdir -m 700 "$POISON_BIN" "$POISON_GIT_TEMPLATE"
printf -v poison_bash_marker_q '%q' "$POISON_BASH_MARKER"
printf -v poison_bash_env_marker_q '%q' "$POISON_BASH_ENV_MARKER"
printf -v poison_path_marker_q '%q' "$POISON_PATH_MARKER"
cat > "$POISON_BIN/bash" <<EOF
#!/bin/bash
printf '%s\n' invoked >> $poison_bash_marker_q
exec /bin/bash "\$@"
EOF
chmod +x "$POISON_BIN/bash"
cat > "$POISON_BIN/grep" <<EOF
#!/bin/bash
printf '%s\n' invoked >> $poison_path_marker_q
exit 97
EOF
chmod +x "$POISON_BIN/grep"
cat > "$POISON_BASH_ENV" <<EOF
printf '%s\n' invoked >> $poison_bash_env_marker_q
exit 97
EOF
printf '%s\n' poison-template > "$POISON_GIT_TEMPLATE/poison-template-marker"

TARGET_BD="$tmp/fake-bd-current"
TARGET_LOG="$tmp/fake-target.log"
OLD_TARGET_BD="$tmp/fake-bd-old-target"
OLD_TARGET_LOG="$tmp/fake-old-target.log"
INCAPABLE_TARGET_BD="$tmp/fake-bd-incapable-target"
INCAPABLE_TARGET_LOG="$tmp/fake-incapable-target.log"
TIMEOUT_TARGET_BD="$tmp/fake-bd-timeout-target"
TIMEOUT_TARGET_LOG="$tmp/fake-timeout-target.log"
LOSSY_TARGET_LOG="$tmp/fake-lossy-audit-target.log"
ROUTED_TARGET_BD="$tmp/fake-bd-routed-target"
ROUTED_TARGET_LOG="$tmp/fake-routed-target.log"
LATE_ROUTED_TARGET_BD="$tmp/fake-bd-late-routed-target"
LATE_ROUTED_TARGET_LOG="$tmp/fake-late-routed-target.log"
SYMLINK_DOLT_TARGET_BD="$tmp/fake-bd-symlink-dolt-target"
SYMLINK_DOLT_TARGET_LOG="$tmp/fake-symlink-dolt-target.log"
SYMLINK_DATABASE_TARGET_BD="$tmp/fake-bd-symlink-database-target"
SYMLINK_DATABASE_TARGET_LOG="$tmp/fake-symlink-database-target.log"
SOURCE_BD="$tmp/fake-bd-v0.62.0"
SOURCE_LOG="$tmp/fake-source.log"
SOURCE_DOLT="$tmp/fake-dolt-1.84.0"
SOURCE_DOLT_LOG="$tmp/fake-source-dolt.log"
OLD_NO_CLOBBER_MV="$tmp/fake-old-no-clobber-mv"
BAD_SOURCE_BD="$tmp/fake-bd-v0.61.0"
BAD_SOURCE_LOG="$tmp/fake-bad-source.log"
BAD_SOURCE_DOLT="$tmp/fake-dolt-1.83.0"
BAD_SOURCE_DOLT_LOG="$tmp/fake-bad-source-dolt.log"
CANONICAL_EXPORT="$tmp/canonical-v062-export.jsonl"
CANONICAL_SHOW="$tmp/canonical-v062-show.json"
UNQUALIFIED_EXPORT="$tmp/unqualified-v062-export.jsonl"
UNQUALIFIED_SHOW="$tmp/unqualified-v062-show.json"
UNSUPPORTED_EXPORT="$tmp/unsupported-v062-export.jsonl"
UNSUPPORTED_SHOW="$tmp/unsupported-v062-show.json"
NESTED_DEPENDENCY_EXPORT="$tmp/nested-dependency-v062-export.jsonl"
NESTED_COMMENT_SHOW="$tmp/nested-comment-v062-show.json"
SOURCE_AUDIT_FIXTURE_DIR="$tmp/source-audit-fixtures"
SOURCE_ISSUE_PREFIX=legacy
SOURCE_DATABASE=smoke
SOURCE_PROJECT_ID=7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6

# Model coreutils releases where mv --no-clobber exits zero after skipping a
# move because the destination appeared. The bridge must trust postconditions,
# not that historically inconsistent exit status.
cat > "$OLD_NO_CLOBBER_MV" <<'EOF'
#!/bin/bash
arguments=("$@")
count=${#arguments[@]}
if ((count >= 2)); then
    source=${arguments[count - 2]}
    destination=${arguments[count - 1]}
    if { [ -e "$source" ] || [ -L "$source" ]; } &&
        { [ -e "$destination" ] || [ -L "$destination" ]; }; then
        exit 0
    fi
fi
exec /usr/bin/mv "$@"
EOF
chmod +x "$OLD_NO_CLOBBER_MV"

# The first public apply path is deliberately bounded to the exact strict-lane
# v0.62 corpus: five issues carrying eight semantic features. The historical
# export omits comment bodies; one-item show calls are required to enrich it.
cat > "$CANONICAL_EXPORT" <<'EOF'
{"id":"old-epic","title":"Migration epic","description":"Epic for migration testing","priority":2,"issue_type":"epic","status":"open","dependency_count":0,"comment_count":0}
{"id":"old-standalone","title":"Standalone detailed task","description":"This task has a detailed description for fidelity testing.","notes":"Historical notes must survive the upgrade.","design":"Historical design must survive the upgrade.","acceptance_criteria":"Historical acceptance criteria must survive the upgrade.","external_ref":"legacy-upgrade-42","priority":2,"issue_type":"task","status":"open","dependency_count":0,"comment_count":0}
{"id":"old-closed","title":"Already closed issue","priority":3,"issue_type":"task","status":"closed","dependency_count":0,"comment_count":0}
{"id":"old-task","title":"Migration task alpha","priority":1,"issue_type":"task","status":"open","labels":["urgent"],"dependencies":[{"issue_id":"old-task","depends_on_id":"old-epic","type":"parent-child","created_at":"2025-01-02T03:04:05Z","created_by":"legacy-parent-author","metadata":"{}","thread_id":""}],"dependency_count":0,"comment_count":1}
{"id":"old-bug","title":"Migration bug beta","priority":3,"issue_type":"bug","status":"open","dependencies":[{"issue_id":"old-bug","depends_on_id":"old-task","type":"blocks","created_at":"2025-01-03T04:05:06Z","created_by":"legacy-block-author","metadata":"{}","thread_id":""}],"dependency_count":1,"comment_count":0}
EOF
cat > "$CANONICAL_SHOW" <<'EOF'
[
  {"id":"old-epic","title":"Migration epic","description":"Epic for migration testing","priority":2,"issue_type":"epic","status":"open","dependencies":[],"comments":[]},
  {"id":"old-standalone","title":"Standalone detailed task","description":"This task has a detailed description for fidelity testing.","notes":"Historical notes must survive the upgrade.","design":"Historical design must survive the upgrade.","acceptance_criteria":"Historical acceptance criteria must survive the upgrade.","external_ref":"legacy-upgrade-42","priority":2,"issue_type":"task","status":"open","dependencies":[],"comments":[]},
  {"id":"old-closed","title":"Already closed issue","priority":3,"issue_type":"task","status":"closed","dependencies":[],"comments":[]},
  {"id":"old-task","title":"Migration task alpha","priority":1,"issue_type":"task","status":"open","parent":"old-epic","labels":["urgent"],"dependencies":[{"id":"old-epic","dependency_type":"parent-child"}],"comments":[{"id":"7dbef7d8-c3af-42e3-9b59-9f30e81e2647","issue_id":"old-task","author":"legacy-author","text":"Historical comment must survive the upgrade.","created_at":"2025-01-04T05:06:07Z"}]},
  {"id":"old-bug","title":"Migration bug beta","priority":3,"issue_type":"bug","status":"open","dependencies":[{"id":"old-task","dependency_type":"blocks"}],"comments":[]}
]
EOF
# A sixth record is valid JSONL but outside the currently proven semantic
# envelope. It must be rejected before any workspace effect.
cp -f -- "$CANONICAL_EXPORT" "$UNQUALIFIED_EXPORT"
printf '%s\n' '{"id":"old-extra","title":"Unqualified extra issue","priority":2,"issue_type":"task","status":"open","dependency_count":0,"comment_count":0}' \
    >> "$UNQUALIFIED_EXPORT"
jq '. + [{
    id: "old-extra", title: "Unqualified extra issue", priority: 2,
    issue_type: "task", status: "open", dependencies: [], comments: []
}]' "$CANONICAL_SHOW" > "$UNQUALIFIED_SHOW"

# Record count alone cannot qualify a semantic envelope. Keep the canonical
# five IDs and values but add a v0.62 field that this first bridge has not
# independently proven through import/reopen fidelity.
jq -c '
    if .id == "old-standalone"
    then . + {creator: "unqualified-creator"}
    else .
    end
' "$CANONICAL_EXPORT" > "$UNSUPPORTED_EXPORT"
jq '
    map(
        if .id == "old-standalone"
        then . + {creator: "unqualified-creator"}
        else .
        end
    )
' "$CANONICAL_SHOW" > "$UNSUPPORTED_SHOW"

# Nested values that the canonical projection drops are outside the qualified
# scope even when the same five records still carry all eight proven features.
jq -c '
    if .id == "old-task"
    then .dependencies = (.dependencies | map(
        .metadata = "{\"legacy\":\"value\"}" |
        .thread_id = "legacy-dependency-thread"
    ))
    else .
    end
' "$CANONICAL_EXPORT" > "$NESTED_DEPENDENCY_EXPORT"
jq '
    map(
        if .id == "old-task"
        then .comments = (.comments | map(
            . + {legacy_thread_id: "legacy-comment-thread"}
        ))
        else .
        end
    )
' "$CANONICAL_SHOW" > "$NESTED_COMMENT_SHOW"

# Each admitted audit field is independently required. Empty historical values
# must be refused before a plan is offered, not normalized away during import.
mkdir -m 700 "$SOURCE_AUDIT_FIXTURE_DIR"
for source_audit_field in created-at created-by; do
    jq -c --arg field "${source_audit_field//-/_}" '
        if .id == "old-task"
        then .dependencies = (.dependencies | map(.[$field] = ""))
        else .
        end
    ' "$CANONICAL_EXPORT" \
        > "$SOURCE_AUDIT_FIXTURE_DIR/dependency-$source_audit_field.jsonl"
done
for source_audit_field in id issue-id created-at; do
    jq --arg field "${source_audit_field//-/_}" '
        map(
            if .id == "old-task"
            then .comments = (.comments | map(.[$field] = ""))
            else .
            end
        )
    ' "$CANONICAL_SHOW" \
        > "$SOURCE_AUDIT_FIXTURE_DIR/comment-$source_audit_field.json"
done

make_fake_bd() {
    local path="$1" version="$2" capability="$3" log="$4"
    local log_q version_q capability_q log_pid_q log_pids_q
    local injection_marker_q export_marker_q
    printf -v log_q '%q' "$log"
    printf -v version_q '%q' "$version"
    printf -v capability_q '%q' "$capability"
    printf -v log_pid_q '%q' "${log}.pid"
    printf -v log_pids_q '%q' "${log}.pids"
    printf -v injection_marker_q '%q' "${path}.injected"
    printf -v export_marker_q '%q' "${path}.exported"
    cat > "$path" <<EOF
#!/usr/bin/env bash
{
    printf 'argv=%q' "\$0"
    printf ' %q' "\$@"
    printf '\n'
    printf 'cwd=%q\n' "\$PWD"
    env | LC_ALL=C sort
} >> $log_q
case "\${1:-}" in
    version)
        if [ "\${2:-}" = --json ]; then
            printf '{"version":"%s","build":"test"}\n' $version_q
        elif [ "\$#" -eq 1 ]; then
            printf 'bd version %s\n' $version_q
        else
            exit 2
        fi
        ;;
    __migration-v062-inspect)
        if [ $capability_q = timeout ]; then
            printf '%s\n' "\$BASHPID" > $log_pid_q
            printf '%s\n' "\$BASHPID" >> $log_pids_q
            trap 'exit 0' TERM INT
            while :; do
                /usr/bin/sleep 0.05 &
                wait "\$!" || true
            done
        fi
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        [ "\$#" -eq 4 ] && [ "\$2" = --workspace ] &&
            [[ "\$3" = /* ]] && [ "\$4" = --json ] || exit 2
        inspection_code=
        inspection_retryable=false
        inspection_exit=1
        qualified_workspace="\$3"
        qualified_digest_scope=admission_observation
        qualified_exit=0
        repeat_qualified=false
        case "\${3##*/}" in
            wrong-witness) inspection_code=source_version_mismatch ;;
            missing-witness) inspection_code=source_version_missing ;;
            ambiguous-witness) inspection_code=source_version_ambiguous ;;
            wrong-metadata) inspection_code=source_metadata_mismatch ;;
            symlink-layout) inspection_code=unsafe_source_symlink ;;
            mixed-target) inspection_code=mixed_storage_layout ;;
            routing-env|routing-redirect)
                inspection_code=source_routing_unsupported
                ;;
            rollback-collision) inspection_code=rollback_collision ;;
            lying-workspace)
                qualified_workspace=/not/the/requested/workspace
                ;;
            wrong-digest-scope) qualified_digest_scope=lifetime_authority ;;
            multiple-json) repeat_qualified=true ;;
            qualified-wrong-exit) qualified_exit=1 ;;
            refused-wrong-exit)
                inspection_code=source_version_mismatch
                inspection_exit=0
                ;;
            unknown-refusal-code) inspection_code=unrecognized_private_code ;;
            wrong-retryability-stable)
                inspection_code=source_version_mismatch
                inspection_retryable=true
                ;;
            wrong-retryability-transient)
                inspection_code=source_changed
                inspection_retryable=false
                ;;
            retryable-source-changed)
                inspection_code=source_changed
                inspection_retryable=true
                ;;
        esac
        if [ -n "\$inspection_code" ]; then
            printf '{"schema_version":1,"operation":"v062_source_inspection","status":"refused","retryable":%s,"effect":"none","code":"%s"}\n' "\$inspection_retryable" "\$inspection_code"
            exit "\$inspection_exit"
        fi
        qualified_digest=\$(
            cd "\$3/.beads" &&
                {
                    find -P . -maxdepth 0 -printf '%y %m %p %l\n'
                    find -P . -mindepth 1 -printf '%y %m %p %l\n' |
                        LC_ALL=C sort
                    find -P . -type f -print0 | LC_ALL=C sort -z |
                        xargs -0 -r sha256sum
                } | sha256sum | awk '{print \$1}'
        ) || exit 2
        printf '{"schema_version":1,"operation":"v062_source_inspection","status":"qualified","retryable":false,"effect":"none","source":{"workspace":"%s","version":"0.62.0","backend":"dolt-server","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6","tree_sha256":"%s","digest_scope":"%s"},"target":{"version":"%s","backend":"dolt-embedded","embedded_capable":true}}\n' "\$qualified_workspace" "\$qualified_digest" "\$qualified_digest_scope" $version_q
        if \$repeat_qualified; then
            printf '{"schema_version":1,"operation":"v062_source_inspection","status":"qualified","retryable":false,"effect":"none","source":{"workspace":"%s","version":"0.62.0","backend":"dolt-server","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6","tree_sha256":"%s","digest_scope":"%s"},"target":{"version":"%s","backend":"dolt-embedded","embedded_capable":true}}\n' "\$qualified_workspace" "\$qualified_digest" "\$qualified_digest_scope" $version_q
        fi
        exit "\$qualified_exit"
        ;;
    init)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        # The fake must not manufacture an embedded target unless production
        # explicitly selected it. A permissive init fake would let ambient or
        # server-provider routing pass while the test still observed Dolt. It
        # also requires the authenticated source identity to be explicit: a
        # default prefix, database, or newly minted project ID is data drift.
        backend_count=0
        prefix_count=0
        database_count=0
        project_id_count=0
        repository_root_count=0
        prefix=
        database=
        project_id=
        repository_root=
        shift
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                --backend=dolt)
                    backend_count=\$((backend_count + 1))
                    shift
                    ;;
                --backend|--backend=*) exit 2 ;;
                --server|--shared-server|--external|--server-*) exit 2 ;;
                --prefix)
                    [ "\$#" -ge 2 ] || exit 2
                    prefix_count=\$((prefix_count + 1))
                    prefix="\$2"
                    shift 2
                    ;;
                --prefix=*) exit 2 ;;
                --database)
                    [ "\$#" -ge 2 ] || exit 2
                    database_count=\$((database_count + 1))
                    database="\$2"
                    shift 2
                    ;;
                --database=*) exit 2 ;;
                --migration-v062-project-id)
                    [ "\$#" -ge 2 ] || exit 2
                    project_id_count=\$((project_id_count + 1))
                    project_id="\$2"
                    shift 2
                    ;;
                --migration-v062-project-id=*) exit 2 ;;
                --migration-v062-repository-root)
                    [ "\$#" -ge 2 ] || exit 2
                    repository_root_count=\$((repository_root_count + 1))
                    repository_root="\$2"
                    shift 2
                    ;;
                --migration-v062-repository-root=*) exit 2 ;;
                --role)
                    [ "\$#" -ge 2 ] && [ "\$2" = maintainer ] || exit 2
                    shift 2
                    ;;
                --quiet|--non-interactive|--skip-agents|--skip-hooks)
                    shift
                    ;;
                *) exit 2 ;;
            esac
        done
        [ "\$backend_count" -eq 1 ] &&
            [ "\$prefix_count" -eq 1 ] && [ "\$prefix" = legacy ] &&
            [ "\$database_count" -eq 1 ] && [ "\$database" = smoke ] &&
            [ "\$project_id_count" -eq 1 ] &&
            [ "\$project_id" = 7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6 ] &&
            [ "\$repository_root_count" -eq 1 ] &&
            [[ "\$repository_root" = /* ]] &&
            [ -d "\$repository_root/.git" ] || exit 2
        mkdir -p "\$PWD/.beads/embeddeddolt/\$database/.dolt"
        printf '%s\n' \
            '{"database":"dolt","backend":"dolt","dolt_mode":"embedded","dolt_database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}' \
            > "\$PWD/.beads/metadata.json"
        printf '%s\n' \
            '{"issue_prefix":"legacy","_project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}' \
            > "\$PWD/.beads/fake-target-config.json"
        if [ $capability_q = embedded ]; then
            printf '%s\n' '# comment-only target config is inert' '' \
                > "\$PWD/.beads/config.yaml"
        elif [ $capability_q = active-config ]; then
            printf '%s\n' 'dolt:' '  host: poison.invalid' '  port: 29998' \
                > "\$PWD/.beads/config.yaml" || exit 2
            printf '%s\n' $capability_q > $injection_marker_q || exit 2
        elif [ $capability_q = symlink-dolt ]; then
            mv -f -- "\$PWD/.beads/embeddeddolt/\$database/.dolt" \
                "\$PWD/.beads/embeddeddolt/\$database/.dolt-real" || exit 2
            ln -s .dolt-real \
                "\$PWD/.beads/embeddeddolt/\$database/.dolt" || exit 2
            printf '%s\n' $capability_q > $injection_marker_q || exit 2
        elif [ $capability_q = symlink-database ]; then
            mv -f -- "\$PWD/.beads/embeddeddolt/\$database" \
                "\$PWD/.beads/embeddeddolt/\${database}-authentic" || exit 2
            ln -s "\${database}-authentic" \
                "\$PWD/.beads/embeddeddolt/\$database" || exit 2
            printf '%s\n' $capability_q > $injection_marker_q || exit 2
        fi
        ;;
    import)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        input=
        shift
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                -i|--input)
                    [ "\$#" -ge 2 ] || exit 2
                    input="\$2"
                    shift 2
                    ;;
                --input=*) input="\${1#*=}"; shift ;;
                --*) shift ;;
                *)
                    [ -n "\$input" ] || input="\$1"
                    shift
                    ;;
            esac
        done
        [ -n "\$input" ] && [ -f "\$input" ] || exit 2
        case $capability_q in
            lossy-dependency-created-at)
                filter='.dependencies = ((.dependencies // []) | map(del(.created_at)))'
                ;;
            lossy-dependency-created-by)
                filter='.dependencies = ((.dependencies // []) | map(del(.created_by)))'
                ;;
            lossy-comment-id)
                filter='.comments = ((.comments // []) | map(del(.id)))'
                ;;
            lossy-comment-issue-id)
                filter='.comments = ((.comments // []) | map(del(.issue_id)))'
                ;;
            lossy-comment-created-at)
                filter='.comments = ((.comments // []) | map(del(.created_at)))'
                ;;
            *) filter= ;;
        esac
        if [ -n "\$filter" ]; then
            /usr/bin/jq -c "\$filter" "\$input" \
                > "\$PWD/.beads/fake-target-state.jsonl" || exit 2
            printf '%s\n' $capability_q > $injection_marker_q || exit 2
        else
            cp -f -- "\$input" "\$PWD/.beads/fake-target-state.jsonl" ||
                exit 2
        fi
        ;;
    export)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        output=
        no_memories=false
        shift
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                -o|--output)
                    [ "\$#" -ge 2 ] || exit 2
                    output="\$2"
                    shift 2
                    ;;
                --output=*) output="\${1#*=}"; shift ;;
                --no-memories) no_memories=true; shift ;;
                --*) shift ;;
                *) shift ;;
            esac
        done
        \$no_memories && [ -n "\$output" ] &&
            [ -f "\$PWD/.beads/fake-target-state.jsonl" ] || exit 2
        # Current bd export encodes parenthood through the parent-child
        # dependency and does not repeat it in the legacy top-level parent
        # projection. Model that real output shape so the bridge cannot pass
        # only because its fake copied the import record byte-for-byte.
        /usr/bin/jq -c 'del(.parent)' \
            "\$PWD/.beads/fake-target-state.jsonl" > "\$output" || exit 2
        if [ $capability_q = late-active-config ]; then
            printf '%s\n' 'dolt:' '  host: poison.invalid' '  port: 29998' \
                > "\$PWD/.beads/config.yaml" || exit 2
            printf '%s\n' $capability_q > $injection_marker_q || exit 2
        fi
        printf '%s\n' $capability_q > $export_marker_q || exit 2
        ;;
    list)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        [ "\$#" -eq 5 ] && [ "\$2" = --json ] &&
            [ "\$3" = --all ] && [ "\$4" = -n ] &&
            [ "\$5" = 0 ] || exit 2
        [ -f "\$PWD/.beads/fake-target-state.jsonl" ] || exit 1
        /usr/bin/jq -s '.' "\$PWD/.beads/fake-target-state.jsonl"
        ;;
    show)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        [ "\$#" -eq 4 ] && [[ "\$2" == --id=* ]] &&
            [ "\$3" = --json ] && [ "\$4" = --include-comments ] || exit 2
        [ -f "\$PWD/.beads/fake-target-state.jsonl" ] || exit 1
        wanted="\${2#*=}"
        [ -n "\$wanted" ] || exit 2
        /usr/bin/jq -s --arg id "\$wanted" \
            '[.[] | select(.id == \$id)]' \
            "\$PWD/.beads/fake-target-state.jsonl"
        ;;
    config)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        [ "\$#" -eq 4 ] && [ "\$2" = get ] &&
            [ "\$3" = issue_prefix ] && [ "\$4" = --json ] || exit 2
        if [ -f "\$PWD/.beads/force-noop-lock-cleanup-failure" ] &&
            [ -f "\$PWD/.beads/v062-migration-receipt.json" ] &&
            [ -d "\$PWD/.beads-v0.62.0-migration.lock" ]; then
            printf '%s\n' 'injected cleanup obstruction' \
                > "\$PWD/.beads-v0.62.0-migration.lock/unexpected-entry"
        fi
        prefix=\$(/usr/bin/jq -er \
            '.issue_prefix | select(type == "string" and length > 0)' \
            "\$PWD/.beads/fake-target-config.json") || exit 1
        /usr/bin/jq -cn --arg value "\$prefix" \
            '{schema_version:1, key:"issue_prefix", value:\$value}'
        ;;
    create)
        case $capability_q in
            embedded|lossy-*|active-config|late-active-config|symlink-dolt|symlink-database) ;;
            *) exit 2 ;;
        esac
        [ "\$#" -eq 3 ] && [ "\$2" = "Post-migration identity probe" ] &&
            [ "\$3" = --json ] || exit 2
        [ -f "\$PWD/.beads/metadata.json" ] &&
            [ -f "\$PWD/.beads/fake-target-state.jsonl" ] || exit 1
        prefix=\$(/usr/bin/jq -er \
            '.issue_prefix | select(type == "string" and length > 0)' \
            "\$PWD/.beads/fake-target-config.json") || exit 1
        issue_id="\${prefix}-post-migration-1"
        /usr/bin/jq -e --arg id "\$issue_id" \
            'select(.id == \$id)' "\$PWD/.beads/fake-target-state.jsonl" \
            >/dev/null 2>&1 && exit 1
        record=\$(/usr/bin/jq -cn --arg id "\$issue_id" '
            {
                id: \$id, title: "Post-migration identity probe",
                priority: 2, issue_type: "task", status: "open",
                dependencies: [], comments: []
            }
        ') || exit 1
        printf '%s\n' "\$record" >> "\$PWD/.beads/fake-target-state.jsonl"
        printf '%s\n' "\$record"
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$path"
}

make_fake_bd "$TARGET_BD" 1.1.0 embedded "$TARGET_LOG"
make_fake_bd "$OLD_TARGET_BD" 0.62.0 embedded "$OLD_TARGET_LOG"
make_fake_bd "$INCAPABLE_TARGET_BD" 1.1.0 unavailable "$INCAPABLE_TARGET_LOG"
make_fake_bd "$TIMEOUT_TARGET_BD" 1.1.0 timeout "$TIMEOUT_TARGET_LOG"
for lossy_audit_field in \
    dependency-created-at dependency-created-by \
    comment-id comment-issue-id comment-created-at; do
    make_fake_bd "$tmp/fake-bd-lossy-$lossy_audit_field-target" 1.1.0 \
        "lossy-$lossy_audit_field" "$LOSSY_TARGET_LOG"
done
make_fake_bd "$ROUTED_TARGET_BD" 1.1.0 active-config "$ROUTED_TARGET_LOG"
make_fake_bd "$LATE_ROUTED_TARGET_BD" 1.1.0 late-active-config \
    "$LATE_ROUTED_TARGET_LOG"
make_fake_bd "$SYMLINK_DOLT_TARGET_BD" 1.1.0 symlink-dolt \
    "$SYMLINK_DOLT_TARGET_LOG"
make_fake_bd "$SYMLINK_DATABASE_TARGET_BD" 1.1.0 symlink-database \
    "$SYMLINK_DATABASE_TARGET_LOG"

make_fake_source_bd() {
    local path="$1" version="$2" log="$3"
    local log_q version_q canonical_export_q unqualified_export_q
    local unsupported_export_q nested_dependency_export_q canonical_show_q
    local unqualified_show_q unsupported_show_q nested_comment_show_q
    local source_audit_fixture_dir_q
    printf -v log_q '%q' "$log"
    printf -v version_q '%q' "$version"
    printf -v canonical_export_q '%q' "$CANONICAL_EXPORT"
    printf -v unqualified_export_q '%q' "$UNQUALIFIED_EXPORT"
    printf -v unsupported_export_q '%q' "$UNSUPPORTED_EXPORT"
    printf -v nested_dependency_export_q '%q' "$NESTED_DEPENDENCY_EXPORT"
    printf -v canonical_show_q '%q' "$CANONICAL_SHOW"
    printf -v unqualified_show_q '%q' "$UNQUALIFIED_SHOW"
    printf -v unsupported_show_q '%q' "$UNSUPPORTED_SHOW"
    printf -v nested_comment_show_q '%q' "$NESTED_COMMENT_SHOW"
    printf -v source_audit_fixture_dir_q '%q' "$SOURCE_AUDIT_FIXTURE_DIR"
    cat > "$path" <<EOF
#!/usr/bin/env bash
{
    printf 'argv=%q' "\$0"
    printf ' %q' "\$@"
    printf '\n'
    printf 'cwd=%q\n' "\$PWD"
    env | LC_ALL=C sort
} >> $log_q
case "\${1:-}" in
    version|--version)
        if [ "\${2:-}" = --json ]; then
            printf '{"version":"%s","build":"historical-test"}\n' $version_q
        else
            printf 'bd version %s\n' $version_q
        fi
        ;;
    config)
        [ "\$#" -eq 4 ] && [ "\$2" = get ] &&
            [ "\$3" = issue_prefix ] && [ "\$4" = --json ] || exit 2
        if [ -f "\$PWD/.beads/require-owned-source-route" ]; then
            [ "\${BEADS_DOLT_SERVER_HOST:-}" = 127.0.0.1 ] &&
                [ "\${BEADS_DOLT_SERVER_PORT:-}" = 3307 ] &&
                [ "\${BEADS_DOLT_SERVER_DATABASE:-}" = smoke ] || exit 86
        fi
        source_prefix=legacy
        if [ -f "\$PWD/.beads/source-prefix-dotted" ]; then
            source_prefix=legacy.alpha
        elif [ -f "\$PWD/.beads/source-prefix-trailing-hyphen" ]; then
            source_prefix=legacy-
        fi
        printf '{"key":"issue_prefix","value":"%s"}\n' "\$source_prefix"
        ;;
    export)
        if [ -f "\$PWD/.beads/require-owned-source-route" ]; then
            [ "\${BEADS_DOLT_SERVER_HOST:-}" = 127.0.0.1 ] &&
                [ "\${BEADS_DOLT_SERVER_PORT:-}" = 3307 ] &&
                [ "\${BEADS_DOLT_SERVER_DATABASE:-}" = smoke ] || exit 86
        fi
        output=
        shift
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                -o|--output)
                    [ "\$#" -ge 2 ] || exit 2
                    output="\$2"
                    shift 2
                    ;;
                --output=*) output="\${1#*=}"; shift ;;
                *) shift ;;
            esac
        done
        [ -n "\$output" ] || exit 2
        if [ -f "\$PWD/.beads/unqualified-semantic-scope" ]; then
            cp -f -- $unqualified_export_q "\$output"
        elif [ -f "\$PWD/.beads/unsupported-semantic-scope" ]; then
            cp -f -- $unsupported_export_q "\$output"
        elif [ -f "\$PWD/.beads/nested-dependency-semantic-scope" ]; then
            cp -f -- $nested_dependency_export_q "\$output"
        elif [ -f "\$PWD/.beads/audit-source-dependency-created-at" ]; then
            cp -f -- \
                $source_audit_fixture_dir_q/dependency-created-at.jsonl \
                "\$output"
        elif [ -f "\$PWD/.beads/audit-source-dependency-created-by" ]; then
            cp -f -- \
                $source_audit_fixture_dir_q/dependency-created-by.jsonl \
                "\$output"
        else
            cp -f -- $canonical_export_q "\$output"
        fi
        ;;
    list)
        if [ -f "\$PWD/.beads/unqualified-semantic-scope" ]; then
            /usr/bin/jq -s '.' $unqualified_export_q
        elif [ -f "\$PWD/.beads/unsupported-semantic-scope" ]; then
            /usr/bin/jq -s '.' $unsupported_export_q
        elif [ -f "\$PWD/.beads/nested-dependency-semantic-scope" ]; then
            /usr/bin/jq -s '.' $nested_dependency_export_q
        else
            /usr/bin/jq -s '.' $canonical_export_q
        fi
        ;;
    show)
        if [ -f "\$PWD/.beads/require-owned-source-route" ]; then
            [ "\${BEADS_DOLT_SERVER_HOST:-}" = 127.0.0.1 ] &&
                [ "\${BEADS_DOLT_SERVER_PORT:-}" = 3307 ] &&
                [ "\${BEADS_DOLT_SERVER_DATABASE:-}" = smoke ] || exit 86
        fi
        wanted=
        show_fixture=$canonical_show_q
        if [ -f "\$PWD/.beads/unqualified-semantic-scope" ]; then
            show_fixture=$unqualified_show_q
        elif [ -f "\$PWD/.beads/unsupported-semantic-scope" ]; then
            show_fixture=$unsupported_show_q
        elif [ -f "\$PWD/.beads/nested-comment-semantic-scope" ]; then
            show_fixture=$nested_comment_show_q
        elif [ -f "\$PWD/.beads/audit-source-comment-id" ]; then
            show_fixture=$source_audit_fixture_dir_q/comment-id.json
        elif [ -f "\$PWD/.beads/audit-source-comment-issue-id" ]; then
            show_fixture=$source_audit_fixture_dir_q/comment-issue-id.json
        elif [ -f "\$PWD/.beads/audit-source-comment-created-at" ]; then
            show_fixture=$source_audit_fixture_dir_q/comment-created-at.json
        fi
        shift
        while [ "\$#" -gt 0 ]; do
            case "\$1" in
                --id=*) wanted="\${1#*=}" ;;
                --id) shift; wanted="\${1:-}" ;;
                --json) ;;
                --*) ;;
                *) [ -n "\$wanted" ] || wanted="\$1" ;;
            esac
            shift
        done
        [ -n "\$wanted" ] || exit 2
        /usr/bin/jq --arg id "\$wanted" \
            '[.[] | select(.id == \$id)]' "\$show_fixture"
        ;;
    dolt)
        [ "\${2:-}" = stop ] || exit 2
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$path"
}

make_fake_source_dolt() {
    local path="$1" version="$2" log="$3"
    local log_q version_q log_pid_q log_pids_q
    printf -v log_q '%q' "$log"
    printf -v version_q '%q' "$version"
    printf -v log_pid_q '%q' "${log}.pid"
    printf -v log_pids_q '%q' "${log}.pids"
    cat > "$path" <<EOF
#!/usr/bin/env bash
{
    printf 'argv=%q' "\$0"
    printf ' %q' "\$@"
    printf '\n'
    printf 'cwd=%q\n' "\$PWD"
    env | LC_ALL=C sort
} >> $log_q
case "\${1:-}" in
    init)
        mkdir -p .dolt
        printf '%s\n' '{"head":"refs/heads/main"}' > .dolt/repo_state.json
        ;;
    sql-server)
        printf '%s\n' "\$BASHPID" > $log_pid_q
        printf '%s\n' "\$BASHPID" >> $log_pids_q
        trap 'exit 0' TERM INT
        while :; do
            /usr/bin/sleep 0.05 &
            wait "\$!" || true
        done
        ;;
    --host)
        # Fake-only readiness transport: the bridge must still launch and own
        # the sql-server child, then probe it through the pinned runtime. The
        # official lane supplies the real checksum-pinned Dolt listener.
        server_pid=\$(< $log_pid_q)
        kill -0 "\$server_pid" 2>/dev/null || exit 2
        [[ " \$* " == *" sql "* ]] || exit 2
        if [[ " \$* " == *" SELECT value AS project_id FROM metadata"* ]] &&
            [[ " \$* " == *"_project_id"* ]]; then
            project_id=7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6
            if [ -f "\$PWD/.beads/database-project-id-mismatch" ]; then
                project_id=00000000-0000-0000-0000-000000000000
            fi
            printf '{"rows":[{"project_id":"%s"}]}\n' "\$project_id"
        else
            [[ " \$* " == *" SELECT 1"* ]] || exit 2
            printf '%s\n' '{"rows":[{"1":1}]}'
        fi
        ;;
    version|--version)
        printf 'dolt version %s\n' $version_q
        ;;
    *) exit 2 ;;
esac
EOF
    chmod +x "$path"
}

make_fake_source_bd "$SOURCE_BD" 0.62.0 "$SOURCE_LOG"
make_fake_source_bd "$BAD_SOURCE_BD" 0.61.0 "$BAD_SOURCE_LOG"
make_fake_source_dolt "$SOURCE_DOLT" 1.84.0 "$SOURCE_DOLT_LOG"
make_fake_source_dolt "$BAD_SOURCE_DOLT" 1.83.0 "$BAD_SOURCE_DOLT_LOG"

make_executable_tripwire() {
    local path="$1" label="$2" marker="$3"
    local label_q marker_q replacement="${path}.replacement"
    printf -v label_q '%q' "$label"
    printf -v marker_q '%q' "$marker"
    cat > "$replacement" <<EOF
#!/usr/bin/env bash
printf '%s\n' $label_q >> $marker_q
exit 97
EOF
    chmod +x "$replacement"
    mv -f -- "$replacement" "$path"
}

new_v062_workspace() {
    local ws="$1"
    mkdir -p "$ws"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -C "$ws" init --quiet
    git -C "$ws" config core.hooksPath .git/hooks
    mkdir -p \
        "$ws/.beads/dolt/.dolt" \
        "$ws/.beads/dolt/smoke/.dolt"
    cat > "$ws/.beads/metadata.json" <<'EOF'
{
  "database": "dolt",
  "backend": "dolt",
  "dolt_mode": "server",
  "dolt_server_host": "127.0.0.1",
  "dolt_server_port": 3307,
  "dolt_database": "smoke",
  "project_id": "7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"
}
EOF
    printf '0.62.0\n' > "$ws/.beads/.local_version"
    printf '{}\n' > "$ws/.beads/dolt/.dolt/config.json"
    printf '{"head":"refs/heads/main"}\n' > "$ws/.beads/dolt/.dolt/repo_state.json"
    printf '{}\n' > "$ws/.beads/dolt/smoke/.dolt/config.json"
    printf '{"head":"refs/heads/main"}\n' > "$ws/.beads/dolt/smoke/.dolt/repo_state.json"
    printf 'listener:\n  host: 127.0.0.1\n  port: 3307\n' \
        > "$ws/.beads/dolt/config.yaml"
}

tree_fingerprint() {
    local root="$1"
    (
        cd "$root"
        find -P . -mindepth 1 \
            -printf '%y %m %D %i %n %u %g %s %T@ %C@ %p %l\n' |
            LC_ALL=C sort
        find -P . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) | sha256sum | awk '{print $1}'
}

# Content-only identity is used across the atomic source rename: inode and
# ctime changes are irrelevant, but every file byte, mode, and symlink target
# in the retained rollback must remain identical.
content_fingerprint() {
    local root="$1"
    (
        cd "$root"
        find -P . -maxdepth 0 -printf '%y %m %p %l\n'
        find -P . -mindepth 1 -printf '%y %m %p %l\n' | LC_ALL=C sort
        find -P . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
    ) | sha256sum | awk '{print $1}'
}

assert_log_unpoisoned() {
    local log="$1" peer="$2" poison
    [ -s "$log" ] || fail "$peer was never invoked"
    for poison in \
        'BD_BACKEND=postgres' 'BD_DATABASE_BACKEND=mysql' \
        'postgres://poison.invalid/beads' 'mysql://poison.invalid/beads' \
        "$tmp/poison-beads" "$tmp/poison.sqlite" "$tmp/poison-dolt" \
        'BEADS_DOLT_SERVER_MODE=1' 'BEADS_DOLT_SHARED_SERVER=1' \
        'poison.invalid' 'BEADS_DOLT_SERVER_PORT=29999'; do
        if grep -F -- "$poison" "$log" >/dev/null; then
            fail "ambient provider selector reached $peer: $poison"
        fi
    done
}

RUN_STATUS=0
RUN_STDOUT=""
RUN_STDERR=""
run_bridge() {
    local label="$1" cwd="$2"
    shift 2
    local out="$tmp/$label.stdout" err="$tmp/$label.stderr"
    local target="${BRIDGE_TEST_TARGET:-$TARGET_BD}"
    set +e
    (
        cd "$cwd"
        env -i \
            "PATH=$POISON_BIN:$PATH" "HOME=$tmp/home" "TMPDIR=$tmp" \
            "BASH_ENV=$POISON_BASH_ENV" SHELLOPTS=xtrace \
            "GIT_DIR=$POISON_GIT_DIR" \
            "GIT_WORK_TREE=$POISON_GIT_WORK_TREE" \
            "GIT_TEMPLATE_DIR=$POISON_GIT_TEMPLATE" \
            LANG=C LC_ALL=C TZ=UTC TERM=dumb \
            BD_BACKEND=postgres BD_DATABASE_BACKEND=mysql \
            BEADS_DB='postgres://poison.invalid/beads' \
            BD_DB='mysql://poison.invalid/beads' \
            BEADS_DIR="$tmp/poison-beads" \
            BEADS_SQLITE_PATH="$tmp/poison.sqlite" \
            BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_SHARED_SERVER=1 \
            BEADS_DOLT_DATA_DIR="$tmp/poison-dolt" \
            BEADS_DOLT_SERVER_HOST=poison.invalid \
            BEADS_DOLT_SERVER_PORT=29999 \
            "BD_V062_INSPECT_TIMEOUT_SECONDS=${BRIDGE_TEST_INSPECT_TIMEOUT_SECONDS:-600}" \
            "BD_V062_TEST_FAILPOINT=${BRIDGE_TEST_FAILPOINT:-}" \
            "BD_V062_TEST_PHASE_DIR=${BRIDGE_TEST_PHASE_DIR:-}" \
            "BD_V062_TEST_FINGERPRINT_FAILURE=${BRIDGE_TEST_FINGERPRINT_FAILURE:-}" \
            "BD_V062_TEST_MV_MODE=${BRIDGE_TEST_MV_MODE:-}" \
            "BD_V062_TEST_RUNTIME_UNKNOWN_ENTRY=${BRIDGE_TEST_RUNTIME_UNKNOWN_ENTRY:-}" \
            "BD_V062_TEST_IDENTITY_PROBE_FAILURE=${BRIDGE_TEST_IDENTITY_PROBE_FAILURE:-}" \
            "BD_V062_TEST_GUARDIAN_START_FAILURE=${BRIDGE_TEST_GUARDIAN_START_FAILURE:-}" \
            "BD_V062_TEST_MV_BIN=${BRIDGE_TEST_MV_BIN:-}" \
            /usr/bin/timeout --kill-after=5s 180s \
            "$BRIDGE" --target-bd "$target" --json "$@" \
            </dev/null >"$out" 2>"$err"
    )
    RUN_STATUS=$?
    set -e
    RUN_STDOUT=$(<"$out")
    RUN_STDERR=$(<"$err")
}

ASYNC_BRIDGE_PID=""
ASYNC_BRIDGE_OUT=""
ASYNC_BRIDGE_ERR=""
JOURNAL_ZOMBIE_HOLDER_PID=""
JOURNAL_ZOMBIE_OWNER_PID=""
WORKSPACE_LOCK_TEST_IDENTITY_FILE=""
GUARDIAN_TEST_PHASE_DIR=""

capture_async_bridge_output() {
    if [ -f "$ASYNC_BRIDGE_OUT" ]; then
        RUN_STDOUT=$(<"$ASYNC_BRIDGE_OUT")
    else
        RUN_STDOUT=""
    fi
    if [ -f "$ASYNC_BRIDGE_ERR" ]; then
        RUN_STDERR=$(<"$ASYNC_BRIDGE_ERR")
    else
        RUN_STDERR=""
    fi
}

start_bridge_at_phase() {
    local label="$1" cwd="$2"
    shift 2
    local target="${BRIDGE_TEST_TARGET:-$TARGET_BD}"
    [ -n "${BRIDGE_TEST_PHASE_DIR:-}" ] ||
        fail "$label has no phase-handshake directory"
    ASYNC_BRIDGE_OUT="$tmp/$label.stdout"
    ASYNC_BRIDGE_ERR="$tmp/$label.stderr"
    RUN_STATUS=0
    RUN_STDOUT=""
    RUN_STDERR=""
    (
        cd "$cwd"
        exec env -i \
            "PATH=$POISON_BIN:$PATH" "HOME=$tmp/home" "TMPDIR=$tmp" \
            "BASH_ENV=$POISON_BASH_ENV" SHELLOPTS=xtrace \
            "GIT_DIR=$POISON_GIT_DIR" \
            "GIT_WORK_TREE=$POISON_GIT_WORK_TREE" \
            "GIT_TEMPLATE_DIR=$POISON_GIT_TEMPLATE" \
            LANG=C LC_ALL=C TZ=UTC TERM=dumb \
            BD_BACKEND=postgres BD_DATABASE_BACKEND=mysql \
            BEADS_DB='postgres://poison.invalid/beads' \
            BD_DB='mysql://poison.invalid/beads' \
            BEADS_DIR="$tmp/poison-beads" \
            BEADS_SQLITE_PATH="$tmp/poison.sqlite" \
            BEADS_DOLT_SERVER_MODE=1 BEADS_DOLT_SHARED_SERVER=1 \
            BEADS_DOLT_DATA_DIR="$tmp/poison-dolt" \
            BEADS_DOLT_SERVER_HOST=poison.invalid \
            BEADS_DOLT_SERVER_PORT=29999 \
            "BD_V062_INSPECT_TIMEOUT_SECONDS=${BRIDGE_TEST_INSPECT_TIMEOUT_SECONDS:-600}" \
            "BD_V062_TEST_FAILPOINT=${BRIDGE_TEST_FAILPOINT:-}" \
            "BD_V062_TEST_PHASE_DIR=$BRIDGE_TEST_PHASE_DIR" \
            "BD_V062_TEST_FINGERPRINT_FAILURE=${BRIDGE_TEST_FINGERPRINT_FAILURE:-}" \
            "BD_V062_TEST_MV_MODE=${BRIDGE_TEST_MV_MODE:-}" \
            "BD_V062_TEST_RUNTIME_UNKNOWN_ENTRY=${BRIDGE_TEST_RUNTIME_UNKNOWN_ENTRY:-}" \
            "BD_V062_TEST_IDENTITY_PROBE_FAILURE=${BRIDGE_TEST_IDENTITY_PROBE_FAILURE:-}" \
            "BD_V062_TEST_GUARDIAN_START_FAILURE=${BRIDGE_TEST_GUARDIAN_START_FAILURE:-}" \
            "BD_V062_TEST_MV_BIN=${BRIDGE_TEST_MV_BIN:-}" \
            "$BRIDGE" --target-bd "$target" --json "$@" \
            </dev/null >"$ASYNC_BRIDGE_OUT" 2>"$ASYNC_BRIDGE_ERR"
    ) &
    ASYNC_BRIDGE_PID=$!
}

finish_phase_bridge() {
    local context="${1:-phase bridge}" pid attempt
    [ -n "$ASYNC_BRIDGE_PID" ] || fail "no phase bridge is running"
    pid="$ASYNC_BRIDGE_PID"
    for ((attempt = 0; attempt < 1200; attempt++)); do
        pid_is_running "$pid" || break
        sleep 0.025
    done
    if pid_is_running "$pid"; then
        terminate_pid_bounded "$pid" || true
        capture_async_bridge_output
        ASYNC_BRIDGE_PID=""
        fail "$context did not exit within 30 seconds after phase release: stdout=$RUN_STDOUT stderr=$RUN_STDERR"
    fi
    set +e
    wait "$pid"
    RUN_STATUS=$?
    set -e
    ASYNC_BRIDGE_PID=""
    capture_async_bridge_output
}

abort_phase_bridge() {
    if [ -n "$ASYNC_BRIDGE_PID" ]; then
        terminate_pid_bounded "$ASYNC_BRIDGE_PID" || true
        ASYNC_BRIDGE_PID=""
        capture_async_bridge_output
    fi
}

hard_kill_phase_bridge() {
    local context="${1:-phase bridge}" pid
    [ -n "$ASYNC_BRIDGE_PID" ] || fail "no phase bridge is running"
    pid="$ASYNC_BRIDGE_PID"
    kill -KILL -- "$pid" 2>/dev/null || true
    set +e
    wait "$pid" 2>/dev/null
    RUN_STATUS=$?
    set -e
    ASYNC_BRIDGE_PID=""
    capture_async_bridge_output
    [ "$RUN_STATUS" -eq 137 ] ||
        fail "$context exit=$RUN_STATUS after SIGKILL, want 137: $RUN_STDOUT $RUN_STDERR"
}

replace_journal_owner_with_zombie() {
    local journal="$1" pid_file="$tmp/journal-zombie-owner.pid"
    local attempt stat rest state="" start_time boot_id temporary
    command -v perl >/dev/null || fail "perl is required for zombie-owner coverage"
    rm -f -- "$pid_file"
    /usr/bin/perl -e '
        my ($pid_file) = @ARGV;
        my $child = fork();
        die "fork failed" unless defined $child;
        exit 0 unless $child;
        open my $fh, ">", $pid_file or die "open pid file: $!";
        print {$fh} "$child\n";
        close $fh or die "close pid file: $!";
        $SIG{TERM} = sub { exit 0 };
        sleep 600;
    ' "$pid_file" &
    JOURNAL_ZOMBIE_HOLDER_PID=$!
    for ((attempt = 0; attempt < 400; attempt++)); do
        if [ -s "$pid_file" ]; then
            JOURNAL_ZOMBIE_OWNER_PID=$(<"$pid_file")
            stat=$(/usr/bin/cat -- "/proc/$JOURNAL_ZOMBIE_OWNER_PID/stat" \
                2>/dev/null) || stat=""
            if [ -n "$stat" ]; then
                rest=${stat##*) }
                read -r -a fields <<< "$rest"
                state=${fields[0]:-}
                start_time=${fields[19]:-}
                [ "$state" = Z ] && [ -n "$start_time" ] && break
            fi
        fi
        sleep 0.025
    done
    [ "$state" = Z ] && [[ "$start_time" =~ ^[0-9]+$ ]] ||
        fail "could not create an unreaped journal-owner zombie"
    boot_id=$(/usr/bin/cat -- /proc/sys/kernel/random/boot_id) ||
        fail "could not read boot ID for zombie-owner coverage"
    temporary="${journal}.zombie-owner"
    jq --argjson pid "$JOURNAL_ZOMBIE_OWNER_PID" \
        --arg start_time "$start_time" --arg boot_id "$boot_id" '
        .owner.pid = $pid |
        .owner.start_time = $start_time |
        .owner.boot_id = $boot_id
    ' "$journal" > "$temporary" || fail "could not stage zombie owner journal"
    chmod 600 "$temporary"
    mv -f -- "$temporary" "$journal"
}

stop_journal_owner_zombie() {
    if [ -n "$JOURNAL_ZOMBIE_HOLDER_PID" ]; then
        kill -TERM -- "$JOURNAL_ZOMBIE_HOLDER_PID" 2>/dev/null || true
        wait "$JOURNAL_ZOMBIE_HOLDER_PID" 2>/dev/null || true
        JOURNAL_ZOMBIE_HOLDER_PID=""
        JOURNAL_ZOMBIE_OWNER_PID=""
    fi
}

last_private_runtime_from_log() {
    local log="$1" runtime
    runtime=$(sed -n \
        's|^argv=\(.*\)/source-bd version --json$|\1|p' \
        "$log" 2>/dev/null | tail -1) || runtime=""
    [ -n "$runtime" ] || return 1
    [[ "$runtime" = /* ]] || return 1
    printf '%s\n' "$runtime"
}

last_clean_home_from_log() {
    local log="$1" home
    home=$(sed -n 's|^HOME=\(/[^[:space:]]*\)$|\1|p' \
        "$log" 2>/dev/null | tail -1) || home=""
    [ -n "$home" ] || return 1
    printf '%s\n' "$home"
}

last_source_copy_from_log() {
    local log="$1" source_copy
    source_copy=$(sed -n 's|^cwd=\(/[^[:space:]]*\)$|\1|p' \
        "$log" 2>/dev/null | tail -1) || source_copy=""
    [ -n "$source_copy" ] || return 1
    printf '%s\n' "$source_copy"
}

last_semantic_probe_from_log() {
    local log="$1" probe
    probe=$(sed -n \
        's|^argv=.* import -i \(/[^[:space:]]*\) --json$|\1|p' \
        "$log" 2>/dev/null | tail -1) || probe=""
    [ -n "$probe" ] || return 1
    printf '%s\n' "$probe"
}

wait_for_path_absence() {
    local path="$1" context="$2" attempt
    for ((attempt = 0; attempt < 400; attempt++)); do
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            return 0
        fi
        sleep 0.025
    done
    fail "$context was not removed within 10 seconds: $path"
}

assert_last_private_runtime_removed() {
    local log="$1" context="$2" runtime
    runtime=$(last_private_runtime_from_log "$log") ||
        fail "$context did not expose its authenticated runtime root"
    wait_for_path_absence "$runtime" "$context runtime root"
}

assert_no_workspace_runtime_artifacts() {
    local ws="$1" context="$2" artifact attempt
    for ((attempt = 0; attempt < 400; attempt++)); do
        artifact=$(find -P "$ws" -mindepth 1 -maxdepth 1 \
            -name '.beads-v0.62.0-migration.runtime.*' -print -quit) ||
            fail "$context runtime-artifact scan failed"
        [ -n "$artifact" ] || return 0
        sleep 0.025
    done
    fail "$context left a workspace runtime artifact: $artifact"
}

assert_scratch_is_beneath_runtime() {
    local runtime="$1" path="$2" label="$3"
    case "$path" in
        "$runtime"/*) ;;
        *) fail "$label escaped the authenticated runtime root: $path" ;;
    esac
}

release_transaction_gap_phases() {
    local phase_dir="$1"
    touch \
        "$phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
        "$phase_dir/after_staging_publish_before_journal_update.continue" \
        "$phase_dir/after_operation_fence_retired_before_private_cleanup.continue"
}

phase_marker_state() {
    local phase_dir="$1" marker state=""
    for marker in "$phase_dir"/*; do
        [ -f "$marker" ] || continue
        state+="${state:+,}${marker##*/}"
    done
    printf '%s\n' "${state:-none}"
}

wait_for_phase() {
    local phase_dir="$1" phase="$2" context="$3" attempt markers
    for ((attempt = 0; attempt < 400; attempt++)); do
        [ -f "$phase_dir/$phase.reached" ] && return 0
        if ! pid_is_running "$ASYNC_BRIDGE_PID" ||
            [ -s "$ASYNC_BRIDGE_OUT" ]; then
            finish_phase_bridge "$context"
            fail "$context exited before phase $phase: $RUN_STDOUT $RUN_STDERR"
        fi
        sleep 0.025
    done
    markers=$(phase_marker_state "$phase_dir")
    abort_phase_bridge
    fail "$context did not reach phase $phase within 10 seconds: markers=$markers stdout=$RUN_STDOUT stderr=$RUN_STDERR"
}

wait_for_guardian_marker() {
    local phase_dir="$1" marker="$2" context="$3" attempt markers
    for ((attempt = 0; attempt < 400; attempt++)); do
        [ -f "$phase_dir/$marker" ] && return 0
        if ! pid_is_running "$ASYNC_BRIDGE_PID"; then
            finish_phase_bridge "$context"
            fail "$context exited before guardian marker $marker: $RUN_STDOUT $RUN_STDERR"
        fi
        sleep 0.025
    done
    markers=$(phase_marker_state "$phase_dir")
    abort_phase_bridge
    fail "$context did not emit guardian marker $marker within 10 seconds: markers=$markers stdout=$RUN_STDOUT stderr=$RUN_STDERR"
}

run_apply_without_yes_on_tty() {
    local ws="$1" command
    printf -v command '%q ' env -i "PATH=$PATH" "HOME=$tmp/home" \
        LANG=C LC_ALL=C TZ=UTC TERM=dumb "$BRIDGE" \
        --target-bd "$TARGET_BD" --apply --workspace "$ws" --json
    set +e
    (cd "$ws" && script -q -e -c "$command" /dev/null >/dev/null 2>&1)
    RUN_STATUS=$?
    set -e
}

assert_common_json() {
    local mode="$1" status="$2" effect="$3"
    jq -se --arg mode "$mode" --arg status "$status" --arg effect "$effect" '
        length == 1 and (.[0] |
            type == "object" and
            .schema_version == 1 and
            .operation == "v062_server_to_current" and
            .mode == $mode and .status == $status and
            (.retryable | type) == "boolean" and .effect == $effect and
            (keys - ["schema_version", "operation", "mode", "status",
                     "retryable", "effect", "code", "source", "target",
                     "plan", "rollback", "verification", "no_op"] |
                length) == 0
        )
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "invalid JSON contract for $mode/$status: $RUN_STDOUT $RUN_STDERR"
}

assert_unchanged() {
    local ws="$1" before="$2" context="$3"
    [ "$(tree_fingerprint "$ws")" = "$before" ] ||
        fail "$context mutated the workspace"
}

# Default mode can qualify the source layout without executing historical
# tools, but it must accurately explain what is required for a bindable plan.
inspect_ws="$tmp/inspect-default"
new_v062_workspace "$inspect_ws"
inspect_before=$(tree_fingerprint "$inspect_ws")
run_bridge inspect-default "$inspect_ws"
[ "$RUN_STATUS" -eq 1 ] || fail "default inspect exit=$RUN_STATUS, want 1"
assert_common_json inspect refused none
jq -e '
    .retryable == false and .code == "source_tools_required" and
    .source.version == "0.62.0" and .source.backend == "dolt-server" and
    .source.digest_scope == "admission_observation" and
    (.source.tree_sha256 | test("^[0-9a-f]{64}$")) and
    .target.backend == "dolt-embedded" and .target.embedded_capable == true and
    (.rollback | type) == "object" and
    .verification.source_digest_scope == "admission_observation" and
    .verification.apply_reinspection_required == true and
    .verification.apply_available == true and
    .verification.apply_requires_pinned_source_tools == true and
    .verification.workspace_effects == false
' <<< "$RUN_STDOUT" >/dev/null || fail "default inspect omitted its qualified plan"
default_json=$(jq -Sc . <<< "$RUN_STDOUT")
assert_unchanged "$inspect_ws" "$inspect_before" "default inspect"

run_bridge inspect-explicit "$inspect_ws" --inspect --workspace "$inspect_ws"
[ "$RUN_STATUS" -eq 1 ] || fail "explicit inspect exit=$RUN_STATUS, want 1"
assert_common_json inspect refused none
[ "$(jq -Sc . <<< "$RUN_STDOUT")" = "$default_json" ] ||
    fail "default and explicit inspect returned different JSON contracts"
assert_unchanged "$inspect_ws" "$inspect_before" "explicit inspect"

# Provider and database selectors inherited from the caller may not reach the
# target binary, which owns both version and hidden migration inspection.
[ -s "$TARGET_LOG" ] || fail "inspect did not validate the target binary"
grep -F -- '__migration-v062-inspect' "$TARGET_LOG" >/dev/null ||
    fail "public inspect did not use the target hidden inspection command"
printf -v inspect_ws_log_q '%q' "$inspect_ws"
grep -F -- "--workspace $inspect_ws_log_q --json" "$TARGET_LOG" >/dev/null ||
    fail "target hidden inspection did not receive the physical workspace"
for poison in \
    'BD_BACKEND=postgres' 'BD_DATABASE_BACKEND=mysql' \
    'postgres://poison.invalid/beads' 'mysql://poison.invalid/beads' \
    "$tmp/poison-beads" "$tmp/poison.sqlite" "$tmp/poison-dolt" \
    'BEADS_DOLT_SERVER_MODE=1' 'BEADS_DOLT_SHARED_SERVER=1' \
    'poison.invalid' 'BEADS_DOLT_SERVER_PORT=29999'; do
    if grep -F -- "$poison" "$TARGET_LOG" >/dev/null; then
        fail "ambient provider selector reached the target binary: $poison"
    fi
done

# Treat the hidden command as an untrusted protocol peer. A response is
# admissible only when its payload and process exit form one exact tuple.
protocol_rejection_failures=()
check_protocol_rejected() {
    local label="$1" ws="$tmp/$1" before
    new_v062_workspace "$ws"
    before=$(tree_fingerprint "$ws")
    run_bridge "$label" "$ws" --inspect --workspace "$ws"
    if [ "$RUN_STATUS" -ne 1 ]; then
        printf '%s: exit=%s, want 1\n' "$label" "$RUN_STATUS" >&2
        return 1
    fi
    if ! jq -se '
        length == 1 and .[0] == {
            schema_version: 1,
            operation: "v062_server_to_current",
            mode: "inspect",
            status: "refused",
            retryable: false,
            effect: "none",
            code: "target_capability_missing"
        }
    ' <<< "$RUN_STDOUT" >/dev/null 2>&1; then
        printf '%s: wrapper trusted invalid inspector tuple: %s %s\n' \
            "$label" "$RUN_STDOUT" "$RUN_STDERR" >&2
        return 1
    fi
    if [ "$(tree_fingerprint "$ws")" != "$before" ]; then
        printf '%s: protocol rejection mutated the workspace\n' "$label" >&2
        return 1
    fi
}

for protocol_case in \
    lying-workspace \
    wrong-digest-scope \
    multiple-json \
    qualified-wrong-exit \
    refused-wrong-exit \
    unknown-refusal-code \
    wrong-retryability-stable \
    wrong-retryability-transient; do
    if ! check_protocol_rejected "$protocol_case"; then
        protocol_rejection_failures+=("$protocol_case")
    fi
done
if [ "${#protocol_rejection_failures[@]}" -ne 0 ]; then
    fail "inspector protocol regressions: ${protocol_rejection_failures[*]}"
fi

assert_refused() {
    local label="$1" ws="$2" code="$3"
    local before
    before=$(tree_fingerprint "$ws")
    run_bridge "$label" "$ws" --inspect --workspace "$ws"
    [ "$RUN_STATUS" -eq 1 ] || fail "$label exit=$RUN_STATUS, want refusal exit 1"
    assert_common_json inspect refused none
    jq -e --arg code "$code" '.retryable == false and .code == $code' \
        <<< "$RUN_STDOUT" >/dev/null || fail "$label returned the wrong refusal code"
    assert_unchanged "$ws" "$before" "$label refusal"
}

wrong_ws="$tmp/wrong-witness"; new_v062_workspace "$wrong_ws"
printf '0.61.0\n' > "$wrong_ws/.beads/.local_version"
assert_refused wrong-witness "$wrong_ws" source_version_mismatch

missing_ws="$tmp/missing-witness"; new_v062_workspace "$missing_ws"
rm -f -- "$missing_ws/.beads/.local_version"
assert_refused missing-witness "$missing_ws" source_version_missing

ambiguous_ws="$tmp/ambiguous-witness"; new_v062_workspace "$ambiguous_ws"
mv -f -- "$ambiguous_ws/.beads/.local_version" "$ambiguous_ws/version-target"
ln -s ../version-target "$ambiguous_ws/.beads/.local_version"
assert_refused ambiguous-witness "$ambiguous_ws" source_version_ambiguous

metadata_ws="$tmp/wrong-metadata"; new_v062_workspace "$metadata_ws"
jq '.backend = "postgres"' "$metadata_ws/.beads/metadata.json" \
    > "$metadata_ws/.beads/metadata.json.tmp"
mv -f -- "$metadata_ws/.beads/metadata.json.tmp" "$metadata_ws/.beads/metadata.json"
assert_refused wrong-metadata "$metadata_ws" source_metadata_mismatch

symlink_ws="$tmp/symlink-layout"; new_v062_workspace "$symlink_ws"
mv -f -- "$symlink_ws/.beads/dolt" "$symlink_ws/.beads/dolt-real"
ln -s dolt-real "$symlink_ws/.beads/dolt"
assert_refused symlink-layout "$symlink_ws" unsafe_source_symlink

mixed_ws="$tmp/mixed-target"; new_v062_workspace "$mixed_ws"
mkdir -p "$mixed_ws/.beads/embeddeddolt"
assert_refused mixed-target "$mixed_ws" mixed_storage_layout

routing_env_ws="$tmp/routing-env"; new_v062_workspace "$routing_env_ws"
printf '%s\n' 'BEADS_DOLT_SERVER_HOST=poison.invalid' \
    > "$routing_env_ws/.beads/.env"
assert_refused routing-env "$routing_env_ws" source_routing_unsupported

routing_redirect_ws="$tmp/routing-redirect"
new_v062_workspace "$routing_redirect_ws"
printf '%s\n' '../poison-routing/.beads' \
    > "$routing_redirect_ws/.beads/redirect"
assert_refused routing-redirect "$routing_redirect_ws" \
    source_routing_unsupported

collision_ws="$tmp/rollback-collision"; new_v062_workspace "$collision_ws"
mkdir -p "$collision_ws/.beads-v0.62.0-rollback"
printf 'unrelated retained data\n' > "$collision_ws/.beads-v0.62.0-rollback/sentinel"
assert_refused rollback-collision "$collision_ws" rollback_collision

changed_ws="$tmp/retryable-source-changed"; new_v062_workspace "$changed_ws"
changed_before=$(tree_fingerprint "$changed_ws")
run_bridge retryable-source-changed "$changed_ws" \
    --inspect --workspace "$changed_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "retryable source change exit=$RUN_STATUS, want refusal exit 1"
assert_common_json inspect refused none
jq -e '
    .retryable == true and .code == "source_changed"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "valid retryable source change was not forwarded unchanged"
assert_unchanged "$changed_ws" "$changed_before" \
    "retryable source change refusal"

assert_target_refused() {
    local label="$1" target="$2" code="$3" ws="$tmp/$1"
    local before
    new_v062_workspace "$ws"
    before=$(tree_fingerprint "$ws")
    BRIDGE_TEST_TARGET="$target" run_bridge "$label" "$ws" --inspect --workspace "$ws"
    [ "$RUN_STATUS" -eq 1 ] || fail "$label exit=$RUN_STATUS, want refusal exit 1"
    assert_common_json inspect refused none
    jq -e --arg code "$code" '.retryable == false and .code == $code' \
        <<< "$RUN_STDOUT" >/dev/null || fail "$label returned the wrong refusal code"
    assert_unchanged "$ws" "$before" "$label refusal"
}

assert_target_refused old-target "$OLD_TARGET_BD" target_binary_invalid
grep -F -- '__migration-v062-inspect' "$OLD_TARGET_LOG" >/dev/null ||
    fail "historical target was rejected without validating its hidden response"
assert_target_refused incapable-target "$INCAPABLE_TARGET_BD" target_capability_missing
grep -F -- '__migration-v062-inspect' "$INCAPABLE_TARGET_LOG" >/dev/null ||
    fail "embedded-incapable target was rejected without a capability probe"

timeout_ws="$tmp/timeout-target"
new_v062_workspace "$timeout_ws"
timeout_before=$(tree_fingerprint "$timeout_ws")
timeout_started=$SECONDS
BRIDGE_TEST_INSPECT_TIMEOUT_SECONDS=1 \
BRIDGE_TEST_TARGET="$TIMEOUT_TARGET_BD" \
    run_bridge timeout-target "$timeout_ws" --inspect --workspace "$timeout_ws"
timeout_elapsed=$((SECONDS - timeout_started))
[ "$RUN_STATUS" -eq 1 ] ||
    fail "timeout target exit=$RUN_STATUS, want refusal exit 1"
[ "$timeout_elapsed" -le 5 ] ||
    fail "timeout target exceeded its wall-clock bound (${timeout_elapsed}s)"
assert_common_json inspect refused none
jq -e '
    .retryable == true and .code == "target_inspection_timeout"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "target timeout was not reported as a retryable refusal"
[ -s "${TIMEOUT_TARGET_LOG}.pid" ] ||
    fail "timeout target did not record its process identity"
timeout_target_pid=$(<"${TIMEOUT_TARGET_LOG}.pid")
if kill -0 "$timeout_target_pid" 2>/dev/null; then
    fail "timed-out target process $timeout_target_pid leaked"
fi
assert_unchanged "$timeout_ws" "$timeout_before" "target timeout refusal"

# Apply always requires explicit consent, even on a terminal. Once consent is
# present, a blocking apply still requires the exact inspect-generated plan
# before source/runtime validation or any workspace effect.
apply_ws="$tmp/apply-without-consent"; new_v062_workspace "$apply_ws"
apply_before=$(tree_fingerprint "$apply_ws")
run_bridge apply-without-consent "$apply_ws" --apply --workspace "$apply_ws"
[ "$RUN_STATUS" -eq 2 ] || fail "apply without --yes exit=$RUN_STATUS, want 2"
assert_common_json apply usage_error none
jq -e '.retryable == false and .code == "confirmation_required"' \
    <<< "$RUN_STDOUT" >/dev/null || fail "apply without --yes lacked stable JSON"
assert_unchanged "$apply_ws" "$apply_before" "apply without --yes"

run_apply_without_yes_on_tty "$apply_ws"
[ "$RUN_STATUS" -eq 2 ] || fail "TTY apply without --yes exit=$RUN_STATUS, want 2"
assert_unchanged "$apply_ws" "$apply_before" "TTY apply without --yes"

run_bridge apply-plan-required "$apply_ws" --apply --yes --workspace "$apply_ws"
[ "$RUN_STATUS" -eq 2 ] ||
    fail "apply --yes without plan exit=$RUN_STATUS, want usage exit 2: $RUN_STDOUT"
assert_common_json apply usage_error none
jq -e '.retryable == false and .code == "plan_required"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "apply --yes without --expect-plan lacked plan_required: $RUN_STDOUT"
assert_unchanged "$apply_ws" "$apply_before" "apply without expected plan"

# JSON is bootstrapped before ordinary parsing: even when --json follows an
# invalid flag, the result is one structured usage error and no effects.
run_bridge invalid-usage "$inspect_ws" --definitely-not-a-real-option
[ "$RUN_STATUS" -eq 2 ] || fail "invalid usage exit=$RUN_STATUS, want 2"
assert_common_json inspect usage_error none
jq -e '.retryable == false and .code == "invalid_usage"' \
    <<< "$RUN_STDOUT" >/dev/null || fail "invalid usage lacked stable JSON"
assert_unchanged "$inspect_ws" "$inspect_before" "invalid usage"

assert_usage_error() {
    local label="$1" code="$2"
    shift 2
    run_bridge "$label" "$inspect_ws" "$@"
    [ "$RUN_STATUS" -eq 2 ] ||
        fail "$label exit=$RUN_STATUS, want usage exit 2"
    assert_common_json inspect usage_error none
    jq -e --arg code "$code" '.retryable == false and .code == $code' \
        <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label lacked its stable usage code"
    assert_unchanged "$inspect_ws" "$inspect_before" "$label"
}

assert_usage_error conflicting-modes invalid_usage --inspect --apply
assert_usage_error inspect-with-yes invalid_usage --inspect --yes
assert_usage_error workspace-missing-value invalid_usage --workspace
assert_usage_error target-missing-value invalid_usage --target-bd
assert_usage_error source-bd-missing-value invalid_usage --source-bd
assert_usage_error source-dolt-missing-value invalid_usage --source-dolt
assert_usage_error expect-plan-missing-value invalid_usage --expect-plan

for invalid_timeout in \
    0 \
    3601 \
    999999999999999999999999999999999999999999999999999999999999 \
    not-a-number; do
    BRIDGE_TEST_INSPECT_TIMEOUT_SECONDS="$invalid_timeout" \
        run_bridge "invalid-timeout-$invalid_timeout" "$inspect_ws" --inspect
    [ "$RUN_STATUS" -eq 2 ] ||
        fail "invalid timeout $invalid_timeout exit=$RUN_STATUS, want 2"
    assert_common_json inspect usage_error none
    jq -e '
        .retryable == false and .code == "invalid_environment"
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "invalid timeout $invalid_timeout lacked its stable usage code"
    assert_unchanged "$inspect_ws" "$inspect_before" \
        "invalid timeout $invalid_timeout"
done

# Close the test-double gap: exercise the actual built current bd through the
# public shell entrypoint, hidden Cobra protocol, and descriptor-relative Go
# inspector. This is the admission slice's real process-boundary E2E path.
real_ws="$tmp/real-current-target"
new_v062_workspace "$real_ws"
# Fresh v0.62.0 workspaces using the default server endpoint omit these
# optional metadata fields; exercise that authentic shape through the real
# current binary rather than only the explicitly configured CI fixture.
jq 'del(.dolt_server_host, .dolt_server_port)' \
    "$real_ws/.beads/metadata.json" > "$real_ws/.beads/metadata.json.tmp"
mv -f -- "$real_ws/.beads/metadata.json.tmp" \
    "$real_ws/.beads/metadata.json"
real_before=$(tree_fingerprint "$real_ws")

hostile_cwd="$tmp/hostile-cwd"
hostile_home="$tmp/hostile-home-real"
mkdir -p \
    "$hostile_cwd/.beads" \
    "$hostile_home/.config/bd" \
    "$hostile_home/.cache" \
    "$hostile_home/.local/share" \
    "$hostile_home/.local/state"
printf '%s\n' '{"backend":"postgres","database":"postgres"}' \
    > "$hostile_cwd/.beads/metadata.json"
printf '%s\n' 'backend: postgres' > "$hostile_cwd/.beads/config.yaml"
printf '%s\n' 'BD_BACKEND=postgres' > "$hostile_cwd/.beads/.env"
printf '%s\n' 'metrics.disabled: false' \
    > "$hostile_home/.config/bd/config.yaml"
hostile_cwd_before=$(tree_fingerprint "$hostile_cwd")
hostile_home_before=$(tree_fingerprint "$hostile_home")
hidden_real_stdout="$tmp/hidden-real.stdout"
hidden_real_stderr="$tmp/hidden-real.stderr"
set +e
(
    cd "$hostile_cwd"
    env \
        HOME="$hostile_home" \
        XDG_CONFIG_HOME="$hostile_home/.config" \
        XDG_CACHE_HOME="$hostile_home/.cache" \
        XDG_DATA_HOME="$hostile_home/.local/share" \
        XDG_STATE_HOME="$hostile_home/.local/state" \
        BD_BACKEND=postgres BD_DATABASE_BACKEND=mysql \
        BEADS_DB='postgres://poison.invalid/beads' \
        BD_DB='mysql://poison.invalid/beads' \
        BEADS_DIR="$hostile_cwd/.beads" \
        "$REAL_TARGET_BD" __migration-v062-inspect \
            --workspace "$real_ws" --json \
            > "$hidden_real_stdout" 2> "$hidden_real_stderr"
)
hidden_real_status=$?
set -e
[ "$hidden_real_status" -eq 0 ] ||
    fail "real hidden command exit=$hidden_real_status, want 0"
[ ! -s "$hidden_real_stderr" ] ||
    fail "real hidden command emitted stderr: $(<"$hidden_real_stderr")"
jq -e --arg workspace "$real_ws" '
    keys == ["effect", "operation", "retryable", "schema_version",
             "source", "status", "target"] and
    .schema_version == 1 and .operation == "v062_source_inspection" and
    .status == "qualified" and .retryable == false and .effect == "none" and
    .source.workspace == $workspace and .source.version == "0.62.0" and
    .source.backend == "dolt-server" and
    .source.digest_scope == "admission_observation" and
    (.source.tree_sha256 | test("^[0-9a-f]{64}$")) and
    .target.backend == "dolt-embedded" and
    .target.embedded_capable == true
' "$hidden_real_stdout" >/dev/null ||
    fail "real hidden command did not emit the exact qualified protocol"
assert_unchanged "$real_ws" "$real_before" "real hidden command"
assert_unchanged "$hostile_cwd" "$hostile_cwd_before" \
    "real hidden command hostile cwd"
assert_unchanged "$hostile_home" "$hostile_home_before" \
    "real hidden command hostile home"
hidden_real_digest=$(jq -r '.source.tree_sha256' "$hidden_real_stdout")

BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
    run_bridge real-current-target "$real_ws" \
        --inspect --workspace "$real_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "real current target exit=$RUN_STATUS, want fail-closed exit 1"
assert_common_json inspect refused none
jq -e --arg workspace "$real_ws" --arg digest "$hidden_real_digest" '
    .retryable == false and .code == "source_tools_required" and
    .source.workspace == $workspace and .source.version == "0.62.0" and
    .source.backend == "dolt-server" and
    .source.digest_scope == "admission_observation" and
    .source.tree_sha256 == $digest and
    .target.backend == "dolt-embedded" and
    .target.embedded_capable == true and
    .verification.source_digest_scope == "admission_observation" and
    .verification.apply_reinspection_required == true
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "real current target did not return the qualified admission plan"
assert_unchanged "$real_ws" "$real_before" "real current target inspection"

real_negative_ws="$tmp/real-current-negative"
new_v062_workspace "$real_negative_ws"
printf '0.61.0\n' > "$real_negative_ws/.beads/.local_version"
real_negative_before=$(tree_fingerprint "$real_negative_ws")
BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
    run_bridge real-current-negative "$real_negative_ws" \
        --inspect --workspace "$real_negative_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "real negative source exit=$RUN_STATUS, want refusal exit 1"
assert_common_json inspect refused none
jq -e '
    .retryable == false and .code == "source_version_mismatch"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "real negative source did not preserve its typed refusal"
assert_unchanged "$real_negative_ws" "$real_negative_before" \
    "real negative source refusal"

# The version gate above is not a safety refusal. Prove that the real inspector
# also fails closed on the safety-critical shapes end to end, through the public
# wrapper and the descriptor-relative Go walk, not only the fake target.
assert_real_target_refused() {
    local label="$1" ws="$2" code="$3" before
    before=$(tree_fingerprint "$ws")
    BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
        run_bridge "$label" "$ws" --inspect --workspace "$ws"
    [ "$RUN_STATUS" -eq 1 ] ||
        fail "$label exit=$RUN_STATUS, want fail-closed refusal exit 1"
    assert_common_json inspect refused none
    jq -e --arg code "$code" '.retryable == false and .code == $code' \
        <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label did not preserve its typed safety refusal"
    assert_unchanged "$ws" "$before" "$label refusal"
}

real_symlink_ws="$tmp/real-current-symlink"
new_v062_workspace "$real_symlink_ws"
mv -f -- "$real_symlink_ws/.beads/dolt" "$real_symlink_ws/.beads/dolt-real"
ln -s dolt-real "$real_symlink_ws/.beads/dolt"
assert_real_target_refused real-current-symlink "$real_symlink_ws" unsafe_source_symlink

real_mixed_ws="$tmp/real-current-mixed"
new_v062_workspace "$real_mixed_ws"
printf 'sqlite-like bytes\n' > "$real_mixed_ws/.beads/beads.db"
assert_real_target_refused real-current-mixed "$real_mixed_ws" mixed_storage_layout

for routing_artifact in env redirect; do
    routing_label="real-routing-$routing_artifact"
    routing_ws="$tmp/$routing_label"
    new_v062_workspace "$routing_ws"
    case "$routing_artifact" in
        env)
            printf '%s\n' \
                'BEADS_DOLT_SERVER_HOST=poison.invalid' \
                'BEADS_DOLT_SERVER_PORT=29999' \
                > "$routing_ws/.beads/.env"
            ;;
        redirect)
            printf '%s\n' '../poison-routing/.beads' \
                > "$routing_ws/.beads/redirect"
            ;;
    esac
    routing_before=$(tree_fingerprint "$routing_ws")
    BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
        run_bridge "$routing_label" "$routing_ws" \
            --inspect --workspace "$routing_ws"
    [ "$RUN_STATUS" -eq 1 ] ||
        fail "$routing_label exit=$RUN_STATUS, want refusal exit 1"
    assert_common_json inspect refused none
    jq -e '
        .retryable == false and .code == "source_routing_unsupported"
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "$routing_label did not reject project-local routing state"
    assert_unchanged "$routing_ws" "$routing_before" "$routing_label refusal"
done

# Effectful walking-skeleton contract. Admission-only inspect above remains
# fail-closed for callers that have not supplied pinned historical tools. A
# bindable plan is available only when the exact source bd and Dolt runtime are
# explicit inputs; apply repeats those identities and the plan digest.
EFFECTFUL_PLAN=""
inspect_effectful_plan() {
    local label="$1" ws="$2" source_bd="$3" source_dolt="$4" target_bd="$5"
    local before source_sha runtime_sha target_sha
    before=$(tree_fingerprint "$ws")
    BRIDGE_TEST_TARGET="$target_bd" \
        run_bridge "$label" "$ws" \
            --inspect --workspace "$ws" \
            --source-bd "$source_bd" --source-dolt "$source_dolt"
    [ "$RUN_STATUS" -eq 0 ] ||
        fail "$label exit=$RUN_STATUS, want planned exit 0: $RUN_STDOUT $RUN_STDERR"
    [ -z "$RUN_STDERR" ] ||
        fail "$label emitted stderr in JSON mode: $RUN_STDERR"
    assert_common_json inspect planned none
    source_sha=$(sha256sum "$source_bd" | awk '{print $1}')
    runtime_sha=$(sha256sum "$source_dolt" | awk '{print $1}')
    target_sha=$(sha256sum "$target_bd" | awk '{print $1}')
    jq -e \
        --arg workspace "$ws" \
        --arg issue_prefix "$SOURCE_ISSUE_PREFIX" \
        --arg database "$SOURCE_DATABASE" \
        --arg project_id "$SOURCE_PROJECT_ID" \
        --arg source_bd "$source_bd" --arg source_sha "$source_sha" \
        --arg source_dolt "$source_dolt" --arg runtime_sha "$runtime_sha" \
        --arg target_bd "$target_bd" --arg target_sha "$target_sha" '
        .retryable == false and
        .source.workspace == $workspace and
        .source.version == "0.62.0" and
        .source.backend == "dolt-server" and
        .source.digest_scope == "admission_observation" and
        (.source.tree_sha256 | test("^[0-9a-f]{64}$")) and
        .target.backend == "dolt-embedded" and
        .target.embedded_capable == true and
        .plan.schema == "bd.v062.bridge-plan.v1" and
        (.plan.digest | test("^[0-9a-f]{64}$")) and
        .plan.semantic_scope == "v062_lossless_core_v1" and
        .plan.semantic_baseline.issue_ids == [
            "old-bug", "old-closed", "old-epic", "old-standalone", "old-task"
        ] and
        (.plan.semantic_baseline.sha256 | test("^[0-9a-f]{64}$")) and
        .plan.target_backend == "dolt-embedded" and
        .plan.source_observation.tree_sha256 == .source.tree_sha256 and
        .plan.source_observation.digest_scope == "admission_observation" and
        .plan.source_identity == {
            issue_prefix: $issue_prefix,
            database: $database,
            project_id: $project_id
        } and
        .plan.source_binary == {
            path: $source_bd, version: "0.62.0", sha256: $source_sha
        } and
        .plan.source_runtime == {
            kind: "dolt", path: $source_dolt,
            version: "1.84.0", sha256: $runtime_sha
        } and
        .plan.target_binary == {
            path: $target_bd, version: "1.1.0", sha256: $target_sha
        }
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label omitted a fully bound effectful plan: $RUN_STDOUT"
    EFFECTFUL_PLAN=$(jq -er '.plan.digest' <<< "$RUN_STDOUT") ||
        fail "$label did not expose a plan digest"
    assert_unchanged "$ws" "$before" "$label"
}

assert_bridge_error() {
    local label="$1" ws="$2" expected_exit="$3" mode="$4"
    local status="$5" code="$6" before
    shift 6
    before=$(tree_fingerprint "$ws")
    run_bridge "$label" "$ws" "$@"
    [ "$RUN_STATUS" -eq "$expected_exit" ] ||
        fail "$label exit=$RUN_STATUS, want $expected_exit: $RUN_STDOUT $RUN_STDERR"
    assert_common_json "$mode" "$status" none
    jq -e --arg code "$code" \
        '.retryable == false and .code == $code' \
        <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label lacked stable $code refusal: $RUN_STDOUT"
    assert_unchanged "$ws" "$before" "$label"
}

call_count() {
    local log="$1" command="$2" count
    count=$(grep -Ec "^argv=.* ${command}( |$)" "$log" 2>/dev/null) || true
    printf '%s\n' "${count:-0}"
}

# Production must never select an inherited helper executable for destructive
# publication. The only supported test seam is a validated, fail-only mode.
unsafe_mv_override_ws="$tmp/unsafe-mv-helper-override"
new_v062_workspace "$unsafe_mv_override_ws"
unsafe_mv_override_before=$(tree_fingerprint "$unsafe_mv_override_ws")
BRIDGE_TEST_MV_BIN="$OLD_NO_CLOBBER_MV" \
    run_bridge unsafe-mv-helper-override "$unsafe_mv_override_ws" \
        --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$unsafe_mv_override_ws"
[ "$RUN_STATUS" -eq 2 ] ||
    fail "unsafe mv helper override exit=$RUN_STATUS, want usage refusal: $RUN_STDOUT $RUN_STDERR"
assert_common_json inspect usage_error none
jq -e '
    .retryable == false and .code == "invalid_environment"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "unsafe mv helper override was accepted: $RUN_STDOUT"
assert_unchanged "$unsafe_mv_override_ws" "$unsafe_mv_override_before" \
    "unsafe mv helper override"

# A failed file hash inside the complete-source fingerprint must propagate to
# inspection. A digest over the successfully read prefix is not authorization.
fingerprint_failure_ws="$tmp/effectful-fingerprint-hash-failure"
new_v062_workspace "$fingerprint_failure_ws"
fingerprint_failure_before=$(tree_fingerprint "$fingerprint_failure_ws")
BRIDGE_TEST_FINGERPRINT_FAILURE=hash \
    run_bridge effectful-fingerprint-hash-failure "$fingerprint_failure_ws" \
        --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$fingerprint_failure_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "fingerprint hash failure exit=$RUN_STATUS, want refusal: $RUN_STDOUT $RUN_STDERR"
assert_common_json inspect refused none
jq -e '
    .retryable == true and .code == "source_unverifiable"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "fingerprint hash failure was not propagated: $RUN_STDOUT"
assert_unchanged "$fingerprint_failure_ws" "$fingerprint_failure_before" \
    "fingerprint hash failure"

effect_ws="$tmp/effectful-canonical"
new_v062_workspace "$effect_ws"
effect_before=$(tree_fingerprint "$effect_ws")
inspect_effectful_plan effectful-inspect "$effect_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
canonical_plan="$EFFECTFUL_PLAN"
canonical_plan_json=$(jq -Sc '.plan' <<< "$RUN_STDOUT")
canonical_source_tree=$(jq -er '.plan.source_observation.tree_sha256' \
    <<< "$RUN_STDOUT")
grep -E '^argv=.* config get issue_prefix --json$' "$SOURCE_LOG" >/dev/null ||
    fail "effectful inspect did not read the authenticated v0.62 issue prefix"
grep -E '^argv=.* --host .*project_id.*_project_id' \
    "$SOURCE_DOLT_LOG" >/dev/null ||
    fail "effectful inspect did not authenticate the v0.62 database project ID"

# Identical inspection is deterministic, while every executable identity is
# bound by bytes and therefore changes the consent digest when it changes.
inspect_effectful_plan effectful-inspect-repeat "$effect_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
[ "$EFFECTFUL_PLAN" = "$canonical_plan" ] ||
    fail "identical effectful inspect produced a different plan digest"
[ "$(jq -Sc '.plan' <<< "$RUN_STDOUT")" = "$canonical_plan_json" ] ||
    fail "identical effectful inspect produced a different plan"

# Unknown bytes in the authenticated /tmp runtime are preserved even after
# the owner exits; the real guardian must observe that exit and finish without
# receiving TERM.
runtime_unknown_phase_dir="$tmp/effectful-runtime-unknown-phase"
mkdir -m 700 "$runtime_unknown_phase_dir"
touch "$runtime_unknown_phase_dir/guardian-cooperative-shutdown.enabled"
runtime_unknown_before=$(tree_fingerprint "$effect_ws")
BRIDGE_TEST_RUNTIME_UNKNOWN_ENTRY=inject \
BRIDGE_TEST_PHASE_DIR="$runtime_unknown_phase_dir" \
    run_bridge effectful-runtime-unknown "$effect_ws" \
        --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "runtime unknown-entry inspect failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json inspect planned none
runtime_unknown_root=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "runtime unknown-entry case did not expose its private root"
[ -f "$runtime_unknown_root/unexpected-runtime-entry" ] ||
    fail "runtime cleanup deleted an unexpected entry"
for ((attempt = 0; attempt < 400; attempt++)); do
    [ -f "$runtime_unknown_phase_dir/runtime-guardian.done" ] && break
    sleep 0.025
done
[ -f "$runtime_unknown_phase_dir/runtime-guardian.started" ] &&
    [ -f "$runtime_unknown_phase_dir/runtime-guardian.done" ] ||
    fail "runtime guardian did not observe owner exit after cleanup refusal"
[ ! -e "$runtime_unknown_phase_dir/runtime-guardian.term" ] ||
    fail "runtime guardian received TERM during cleanup refusal"
[ "$(tree_fingerprint "$effect_ws")" = "$runtime_unknown_before" ] ||
    fail "runtime unknown-entry inspect mutated the workspace"
rm -rf -- "$runtime_unknown_root"

# Historical config/export/show must be pinned to the private server owned by
# this bridge. A stale runtime port file and active config.yaml are data-routing
# inputs, not authority to contact another server during semantic extraction.
source_route_ws="$tmp/effectful-source-route-override"
new_v062_workspace "$source_route_ws"
printf '%s\n' 29998 > "$source_route_ws/.beads/dolt-server.port"
cat > "$source_route_ws/.beads/config.yaml" <<'EOF'
dolt:
  host: poison.invalid
  port: 29998
  database: poison_database
EOF
printf '%s\n' 'require explicit private source route' \
    > "$source_route_ws/.beads/require-owned-source-route"
inspect_effectful_plan source-route-override-plan "$source_route_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"

SOURCE_BD_ALT="$tmp/fake-bd-v0.62.0-byte-variant"
SOURCE_DOLT_ALT="$tmp/fake-dolt-1.84.0-byte-variant"
TARGET_BD_ALT="$tmp/fake-bd-current-byte-variant"
cp -f -- "$SOURCE_BD" "$SOURCE_BD_ALT"
cp -f -- "$SOURCE_DOLT" "$SOURCE_DOLT_ALT"
cp -f -- "$TARGET_BD" "$TARGET_BD_ALT"
printf '\n# source identity variant\n' >> "$SOURCE_BD_ALT"
printf '\n# runtime identity variant\n' >> "$SOURCE_DOLT_ALT"
printf '\n# target identity variant\n' >> "$TARGET_BD_ALT"
chmod +x "$SOURCE_BD_ALT" "$SOURCE_DOLT_ALT" "$TARGET_BD_ALT"
SOURCE_BD_LINK="$tmp/fake-bd-v0.62.0-link"
SOURCE_DOLT_LINK="$tmp/fake-dolt-1.84.0-link"
ln -s "$SOURCE_BD" "$SOURCE_BD_LINK"
ln -s "$SOURCE_DOLT" "$SOURCE_DOLT_LINK"

inspect_effectful_plan source-identity-plan "$effect_ws" \
    "$SOURCE_BD_ALT" "$SOURCE_DOLT" "$TARGET_BD"
[ "$EFFECTFUL_PLAN" != "$canonical_plan" ] ||
    fail "source binary identity was not bound into the plan"
inspect_effectful_plan runtime-identity-plan "$effect_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT_ALT" "$TARGET_BD"
[ "$EFFECTFUL_PLAN" != "$canonical_plan" ] ||
    fail "source runtime identity was not bound into the plan"
inspect_effectful_plan target-identity-plan "$effect_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD_ALT"
[ "$EFFECTFUL_PLAN" != "$canonical_plan" ] ||
    fail "target binary identity was not bound into the plan"
assert_unchanged "$effect_ws" "$effect_before" "all effectful planning"

# Source and runtime paths are explicit, absolute, release-qualified inputs.
# A syntactically valid expected digest is supplied so these refusals prove the
# input check rather than merely falling into plan parsing.
assert_bridge_error source-binary-omitted "$effect_ws" 1 apply refused \
    source_binary_missing \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-dolt "$SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-binary-absent "$effect_ws" 1 apply refused \
    source_binary_missing \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$tmp/does-not-exist-bd" \
    --source-dolt "$SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-binary-relative "$effect_ws" 1 apply refused \
    source_binary_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd fake-bd-v0.62.0 \
    --source-dolt "$SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-binary-wrong-version "$effect_ws" 1 apply refused \
    source_binary_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$BAD_SOURCE_BD" \
    --source-dolt "$SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-binary-symlink "$effect_ws" 1 apply refused \
    source_binary_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD_LINK" \
    --source-dolt "$SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-runtime-omitted "$effect_ws" 1 apply refused \
    source_runtime_missing \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" --workspace "$effect_ws"
assert_bridge_error source-runtime-absent "$effect_ws" 1 apply refused \
    source_runtime_missing \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" \
    --source-dolt "$tmp/does-not-exist-dolt" --workspace "$effect_ws"
assert_bridge_error source-runtime-relative "$effect_ws" 1 apply refused \
    source_runtime_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" \
    --source-dolt fake-dolt-1.84.0 --workspace "$effect_ws"
assert_bridge_error source-runtime-wrong-version "$effect_ws" 1 apply refused \
    source_runtime_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" \
    --source-dolt "$BAD_SOURCE_DOLT" --workspace "$effect_ws"
assert_bridge_error source-runtime-symlink "$effect_ws" 1 apply refused \
    source_runtime_invalid \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" \
    --source-dolt "$SOURCE_DOLT_LINK" --workspace "$effect_ws"
BRIDGE_TEST_GUARDIAN_START_FAILURE=runtime_guardian_start \
    assert_bridge_error runtime-guardian-start-unverifiable \
        "$effect_ws" 1 apply refused target_binary_invalid \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"

wrong_plan=$(printf 'f%.0s' {1..64})
[ "$wrong_plan" != "$canonical_plan" ] ||
    wrong_plan=$(printf 'e%.0s' {1..64})
assert_bridge_error wrong-plan "$effect_ws" 1 apply refused plan_mismatch \
    --apply --yes --expect-plan "$wrong_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$effect_ws"
assert_bridge_error changed-source-binary "$effect_ws" 1 apply refused \
    plan_mismatch \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD_ALT" --source-dolt "$SOURCE_DOLT" \
    --workspace "$effect_ws"
assert_bridge_error changed-source-runtime "$effect_ws" 1 apply refused \
    plan_mismatch \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT_ALT" \
    --workspace "$effect_ws"
BRIDGE_TEST_TARGET="$TARGET_BD_ALT" \
    assert_bridge_error changed-target-binary "$effect_ws" 1 apply refused \
        plan_mismatch \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"

# Apply must re-observe the original under its operation fence. A source byte
# changed after planning invalidates consent and is never imported.
drift_ws="$tmp/effectful-source-drift"
new_v062_workspace "$drift_ws"
inspect_effectful_plan source-drift-plan "$drift_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
drift_plan="$EFFECTFUL_PLAN"
printf '%s\n' '{"drift":true}' \
    > "$drift_ws/.beads/dolt/smoke/.dolt/config.json"
assert_bridge_error source-drift-apply "$drift_ws" 1 apply refused \
    plan_mismatch \
    --apply --yes --expect-plan "$drift_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$drift_ws"

# Hold the first apply immediately after it owns the operation fence but before
# its mandatory reinspection. A concurrent apply must observe the fence, and a
# source write in this overlap window must invalidate the first consent digest.
overlap_ws="$tmp/effectful-overlap-before-reinspect"
new_v062_workspace "$overlap_ws"
inspect_effectful_plan overlap-plan "$overlap_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
overlap_plan="$EFFECTFUL_PLAN"
overlap_phase_dir="$tmp/effectful-overlap-phase"
mkdir -m 700 "$overlap_phase_dir"
release_transaction_gap_phases "$overlap_phase_dir"
BRIDGE_TEST_PHASE_DIR="$overlap_phase_dir" \
    start_bridge_at_phase overlap-first "$overlap_ws" \
        --apply --yes --expect-plan "$overlap_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$overlap_ws"
wait_for_phase "$overlap_phase_dir" after_operation_fence_before_reinspect \
    "first overlapping apply"
[ -d "$overlap_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -L "$overlap_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "first overlapping apply did not publish its physical operation fence"
[ -d "$overlap_ws/.beads" ] &&
    [ ! -e "$overlap_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$overlap_ws/.beads-v0.62.0-rollback" ] ||
    fail "operation-fence phase exposed an impossible pre-reinspection layout"
overlap_fenced_before=$(content_fingerprint "$overlap_ws")
run_bridge overlap-second "$overlap_ws" \
    --apply --yes --expect-plan "$overlap_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$overlap_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "second overlapping apply exit=$RUN_STATUS, want refusal exit 1"
assert_common_json apply refused none
jq -e '
    .retryable == true and .code == "operation_in_progress"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "second overlapping apply did not observe the operation fence"
[ "$(content_fingerprint "$overlap_ws")" = "$overlap_fenced_before" ] ||
    fail "second overlapping apply changed the fenced workspace"
printf '%s\n' '{"overlap_drift":true}' \
    > "$overlap_ws/.beads/dolt/smoke/.dolt/config.json"
overlap_drifted_source=$(content_fingerprint "$overlap_ws/.beads")
touch "$overlap_phase_dir/after_operation_fence_before_reinspect.continue"
finish_phase_bridge "drifted first apply"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "drifted first apply exit=$RUN_STATUS, want refusal exit 1: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply refused none
jq -e '
    .retryable == false and .code == "plan_mismatch"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "fenced reinspection did not reject overlapping source drift"
[ "$(content_fingerprint "$overlap_ws/.beads")" = "$overlap_drifted_source" ] ||
    fail "drift refusal did not preserve the externally changed source"
[ ! -e "$overlap_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$overlap_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$overlap_ws/.beads-v0.62.0-rollback" ] ||
    fail "drift refusal leaked a transaction artifact"

identity_mismatch_ws="$tmp/source-project-id-mismatch"
new_v062_workspace "$identity_mismatch_ws"
touch "$identity_mismatch_ws/.beads/database-project-id-mismatch"
identity_mismatch_before=$(tree_fingerprint "$identity_mismatch_ws")
run_bridge source-project-id-mismatch "$identity_mismatch_ws" \
    --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$identity_mismatch_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "source project-ID mismatch exit=$RUN_STATUS, want refusal exit 1"
assert_common_json inspect refused none
jq -e '
    .retryable == false and .code == "source_identity_mismatch"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "source project-ID mismatch lacked a stable refusal: $RUN_STDOUT"
assert_unchanged "$identity_mismatch_ws" "$identity_mismatch_before" \
    "source project-ID mismatch"

# Executable identity is authenticated before the operation fence and then
# executed only through private copies. Replacing every caller-supplied path
# after the fence cannot redirect the already-authorized in-flight apply.
pinning_ws="$tmp/effectful-executable-pinning"
new_v062_workspace "$pinning_ws"
pinning_source_bd="$tmp/pinning-source-bd"
pinning_source_dolt="$tmp/pinning-source-dolt"
pinning_target_bd="$tmp/pinning-target-bd"
pinning_source_log="$tmp/pinning-source-bd.log"
pinning_source_dolt_log="$tmp/pinning-source-dolt.log"
pinning_target_log="$tmp/pinning-target-bd.log"
make_fake_source_bd "$pinning_source_bd" 0.62.0 "$pinning_source_log"
make_fake_source_dolt "$pinning_source_dolt" 1.84.0 \
    "$pinning_source_dolt_log"
make_fake_bd "$pinning_target_bd" 1.1.0 embedded "$pinning_target_log"
inspect_effectful_plan executable-pinning-plan "$pinning_ws" \
    "$pinning_source_bd" "$pinning_source_dolt" "$pinning_target_bd"
pinning_plan="$EFFECTFUL_PLAN"
pinning_source_sha=$(sha256sum "$pinning_source_bd" | awk '{print $1}')
pinning_source_dolt_sha=$(sha256sum "$pinning_source_dolt" | awk '{print $1}')
pinning_target_sha=$(sha256sum "$pinning_target_bd" | awk '{print $1}')
pinning_phase_dir="$tmp/effectful-executable-pinning-phase"
pinning_tripwire_log="$tmp/effectful-executable-pinning-tripwire.log"
mkdir -m 700 "$pinning_phase_dir"
release_transaction_gap_phases "$pinning_phase_dir"
touch "$pinning_phase_dir/before_source_rename.continue"
touch "$pinning_phase_dir/after_source_rename_before_target_publish.continue"
touch "$pinning_phase_dir/after_target_publish.continue"
BRIDGE_TEST_PHASE_DIR="$pinning_phase_dir" \
BRIDGE_TEST_TARGET="$pinning_target_bd" \
    start_bridge_at_phase executable-pinning-apply "$pinning_ws" \
        --apply --yes --expect-plan "$pinning_plan" \
        --source-bd "$pinning_source_bd" \
        --source-dolt "$pinning_source_dolt" \
        --workspace "$pinning_ws"
wait_for_phase "$pinning_phase_dir" after_operation_fence_before_reinspect \
    "executable-pinning apply"
pinning_runtime_dir=$(last_private_runtime_from_log "$pinning_source_log") ||
    fail "executable-pinning apply did not expose its private runtime"
[ -d "$pinning_runtime_dir" ] && [ ! -L "$pinning_runtime_dir" ] &&
    [ "$(stat -c '%a' "$pinning_runtime_dir")" = 700 ] &&
    [ "$(stat -c '%d' "$pinning_runtime_dir")" = \
        "$(stat -c '%d' "$pinning_ws")" ] ||
    fail "private runtime is not an owner-only directory on the workspace filesystem"
pinning_initial_home=$(last_clean_home_from_log "$pinning_source_log") ||
    fail "executable-pinning apply did not expose its isolated home"
assert_scratch_is_beneath_runtime "$pinning_runtime_dir" \
    "$pinning_initial_home" "initial clean home"
[ "$(sha256sum "$pinning_runtime_dir/source-bd" | awk '{print $1}')" = \
    "$pinning_source_sha" ] &&
    [ "$(sha256sum "$pinning_runtime_dir/source-dolt" | awk '{print $1}')" = \
        "$pinning_source_dolt_sha" ] &&
    [ "$(sha256sum "$pinning_runtime_dir/target-bd" | awk '{print $1}')" = \
        "$pinning_target_sha" ] ||
    fail "private runtime bytes differ from the authorized executables"
: > "$pinning_source_log"
: > "$pinning_source_dolt_log"
: > "$pinning_target_log"
make_executable_tripwire \
    "$pinning_source_bd" source-bd "$pinning_tripwire_log"
make_executable_tripwire \
    "$pinning_source_dolt" source-dolt "$pinning_tripwire_log"
make_executable_tripwire \
    "$pinning_target_bd" target-bd "$pinning_tripwire_log"
[ "$(sha256sum "$pinning_source_bd" | awk '{print $1}')" != \
    "$pinning_source_sha" ] &&
    [ "$(sha256sum "$pinning_source_dolt" | awk '{print $1}')" != \
        "$pinning_source_dolt_sha" ] &&
    [ "$(sha256sum "$pinning_target_bd" | awk '{print $1}')" != \
        "$pinning_target_sha" ] ||
    fail "executable-pinning tripwires did not replace every original path"
touch "$pinning_phase_dir/after_operation_fence_before_reinspect.continue"
wait_for_phase "$pinning_phase_dir" before_receipt_publish \
    "executable-pinning apply scratch consolidation"
pinning_active_home=$(last_clean_home_from_log "$pinning_source_log") ||
    fail "post-fence source reads did not expose their isolated home"
pinning_source_copy=$(last_source_copy_from_log "$pinning_source_log") ||
    fail "post-fence source reads did not expose their expendable source copy"
pinning_semantic_probe=$(last_semantic_probe_from_log "$pinning_target_log") ||
    fail "staged import did not expose its semantic probe"
[ "$pinning_active_home" = "$pinning_initial_home" ] ||
    fail "clean home changed across pinned subprocess calls"
assert_scratch_is_beneath_runtime "$pinning_runtime_dir" \
    "$pinning_active_home" "active clean home"
assert_scratch_is_beneath_runtime "$pinning_runtime_dir" \
    "$pinning_source_copy" "expendable source copy"
assert_scratch_is_beneath_runtime "$pinning_runtime_dir" \
    "$pinning_semantic_probe" "semantic probe"
touch "$pinning_phase_dir/before_receipt_publish.continue"
finish_phase_bridge "executable-pinning apply"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "executable-pinning apply followed a replaced path: $RUN_STDOUT $RUN_STDERR"
[ ! -e "$pinning_tripwire_log" ] ||
    fail "in-flight apply invoked a replaced executable: $(<"$pinning_tripwire_log")"
wait_for_path_absence "$pinning_runtime_dir" \
    "successful executable-pinning apply runtime root"
for pinning_scratch in \
    "$pinning_initial_home" "$pinning_active_home" \
    "$pinning_source_copy" "$pinning_semantic_probe"; do
    [ ! -e "$pinning_scratch" ] && [ ! -L "$pinning_scratch" ] ||
        fail "successful executable-pinning apply leaked scratch: $pinning_scratch"
done
grep -F "argv=$pinning_runtime_dir/source-bd config get issue_prefix --json" \
    "$pinning_source_log" >/dev/null &&
    grep -F "argv=$pinning_runtime_dir/source-bd export" \
        "$pinning_source_log" >/dev/null &&
    grep -F "argv=$pinning_runtime_dir/source-bd show" \
        "$pinning_source_log" >/dev/null ||
    fail "post-fence source reads did not use the private source bd"
grep -F "argv=$pinning_runtime_dir/source-dolt sql-server" \
    "$pinning_source_dolt_log" >/dev/null &&
    grep -F "argv=$pinning_runtime_dir/source-dolt --host" \
        "$pinning_source_dolt_log" >/dev/null ||
    fail "post-fence source runtime calls did not use the private Dolt"
for target_command in \
    __migration-v062-inspect init import export config; do
    grep -F "argv=$pinning_runtime_dir/target-bd $target_command" \
        "$pinning_target_log" >/dev/null ||
        fail "post-fence target $target_command did not use the private target bd"
done
assert_common_json apply succeeded workspace_migrated
jq -e --arg plan "$pinning_plan" '
    .retryable == false and .plan.digest == $plan and
    .verification.semantic_scope_verified == true and
    .verification.separate_process_reopen == true
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "executable-pinning apply overstated verification: $RUN_STDOUT"
[ ! -e "$pinning_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$pinning_ws/.beads-v0.62.0-staging" ] &&
    [ -d "$pinning_ws/.beads-v0.62.0-rollback" ] ||
    fail "executable-pinning apply leaked transaction artifacts"
while IFS= read -r pinning_source_dolt_pid; do
    pid_is_running "$pinning_source_dolt_pid" &&
        fail "private source Dolt child $pinning_source_dolt_pid leaked"
done < "${pinning_source_dolt_log}.pids"

# General v0.62 data is intentionally not qualified yet. The negative marker
# lives inside .beads so it survives the mandatory expendable source copy.
semantic_ws="$tmp/semantic-unqualified"
new_v062_workspace "$semantic_ws"
printf '%s\n' 'six-record corpus is outside v062_lossless_core_v1' \
    > "$semantic_ws/.beads/unqualified-semantic-scope"
assert_bridge_error semantic-scope "$semantic_ws" 1 inspect refused \
    source_semantic_scope_unqualified \
    --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$semantic_ws"

# Preserve the canonical count and IDs while introducing one unsupported
# historical field. Qualification must be an exact semantic allowlist rather
# than a five-row heuristic.
unsupported_ws="$tmp/semantic-unsupported-same-count"
new_v062_workspace "$unsupported_ws"
printf '%s\n' 'five-record corpus contains an unsupported field' \
    > "$unsupported_ws/.beads/unsupported-semantic-scope"
assert_bridge_error semantic-unsupported-same-count "$unsupported_ws" \
    1 inspect refused source_semantic_scope_unqualified \
    --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$unsupported_ws"

# Top-level allowlisting is insufficient: dependency metadata/thread IDs and
# unqualified comment fields would be silently discarded by canonicalization.
nested_dependency_ws="$tmp/semantic-nested-dependency"
new_v062_workspace "$nested_dependency_ws"
printf '%s\n' 'five-record corpus contains nested dependency state' \
    > "$nested_dependency_ws/.beads/nested-dependency-semantic-scope"
assert_bridge_error semantic-nested-dependency "$nested_dependency_ws" \
    1 inspect refused source_semantic_scope_unqualified \
    --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$nested_dependency_ws"

nested_comment_ws="$tmp/semantic-nested-comment"
new_v062_workspace "$nested_comment_ws"
printf '%s\n' 'five-record corpus contains an unqualified nested comment field' \
    > "$nested_comment_ws/.beads/nested-comment-semantic-scope"
assert_bridge_error semantic-nested-comment "$nested_comment_ws" \
    1 inspect refused source_semantic_scope_unqualified \
    --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$nested_comment_ws"

for source_audit_field in \
    dependency-created-at dependency-created-by \
    comment-id comment-issue-id comment-created-at; do
    source_audit_ws="$tmp/semantic-audit-source-$source_audit_field"
    new_v062_workspace "$source_audit_ws"
    printf '%s\n' "$source_audit_field is empty" \
        > "$source_audit_ws/.beads/audit-source-$source_audit_field"
    assert_bridge_error "semantic-audit-source-$source_audit_field" \
        "$source_audit_ws" 1 inspect refused \
        source_semantic_scope_unqualified \
        --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$source_audit_ws"
done

assert_unsafe_target_candidate_rejected() {
    local label="$1" target_bd="$2" expected_injection="$3"
    local ws plan source_before
    ws="$tmp/$label"
    new_v062_workspace "$ws"
    inspect_effectful_plan "$label-plan" "$ws" \
        "$SOURCE_BD" "$SOURCE_DOLT" "$target_bd"
    plan="$EFFECTFUL_PLAN"
    source_before=$(content_fingerprint "$ws/.beads")
    BRIDGE_TEST_TARGET="$target_bd" \
        run_bridge "$label-apply" "$ws" \
            --apply --yes --expect-plan "$plan" \
            --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
            --workspace "$ws"
    [ "$RUN_STATUS" -eq 1 ] ||
        fail "$label exit=$RUN_STATUS, want target-verification failure: $RUN_STDOUT $RUN_STDERR"
    assert_common_json apply failed none
    jq -e '
        .retryable == false and .code == "target_verification_failed"
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label did not reject the unsafe staged target: $RUN_STDOUT"
    [ -f "${target_bd}.injected" ] &&
        grep -Fqx -- "$expected_injection" "${target_bd}.injected" ||
        fail "$label refused before injecting $expected_injection"
    case "$expected_injection" in
        lossy-*)
            [ -f "${target_bd}.exported" ] &&
                grep -Fqx -- "$expected_injection" \
                    "${target_bd}.exported" ||
                fail "$label refused before exporting the lossy target"
            ;;
    esac
    [ "$(content_fingerprint "$ws/.beads")" = "$source_before" ] &&
        [ ! -e "$ws/.beads-v0.62.0-rollback" ] &&
        [ ! -e "$ws/.beads-v0.62.0-staging" ] &&
        [ ! -e "$ws/.beads-v0.62.0-migration.lock" ] ||
        fail "$label changed the source or leaked transaction artifacts"
}

# The admitted audit fields are part of the lossless contract. Verification
# must compare them through current export, not a show projection that can omit
# dependency provenance or regenerate comment identity.
for lossy_audit_field in \
    dependency-created-at dependency-created-by \
    comment-id comment-issue-id comment-created-at; do
    assert_unsafe_target_candidate_rejected \
        "effectful-lossy-$lossy_audit_field-target" \
        "$tmp/fake-bd-lossy-$lossy_audit_field-target" \
        "lossy-$lossy_audit_field"
done

# Neither active provider routing nor a symlinked embedded repository is a
# publishable target, even if all five issue records otherwise reopen.
assert_unsafe_target_candidate_rejected \
    effectful-active-target-config "$ROUTED_TARGET_BD" active-config
assert_unsafe_target_candidate_rejected \
    effectful-late-active-target-config "$LATE_ROUTED_TARGET_BD" \
    late-active-config
assert_unsafe_target_candidate_rejected \
    effectful-symlink-target-dolt "$SYMLINK_DOLT_TARGET_BD" symlink-dolt
assert_unsafe_target_candidate_rejected \
    effectful-symlink-target-database "$SYMLINK_DATABASE_TARGET_BD" \
    symlink-database

target_inits_before_identity_refusal=$(call_count "$TARGET_LOG" init)
target_imports_before_identity_refusal=$(call_count "$TARGET_LOG" import)
for incompatible_prefix in dotted trailing-hyphen; do
    identity_ws="$tmp/identity-prefix-$incompatible_prefix"
    new_v062_workspace "$identity_ws"
    printf '%s\n' "$incompatible_prefix prefix cannot round-trip" \
        > "$identity_ws/.beads/source-prefix-$incompatible_prefix"
    BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
        assert_bridge_error "identity-prefix-$incompatible_prefix" \
            "$identity_ws" 1 inspect refused source_identity_unsupported \
            --inspect --source-bd "$SOURCE_BD" \
            --source-dolt "$SOURCE_DOLT" --workspace "$identity_ws"
done

identity_database_ws="$tmp/identity-database-hyphen"
new_v062_workspace "$identity_database_ws"
mv -f -- "$identity_database_ws/.beads/dolt/smoke" \
    "$identity_database_ws/.beads/dolt/smoke-db"
jq '.dolt_database = "smoke-db"' \
    "$identity_database_ws/.beads/metadata.json" \
    > "$identity_database_ws/.beads/metadata.json.tmp"
mv -f -- "$identity_database_ws/.beads/metadata.json.tmp" \
    "$identity_database_ws/.beads/metadata.json"
BRIDGE_TEST_TARGET="$REAL_TARGET_BD" \
    assert_bridge_error identity-database-hyphen "$identity_database_ws" \
        1 inspect refused source_identity_unsupported \
        --inspect --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$identity_database_ws"
[ "$(call_count "$TARGET_LOG" init)" -eq \
    "$target_inits_before_identity_refusal" ] &&
    [ "$(call_count "$TARGET_LOG" import)" -eq \
        "$target_imports_before_identity_refusal" ] ||
    fail "identity refusal reached target init or import"

# Rollback and side-by-side staging destinations are never adopted, replaced,
# or cleaned when they pre-exist, even when their contents look plausible.
rollback_collision_ws="$tmp/effectful-rollback-destination"
new_v062_workspace "$rollback_collision_ws"
inspect_effectful_plan effectful-rollback-plan "$rollback_collision_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
rollback_collision_plan="$EFFECTFUL_PLAN"
mkdir -p "$rollback_collision_ws/.beads-v0.62.0-rollback"
printf '%s\n' 'unrelated retained data' \
    > "$rollback_collision_ws/.beads-v0.62.0-rollback/sentinel"
assert_bridge_error effectful-rollback-collision "$rollback_collision_ws" \
    1 apply refused rollback_collision \
    --apply --yes --expect-plan "$rollback_collision_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$rollback_collision_ws"

staging_collision_ws="$tmp/effectful-staging-destination"
new_v062_workspace "$staging_collision_ws"
inspect_effectful_plan effectful-staging-plan "$staging_collision_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
staging_collision_plan="$EFFECTFUL_PLAN"
mkdir -p "$staging_collision_ws/.beads-v0.62.0-staging"
printf '%s\n' 'unrelated staging data' \
    > "$staging_collision_ws/.beads-v0.62.0-staging/sentinel"
assert_bridge_error effectful-staging-collision "$staging_collision_ws" \
    1 apply refused staging_collision \
    --apply --yes --expect-plan "$staging_collision_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$staging_collision_ws"

# Cleanup authority is limited to the bridge's known staging entries. An
# unexpected descendant survives for inspection after the target commit and
# converts success into a typed cleanup failure.
unknown_staging_ws="$tmp/effectful-unknown-staging-entry"
new_v062_workspace "$unknown_staging_ws"
inspect_effectful_plan effectful-unknown-staging-plan "$unknown_staging_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
unknown_staging_plan="$EFFECTFUL_PLAN"
unknown_staging_phase_dir="$tmp/effectful-unknown-staging-phase"
mkdir -m 700 "$unknown_staging_phase_dir"
touch \
    "$unknown_staging_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$unknown_staging_phase_dir/after_operation_fence_before_reinspect.continue" \
    "$unknown_staging_phase_dir/before_receipt_publish.continue" \
    "$unknown_staging_phase_dir/before_source_rename.continue" \
    "$unknown_staging_phase_dir/after_source_rename_before_target_publish.continue" \
    "$unknown_staging_phase_dir/after_target_publish.continue"
BRIDGE_TEST_PHASE_DIR="$unknown_staging_phase_dir" \
    start_bridge_at_phase effectful-unknown-staging "$unknown_staging_ws" \
        --apply --yes --expect-plan "$unknown_staging_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$unknown_staging_ws"
wait_for_phase "$unknown_staging_phase_dir" \
    after_staging_publish_before_journal_update \
    "effectful unknown staging entry"
printf '%s\n' 'unowned staging bytes' \
    > "$unknown_staging_ws/.beads-v0.62.0-staging/unexpected-entry"
touch \
    "$unknown_staging_phase_dir/after_staging_publish_before_journal_update.continue"
finish_phase_bridge "effectful unknown staging entry"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "unknown staging cleanup exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed workspace_migrated
jq -e '.retryable == false and .code == "cleanup_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "unknown staging cleanup was misclassified: $RUN_STDOUT"
[ -f "$unknown_staging_ws/.beads-v0.62.0-staging/unexpected-entry" ] ||
    fail "cleanup deleted an unexpected staging entry"

# A rename can complete before a later postcondition reports failure. Recovery
# must reconcile the original inode and restore it before claiming effect:none.
source_rename_false_failure_ws="$tmp/effectful-source-rename-false-failure"
new_v062_workspace "$source_rename_false_failure_ws"
inspect_effectful_plan effectful-source-rename-false-failure-plan \
    "$source_rename_false_failure_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
source_rename_false_failure_plan="$EFFECTFUL_PLAN"
source_rename_false_failure_digest=$(content_fingerprint \
    "$source_rename_false_failure_ws/.beads")
BRIDGE_TEST_MV_MODE=fail_after_source_rename \
    run_bridge effectful-source-rename-false-failure \
        "$source_rename_false_failure_ws" \
        --apply --yes --expect-plan "$source_rename_false_failure_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$source_rename_false_failure_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "source rename false failure exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '
    .retryable == true and .code == "source_rename_failed"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "source rename false failure was misclassified: $RUN_STDOUT"
[ -d "$source_rename_false_failure_ws/.beads" ] &&
    [ "$(content_fingerprint "$source_rename_false_failure_ws/.beads")" = \
        "$source_rename_false_failure_digest" ] &&
    [ ! -e "$source_rename_false_failure_ws/.beads-v0.62.0-rollback" ] &&
    [ ! -e "$source_rename_false_failure_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$source_rename_false_failure_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "source rename false failure did not restore the exact source"
run_bridge effectful-source-rename-false-failure-retry \
    "$source_rename_false_failure_ws" \
    --apply --yes --expect-plan "$source_rename_false_failure_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$source_rename_false_failure_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "source rename false-failure retry did not succeed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated

# The workspace flock belongs only to a dedicated holder. A direct child that
# outlives a SIGKILLed bridge must not inherit the lock or delay exact-plan
# recovery.
lock_handoff_ws="$tmp/effectful-workspace-lock-handoff"
new_v062_workspace "$lock_handoff_ws"
inspect_effectful_plan effectful-workspace-lock-handoff-plan \
    "$lock_handoff_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
lock_handoff_plan="$EFFECTFUL_PLAN"
lock_handoff_phase_dir="$tmp/effectful-workspace-lock-handoff-phase"
mkdir -m 700 "$lock_handoff_phase_dir"
release_transaction_gap_phases "$lock_handoff_phase_dir"
touch "$lock_handoff_phase_dir/after_operation_fence_before_reinspect.continue"
BRIDGE_TEST_FINGERPRINT_FAILURE=hold \
BRIDGE_TEST_IDENTITY_PROBE_FAILURE=owner_unverifiable \
BRIDGE_TEST_PHASE_DIR="$lock_handoff_phase_dir" \
    start_bridge_at_phase effectful-workspace-lock-handoff \
        "$lock_handoff_ws" \
        --apply --yes --expect-plan "$lock_handoff_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$lock_handoff_ws"
for ((attempt = 0; attempt < 400; attempt++)); do
    [ -s "$lock_handoff_phase_dir/workspace-lock-child.identities" ] && break
    pid_is_running "$ASYNC_BRIDGE_PID" ||
        fail "workspace-lock handoff bridge exited before its child started"
    sleep 0.025
done
[ -s "$lock_handoff_phase_dir/workspace-lock-child.identities" ] ||
    fail "workspace-lock handoff child did not start"
WORKSPACE_LOCK_TEST_IDENTITY_FILE=\
"$lock_handoff_phase_dir/workspace-lock-child.identities"
while IFS=' ' read -r pid start; do
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] && [[ "$start" =~ ^[0-9]+$ ]] &&
        pid_identity_is_running "$pid" "$start" ||
        fail "workspace-lock test child identity is not alive: $pid/$start"
done < "$WORKSPACE_LOCK_TEST_IDENTITY_FILE"
lock_handoff_runtime=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "workspace-lock handoff did not expose its private runtime"
IFS=' ' read -r lock_holder_pid lock_holder_start \
    < "$lock_handoff_runtime/.workspace-lock-ready" ||
    fail "workspace-lock holder readiness record is unreadable"
pid_identity_is_running "$lock_holder_pid" "$lock_holder_start" ||
    fail "workspace-lock holder identity is not live"
kill -TERM -- "$lock_holder_pid" 2>/dev/null ||
    fail "workspace-lock holder could not receive the TERM robustness probe"
sleep 0.1
pid_identity_is_running "$lock_holder_pid" "$lock_holder_start" ||
    fail "workspace-lock holder released on TERM while its owner was live"
if /usr/bin/flock -x -n "$lock_handoff_ws" /usr/bin/true; then
    fail "competing workspace flock succeeded while the bridge was alive"
fi
hard_kill_phase_bridge "effectful workspace-lock handoff"
while IFS=' ' read -r pid start; do
    pid_identity_is_running "$pid" "$start" ||
        fail "workspace-lock test child $pid did not outlive the bridge"
done < "$WORKSPACE_LOCK_TEST_IDENTITY_FILE"
lock_handoff_released=false
for ((attempt = 0; attempt < 400; attempt++)); do
    if /usr/bin/flock -x -n "$lock_handoff_ws" /usr/bin/true; then
        lock_handoff_released=true
        break
    fi
    sleep 0.025
done
$lock_handoff_released ||
    fail "an orphan child retained the workspace flock after bridge SIGKILL"
run_bridge effectful-workspace-lock-handoff-retry "$lock_handoff_ws" \
    --apply --yes --expect-plan "$lock_handoff_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$lock_handoff_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "workspace-lock handoff retry failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated
while IFS=' ' read -r pid start; do
    terminate_pid_identity_bounded "$pid" "$start" ||
        fail "workspace-lock test child $pid could not be terminated"
done < "$WORKSPACE_LOCK_TEST_IDENTITY_FILE"
WORKSPACE_LOCK_TEST_IDENTITY_FILE=""

# The operation fence and staging inode are published from one fully journaled
# bundle. SIGKILL in each rename gap must leave either no canonical transaction
# state or an authenticated stale state that the exact-plan retry can recover.
kill_bundle_ws="$tmp/effectful-kill-prepared-operation-bundle"
new_v062_workspace "$kill_bundle_ws"
inspect_effectful_plan effectful-kill-prepared-bundle-plan "$kill_bundle_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_bundle_plan="$EFFECTFUL_PLAN"
kill_bundle_source=$(content_fingerprint "$kill_bundle_ws/.beads")
kill_bundle_phase_dir="$tmp/effectful-kill-prepared-bundle-phase"
mkdir -m 700 "$kill_bundle_phase_dir"
BRIDGE_TEST_PHASE_DIR="$kill_bundle_phase_dir" \
    start_bridge_at_phase effectful-kill-prepared-bundle "$kill_bundle_ws" \
        --apply --yes --expect-plan "$kill_bundle_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_bundle_ws"
wait_for_phase "$kill_bundle_phase_dir" \
    after_operation_bundle_prepared_before_fence_publish \
    "SIGKILL after prepared operation bundle"
kill_bundle_runtime=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "prepared-bundle operation did not expose its runtime root"
[ -d "$kill_bundle_ws/.beads" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-rollback" ] ||
    fail "prepared operation bundle escaped into canonical workspace state"
hard_kill_phase_bridge "SIGKILL after prepared operation bundle"
wait_for_path_absence "$kill_bundle_runtime" \
    "SIGKILL prepared-bundle runtime root"
assert_no_workspace_runtime_artifacts "$kill_bundle_ws" \
    "SIGKILL after prepared operation bundle"
[ "$(content_fingerprint "$kill_bundle_ws/.beads")" = \
    "$kill_bundle_source" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$kill_bundle_ws/.beads-v0.62.0-rollback" ] ||
    fail "SIGKILL after prepared bundle changed canonical workspace state"
run_bridge effectful-kill-prepared-bundle-retry "$kill_bundle_ws" \
    --apply --yes --expect-plan "$kill_bundle_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_bundle_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after prepared-bundle SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated

kill_staging_gap_ws="$tmp/effectful-kill-staging-publication-gap"
new_v062_workspace "$kill_staging_gap_ws"
inspect_effectful_plan effectful-kill-staging-gap-plan "$kill_staging_gap_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_staging_gap_plan="$EFFECTFUL_PLAN"
kill_staging_gap_source=$(content_fingerprint "$kill_staging_gap_ws/.beads")
kill_staging_gap_phase_dir="$tmp/effectful-kill-staging-gap-phase"
mkdir -m 700 "$kill_staging_gap_phase_dir"
touch \
    "$kill_staging_gap_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$kill_staging_gap_phase_dir/after_operation_fence_before_reinspect.continue"
BRIDGE_TEST_PHASE_DIR="$kill_staging_gap_phase_dir" \
    start_bridge_at_phase effectful-kill-staging-gap "$kill_staging_gap_ws" \
        --apply --yes --expect-plan "$kill_staging_gap_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_staging_gap_ws"
wait_for_phase "$kill_staging_gap_phase_dir" \
    after_staging_publish_before_journal_update \
    "SIGKILL after staging publication"
kill_staging_gap_runtime=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "staging-gap operation did not expose its runtime root"
[ "$(content_fingerprint "$kill_staging_gap_ws/.beads")" = \
    "$kill_staging_gap_source" ] &&
    [ -f "$kill_staging_gap_ws/.beads-v0.62.0-migration.lock/journal.json" ] &&
    [ -d "$kill_staging_gap_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$kill_staging_gap_ws/.beads-v0.62.0-rollback" ] ||
    fail "staging publication gap was not completely journaled"
hard_kill_phase_bridge "SIGKILL after staging publication"
wait_for_path_absence "$kill_staging_gap_runtime" \
    "SIGKILL staging-publication runtime root"
run_bridge effectful-kill-staging-gap-retry "$kill_staging_gap_ws" \
    --apply --yes --expect-plan "$kill_staging_gap_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_staging_gap_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after staging-publication SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated
[ ! -e "$kill_staging_gap_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_staging_gap_ws/.beads-v0.62.0-staging" ] ||
    fail "staging-gap recovery left transaction artifacts"

kill_retired_fence_ws="$tmp/effectful-kill-retired-operation-fence"
new_v062_workspace "$kill_retired_fence_ws"
inspect_effectful_plan effectful-kill-retired-fence-plan \
    "$kill_retired_fence_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_retired_fence_plan="$EFFECTFUL_PLAN"
kill_retired_fence_phase_dir="$tmp/effectful-kill-retired-fence-phase"
mkdir -m 700 "$kill_retired_fence_phase_dir"
touch \
    "$kill_retired_fence_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$kill_retired_fence_phase_dir/after_operation_fence_before_reinspect.continue" \
    "$kill_retired_fence_phase_dir/after_staging_publish_before_journal_update.continue" \
    "$kill_retired_fence_phase_dir/before_receipt_publish.continue" \
    "$kill_retired_fence_phase_dir/before_source_rename.continue" \
    "$kill_retired_fence_phase_dir/after_source_rename_before_target_publish.continue" \
    "$kill_retired_fence_phase_dir/after_target_publish.continue" \
    "$kill_retired_fence_phase_dir/after_operation_fence_retired_before_private_cleanup.continue"
BRIDGE_TEST_FAILPOINT=after_private_children_deleted_before_root_rmdir \
BRIDGE_TEST_IDENTITY_PROBE_FAILURE=owner_unverifiable \
BRIDGE_TEST_PHASE_DIR="$kill_retired_fence_phase_dir" \
    start_bridge_at_phase effectful-kill-retired-fence \
        "$kill_retired_fence_ws" \
        --apply --yes --expect-plan "$kill_retired_fence_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_retired_fence_ws"
wait_for_phase "$kill_retired_fence_phase_dir" \
    after_private_children_deleted_before_root_rmdir \
    "SIGKILL during retired-fence cleanup"
kill_retired_fence_runtime=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "retired-fence operation did not expose its runtime root"
kill_retired_fence_transaction=$(find -P "$kill_retired_fence_ws" \
    -mindepth 1 -maxdepth 1 -type d \
    -name '.beads-v0.62.0-migration.runtime.*' -print -quit)
[ -n "$kill_retired_fence_transaction" ] &&
    [ ! -e "$kill_retired_fence_transaction/lock" ] &&
    [ ! -L "$kill_retired_fence_transaction/lock" ] &&
    [ ! -e "$kill_retired_fence_transaction/staging" ] &&
    [ ! -L "$kill_retired_fence_transaction/staging" ] ||
    fail "retired-fence cleanup did not reach the empty-root crash window"
[ -f "$kill_retired_fence_ws/.beads/v062-migration-receipt.json" ] &&
    [ -d "$kill_retired_fence_ws/.beads-v0.62.0-rollback" ] &&
    [ ! -e "$kill_retired_fence_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_retired_fence_ws/.beads-v0.62.0-staging" ] ||
    fail "retired operation fence remained canonical or lost committed state"
hard_kill_phase_bridge "SIGKILL during retired-fence cleanup"
wait_for_path_absence "$kill_retired_fence_runtime" \
    "SIGKILL retired-fence runtime root"
assert_no_workspace_runtime_artifacts "$kill_retired_fence_ws" \
    "SIGKILL during retired-fence cleanup"
kill_retired_fence_create=$(cd "$kill_retired_fence_ws" &&
    env -i PATH="$PATH" HOME="$tmp/home" LANG=C LC_ALL=C TZ=UTC TERM=dumb \
        "$TARGET_BD" create "Post-migration identity probe" --json) ||
    fail "ordinary write after retired-fence SIGKILL failed"
kill_retired_fence_create_id=$(jq -er '.id' \
    <<< "$kill_retired_fence_create") ||
    fail "ordinary write after retired-fence SIGKILL returned invalid JSON"
run_bridge effectful-kill-retired-fence-retry "$kill_retired_fence_ws" \
    --apply --yes --expect-plan "$kill_retired_fence_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_retired_fence_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after retired-fence SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded none
jq -e '.no_op == true' <<< "$RUN_STDOUT" >/dev/null ||
    fail "retry after retired-fence SIGKILL did not verify a no-op"
jq -e --arg id "$kill_retired_fence_create_id" \
    'select(.id == $id)' \
    "$kill_retired_fence_ws/.beads/fake-target-state.jsonl" >/dev/null ||
    fail "retired-fence retry lost the post-publication issue"

# Replacing the runtime pathname cannot trick the detached guardian into
# deleting attacker-owned bytes or ambiguous renamed evidence. A pathname
# identity mismatch preserves both roots for explicit recovery.
runtime_replacement_ws="$tmp/effectful-runtime-replacement-race"
new_v062_workspace "$runtime_replacement_ws"
inspect_effectful_plan effectful-runtime-replacement-plan \
    "$runtime_replacement_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
runtime_replacement_plan="$EFFECTFUL_PLAN"
runtime_replacement_phase_dir="$tmp/effectful-runtime-replacement-phase"
mkdir -m 700 "$runtime_replacement_phase_dir"
touch \
    "$runtime_replacement_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue"
BRIDGE_TEST_PHASE_DIR="$runtime_replacement_phase_dir" \
    start_bridge_at_phase effectful-runtime-replacement \
        "$runtime_replacement_ws" \
        --apply --yes --expect-plan "$runtime_replacement_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$runtime_replacement_ws"
wait_for_phase "$runtime_replacement_phase_dir" \
    after_operation_fence_before_reinspect \
    "runtime-root replacement race"
runtime_replacement_root=$(last_private_runtime_from_log "$SOURCE_LOG") ||
    fail "runtime replacement race did not expose its runtime root"
runtime_authenticated_root="${runtime_replacement_root}.authenticated"
runtime_authenticated_source_sha=$(sha256sum \
    "$runtime_replacement_root/source-bd" | awk '{print $1}')
mv -fT -- "$runtime_replacement_root" "$runtime_authenticated_root"
mkdir -m 700 -- "$runtime_replacement_root"
printf '%s\n' 'replacement must survive guardian cleanup' \
    > "$runtime_replacement_root/sentinel"
hard_kill_phase_bridge "runtime-root replacement race"
# Give the detached guardian a bounded window to observe the dead owner. A
# pathname-identity mismatch is fail-closed: neither inode is safe to delete.
for ((runtime_guardian_attempt = 0; \
    runtime_guardian_attempt < 40; runtime_guardian_attempt++)); do
    sleep 0.025
done
[ -f "$runtime_replacement_root/sentinel" ] &&
    grep -Fqx 'replacement must survive guardian cleanup' \
        "$runtime_replacement_root/sentinel" ||
    fail "guardian deleted or changed the replacement runtime path"
[ -f "$runtime_authenticated_root/source-bd" ] &&
    [ "$(sha256sum "$runtime_authenticated_root/source-bd" | awk '{print $1}')" = \
        "$runtime_authenticated_source_sha" ] ||
    fail "guardian deleted or changed renamed authenticated runtime evidence"
rm -rf -- "$runtime_replacement_root" "$runtime_authenticated_root"
run_bridge effectful-runtime-replacement-retry "$runtime_replacement_ws" \
    --apply --yes --expect-plan "$runtime_replacement_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$runtime_replacement_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after runtime replacement SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated

# A process death cannot run EXIT traps. The authenticated fence distinguishes a
# live operation from these three authenticated stale transaction layouts.
kill_fence_ws="$tmp/effectful-kill-after-fence"
new_v062_workspace "$kill_fence_ws"
inspect_effectful_plan effectful-kill-after-fence-plan "$kill_fence_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_fence_plan="$EFFECTFUL_PLAN"
kill_fence_source=$(content_fingerprint "$kill_fence_ws/.beads")
kill_fence_phase_dir="$tmp/effectful-kill-after-fence-phase"
mkdir -m 700 "$kill_fence_phase_dir"
release_transaction_gap_phases "$kill_fence_phase_dir"
BRIDGE_TEST_PHASE_DIR="$kill_fence_phase_dir" \
    start_bridge_at_phase effectful-kill-after-fence "$kill_fence_ws" \
        --apply --yes --expect-plan "$kill_fence_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_fence_ws"
wait_for_phase "$kill_fence_phase_dir" \
    after_operation_fence_before_reinspect "SIGKILL after operation fence"
hard_kill_phase_bridge "SIGKILL after operation fence"
assert_last_private_runtime_removed "$SOURCE_LOG" \
    "SIGKILL after operation fence"
[ -f "$kill_fence_ws/.beads-v0.62.0-migration.lock/journal.json" ] ||
    fail "SIGKILL after fence did not retain its recovery journal"
replace_journal_owner_with_zombie \
    "$kill_fence_ws/.beads-v0.62.0-migration.lock/journal.json"
[ "$(content_fingerprint "$kill_fence_ws/.beads")" = "$kill_fence_source" ] &&
    [ -d "$kill_fence_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_fence_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$kill_fence_ws/.beads-v0.62.0-rollback" ] ||
    fail "SIGKILL after fence produced an unrecognized transaction layout"
run_bridge effectful-kill-after-fence-retry "$kill_fence_ws" \
    --apply --yes --expect-plan "$kill_fence_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_fence_ws"
stop_journal_owner_zombie
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after fence SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated
[ ! -e "$kill_fence_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_fence_ws/.beads-v0.62.0-staging" ] ||
    fail "retry after fence SIGKILL left transaction artifacts"

kill_source_ws="$tmp/effectful-kill-after-source-rename"
new_v062_workspace "$kill_source_ws"
inspect_effectful_plan effectful-kill-after-source-plan "$kill_source_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_source_plan="$EFFECTFUL_PLAN"
kill_source_digest=$(content_fingerprint "$kill_source_ws/.beads")
kill_source_phase_dir="$tmp/effectful-kill-after-source-phase"
mkdir -m 700 "$kill_source_phase_dir"
release_transaction_gap_phases "$kill_source_phase_dir"
touch "$kill_source_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$kill_source_phase_dir/before_receipt_publish.continue"
touch "$kill_source_phase_dir/before_source_rename.continue"
BRIDGE_TEST_PHASE_DIR="$kill_source_phase_dir" \
    start_bridge_at_phase effectful-kill-after-source "$kill_source_ws" \
        --apply --yes --expect-plan "$kill_source_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_source_ws"
wait_for_phase "$kill_source_phase_dir" \
    after_source_rename_before_target_publish "SIGKILL after source rename"
hard_kill_phase_bridge "SIGKILL after source rename"
assert_last_private_runtime_removed "$SOURCE_LOG" \
    "SIGKILL after source rename"
[ ! -e "$kill_source_ws/.beads" ] &&
    [ "$(content_fingerprint "$kill_source_ws/.beads-v0.62.0-rollback")" = \
        "$kill_source_digest" ] &&
    [ -d "$kill_source_ws/.beads-v0.62.0-staging" ] &&
    [ -d "$kill_source_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "SIGKILL after source rename produced an unrecognized transaction layout"
run_bridge effectful-kill-after-source-retry "$kill_source_ws" \
    --apply --yes --expect-plan "$kill_source_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_source_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after source-rename SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated
[ "$(content_fingerprint "$kill_source_ws/.beads-v0.62.0-rollback")" = \
    "$kill_source_digest" ] &&
    [ ! -e "$kill_source_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_source_ws/.beads-v0.62.0-staging" ] ||
    fail "retry after source-rename SIGKILL lost rollback or left artifacts"

# Recovery may restore the retained source only after the staged receipt binds
# it to the caller's exact consent plan. Preserve every artifact when that
# receipt is malformed or has been replaced after process death.
kill_tamper_ws="$tmp/effectful-kill-tampered-staged-receipt"
new_v062_workspace "$kill_tamper_ws"
inspect_effectful_plan effectful-kill-tamper-plan "$kill_tamper_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_tamper_plan="$EFFECTFUL_PLAN"
kill_tamper_source=$(content_fingerprint "$kill_tamper_ws/.beads")
kill_tamper_phase_dir="$tmp/effectful-kill-tamper-phase"
mkdir -m 700 "$kill_tamper_phase_dir"
release_transaction_gap_phases "$kill_tamper_phase_dir"
touch "$kill_tamper_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$kill_tamper_phase_dir/before_receipt_publish.continue"
touch "$kill_tamper_phase_dir/before_source_rename.continue"
BRIDGE_TEST_PHASE_DIR="$kill_tamper_phase_dir" \
    start_bridge_at_phase effectful-kill-tamper "$kill_tamper_ws" \
        --apply --yes --expect-plan "$kill_tamper_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_tamper_ws"
wait_for_phase "$kill_tamper_phase_dir" \
    after_source_rename_before_target_publish \
    "SIGKILL before staged-receipt tamper"
hard_kill_phase_bridge "SIGKILL before staged-receipt tamper"
assert_last_private_runtime_removed "$SOURCE_LOG" \
    "SIGKILL before staged-receipt tamper"
kill_tamper_receipt="$kill_tamper_ws/.beads-v0.62.0-staging/target/.beads/v062-migration-receipt.json"
jq '.plan_digest = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$kill_tamper_receipt" > "${kill_tamper_receipt}.tampered"
chmod 600 "${kill_tamper_receipt}.tampered"
mv -f -- "${kill_tamper_receipt}.tampered" "$kill_tamper_receipt"
kill_tamper_rollback_before=$(content_fingerprint \
    "$kill_tamper_ws/.beads-v0.62.0-rollback")
kill_tamper_staging_before=$(content_fingerprint \
    "$kill_tamper_ws/.beads-v0.62.0-staging")
kill_tamper_lock_before=$(content_fingerprint \
    "$kill_tamper_ws/.beads-v0.62.0-migration.lock")
run_bridge effectful-kill-tamper-retry "$kill_tamper_ws" \
    --apply --yes --expect-plan "$kill_tamper_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_tamper_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "tampered stale receipt retry exit=$RUN_STATUS, want failure"
assert_common_json apply failed workspace_requires_recovery
jq -e '.retryable == false and .code == "recovery_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "tampered stale receipt was not refused: $RUN_STDOUT"
[ ! -e "$kill_tamper_ws/.beads" ] &&
    [ "$(content_fingerprint "$kill_tamper_ws/.beads-v0.62.0-rollback")" = \
        "$kill_tamper_rollback_before" ] &&
    [ "$kill_tamper_rollback_before" = "$kill_tamper_source" ] &&
    [ "$(content_fingerprint "$kill_tamper_ws/.beads-v0.62.0-staging")" = \
        "$kill_tamper_staging_before" ] &&
    [ "$(content_fingerprint "$kill_tamper_ws/.beads-v0.62.0-migration.lock")" = \
        "$kill_tamper_lock_before" ] ||
    fail "tampered stale recovery changed or discarded transaction evidence"

kill_publish_ws="$tmp/effectful-kill-after-target-publish"
new_v062_workspace "$kill_publish_ws"
inspect_effectful_plan effectful-kill-after-publish-plan "$kill_publish_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
kill_publish_plan="$EFFECTFUL_PLAN"
kill_publish_phase_dir="$tmp/effectful-kill-after-publish-phase"
mkdir -m 700 "$kill_publish_phase_dir"
release_transaction_gap_phases "$kill_publish_phase_dir"
touch "$kill_publish_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$kill_publish_phase_dir/before_receipt_publish.continue"
touch "$kill_publish_phase_dir/before_source_rename.continue"
touch "$kill_publish_phase_dir/after_source_rename_before_target_publish.continue"
BRIDGE_TEST_PHASE_DIR="$kill_publish_phase_dir" \
    start_bridge_at_phase effectful-kill-after-publish "$kill_publish_ws" \
        --apply --yes --expect-plan "$kill_publish_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$kill_publish_ws"
wait_for_phase "$kill_publish_phase_dir" after_target_publish \
    "SIGKILL after target publication"
hard_kill_phase_bridge "SIGKILL after target publication"
assert_last_private_runtime_removed "$SOURCE_LOG" \
    "SIGKILL after target publication"
[ -f "$kill_publish_ws/.beads/v062-migration-receipt.json" ] &&
    [ -d "$kill_publish_ws/.beads-v0.62.0-rollback" ] &&
    [ -d "$kill_publish_ws/.beads-v0.62.0-staging" ] &&
    [ -d "$kill_publish_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "SIGKILL after target publication produced an unrecognized layout"
kill_publish_create=$(cd "$kill_publish_ws" &&
    env -i PATH="$PATH" HOME="$tmp/home" LANG=C LC_ALL=C TZ=UTC TERM=dumb \
        "$TARGET_BD" create "Post-migration identity probe" --json) ||
    fail "ordinary write after killed publication failed"
kill_publish_create_id=$(jq -er '.id' <<< "$kill_publish_create") ||
    fail "ordinary write after killed publication returned invalid JSON"
run_bridge effectful-kill-after-publish-retry "$kill_publish_ws" \
    --apply --yes --expect-plan "$kill_publish_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$kill_publish_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "retry after target-publication SIGKILL failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded none
jq -e '.no_op == true' <<< "$RUN_STDOUT" >/dev/null ||
    fail "retry after killed publication did not verify a no-op"
jq -e --arg id "$kill_publish_create_id" 'select(.id == $id)' \
    "$kill_publish_ws/.beads/fake-target-state.jsonl" >/dev/null ||
    fail "retry after killed publication lost the additive issue"
[ ! -e "$kill_publish_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$kill_publish_ws/.beads-v0.62.0-staging" ] ||
    fail "retry after target-publication SIGKILL left transaction artifacts"

# GNU mv --no-clobber can report success when it skipped a rename. Exercise
# each transaction publication point with a byte-identical destination so
# content checks cannot be mistaken for proof that the owned source moved.
receipt_race_ws="$tmp/effectful-receipt-publish-race"
new_v062_workspace "$receipt_race_ws"
inspect_effectful_plan effectful-receipt-race-plan "$receipt_race_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
receipt_race_plan="$EFFECTFUL_PLAN"
receipt_race_source=$(content_fingerprint "$receipt_race_ws/.beads")
receipt_race_phase_dir="$tmp/effectful-receipt-race-phase"
mkdir -m 700 "$receipt_race_phase_dir"
release_transaction_gap_phases "$receipt_race_phase_dir"
touch "$receipt_race_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$receipt_race_phase_dir/before_source_rename.continue"
touch "$receipt_race_phase_dir/after_source_rename_before_target_publish.continue"
touch "$receipt_race_phase_dir/after_target_publish.continue"
BRIDGE_TEST_MV_MODE=false_success_on_collision \
BRIDGE_TEST_PHASE_DIR="$receipt_race_phase_dir" \
    start_bridge_at_phase effectful-receipt-race "$receipt_race_ws" \
        --apply --yes --expect-plan "$receipt_race_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$receipt_race_ws"
wait_for_phase "$receipt_race_phase_dir" before_receipt_publish \
    "effectful receipt publication race"
receipt_race_staged="$receipt_race_ws/.beads-v0.62.0-staging/target/.beads"
/usr/bin/cp -a -- \
    "$receipt_race_staged/.v062-migration-receipt.tmp" \
    "$receipt_race_staged/v062-migration-receipt.json"
touch "$receipt_race_phase_dir/before_receipt_publish.continue"
finish_phase_bridge "effectful receipt publication race"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "receipt publication race exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '.retryable == false and .code == "receipt_write_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "receipt publication race was accepted: $RUN_STDOUT"
[ "$(content_fingerprint "$receipt_race_ws/.beads")" = \
    "$receipt_race_source" ] &&
    [ ! -e "$receipt_race_ws/.beads-v0.62.0-rollback" ] &&
    [ ! -e "$receipt_race_ws/.beads-v0.62.0-staging" ] &&
    [ ! -e "$receipt_race_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "receipt publication race changed the source or leaked transaction state"

source_rename_race_ws="$tmp/effectful-source-rename-race"
new_v062_workspace "$source_rename_race_ws"
inspect_effectful_plan effectful-source-rename-race-plan \
    "$source_rename_race_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
source_rename_race_plan="$EFFECTFUL_PLAN"
source_rename_race_digest=$(content_fingerprint \
    "$source_rename_race_ws/.beads")
source_rename_race_phase_dir="$tmp/effectful-source-rename-race-phase"
mkdir -m 700 "$source_rename_race_phase_dir"
release_transaction_gap_phases "$source_rename_race_phase_dir"
touch "$source_rename_race_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$source_rename_race_phase_dir/before_receipt_publish.continue"
touch "$source_rename_race_phase_dir/after_source_rename_before_target_publish.continue"
BRIDGE_TEST_MV_MODE=false_success_on_collision \
BRIDGE_TEST_PHASE_DIR="$source_rename_race_phase_dir" \
    start_bridge_at_phase effectful-source-rename-race \
        "$source_rename_race_ws" \
        --apply --yes --expect-plan "$source_rename_race_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$source_rename_race_ws"
wait_for_phase "$source_rename_race_phase_dir" before_source_rename \
    "effectful source rename race"
/usr/bin/cp -a -- "$source_rename_race_ws/.beads" \
    "$source_rename_race_ws/.beads-v0.62.0-rollback"
touch "$source_rename_race_phase_dir/before_source_rename.continue"
finish_phase_bridge "effectful source rename race"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "source rename race exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '.retryable == true and .code == "source_rename_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "source rename race advanced transaction state: $RUN_STDOUT"
[ "$(content_fingerprint "$source_rename_race_ws/.beads")" = \
    "$source_rename_race_digest" ] &&
    [ "$(content_fingerprint \
        "$source_rename_race_ws/.beads-v0.62.0-rollback")" = \
        "$source_rename_race_digest" ] ||
    fail "source rename race changed the active or colliding source bytes"

target_publish_race_ws="$tmp/effectful-target-publish-race"
new_v062_workspace "$target_publish_race_ws"
inspect_effectful_plan effectful-target-publish-race-plan \
    "$target_publish_race_ws" "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
target_publish_race_plan="$EFFECTFUL_PLAN"
target_publish_race_source=$(content_fingerprint \
    "$target_publish_race_ws/.beads")
target_publish_race_phase_dir="$tmp/effectful-target-publish-race-phase"
mkdir -m 700 "$target_publish_race_phase_dir"
release_transaction_gap_phases "$target_publish_race_phase_dir"
touch "$target_publish_race_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$target_publish_race_phase_dir/before_receipt_publish.continue"
touch "$target_publish_race_phase_dir/before_source_rename.continue"
touch "$target_publish_race_phase_dir/after_target_publish.continue"
BRIDGE_TEST_MV_MODE=false_success_on_collision \
BRIDGE_TEST_PHASE_DIR="$target_publish_race_phase_dir" \
    start_bridge_at_phase effectful-target-publish-race \
        "$target_publish_race_ws" \
        --apply --yes --expect-plan "$target_publish_race_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$target_publish_race_ws"
wait_for_phase "$target_publish_race_phase_dir" \
    after_source_rename_before_target_publish \
    "effectful target publication race"
/usr/bin/cp -a -- \
    "$target_publish_race_ws/.beads-v0.62.0-staging/target/.beads" \
    "$target_publish_race_ws/.beads"
touch "$target_publish_race_phase_dir/after_source_rename_before_target_publish.continue"
finish_phase_bridge "effectful target publication race"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "target publication race exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed workspace_requires_recovery
jq -e '.retryable == false and .code == "recovery_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "target publication race claimed a committed migration: $RUN_STDOUT"
[ "$(content_fingerprint \
    "$target_publish_race_ws/.beads-v0.62.0-rollback")" = \
    "$target_publish_race_source" ] ||
    fail "target publication race lost the authoritative rollback"

recovery_race_ws="$tmp/effectful-recovery-race"
new_v062_workspace "$recovery_race_ws"
inspect_effectful_plan effectful-recovery-race-plan "$recovery_race_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
recovery_race_plan="$EFFECTFUL_PLAN"
recovery_race_source=$(content_fingerprint "$recovery_race_ws/.beads")
recovery_race_phase_dir="$tmp/effectful-recovery-race-phase"
mkdir -m 700 "$recovery_race_phase_dir"
release_transaction_gap_phases "$recovery_race_phase_dir"
touch "$recovery_race_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$recovery_race_phase_dir/before_receipt_publish.continue"
touch "$recovery_race_phase_dir/before_source_rename.continue"
BRIDGE_TEST_FAILPOINT=after_source_rename_before_target_publish \
BRIDGE_TEST_MV_MODE=false_success_on_collision \
BRIDGE_TEST_PHASE_DIR="$recovery_race_phase_dir" \
    start_bridge_at_phase effectful-recovery-race "$recovery_race_ws" \
        --apply --yes --expect-plan "$recovery_race_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$recovery_race_ws"
wait_for_phase "$recovery_race_phase_dir" \
    after_source_rename_before_target_publish \
    "effectful recovery race"
/usr/bin/cp -a -- \
    "$recovery_race_ws/.beads-v0.62.0-staging/target/.beads" \
    "$recovery_race_ws/.beads"
touch "$recovery_race_phase_dir/after_source_rename_before_target_publish.continue"
finish_phase_bridge "effectful recovery race"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "recovery race exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed workspace_requires_recovery
jq -e '.retryable == false and .code == "recovery_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "recovery race claimed that rollback restoration succeeded: $RUN_STDOUT"
[ "$(content_fingerprint \
    "$recovery_race_ws/.beads-v0.62.0-rollback")" = \
    "$recovery_race_source" ] ||
    fail "recovery race lost the authoritative rollback"

assert_failpoint_preserves_source() {
    local label="$1" ws="$2" plan="$3" failpoint="$4"
    local source_before workspace_before phase_dir
    source_before=$(content_fingerprint "$ws/.beads")
    workspace_before=$(content_fingerprint "$ws")
    phase_dir="$tmp/$label-phase"
    mkdir -m 700 "$phase_dir"
    release_transaction_gap_phases "$phase_dir"
    # This helper observes a later cutover phase. Release the earlier
    # operation-fence hook up front so the bridge can reach that phase.
    touch "$phase_dir/after_operation_fence_before_reinspect.continue"
    touch "$phase_dir/before_receipt_publish.continue"
    case "$failpoint" in
        after_source_rename_before_target_publish)
            touch "$phase_dir/before_source_rename.continue"
            ;;
    esac
    BRIDGE_TEST_FAILPOINT="$failpoint" \
    BRIDGE_TEST_PHASE_DIR="$phase_dir" \
        start_bridge_at_phase "$label" "$ws" \
            --apply --yes --expect-plan "$plan" \
            --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
            --workspace "$ws"
    wait_for_phase "$phase_dir" "$failpoint" "$label"
    [ -d "$ws/.beads-v0.62.0-migration.lock" ] &&
        [ ! -L "$ws/.beads-v0.62.0-migration.lock" ] &&
        [ -d "$ws/.beads-v0.62.0-staging" ] &&
        [ ! -L "$ws/.beads-v0.62.0-staging" ] ||
        fail "$label did not reach cutover with a fenced verified candidate"
    case "$failpoint" in
        before_source_rename)
            [ -d "$ws/.beads" ] && [ ! -L "$ws/.beads" ] &&
                [ ! -e "$ws/.beads-v0.62.0-rollback" ] &&
                [ -f "$ws/.beads-v0.62.0-staging/target/.beads/v062-migration-receipt.json" ] ||
                fail "$label exposed an invalid pre-rename layout"
            [ ! -e "$POISON_BASH_MARKER" ] &&
                [ ! -e "$POISON_BASH_ENV_MARKER" ] &&
                [ ! -e "$POISON_PATH_MARKER" ] &&
                [ ! -e "$POISON_GIT_DIR" ] &&
                [ ! -e "$POISON_GIT_WORK_TREE" ] &&
                [ -d "$ws/.beads-v0.62.0-staging/target/.git" ] &&
                [ ! -e "$ws/.beads-v0.62.0-staging/target/.git/poison-template-marker" ] &&
                ! grep -F "$POISON_GIT_WORK_TREE" \
                    "$ws/.beads-v0.62.0-staging/target/.git/config" \
                    >/dev/null ||
                fail "$label allowed hostile shell or Git environment state"
            ;;
        after_source_rename_before_target_publish)
            [ ! -e "$ws/.beads" ] && [ ! -L "$ws/.beads" ] &&
                [ -d "$ws/.beads-v0.62.0-rollback" ] &&
                [ ! -L "$ws/.beads-v0.62.0-rollback" ] &&
                [ -f "$ws/.beads-v0.62.0-staging/target/.beads/v062-migration-receipt.json" ] &&
                [ "$(content_fingerprint "$ws/.beads-v0.62.0-rollback")" = \
                    "$source_before" ] ||
                fail "$label exposed an invalid post-rename layout"
            ;;
        *) fail "$label requested an unknown observed failpoint: $failpoint" ;;
    esac
    touch "$phase_dir/$failpoint.continue"
    finish_phase_bridge "$label"
    [ "$RUN_STATUS" -eq 1 ] ||
        fail "$label exit=$RUN_STATUS, want injected failure exit 1: $RUN_STDOUT $RUN_STDERR"
    assert_common_json apply failed none
    jq -e --arg failpoint "$failpoint" '
        .retryable == true and .code == "injected_failure" and
        .verification.failpoint == $failpoint and
        .verification.phase_reached == true
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label lacked stable injected-failure evidence: $RUN_STDOUT"
    [ -d "$ws/.beads" ] && [ ! -L "$ws/.beads" ] ||
        fail "$label did not restore the active source directory"
    [ "$(content_fingerprint "$ws/.beads")" = "$source_before" ] ||
        fail "$label changed original source bytes"
    [ "$(content_fingerprint "$ws")" = "$workspace_before" ] ||
        fail "$label left a workspace artifact after recovery"
    [ ! -e "$ws/.beads-v0.62.0-rollback" ] &&
        [ ! -L "$ws/.beads-v0.62.0-rollback" ] ||
        fail "$label left a rollback publication after failed cutover"
    [ ! -e "$ws/.beads-v0.62.0-staging" ] &&
        [ ! -L "$ws/.beads-v0.62.0-staging" ] ||
        fail "$label left a staging publication after recovery"
}

before_rename_ws="$tmp/fail-before-source-rename"
new_v062_workspace "$before_rename_ws"
inspect_effectful_plan fail-before-source-rename-plan "$before_rename_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
before_rename_plan="$EFFECTFUL_PLAN"
assert_failpoint_preserves_source fail-before-source-rename \
    "$before_rename_ws" "$before_rename_plan" before_source_rename

# Exercise the harder cutover window on the canonical success workspace, then
# retry the exact authorized plan. A restored source must remain resumable.
assert_failpoint_preserves_source fail-after-source-rename \
    "$effect_ws" "$canonical_plan" \
    after_source_rename_before_target_publish

# Atomic publication is the irreversible commit point. Once normal commands
# can see the target, even an injected bridge failure must retain their writes.
post_publish_ws="$tmp/write-after-target-publish"
new_v062_workspace "$post_publish_ws"
inspect_effectful_plan write-after-publish-plan "$post_publish_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
post_publish_plan="$EFFECTFUL_PLAN"
post_publish_phase_dir="$tmp/write-after-publish-phase"
mkdir -m 700 "$post_publish_phase_dir"
release_transaction_gap_phases "$post_publish_phase_dir"
touch "$post_publish_phase_dir/after_operation_fence_before_reinspect.continue"
touch "$post_publish_phase_dir/before_receipt_publish.continue"
touch "$post_publish_phase_dir/before_source_rename.continue"
touch "$post_publish_phase_dir/after_source_rename_before_target_publish.continue"
BRIDGE_TEST_FAILPOINT=after_target_publish \
BRIDGE_TEST_PHASE_DIR="$post_publish_phase_dir" \
    start_bridge_at_phase write-after-publish "$post_publish_ws" \
        --apply --yes --expect-plan "$post_publish_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$post_publish_ws"
wait_for_phase "$post_publish_phase_dir" after_target_publish \
    "write-after-publish apply"
[ -d "$post_publish_ws/.beads-v0.62.0-migration.lock" ] &&
    [ -f "$post_publish_ws/.beads/v062-migration-receipt.json" ] &&
    [ -d "$post_publish_ws/.beads-v0.62.0-rollback" ] ||
    fail "write-after-publish apply did not expose its committed target"
post_publish_create="$tmp/write-after-publish-create.json"
(
    cd "$post_publish_ws"
    env -i PATH="$PATH" HOME="$tmp/home" LANG=C LC_ALL=C TZ=UTC TERM=dumb \
        "$TARGET_BD" create "Post-migration identity probe" --json \
        > "$post_publish_create"
) || fail "ordinary target write failed after atomic publication"
post_publish_id=$(jq -er '.id' "$post_publish_create") ||
    fail "ordinary target write returned invalid JSON"
touch "$post_publish_phase_dir/after_target_publish.continue"
finish_phase_bridge "write-after-publish apply"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "post-publish failpoint exit=$RUN_STATUS, want injected failure"
assert_common_json apply failed workspace_migrated
jq -e '
    .retryable == true and .code == "injected_failure" and
    .verification.failpoint == "after_target_publish"
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "post-publish failure did not report committed effects: $RUN_STDOUT"
jq -e --arg id "$post_publish_id" 'select(.id == $id)' \
    "$post_publish_ws/.beads/fake-target-state.jsonl" >/dev/null ||
    fail "post-publish recovery discarded an ordinary target write"
[ ! -e "$post_publish_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$post_publish_ws/.beads-v0.62.0-staging" ] &&
    [ -d "$post_publish_ws/.beads-v0.62.0-rollback" ] ||
    fail "post-publish failure leaked committed transaction artifacts"

# A receipt-backed retry verifies the migrated five-record baseline without
# rejecting ordinary issues written after publication or repeating migration.
post_publish_retry_before=$(tree_fingerprint "$post_publish_ws")
post_publish_receipt="$post_publish_ws/.beads/v062-migration-receipt.json"
post_publish_receipt_before=$(sha256sum "$post_publish_receipt" | awk '{print $1}')
post_publish_source_exports=$(call_count "$SOURCE_LOG" export)
post_publish_source_shows=$(call_count "$SOURCE_LOG" show)
post_publish_target_inits=$(call_count "$TARGET_LOG" init)
post_publish_target_imports=$(call_count "$TARGET_LOG" import)
run_bridge write-after-publish-no-op "$post_publish_ws" \
    --apply --yes --expect-plan "$post_publish_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$post_publish_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "post-publish retry exit=$RUN_STATUS, want no-op exit 0: $RUN_STDOUT $RUN_STDERR"
[ -z "$RUN_STDERR" ] ||
    fail "post-publish retry emitted stderr in JSON mode: $RUN_STDERR"
assert_common_json apply succeeded none
jq -e --arg plan "$post_publish_plan" '
    .retryable == false and .no_op == true and (.code | not) and
    .plan.digest == $plan and .verification.issue_count == 5 and
    .verification.semantic_scope_verified == true and
    .verification.separate_process_reopen == true
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "post-publish retry did not report a verified no-op: $RUN_STDOUT"
assert_unchanged "$post_publish_ws" "$post_publish_retry_before" \
    "post-publish retry"
[ "$(sha256sum "$post_publish_receipt" | awk '{print $1}')" = \
    "$post_publish_receipt_before" ] ||
    fail "post-publish retry rewrote its completion receipt"
jq -e --arg id "$post_publish_id" 'select(.id == $id)' \
    "$post_publish_ws/.beads/fake-target-state.jsonl" >/dev/null ||
    fail "post-publish retry discarded the ordinary target write"
[ "$(call_count "$SOURCE_LOG" export)" -eq "$post_publish_source_exports" ] &&
    [ "$(call_count "$SOURCE_LOG" show)" -eq "$post_publish_source_shows" ] &&
    [ "$(call_count "$TARGET_LOG" init)" -eq "$post_publish_target_inits" ] &&
    [ "$(call_count "$TARGET_LOG" import)" -eq "$post_publish_target_imports" ] ||
    fail "post-publish retry repeated a mutating migration phase"

# Failure to authenticate a newly spawned transaction guardian is bounded.
# The source remains unchanged while the detached guardian removes the private
# pre-publication bundle after its owner exits.
guardian_start_ws="$tmp/effectful-transaction-guardian-start"
new_v062_workspace "$guardian_start_ws"
inspect_effectful_plan transaction-guardian-start-plan "$guardian_start_ws" \
    "$SOURCE_BD" "$SOURCE_DOLT" "$TARGET_BD"
guardian_start_plan="$EFFECTFUL_PLAN"
guardian_start_source=$(content_fingerprint "$guardian_start_ws/.beads")
BRIDGE_TEST_GUARDIAN_START_FAILURE=transaction_guardian_start \
    run_bridge transaction-guardian-start-unverifiable "$guardian_start_ws" \
        --apply --yes --expect-plan "$guardian_start_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$guardian_start_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "transaction guardian start failure exit=$RUN_STATUS, want 1: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed workspace_requires_recovery
jq -e '.retryable == false and .code == "recovery_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "transaction guardian start failure was misclassified: $RUN_STDOUT"
[ "$(content_fingerprint "$guardian_start_ws/.beads")" = \
    "$guardian_start_source" ] &&
    [ ! -e "$guardian_start_ws/.beads-v0.62.0-migration.lock" ] &&
    [ ! -e "$guardian_start_ws/.beads-v0.62.0-staging" ] ||
    fail "transaction guardian start failure changed canonical source state"
assert_no_workspace_runtime_artifacts "$guardian_start_ws" \
    "transaction guardian start failure"
run_bridge transaction-guardian-start-retry "$guardian_start_ws" \
    --apply --yes --expect-plan "$guardian_start_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$guardian_start_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "transaction guardian start retry failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded workspace_migrated
assert_no_workspace_runtime_artifacts "$guardian_start_ws" \
    "transaction guardian start retry"

source_content_before=$(content_fingerprint "$effect_ws/.beads")
[ "$source_content_before" = "$canonical_source_tree" ] ||
    fail "test source manifest disagrees with the inspect-bound observation"
source_export_before=$(call_count "$SOURCE_LOG" export)
source_show_before=$(call_count "$SOURCE_LOG" show)
target_init_before=$(call_count "$TARGET_LOG" init)
target_import_before=$(call_count "$TARGET_LOG" import)
target_export_before=$(call_count "$TARGET_LOG" export)
guardian_success_phase_dir="$tmp/effectful-guardian-success-phase"
mkdir -m 700 "$guardian_success_phase_dir"
touch \
    "$guardian_success_phase_dir/guardian-cooperative-shutdown.enabled" \
    "$guardian_success_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$guardian_success_phase_dir/after_operation_fence_before_reinspect.continue" \
    "$guardian_success_phase_dir/after_staging_publish_before_journal_update.continue" \
    "$guardian_success_phase_dir/before_receipt_publish.continue" \
    "$guardian_success_phase_dir/before_source_rename.continue" \
    "$guardian_success_phase_dir/after_source_rename_before_target_publish.continue" \
    "$guardian_success_phase_dir/after_target_publish.continue" \
    "$guardian_success_phase_dir/after_operation_fence_retired_before_private_cleanup.continue"
GUARDIAN_TEST_PHASE_DIR="$guardian_success_phase_dir"
BRIDGE_TEST_PHASE_DIR="$guardian_success_phase_dir" \
    start_bridge_at_phase effectful-apply "$effect_ws" \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"
wait_for_phase "$guardian_success_phase_dir" \
    transaction_guardian_resource_removed \
    "transaction guardian cooperative shutdown"
wait_for_guardian_marker "$guardian_success_phase_dir" \
    transaction-guardian.stop-waiting \
    "transaction guardian cooperative shutdown"
pid_is_running "$ASYNC_BRIDGE_PID" &&
    [ -f "$guardian_success_phase_dir/transaction-guardian.started" ] &&
    [ ! -e "$guardian_success_phase_dir/transaction-guardian.done" ] &&
    [ ! -e "$guardian_success_phase_dir/transaction-guardian.term" ] ||
    fail "transaction guardian was not live during cooperative shutdown"
touch "$guardian_success_phase_dir/transaction_guardian_resource_removed.continue"
wait_for_guardian_marker "$guardian_success_phase_dir" \
    runtime_guardian_resource_removed.reached \
    "runtime guardian cooperative shutdown"
wait_for_guardian_marker "$guardian_success_phase_dir" \
    runtime-guardian.stop-waiting \
    "runtime guardian cooperative shutdown"
pid_is_running "$ASYNC_BRIDGE_PID" &&
    [ -f "$guardian_success_phase_dir/runtime-guardian.started" ] &&
    [ ! -e "$guardian_success_phase_dir/runtime-guardian.done" ] &&
    [ ! -e "$guardian_success_phase_dir/runtime-guardian.term" ] ||
    fail "runtime guardian was not live during cooperative shutdown"
touch "$guardian_success_phase_dir/runtime_guardian_resource_removed.continue"
finish_phase_bridge "effectful apply guardian shutdown"
GUARDIAN_TEST_PHASE_DIR=""
[ "$RUN_STATUS" -eq 0 ] ||
    fail "effectful apply exit=$RUN_STATUS, want 0: $RUN_STDOUT $RUN_STDERR"
[ -z "$RUN_STDERR" ] ||
    fail "effectful apply emitted stderr in JSON mode: $RUN_STDERR"
for guardian in runtime transaction; do
    [ -f "$guardian_success_phase_dir/$guardian-guardian.started" ] &&
        [ -f "$guardian_success_phase_dir/$guardian-guardian.done" ] ||
        fail "$guardian guardian did not complete cooperative cleanup"
    [ ! -e "$guardian_success_phase_dir/$guardian-guardian.term" ] ||
        fail "$guardian guardian was stopped by a TERM signal"
done
assert_common_json apply succeeded workspace_migrated
jq -e \
    --arg plan "$canonical_plan" \
    --arg rollback "$effect_ws/.beads-v0.62.0-rollback" \
    --arg source_content "$source_content_before" \
    --arg issue_prefix "$SOURCE_ISSUE_PREFIX" \
    --arg database "$SOURCE_DATABASE" \
    --arg project_id "$SOURCE_PROJECT_ID" '
    .retryable == false and (.code | not) and
    .plan.digest == $plan and
    .plan.semantic_scope == "v062_lossless_core_v1" and
    .plan.source_identity == {
        issue_prefix: $issue_prefix,
        database: $database,
        project_id: $project_id
    } and
    .target.backend == "dolt-embedded" and
    .rollback.path == $rollback and
    .rollback.policy == "retain" and
    .rollback.verified == true and
    .rollback.tree_sha256 == $source_content and
    .verification.semantic_scope == "v062_lossless_core_v1" and
    .verification.semantic_scope_verified == true and
    .verification.issue_count == 5 and
    .verification.target_backend_verified == true and
    .verification.separate_process_reopen == true
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "effectful apply overstated or omitted verification: $RUN_STDOUT"

rollback_path="$effect_ws/.beads-v0.62.0-rollback"
receipt_path="$effect_ws/.beads/v062-migration-receipt.json"
[ -d "$rollback_path" ] && [ ! -L "$rollback_path" ] ||
    fail "effectful apply did not retain a physical rollback"
[ "$(content_fingerprint "$rollback_path")" = "$source_content_before" ] ||
    fail "retained rollback differs from the admitted source bytes"
[ -d "$rollback_path/dolt" ] && [ ! -e "$effect_ws/.beads/dolt" ] ||
    fail "effectful apply left the historical source selected"
[ -d "$effect_ws/.beads/embeddeddolt/$SOURCE_DATABASE/.dolt" ] &&
    [ ! -L "$effect_ws/.beads/embeddeddolt" ] ||
    fail "effectful apply did not publish embedded Dolt"
jq -e \
    --arg issue_prefix "$SOURCE_ISSUE_PREFIX" \
    --arg database "$SOURCE_DATABASE" \
    --arg project_id "$SOURCE_PROJECT_ID" '
    .database == "dolt" and .backend == "dolt" and
    .dolt_mode == "embedded" and .dolt_database == $database and
    .project_id == $project_id
' \
    "$effect_ws/.beads/metadata.json" >/dev/null ||
    fail "effectful apply did not preserve source identity in embedded metadata"
[ ! -e "$effect_ws/.beads-v0.62.0-staging" ] &&
    [ ! -L "$effect_ws/.beads-v0.62.0-staging" ] ||
    fail "effectful apply leaked its side-by-side staging tree"
[ -f "$receipt_path" ] && [ ! -L "$receipt_path" ] ||
    fail "effectful apply did not publish its completion receipt"
[ "$(stat -c '%a' "$receipt_path")" = 600 ] ||
    fail "completion receipt is not owner-only"
jq -e \
    --arg plan "$canonical_plan" \
    --arg rollback "$rollback_path" \
    --arg source_content "$source_content_before" \
    --arg issue_prefix "$SOURCE_ISSUE_PREFIX" \
    --arg database "$SOURCE_DATABASE" \
    --arg project_id "$SOURCE_PROJECT_ID" '
    .schema_version == 1 and
    .operation == "v062_server_to_current" and
    .state == "committed" and .plan_digest == $plan and
    .semantic_scope == "v062_lossless_core_v1" and
    .semantic_scope_verified == true and
    (.semantic_sha256 | type == "string" and
        test("^[0-9a-f]{64}$")) and
    .semantic_sha256 == .plan.semantic_baseline.sha256 and
    .target_backend == "dolt-embedded" and
    .plan.digest == $plan and
    .plan.source_identity == {
        issue_prefix: $issue_prefix,
        database: $database,
        project_id: $project_id
    } and
    .rollback.path == $rollback and .rollback.verified == true and
    .rollback.tree_sha256 == $source_content
' "$receipt_path" >/dev/null ||
    fail "completion receipt cannot authorize safe idempotent re-entry"

[ "$(call_count "$SOURCE_LOG" export)" -gt "$source_export_before" ] ||
    fail "effectful apply did not export through the pinned source bd"
[ "$(call_count "$SOURCE_LOG" show)" -gt "$source_show_before" ] ||
    fail "effectful apply did not enrich export through source show"
[ "$(call_count "$TARGET_LOG" init)" -gt "$target_init_before" ] ||
    fail "effectful apply did not initialize a side-by-side target"
[ "$(call_count "$TARGET_LOG" import)" -gt "$target_import_before" ] ||
    fail "effectful apply did not import into the side-by-side target"
[ "$(call_count "$TARGET_LOG" export)" -gt "$target_export_before" ] ||
    fail "effectful apply did not verify target audit fields through current export"
grep -E '^argv=.* export --no-memories -o (.*)$' \
    "$TARGET_LOG" >/dev/null ||
    fail "target audit verification omitted export --no-memories"
[ "$(call_count "$TARGET_LOG" show)" -eq 0 ] ||
    fail "target audit verification fell back to a lossy show projection"
grep -E '^argv=.* init --quiet --non-interactive --backend=dolt( |$)' \
    "$TARGET_LOG" >/dev/null ||
    fail "effectful apply did not explicitly force the staged Dolt backend"
if ! grep -E '^argv=.* init .*--prefix legacy( |$)' \
    "$TARGET_LOG" >/dev/null ||
    ! grep -E '^argv=.* init .*--database smoke( |$)' \
        "$TARGET_LOG" >/dev/null ||
    ! grep -E '^argv=.* init .*--migration-v062-project-id 7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6( |$)' \
        "$TARGET_LOG" >/dev/null; then
    fail "effectful apply did not initialize with the bound source identity"
fi
if grep -E '^argv=.* init .*--(server|shared-server|external)( |$)' \
    "$TARGET_LOG" >/dev/null; then
    fail "effectful apply selected a server-mode target during staged init"
fi
grep -E '^argv=.* (version|--version)( |$)' "$SOURCE_DOLT_LOG" >/dev/null ||
    fail "effectful apply did not validate the pinned Dolt runtime"
grep -E '^argv=.* sql-server( |$)' "$SOURCE_DOLT_LOG" >/dev/null ||
    fail "effectful apply did not launch the pinned historical Dolt runtime"
grep -E '^argv=.* --host( |$)' "$SOURCE_DOLT_LOG" >/dev/null ||
    fail "effectful apply did not probe historical Dolt readiness"
printf -v original_source_cwd_log_q '%q' "$effect_ws/.beads/dolt"
grep -F "cwd=$original_source_cwd_log_q" "$SOURCE_DOLT_LOG" >/dev/null &&
    fail "historical Dolt was started against the original source"

# Reopen the published target in a separate clean process and independently
# assert the complete five-issue/eight-feature semantic result.
reopen_stdout="$tmp/effectful-reopen.stdout"
reopen_stderr="$tmp/effectful-reopen.stderr"
set +e
(
    cd "$effect_ws"
    env -i PATH="$PATH" HOME="$tmp/home" LANG=C LC_ALL=C TZ=UTC TERM=dumb \
        "$TARGET_BD" list --json --all -n 0 \
        > "$reopen_stdout" 2> "$reopen_stderr"
)
reopen_status=$?
set -e
[ "$reopen_status" -eq 0 ] ||
    fail "separate-process target reopen exit=$reopen_status"
[ ! -s "$reopen_stderr" ] ||
    fail "separate-process target reopen emitted stderr"
jq -e '
    def deps:
        (.dependencies // []) |
        map({
            issue_id,
            depends_on_id,
            type,
            created_at,
            created_by,
            metadata: ((.metadata // "{}") | fromjson),
            thread_id: (.thread_id // "")
        }) | sort_by(.issue_id, .depends_on_id, .type);
    length == 5 and
    ([.[].id] | sort) ==
        ["old-bug", "old-closed", "old-epic", "old-standalone", "old-task"] and
    any(.[];
        .id == "old-epic" and .title == "Migration epic" and
        .description == "Epic for migration testing" and
        .priority == 2 and .issue_type == "epic" and .status == "open") and
    any(.[];
        .id == "old-standalone" and
        .description == "This task has a detailed description for fidelity testing." and
        .notes == "Historical notes must survive the upgrade." and
        .design == "Historical design must survive the upgrade." and
        .acceptance_criteria == "Historical acceptance criteria must survive the upgrade." and
        .external_ref == "legacy-upgrade-42") and
    any(.[]; .id == "old-closed" and .status == "closed") and
    any(.[];
        .id == "old-task" and .parent == "old-epic" and
        (deps == [{
            issue_id: "old-task",
            depends_on_id: "old-epic",
            type: "parent-child",
            created_at: "2025-01-02T03:04:05Z",
            created_by: "legacy-parent-author",
            metadata: {},
            thread_id: ""
        }]) and
        ((.labels // []) | index("urgent") != null) and
        ((.comments // [] | map({id, issue_id, author, text, created_at})) |
            index({
                id: "7dbef7d8-c3af-42e3-9b59-9f30e81e2647",
                issue_id: "old-task",
                author: "legacy-author",
                text: "Historical comment must survive the upgrade.",
                created_at: "2025-01-04T05:06:07Z"
            }) != null)) and
    any(.[];
        .id == "old-bug" and
        (deps == [{
            issue_id: "old-bug",
            depends_on_id: "old-task",
            type: "blocks",
            created_at: "2025-01-03T04:05:06Z",
            created_by: "legacy-block-author",
            metadata: {},
            thread_id: ""
        }]))
' "$reopen_stdout" >/dev/null ||
    fail "separate-process target lost the canonical semantic corpus"

# The retired private bundle is also an authority boundary. If an unknown
# top-level entry appears after the canonical fence is retired, the bridge
# preserves it and reports cleanup failure instead of recursively deleting it.
unknown_root_phase_dir="$tmp/effectful-unknown-transaction-root-phase"
mkdir -m 700 "$unknown_root_phase_dir"
touch \
    "$unknown_root_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$unknown_root_phase_dir/after_operation_fence_before_reinspect.continue" \
    "$unknown_root_phase_dir/after_staging_publish_before_journal_update.continue"
BRIDGE_TEST_PHASE_DIR="$unknown_root_phase_dir" \
    start_bridge_at_phase effectful-unknown-transaction-root "$effect_ws" \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"
wait_for_phase "$unknown_root_phase_dir" \
    after_operation_fence_retired_before_private_cleanup \
    "effectful unknown transaction root"
unknown_transaction_root=$(find -P "$effect_ws" -mindepth 1 -maxdepth 1 \
    -type d -name '.beads-v0.62.0-migration.runtime.*' -print -quit)
[ -n "$unknown_transaction_root" ] ||
    fail "retired transaction root was not discoverable"
unknown_transaction_entry=$'lock\nstaging'
printf '%s\n' 'unowned transaction bytes' \
    > "$unknown_transaction_root/$unknown_transaction_entry"
touch \
    "$unknown_root_phase_dir/after_operation_fence_retired_before_private_cleanup.continue"
finish_phase_bridge "effectful unknown transaction root"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "unknown transaction cleanup exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '.retryable == false and .code == "cleanup_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "unknown transaction cleanup was misclassified: $RUN_STDOUT"
[ -f "$unknown_transaction_root/$unknown_transaction_entry" ] ||
    fail "cleanup deleted an unexpected transaction-root entry"
sleep 0.1
rm -rf -- "$unknown_transaction_root"

# Allowed cleanup names do not authorize a different object type. Replacing
# journal.json with a directory must preserve its contents just like an
# entirely unknown entry.
wrong_lock_type_phase_dir="$tmp/effectful-wrong-lock-type-phase"
mkdir -m 700 "$wrong_lock_type_phase_dir"
touch \
    "$wrong_lock_type_phase_dir/after_operation_bundle_prepared_before_fence_publish.continue" \
    "$wrong_lock_type_phase_dir/after_operation_fence_before_reinspect.continue" \
    "$wrong_lock_type_phase_dir/after_staging_publish_before_journal_update.continue"
BRIDGE_TEST_PHASE_DIR="$wrong_lock_type_phase_dir" \
    start_bridge_at_phase effectful-wrong-lock-type "$effect_ws" \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"
wait_for_phase "$wrong_lock_type_phase_dir" \
    after_operation_fence_retired_before_private_cleanup \
    "effectful wrong lock entry type"
wrong_lock_type_root=$(find -P "$effect_ws" -mindepth 1 -maxdepth 1 \
    -type d -name '.beads-v0.62.0-migration.runtime.*' -print -quit)
[ -n "$wrong_lock_type_root" ] ||
    fail "wrong-type transaction root was not discoverable"
mv -f -- "$wrong_lock_type_root/lock/journal.json" \
    "$tmp/wrong-lock-type-journal.json"
mkdir -m 700 "$wrong_lock_type_root/lock/journal.json"
printf '%s\n' 'unowned allowed-name bytes' \
    > "$wrong_lock_type_root/lock/journal.json/sentinel"
touch \
    "$wrong_lock_type_phase_dir/after_operation_fence_retired_before_private_cleanup.continue"
finish_phase_bridge "effectful wrong lock entry type"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "wrong lock type exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '.retryable == false and .code == "cleanup_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "wrong lock type cleanup was misclassified: $RUN_STDOUT"
[ -f "$wrong_lock_type_root/lock/journal.json/sentinel" ] ||
    fail "cleanup recursively deleted an allowed-name replacement"
sleep 0.1
rm -rf -- "$wrong_lock_type_root"

# A second byte-for-byte identical invocation is authorized only by the
# committed receipt and verified retained rollback. It performs no extraction,
# initialization, import, publication, or workspace write.
second_before=$(tree_fingerprint "$effect_ws")
receipt_before=$(sha256sum "$receipt_path" | awk '{print $1}')
second_source_exports=$(call_count "$SOURCE_LOG" export)
second_source_shows=$(call_count "$SOURCE_LOG" show)
second_target_inits=$(call_count "$TARGET_LOG" init)
second_target_imports=$(call_count "$TARGET_LOG" import)
run_bridge effectful-no-op "$effect_ws" \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$effect_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "second effectful apply exit=$RUN_STATUS, want no-op exit 0"
[ -z "$RUN_STDERR" ] ||
    fail "second effectful apply emitted stderr in JSON mode: $RUN_STDERR"
assert_common_json apply succeeded none
jq -e \
    --arg plan "$canonical_plan" --arg rollback "$rollback_path" \
    --arg issue_prefix "$SOURCE_ISSUE_PREFIX" \
    --arg database "$SOURCE_DATABASE" \
    --arg project_id "$SOURCE_PROJECT_ID" '
    .retryable == false and .no_op == true and (.code | not) and
    .plan.digest == $plan and .target.backend == "dolt-embedded" and
    .plan.source_identity == {
        issue_prefix: $issue_prefix,
        database: $database,
        project_id: $project_id
    } and
    .rollback.path == $rollback and .rollback.policy == "retain" and
    .rollback.verified == true and
    .verification.semantic_scope_verified == true and
    .verification.separate_process_reopen == true
' <<< "$RUN_STDOUT" >/dev/null ||
    fail "second effectful apply did not report a verified no-op: $RUN_STDOUT"
assert_unchanged "$effect_ws" "$second_before" "second effectful apply"
[ "$(sha256sum "$receipt_path" | awk '{print $1}')" = "$receipt_before" ] ||
    fail "no-op invocation rewrote its completion receipt"
[ "$(call_count "$SOURCE_LOG" export)" -eq "$second_source_exports" ] &&
    [ "$(call_count "$SOURCE_LOG" show)" -eq "$second_source_shows" ] &&
[ "$(call_count "$TARGET_LOG" init)" -eq "$second_target_inits" ] &&
    [ "$(call_count "$TARGET_LOG" import)" -eq "$second_target_imports" ] ||
    fail "no-op invocation repeated a mutating migration phase"

assert_tampered_completion_refused() {
    local label="$1" before
    local exports_before shows_before inits_before imports_before
    before=$(tree_fingerprint "$effect_ws")
    exports_before=$(call_count "$SOURCE_LOG" export)
    shows_before=$(call_count "$SOURCE_LOG" show)
    inits_before=$(call_count "$TARGET_LOG" init)
    imports_before=$(call_count "$TARGET_LOG" import)
    run_bridge "$label" "$effect_ws" \
        --apply --yes --expect-plan "$canonical_plan" \
        --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
        --workspace "$effect_ws"
    [ "$RUN_STATUS" -eq 1 ] ||
        fail "$label exit=$RUN_STATUS, want completion refusal exit 1"
    assert_common_json apply refused none
    jq -e '
        .retryable == false and .code == "completion_state_invalid"
    ' <<< "$RUN_STDOUT" >/dev/null ||
        fail "$label did not fail closed on tampered completion state"
    assert_unchanged "$effect_ws" "$before" "$label"
    [ "$(call_count "$SOURCE_LOG" export)" -eq "$exports_before" ] &&
        [ "$(call_count "$SOURCE_LOG" show)" -eq "$shows_before" ] &&
        [ "$(call_count "$TARGET_LOG" init)" -eq "$inits_before" ] &&
        [ "$(call_count "$TARGET_LOG" import)" -eq "$imports_before" ] ||
        fail "$label restarted an effectful migration while refusing tampering"
}

# A completion claim is authority only while its receipt, retained source, and
# active target independently agree. Exercise each trust root separately and
# restore the fixture only after proving that the invocation made no changes.
receipt_backup="$tmp/effectful-receipt.valid.json"
cp -p -- "$receipt_path" "$receipt_backup"
jq '.state = "prepared"' "$receipt_backup" \
    > "$effect_ws/.beads/.tampered-receipt.json"
chmod 600 "$effect_ws/.beads/.tampered-receipt.json"
mv -f -- "$effect_ws/.beads/.tampered-receipt.json" "$receipt_path"
assert_tampered_completion_refused tampered-completion-receipt
cp -p -- "$receipt_backup" "$receipt_path"

jq '.plan.strategy.rollback = "delete"' "$receipt_backup" \
    > "$effect_ws/.beads/.tampered-receipt.json"
chmod 600 "$effect_ws/.beads/.tampered-receipt.json"
mv -f -- "$effect_ws/.beads/.tampered-receipt.json" "$receipt_path"
assert_tampered_completion_refused tampered-completion-plan-digest
cp -p -- "$receipt_backup" "$receipt_path"

printf '%s\n' 'rollback bytes changed after commit' \
    > "$rollback_path/.tampered-completion-state"
assert_tampered_completion_refused tampered-completion-rollback
rm -f -- "$rollback_path/.tampered-completion-state"

rollback_root_mode=$(stat -c '%a' "$rollback_path")
case "$rollback_root_mode" in
    700) rollback_tampered_mode=755 ;;
    *) rollback_tampered_mode=700 ;;
esac
chmod "$rollback_tampered_mode" "$rollback_path"
assert_tampered_completion_refused tampered-completion-rollback-root-mode
chmod "$rollback_root_mode" "$rollback_path"

# The receipt cannot redefine which source tree the authenticated plan bound.
# Even matching rollback bytes and receipt digest must fail when both diverge
# from the source observation committed in the plan.
printf '%s\n' 'rollback and receipt changed together after commit' \
    > "$rollback_path/.paired-tampered-completion-state"
paired_rollback_digest=$(content_fingerprint "$rollback_path")
jq --arg digest "$paired_rollback_digest" \
    '.rollback.tree_sha256 = $digest' "$receipt_backup" \
    > "$effect_ws/.beads/.tampered-receipt.json"
chmod 600 "$effect_ws/.beads/.tampered-receipt.json"
mv -f -- "$effect_ws/.beads/.tampered-receipt.json" "$receipt_path"
assert_tampered_completion_refused tampered-completion-rollback-receipt-pair
rm -f -- "$rollback_path/.paired-tampered-completion-state"
cp -p -- "$receipt_backup" "$receipt_path"

# Project-local routing state is unsafe even after publication; a receipt must
# not let retry bypass the same routing-artifact refusal enforced at admission.
printf '%s\n' '../redirected-after-completion' > "$effect_ws/.beads/redirect"
assert_tampered_completion_refused tampered-completion-routing-redirect
rm -f -- "$effect_ws/.beads/redirect"

printf '%s\n' 'dolt:' '  host: poison.invalid' '  port: 29998' \
    > "$effect_ws/.beads/config.yaml"
assert_tampered_completion_refused tampered-completion-active-config
rm -f -- "$effect_ws/.beads/config.yaml"

target_dolt="$effect_ws/.beads/embeddeddolt/$SOURCE_DATABASE/.dolt"
target_dolt_backup="$effect_ws/.beads/embeddeddolt/$SOURCE_DATABASE/.dolt-authentic"
mv -f -- "$target_dolt" "$target_dolt_backup"
ln -s .dolt-authentic "$target_dolt"
assert_tampered_completion_refused tampered-completion-symlink-dolt
rm -f -- "$target_dolt"
mv -f -- "$target_dolt_backup" "$target_dolt"

target_metadata="$effect_ws/.beads/metadata.json"
target_metadata_backup="$tmp/effectful-target-metadata.valid.json"
cp -p -- "$target_metadata" "$target_metadata_backup"
jq '.project_id = "00000000-0000-0000-0000-000000000000"' \
    "$target_metadata_backup" > "$effect_ws/.beads/.tampered-metadata.json"
mv -f -- "$effect_ws/.beads/.tampered-metadata.json" "$target_metadata"
assert_tampered_completion_refused tampered-completion-identity
cp -p -- "$target_metadata_backup" "$target_metadata"

target_config="$effect_ws/.beads/fake-target-config.json"
target_config_backup="$tmp/effectful-target-config.valid.json"
cp -p -- "$target_config" "$target_config_backup"
jq '.issue_prefix = "tampered"' \
    "$target_config_backup" > "$effect_ws/.beads/.tampered-config.json"
mv -f -- "$effect_ws/.beads/.tampered-config.json" "$target_config"
assert_tampered_completion_refused tampered-completion-prefix
cp -p -- "$target_config_backup" "$target_config"

target_state="$effect_ws/.beads/fake-target-state.jsonl"
target_state_backup="$tmp/effectful-target-state.valid.jsonl"
cp -p -- "$target_state" "$target_state_backup"
jq -c '
    if .id == "old-standalone"
    then .title = "Tampered after completion"
    else .
    end
' "$target_state_backup" > "$effect_ws/.beads/.tampered-target.jsonl"
mv -f -- "$effect_ws/.beads/.tampered-target.jsonl" "$target_state"
assert_tampered_completion_refused tampered-completion-target
cp -p -- "$target_state_backup" "$target_state"

# A verified retry is not successful until its operation fence is gone. The
# target fake adds an unknown lock entry during identity verification so lock
# retirement fails deterministically without relying on permissions as root.
touch "$effect_ws/.beads/force-noop-lock-cleanup-failure"
run_bridge forced-noop-lock-cleanup-failure "$effect_ws" \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$effect_ws"
[ "$RUN_STATUS" -eq 1 ] ||
    fail "forced no-op cleanup failure exit=$RUN_STATUS, want failure: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply failed none
jq -e '.retryable == false and .code == "cleanup_failed"' \
    <<< "$RUN_STDOUT" >/dev/null ||
    fail "no-op cleanup failure emitted success before releasing its fence"
[ -f "$effect_ws/.beads-v0.62.0-migration.lock/unexpected-entry" ] ||
    fail "no-op cleanup seam did not retain its obstruction evidence"
rm -f -- \
    "$effect_ws/.beads/force-noop-lock-cleanup-failure" \
    "$effect_ws/.beads-v0.62.0-migration.lock/unexpected-entry"
run_bridge forced-noop-lock-cleanup-recovery "$effect_ws" \
    --apply --yes --expect-plan "$canonical_plan" \
    --source-bd "$SOURCE_BD" --source-dolt "$SOURCE_DOLT" \
    --workspace "$effect_ws"
[ "$RUN_STATUS" -eq 0 ] ||
    fail "recovery after forced no-op cleanup failure failed: $RUN_STDOUT $RUN_STDERR"
assert_common_json apply succeeded none
jq -e '.no_op == true' <<< "$RUN_STDOUT" >/dev/null ||
    fail "cleanup recovery did not return a verified no-op"
[ ! -e "$effect_ws/.beads-v0.62.0-migration.lock" ] ||
    fail "cleanup recovery left the operation fence"

# Creating new work after migration must continue the source project's ID
# namespace. The fake persists the record so this cannot pass by printing a
# canned ID disconnected from the published target metadata.
post_create_stdout="$tmp/effectful-post-create.stdout"
post_create_stderr="$tmp/effectful-post-create.stderr"
set +e
(
    cd "$effect_ws"
    env -i PATH="$PATH" HOME="$tmp/home" LANG=C LC_ALL=C TZ=UTC TERM=dumb \
        "$TARGET_BD" create "Post-migration identity probe" --json \
        > "$post_create_stdout" 2> "$post_create_stderr"
)
post_create_status=$?
set -e
[ "$post_create_status" -eq 0 ] ||
    fail "post-migration create exit=$post_create_status"
[ ! -s "$post_create_stderr" ] ||
    fail "post-migration create emitted stderr"
jq -e --arg prefix "$SOURCE_ISSUE_PREFIX" '
    (.id | startswith($prefix + "-")) and
    .title == "Post-migration identity probe"
' "$post_create_stdout" >/dev/null ||
    fail "post-migration create did not use the preserved issue prefix"
post_create_id=$(jq -er '.id' "$post_create_stdout")
jq -e --arg id "$post_create_id" \
    'select(.id == $id and .title == "Post-migration identity probe")' \
    "$target_state" >/dev/null ||
    fail "post-migration create did not persist its prefixed issue"

# Every subprocess boundary is provider-hostile by construction. None of the
# PostgreSQL, MySQL, SQLite, external-Dolt, or path selectors may survive.
assert_log_unpoisoned "$TARGET_LOG" "target bd"
assert_log_unpoisoned "$SOURCE_LOG" "source bd"
assert_log_unpoisoned "$SOURCE_DOLT_LOG" "source Dolt runtime"
assert_log_unpoisoned "$BAD_SOURCE_LOG" "invalid source bd"
assert_log_unpoisoned "$BAD_SOURCE_DOLT_LOG" "invalid source Dolt runtime"
if [ -s "${SOURCE_DOLT_LOG}.pids" ]; then
    while IFS= read -r source_dolt_pid; do
        [[ "$source_dolt_pid" =~ ^[1-9][0-9]*$ ]] ||
            fail "historical Dolt fake recorded an invalid process ID"
        if kill -0 "$source_dolt_pid" 2>/dev/null; then
            fail "historical Dolt child $source_dolt_pid leaked after bridge completion"
        fi
    done < <(LC_ALL=C sort -u "${SOURCE_DOLT_LOG}.pids")
fi

printf 'public-v062-bridge-test: PASS\n'
