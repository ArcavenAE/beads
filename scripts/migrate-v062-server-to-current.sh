#!/bin/bash -p
# Qualified public bridge for v0.62.0 Dolt-server workspaces.
# Source admission is delegated to hidden no-follow plumbing in current bd.
# Transaction recovery covers process interruption on a live filesystem. This
# bridge does not claim to implement storage-engine power-loss durability.

set -uo pipefail
umask 077

readonly OPERATION=v062_server_to_current
readonly ENV_BIN=/usr/bin/env
readonly JQ_BIN=/usr/bin/jq
readonly READLINK_BIN=/usr/bin/readlink
readonly REALPATH_BIN=/usr/bin/realpath
readonly TIMEOUT_BIN=/usr/bin/timeout
readonly SHA256SUM_BIN=/usr/bin/sha256sum
readonly CP_BIN=/usr/bin/cp
readonly GIT_BIN=/usr/bin/git
readonly MKTEMP_BIN=/usr/bin/mktemp
readonly MKDIR_BIN=/usr/bin/mkdir
readonly RM_BIN=/usr/bin/rm
readonly RMDIR_BIN=/usr/bin/rmdir
readonly SLEEP_BIN=/usr/bin/sleep
readonly FIND_BIN=/usr/bin/find
readonly SORT_BIN=/usr/bin/sort
readonly XARGS_BIN=/usr/bin/xargs
readonly MV_BIN=/usr/bin/mv
readonly CHMOD_BIN=/usr/bin/chmod
readonly STAT_BIN=/usr/bin/stat
readonly CAT_BIN=/usr/bin/cat
readonly GREP_BIN=/usr/bin/grep
readonly FLOCK_BIN=/usr/bin/flock
readonly BOOT_ID_PATH=/proc/sys/kernel/random/boot_id
readonly SEMANTIC_SCOPE=v062_lossless_core_v1
readonly PLAN_SCHEMA=bd.v062.bridge-plan.v1

MODE=inspect
MODE_SET=false
JSON_OUTPUT=false
YES=false
WORKSPACE_ARG=
TARGET_BD_ARG=
SOURCE_BD_ARG=
SOURCE_DOLT_ARG=
EXPECT_PLAN=
SOURCE_BD=
SOURCE_DOLT=
SOURCE_BD_EXEC=
SOURCE_DOLT_EXEC=
SOURCE_BD_SHA256=
SOURCE_DOLT_SHA256=
SOURCE_ISSUE_PREFIX=
SOURCE_DATABASE=
SOURCE_PROJECT_ID=
SOURCE_SERVER_PORT=
TARGET_BD_SHA256=
TARGET_BD_EXEC=
PLAN_JSON=
PLAN_DIGEST=
SEMANTIC_PROBE=
RUNTIME_SCRATCH=
RUNTIME_SCRATCH_ID=
RUNTIME_GUARD_PID=
RUNTIME_GUARD_START_TIME=
SOURCE_SCRATCH=
SOURCE_SERVER_PID=
SOURCE_SERVER_START_TIME=
SOURCE_SERVER_LOG=
CLEAN_HOME=
QUALIFICATION_CODE=
QUALIFIED_SOURCE_TREE=
ROLLBACK_PATH=
CANONICAL_STAGING_PATH=
CANONICAL_LOCK_PATH=
STAGING_PATH=
LOCK_PATH=
LOCK_JOURNAL_PATH=
TRANSACTION_ROOT=
TRANSACTION_ROOT_ID=
TRANSACTION_LOCK_PATH=
TRANSACTION_STAGING_PATH=
TRANSACTION_GUARD_PID=
TRANSACTION_GUARD_START_TIME=
STAGING_ID=
LOCK_ID=
LOCK_PHASE=
LOCK_STAGING_ID=
LOCK_SOURCE_ID=
LOCK_OWNER_PID=
LOCK_OWNER_START_TIME=
LOCK_BOOT_ID=
WORKSPACE_LOCK_FD=
WORKSPACE_LOCK_HOLDER_PID=
WORKSPACE_LOCK_HOLDER_START_TIME=
WORKSPACE_LOCK_READY=
WORKSPACE_LOCK_RELEASE=
WORKSPACE_ID=
AUTHENTICATED_SOURCE_CONTENT=
STAGING_OWNED=false
LOCK_OWNED=false
LOCK_PUBLISHED=false
SOURCE_RENAMED=false
SOURCE_MOVE_ATTEMPTED=false
SOURCE_ORIGINAL_ID=
TRANSACTION_COMMITTED=false
TEST_PHASE_DIR=${BD_V062_TEST_PHASE_DIR:-}
TEST_FINGERPRINT_FAILURE=${BD_V062_TEST_FINGERPRINT_FAILURE:-}
TEST_MV_MODE=${BD_V062_TEST_MV_MODE:-}
TEST_RUNTIME_UNKNOWN_ENTRY=${BD_V062_TEST_RUNTIME_UNKNOWN_ENTRY:-}
TEST_IDENTITY_PROBE_FAILURE=${BD_V062_TEST_IDENTITY_PROBE_FAILURE:-}
TEST_GUARDIAN_START_FAILURE=${BD_V062_TEST_GUARDIAN_START_FAILURE:-}
UNSAFE_TEST_MV_BIN=${BD_V062_TEST_MV_BIN:-}

# Honor --json even when a preceding argument is invalid.
for argument in "$@"; do
    [ "$argument" = --json ] && JSON_OUTPUT=true
done

usage() {
    "$CAT_BIN" >&2 <<'EOF'
Usage: migrate-v062-server-to-current.sh [options]

  --workspace PROJECT  Project containing the v0.62.0 .beads directory
  --target-bd PATH     Absolute path to the current embedded-capable bd
  --source-bd PATH     Absolute path to the pinned v0.62.0 bd
  --source-dolt PATH   Absolute path to the pinned Dolt 1.84.0 runtime
  --inspect            Inspect only (default; no workspace effects)
  --apply              Perform the migration
  --yes                Required confirmation for --apply
  --expect-plan SHA256 Required inspect plan digest for --apply
  --json               Emit exactly one JSON result on stdout
  -h, --help           Show this help
EOF
}

bootstrap_json() {
    local status="$1" code="$2" retryable="$3" effect="$4"
    printf '{"schema_version":1,"operation":"%s",' "$OPERATION"
    printf '"mode":"%s","status":"%s","retryable":%s,' \
        "$MODE" "$status" "$retryable"
    printf '"effect":"%s","code":"%s"}\n' "$effect" "$code"
}

emit_base_json() {
    "$JQ_BIN" -cn \
        --arg operation "$OPERATION" --arg mode "$MODE" \
        --arg status "$1" --arg code "$2" \
        --argjson retryable "$3" --arg effect "$4" '
        {
            schema_version: 1, operation: $operation, mode: $mode,
            status: $status, retryable: $retryable, effect: $effect
        } + if $code == "" then {} else {code: $code} end
    '
}

finish_error() {
    local exit_status="$1" status="$2" code="$3"
    local retryable="$4" effect="$5" message="$6"
    printf '%s: %s\n' "$OPERATION" "$message" >&2
    if $JSON_OUTPUT; then
        if [ -x "$JQ_BIN" ]; then
            emit_base_json "$status" "$code" "$retryable" "$effect"
        else
            bootstrap_json "$status" "$code" "$retryable" "$effect"
        fi
    fi
    exit "$exit_status"
}

invalid_usage() {
    finish_error 2 usage_error "$1" false none "$2"
}

refuse() {
    finish_error 1 refused "$1" "$2" none "$3"
}

sha256_file() {
    local digest
    read -r digest _ < <("$SHA256SUM_BIN" -- "$1") || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

ensure_runtime_scratch() {
    local owner_start

    if [ -n "$RUNTIME_SCRATCH" ]; then
        return 0
    fi
    RUNTIME_SCRATCH=$("$MKTEMP_BIN" -d /tmp/bd-v062-runtime.XXXXXX) ||
        return 1
    RUNTIME_SCRATCH_ID=$(directory_identity "$RUNTIME_SCRATCH") || {
        RUNTIME_SCRATCH=
        return 1
    }
    if ! "$CHMOD_BIN" 700 -- "$RUNTIME_SCRATCH" ||
        ! owner_start=$(source_server_start_time "$$"); then
        remove_authenticated_directory \
            "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID" runtime \
            2>/dev/null || true
        RUNTIME_SCRATCH=
        RUNTIME_SCRATCH_ID=
        return 1
    fi
    (
        trap - EXIT
        close_workspace_lock_in_child
        runtime_scratch_guardian \
            "$$" "$owner_start" "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID"
    ) </dev/null >/dev/null 2>&1 &
    RUNTIME_GUARD_PID=$!
    RUNTIME_GUARD_START_TIME=$(bounded_process_start_time_builtin \
        "$RUNTIME_GUARD_PID" runtime_guardian_start) || return 1
    if [ "$TEST_RUNTIME_UNKNOWN_ENTRY" = inject ]; then
        printf '%s\n' 'test-only unknown runtime bytes' \
            > "$RUNTIME_SCRATCH/unexpected-runtime-entry" || return 1
    fi
}

pin_executable() {
    local source="$1" destination="$2"
    [ -f "$source" ] && [ -x "$source" ] && [ ! -L "$source" ] || return 1
    [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 1
    "$CP_BIN" -f -- "$source" "$destination" || return 1
    "$CHMOD_BIN" 700 -- "$destination" || return 1
    [ -f "$destination" ] && [ -x "$destination" ] &&
        [ ! -L "$destination" ] || return 1
}

clean_capture() {
    [ -n "$CLEAN_HOME" ] && [ -d "$CLEAN_HOME" ] &&
        [ ! -L "$CLEAN_HOME" ] || return 1
    "$ENV_BIN" -i \
        PATH=/usr/bin:/bin HOME="$CLEAN_HOME" TMPDIR="$CLEAN_HOME/tmp" \
        XDG_CONFIG_HOME="$CLEAN_HOME/config" \
        XDG_CACHE_HOME="$CLEAN_HOME/cache" \
        XDG_DATA_HOME="$CLEAN_HOME/data" \
        XDG_STATE_HOME="$CLEAN_HOME/state" \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        GIT_TERMINAL_PROMPT=0 BD_DISABLE_METRICS=1 \
        BD_DISABLE_EVENT_FLUSH=1 BD_NON_INTERACTIVE=1 \
        BEADS_NO_DAEMON=1 BEADS_DOLT_AUTO_START=0 \
        NO_COLOR=1 CI=1 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC TERM=dumb \
        "$TIMEOUT_BIN" --kill-after=5s "${INSPECT_TIMEOUT_SECONDS}s" "$@"
}

resolve_source_tools() {
    local version_json version_text

    if [ -z "$SOURCE_BD_ARG" ]; then
        refuse source_binary_missing false \
            "an explicit pinned v0.62.0 source bd is required"
    fi
    if [[ "$SOURCE_BD_ARG" != /* ]]; then
        refuse source_binary_invalid false \
            "--source-bd must be an absolute path"
    fi
    if [ ! -e "$SOURCE_BD_ARG" ] && [ ! -L "$SOURCE_BD_ARG" ]; then
        refuse source_binary_missing false \
            "the pinned v0.62.0 source bd is unavailable"
    fi
    [ ! -L "$SOURCE_BD_ARG" ] ||
        refuse source_binary_invalid false \
            "the source bd path must not be a symbolic link"
    SOURCE_BD=$("$READLINK_BIN" -f -- "$SOURCE_BD_ARG" 2>/dev/null) ||
        refuse source_binary_invalid false \
            "the source bd path cannot be resolved"
    [ -f "$SOURCE_BD" ] && [ -x "$SOURCE_BD" ] ||
        refuse source_binary_invalid false \
            "the source bd path is not an executable regular file"
    ensure_runtime_scratch ||
        refuse source_binary_invalid false \
            "a private source runtime directory cannot be created"
    SOURCE_BD_EXEC="$RUNTIME_SCRATCH/source-bd"
    pin_executable "$SOURCE_BD" "$SOURCE_BD_EXEC" ||
        refuse source_binary_invalid false \
            "the source bd executable cannot be pinned"
    ensure_clean_home ||
        refuse source_binary_invalid false \
            "an isolated runtime home could not be created"
    version_json=$(clean_capture "$SOURCE_BD_EXEC" version --json 2>/dev/null) ||
        refuse source_binary_invalid false \
            "the source bd version cannot be verified"
    version_text=$("$JQ_BIN" -er '.version | select(type == "string")' \
        <<< "$version_json" 2>/dev/null) ||
        refuse source_binary_invalid false \
            "the source bd version response is invalid"
    [ "$version_text" = 0.62.0 ] ||
        refuse source_binary_invalid false \
            "the source bd must be exactly v0.62.0"
    SOURCE_BD_SHA256=$(sha256_file "$SOURCE_BD_EXEC") ||
        refuse source_binary_invalid false \
            "the source bd identity cannot be hashed"

    if [ -z "$SOURCE_DOLT_ARG" ]; then
        refuse source_runtime_missing false \
            "an explicit pinned Dolt 1.84.0 runtime is required"
    fi
    if [[ "$SOURCE_DOLT_ARG" != /* ]]; then
        refuse source_runtime_invalid false \
            "--source-dolt must be an absolute path"
    fi
    if [ ! -e "$SOURCE_DOLT_ARG" ] && [ ! -L "$SOURCE_DOLT_ARG" ]; then
        refuse source_runtime_missing false \
            "the pinned Dolt 1.84.0 runtime is unavailable"
    fi
    [ ! -L "$SOURCE_DOLT_ARG" ] ||
        refuse source_runtime_invalid false \
            "the source Dolt path must not be a symbolic link"
    SOURCE_DOLT=$("$READLINK_BIN" -f -- "$SOURCE_DOLT_ARG" 2>/dev/null) ||
        refuse source_runtime_invalid false \
            "the source Dolt path cannot be resolved"
    [ -f "$SOURCE_DOLT" ] && [ -x "$SOURCE_DOLT" ] ||
        refuse source_runtime_invalid false \
            "the source Dolt path is not an executable regular file"
    SOURCE_DOLT_EXEC="$RUNTIME_SCRATCH/source-dolt"
    pin_executable "$SOURCE_DOLT" "$SOURCE_DOLT_EXEC" ||
        refuse source_runtime_invalid false \
            "the source Dolt executable cannot be pinned"
    version_text=$(clean_capture "$SOURCE_DOLT_EXEC" version 2>/dev/null) ||
        refuse source_runtime_invalid false \
            "the source Dolt version cannot be verified"
    "$GREP_BIN" -Eq '^dolt version 1[.]84[.]0([[:space:]]|$)' \
        <<< "$version_text" ||
        refuse source_runtime_invalid false \
            "the source Dolt runtime must be exactly 1.84.0"
    SOURCE_DOLT_SHA256=$(sha256_file "$SOURCE_DOLT_EXEC") ||
        refuse source_runtime_invalid false \
            "the source Dolt identity cannot be hashed"
}

semantic_issue_ids() {
    "$JQ_BIN" -cse '
        select(
            length == 5 and
            all(.[];
                type == "object" and
                ((.id? | type) == "string") and
                (.id | test("^[A-Za-z0-9._-]{1,128}$"))) and
            (([.[].id] | unique | length) == 5)
        ) |
        [.[].id] | sort
    ' "$1" 2>/dev/null
}

build_bound_plan() {
    local inspection="$1" semantic_file="$2" source_content="$3"
    local plan_without_digest target_version source_tree
    local baseline_ids baseline_digest

    target_version=$("$JQ_BIN" -er '.target.version' <<< "$inspection") ||
        return 1
    source_tree=$("$JQ_BIN" -er '.source.tree_sha256' <<< "$inspection") ||
        return 1
    [[ "$source_content" =~ ^[0-9a-f]{64}$ ]] || return 1
    baseline_ids=$(semantic_issue_ids "$semantic_file") || return 1
    baseline_digest=$(semantic_sha256 "$semantic_file") || return 1
    [[ "$TARGET_BD_SHA256" =~ ^[0-9a-f]{64}$ ]] || return 1
    plan_without_digest=$("$JQ_BIN" -cnS \
        --arg schema "$PLAN_SCHEMA" --arg workspace "$WORKSPACE" \
        --arg semantic_scope "$SEMANTIC_SCOPE" \
        --arg tree "$source_tree" \
        --arg source_content "$source_content" \
        --arg source_bd "$SOURCE_BD" --arg source_bd_sha "$SOURCE_BD_SHA256" \
        --arg source_dolt "$SOURCE_DOLT" --arg source_dolt_sha "$SOURCE_DOLT_SHA256" \
        --arg source_prefix "$SOURCE_ISSUE_PREFIX" \
        --arg source_database "$SOURCE_DATABASE" \
        --arg source_project_id "$SOURCE_PROJECT_ID" \
        --argjson baseline_ids "$baseline_ids" \
        --arg baseline_digest "$baseline_digest" \
        --arg target_bd "$TARGET_BD" --arg target_version "$target_version" \
        --arg target_sha "$TARGET_BD_SHA256" '
        {
            schema: $schema,
            workspace: $workspace,
            semantic_scope: $semantic_scope,
            target_backend: "dolt-embedded",
            source_observation: {
                tree_sha256: $tree,
                digest_scope: "admission_observation",
                content_sha256: $source_content,
                content_digest_scope: "complete_source_tree"
            },
            source_identity: {
                issue_prefix: $source_prefix,
                database: $source_database,
                project_id: $source_project_id
            },
            semantic_baseline: {
                issue_ids: $baseline_ids,
                sha256: $baseline_digest
            },
            source_binary: {
                path: $source_bd, version: "0.62.0", sha256: $source_bd_sha
            },
            source_runtime: {
                kind: "dolt", path: $source_dolt,
                version: "1.84.0", sha256: $source_dolt_sha
            },
            target_binary: {
                path: $target_bd, version: $target_version, sha256: $target_sha
            },
            strategy: {
                export: "native_export_show_comments_v1",
                import: "jsonl_v1",
                verification: "id_keyed_canonical_v1",
                cutover: "side_by_side_atomic_publish_v1",
                rollback: "retain"
            }
        }
    ') || return 1
    PLAN_DIGEST=$(printf '%s' "$plan_without_digest" | "$SHA256SUM_BIN" |
        { read -r digest _; printf '%s\n' "$digest"; }) || return 1
    [[ "$PLAN_DIGEST" =~ ^[0-9a-f]{64}$ ]] || return 1
    PLAN_JSON=$("$JQ_BIN" -cS --arg digest "$PLAN_DIGEST" \
        '. + {digest: $digest}' <<< "$plan_without_digest") || return 1
}

ensure_clean_home() {
    if [ -n "$CLEAN_HOME" ]; then
        [ "$CLEAN_HOME" = "$RUNTIME_SCRATCH/home" ] &&
            [ -d "$CLEAN_HOME" ] && [ ! -L "$CLEAN_HOME" ]
        return
    fi
    ensure_runtime_scratch || return 1
    CLEAN_HOME="$RUNTIME_SCRATCH/home"
    path_absent "$CLEAN_HOME" || return 1
    "$MKDIR_BIN" -m 700 -- "$CLEAN_HOME" || return 1
    "$MKDIR_BIN" -m 700 -- \
        "$CLEAN_HOME/config" "$CLEAN_HOME/cache" "$CLEAN_HOME/data" \
        "$CLEAN_HOME/state" "$CLEAN_HOME/tmp" || return 1
}

close_workspace_lock_in_child() {
    [ -z "$WORKSPACE_LOCK_FD" ] || exec {WORKSPACE_LOCK_FD}>&-
}

clean_at() {
    local cwd="$1"
    shift
    (
        close_workspace_lock_in_child
        cd -P -- "$cwd" || exit 1
        "$ENV_BIN" -i \
            PATH=/usr/bin:/bin HOME="$CLEAN_HOME" TMPDIR="$CLEAN_HOME/tmp" \
            XDG_CONFIG_HOME="$CLEAN_HOME/config" \
            XDG_CACHE_HOME="$CLEAN_HOME/cache" \
            XDG_DATA_HOME="$CLEAN_HOME/data" \
            XDG_STATE_HOME="$CLEAN_HOME/state" \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 BD_DISABLE_METRICS=1 \
            BD_DISABLE_EVENT_FLUSH=1 BD_NON_INTERACTIVE=1 \
            BD_NO_PAGER=1 BEADS_NO_DAEMON=1 BEADS_DOLT_AUTO_START=0 \
            NO_COLOR=1 CI=1 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC TERM=dumb \
            "$TIMEOUT_BIN" --kill-after=5s "${INSPECT_TIMEOUT_SECONDS}s" "$@"
    )
}

target_at() {
    local cwd="$1"
    shift
    [ ! -e "$cwd/.beads/.env" ] && [ ! -L "$cwd/.beads/.env" ] &&
        [ ! -e "$cwd/.beads/redirect" ] &&
        [ ! -L "$cwd/.beads/redirect" ] || return 1
    ensure_clean_home || return 1
    (
        close_workspace_lock_in_child
        cd -P -- "$cwd" || exit 1
        "$ENV_BIN" -i \
            PATH=/usr/bin:/bin HOME="$CLEAN_HOME" TMPDIR="$CLEAN_HOME/tmp" \
            XDG_CONFIG_HOME="$CLEAN_HOME/config" \
            XDG_CACHE_HOME="$CLEAN_HOME/cache" \
            XDG_DATA_HOME="$CLEAN_HOME/data" \
            XDG_STATE_HOME="$CLEAN_HOME/state" \
            BEADS_DIR="$cwd/.beads" USER=beads-migration \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 BD_DISABLE_METRICS=1 \
            BD_DISABLE_EVENT_FLUSH=1 BD_NON_INTERACTIVE=1 \
            BD_NO_PAGER=1 BEADS_NO_DAEMON=1 BEADS_DOLT_AUTO_START=0 \
            NO_COLOR=1 CI=1 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC TERM=dumb \
            "$TIMEOUT_BIN" --kill-after=5s "${INSPECT_TIMEOUT_SECONDS}s" "$@"
    )
}

source_at() {
    local cwd="$1"
    shift
    [[ "$SOURCE_SERVER_PORT" =~ ^[1-9][0-9]*$ ]] &&
        [ "$SOURCE_SERVER_PORT" -le 65535 ] || return 1
    [[ "$SOURCE_DATABASE" =~ ^[A-Za-z_][A-Za-z0-9_-]{0,63}$ ]] || return 1
    ensure_clean_home || return 1
    (
        close_workspace_lock_in_child
        cd -P -- "$cwd" || exit 1
        "$ENV_BIN" -i \
            PATH=/usr/bin:/bin HOME="$CLEAN_HOME" TMPDIR="$CLEAN_HOME/tmp" \
            XDG_CONFIG_HOME="$CLEAN_HOME/config" \
            XDG_CACHE_HOME="$CLEAN_HOME/cache" \
            XDG_DATA_HOME="$CLEAN_HOME/data" \
            XDG_STATE_HOME="$CLEAN_HOME/state" \
            BEADS_DOLT_SERVER_HOST=127.0.0.1 \
            BEADS_DOLT_SERVER_PORT="$SOURCE_SERVER_PORT" \
            BEADS_DOLT_SERVER_DATABASE="$SOURCE_DATABASE" \
            GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
            GIT_TERMINAL_PROMPT=0 BD_DISABLE_METRICS=1 \
            BD_DISABLE_EVENT_FLUSH=1 BD_NON_INTERACTIVE=1 \
            BD_NO_PAGER=1 BEADS_NO_DAEMON=1 BEADS_DOLT_AUTO_START=0 \
            NO_COLOR=1 CI=1 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC TERM=dumb \
            "$TIMEOUT_BIN" --kill-after=5s "${INSPECT_TIMEOUT_SECONDS}s" "$@"
    )
}

inspect_admission_source() {
    local workspace="$1" output process_status
    ensure_clean_home || return 1
    output=$(clean_at "$workspace" "$TARGET_BD_EXEC" \
        __migration-v062-inspect --workspace "$workspace" --json 2>/dev/null)
    process_status=$?
    [ "$process_status" -eq 0 ] || return 1
    "$JQ_BIN" -crse --arg workspace "$workspace" '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and .schema_version == 1 and
            .operation == "v062_source_inspection" and
            .status == "qualified" and .retryable == false and
            .effect == "none" and
            .source.workspace == $workspace and
            .source.version == "0.62.0" and
            .source.backend == "dolt-server" and
            (.source | keys) == [
                "backend", "database", "digest_scope", "project_id",
                "tree_sha256", "version", "workspace"
            ] and
            (.source.database | type) == "string" and
            (.source.database |
                test("^[A-Za-z_][A-Za-z0-9_-]{0,63}$")) and
            (.source.project_id | type) == "string" and
            (.source.project_id | test(
                "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            )) and
            .source.digest_scope == "admission_observation" and
            (.source.tree_sha256 | type) == "string" and
            (.source.tree_sha256 | test("^[0-9a-f]{64}$")) and
            .target.backend == "dolt-embedded" and
            .target.embedded_capable == true
        ) |
        .source
    ' 2>/dev/null <<< "$output"
}

inspect_admission_tree() {
    local source
    source=$(inspect_admission_source "$1") || return 1
    "$JQ_BIN" -er '.tree_sha256' <<< "$source" 2>/dev/null
}

content_fingerprint() {
    local root="$1" digest hold_pid hold_start owner_pid owner_start
    local output temporary unsafe
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    if [ "$TEST_FINGERPRINT_FAILURE" = hold ]; then
        [ -n "$TEST_PHASE_DIR" ] && [[ "$TEST_PHASE_DIR" = /* ]] &&
            [ -d "$TEST_PHASE_DIR" ] && [ ! -L "$TEST_PHASE_DIR" ] ||
            return 1
        path_absent "$TEST_PHASE_DIR/workspace-lock-child.identities" ||
            return 1
        temporary="$TEST_PHASE_DIR/workspace-lock-child.identities.next"
        path_absent "$temporary" || return 1
        "$SLEEP_BIN" 600 &
        hold_pid=$!
        owner_pid=$BASHPID
        owner_start=$(source_server_start_time "$owner_pid") || {
            kill -TERM "$hold_pid" 2>/dev/null || true
            wait "$hold_pid" 2>/dev/null || true
            return 1
        }
        hold_start=$(source_server_start_time "$hold_pid") || {
            kill -TERM "$hold_pid" 2>/dev/null || true
            wait "$hold_pid" 2>/dev/null || true
            return 1
        }
        printf '%s %s\n%s %s\n' \
            "$owner_pid" "$owner_start" "$hold_pid" "$hold_start" \
            > "$temporary" || {
            kill -TERM "$hold_pid" 2>/dev/null || true
            wait "$hold_pid" 2>/dev/null || true
            return 1
        }
        move_no_clobber_verified file "$temporary" \
            "$TEST_PHASE_DIR/workspace-lock-child.identities" || return 1
        wait "$hold_pid" || return 1
    fi
    unsafe=$(
        cd -P -- "$root" &&
            "$FIND_BIN" -P . -mindepth 1 \
                ! \( -type d -o -type f \) -print -quit
    ) || return 1
    [ -z "$unsafe" ] || return 1
    unsafe=$(
        cd -P -- "$root" &&
            "$FIND_BIN" -P . -type f -links +1 -print -quit
    ) || return 1
    [ -z "$unsafe" ] || return 1
    output=$(
        (
            cd -P -- "$root" || exit 1
            "$FIND_BIN" -P . -maxdepth 0 -printf '%y %m %p %l\n' ||
                exit 1
            "$FIND_BIN" -P . -mindepth 1 -printf '%y %m %p %l\n' |
                LC_ALL=C "$SORT_BIN" || exit 1
            {
                "$FIND_BIN" -P . -type f -print0 || exit 1
                if [ "$TEST_FINGERPRINT_FAILURE" = hash ]; then
                    [ ! -e .bd-v062-intentional-missing-hash-input ] &&
                        [ ! -L .bd-v062-intentional-missing-hash-input ] ||
                        exit 1
                    printf '%s\0' ./.bd-v062-intentional-missing-hash-input
                fi
            } | LC_ALL=C "$SORT_BIN" -z |
                "$XARGS_BIN" -0 -r "$SHA256SUM_BIN" || exit 1
        ) | "$SHA256SUM_BIN"
    ) || return 1
    read -r digest _ <<< "$output" || return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

directory_identity() {
    [ -d "$1" ] && [ ! -L "$1" ] || return 1
    "$STAT_BIN" -Lc '%d:%i' -- "$1" 2>/dev/null
}

regular_file_identity() {
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    "$STAT_BIN" -Lc '%d:%i' -- "$1" 2>/dev/null
}

path_absent() {
    [ ! -e "$1" ] && [ ! -L "$1" ]
}

close_workspace_lock() {
    local attempt probe_status=2 status=0 temporary

    if [ -n "$WORKSPACE_LOCK_FD" ]; then
        exec {WORKSPACE_LOCK_FD}>&- || status=1
        WORKSPACE_LOCK_FD=
    fi
    if [ -n "$WORKSPACE_LOCK_HOLDER_PID" ]; then
        [ -n "$WORKSPACE_LOCK_HOLDER_START_TIME" ] || return 1
        owned_directory_matches "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID" ||
            return 1
        temporary="${WORKSPACE_LOCK_RELEASE}.next"
        path_absent "$WORKSPACE_LOCK_RELEASE" && path_absent "$temporary" ||
            return 1
        printf '%s %s\n' "$WORKSPACE_LOCK_HOLDER_PID" \
            "$WORKSPACE_LOCK_HOLDER_START_TIME" > "$temporary" || return 1
        move_no_clobber_verified file \
            "$temporary" "$WORKSPACE_LOCK_RELEASE" || return 1
        for ((attempt = 0; attempt < 200; attempt++)); do
            probe_process_identity_builtin \
                "$WORKSPACE_LOCK_HOLDER_PID" \
                "$WORKSPACE_LOCK_HOLDER_START_TIME"
            probe_status=$?
            [ "$probe_status" -ne 1 ] || break
            "$SLEEP_BIN" 0.005
        done
        [ "$probe_status" -eq 1 ] || return 1
        wait "$WORKSPACE_LOCK_HOLDER_PID" 2>/dev/null || return 1
        WORKSPACE_LOCK_HOLDER_PID=
        WORKSPACE_LOCK_HOLDER_START_TIME=
        remove_known_regular_file "$WORKSPACE_LOCK_READY" || status=1
        remove_known_regular_file "$WORKSPACE_LOCK_RELEASE" || status=1
        WORKSPACE_LOCK_READY=
        WORKSPACE_LOCK_RELEASE=
    fi
    return "$status"
}

probe_process_identity_builtin() {
    local pid="$1" expected_start="$2" role="${3:-}" stat rest
    local -a fields

    [[ "$pid" =~ ^[1-9][0-9]*$ ]] &&
        [[ "$expected_start" =~ ^[0-9]+$ ]] || return 2
    if [ "$TEST_IDENTITY_PROBE_FAILURE" = owner_unverifiable ] &&
        [ "$role" = owner ] && kill -0 "$pid" 2>/dev/null; then
        return 2
    fi
    if ! IFS= read -r stat 2>/dev/null < "/proc/$pid/stat"; then
        kill -0 "$pid" 2>/dev/null && return 2
        return 1
    fi
    rest=${stat##*) }
    read -r -a fields <<< "$rest" || return 2
    [ "${#fields[@]}" -ge 20 ] || return 2
    [ "${fields[0]}" != Z ] || return 1
    [ "${fields[19]}" = "$expected_start" ] && return 0
    return 1
}

process_start_time_builtin() {
    local pid="$1" stat rest
    local -a fields

    IFS= read -r stat 2>/dev/null < "/proc/$pid/stat" || return 1
    rest=${stat##*) }
    read -r -a fields <<< "$rest" || return 1
    [ "${#fields[@]}" -ge 20 ] && [ "${fields[0]}" != Z ] || return 1
    printf '%s\n' "${fields[19]}"
}

bounded_process_start_time_builtin() {
    local pid="$1" role="$2" attempt start

    for ((attempt = 0; attempt < 200; attempt++)); do
        if [ "$TEST_GUARDIAN_START_FAILURE" != "$role" ]; then
            start=$(process_start_time_builtin "$pid") && {
                printf '%s\n' "$start"
                return 0
            }
        fi
        kill -0 "$pid" 2>/dev/null || return 1
        "$SLEEP_BIN" 0.005
    done
    return 2
}

workspace_lock_holder() {
    local owner_pid="$1" owner_start="$2" runtime="$3" runtime_id="$4"
    local ready="$5" release="$6" current_id release_pid release_start
    local self_pid="$BASHPID" self_start temporary="${ready}.next"
    local owner_status release_enabled=true

    trap '' HUP INT TERM
    self_start=$(process_start_time_builtin "$self_pid") || return 1
    path_absent "$ready" && path_absent "$temporary" || return 1
    printf '%s %s\n' "$self_pid" "$self_start" > "$temporary" || return 1
    (
        close_workspace_lock_in_child
        move_no_clobber_verified file "$temporary" "$ready"
    ) || return 1
    while :; do
        probe_process_identity_builtin "$owner_pid" "$owner_start" owner
        owner_status=$?
        [ "$owner_status" -ne 1 ] || break
        if [ "$owner_status" -eq 2 ]; then
            (
                close_workspace_lock_in_child
                exec "$SLEEP_BIN" 0.05
            )
            continue
        fi
        if $release_enabled; then
            current_id=$(
                close_workspace_lock_in_child
                directory_identity "$runtime"
            ) || release_enabled=false
            [ "$current_id" = "$runtime_id" ] || release_enabled=false
        fi
        if $release_enabled && [ -f "$release" ] && [ ! -L "$release" ]; then
            IFS=' ' read -r release_pid release_start < "$release" || {
                release_pid=
                release_start=
            }
            [ "$release_pid" = "$self_pid" ] &&
                [ "$release_start" = "$self_start" ] && break
        fi
        (
            close_workspace_lock_in_child
            exec "$SLEEP_BIN" 0.05
        )
    done
    close_workspace_lock_in_child
}

acquire_workspace_lock() {
    local attempt held_identity holder_pid holder_start owner_start
    local probe_status status

    WORKSPACE_ID=$(directory_identity "$WORKSPACE") || return 1
    owned_directory_matches "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID" ||
        return 1
    owner_start=$(source_server_start_time "$$") || return 1
    exec {WORKSPACE_LOCK_FD}<"$WORKSPACE" || return 1
    held_identity=$("$STAT_BIN" -Lc '%d:%i' -- \
        "/proc/$$/fd/$WORKSPACE_LOCK_FD" 2>/dev/null) || {
        close_workspace_lock
        return 1
    }
    if [ "$held_identity" != "$WORKSPACE_ID" ] ||
        [ "$(directory_identity "$WORKSPACE" 2>/dev/null)" != \
            "$WORKSPACE_ID" ]; then
        close_workspace_lock
        return 1
    fi
    "$FLOCK_BIN" -x -n -E 75 "$WORKSPACE_LOCK_FD"
    status=$?
    if [ "$status" -ne 0 ]; then
        close_workspace_lock
        return "$status"
    fi
    WORKSPACE_LOCK_READY="$RUNTIME_SCRATCH/.workspace-lock-ready"
    WORKSPACE_LOCK_RELEASE="$RUNTIME_SCRATCH/.workspace-lock-release"
    path_absent "$WORKSPACE_LOCK_READY" &&
        path_absent "$WORKSPACE_LOCK_RELEASE" || {
        close_workspace_lock
        return 1
    }
    (
        trap - EXIT
        workspace_lock_holder "$$" "$owner_start" \
            "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID" \
            "$WORKSPACE_LOCK_READY" "$WORKSPACE_LOCK_RELEASE"
    ) </dev/null >/dev/null 2>&1 &
    WORKSPACE_LOCK_HOLDER_PID=$!
    exec {WORKSPACE_LOCK_FD}>&- || return 1
    WORKSPACE_LOCK_FD=
    for ((attempt = 0; attempt < 200; attempt++)); do
        if [ -s "$WORKSPACE_LOCK_READY" ]; then
            IFS=' ' read -r holder_pid holder_start \
                < "$WORKSPACE_LOCK_READY" || {
                holder_pid=
                holder_start=
            }
            if [ "$holder_pid" = "$WORKSPACE_LOCK_HOLDER_PID" ] &&
                [[ "$holder_start" =~ ^[0-9]+$ ]]; then
                probe_process_identity_builtin "$holder_pid" "$holder_start"
                probe_status=$?
                if [ "$probe_status" -eq 0 ]; then
                    WORKSPACE_LOCK_HOLDER_START_TIME="$holder_start"
                    return 0
                fi
                [ "$probe_status" -ne 1 ] || break
            fi
        fi
        kill -0 "$WORKSPACE_LOCK_HOLDER_PID" 2>/dev/null || break
        "$SLEEP_BIN" 0.005
    done
    # Do not wait on a holder that may still be live. Returning failure makes
    # this owner exit; the holder then releases by authenticated owner identity.
    return 1
}

move_no_clobber_verified() {
    local kind="$1" source="$2" destination="$3" before after
    case "$kind" in
        directory) before=$(directory_identity "$source") || return 1 ;;
        file) before=$(regular_file_identity "$source") || return 1 ;;
        *) return 1 ;;
    esac

    if [ "$TEST_MV_MODE" = false_success_on_collision ] &&
        { [ -e "$destination" ] || [ -L "$destination" ]; }; then
        :
    else
        "$MV_BIN" -T --no-clobber -- "$source" "$destination" || return 1
    fi
    [ ! -e "$source" ] && [ ! -L "$source" ] || return 1

    case "$kind" in
        directory) after=$(directory_identity "$destination") || return 1 ;;
        file) after=$(regular_file_identity "$destination") || return 1 ;;
    esac
    [ "$after" = "$before" ] || return 1
    if [ "$TEST_MV_MODE" = fail_after_source_rename ] &&
        [ "$kind" = directory ] &&
        [ "$source" = "$WORKSPACE/.beads" ] &&
        [ "$destination" = "$ROLLBACK_PATH" ]; then
        return 1
    fi
}

owned_directory_matches() {
    local path="$1" expected="$2" actual
    [ -n "$expected" ] || return 1
    actual=$(directory_identity "$path") || return 1
    [ "$actual" = "$expected" ]
}

test_phase() {
    local phase="$1" attempt
    [ -n "$TEST_PHASE_DIR" ] || return 0
    [[ "$TEST_PHASE_DIR" = /* ]] &&
        [ -d "$TEST_PHASE_DIR" ] && [ ! -L "$TEST_PHASE_DIR" ] || return 1
    : > "$TEST_PHASE_DIR/$phase.reached" || return 1
    for ((attempt = 0; attempt < 600; attempt++)); do
        [ -f "$TEST_PHASE_DIR/$phase.continue" ] && return 0
        (
            close_workspace_lock_in_child
            exec "$SLEEP_BIN" 0.05
        )
    done
    return 1
}

source_server_start_time() {
    local pid="$1" stat rest
    local -a fields
    stat=$("$CAT_BIN" -- "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    read -r -a fields <<< "$rest" || return 1
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s\n' "${fields[19]}"
}

process_state() {
    local pid="$1" stat rest
    local -a fields
    stat=$("$CAT_BIN" -- "/proc/$pid/stat" 2>/dev/null) || return 1
    rest=${stat##*) }
    read -r -a fields <<< "$rest" || return 1
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s\n' "${fields[0]}"
}

guardian_test_marker() {
    local guardian="$1" event="$2"
    guardian_test_enabled || return 0
    : > "$TEST_PHASE_DIR/$guardian-guardian.$event"
}

guardian_test_enabled() {
    [ -n "$TEST_PHASE_DIR" ] || return 1
    [[ "$TEST_PHASE_DIR" = /* ]] && [ -d "$TEST_PHASE_DIR" ] &&
        [ ! -L "$TEST_PHASE_DIR" ] &&
        [ -f "$TEST_PHASE_DIR/guardian-cooperative-shutdown.enabled" ] &&
        [ ! -L "$TEST_PHASE_DIR/guardian-cooperative-shutdown.enabled" ]
}

guardian_test_checkpoint() {
    local guardian="$1"
    guardian_test_enabled || return 0
    test_phase "${guardian}_guardian_resource_removed"
}

runtime_scratch_guardian() {
    local owner_pid="$1" owner_start="$2" scratch="$3" expected_id="$4"
    local current_id owner_status

    # The guardian must survive loss of its owner, but normal cleanup can stop
    # and reap it explicitly.
    trap '' HUP INT
    if guardian_test_enabled; then
        trap 'guardian_test_marker runtime term || true; exit 97' TERM
    else
        trap '' TERM
    fi
    trap 'guardian_test_marker runtime done || true' EXIT
    guardian_test_marker runtime started || true
    while :; do
        current_id=$(directory_identity "$scratch" 2>/dev/null) || {
            if path_absent "$scratch"; then
                guardian_test_checkpoint runtime || return 1
                return 0
            fi
            break
        }
        [ "$current_id" = "$expected_id" ] || return 0
        probe_process_identity_builtin "$owner_pid" "$owner_start" owner
        owner_status=$?
        [ "$owner_status" -ne 1 ] || break
        "$SLEEP_BIN" 0.05
    done

    remove_authenticated_directory "$scratch" "$expected_id" runtime || true
}

transaction_root_guardian() {
    local owner_pid="$1" owner_start="$2" root="$3" root_id="$4"
    local canonical_lock="$5" private_lock="$6" lock_id="$7"
    local canonical_staging="$8" current_id owner_status

    # A canonical fence is the recovery authority. The guardian removes the
    # private bundle only before that fence is published, or after the same
    # lock inode has been retired back into the authenticated private root.
    trap '' HUP INT
    if guardian_test_enabled; then
        trap 'guardian_test_marker transaction term || true; exit 97' TERM
    else
        trap '' TERM
    fi
    trap 'guardian_test_marker transaction done || true' EXIT
    guardian_test_marker transaction started || true
    while :; do
        current_id=$(directory_identity "$root" 2>/dev/null) || {
            if path_absent "$root"; then
                guardian_test_checkpoint transaction || return 1
                return 0
            fi
            break
        }
        [ "$current_id" = "$root_id" ] || return 0
        probe_process_identity_builtin "$owner_pid" "$owner_start" owner
        owner_status=$?
        [ "$owner_status" -ne 1 ] || break
        "$SLEEP_BIN" 0.05
    done

    path_absent "$canonical_lock" || return 0
    path_absent "$canonical_staging" || return 0
    if ! owned_directory_matches "$private_lock" "$lock_id"; then
        path_absent "$private_lock" || return 0
    fi
    remove_authenticated_directory "$root" "$root_id" transaction || true
}

start_transaction_guardian() {
    local owner_start private_id canonical_id

    if [ -n "$TRANSACTION_GUARD_PID" ]; then
        [ -n "$TRANSACTION_GUARD_START_TIME" ] && return 0
        return 1
    fi
    owned_directory_matches "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" ||
        return 1
    private_id=$(directory_identity "$TRANSACTION_LOCK_PATH" 2>/dev/null) ||
        private_id=
    canonical_id=$(directory_identity "$CANONICAL_LOCK_PATH" 2>/dev/null) ||
        canonical_id=
    if [ "$private_id" = "$LOCK_ID" ] && [ -z "$canonical_id" ]; then
        :
    elif [ "$canonical_id" = "$LOCK_ID" ] && [ -z "$private_id" ]; then
        :
    else
        return 1
    fi
    owner_start=$(source_server_start_time "$$") || return 1
    (
        trap - EXIT
        close_workspace_lock_in_child
        transaction_root_guardian \
            "$$" "$owner_start" "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" \
            "$CANONICAL_LOCK_PATH" "$TRANSACTION_LOCK_PATH" "$LOCK_ID" \
            "$CANONICAL_STAGING_PATH"
    ) </dev/null >/dev/null 2>&1 &
    TRANSACTION_GUARD_PID=$!
    TRANSACTION_GUARD_START_TIME=$(bounded_process_start_time_builtin \
        "$TRANSACTION_GUARD_PID" transaction_guardian_start) || return 1
}

stop_transaction_guardian() {
    local attempt probe_status=2
    [ -n "$TRANSACTION_GUARD_PID" ] || return 0
    [ -n "$TRANSACTION_GUARD_START_TIME" ] || return 1
    guardian_test_marker transaction stop-waiting || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        probe_process_identity_builtin "$TRANSACTION_GUARD_PID" \
            "$TRANSACTION_GUARD_START_TIME"
        probe_status=$?
        [ "$probe_status" -ne 1 ] || break
        "$SLEEP_BIN" 0.005
    done
    [ "$probe_status" -eq 1 ] || return 1
    wait "$TRANSACTION_GUARD_PID" 2>/dev/null || return 1
    TRANSACTION_GUARD_PID=
    TRANSACTION_GUARD_START_TIME=
}

staging_directory_has_only_known_entries() (
    local root="$1" path entry
    local -a paths
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    shopt -s dotglob nullglob
    paths=("$root"/*)
    for path in "${paths[@]}"; do
        entry=${path##*/}
        case "$entry" in
            target)
                [ -d "$path" ] && [ ! -L "$path" ] ||
                    return 1
                ;;
            target-semantics.jsonl|reopen-semantics.jsonl)
                [ -f "$path" ] && [ ! -L "$path" ] ||
                    return 1
                ;;
            *) return 1 ;;
        esac
    done
)

runtime_directory_has_only_known_entries() (
    local root="$1" path entry
    local -a paths
    shopt -s dotglob nullglob
    paths=("$root"/*)
    for path in "${paths[@]}"; do
        entry=${path##*/}
        case "$entry" in
            home|source)
                [ -d "$path" ] && [ ! -L "$path" ] ||
                    return 1
                ;;
            source-bd|source-dolt|target-bd|target-export.jsonl|qualified.jsonl|\
            .workspace-lock-ready|.workspace-lock-ready.next|\
            .workspace-lock-release|.workspace-lock-release.next)
                [ -f "$path" ] && [ ! -L "$path" ] ||
                    return 1
                ;;
            *) return 1 ;;
        esac
    done
)

transaction_directory_has_only_known_entries() (
    local root="$1" path entry
    local -a paths
    shopt -s dotglob nullglob
    paths=("$root"/*)
    for path in "${paths[@]}"; do
        entry=${path##*/}
        case "$entry" in
            lock)
                [ -d "$path" ] && [ ! -L "$path" ] &&
                    lock_directory_has_only_known_files "$path" ||
                    return 1
                ;;
            staging)
                staging_directory_has_only_known_entries "$path" ||
                    return 1
                ;;
            *) return 1 ;;
        esac
    done
)

cleanup_tree_is_safe() {
    # This rejects pre-existing corruption before recursive cleanup. The
    # workspace flock coordinates supported callers; an actively adversarial
    # same-UID process racing this private 0700 tree is outside this bridge's
    # process-interruption guarantee.
    case "$2" in
        runtime) runtime_directory_has_only_known_entries "$1" ;;
        transaction) transaction_directory_has_only_known_entries "$1" ;;
        *) return 1 ;;
    esac
}

remove_authenticated_directory() {
    local path="$1" expected_id="$2" policy="$3"
    local test_phase_name="${4:-}"
    local directory_fd held_id current_id root_fd
    local owner_pid=$BASHPID

    [ -n "$expected_id" ] || return 1
    case "$policy" in
        runtime|transaction) ;;
        *) return 1 ;;
    esac
    exec {directory_fd}<"$path" || return 1
    root_fd="/proc/$owner_pid/fd/$directory_fd"
    held_id=$("$STAT_BIN" -Lc '%d:%i' -- \
        "$root_fd" 2>/dev/null) || {
        exec {directory_fd}>&-
        return 1
    }
    [ "$held_id" = "$expected_id" ] || {
        exec {directory_fd}>&-
        return 1
    }
    current_id=$(directory_identity "$path") || {
        exec {directory_fd}>&-
        return 1
    }
    [ "$current_id" = "$expected_id" ] || {
        exec {directory_fd}>&-
        return 1
    }
    cleanup_tree_is_safe "$root_fd" "$policy" || {
        exec {directory_fd}>&-
        return 1
    }
    (
        cd -P -- "$root_fd" || exit 1
        "$FIND_BIN" -P . -xdev -mindepth 1 -depth -delete
    ) || {
        exec {directory_fd}>&-
        return 1
    }
    if [ -n "$test_phase_name" ] &&
        [ "${BD_V062_TEST_FAILPOINT:-}" = "$test_phase_name" ] &&
        ! test_phase "$test_phase_name"; then
        exec {directory_fd}>&-
        return 1
    fi
    current_id=$(directory_identity "$path") || {
        exec {directory_fd}>&-
        return 1
    }
    [ "$current_id" = "$expected_id" ] || {
        exec {directory_fd}>&-
        return 1
    }
    "$RMDIR_BIN" -- "$path" || {
        exec {directory_fd}>&-
        return 1
    }
    exec {directory_fd}>&-
    path_absent "$path"
}

stop_runtime_guardian() {
    local attempt probe_status=2
    [ -n "$RUNTIME_GUARD_PID" ] || return 0
    [ -n "$RUNTIME_GUARD_START_TIME" ] || return 1
    guardian_test_marker runtime stop-waiting || true
    for ((attempt = 0; attempt < 200; attempt++)); do
        probe_process_identity_builtin "$RUNTIME_GUARD_PID" \
            "$RUNTIME_GUARD_START_TIME"
        probe_status=$?
        [ "$probe_status" -ne 1 ] || break
        "$SLEEP_BIN" 0.005
    done
    [ "$probe_status" -eq 1 ] || return 1
    wait "$RUNTIME_GUARD_PID" 2>/dev/null || return 1
    RUNTIME_GUARD_PID=
    RUNTIME_GUARD_START_TIME=
}

cleanup_runtime_scratch() {
    local status=0

    if [ -n "$RUNTIME_SCRATCH" ]; then
        if path_absent "$RUNTIME_SCRATCH"; then
            stop_runtime_guardian || status=1
        elif remove_authenticated_directory \
            "$RUNTIME_SCRATCH" "$RUNTIME_SCRATCH_ID" runtime; then
            stop_runtime_guardian || status=1
        else
            # Preserve both renamed evidence and any replacement pathname.
            status=1
        fi
    fi
    if [ "$status" -eq 0 ]; then
        RUNTIME_SCRATCH=
        RUNTIME_SCRATCH_ID=
        SOURCE_SCRATCH=
        CLEAN_HOME=
        SEMANTIC_PROBE=
    fi
    return "$status"
}

owned_source_server_alive() {
    local current
    [ -n "$SOURCE_SERVER_PID" ] && [ -n "$SOURCE_SERVER_START_TIME" ] ||
        return 1
    kill -0 "$SOURCE_SERVER_PID" 2>/dev/null || return 1
    current=$(source_server_start_time "$SOURCE_SERVER_PID") || return 1
    [ "$current" = "$SOURCE_SERVER_START_TIME" ]
}

stop_owned_source_server() {
    local attempt
    if [ -z "$SOURCE_SERVER_PID" ]; then
        return 0
    fi
    if owned_source_server_alive; then
        kill -TERM "$SOURCE_SERVER_PID" 2>/dev/null || true
        for ((attempt = 0; attempt < 100; attempt++)); do
            owned_source_server_alive || break
            "$SLEEP_BIN" 0.05
        done
        if owned_source_server_alive; then
            kill -KILL "$SOURCE_SERVER_PID" 2>/dev/null || true
        fi
    fi
    wait "$SOURCE_SERVER_PID" 2>/dev/null || true
    SOURCE_SERVER_PID=
    SOURCE_SERVER_START_TIME=
}

cleanup_owned_paths() {
    stop_owned_source_server
}

canonical_semantic_corpus() {
    "$JQ_BIN" -se '
        def deps:
            (.dependencies // []) |
            map({
                id: (.id // .depends_on_id),
                type: (.dependency_type // .type)
            }) | sort_by(.id, .type);
        def parent:
            .parent //
            ([deps[] | select(.type == "parent-child") | .id] |
                if length == 1 then .[0] else "" end);
        def unsupported:
            has("assignee") or has("estimated_minutes") or
            has("due_at") or has("defer_until") or has("source_system") or
            has("metadata") or has("spec_id") or
            has("compaction_level") or has("compacted_at") or
            has("compacted_at_commit") or has("original_size") or
            has("sender") or has("ephemeral") or has("no_history") or
            has("wisp_type") or has("pinned") or has("is_template") or
            has("bonded_from") or has("await_type") or has("await_id") or
            has("timeout") or has("waiters") or has("source_formula") or
            has("source_location") or has("mol_type") or has("work_type") or
            has("event_kind") or has("actor") or has("target") or
            has("payload") or has("crystallizes") or has("creator") or
            has("quality_score") or has("validations") or
            has("hook_bead") or has("role_bead") or
            has("agent_state") or has("last_activity") or
            has("role_type") or has("rig") or has("holder") or
            has("closed_by_session");
        ([.[] | select(.title == "Migration epic") | .id][0]) as $epic |
        ([.[] | select(.title == "Migration task alpha") | .id][0]) as $task |
        length == 5 and
        all(.[];
            type == "object" and
            ((.id? | type) == "string") and
            (.id | test("^[A-Za-z0-9._-]{1,128}$")) and
            (unsupported | not)) and
        (([.[].id] | length) == ([.[].id] | unique | length)) and
        any(.[];
            .title == "Migration epic" and
            .description == "Epic for migration testing" and
            .priority == 2 and .issue_type == "epic" and
            .status == "open" and (deps | length) == 0) and
        any(.[];
            .title == "Standalone detailed task" and
            .description == "This task has a detailed description for fidelity testing." and
            .notes == "Historical notes must survive the upgrade." and
            .design == "Historical design must survive the upgrade." and
            .acceptance_criteria == "Historical acceptance criteria must survive the upgrade." and
            .external_ref == "legacy-upgrade-42" and
            .priority == 2 and .issue_type == "task" and
            .status == "open" and (deps | length) == 0) and
        any(.[];
            .title == "Already closed issue" and
            .priority == 3 and .issue_type == "task" and
            .status == "closed" and (deps | length) == 0) and
        ([.[] | select(.title == "Migration epic") | .id] | length == 1) and
        ([.[] | select(.title == "Migration task alpha")] | length == 1) and
        ([.[] | select(.title == "Migration bug beta")] | length == 1) and
        any(.[];
            .id == $task and .priority == 1 and
            .issue_type == "task" and .status == "open" and
            parent == $epic and
            deps == [{id: $epic, type: "parent-child"}] and
            ((.labels // []) | sort) == ["urgent"] and
            ((.comments // [] | map({author, text})) |
                index({
                    author: "legacy-author",
                    text: "Historical comment must survive the upgrade."
                }) != null)) and
        any(.[];
            .title == "Migration bug beta" and
            .priority == 3 and .issue_type == "bug" and
            .status == "open" and
            deps == [{id: $task, type: "blocks"}])
    ' "$1" >/dev/null 2>&1
}

qualified_source_semantic_corpus() {
    canonical_semantic_corpus "$1" || return 1
    "$JQ_BIN" -se '
        def allowed_keys: [
            "id", "title", "description", "design",
            "acceptance_criteria", "notes", "status", "priority",
            "issue_type", "created_at", "created_by", "updated_at",
            "closed_at", "close_reason", "owner", "external_ref", "parent",
            "labels", "dependencies", "comments", "dependency_count",
            "dependent_count", "comment_count"
        ];
        def allowed_dependency_keys: [
            "issue_id", "depends_on_id", "type", "created_at",
            "created_by", "metadata", "thread_id"
        ];
        def allowed_comment_keys: [
            "id", "issue_id", "author", "text", "created_at"
        ];
        all(.[];
            . as $issue |
            (($issue | keys - allowed_keys) | length) == 0 and
            all(($issue.dependencies // [])[];
                type == "object" and
                ((keys - allowed_dependency_keys) | length) == 0 and
                .issue_id == $issue.id and
                ((.depends_on_id? | type) == "string") and
                ((.depends_on_id? | length) > 0) and
                ((.type? | type) == "string") and
                ((.type? | length) > 0) and
                ((.created_at? | type) == "string") and
                ((.created_at? | length) > 0) and
                ((.created_by? | type) == "string") and
                ((.created_by? | length) > 0) and
                ((.metadata? // "{}") as $metadata |
                    ($metadata | type) == "string" and
                    ((try ($metadata | fromjson) catch null) == {})) and
                ((.thread_id? // "") == "")) and
            all(($issue.comments // [])[];
                type == "object" and
                ((keys - allowed_comment_keys) | length) == 0 and
                ((.id? | type) == "string") and
                ((.id? | length) > 0) and
                (.issue_id == $issue.id) and
                ((.author? | type) == "string") and
                ((.text? | type) == "string") and
                ((.created_at? | type) == "string") and
                ((.created_at? | length) > 0)))
    ' "$1" >/dev/null 2>&1
}

canonical_semantic_json() {
    "$JQ_BIN" -csS '
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
            }) |
            sort_by(
                .issue_id, .depends_on_id, .type, .created_at, .created_by,
                (.metadata | tojson), .thread_id
            );
        def parent:
            .parent //
            ([deps[] |
                select(.type == "parent-child") | .depends_on_id] |
                if length == 1 then .[0] else "" end);
        map({
            id,
            title,
            description: (.description // ""),
            notes: (.notes // ""),
            design: (.design // ""),
            acceptance_criteria: (.acceptance_criteria // ""),
            external_ref: (.external_ref // ""),
            owner: (.owner // ""),
            created_at: (.created_at // ""),
            created_by: (.created_by // ""),
            updated_at: (.updated_at // ""),
            closed_at: (.closed_at // ""),
            close_reason: (.close_reason // ""),
            priority,
            issue_type,
            status,
            parent: parent,
            labels: ((.labels // []) | sort),
            dependencies: deps,
            comments: ((.comments // []) |
                map({id, issue_id, author, text, created_at}) |
                sort_by(.id, .issue_id, .author, .text, .created_at))
        }) | sort_by(.id)
    ' "$1" 2>/dev/null
}

verify_embedded_layout() {
    local root="$1" metadata database config database_root grep_status
    [ -d "$root/.beads" ] && [ ! -L "$root/.beads" ] || return 1
    [ ! -e "$root/.beads/.env" ] && [ ! -L "$root/.beads/.env" ] &&
        [ ! -e "$root/.beads/redirect" ] &&
        [ ! -L "$root/.beads/redirect" ] || return 1
    config="$root/.beads/config.yaml"
    if [ -e "$config" ] || [ -L "$config" ]; then
        [ -f "$config" ] && [ ! -L "$config" ] || return 1
        if "$GREP_BIN" -Eq '^[[:space:]]*[^#[:space:]]' -- "$config" \
            2>/dev/null; then
            return 1
        else
            grep_status=$?
            [ "$grep_status" -eq 1 ] || return 1
        fi
    fi
    metadata="$root/.beads/metadata.json"
    [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
    database=$("$JQ_BIN" -er '
        select(.backend == "dolt" and .dolt_mode == "embedded") |
        (.dolt_database // .database) |
        select(type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]{0,63}$"))
    ' "$metadata" 2>/dev/null) || return 1
    database_root="$root/.beads/embeddeddolt/$database"
    [ -d "$root/.beads/embeddeddolt" ] &&
        [ ! -L "$root/.beads/embeddeddolt" ] &&
        [ -d "$database_root" ] && [ ! -L "$database_root" ] &&
        [ -d "$database_root/.dolt" ] && [ ! -L "$database_root/.dolt" ] &&
        [ ! -e "$root/.beads/dolt" ] && [ ! -L "$root/.beads/dolt" ]
}

# Post-init identity re-check (belt-and-suspenders): re-verify backend,
# dolt_mode, database, project_id, and issue_prefix directly from the published
# target. repo_id/clone_id are intentionally NOT re-checked here even though
# --migration-v062-repository-root exists to get them right: they are computed
# by the target binary's init from that flag, their persistence is
# fatal-on-failure (cmd/bd/init.go), and it is proven end to end in Go by
# TestMigrationV062StagedInitPublishesFinalRepositoryIdentity. Re-deriving them
# in shell would duplicate the Go identity logic (ComputeRepoIDForPath /
# GetCloneIDForPath) this bridge deliberately reuses rather than reimplements,
# so those two guarantees are delegated to init's fatal contract.
verify_target_identity() {
    local root="$1" metadata prefix_json
    metadata="$root/.beads/metadata.json"
    [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
    "$JQ_BIN" -e \
        --arg database "$SOURCE_DATABASE" \
        --arg project_id "$SOURCE_PROJECT_ID" '
        .backend == "dolt" and .dolt_mode == "embedded" and
        (.dolt_database // .database) == $database and
        .project_id == $project_id
    ' "$metadata" >/dev/null 2>&1 || return 1
    prefix_json=$(target_at "$root" "$TARGET_BD_EXEC" \
        config get issue_prefix --json 2>/dev/null) || return 1
    "$JQ_BIN" -cse --arg issue_prefix "$SOURCE_ISSUE_PREFIX" '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and
            keys == ["key", "schema_version", "value"] and
            .schema_version == 1 and
            .key == "issue_prefix" and .value == $issue_prefix
        )
    ' >/dev/null 2>&1 <<< "$prefix_json"
}

collect_target_semantics() {
    local root="$1" destination="$2" expected_ids="${3:-}"
    local inventory ids selected_ids raw_export

    inventory=$(target_at "$root" "$TARGET_BD_EXEC" list --json --all -n 0 \
        2>/dev/null) || return 1
    if [ -n "$expected_ids" ]; then
        ids=$("$JQ_BIN" -cer --argjson expected "$expected_ids" '
            select(type == "array") |
            ([.[].id]) as $actual |
            if
                ($expected | type) == "array" and
                ($expected | length) == 5 and
                all($expected[];
                    type == "string" and
                    test("^[A-Za-z0-9._-]{1,128}$")) and
                $expected == ($expected | sort | unique) and
                all(.[];
                    type == "object" and
                    ((.id? | type) == "string") and
                    (.id | test("^[A-Za-z0-9._-]{1,128}$"))) and
                ($actual | length) == ($actual | unique | length) and
                (($expected - $actual) | length) == 0
            then $expected[] | @json
            else error("invalid target baseline")
            end
        ' <<< "$inventory" 2>/dev/null) || return 1
    else
        ids=$("$JQ_BIN" -cer '
            select(type == "array") |
            if length == 5 and
               all(.[];
                   type == "object" and
                   ((.id? | type) == "string") and
                   (.id | test("^[A-Za-z0-9._-]{1,128}$"))) and
               (([.[].id] | unique | length) == 5)
            then .[].id | @json
            else error("invalid target inventory")
            end
        ' <<< "$inventory" 2>/dev/null) || return 1
    fi
    selected_ids=$("$JQ_BIN" -cs 'select(length > 0)' <<< "$ids" \
        2>/dev/null) || return 1
    raw_export="$RUNTIME_SCRATCH/target-export.jsonl"
    path_absent "$raw_export" || return 1
    if ! target_at "$root" "$TARGET_BD_EXEC" export --no-memories \
        -o "$raw_export" >/dev/null 2>&1; then
        "$RM_BIN" -f -- "$raw_export" >/dev/null 2>&1 || true
        return 1
    fi
    if ! "$JQ_BIN" -ce -s --argjson selected "$selected_ids" '
        . as $records |
        ([$records[] |
            select(.id as $id | $selected | index($id) != null)]) as $matches |
        if
            ($matches | length) == ($selected | length) and
            (($matches | map(.id) | sort) == ($selected | sort))
        then $matches[]
        else error("target export does not contain the selected IDs exactly once")
        end
    ' "$raw_export" > "$destination" 2>/dev/null; then
        "$RM_BIN" -f -- "$raw_export" >/dev/null 2>&1 || true
        return 1
    fi
    "$RM_BIN" -f -- "$raw_export" || return 1
    canonical_semantic_corpus "$destination"
}

semantics_match() {
    local source="$1" target="$2" source_json target_json
    source_json=$(canonical_semantic_json "$source") || return 1
    target_json=$(canonical_semantic_json "$target") || return 1
    [ "$source_json" = "$target_json" ]
}

semantic_sha256() {
    local semantic_json digest
    semantic_json=$(canonical_semantic_json "$1") || return 1
    read -r digest _ < <(printf '%s' "$semantic_json" | "$SHA256SUM_BIN") ||
        return 1
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

transaction_root_path_is_valid() {
    local prefix="$WORKSPACE/.beads-v0.62.0-migration.runtime."
    local suffix=${TRANSACTION_ROOT#"$prefix"}

    [ "$suffix" != "$TRANSACTION_ROOT" ] && [ "${#suffix}" -eq 6 ] &&
        [[ "$suffix" =~ ^[A-Za-z0-9]+$ ]] &&
        [ "$TRANSACTION_LOCK_PATH" = "$TRANSACTION_ROOT/lock" ] &&
        [ "$TRANSACTION_STAGING_PATH" = "$TRANSACTION_ROOT/staging" ]
}

clear_operation_state() {
    STAGING_OWNED=false
    LOCK_OWNED=false
    LOCK_PUBLISHED=false
    STAGING_ID=
    LOCK_ID=
    LOCK_PHASE=
    LOCK_STAGING_ID=
    LOCK_SOURCE_ID=
    LOCK_OWNER_PID=
    LOCK_OWNER_START_TIME=
    LOCK_BOOT_ID=
    TRANSACTION_ROOT=
    TRANSACTION_ROOT_ID=
    TRANSACTION_LOCK_PATH=
    TRANSACTION_STAGING_PATH=
    STAGING_PATH="$CANONICAL_STAGING_PATH"
    LOCK_PATH="$CANONICAL_LOCK_PATH"
    LOCK_JOURNAL_PATH="$LOCK_PATH/journal.json"
}

create_operation_bundle() {
    local lock_id staging_id source_id owner_start boot_id

    path_absent "$CANONICAL_LOCK_PATH" &&
        path_absent "$CANONICAL_STAGING_PATH" || return 1
    TRANSACTION_ROOT=$(
        "$MKTEMP_BIN" -d \
            "$WORKSPACE/.beads-v0.62.0-migration.runtime.XXXXXX"
    ) || return 1
    TRANSACTION_ROOT_ID=$(directory_identity "$TRANSACTION_ROOT") || {
        TRANSACTION_ROOT=
        clear_operation_state
        return 1
    }
    if ! "$CHMOD_BIN" 700 -- "$TRANSACTION_ROOT"; then
        remove_authenticated_directory \
            "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" transaction \
            2>/dev/null || true
        clear_operation_state
        return 1
    fi
    TRANSACTION_LOCK_PATH="$TRANSACTION_ROOT/lock"
    TRANSACTION_STAGING_PATH="$TRANSACTION_ROOT/staging"
    if ! transaction_root_path_is_valid ||
        ! "$MKDIR_BIN" -m 700 -- \
            "$TRANSACTION_LOCK_PATH" "$TRANSACTION_STAGING_PATH"; then
        remove_authenticated_directory \
            "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" transaction \
            2>/dev/null || true
        clear_operation_state
        return 1
    fi

    LOCK_PATH="$TRANSACTION_LOCK_PATH"
    LOCK_JOURNAL_PATH="$LOCK_PATH/journal.json"
    STAGING_PATH="$TRANSACTION_STAGING_PATH"
    if ! lock_id=$(directory_identity "$LOCK_PATH") ||
        ! staging_id=$(directory_identity "$STAGING_PATH") ||
        ! source_id=$(directory_identity "$WORKSPACE/.beads") ||
        ! owner_start=$(source_server_start_time "$$") ||
        ! boot_id=$("$CAT_BIN" -- "$BOOT_ID_PATH" 2>/dev/null); then
        remove_authenticated_directory \
            "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" transaction \
            2>/dev/null || true
        clear_operation_state
        return 1
    fi
    LOCK_ID="$lock_id"
    STAGING_ID="$staging_id"
    LOCK_OWNED=true
    STAGING_OWNED=true
    LOCK_PUBLISHED=false
    LOCK_STAGING_ID="$STAGING_ID"
    LOCK_SOURCE_ID="$source_id"
    LOCK_OWNER_PID=$$
    LOCK_OWNER_START_TIME="$owner_start"
    LOCK_BOOT_ID="$boot_id"
    write_lock_journal fenced || return 1
    start_transaction_guardian
}

publish_operation_lock() {
    $LOCK_OWNED && ! $LOCK_PUBLISHED || return 1
    [ "$LOCK_PATH" = "$TRANSACTION_LOCK_PATH" ] || return 1
    owned_directory_matches "$LOCK_PATH" "$LOCK_ID" || return 1
    path_absent "$CANONICAL_LOCK_PATH" || return 1
    move_no_clobber_verified directory \
        "$LOCK_PATH" "$CANONICAL_LOCK_PATH" || return 1
    LOCK_PATH="$CANONICAL_LOCK_PATH"
    LOCK_JOURNAL_PATH="$LOCK_PATH/journal.json"
    LOCK_PUBLISHED=true
}

publish_operation_staging() {
    $STAGING_OWNED && $LOCK_PUBLISHED || return 1
    [ "$STAGING_PATH" = "$TRANSACTION_STAGING_PATH" ] || return 1
    owned_directory_matches "$STAGING_PATH" "$STAGING_ID" || return 1
    path_absent "$CANONICAL_STAGING_PATH" || return 1
    move_no_clobber_verified directory \
        "$STAGING_PATH" "$CANONICAL_STAGING_PATH" || return 1
    STAGING_PATH="$CANONICAL_STAGING_PATH"
}

remove_owned_staging() {
    $STAGING_OWNED || return 0
    transaction_root_path_is_valid || return 1
    owned_directory_matches "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" ||
        return 1
    [ "$STAGING_ID" = "$LOCK_STAGING_ID" ] || return 1
    staging_directory_has_only_known_entries "$STAGING_PATH" || return 1
    if [ "$STAGING_PATH" = "$CANONICAL_STAGING_PATH" ]; then
        owned_directory_matches "$STAGING_PATH" "$STAGING_ID" || return 1
        path_absent "$TRANSACTION_STAGING_PATH" || return 1
        move_no_clobber_verified directory \
            "$STAGING_PATH" "$TRANSACTION_STAGING_PATH" || return 1
        STAGING_PATH="$TRANSACTION_STAGING_PATH"
    fi
    [ "$STAGING_PATH" = "$TRANSACTION_STAGING_PATH" ] || return 1
    owned_directory_matches "$STAGING_PATH" "$STAGING_ID"
}

lock_directory_has_only_known_files() (
    local root="${1:-$LOCK_PATH}" path entry
    local -a paths
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    shopt -s dotglob nullglob
    paths=("$root"/*)
    for path in "${paths[@]}"; do
        entry=${path##*/}
        case "$entry" in
            journal.json|.journal.next)
                [ -f "$path" ] && [ ! -L "$path" ] ||
                    return 1
                ;;
            *) return 1 ;;
        esac
    done
)

known_lock_file_is_safe() {
    local path="$1"
    path_absent "$path" && return 0
    [ -f "$path" ] && [ ! -L "$path" ]
}

remove_known_lock_file() {
    local path="$1"
    path_absent "$path" && return 0
    known_lock_file_is_safe "$path" || return 1
    "$RM_BIN" -f -- "$path" || return 1
    path_absent "$path"
}

remove_known_regular_file() {
    local path="$1"
    path_absent "$path" && return 0
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    "$RM_BIN" -f -- "$path" || return 1
    path_absent "$path"
}

write_lock_journal() {
    local phase="$1" temporary="$LOCK_PATH/.journal.next"
    case "$phase" in
        fenced|staging|source-move-pending|source-retained|committed) ;;
        *) return 1 ;;
    esac
    $LOCK_OWNED || return 1
    transaction_root_path_is_valid || return 1
    owned_directory_matches "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" ||
        return 1
    owned_directory_matches "$LOCK_PATH" "$LOCK_ID" || return 1
    owned_directory_matches "$STAGING_PATH" "$STAGING_ID" || return 1
    [ "$STAGING_ID" = "$LOCK_STAGING_ID" ] || return 1
    [[ "$TRANSACTION_ROOT_ID" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    [[ "$LOCK_SOURCE_ID" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    [[ "$LOCK_OWNER_PID" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "$LOCK_OWNER_START_TIME" =~ ^[0-9]+$ ]] || return 1
    [[ "$LOCK_BOOT_ID" =~ ^[0-9a-fA-F-]{36}$ ]] || return 1
    path_absent "$temporary" || return 1
    "$JQ_BIN" -cn \
        --arg operation "$OPERATION" --arg workspace "$WORKSPACE" \
        --arg expected_plan "$EXPECT_PLAN" --arg phase "$phase" \
        --argjson owner_pid "$LOCK_OWNER_PID" \
        --arg owner_start_time "$LOCK_OWNER_START_TIME" \
        --arg boot_id "$LOCK_BOOT_ID" \
        --arg transaction_root "$TRANSACTION_ROOT" \
        --arg lock_path "$CANONICAL_LOCK_PATH" \
        --arg staging_path "$CANONICAL_STAGING_PATH" \
        --arg source_path "$WORKSPACE/.beads" \
        --arg rollback_path "$ROLLBACK_PATH" \
        --arg transaction_root_id "$TRANSACTION_ROOT_ID" \
        --arg lock_id "$LOCK_ID" --arg source_id "$LOCK_SOURCE_ID" \
        --arg staging_id "$LOCK_STAGING_ID" '
        {
            schema_version: 1,
            operation: $operation,
            workspace: $workspace,
            expected_plan: $expected_plan,
            phase: $phase,
            owner: {
                pid: $owner_pid,
                start_time: $owner_start_time,
                boot_id: $boot_id
            },
            paths: {
                transaction_root: $transaction_root,
                lock: $lock_path,
                staging: $staging_path,
                source: $source_path,
                rollback: $rollback_path
            },
            identities: {
                transaction_root: $transaction_root_id,
                lock: $lock_id,
                staging: $staging_id,
                source: $source_id
            }
        }
    ' > "$temporary" || return 1
    "$CHMOD_BIN" 600 -- "$temporary" || return 1
    "$MV_BIN" -T -f -- "$temporary" "$LOCK_JOURNAL_PATH" || return 1
    [ -f "$LOCK_JOURNAL_PATH" ] && [ ! -L "$LOCK_JOURNAL_PATH" ] ||
        return 1
    LOCK_PHASE="$phase"
}

load_lock_journal() {
    local journal private_present=0 canonical_present=0 actual
    local transaction_prefix="$WORKSPACE/.beads-v0.62.0-migration.runtime."
    lock_directory_has_only_known_files || return 1
    [ -f "$LOCK_JOURNAL_PATH" ] && [ ! -L "$LOCK_JOURNAL_PATH" ] ||
        return 1
    known_lock_file_is_safe "$LOCK_PATH/.journal.next" || return 1
    journal=$("$JQ_BIN" -cse \
        --arg operation "$OPERATION" --arg workspace "$WORKSPACE" \
        --arg expected_plan "$EXPECT_PLAN" \
        --arg transaction_prefix "$transaction_prefix" \
        --arg lock_path "$CANONICAL_LOCK_PATH" \
        --arg staging_path "$CANONICAL_STAGING_PATH" \
        --arg source_path "$WORKSPACE/.beads" \
        --arg rollback_path "$ROLLBACK_PATH" --arg lock_id "$LOCK_ID" '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and
            keys == [
                "expected_plan", "identities", "operation", "owner",
                "paths", "phase", "schema_version", "workspace"
            ] and
            .schema_version == 1 and .operation == $operation and
            .workspace == $workspace and .expected_plan == $expected_plan and
            (.expected_plan | test("^[0-9a-f]{64}$")) and
            (.phase | IN(
                "fenced", "staging", "source-move-pending",
                "source-retained", "committed"
            )) and
            (.owner | keys) == ["boot_id", "pid", "start_time"] and
            (.owner.pid | type) == "number" and
            (.owner.pid | floor) == .owner.pid and .owner.pid > 0 and
            (.owner.start_time | type) == "string" and
            (.owner.start_time | test("^[0-9]+$")) and
            (.owner.boot_id | type) == "string" and
            (.owner.boot_id | test(
                "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            )) and
            (.paths | keys) == [
                "lock", "rollback", "source", "staging", "transaction_root"
            ] and
            (.paths.transaction_root | type) == "string" and
            (.paths.transaction_root | startswith($transaction_prefix)) and
            .paths.lock == $lock_path and .paths.staging == $staging_path and
            .paths.source == $source_path and .paths.rollback == $rollback_path and
            (.identities | keys) == [
                "lock", "source", "staging", "transaction_root"
            ] and
            (.identities.transaction_root | type) == "string" and
            (.identities.transaction_root | test("^[0-9]+:[0-9]+$")) and
            .identities.lock == $lock_id and
            (.identities.source | type) == "string" and
            (.identities.source | test("^[0-9]+:[0-9]+$")) and
            (.identities.staging | type) == "string" and
            (.identities.staging | test("^[0-9]+:[0-9]+$"))
        )
    ' "$LOCK_JOURNAL_PATH" 2>/dev/null) || return 1
    LOCK_PHASE=$("$JQ_BIN" -er '.phase' <<< "$journal") || return 1
    LOCK_STAGING_ID=$("$JQ_BIN" -er '.identities.staging // ""' \
        <<< "$journal") || return 1
    TRANSACTION_ROOT=$("$JQ_BIN" -er '.paths.transaction_root' \
        <<< "$journal") || return 1
    TRANSACTION_ROOT_ID=$("$JQ_BIN" -er '.identities.transaction_root' \
        <<< "$journal") || return 1
    TRANSACTION_LOCK_PATH="$TRANSACTION_ROOT/lock"
    TRANSACTION_STAGING_PATH="$TRANSACTION_ROOT/staging"
    LOCK_SOURCE_ID=$("$JQ_BIN" -er '.identities.source' <<< "$journal") ||
        return 1
    LOCK_OWNER_PID=$("$JQ_BIN" -er '.owner.pid | tostring' <<< "$journal") ||
        return 1
    LOCK_OWNER_START_TIME=$("$JQ_BIN" -er '.owner.start_time' \
        <<< "$journal") || return 1
    LOCK_BOOT_ID=$("$JQ_BIN" -er '.owner.boot_id' <<< "$journal") || return 1
    transaction_root_path_is_valid || return 1
    owned_directory_matches "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" ||
        return 1
    path_absent "$TRANSACTION_LOCK_PATH" || return 1
    if [ -e "$TRANSACTION_STAGING_PATH" ] ||
        [ -L "$TRANSACTION_STAGING_PATH" ]; then
        private_present=1
    fi
    if [ -e "$CANONICAL_STAGING_PATH" ] ||
        [ -L "$CANONICAL_STAGING_PATH" ]; then
        canonical_present=1
    fi
    [ "$((private_present + canonical_present))" -eq 1 ] || return 1
    if [ "$private_present" -eq 1 ]; then
        STAGING_PATH="$TRANSACTION_STAGING_PATH"
    else
        STAGING_PATH="$CANONICAL_STAGING_PATH"
    fi
    actual=$(directory_identity "$STAGING_PATH") || return 1
    [ "$actual" = "$LOCK_STAGING_ID" ] || return 1
    STAGING_ID="$LOCK_STAGING_ID"
}

release_operation_lock() {
    local retired=false

    $LOCK_OWNED || return 0
    $STAGING_OWNED || return 1
    remove_owned_staging || return 1
    transaction_root_path_is_valid || return 1
    owned_directory_matches "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" ||
        return 1
    owned_directory_matches "$LOCK_PATH" "$LOCK_ID" || return 1
    lock_directory_has_only_known_files || return 1
    known_lock_file_is_safe "$LOCK_PATH/.journal.next" || return 1

    if [ "$LOCK_PATH" = "$CANONICAL_LOCK_PATH" ]; then
        [ -f "$LOCK_JOURNAL_PATH" ] && [ ! -L "$LOCK_JOURNAL_PATH" ] ||
            return 1
        path_absent "$TRANSACTION_LOCK_PATH" || return 1
        start_transaction_guardian || return 1
        move_no_clobber_verified directory \
            "$LOCK_PATH" "$TRANSACTION_LOCK_PATH" || return 1
        LOCK_PATH="$TRANSACTION_LOCK_PATH"
        LOCK_JOURNAL_PATH="$LOCK_PATH/journal.json"
        LOCK_PUBLISHED=false
        retired=true
    elif [ "$LOCK_PATH" = "$TRANSACTION_LOCK_PATH" ]; then
        owned_directory_matches "$LOCK_PATH" "$LOCK_ID" || return 1
        known_lock_file_is_safe "$LOCK_JOURNAL_PATH" || return 1
    else
        return 1
    fi

    path_absent "$CANONICAL_STAGING_PATH" &&
        path_absent "$CANONICAL_LOCK_PATH" || return 1
    if $retired; then
        test_phase after_operation_fence_retired_before_private_cleanup ||
            return 1
    fi
    remove_authenticated_directory \
        "$TRANSACTION_ROOT" "$TRANSACTION_ROOT_ID" transaction \
        after_private_children_deleted_before_root_rmdir || return 1
    stop_transaction_guardian || return 1
    clear_operation_state
}

authenticate_recovery_receipt() {
    local receipt="$1" receipt_json plan_without_digest computed_digest
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
    receipt_json=$("$JQ_BIN" -cse \
        --arg operation "$OPERATION" --arg schema "$PLAN_SCHEMA" \
        --arg workspace "$WORKSPACE" --arg expected "$EXPECT_PLAN" \
        --arg semantic_scope "$SEMANTIC_SCOPE" \
        --arg rollback "$ROLLBACK_PATH" '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and
            keys == [
                "operation", "plan", "plan_digest", "rollback",
                "schema_version", "semantic_scope",
                "semantic_scope_verified", "semantic_sha256", "state",
                "target_backend"
            ] and
            .schema_version == 1 and .operation == $operation and
            .state == "committed" and .plan_digest == $expected and
            .semantic_scope == $semantic_scope and
            .semantic_scope_verified == true and
            (.semantic_sha256 | type) == "string" and
            (.semantic_sha256 | test("^[0-9a-f]{64}$")) and
            .target_backend == "dolt-embedded" and
            (.plan | type) == "object" and .plan.schema == $schema and
            .plan.digest == $expected and .plan.workspace == $workspace and
            .plan.semantic_scope == $semantic_scope and
            .plan.target_backend == "dolt-embedded" and
            (.plan.source_observation.content_sha256 | type) == "string" and
            (.plan.source_observation.content_sha256 |
                test("^[0-9a-f]{64}$")) and
            .plan.source_observation.content_digest_scope ==
                "complete_source_tree" and
            .rollback.path == $rollback and .rollback.policy == "retain" and
            .rollback.verified == true and
            .rollback.tree_sha256 ==
                .plan.source_observation.content_sha256
        )
    ' "$receipt" 2>/dev/null) || return 1
    plan_without_digest=$("$JQ_BIN" -cS '.plan | del(.digest)' \
        <<< "$receipt_json" 2>/dev/null) || return 1
    computed_digest=$(printf '%s' "$plan_without_digest" | "$SHA256SUM_BIN" |
        { read -r digest _; printf '%s\n' "$digest"; }) || return 1
    [ "$computed_digest" = "$EXPECT_PLAN" ] || return 1
    AUTHENTICATED_SOURCE_CONTENT=$("$JQ_BIN" -er \
        '.plan.source_observation.content_sha256' <<< "$receipt_json") ||
        return 1
}

journal_owner_is_alive() {
    local current_boot current_start current_state
    current_boot=$("$CAT_BIN" -- "$BOOT_ID_PATH" 2>/dev/null) || return 1
    [ "$current_boot" = "$LOCK_BOOT_ID" ] || return 1
    kill -0 "$LOCK_OWNER_PID" 2>/dev/null || return 1
    current_state=$(process_state "$LOCK_OWNER_PID") || return 1
    [ "$current_state" != Z ] || return 1
    current_start=$(source_server_start_time "$LOCK_OWNER_PID") || return 1
    [ "$current_start" = "$LOCK_OWNER_START_TIME" ]
}

reset_stale_lock_state() {
    clear_operation_state
    AUTHENTICATED_SOURCE_CONTENT=
}

finalize_stale_operation() {
    LOCK_OWNED=true
    STAGING_OWNED=true
    LOCK_PUBLISHED=true
    STAGING_ID="$LOCK_STAGING_ID"
    if remove_owned_staging && release_operation_lock; then
        AUTHENTICATED_SOURCE_CONTENT=
        return 0
    fi

    # The canonical fence, or the guardian after a completed retirement,
    # remains the recovery authority. Do not let EXIT retry a failed cleanup.
    LOCK_OWNED=false
    STAGING_OWNED=false
    return 1
}

recover_stale_operation() {
    local active_id rollback_id restored_id rollback_digest
    local active_receipt="$WORKSPACE/.beads/v062-migration-receipt.json"
    local staged_root="$STAGING_PATH/target"
    local staged_receipt="$staged_root/.beads/v062-migration-receipt.json"

    [ -d "$LOCK_PATH" ] && [ ! -L "$LOCK_PATH" ] || return 1
    LOCK_ID=$(directory_identity "$LOCK_PATH") || return 1
    load_lock_journal || return 1
    journal_owner_is_alive && return 1

    staged_root="$STAGING_PATH/target"
    staged_receipt="$staged_root/.beads/v062-migration-receipt.json"

    active_id=$(directory_identity "$WORKSPACE/.beads" 2>/dev/null) ||
        active_id=
    rollback_id=$(directory_identity "$ROLLBACK_PATH" 2>/dev/null) ||
        rollback_id=

    # A receipt-backed active target is authoritative. It can contain ordinary
    # writes made after publication, so recovery removes only transaction
    # artifacts and leaves final verification to the normal no-op path.
    if [ -n "$active_id" ] &&
        { [ -e "$active_receipt" ] || [ -L "$active_receipt" ] ||
          looks_like_completed_target; }; then
        [ -n "$rollback_id" ] || return 1
        [ -d "$WORKSPACE/.beads" ] && [ ! -L "$WORKSPACE/.beads" ] ||
            return 1
        authenticate_recovery_receipt "$active_receipt" || return 1
        rollback_digest=$(content_fingerprint "$ROLLBACK_PATH") || return 1
        [ "$rollback_digest" = "$AUTHENTICATED_SOURCE_CONTENT" ] || return 1
        case "$LOCK_PHASE" in
            fenced|staging)
                [ "$active_id" = "$LOCK_SOURCE_ID" ] || return 1
                ;;
            source-retained|committed)
                [ "$rollback_id" = "$LOCK_SOURCE_ID" ] || return 1
                ;;
            *) return 1 ;;
        esac
        finalize_stale_operation
        return
    fi

    # Before target publication, the exact original inode may be sitting at
    # the retained rollback path. Authenticate the staged receipt before its
    # content digest is allowed to authorize restoration.
    if [ -z "$active_id" ] && path_absent "$WORKSPACE/.beads" &&
        [ -n "$rollback_id" ]; then
        [ "$rollback_id" = "$LOCK_SOURCE_ID" ] || return 1
        [ -n "$LOCK_STAGING_ID" ] || return 1
        [ -d "$staged_root" ] && [ ! -L "$staged_root" ] &&
            [ -d "$staged_root/.beads" ] &&
            [ ! -L "$staged_root/.beads" ] || return 1
        authenticate_recovery_receipt "$staged_receipt" || return 1
        rollback_digest=$(content_fingerprint "$ROLLBACK_PATH") || return 1
        [ "$rollback_digest" = "$AUTHENTICATED_SOURCE_CONTENT" ] || return 1
        case "$LOCK_PHASE" in
            source-move-pending|source-retained) ;;
            *) return 1 ;;
        esac
        move_no_clobber_verified directory \
            "$ROLLBACK_PATH" "$WORKSPACE/.beads" || return 1
        restored_id=$(directory_identity "$WORKSPACE/.beads") || return 1
        [ "$restored_id" = "$LOCK_SOURCE_ID" ] || return 1
        finalize_stale_operation
        return
    fi

    # If the original inode never left (or was already restored), deleting an
    # inode-matched staging tree and the authenticated journal is effect-free.
    if [ "$active_id" = "$LOCK_SOURCE_ID" ] &&
        path_absent "$ROLLBACK_PATH" && [ "$LOCK_PHASE" != committed ]; then
        finalize_stale_operation
        return
    fi

    return 1
}

recover_cutover() {
    local active_id rollback_id
    $TRANSACTION_COMMITTED && return 0

    if $SOURCE_MOVE_ATTEMPTED; then
        [ -n "$SOURCE_ORIGINAL_ID" ] || return 1
        active_id=$(directory_identity "$WORKSPACE/.beads" 2>/dev/null) ||
            active_id=
        if [ "$active_id" = "$SOURCE_ORIGINAL_ID" ]; then
            SOURCE_MOVE_ATTEMPTED=false
            SOURCE_RENAMED=false
            SOURCE_ORIGINAL_ID=
            return 0
        fi
        [ -z "$active_id" ] &&
            [ ! -e "$WORKSPACE/.beads" ] &&
            [ ! -L "$WORKSPACE/.beads" ] || return 1
        rollback_id=$(directory_identity "$ROLLBACK_PATH" 2>/dev/null) ||
            rollback_id=
        [ "$rollback_id" = "$SOURCE_ORIGINAL_ID" ] || return 1
        move_no_clobber_verified directory \
            "$ROLLBACK_PATH" "$WORKSPACE/.beads" ||
            return 1
        active_id=$(directory_identity "$WORKSPACE/.beads") || return 1
        [ "$active_id" = "$SOURCE_ORIGINAL_ID" ] || return 1
        SOURCE_MOVE_ATTEMPTED=false
        SOURCE_RENAMED=false
        SOURCE_ORIGINAL_ID=
    fi
}

cleanup_all() {
    if ! $TRANSACTION_COMMITTED; then
        recover_cutover 2>/dev/null || true
    fi
    remove_owned_staging 2>/dev/null || true
    release_operation_lock 2>/dev/null || true
    cleanup_owned_paths
    close_workspace_lock 2>/dev/null || true
    cleanup_runtime_scratch 2>/dev/null || true
}

transaction_failure() {
    local code="$1" retryable="$2" message="$3"
    if $TRANSACTION_COMMITTED; then
        if ! remove_owned_staging || ! release_operation_lock; then
            finish_error 1 failed cleanup_failed false workspace_migrated \
                "migration committed but its transaction artifacts could not be removed"
        fi
        finish_error 1 failed "$code" "$retryable" workspace_migrated \
            "$message"
    fi
    if ! recover_cutover || ! remove_owned_staging || ! release_operation_lock; then
        finish_error 1 failed recovery_failed false workspace_requires_recovery \
            "migration failed and the original workspace could not be restored"
    fi
    finish_error 1 failed "$code" "$retryable" none "$message"
}

injected_failure() {
    local failpoint="$1" effect=none
    if $TRANSACTION_COMMITTED; then
        effect=workspace_migrated
        if ! remove_owned_staging || ! release_operation_lock; then
            finish_error 1 failed cleanup_failed false workspace_migrated \
                "migration committed but injected-failure cleanup did not complete"
        fi
    elif ! recover_cutover || ! remove_owned_staging || ! release_operation_lock; then
        finish_error 1 failed recovery_failed false workspace_requires_recovery \
            "injected failure recovery could not restore the original workspace"
    fi
    printf '%s: injected failure at %s\n' "$OPERATION" "$failpoint" >&2
    if $JSON_OUTPUT; then
        "$JQ_BIN" -cn --arg operation "$OPERATION" --arg failpoint "$failpoint" \
            --arg effect "$effect" '
            {
                schema_version: 1, operation: $operation, mode: "apply",
                status: "failed", retryable: true, effect: $effect,
                code: "injected_failure",
                verification: {failpoint: $failpoint, phase_reached: true}
            }
        '
    fi
    exit 1
}

completion_receipt_path() {
    printf '%s\n' "$WORKSPACE/.beads/v062-migration-receipt.json"
}

looks_like_completed_target() {
    local metadata="$WORKSPACE/.beads/metadata.json"
    [ -f "$metadata" ] && [ ! -L "$metadata" ] || return 1
    "$JQ_BIN" -e '.backend == "dolt" and .dolt_mode == "embedded"' \
        "$metadata" >/dev/null 2>&1
}

emit_verified_no_op() {
    local receipt_path receipt_json rollback_digest target_semantics
    local target_semantic_digest plan_without_digest computed_digest
    local baseline_ids baseline_digest
    receipt_path=$(completion_receipt_path)
    [ -f "$receipt_path" ] && [ ! -L "$receipt_path" ] ||
        refuse completion_state_invalid false \
            "the completed migration receipt is missing or unsafe"
    receipt_json=$("$JQ_BIN" -cse \
        --arg operation "$OPERATION" --arg schema "$PLAN_SCHEMA" \
        --arg workspace "$WORKSPACE" --arg expected "$EXPECT_PLAN" \
        --arg semantic_scope "$SEMANTIC_SCOPE" \
        --arg source_bd "$SOURCE_BD" --arg source_bd_sha "$SOURCE_BD_SHA256" \
        --arg source_dolt "$SOURCE_DOLT" \
        --arg source_dolt_sha "$SOURCE_DOLT_SHA256" \
        --arg target_bd "$TARGET_BD" --arg target_sha "$TARGET_BD_SHA256" \
        --arg rollback "$ROLLBACK_PATH" '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and .schema_version == 1 and
            .operation == $operation and .state == "committed" and
            .plan_digest == $expected and
            .semantic_scope == $semantic_scope and
            .semantic_scope_verified == true and
            (.semantic_sha256 | type) == "string" and
            (.semantic_sha256 | test("^[0-9a-f]{64}$")) and
            .target_backend == "dolt-embedded" and
            .plan.schema == $schema and .plan.digest == $expected and
            .plan.workspace == $workspace and
            .plan.semantic_scope == $semantic_scope and
            .plan.target_backend == "dolt-embedded" and
            (.plan.semantic_baseline | type) == "object" and
            (.plan.semantic_baseline | keys) == ["issue_ids", "sha256"] and
            (.plan.semantic_baseline.issue_ids | type) == "array" and
            (.plan.semantic_baseline.issue_ids | length) == 5 and
            all(.plan.semantic_baseline.issue_ids[];
                type == "string" and
                test("^[A-Za-z0-9._-]{1,128}$")) and
            .plan.semantic_baseline.issue_ids ==
                (.plan.semantic_baseline.issue_ids | sort | unique) and
            (.plan.semantic_baseline.sha256 | type) == "string" and
            (.plan.semantic_baseline.sha256 | test("^[0-9a-f]{64}$")) and
            .semantic_sha256 == .plan.semantic_baseline.sha256 and
            (.plan.source_observation.content_sha256 | type) == "string" and
            (.plan.source_observation.content_sha256 |
                test("^[0-9a-f]{64}$")) and
            .plan.source_observation.content_digest_scope ==
                "complete_source_tree" and
            (.plan.source_identity | type) == "object" and
            (.plan.source_identity | keys) == [
                "database", "issue_prefix", "project_id"
            ] and
            (.plan.source_identity.issue_prefix | type) == "string" and
            (.plan.source_identity.issue_prefix |
                test("^[A-Za-z][A-Za-z0-9_-]{0,63}$")) and
            (.plan.source_identity.issue_prefix | endswith("-") | not) and
            (.plan.source_identity.database | type) == "string" and
            (.plan.source_identity.database |
                test("^[A-Za-z_][A-Za-z0-9_]{0,63}$")) and
            (.plan.source_identity.project_id | type) == "string" and
            (.plan.source_identity.project_id | test(
                "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            )) and
            .plan.source_binary.path == $source_bd and
            .plan.source_binary.sha256 == $source_bd_sha and
            .plan.source_runtime.path == $source_dolt and
            .plan.source_runtime.sha256 == $source_dolt_sha and
            .plan.target_binary.path == $target_bd and
            .plan.target_binary.sha256 == $target_sha and
            .rollback.path == $rollback and
            .rollback.policy == "retain" and
            .rollback.verified == true and
            (.rollback.tree_sha256 | type) == "string" and
            (.rollback.tree_sha256 | test("^[0-9a-f]{64}$")) and
            .rollback.tree_sha256 ==
                .plan.source_observation.content_sha256
        )
    ' "$receipt_path" 2>/dev/null) ||
        refuse completion_state_invalid false \
            "the completed migration receipt does not match this invocation"
    plan_without_digest=$("$JQ_BIN" -cS '.plan | del(.digest)' \
        <<< "$receipt_json" 2>/dev/null) ||
        refuse completion_state_invalid false \
            "the completed migration plan cannot be authenticated"
    computed_digest=$(printf '%s' "$plan_without_digest" | "$SHA256SUM_BIN" |
        { read -r digest _; printf '%s\n' "$digest"; }) ||
        refuse completion_state_invalid false \
            "the completed migration plan cannot be authenticated"
    [ "$computed_digest" = "$EXPECT_PLAN" ] ||
        refuse completion_state_invalid false \
            "the completed migration plan digest is invalid"
    baseline_ids=$("$JQ_BIN" -cer '.plan.semantic_baseline.issue_ids' \
        <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed semantic baseline cannot be recovered"
    baseline_digest=$("$JQ_BIN" -er '.plan.semantic_baseline.sha256' \
        <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed semantic baseline cannot be recovered"
    SOURCE_ISSUE_PREFIX=$("$JQ_BIN" -er \
        '.plan.source_identity.issue_prefix' <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed source prefix cannot be recovered"
    SOURCE_DATABASE=$("$JQ_BIN" -er \
        '.plan.source_identity.database' <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed source database cannot be recovered"
    SOURCE_PROJECT_ID=$("$JQ_BIN" -er \
        '.plan.source_identity.project_id' <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed source project identity cannot be recovered"
    [ -d "$ROLLBACK_PATH" ] && [ ! -L "$ROLLBACK_PATH" ] ||
        refuse completion_state_invalid false \
            "the retained rollback is missing or unsafe"
    rollback_digest=$(content_fingerprint "$ROLLBACK_PATH") ||
        refuse completion_state_invalid false \
            "the retained rollback cannot be verified"
    [ "$rollback_digest" = \
        "$("$JQ_BIN" -r '.rollback.tree_sha256' <<< "$receipt_json")" ] ||
        refuse completion_state_invalid false \
            "the retained rollback no longer matches its receipt"
    verify_embedded_layout "$WORKSPACE" ||
        refuse completion_state_invalid false \
            "the active target is not the committed embedded layout"
    verify_target_identity "$WORKSPACE" ||
        refuse completion_state_invalid false \
            "the active target no longer has the committed source identity"
    target_semantics="$CLEAN_HOME/tmp/no-op-target.jsonl"
    collect_target_semantics \
        "$WORKSPACE" "$target_semantics" "$baseline_ids" ||
        refuse completion_state_invalid false \
            "the active target no longer has the committed semantic corpus"
    target_semantic_digest=$(semantic_sha256 "$target_semantics") ||
        refuse completion_state_invalid false \
            "the active target semantic digest cannot be computed"
    [ "$target_semantic_digest" = "$baseline_digest" ] ||
        refuse completion_state_invalid false \
            "the active target no longer matches the committed semantic digest"
    verify_embedded_layout "$WORKSPACE" ||
        refuse completion_state_invalid false \
            "the active target routing or layout changed during verification"

    PLAN_JSON=$("$JQ_BIN" -c '.plan' <<< "$receipt_json") ||
        refuse completion_state_invalid false \
            "the completed plan cannot be recovered from its receipt"
    PLAN_DIGEST="$EXPECT_PLAN"
    if ! remove_owned_staging || ! release_operation_lock; then
        finish_error 1 failed cleanup_failed false none \
            "the verified no-op operation fence could not be released"
    fi
    if $JSON_OUTPUT; then
        "$JQ_BIN" -cn \
            --arg operation "$OPERATION" --argjson receipt "$receipt_json" '
            {
                schema_version: 1, operation: $operation, mode: "apply",
                status: "succeeded", retryable: false, effect: "none",
                no_op: true, plan: $receipt.plan,
                target: {
                    version: $receipt.plan.target_binary.version,
                    backend: "dolt-embedded", embedded_capable: true
                },
                rollback: $receipt.rollback,
                verification: {
                    semantic_scope: $receipt.semantic_scope,
                    semantic_scope_verified: true,
                    issue_count: 5,
                    target_backend_verified: true,
                    separate_process_reopen: true
                }
            }
        '
    else
        printf 'Migration already committed and verified: %s\n' "$PLAN_DIGEST"
    fi
    exit 0
}

write_completion_receipt() {
    local target_root="$1" source_tree="$2" semantic_digest="$3"
    local receipt="$target_root/.beads/v062-migration-receipt.json"
    local temporary="$target_root/.beads/.v062-migration-receipt.tmp"
    local baseline_digest
    baseline_digest=$("$JQ_BIN" -er \
        '.semantic_baseline.sha256 | select(type == "string")' \
        <<< "$PLAN_JSON") || return 1
    [ "$semantic_digest" = "$baseline_digest" ] || return 1
    [ ! -e "$receipt" ] && [ ! -L "$receipt" ] || return 1
    "$JQ_BIN" -cn \
        --arg operation "$OPERATION" --arg semantic_scope "$SEMANTIC_SCOPE" \
        --arg plan_digest "$PLAN_DIGEST" --argjson plan "$PLAN_JSON" \
        --arg semantic_digest "$semantic_digest" \
        --arg rollback "$ROLLBACK_PATH" --arg source_tree "$source_tree" '
        {
            schema_version: 1,
            operation: $operation,
            state: "committed",
            plan_digest: $plan_digest,
            plan: $plan,
            semantic_scope: $semantic_scope,
            semantic_scope_verified: true,
            semantic_sha256: $semantic_digest,
            target_backend: "dolt-embedded",
            rollback: {
                path: $rollback,
                policy: "retain",
                verified: true,
                tree_sha256: $source_tree
            }
        }
    ' > "$temporary" || return 1
    "$CHMOD_BIN" 600 -- "$temporary" || return 1
    test_phase before_receipt_publish || return 1
    move_no_clobber_verified file "$temporary" "$receipt"
}

initialize_staged_target() {
    local target_root="$1" source_semantics="$2" target_semantics="$3"
    "$MKDIR_BIN" -m 700 -- "$target_root" || return 1
    ensure_clean_home || return 1
    clean_at "$target_root" "$GIT_BIN" init --quiet || return 1
    clean_at "$target_root" "$GIT_BIN" \
        config core.hooksPath .git/hooks || return 1
    target_at "$target_root" "$TARGET_BD_EXEC" init \
        --quiet --non-interactive --backend=dolt \
        --prefix "$SOURCE_ISSUE_PREFIX" --database "$SOURCE_DATABASE" \
        --migration-v062-project-id "$SOURCE_PROJECT_ID" \
        --migration-v062-repository-root "$WORKSPACE" \
        --role maintainer --skip-agents --skip-hooks \
        >/dev/null 2>&1 || return 1
    verify_embedded_layout "$target_root" || return 1
    verify_target_identity "$target_root" || return 1
    target_at "$target_root" "$TARGET_BD_EXEC" import \
        -i "$source_semantics" --json >/dev/null 2>&1 || return 1
    collect_target_semantics "$target_root" "$target_semantics" || return 1
    semantics_match "$source_semantics" "$target_semantics" || return 1
    verify_embedded_layout "$target_root"
}

emit_apply_success() {
    local source_tree="$1"
    if $JSON_OUTPUT; then
        "$JQ_BIN" -cn \
            --arg operation "$OPERATION" \
            --argjson inspection "$inspection_json" \
            --argjson plan "$PLAN_JSON" \
            --arg rollback "$ROLLBACK_PATH" \
            --arg semantic_scope "$SEMANTIC_SCOPE" \
            --arg source_tree "$source_tree" '
            {
                schema_version: 1, operation: $operation, mode: "apply",
                status: "succeeded", retryable: false,
                effect: "workspace_migrated",
                source: $inspection.source,
                target: $inspection.target,
                plan: $plan,
                rollback: {
                    path: $rollback, policy: "retain",
                    verified: true, tree_sha256: $source_tree
                },
                verification: {
                    semantic_scope: $semantic_scope,
                    semantic_scope_verified: true,
                    issue_count: 5,
                    target_backend_verified: true,
                    separate_process_reopen: true
                }
            }
        '
    else
        printf 'Migrated v0.62.0 workspace; rollback retained at %s\n' \
            "$ROLLBACK_PATH"
    fi
}

perform_apply() {
    local source_semantics="$1" target_root target_semantics reopen_semantics
    local planned_tree planned_content current_admission source_tree current_content
    local rollback_tree semantic_digest failpoint

    [ ! -e "$ROLLBACK_PATH" ] && [ ! -L "$ROLLBACK_PATH" ] ||
        refuse rollback_collision false \
            "the retained rollback destination already exists"
    $LOCK_OWNED && $STAGING_OWNED && $LOCK_PUBLISHED &&
        [ "$LOCK_PHASE" = staging ] &&
        [ "$STAGING_PATH" = "$CANONICAL_STAGING_PATH" ] &&
        owned_directory_matches "$STAGING_PATH" "$STAGING_ID" ||
        transaction_failure staging_unavailable true \
            "the published staging transaction could not be authenticated"

    target_root="$STAGING_PATH/target"
    target_semantics="$STAGING_PATH/target-semantics.jsonl"
    reopen_semantics="$STAGING_PATH/reopen-semantics.jsonl"
    planned_tree=$("$JQ_BIN" -er '.source_observation.tree_sha256' \
        <<< "$PLAN_JSON") ||
        transaction_failure plan_invalid false \
            "the authorized source observation is invalid"
    planned_content=$("$JQ_BIN" -er \
        '.source_observation.content_sha256 |
            select(type == "string" and test("^[0-9a-f]{64}$"))' \
        <<< "$PLAN_JSON") ||
        transaction_failure plan_invalid false \
            "the authorized source content identity is invalid"

    [ "$QUALIFIED_SOURCE_TREE" = "$planned_tree" ] || {
        remove_owned_staging ||
            transaction_failure cleanup_failed false \
                "the changed-source staging tree could not be removed"
        refuse plan_mismatch false \
            "the source changed while the authorized plan was being applied"
    }
    source_tree=$(content_fingerprint "$WORKSPACE/.beads") ||
        transaction_failure source_unverifiable true \
            "the active source cannot be reverified"
    [ "$source_tree" = "$planned_content" ] || {
        remove_owned_staging ||
            transaction_failure cleanup_failed false \
                "the changed-source staging tree could not be removed"
        refuse plan_mismatch false \
            "the source content changed while the authorized plan was being applied"
    }

    initialize_staged_target \
        "$target_root" "$source_semantics" "$target_semantics" ||
        transaction_failure target_verification_failed false \
            "the staged embedded target could not be initialized and verified"
    semantic_digest=$(semantic_sha256 "$source_semantics") ||
        transaction_failure target_verification_failed false \
            "the verified source semantic digest could not be computed"
    write_completion_receipt \
        "$target_root" "$source_tree" "$semantic_digest" ||
        transaction_failure receipt_write_failed false \
            "the completion receipt could not be staged"

    current_admission=$(inspect_admission_tree "$WORKSPACE") ||
        transaction_failure source_unverifiable true \
            "the active source admission state cannot be reinspected"
    [ "$current_admission" = "$planned_tree" ] || {
        remove_owned_staging ||
            transaction_failure cleanup_failed false \
                "the changed-source staging tree could not be removed"
        refuse plan_mismatch false \
            "the source admission state changed before cutover"
    }
    current_content=$(content_fingerprint "$WORKSPACE/.beads") ||
        transaction_failure source_unverifiable true \
            "the active source cannot be verified before cutover"
    [ "$current_content" = "$source_tree" ] || {
        remove_owned_staging ||
            transaction_failure cleanup_failed false \
                "the changed-source staging tree could not be removed"
        refuse plan_mismatch false \
            "the source changed before cutover"
    }

    test_phase before_source_rename ||
        transaction_failure test_phase_failed true \
            "the test phase handshake did not complete"
    failpoint=${BD_V062_TEST_FAILPOINT:-}
    [ "$failpoint" != before_source_rename ] ||
        injected_failure before_source_rename

    SOURCE_ORIGINAL_ID=$(directory_identity "$WORKSPACE/.beads") ||
        transaction_failure source_rename_failed true \
            "the source identity could not be captured before retention"
    [ "$SOURCE_ORIGINAL_ID" = "$LOCK_SOURCE_ID" ] ||
        transaction_failure source_rename_failed true \
            "the source directory identity changed before retention"
    write_lock_journal source-move-pending ||
        transaction_failure journal_write_failed false \
            "the pending source move could not be journaled"
    SOURCE_MOVE_ATTEMPTED=true
    move_no_clobber_verified directory \
        "$WORKSPACE/.beads" "$ROLLBACK_PATH" ||
        transaction_failure source_rename_failed true \
            "the source could not be atomically retained as rollback"
    SOURCE_RENAMED=true
    write_lock_journal source-retained ||
        transaction_failure journal_write_failed false \
            "the retained source state could not be journaled"
    rollback_tree=$(content_fingerprint "$ROLLBACK_PATH") ||
        transaction_failure rollback_verification_failed false \
            "the retained rollback could not be verified"
    [ "$rollback_tree" = "$source_tree" ] ||
        transaction_failure rollback_verification_failed false \
            "the retained rollback differs from the authorized source"

    test_phase after_source_rename_before_target_publish ||
        transaction_failure test_phase_failed true \
            "the post-rename test phase handshake did not complete"
    [ "$failpoint" != after_source_rename_before_target_publish ] ||
        injected_failure after_source_rename_before_target_publish

    move_no_clobber_verified directory \
        "$target_root/.beads" "$WORKSPACE/.beads" ||
        transaction_failure target_publish_failed true \
            "the verified target could not be atomically published"
    # Atomic publication is the commit point. From here onward the target may
    # accept ordinary bd writes, so no failure path may restore the old source
    # over it or delete the published target.
    TRANSACTION_COMMITTED=true
    SOURCE_MOVE_ATTEMPTED=false
    SOURCE_RENAMED=false
    SOURCE_ORIGINAL_ID=
    write_lock_journal committed ||
        transaction_failure journal_write_failed false \
            "the committed target state could not be journaled"
    verify_embedded_layout "$WORKSPACE" ||
        transaction_failure target_reopen_failed false \
            "the published target layout could not be reopened"
    verify_target_identity "$WORKSPACE" ||
        transaction_failure target_reopen_failed false \
            "the published target failed source identity reopen"
    collect_target_semantics "$WORKSPACE" "$reopen_semantics" &&
        semantics_match "$source_semantics" "$reopen_semantics" ||
        transaction_failure target_reopen_failed false \
            "the published target failed separate-process semantic reopen"
    verify_embedded_layout "$WORKSPACE" ||
        transaction_failure target_reopen_failed false \
            "the published target routing or layout changed during reopen"

    test_phase after_target_publish ||
        transaction_failure test_phase_failed true \
            "the post-publish test phase handshake did not complete"
    [ "$failpoint" != after_target_publish ] ||
        injected_failure after_target_publish

    remove_owned_staging ||
        finish_error 1 failed cleanup_failed false workspace_migrated \
            "migration committed but its owned staging tree remains"
    release_operation_lock ||
        finish_error 1 failed cleanup_failed false workspace_migrated \
            "migration committed but its operation fence remains"
    emit_apply_success "$source_tree"
    exit 0
}

qualify_source_semantics() {
    local destination="$1"
    local expected_tree="$2" expected_database="$3" expected_project_id="$4"
    local metadata port database raw shows enriched ids encoded_id id
    local qualified_source qualified_database qualified_project_id prefix_json
    local db_project_json db_project_id project_query
    local show_json show_record attempt ready=false

    QUALIFICATION_CODE=source_semantic_scope_unverifiable
    QUALIFIED_SOURCE_TREE=
    ensure_clean_home || return 1
    SOURCE_SCRATCH="$RUNTIME_SCRATCH/source"
    path_absent "$SOURCE_SCRATCH" || return 1
    "$MKDIR_BIN" -m 700 -- "$SOURCE_SCRATCH" || return 1
    if ! clean_at "$SOURCE_SCRATCH" "$GIT_BIN" init --quiet ||
        ! clean_at "$SOURCE_SCRATCH" "$GIT_BIN" \
            config core.hooksPath .git/hooks ||
        ! "$CP_BIN" -a -- "$WORKSPACE/.beads" "$SOURCE_SCRATCH/.beads"; then
        cleanup_owned_paths
        return 1
    fi
    qualified_source=$(inspect_admission_source "$SOURCE_SCRATCH") || {
        cleanup_owned_paths
        return 1
    }
    QUALIFIED_SOURCE_TREE=$("$JQ_BIN" -er '.tree_sha256' \
        <<< "$qualified_source" 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    qualified_database=$("$JQ_BIN" -er '.database' \
        <<< "$qualified_source" 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    qualified_project_id=$("$JQ_BIN" -er '.project_id' \
        <<< "$qualified_source" 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    if [ "$QUALIFIED_SOURCE_TREE" != "$expected_tree" ] ||
        [ "$qualified_database" != "$expected_database" ] ||
        [ "$qualified_project_id" != "$expected_project_id" ]; then
        QUALIFICATION_CODE=source_changed
        cleanup_owned_paths
        return 1
    fi

    metadata="$SOURCE_SCRATCH/.beads/metadata.json"
    port=$("$JQ_BIN" -er '
        (.dolt_server_port // 3307) |
        select(type == "number" and floor == . and . >= 1 and . <= 65535)
    ' "$metadata" 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    SOURCE_SERVER_PORT="$port"
    database=$("$JQ_BIN" -er '
        (.dolt_database // .database) |
        select(type == "string" and test("^[A-Za-z_][A-Za-z0-9_-]{0,63}$"))
    ' "$metadata" 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    [ "$database" = "$qualified_database" ] || {
        cleanup_owned_paths
        return 1
    }
    SOURCE_SERVER_LOG="$SOURCE_SCRATCH/source-dolt.log"
    (
        close_workspace_lock_in_child
        cd -P -- "$SOURCE_SCRATCH/.beads/dolt" || exit 1
        exec "$ENV_BIN" -i \
            PATH=/usr/bin:/bin HOME="$CLEAN_HOME" TMPDIR="$CLEAN_HOME/tmp" \
            XDG_CONFIG_HOME="$CLEAN_HOME/config" \
            XDG_CACHE_HOME="$CLEAN_HOME/cache" \
            XDG_DATA_HOME="$CLEAN_HOME/data" XDG_STATE_HOME="$CLEAN_HOME/state" \
            NO_COLOR=1 LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC TERM=dumb \
            "$SOURCE_DOLT_EXEC" sql-server --host 127.0.0.1 --port "$port"
    ) >> "$SOURCE_SERVER_LOG" 2>&1 < /dev/null &
    SOURCE_SERVER_PID=$!
    SOURCE_SERVER_START_TIME=$(source_server_start_time "$SOURCE_SERVER_PID") || {
        wait "$SOURCE_SERVER_PID" 2>/dev/null || true
        SOURCE_SERVER_PID=
        cleanup_owned_paths
        return 1
    }
    for ((attempt = 0; attempt < 100; attempt++)); do
        if clean_at "$SOURCE_SCRATCH" "$SOURCE_DOLT_EXEC" \
            --host 127.0.0.1 --port "$port" --no-tls \
            --use-db "$database" sql -r json -q 'SELECT 1' \
            >/dev/null 2>&1 && owned_source_server_alive; then
            ready=true
            break
        fi
        owned_source_server_alive || break
        "$SLEEP_BIN" 0.05
    done
    if ! $ready; then
        cleanup_owned_paths
        return 1
    fi

    project_query="SELECT value AS project_id FROM metadata WHERE \`key\` = '_project_id'"
    db_project_json=$(clean_at "$SOURCE_SCRATCH" "$SOURCE_DOLT_EXEC" \
        --host 127.0.0.1 --port "$port" --no-tls \
        --use-db "$database" sql -r json -q "$project_query" \
        2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    owned_source_server_alive || {
        cleanup_owned_paths
        return 1
    }
    db_project_id=$("$JQ_BIN" -crse '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and keys == ["rows"] and
            (.rows | type) == "array" and (.rows | length) == 1 and
            (.rows[0] | type) == "object" and
            (.rows[0] | keys) == ["project_id"] and
            (.rows[0].project_id | type) == "string" and
            (.rows[0].project_id | test(
                "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
            ))
        ) |
        .rows[0].project_id
    ' 2>/dev/null <<< "$db_project_json") || {
        cleanup_owned_paths
        return 1
    }
    if [ "$db_project_id" != "$qualified_project_id" ]; then
        QUALIFICATION_CODE=source_identity_mismatch
        cleanup_owned_paths
        return 1
    fi

    prefix_json=$(source_at "$SOURCE_SCRATCH" "$SOURCE_BD_EXEC" \
        config get issue_prefix --json 2>/dev/null) || {
        cleanup_owned_paths
        return 1
    }
    SOURCE_ISSUE_PREFIX=$("$JQ_BIN" -crse '
        if length == 1 then .[0] else empty end |
        select(
            type == "object" and keys == ["key", "value"] and
            .key == "issue_prefix" and
            (.value | type) == "string" and
            (.value | test("^[A-Za-z][A-Za-z0-9._-]{0,63}$"))
        ) |
        .value
    ' 2>/dev/null <<< "$prefix_json") || {
        cleanup_owned_paths
        return 1
    }
    if [[ ! "$SOURCE_ISSUE_PREFIX" =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]] ||
        [[ "$SOURCE_ISSUE_PREFIX" == *- ]] ||
        [[ ! "$qualified_database" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; then
        QUALIFICATION_CODE=source_identity_unsupported
        cleanup_owned_paths
        return 1
    fi

    raw="$SOURCE_SCRATCH/source-export.jsonl"
    shows="$SOURCE_SCRATCH/source-shows.jsonl"
    enriched="$SOURCE_SCRATCH/source-enriched.jsonl"
    if ! source_at "$SOURCE_SCRATCH" "$SOURCE_BD_EXEC" export -o "$raw" \
        >/dev/null 2>&1 ||
        ! ids=$("$JQ_BIN" -cer -s '
            if length > 0 and all(.[];
                type == "object" and
                ((.id? | type) == "string") and
                (.id | test("^[A-Za-z0-9._-]{1,128}$")))
            then .[].id | @json
            else error("invalid source export")
            end
        ' "$raw" 2>/dev/null); then
        cleanup_owned_paths
        return 1
    fi
    : > "$shows" || {
        cleanup_owned_paths
        return 1
    }
    while IFS= read -r encoded_id; do
        id=$("$JQ_BIN" -er 'select(type == "string" and length > 0)' \
            <<< "$encoded_id" 2>/dev/null) || {
            cleanup_owned_paths
            return 1
        }
        show_json=$(source_at "$SOURCE_SCRATCH" "$SOURCE_BD_EXEC" \
            show --id="$id" --json 2>/dev/null) || {
            cleanup_owned_paths
            return 1
        }
        show_record=$("$JQ_BIN" -ce --arg id "$id" '
            select(type == "array" and length == 1) | .[0] |
            select(type == "object" and .id == $id and
                   ((.comments // []) | type) == "array")
        ' <<< "$show_json" 2>/dev/null) || {
            cleanup_owned_paths
            return 1
        }
        printf '%s\n' "$show_record" >> "$shows" || {
            cleanup_owned_paths
            return 1
        }
    done <<< "$ids"
    stop_owned_source_server

    if ! "$JQ_BIN" -cn \
        --slurpfile exports "$raw" --slurpfile shows "$shows" '
        def by_id: map({key: .id, value: .}) | from_entries;
        ($shows | by_id) as $show |
        $exports[] |
        ($show[.id].parent // null) as $parent |
        ($show[.id].comments // []) as $comments |
        if $parent != null
        then .parent = $parent
        else del(.parent)
        end |
        if ($comments | length) > 0
        then .comments = $comments
        else del(.comments)
        end
    ' > "$enriched" || ! qualified_source_semantic_corpus "$enriched"; then
        QUALIFICATION_CODE=source_semantic_scope_unqualified
        cleanup_owned_paths
        return 1
    fi
    if ! "$CP_BIN" -f -- "$enriched" "$destination"; then
        cleanup_owned_paths
        return 1
    fi
    cleanup_owned_paths
    QUALIFICATION_CODE=
    return 0
}

trap cleanup_all EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --workspace)
            [ "$#" -ge 2 ] ||
                invalid_usage invalid_usage "--workspace requires a value"
            WORKSPACE_ARG="$2"
            shift 2
            ;;
        --target-bd)
            [ "$#" -ge 2 ] ||
                invalid_usage invalid_usage "--target-bd requires a value"
            TARGET_BD_ARG="$2"
            shift 2
            ;;
        --source-bd)
            [ "$#" -ge 2 ] ||
                invalid_usage invalid_usage "--source-bd requires a value"
            SOURCE_BD_ARG="$2"
            shift 2
            ;;
        --source-dolt)
            [ "$#" -ge 2 ] ||
                invalid_usage invalid_usage "--source-dolt requires a value"
            SOURCE_DOLT_ARG="$2"
            shift 2
            ;;
        --expect-plan)
            [ "$#" -ge 2 ] ||
                invalid_usage invalid_usage "--expect-plan requires a value"
            EXPECT_PLAN="$2"
            shift 2
            ;;
        --inspect|--apply)
            requested_mode="${1#--}"
            if $MODE_SET && [ "$MODE" != "$requested_mode" ]; then
                invalid_usage invalid_usage \
                    "--inspect and --apply are mutually exclusive"
            fi
            MODE="$requested_mode"
            MODE_SET=true
            shift
            ;;
        --yes)
            YES=true
            shift
            ;;
        --json)
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --*)
            invalid_usage invalid_usage "unknown option: $1"
            ;;
        *)
            invalid_usage invalid_usage "unexpected argument: $1"
            ;;
    esac
done

if [ "$MODE" = apply ] && ! $YES; then
    invalid_usage confirmation_required \
        "--apply requires explicit --yes confirmation"
fi
if [ "$MODE" = apply ] && [ -z "$EXPECT_PLAN" ]; then
    invalid_usage plan_required \
        "--apply requires the exact --expect-plan digest from inspect"
fi
if $YES && [ "$MODE" != apply ]; then
    invalid_usage invalid_usage "--yes is valid only with --apply"
fi
if [ -n "$EXPECT_PLAN" ] && [ "$MODE" != apply ]; then
    invalid_usage invalid_usage "--expect-plan is valid only with --apply"
fi
if [ -n "$EXPECT_PLAN" ] && [[ ! "$EXPECT_PLAN" =~ ^[0-9a-f]{64}$ ]]; then
    invalid_usage invalid_plan "--expect-plan must be 64 lowercase hex characters"
fi

INSPECT_TIMEOUT_SECONDS=${BD_V062_INSPECT_TIMEOUT_SECONDS:-600}
if [[ ! "$INSPECT_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    [ "${#INSPECT_TIMEOUT_SECONDS}" -gt 4 ] ||
    [ "$INSPECT_TIMEOUT_SECONDS" -gt 3600 ]; then
    invalid_usage invalid_environment \
        "BD_V062_INSPECT_TIMEOUT_SECONDS must be an integer from 1 to 3600"
fi
case "$TEST_FINGERPRINT_FAILURE" in
    ""|hash|hold) ;;
    *)
        invalid_usage invalid_environment \
            "BD_V062_TEST_FINGERPRINT_FAILURE has an unsupported value"
        ;;
esac
if [ -n "$UNSAFE_TEST_MV_BIN" ]; then
    invalid_usage invalid_environment \
        "BD_V062_TEST_MV_BIN is not a supported executable override"
fi
case "$TEST_MV_MODE" in
    ""|false_success_on_collision|fail_after_source_rename) ;;
    *)
        invalid_usage invalid_environment \
            "BD_V062_TEST_MV_MODE has an unsupported value"
        ;;
esac
case "$TEST_RUNTIME_UNKNOWN_ENTRY" in
    ""|inject) ;;
    *)
        invalid_usage invalid_environment \
            "BD_V062_TEST_RUNTIME_UNKNOWN_ENTRY has an unsupported value"
        ;;
esac
case "$TEST_IDENTITY_PROBE_FAILURE" in
    ""|owner_unverifiable) ;;
    *)
        invalid_usage invalid_environment \
            "BD_V062_TEST_IDENTITY_PROBE_FAILURE has an unsupported value"
        ;;
esac
case "$TEST_GUARDIAN_START_FAILURE" in
    ""|runtime_guardian_start|transaction_guardian_start) ;;
    *)
        invalid_usage invalid_environment \
            "BD_V062_TEST_GUARDIAN_START_FAILURE has an unsupported value"
        ;;
esac
for helper in \
    "$ENV_BIN" "$JQ_BIN" "$READLINK_BIN" "$REALPATH_BIN" "$TIMEOUT_BIN" \
    "$SHA256SUM_BIN" "$CP_BIN" "$GIT_BIN" "$MKTEMP_BIN" \
    "$MKDIR_BIN" "$RM_BIN" "$RMDIR_BIN" "$SLEEP_BIN" \
    "$FIND_BIN" "$SORT_BIN" "$XARGS_BIN" "$MV_BIN" \
    "$CHMOD_BIN" "$STAT_BIN" "$CAT_BIN" "$GREP_BIN" "$FLOCK_BIN"; do
    [ -f "$helper" ] && [ -x "$helper" ] && [ ! -L "$helper" ] ||
        refuse missing_requirement true \
            "required fixed helper is unavailable: $helper"
done

[ -n "$WORKSPACE_ARG" ] || WORKSPACE_ARG="$PWD"
WORKSPACE=$("$REALPATH_BIN" -e -- "$WORKSPACE_ARG" 2>/dev/null) ||
    refuse workspace_invalid true "workspace cannot be resolved"
[ -d "$WORKSPACE" ] && [ ! -L "$WORKSPACE" ] ||
    refuse workspace_invalid true \
        "workspace must be a physical project directory"

if [ -z "$TARGET_BD_ARG" ]; then
    TARGET_BD_ARG=$(type -P bd 2>/dev/null) ||
        refuse target_binary_missing true "no current bd binary was found"
elif [[ "$TARGET_BD_ARG" != /* ]]; then
    refuse target_binary_invalid false \
        "--target-bd must be an absolute path"
fi
TARGET_BD=$("$READLINK_BIN" -f -- "$TARGET_BD_ARG" 2>/dev/null) ||
    refuse target_binary_invalid false \
        "the target bd path cannot be resolved"
[ -f "$TARGET_BD" ] && [ -x "$TARGET_BD" ] ||
    refuse target_binary_invalid false \
        "the target bd path is not an executable regular file"
ensure_runtime_scratch ||
    refuse target_binary_invalid false \
        "a private target runtime directory cannot be created"
TARGET_BD_EXEC="$RUNTIME_SCRATCH/target-bd"
pin_executable "$TARGET_BD" "$TARGET_BD_EXEC" ||
    refuse target_binary_invalid false \
        "the target bd executable cannot be pinned"
TARGET_BD_SHA256=$(sha256_file "$TARGET_BD_EXEC") ||
    refuse target_binary_invalid false \
        "the target bd identity cannot be hashed"

SOURCE_TOOLS_REQUESTED=false
if [ -n "$SOURCE_BD_ARG" ] || [ -n "$SOURCE_DOLT_ARG" ] || \
    [ "$MODE" = apply ]; then
    SOURCE_TOOLS_REQUESTED=true
    resolve_source_tools
fi

ROLLBACK_PATH="$WORKSPACE/.beads-v0.62.0-rollback"
CANONICAL_STAGING_PATH="$WORKSPACE/.beads-v0.62.0-staging"
CANONICAL_LOCK_PATH="$WORKSPACE/.beads-v0.62.0-migration.lock"
STAGING_PATH="$CANONICAL_STAGING_PATH"
LOCK_PATH="$CANONICAL_LOCK_PATH"
LOCK_JOURNAL_PATH="$LOCK_PATH/journal.json"
rollback_path="$ROLLBACK_PATH"

if [ "$MODE" = apply ]; then
    acquire_workspace_lock
    workspace_lock_status=$?
    if [ "$workspace_lock_status" -eq 75 ]; then
        refuse operation_in_progress true \
            "another v0.62 migration operation owns the workspace lock"
    fi
    if [ "$workspace_lock_status" -ne 0 ]; then
        refuse operation_fence_unverifiable true \
            "the workspace migration lock could not be acquired"
    fi
    if [ -e "$LOCK_PATH" ] || [ -L "$LOCK_PATH" ]; then
        recover_stale_operation ||
            finish_error 1 failed recovery_failed false \
                workspace_requires_recovery \
                "stale migration state could not be authenticated and recovered"
    fi
    path_absent "$CANONICAL_STAGING_PATH" ||
        refuse staging_collision false \
            "the side-by-side staging destination already exists"
    create_operation_bundle ||
        transaction_failure operation_fence_unverifiable true \
            "the private migration operation bundle could not be prepared"
    test_phase after_operation_bundle_prepared_before_fence_publish ||
        transaction_failure test_phase_failed true \
            "the prepared-operation test phase handshake did not complete"
    publish_operation_lock ||
        transaction_failure operation_fence_unverifiable true \
            "the migration operation fence could not be published"
    test_phase after_operation_fence_before_reinspect ||
        transaction_failure test_phase_failed true \
            "the operation-fence test phase handshake did not complete"
    publish_operation_staging ||
        transaction_failure staging_unavailable true \
            "the prepared staging inode could not be published"
    test_phase after_staging_publish_before_journal_update ||
        transaction_failure test_phase_failed true \
            "the staging-publication test phase handshake did not complete"
    write_lock_journal staging ||
        transaction_failure journal_write_failed false \
            "the staging transaction state could not be journaled"
    receipt_path=$(completion_receipt_path)
    if [ -e "$receipt_path" ] || [ -L "$receipt_path" ] ||
        looks_like_completed_target; then
        emit_verified_no_op
    fi
fi

ensure_clean_home ||
    refuse missing_requirement true \
        "an isolated runtime home could not be created"
inspection_stdout=$(clean_at "$WORKSPACE" "$TARGET_BD_EXEC" \
    __migration-v062-inspect --workspace "$WORKSPACE" --json 2>/dev/null)
inspection_status=$?

if [ "$inspection_status" -eq 124 ] || [ "$inspection_status" -eq 137 ]; then
    refuse target_inspection_timeout true \
        "target bd inspection exceeded its bounded runtime"
fi

if ! inspection_json=$("$JQ_BIN" -cse \
    --argjson process_status "$inspection_status" '
    def has_code($codes):
        .code as $code | $codes | index($code) != null;
    def nonretryable_refusal:
        .retryable == false and has_code([
            "platform_unsupported",
            "embedded_target_unavailable",
            "workspace_invalid",
            "workspace_not_canonical",
            "source_version_missing",
            "source_version_mismatch",
            "source_version_ambiguous",
            "source_metadata_missing",
            "source_metadata_mismatch",
            "source_layout_missing",
            "source_routing_unsupported",
            "unsafe_source_symlink",
            "unsafe_source_hardlink",
            "unsafe_source_object",
            "cross_device_source",
            "mixed_storage_layout",
            "rollback_collision"
        ]);
    def retryable_refusal:
        .retryable == true and has_code([
            "source_changed",
            "source_unverifiable"
        ]);
    if length != 1 then empty else .[0] end |
    select(
        type == "object" and .schema_version == 1 and
        .operation == "v062_source_inspection" and .effect == "none" and
        (
            (
                .status == "qualified" and $process_status == 0 and
                .retryable == false and
                keys == [
                    "effect", "operation", "retryable", "schema_version",
                    "source", "status", "target"
                ]
            ) or
            (
                .status == "refused" and $process_status == 1 and
                keys == [
                    "code", "effect", "operation", "retryable",
                    "schema_version", "status"
                ] and
                (nonretryable_refusal or retryable_refusal)
            )
        )
    )
' 2>/dev/null <<< "$inspection_stdout"); then
    refuse target_capability_missing false \
        "target bd does not implement the qualified inspection protocol"
fi

inspection_result_status=$("$JQ_BIN" -r '.status' <<< "$inspection_json")
if [ "$inspection_result_status" = refused ]; then
    inspection_code=$("$JQ_BIN" -r '.code' <<< "$inspection_json")
    inspection_retryable=$("$JQ_BIN" -r '.retryable' <<< "$inspection_json")
    finish_error 1 refused "$inspection_code" \
        "$inspection_retryable" none \
        "the no-follow source inspector refused this workspace"
fi

if [ "$inspection_status" -ne 0 ] ||
    ! "$JQ_BIN" -e --arg workspace "$WORKSPACE" '
        .status == "qualified" and
        .source.workspace == $workspace and
        .source.version == "0.62.0" and
        .source.backend == "dolt-server" and
        (.source | keys) == [
            "backend", "database", "digest_scope", "project_id",
            "tree_sha256", "version", "workspace"
        ] and
        (.source.database | type) == "string" and
        (.source.database |
            test("^[A-Za-z_][A-Za-z0-9_-]{0,63}$")) and
        (.source.project_id | type) == "string" and
        (.source.project_id | test(
            "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
        )) and
        .source.digest_scope == "admission_observation" and
        (.source.tree_sha256 | type) == "string" and
        (.source.tree_sha256 | test("^[0-9a-f]{64}$")) and
        .target.backend == "dolt-embedded" and
        .target.embedded_capable == true and
        (.target.version | type) == "string" and
        (.target.version |
            test("^[0-9]+[.][0-9]+[.][0-9]+([+-].*)?$")) and
        ((.target.version | split(".")[0] | tonumber) >= 1)
    ' >/dev/null 2>&1 <<< "$inspection_json"; then
    reported_target_version=$(
        "$JQ_BIN" -r '.target.version // ""' <<< "$inspection_json" \
            2>/dev/null
    ) || reported_target_version=
    if [ "$reported_target_version" = 0.62.0 ]; then
        refuse target_binary_invalid false \
            "the historical bd binary cannot be the migration target"
    fi
    refuse target_capability_missing false \
        "target bd is not a qualified embedded-capable migration target"
fi

SOURCE_DATABASE=$("$JQ_BIN" -er '.source.database' <<< "$inspection_json") ||
    refuse target_capability_missing false \
        "the qualified source database identity is invalid"
SOURCE_PROJECT_ID=$("$JQ_BIN" -er '.source.project_id' <<< "$inspection_json") ||
    refuse target_capability_missing false \
        "the qualified source project identity is invalid"

if $SOURCE_TOOLS_REQUESTED; then
    source_observation=$("$JQ_BIN" -er '.source.tree_sha256' \
        <<< "$inspection_json") ||
        refuse target_capability_missing false \
            "the qualified source observation is invalid"
    SEMANTIC_PROBE="$RUNTIME_SCRATCH/qualified.jsonl"
    path_absent "$SEMANTIC_PROBE" &&
        : > "$SEMANTIC_PROBE" &&
        "$CHMOD_BIN" 600 -- "$SEMANTIC_PROBE" ||
            refuse source_semantic_scope_unverifiable true \
                "a bounded semantic qualification file could not be created"
    if ! qualify_source_semantics "$SEMANTIC_PROBE" \
        "$source_observation" "$SOURCE_DATABASE" "$SOURCE_PROJECT_ID"; then
        if [ "$QUALIFICATION_CODE" = source_semantic_scope_unqualified ]; then
            refuse source_semantic_scope_unqualified false \
                "the source is outside the currently qualified semantic corpus"
        fi
        if [ "$QUALIFICATION_CODE" = source_changed ]; then
            refuse source_changed true \
                "the source identity changed while it was being qualified"
        fi
        if [ "$QUALIFICATION_CODE" = source_identity_mismatch ]; then
            refuse source_identity_mismatch false \
                "metadata.json and the v0.62 database have different project identities"
        fi
        if [ "$QUALIFICATION_CODE" = source_identity_unsupported ]; then
            refuse source_identity_unsupported false \
                "the v0.62 source identity cannot be preserved by the embedded target"
        fi
        refuse source_semantic_scope_unverifiable true \
            "the source semantic corpus could not be verified"
    fi
    [ "$QUALIFIED_SOURCE_TREE" = "$source_observation" ] ||
        refuse source_changed true \
            "the source changed while its semantic corpus was inspected"
    source_content_sha256=$(content_fingerprint "$WORKSPACE/.beads") ||
        refuse source_unverifiable true \
            "the complete source tree could not be fingerprinted"
    build_bound_plan \
        "$inspection_json" "$SEMANTIC_PROBE" "$source_content_sha256" ||
        refuse target_capability_missing false \
            "the bound migration plan could not be constructed"

    if [ "$MODE" = apply ] && [ "$EXPECT_PLAN" != "$PLAN_DIGEST" ]; then
        refuse plan_mismatch false \
            "the source, runtime, target, or workspace changed after inspect"
    fi

    if [ "$MODE" = inspect ]; then
        "$RM_BIN" -f -- "$SEMANTIC_PROBE" ||
            refuse source_semantic_scope_unverifiable true \
                "the semantic qualification scratch file could not be removed"
        SEMANTIC_PROBE=
        if $JSON_OUTPUT; then
            "$JQ_BIN" -cn \
                --argjson inspection "$inspection_json" \
                --argjson plan "$PLAN_JSON" \
                --arg operation "$OPERATION" --arg rollback "$rollback_path" \
                --arg semantic_scope "$SEMANTIC_SCOPE" '
                {
                    schema_version: 1, operation: $operation,
                    mode: "inspect", status: "planned",
                    retryable: false, effect: "none",
                    source: $inspection.source, target: $inspection.target,
                    plan: $plan,
                    rollback: {path: $rollback, policy: "retain"},
                    verification: {
                        source_shape: "qualified",
                        source_digest_scope: $inspection.source.digest_scope,
                        apply_reinspection_required: true,
                        semantic_scope: $semantic_scope,
                        semantic_scope_verified: true,
                        workspace_effects: false
                    }
                }
            '
        else
            printf 'Planned canonical v0.62.0 server-to-embedded migration: %s\n' \
                "$PLAN_DIGEST"
        fi
        exit 0
    fi
    perform_apply "$SEMANTIC_PROBE"
fi

# Layout admission alone cannot produce a consent-bound plan. Historical
# source tools are explicit inputs because their exact bytes become plan data.
if $JSON_OUTPUT; then
    "$JQ_BIN" -cn \
        --argjson inspection "$inspection_json" \
        --arg operation "$OPERATION" --arg mode "$MODE" \
        --arg rollback "$rollback_path" '
        {
            schema_version: 1, operation: $operation, mode: $mode,
            status: "refused", code: "source_tools_required",
            retryable: false, effect: "none",
            source: $inspection.source, target: $inspection.target,
            rollback: {path: $rollback, policy: "retain"},
            verification: {
                source_shape: "qualified",
                source_tree_sha256: $inspection.source.tree_sha256,
                source_digest_scope: $inspection.source.digest_scope,
                apply_reinspection_required: true,
                apply_available: true,
                apply_requires_pinned_source_tools: true,
                workspace_effects: false
            }
        }
    '
else
    printf '%s\n' \
        'Qualified v0.62.0 source; rerun inspect with --source-bd and --source-dolt to bind an apply plan.' >&2
fi
exit 1
