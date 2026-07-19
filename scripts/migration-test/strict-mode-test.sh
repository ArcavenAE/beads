#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/report.sh"
source "$SCRIPT_DIR/lib/versions.sh"
source "$SCRIPT_DIR/lib/binary.sh"
source "$SCRIPT_DIR/lib/workspace.sh"
source "$SCRIPT_DIR/lib/features.sh"
source "$SCRIPT_DIR/lib/snapshot.sh"
source "$SCRIPT_DIR/lib/direct_probe.sh"
source "$SCRIPT_DIR/recipes/sqlite_to_current.sh"
source "$SCRIPT_DIR/recipes/server_to_embedded.sh"

fail() {
    echo "strict-mode-test: $*" >&2
    exit 1
}

asset=$(strict_release_asset v0.49.6 linux amd64)
[ "$asset" = "beads_0.49.6_linux_amd64.tar.gz" ] || fail "unexpected release asset"
sha=$(strict_release_sha256 v0.49.6 linux amd64)
[ "$sha" = "8546dc9a47e11dc31ac2bc9a0224a9c690975e91850932cbb62623053fbb7db8" ] || fail "unexpected release checksum"

asset=$(strict_release_asset v0.55.4 linux amd64) || fail "missing v0.55.4 release asset"
[ "$asset" = "beads_0.55.4_linux_amd64.tar.gz" ] || fail "unexpected v0.55.4 release asset"
sha=$(strict_release_sha256 v0.55.4 linux amd64) || fail "missing v0.55.4 release checksum"
[ "$sha" = "e0fa25456dd82890230eef17653448a0bf995104c78864be91c5ed84426a5f49" ] ||
    fail "unexpected v0.55.4 release checksum"
[ "$(strict_expected_status v0.55.4)" = "MANUAL" ] || fail "unexpected v0.55.4 status"
[ "$(strict_expected_recipe v0.55.4)" = "server_to_embedded" ] || fail "unexpected v0.55.4 recipe"
[ "$(strict_expected_features v0.55.4)" = "epic task bug dependency standalone closed label comment" ] ||
    fail "unexpected v0.55.4 source features"

asset=$(strict_release_asset v0.57.0 linux amd64) || fail "missing v0.57.0 release asset"
[ "$asset" = "beads_0.57.0_linux_amd64.tar.gz" ] || fail "unexpected v0.57.0 release asset"
sha=$(strict_release_sha256 v0.57.0 linux amd64) || fail "missing v0.57.0 release checksum"
[ "$sha" = "f8629d5627bed7d25f06f92334addc171d679f9aed9d08c5d42a9684205dc04b" ] ||
    fail "unexpected v0.57.0 release checksum"
[ "$(strict_expected_status v0.57.0)" = "MANUAL" ] || fail "unexpected v0.57.0 status"
[ "$(strict_expected_recipe v0.57.0)" = "server_to_embedded" ] || fail "unexpected v0.57.0 recipe"
[ "$(strict_expected_features v0.57.0)" = "epic task bug dependency standalone closed label comment" ] ||
    fail "unexpected v0.57.0 source features"
[ "$(strict_required_dolt_version v0.57.0)" = "2.1.8" ] ||
    fail "unexpected v0.57.0 Dolt runtime version"
[ "$(strict_required_dolt_sha256 v0.57.0 linux amd64)" = \
    "f66318f08ed66e409fc39363ae0fff8ce6fbf6dba9f5bac632b91527b9632a74" ] ||
    fail "unexpected v0.57.0 Dolt runtime checksum"

asset=$(strict_release_asset v0.62.0 linux amd64) || fail "missing v0.62.0 release asset"
[ "$asset" = "beads_0.62.0_linux_amd64.tar.gz" ] || fail "unexpected v0.62.0 release asset"
sha=$(strict_release_sha256 v0.62.0 linux amd64) || fail "missing v0.62.0 release checksum"
[ "$sha" = "4cca7265b22e5c3ca8d62ab0b9752bec31f68b7f5fa636282a4c7e5454c35535" ] ||
    fail "unexpected v0.62.0 release checksum"
[ "$(strict_expected_status v0.62.0)" = "MANUAL" ] || fail "unexpected v0.62.0 status"
[ "$(strict_expected_recipe v0.62.0)" = "public_v062_bridge" ] ||
    fail "unexpected v0.62.0 recipe"
[ "$(strict_expected_features v0.62.0)" = "epic task bug dependency standalone closed label comment" ] ||
    fail "unexpected v0.62.0 source features"
[[ ${SERVER_BRIDGE_STRATEGIES["v0.62.0"]+present} != present ]] ||
    fail "v0.62.0 remained in the private server bridge strategy map"
if server_bridge_strategy v0.62.0 >/dev/null 2>&1; then
    fail "v0.62.0 unexpectedly selected a private server bridge strategy"
fi
[ "$(server_bootstrap_strategy v0.62.0)" = "prestarted_server" ] ||
    fail "unexpected v0.62.0 server bootstrap strategy"
[ "$(strict_required_dolt_version v0.62.0)" = "1.84.0" ] ||
    fail "unexpected v0.62.0 Dolt runtime version"
[ "$(strict_required_dolt_sha256 v0.62.0 linux amd64)" = \
    "afcdaa9530ae0b4f317ed6041a41d20096e156b2556eb0e03c7c57a624ccc0b3" ] ||
    fail "unexpected v0.62.0 Dolt runtime checksum"
[ "$(get_era v0.62.0)" = "dolt_server" ] || fail "v0.62.0 was not classified as server mode"

asset=$(strict_release_asset v0.63.3 linux amd64) || fail "missing v0.63.3 release asset"
[ "$asset" = "beads_0.63.3_linux_amd64.tar.gz" ] || fail "unexpected v0.63.3 release asset"
sha=$(strict_release_sha256 v0.63.3 linux amd64) || fail "missing v0.63.3 release checksum"
[ "$sha" = "5f4efd2e010209b3f381dbcd783b2a3a652f50ea72f40ef04c8ba434d408bf9e" ] ||
    fail "unexpected v0.63.3 release checksum"
[ "$(strict_expected_status v0.63.3)" = "AUTO" ] || fail "unexpected v0.63.3 status"
[ "$(strict_expected_recipe v0.63.3)" = "" ] || fail "unexpected v0.63.3 recipe"
[ "$(strict_expected_features v0.63.3)" = "epic task bug dependency standalone closed label comment" ] ||
    fail "unexpected v0.63.3 source features"
[ "${LEGACY_DOLT_ROLLBACK_FILES[*]}" = "metadata.json config.json config.yaml issues.jsonl" ] ||
    fail "unexpected legacy Dolt rollback file inventory"

for lookup in strict_release_asset strict_release_sha256; do
    if "$lookup" v9.9.9 linux amd64 >/dev/null 2>&1; then
        fail "$lookup accepted an unknown release manifest"
    fi
done
for lookup in strict_expected_status strict_expected_recipe strict_expected_features; do
    if "$lookup" v9.9.9 >/dev/null 2>&1; then
        fail "$lookup accepted an unknown qualification manifest"
    fi
done
for lookup in strict_required_dolt_version strict_required_dolt_sha256; do
    if "$lookup" v9.9.9 linux amd64 >/dev/null 2>&1; then
        fail "$lookup accepted an unknown historical runtime manifest"
    fi
done

tmp=$(mktemp -d)
guard_server_pid=""
trap '[ -z "${guard_server_pid:-}" ] || kill -9 -- "$guard_server_pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

server_recipe_route=$(awk '
    /# Step 5: Direct upgrade failed/ { in_recipe_section = 1 }
    in_recipe_section && /^[[:space:]]*case "\$era" in$/ { in_era_case = 1 }
    in_era_case && /^[[:space:]]*dolt_server\)$/ { in_server_route = 1 }
    in_server_route {
        print
        if ($0 ~ /^[[:space:]]*;;[[:space:]]*$/) exit
    }
' "$SCRIPT_DIR/run.sh")
[ -n "$server_recipe_route" ] || fail "could not locate the Dolt-server recipe route"
public_v062_route=$(awk '
    /if \[ "\$version" = "v0\.62\.0" \]; then/ { in_public_route = 1 }
    in_public_route && /^[[:space:]]*elif recipe_server_to_embedded/ { exit }
    in_public_route { print }
' <<< "$server_recipe_route")
grep -Fq 'run_public_v062_bridge' \
    <<< "$public_v062_route" || fail "v0.62.0 did not route through the public bridge"
grep -Fq '"$source_identity_json"' <<< "$public_v062_route" ||
    fail "v0.62.0 public bridge route omitted authenticated source identity"
grep -Fq 'recipe_name="public_v062_bridge"' <<< "$public_v062_route" ||
    fail "v0.62.0 did not report the public bridge recipe"
if grep -Fq 'recipe_server_to_embedded' <<< "$public_v062_route"; then
    fail "v0.62.0 public route retained a private server bridge fallback"
fi
grep -Fq 'elif recipe_server_to_embedded' <<< "$server_recipe_route" ||
    fail "legacy Dolt-server versions lost the private v0.55/v0.57 recipe route"

public_route_root="$tmp/public-route-project"
public_route_bin_dir="$tmp/public-route-bin"
public_route_bridge="$public_route_root/scripts/migrate-v062-server-to-current.sh"
public_route_source_bd="$tmp/public-route-source-bd"
public_route_target_bd="$tmp/public-route-target-bd"
public_route_dolt="$public_route_bin_dir/dolt"
public_route_ws="$tmp/public-route-workspace"
public_route_calls="$tmp/public-route.calls"
public_route_private_calls="$tmp/public-route-private.calls"
public_route_plan=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
public_route_identity='{"issue_prefix":"legacy","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}'
mkdir -p "$public_route_root/scripts" "$public_route_bin_dir" "$public_route_ws"
cat > "$public_route_bridge" <<'EOF'
#!/bin/bash
set -euo pipefail
{
    for arg in "$@"; do
        printf '<%s>' "$arg"
    done
    printf '\n'
} >> "${PUBLIC_ROUTE_CALLS:?}"
case "${1:-}" in
    --inspect)
        printf '{"schema_version":1,"operation":"v062_server_to_current","mode":"inspect","status":"planned","effect":"none","source":{"database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"},"plan":{"digest":"%s","source_identity":{"issue_prefix":"legacy","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}}}\n' \
            "${PUBLIC_ROUTE_PLAN:?}"
        ;;
    --apply)
        args=("$@")
        expected_plan=""
        for ((i = 0; i < ${#args[@]}; i++)); do
            if [ "${args[$i]}" = "--expect-plan" ] && [ $((i + 1)) -lt ${#args[@]} ]; then
                expected_plan="${args[$((i + 1))]}"
            fi
        done
        [ -n "$expected_plan" ] || exit 2
        apply_count=$(grep -c '^<--apply>' "${PUBLIC_ROUTE_CALLS:?}")
        if [ "$apply_count" -eq 1 ]; then
            printf '{"schema_version":1,"operation":"v062_server_to_current","mode":"apply","status":"succeeded","effect":"workspace_migrated","plan":{"digest":"%s","source_identity":{"issue_prefix":"legacy","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}},"target":{"backend":"dolt-embedded"}}\n' \
                "$expected_plan"
        else
            printf '{"schema_version":1,"operation":"v062_server_to_current","mode":"apply","status":"succeeded","effect":"none","no_op":true,"plan":{"digest":"%s","source_identity":{"issue_prefix":"legacy","database":"smoke","project_id":"7ef372b4-4c3c-4e2c-a6cc-29dd2d0a28c6"}},"target":{"backend":"dolt-embedded"},"verification":{"separate_process_reopen":true}}\n' \
                "$expected_plan"
        fi
        ;;
    *) exit 2 ;;
esac
EOF
printf '%s\n' '#!/bin/bash' 'exit 0' > "$public_route_source_bd"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$public_route_target_bd"
printf '%s\n' '#!/bin/bash' 'exit 0' > "$public_route_dolt"
chmod +x \
    "$public_route_bridge" "$public_route_source_bd" \
    "$public_route_target_bd" "$public_route_dolt"
if [[ "$public_route_source_bd" != /* ]] || [[ "$public_route_dolt" != /* ]]; then
    fail "public-route probe binaries were not absolute"
fi
if ! PATH="$public_route_bin_dir:$PATH" \
    PUBLIC_ROUTE_CALLS="$public_route_calls" \
    PUBLIC_ROUTE_PLAN="$public_route_plan" \
    bash -c '
    set -euo pipefail
    export MIGRATION_TEST_RUN_LIBRARY_ONLY=1
    source "$1"
    PROJECT_ROOT="$2"
    private_calls="$3"
    recipe_server_to_embedded() {
        printf "private fallback\n" >> "$private_calls"
        return 1
    }
    run_public_v062_bridge "$4" "$5" "$6" "$7"
' public-route-probe "$SCRIPT_DIR/run.sh" "$public_route_root" \
        "$public_route_private_calls" "$public_route_ws" \
        "$public_route_source_bd" "$public_route_target_bd" \
        "$public_route_identity"; then
    fail "run.sh public v0.62.0 inspect/apply route failed"
fi
[ ! -e "$public_route_private_calls" ] ||
    fail "run.sh public v0.62.0 route invoked the private recipe fallback"
mapfile -t public_route_argv < "$public_route_calls"
[ "${#public_route_argv[@]}" -eq 3 ] ||
    fail "public v0.62.0 route did not make one inspect and two apply calls"
expected_public_inspect="<--inspect><--source-bd><$public_route_source_bd><--source-dolt><$public_route_dolt><--workspace><$public_route_ws><--target-bd><$public_route_target_bd><--json>"
expected_public_apply="<--apply><--yes><--expect-plan><$public_route_plan><--source-bd><$public_route_source_bd><--source-dolt><$public_route_dolt><--workspace><$public_route_ws><--target-bd><$public_route_target_bd><--json>"
[ "${public_route_argv[0]}" = "$expected_public_inspect" ] ||
    fail "public v0.62.0 inspect did not receive exact absolute source inputs"
[ "${public_route_argv[1]}" = "$expected_public_apply" ] ||
    fail "public v0.62.0 apply was not bound to the exact value-bearing inspect plan"
[ "${public_route_argv[2]}" = "$expected_public_apply" ] ||
    fail "public v0.62.0 no-op did not repeat the exact value-bearing inspect plan"

unsafe_cleanup_calls="$tmp/unsafe-cleanup.calls"
if (
    pkill() { printf 'pkill %s\n' "$*" >> "$unsafe_cleanup_calls"; }
    rm() { printf 'rm %s\n' "$*" >> "$unsafe_cleanup_calls"; }
    sleep() { :; }
    cleanup_workspace ""
); then
    fail "cleanup accepted an empty workspace path"
fi
[ ! -e "$unsafe_cleanup_calls" ] ||
    fail "empty workspace cleanup invoked a process or filesystem command"

unowned_workspace="$tmp/unowned-workspace"
mkdir -p "$unowned_workspace"
if (
    pkill() { printf 'pkill %s\n' "$*" >> "$unsafe_cleanup_calls"; }
    rm() { printf 'rm %s\n' "$*" >> "$unsafe_cleanup_calls"; }
    sleep() { :; }
    cleanup_workspace "$unowned_workspace"
); then
    fail "cleanup accepted a workspace not owned by this harness"
fi
[ ! -e "$unsafe_cleanup_calls" ] ||
    fail "unowned workspace cleanup invoked a process or filesystem command"

allocation_failure_tmp="$tmp/not-a-directory"
allocation_failure_bin="$tmp/allocation-failure-bin"
allocation_failure_log="$tmp/allocation-failure-process.calls"
allocation_failure_output="$tmp/allocation-failure.out"
printf 'not a directory\n' > "$allocation_failure_tmp"
mkdir -p "$allocation_failure_bin"
cat > "$allocation_failure_bin/pkill" <<'EOF'
#!/bin/bash
printf 'pkill %s\n' "$*" >> "${MIGRATION_TEST_PROCESS_LOG:?}"
EOF
chmod +x "$allocation_failure_bin/pkill"
if PATH="$allocation_failure_bin:$PATH" \
    TMPDIR="$allocation_failure_tmp" \
    MIGRATION_TEST_PROCESS_LOG="$allocation_failure_log" \
    CANDIDATE_BIN=/bin/true \
    "$SCRIPT_DIR/run.sh" --self-test > "$allocation_failure_output" 2>&1; then
    fail "self-test unexpectedly passed after workspace allocation failed"
fi
grep -q 'BLOCKED: could not create isolated workspace' "$allocation_failure_output" ||
    fail "workspace allocation failure did not produce an explicit BLOCKED result"
[ ! -e "$allocation_failure_log" ] ||
    fail "workspace allocation failure reached process cleanup"
if (
    mktemp() { return 1; }
    new_workspace
); then
    fail "workspace creation accepted a failed mktemp allocation"
fi

snapshot_failure_bin="$tmp/snapshot-failure-bin"
snapshot_failure_output="$tmp/snapshot-failure.out"
real_mktemp=$(command -v mktemp)
mkdir -p "$snapshot_failure_bin"
cat > "$snapshot_failure_bin/mktemp" <<EOF
#!/bin/bash
case "\${*: -1}" in
    /tmp/bd-snapshots-*) exit 1 ;;
    *) exec "$real_mktemp" "\$@" ;;
esac
EOF
chmod +x "$snapshot_failure_bin/mktemp"
if PATH="$snapshot_failure_bin:$PATH" \
    CANDIDATE_BIN=/bin/false \
    "$SCRIPT_DIR/run.sh" --self-test > "$snapshot_failure_output" 2>&1; then
    fail "self-test unexpectedly passed after snapshot allocation failed"
fi
grep -q 'BLOCKED: could not create isolated snapshot directory' "$snapshot_failure_output" ||
    fail "snapshot allocation failure did not produce an explicit BLOCKED result"

host_hooks_dir="$tmp/host-hooks"
host_hook_log="$tmp/host-hook.calls"
host_git_config="$tmp/host.gitconfig"
mkdir -p "$host_hooks_dir"
cat > "$host_hooks_dir/pre-commit" <<'EOF'
#!/bin/bash
printf 'host hook ran\n' >> "${HOST_HOOK_LOG:?}"
exit 99
EOF
chmod +x "$host_hooks_dir/pre-commit"
git config -f "$host_git_config" core.hooksPath "$host_hooks_dir"
if ! hook_guard_workspace=$(
    HOST_HOOK_LOG="$host_hook_log" GIT_CONFIG_GLOBAL="$host_git_config" new_workspace
); then
    fail "workspace creation inherited a failing host-global Git hook"
fi
[ ! -e "$host_hook_log" ] ||
    fail "workspace creation executed a host-global Git hook"
cleanup_workspace "$hook_guard_workspace" ||
    fail "could not clean up the Git-hook isolation workspace"

pid_guard_workspace=$(new_workspace) ||
    fail "could not create a workspace for PID cleanup guards"
mkdir -p "$pid_guard_workspace/.beads"
for unsafe_pid in 0 -1 not-a-pid "$$"; do
    pid_guard_calls="$tmp/pid-guard-${unsafe_pid//[^[:alnum:]]/_}.calls"
    printf '%s\n' "$unsafe_pid" > "$pid_guard_workspace/.beads/dolt-server.pid"
    if ! (
        kill() { printf 'kill %s\n' "$*" >> "$pid_guard_calls"; }
        pkill() { printf 'pkill %s\n' "$*" >> "$pid_guard_calls"; }
        sleep() { :; }
        migration_server_port_in_use() { return 1; }
        stop_dolt_server "$pid_guard_workspace"
    ); then
        fail "server cleanup rejected its owned workspace for PID value $unsafe_pid"
    fi
    if [ -e "$pid_guard_calls" ]; then
        fail "server cleanup trusted unsafe or unrelated PID value $unsafe_pid"
    fi
done

printf '0\n' > "$pid_guard_workspace/.beads/dolt-server.pid"
for occupancy_status in 0 2; do
    pid_guard_calls="$tmp/pid-guard-occupancy-$occupancy_status.calls"
    if (
        kill() { printf 'kill %s\n' "$*" >> "$pid_guard_calls"; }
        pkill() { printf 'pkill %s\n' "$*" >> "$pid_guard_calls"; }
        sleep() { :; }
        migration_server_port_in_use() { return "$occupancy_status"; }
        stop_dolt_server "$pid_guard_workspace"
    ); then
        fail "server cleanup accepted unsafe PID 0 with port occupancy status $occupancy_status"
    fi
    [ ! -e "$pid_guard_calls" ] ||
        fail "server cleanup signaled a process for unsafe PID 0 with occupancy status $occupancy_status"
done

external_dolt_cwd="$tmp/external-dolt-cwd"
mkdir -p "$external_dolt_cwd"
(
    cd "$external_dolt_cwd"
    exec -a 'dolt sql-server' sleep 600
) &
guard_server_pid=$!
for _ in $(seq 1 50); do
    if [ "$(readlink "/proc/$guard_server_pid/cwd" 2>/dev/null || true)" = "$external_dolt_cwd" ] &&
        tr '\0' ' ' < "/proc/$guard_server_pid/cmdline" 2>/dev/null | grep -q 'dolt.*sql-server'; then
        break
    fi
    sleep 0.02
done
printf '%s\n' "$guard_server_pid" > "$pid_guard_workspace/.beads/dolt-server.pid"
stop_dolt_server "$pid_guard_workspace" ||
    fail "server cleanup rejected a free port for an unrelated Dolt-shaped process"
if ! kill -0 "$guard_server_pid" 2>/dev/null; then
    guard_server_pid=""
    fail "server cleanup killed a Dolt-shaped process rooted outside its workspace"
fi
kill -9 -- "$guard_server_pid" 2>/dev/null || true
wait "$guard_server_pid" 2>/dev/null || true
guard_server_pid=""

legacy_child_dolt_cwd="$pid_guard_workspace/.beads/dolt/legacy-child"
mkdir -p "$legacy_child_dolt_cwd"
(
    cd "$legacy_child_dolt_cwd"
    exec -a 'dolt sql-server' sleep 600
) &
guard_server_pid=$!
for _ in $(seq 1 50); do
    if [ "$(readlink "/proc/$guard_server_pid/cwd" 2>/dev/null || true)" = \
        "$legacy_child_dolt_cwd" ]; then
        break
    fi
    sleep 0.02
done
migration_pid_belongs_to_workspace \
    "$guard_server_pid" "$pid_guard_workspace" "dolt-server.pid" ||
    fail "legacy Dolt cleanup lost its established child-cwd compatibility"
kill -9 -- "$guard_server_pid" 2>/dev/null || true
wait "$guard_server_pid" 2>/dev/null || true
guard_server_pid=""

fake_dolt_cwd="$pid_guard_workspace/.beads/dolt"
mkdir -p "$fake_dolt_cwd"
(
    cd "$fake_dolt_cwd"
    exec -a 'dolt sql-server' sleep 600
) &
guard_server_pid=$!
for _ in $(seq 1 50); do
    if [ "$(readlink "/proc/$guard_server_pid/cwd" 2>/dev/null || true)" = "$fake_dolt_cwd" ] &&
        tr '\0' ' ' < "/proc/$guard_server_pid/cmdline" 2>/dev/null | grep -q 'dolt.*sql-server'; then
        break
    fi
    sleep 0.02
done
printf '%s\n' "$guard_server_pid" > "$pid_guard_workspace/.beads/dolt-server.pid"
stop_dolt_server "$pid_guard_workspace" ||
    fail "server cleanup rejected a verified Dolt server rooted in its workspace"
if kill -0 "$guard_server_pid" 2>/dev/null; then
    kill -9 -- "$guard_server_pid" 2>/dev/null || true
    wait "$guard_server_pid" 2>/dev/null || true
    guard_server_pid=""
    fail "server cleanup left a verified Dolt server running"
fi
wait "$guard_server_pid" 2>/dev/null || true
guard_server_pid=""

rm -f "$pid_guard_workspace/.beads/dolt-server.pid"
cleanup_workspace "$pid_guard_workspace" ||
    fail "could not clean up the PID guard workspace"

port_ws_one="$tmp/port-workspace-one"
port_ws_two="$tmp/port-workspace-two"
port_probe_bin="$tmp/port-probe-bd"
mkdir -p "$port_ws_one/.git" "$port_ws_two/.git"
reserve_migration_server_port "$port_ws_one" ||
    fail "could not reserve the first isolated historical server port"
reserve_migration_server_port "$port_ws_two" ||
    fail "could not reserve the second isolated historical server port"
port_one=$(cat "$port_ws_one/.git/bd-migration-server-port")
port_two=$(cat "$port_ws_two/.git/bd-migration-server-port")
[[ "$port_one" =~ ^2[0-9]{4}$ ]] || fail "first isolated server port is outside the reserved range"
[[ "$port_two" =~ ^2[0-9]{4}$ ]] || fail "second isolated server port is outside the reserved range"
[ "$port_one" != "$port_two" ] || fail "concurrent workspaces reused a historical server port"
port_lock_one=$(cat "$port_ws_one/.git/bd-migration-server-port-lock")
port_lock_two=$(cat "$port_ws_two/.git/bd-migration-server-port-lock")
[ -d "$port_lock_one" ] && [ -d "$port_lock_two" ] ||
    fail "isolated historical server port was not reserved atomically"
cat > "$port_probe_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "${BEADS_DOLT_SERVER_PORT:-}"
EOF
chmod +x "$port_probe_bin"
[ "$(bd_in "$port_ws_one" "$port_probe_bin")" = "$port_one" ] ||
    fail "bd_in did not propagate the workspace-specific historical server port"

env_probe_bin="$tmp/environment-probe-bd"
cat > "$env_probe_bin" <<'EOF'
#!/bin/bash
env | sort
EOF
chmod +x "$env_probe_bin"
poisoned_env_output=$(
    BEADS_DB=/production/beads.db \
    BEADS_DIR=/production/.beads \
    BEADS_DOLT_DATA_DIR=/production/dolt \
    BEADS_BACKEND=postgres \
    BD_DB=/production/bd.db \
    GT_ROOT=/production/town \
    DOLT_ROOT_PATH=/production/dolt-root \
    HOME=/production/home \
    XDG_CONFIG_HOME=/production/config \
    GIT_CONFIG_GLOBAL=/production/gitconfig \
    BASH_ENV=/production/bash-env \
    bd_in "$port_ws_one" "$env_probe_bin"
)
if grep -Eq \
    '^(BEADS_DB|BEADS_DIR|BEADS_DOLT_DATA_DIR|BEADS_BACKEND|BD_DB|GT_ROOT|DOLT_ROOT_PATH|BASH_ENV)=' \
    <<< "$poisoned_env_output"; then
    fail "bd_in exposed a poisoned host routing or shell environment"
fi
grep -Fqx "HOME=$port_ws_one/.git/bd-migration-home" <<< "$poisoned_env_output" ||
    fail "bd_in did not isolate HOME inside the workspace"
grep -Fqx "XDG_CONFIG_HOME=$port_ws_one/.git/bd-migration-home/.config" \
    <<< "$poisoned_env_output" ||
    fail "bd_in did not isolate XDG configuration inside the workspace"
grep -Fqx "TMPDIR=$port_ws_one/.git/bd-migration-tmp" <<< "$poisoned_env_output" ||
    fail "bd_in did not isolate temporary files inside the workspace"
grep -Fqx 'GIT_CONFIG_GLOBAL=/dev/null' <<< "$poisoned_env_output" ||
    fail "bd_in did not disable host-global Git configuration"
grep -Fqx "BEADS_DOLT_SERVER_PORT=$port_one" <<< "$poisoned_env_output" ||
    fail "bd_in did not retain the workspace-specific Dolt port"
grep -Fqx 'BEADS_TEST_MODE=0' <<< "$poisoned_env_output" ||
    fail "bd_in did not force the server-capable migration test mode"
grep -Fqx 'BEADS_NO_DAEMON=1' <<< "$poisoned_env_output" ||
    fail "bd_in did not disable the historical background daemon"
grep -Fqx 'BEADS_DOLT_AUTO_START=1' <<< "$poisoned_env_output" ||
    fail "bd_in did not force the intended historical server auto-start behavior"

timeout_probe_bin_dir="$tmp/timeout-probe-bin"
mkdir -p "$timeout_probe_bin_dir"
if ! migration_validate_operation_timeouts; then
    fail "default migration operation timeouts were rejected"
fi
if BD_OP_TIMEOUT=0 migration_validate_operation_timeouts; then
    fail "zero migration operation timeout was accepted"
fi
if BD_OP_TIMEOUT=301 migration_validate_operation_timeouts; then
    fail "unbounded migration operation timeout was accepted"
fi
if BD_OP_KILL_AFTER=0s migration_validate_operation_timeouts; then
    fail "zero migration kill-after timeout was accepted"
fi
if BD_OP_KILL_AFTER=61s migration_validate_operation_timeouts; then
    fail "unbounded migration kill-after timeout was accepted"
fi
if ! migration_validate_readiness_settings 100 0.1 30; then
    fail "default owned-server readiness settings were rejected"
fi
for invalid_readiness in '0 0.1 30' '201 0.1 30' '100 1.1 30' '100 0.1 0' '100 0.1 121'; do
    read -r ready_attempts ready_delay ready_timeout <<< "$invalid_readiness"
    if migration_validate_readiness_settings \
        "$ready_attempts" "$ready_delay" "$ready_timeout"; then
        fail "unsafe owned-server readiness settings were accepted: $invalid_readiness"
    fi
done
cat > "$timeout_probe_bin_dir/timeout" <<'EOF'
#!/bin/bash
printf ' <%s>' "$@"
printf '\n'
EOF
chmod +x "$timeout_probe_bin_dir/timeout"
timeout_probe_output=$(PATH="$timeout_probe_bin_dir:$PATH" bd_in "$port_ws_one" /bin/true)
[ "$timeout_probe_output" = \
    " <--kill-after=$BD_OP_KILL_AFTER> <$BD_OP_TIMEOUT> </bin/true>" ] ||
    fail "bd_in did not bound a stubborn historical command with timeout --kill-after"

release_migration_server_port "$port_ws_one" ||
    fail "could not release the first isolated historical server port"
release_migration_server_port "$port_ws_two" ||
    fail "could not release the second isolated historical server port"
[ ! -e "$port_lock_one" ] && [ ! -e "$port_lock_two" ] ||
    fail "historical server port reservation leaked after release"

if ! (
    transition_pid=""
    transition_state="$tmp/owned-exit-transition.state"
    cleanup_transition_probe() {
        [ -z "$transition_pid" ] || kill -9 -- "$transition_pid" 2>/dev/null || true
        [ -z "$transition_pid" ] || wait "$transition_pid" 2>/dev/null || true
    }
    trap cleanup_transition_probe EXIT
    rm -f -- "$transition_state"
    (
        trap 'printf "term\n" > "$transition_state"; sleep 0.2; exit 0' TERM
        while :; do
            sleep 0.05 &
            wait "$!" || true
        done
    ) &
    transition_pid=$!
    transition_start=$(migration_process_start_time "$transition_pid")
    transition_identity=(
        "$transition_pid" "$transition_start" ignored-exe ignored-launch
        ignored-launch-id binary ignored-cwd
    )
    kill -TERM -- "$transition_pid"
    for ((attempt = 0; attempt < 50; attempt++)); do
        [ -s "$transition_state" ] && break
        sleep 0.01
    done
    [ -s "$transition_state" ]
    migration_owned_process_matches_identity() { return 1; }
    migration_wait_owned_process_exit \
        "$transition_pid" "$tmp" transition_identity 40
); then
    fail "owned-process wait rejected a valid graceful-exit transition"
fi

owned_server_bin_dir="$tmp/owned-server-bin"
owned_server_calls="$owned_server_bin_dir/calls"
owned_server_env="$owned_server_bin_dir/environments"
mkdir -p "$owned_server_bin_dir"
cat > "$owned_server_bin_dir/dolt" <<'EOF'
#!/bin/bash
set -euo pipefail
bin_dir="$(cd "$(dirname "$0")" && pwd)"
{
    printf 'cwd=%s args=' "$PWD"
    printf ' <%s>' "$@"
    printf '\n'
} >> "$bin_dir/calls"
{
    printf '%s\n' '---'
    env | sort
} >> "$bin_dir/environments"
case "${1:-}" in
    init)
        mkdir -p .dolt
        printf '{}\n' > .dolt/repo_state.json
        ;;
    sql-server)
        [ ! -e "$bin_dir/fail-server" ] || exit 42
        printf '%s\n' "$BASHPID" > "$bin_dir/last-server-pid"
        if [ -e "$bin_dir/ignore-term" ]; then
            trap '' TERM
        else
            trap 'exit 0' TERM
        fi
        while :; do
            sleep 0.1 &
            wait "$!" || true
        done
        ;;
    --host)
        [ ! -e "$bin_dir/fail-sql" ] || exit 43
        [ "$2" = "127.0.0.1" ] && [ "$3" = "--port" ] &&
            [[ "$4" =~ ^2[0-9]{4}$ ]] || exit 45
        if [ "$#" -eq 8 ]; then
            [ "$5" = "--no-tls" ] && [ "$6" = "sql" ] &&
                [ "$7" = "-q" ] && [ "$8" = "SELECT 1" ]
            if [ -e "$bin_dir/fail-final-validation" ]; then
                git_dir="${XDG_RUNTIME_DIR%/bd-migration-runtime}"
                printf '29999\n' > "$git_dir/bd-migration-prestarted-server"
            fi
        elif [ "$#" -eq 12 ]; then
            [ "$5" = "--no-tls" ] && [ "$6" = "--use-db" ] &&
                [ "$7" = "smoke" ] && [ "$8" = "sql" ] &&
                [ "$9" = "-r" ] && [ "${10}" = "json" ] &&
                [ "${11}" = "-q" ] &&
                [ "${12}" = "SELECT value AS schema_version FROM config WHERE \`key\` = 'schema_version'" ]
            printf '{"rows":[{"schema_version":"9"}]}\n'
        else
            exit 46
        fi
        ;;
    *)
        exit 44
        ;;
esac
EOF
chmod +x "$owned_server_bin_dir/dolt"

owned_server_workspace=$(new_workspace) ||
    fail "could not create an owned-server helper workspace"
owned_server_port=$(cat "$owned_server_workspace/.git/bd-migration-server-port")
if ! PATH="$owned_server_bin_dir:$PATH" \
    HOME=/production/home \
    XDG_CONFIG_HOME=/production/config \
    DOLT_ROOT_PATH=/production/dolt-root \
    start_owned_migration_dolt_server "$owned_server_workspace"; then
    fail "owned historical Dolt server did not start"
fi
owned_server_pid_file="$owned_server_workspace/.git/bd-migration-owned-dolt-server.pid"
owned_server_identity_file="$owned_server_workspace/.git/bd-migration-owned-dolt-server.identity"
owned_server_mode_file="$owned_server_workspace/.git/bd-migration-prestarted-server"
[ -f "$owned_server_pid_file" ] && [ ! -L "$owned_server_pid_file" ] ||
    fail "owned historical Dolt server PID was not recorded safely"
[ -f "$owned_server_identity_file" ] && [ ! -L "$owned_server_identity_file" ] ||
    fail "owned historical Dolt server launch identity was not recorded safely"
mapfile -t owned_server_recorded_identity < "$owned_server_identity_file"
[ "${#owned_server_recorded_identity[@]}" -eq 7 ] ||
    fail "owned historical Dolt server recorded redundant or incomplete identity fields"
guard_server_pid=$(cat "$owned_server_pid_file")
migration_pid_belongs_to_workspace \
    "$guard_server_pid" "$owned_server_workspace" "bd-migration-owned-dolt-server.pid" ||
    fail "recorded historical Dolt server PID failed ownership validation"
declare -F migration_owned_process_matches_launch >/dev/null ||
    fail "owned historical Dolt server has no exact argv validator"

owned_identity_original="$tmp/owned-server.identity.original"
owned_identity_tampered="$tmp/owned-server.identity.tampered"
/bin/cp -f -- "$owned_server_identity_file" "$owned_identity_original"
awk 'NR == 2 { $0 = $0 + 1 } { print }' \
    "$owned_identity_original" > "$owned_identity_tampered"
mv -f -- "$owned_identity_tampered" "$owned_server_identity_file"
if migration_pid_belongs_to_workspace \
    "$guard_server_pid" "$owned_server_workspace" "bd-migration-owned-dolt-server.pid"; then
    fail "owned historical Dolt server trusted a mismatched process start time"
fi
/bin/cp -f -- "$owned_identity_original" "$owned_server_identity_file"
migration_pid_belongs_to_workspace \
    "$guard_server_pid" "$owned_server_workspace" "bd-migration-owned-dolt-server.pid" ||
    fail "restored owned historical Dolt identity was rejected"

(
    cd "$owned_server_workspace/.beads/dolt"
    exec -a "dolt sql-server --host 127.0.0.1 --port $owned_server_port" sleep 600
) &
spoof_server_pid=$!
for _ in $(seq 1 50); do
    [ "$(readlink "/proc/$spoof_server_pid/cwd" 2>/dev/null || true)" = \
        "$owned_server_workspace/.beads/dolt" ] && break
    sleep 0.02
done
spoof_server_accepted=false
if migration_owned_process_matches_launch \
    "$spoof_server_pid" "$owned_server_workspace" \
    "$owned_server_bin_dir/dolt" "$owned_server_port"; then
    spoof_server_accepted=true
fi
kill -9 -- "$spoof_server_pid" 2>/dev/null || true
wait "$spoof_server_pid" 2>/dev/null || true
$spoof_server_accepted &&
    fail "owned historical Dolt server accepted substring-spoofed argv"
[ "$(cat "$owned_server_mode_file")" = "$owned_server_port" ] ||
    fail "prestarted-server marker did not bind to the reserved workspace port"
[ -d "$owned_server_workspace/.beads/dolt/.dolt" ] ||
    fail "owned historical Dolt server did not initialize its data root"
grep -Fq "cwd=$owned_server_workspace/.beads/dolt args= <sql-server> <--host> <127.0.0.1> <--port> <$owned_server_port>" \
    "$owned_server_calls" || fail "owned historical Dolt server used an unsafe command or cwd"
grep -Fq "args= <--host> <127.0.0.1> <--port> <$owned_server_port> <--no-tls> <sql> <-q> <SELECT 1>" \
    "$owned_server_calls" || fail "owned historical Dolt readiness did not execute a SQL query"
if grep -Eq '^(HOME|XDG_CONFIG_HOME|DOLT_ROOT_PATH)=/production' "$owned_server_env"; then
    fail "owned historical Dolt server inherited a poisoned host environment"
fi
grep -Fq "HOME=$owned_server_workspace/.git/bd-migration-home" "$owned_server_env" ||
    fail "owned historical Dolt server did not use the isolated workspace HOME"
for expected_server_env in \
    "XDG_CONFIG_HOME=$owned_server_workspace/.git/bd-migration-home/.config" \
    "XDG_CACHE_HOME=$owned_server_workspace/.git/bd-migration-home/.cache" \
    "XDG_DATA_HOME=$owned_server_workspace/.git/bd-migration-home/.local/share" \
    "XDG_STATE_HOME=$owned_server_workspace/.git/bd-migration-home/.local/state" \
    "XDG_RUNTIME_DIR=$owned_server_workspace/.git/bd-migration-runtime" \
    "TMPDIR=$owned_server_workspace/.git/bd-migration-tmp"; do
    grep -Fq "$expected_server_env" "$owned_server_env" ||
        fail "owned historical Dolt server did not isolate $expected_server_env"
done
owned_schema_json=$(PATH="$owned_server_bin_dir:$PATH" \
    migration_owned_dolt_sql \
        "$owned_server_workspace" smoke \
        "SELECT value AS schema_version FROM config WHERE \`key\` = 'schema_version'") ||
    fail "read-only owned-server SQL query failed"
[ "$(jq -r '.rows[0].schema_version' <<< "$owned_schema_json")" = "9" ] ||
    fail "read-only owned-server SQL query did not preserve JSON output"
if PATH="$owned_server_bin_dir:$PATH" migration_owned_dolt_sql \
    "$owned_server_workspace" smoke 'SELECT DOLT_COMMIT()' >/dev/null 2>&1; then
    fail "read-only owned-server SQL helper accepted a mutating statement"
fi
grep -Fq "args= <--host> <127.0.0.1> <--port> <$owned_server_port> <--no-tls> <--use-db> <smoke> <sql> <-r> <json> <-q> <SELECT value AS schema_version FROM config WHERE \`key\` = 'schema_version'>" \
    "$owned_server_calls" || fail "read-only owned-server SQL used an unsafe connection shape"

owned_server_bd_env=$(bd_in "$owned_server_workspace" "$env_probe_bin")
grep -Fqx 'BEADS_DOLT_AUTO_START=0' <<< "$owned_server_bd_env" ||
    fail "bd_in did not disable auto-start for the prestarted historical server"
if ! stop_dolt_server "$owned_server_workspace"; then
    fail "could not stop the owned historical Dolt server"
fi
guard_server_pid=""
[ ! -e "$owned_server_pid_file" ] && [ ! -L "$owned_server_pid_file" ] ||
    fail "owned historical Dolt server PID marker survived shutdown"
[ ! -e "$owned_server_identity_file" ] && [ ! -L "$owned_server_identity_file" ] ||
    fail "owned historical Dolt server identity marker survived shutdown"
[ "$(cat "$owned_server_mode_file")" = "$owned_server_port" ] ||
    fail "prestarted-server mode was lost across a deliberate server stop"
grep -Fqx 'BEADS_DOLT_AUTO_START=0' \
    <<< "$(bd_in "$owned_server_workspace" "$env_probe_bin")" ||
    fail "bd_in re-enabled auto-start after a prestarted server stopped"
if PATH="$owned_server_bin_dir:$PATH" migration_owned_dolt_sql \
    "$owned_server_workspace" smoke \
    "SELECT value AS schema_version FROM config WHERE \`key\` = 'schema_version'" \
    >/dev/null 2>&1; then
    fail "read-only owned-server SQL trusted a stopped server"
fi
if ! PATH="$owned_server_bin_dir:$PATH" \
    start_owned_migration_dolt_server "$owned_server_workspace"; then
    fail "owned historical Dolt server did not restart"
fi
guard_server_pid=$(cat "$owned_server_pid_file")
[ "$(grep -c 'args= <init>' "$owned_server_calls")" -eq 1 ] ||
    fail "owned historical Dolt restart reinitialized an existing data root"
cleanup_workspace "$owned_server_workspace" ||
    fail "could not clean up the owned historical Dolt server workspace"
guard_server_pid=""
[ ! -e "$owned_server_workspace" ] ||
    fail "owned historical Dolt server workspace survived verified cleanup"

owned_server_final_failure_workspace=$(new_workspace) ||
    fail "could not create an owned-server final-validation workspace"
touch "$owned_server_bin_dir/fail-final-validation"
final_validation_succeeded=false
if PATH="$owned_server_bin_dir:$PATH" \
    start_owned_migration_dolt_server "$owned_server_final_failure_workspace"; then
    final_validation_succeeded=true
fi
rm -f "$owned_server_bin_dir/fail-final-validation"
final_validation_pid=$(cat "$owned_server_bin_dir/last-server-pid")
final_validation_live=false
kill -0 "$final_validation_pid" 2>/dev/null && final_validation_live=true
final_validation_markers=false
for final_marker in \
    "$owned_server_final_failure_workspace/.git/bd-migration-owned-dolt-server.pid" \
    "$owned_server_final_failure_workspace/.git/bd-migration-owned-dolt-server.identity" \
    "$owned_server_final_failure_workspace/.git/bd-migration-prestarted-server"; do
    if [ -e "$final_marker" ] || [ -L "$final_marker" ]; then
        final_validation_markers=true
    fi
done
cleanup_workspace "$owned_server_final_failure_workspace" ||
    fail "could not clean up the final-validation failure workspace"
$final_validation_succeeded &&
    fail "owned historical Dolt server accepted failed final validation"
$final_validation_live &&
    fail "failed final validation left an owned historical Dolt server live"
$final_validation_markers &&
    fail "failed final validation left owned-server trust markers"

owned_server_capture_failure_workspace=$(new_workspace) ||
    fail "could not create an owned-server capture-failure workspace"
capture_failure_succeeded=false
if (
    PATH="$owned_server_bin_dir:$PATH"
    migration_capture_owned_process_identity() { return 1; }
    start_owned_migration_dolt_server "$owned_server_capture_failure_workspace"
) >/dev/null 2>&1; then
    capture_failure_succeeded=true
fi
capture_failure_pid=$(cat "$owned_server_bin_dir/last-server-pid")
capture_failure_live=false
if kill -0 "$capture_failure_pid" 2>/dev/null; then
    capture_failure_live=true
    kill -9 -- "$capture_failure_pid" 2>/dev/null || true
fi
capture_failure_markers=false
for capture_failure_marker in \
    "$owned_server_capture_failure_workspace/.git/bd-migration-owned-dolt-server.pid" \
    "$owned_server_capture_failure_workspace/.git/bd-migration-owned-dolt-server.identity"; do
    if [ -e "$capture_failure_marker" ] || [ -L "$capture_failure_marker" ]; then
        capture_failure_markers=true
    fi
done
cleanup_workspace "$owned_server_capture_failure_workspace" ||
    fail "could not clean up the owned-server capture-failure workspace"
$capture_failure_succeeded &&
    fail "owned-server launch succeeded without a durable full identity"
$capture_failure_live &&
    fail "failed owned-server identity capture orphaned the launched process"
$capture_failure_markers &&
    fail "failed owned-server identity capture published trust markers"

owned_server_publish_failure_workspace=$(new_workspace) ||
    fail "could not create an owned-server publication-failure workspace"
publication_failure_succeeded=false
if (
    PATH="$owned_server_bin_dir:$PATH"
    migration_publish_owned_process_identity() {
        local ws="$1"
        local identity_name="$2"
        local -n identity_ref="$identity_name"
        printf '%s\n' "${identity_ref[@]}" > \
            "$ws/.git/bd-migration-owned-dolt-server.identity"
        printf '%s\n' "${identity_ref[0]}" > \
            "$ws/.git/bd-migration-owned-dolt-server.pid"
        return 1
    }
    start_owned_migration_dolt_server "$owned_server_publish_failure_workspace"
) >/dev/null 2>&1; then
    publication_failure_succeeded=true
fi
publication_failure_pid=$(cat "$owned_server_bin_dir/last-server-pid")
publication_failure_live=false
kill -0 "$publication_failure_pid" 2>/dev/null && publication_failure_live=true
publication_failure_markers=false
for publication_failure_marker in \
    "$owned_server_publish_failure_workspace/.git/bd-migration-owned-dolt-server.pid" \
    "$owned_server_publish_failure_workspace/.git/bd-migration-owned-dolt-server.identity"; do
    if [ -e "$publication_failure_marker" ] || [ -L "$publication_failure_marker" ]; then
        publication_failure_markers=true
    fi
done
cleanup_workspace "$owned_server_publish_failure_workspace" ||
    fail "could not clean up the owned-server publication-failure workspace"
$publication_failure_succeeded &&
    fail "owned-server launch accepted a failed identity publication"
$publication_failure_live &&
    fail "failed owned-server identity publication orphaned the launched process"
$publication_failure_markers &&
    fail "failed owned-server identity publication retained committed trust markers"

owned_server_rollback_failure_workspace=$(new_workspace) ||
    fail "could not create an owned-server rollback-failure workspace"
touch "$owned_server_bin_dir/fail-final-validation"
rollback_failure_output=$(
    {
        PATH="$owned_server_bin_dir:$PATH"
        migration_signal_owned_process() { return 1; }
        start_owned_migration_dolt_server "$owned_server_rollback_failure_workspace"
    } 2>&1
) && fail "owned-server rollback failure unexpectedly reported success"
rm -f "$owned_server_bin_dir/fail-final-validation"
rollback_failure_pid=$(cat \
    "$owned_server_rollback_failure_workspace/.git/bd-migration-owned-dolt-server.pid")
guard_server_pid="$rollback_failure_pid"
kill -0 "$rollback_failure_pid" 2>/dev/null ||
    fail "rollback cleanup failure lost the accounted owned server"
[ -f "$owned_server_rollback_failure_workspace/.git/bd-migration-owned-dolt-server.identity" ] ||
    fail "rollback cleanup failure lost the owned-server identity marker"
migration_pid_belongs_to_workspace \
    "$rollback_failure_pid" "$owned_server_rollback_failure_workspace" \
    "bd-migration-owned-dolt-server.pid" ||
    fail "rollback cleanup failure left an unverifiable owned server"
grep -Fq 'rollback failed' <<< "$rollback_failure_output" ||
    fail "owned-server rollback cleanup failure was not reported"
cleanup_workspace "$owned_server_rollback_failure_workspace" ||
    fail "could not clean up the accounted rollback-failure workspace"
guard_server_pid=""

ignored_cleanup_workspace=$(new_workspace) ||
    fail "could not create an ignored-cleanup reporting workspace"
ignored_cleanup_snapshots=$(mktemp -d /tmp/bd-snapshots-XXXXXX) ||
    fail "could not create ignored-cleanup snapshot evidence"
printf 'snapshot evidence\n' > "$ignored_cleanup_snapshots/before.json"
ignored_cleanup_result=$(bash -c '
    set -euo pipefail
    export MIGRATION_TEST_RUN_LIBRARY_ONLY=1
    source "$1"
    migration_run_activate_workspace "$2" "$3"
    cleanup_workspace() { return 1; }
    if migration_run_record_result_after_cleanup \
        "$2" "$3" "v0.62.0 → candidate" "BLOCKED" "earlier failure"; then
        exit 1
    fi
    printf "%s\n%s\n%s\n" \
        "${RESULT_STATUSES[-1]}" "${RESULT_DETAILS[-1]}" \
        "$MIGRATION_RUN_ACTIVE_WORKSPACE"
' migration-report-probe "$SCRIPT_DIR/run.sh" \
    "$ignored_cleanup_workspace" "$ignored_cleanup_snapshots") ||
    fail "cleanup refusal did not override the earlier result and retain evidence"
mapfile -t ignored_cleanup_lines <<< "$ignored_cleanup_result"
[ "${ignored_cleanup_lines[0]}" = "BLOCKED" ] &&
    [[ "${ignored_cleanup_lines[1]}" == \
        "could not prove isolated workspace cleanup; preserved at "* ]] &&
    [ -z "${ignored_cleanup_lines[2]:-}" ] &&
    [ -f "$ignored_cleanup_snapshots/before.json" ] ||
    fail "cleanup refusal did not override the earlier result and retain evidence"
cleanup_workspace "$ignored_cleanup_workspace" ||
    fail "could not clean up the ignored-cleanup reporting workspace"
rm -rf -- "$ignored_cleanup_snapshots"

signal_cleanup_state="$tmp/signal-cleanup.state"
(
    exec bash -c '
        set -euo pipefail
        export MIGRATION_TEST_RUN_LIBRARY_ONLY=1
        export PATH="$2:$PATH"
        source "$1"
        migration_run_install_cleanup_traps
        ws=$(new_workspace)
        snapshots=$(mktemp -d /tmp/bd-snapshots-XXXXXX)
        migration_run_activate_workspace "$ws" "$snapshots"
        start_owned_migration_dolt_server "$ws"
        pid=$(cat "$ws/.git/bd-migration-owned-dolt-server.pid")
        printf "%s\n%s\n" "$ws" "$pid" > "$3.tmp"
        mv -f -- "$3.tmp" "$3"
        while :; do sleep 1; done
    ' migration-signal-probe "$SCRIPT_DIR/run.sh" \
        "$owned_server_bin_dir" "$signal_cleanup_state"
) &
signal_cleanup_runner=$!
for _ in $(seq 1 200); do
    [ -s "$signal_cleanup_state" ] && break
    kill -0 "$signal_cleanup_runner" 2>/dev/null || break
    sleep 0.02
done
[ -s "$signal_cleanup_state" ] || {
    kill -9 -- "$signal_cleanup_runner" 2>/dev/null || true
    wait "$signal_cleanup_runner" 2>/dev/null || true
    fail "signal-cleanup subprocess did not become ready"
}
mapfile -t signal_cleanup_identity < "$signal_cleanup_state"
signal_cleanup_workspace="${signal_cleanup_identity[0]}"
signal_cleanup_server_pid="${signal_cleanup_identity[1]}"
kill -TERM -- "$signal_cleanup_runner"
signal_cleanup_status=0
wait "$signal_cleanup_runner" || signal_cleanup_status=$?
[ "$signal_cleanup_status" -eq 143 ] ||
    fail "signal-cleanup subprocess returned $signal_cleanup_status, want 143"
kill -0 "$signal_cleanup_server_pid" 2>/dev/null &&
    fail "signal cleanup left the owned historical Dolt server running"
[ ! -e "$signal_cleanup_workspace" ] ||
    fail "signal cleanup left the active migration workspace behind"

owned_server_failure_workspace=$(new_workspace) ||
    fail "could not create an owned-server failure workspace"
touch "$owned_server_bin_dir/fail-sql"
if PATH="$owned_server_bin_dir:$PATH" \
    MIGRATION_DOLT_READY_ATTEMPTS=2 MIGRATION_DOLT_READY_DELAY=0 \
    start_owned_migration_dolt_server "$owned_server_failure_workspace"; then
    fail "owned historical Dolt server accepted failed SQL readiness"
fi
rm -f "$owned_server_bin_dir/fail-sql"
[ ! -e "$owned_server_failure_workspace/.git/bd-migration-owned-dolt-server.pid" ] &&
    [ ! -e "$owned_server_failure_workspace/.git/bd-migration-prestarted-server" ] ||
    fail "failed SQL readiness left owned-server trust markers"
cleanup_workspace "$owned_server_failure_workspace" ||
    fail "could not clean up the failed owned-server workspace"

owned_server_exit_workspace=$(new_workspace) ||
    fail "could not create an owned-server early-exit workspace"
touch "$owned_server_bin_dir/fail-server"
if PATH="$owned_server_bin_dir:$PATH" \
    start_owned_migration_dolt_server "$owned_server_exit_workspace"; then
    fail "owned historical Dolt server accepted an exited sql-server process"
fi
rm -f "$owned_server_bin_dir/fail-server"
[ ! -e "$owned_server_exit_workspace/.git/bd-migration-owned-dolt-server.pid" ] &&
    [ ! -e "$owned_server_exit_workspace/.git/bd-migration-prestarted-server" ] ||
    fail "early sql-server exit left owned-server trust markers"
cleanup_workspace "$owned_server_exit_workspace" ||
    fail "could not clean up the early-exit owned-server workspace"

owned_server_crash_workspace=$(new_workspace) ||
    fail "could not create an owned-server crash workspace"
if ! PATH="$owned_server_bin_dir:$PATH" \
    start_owned_migration_dolt_server "$owned_server_crash_workspace"; then
    fail "could not start the owned historical Dolt crash fixture"
fi
guard_server_pid=$(cat \
    "$owned_server_crash_workspace/.git/bd-migration-owned-dolt-server.pid")
kill -9 -- "$guard_server_pid" 2>/dev/null || true
wait "$guard_server_pid" 2>/dev/null || true
guard_server_pid=""
cleanup_workspace "$owned_server_crash_workspace" ||
    fail "cleanup stranded a workspace after its owned Dolt server exited"
[ ! -e "$owned_server_crash_workspace" ] ||
    fail "crashed owned-server workspace survived port-verified cleanup"

tampered_mode_workspace=$(new_workspace) ||
    fail "could not create a prestarted-marker tamper workspace"
printf '29999\n' > "$tampered_mode_workspace/.git/bd-migration-prestarted-server"
if bd_in "$tampered_mode_workspace" /bin/true; then
    fail "bd_in trusted a prestarted-server marker for another port"
fi
rm -f "$tampered_mode_workspace/.git/bd-migration-prestarted-server"
ln -s /dev/null "$tampered_mode_workspace/.git/bd-migration-prestarted-server"
if bd_in "$tampered_mode_workspace" /bin/true; then
    fail "bd_in followed a prestarted-server marker symlink"
fi
rm -f "$tampered_mode_workspace/.git/bd-migration-prestarted-server"
cleanup_workspace "$tampered_mode_workspace" ||
    fail "could not clean up the prestarted-marker tamper workspace"

tampered_pid_workspace=$(new_workspace) ||
    fail "could not create an owned-PID tamper workspace"
tampered_pid_external_cwd="$tmp/owned-pid-external-cwd"
mkdir -p "$tampered_pid_workspace/.beads/dolt" "$tampered_pid_external_cwd"
tampered_pid_port=$(cat "$tampered_pid_workspace/.git/bd-migration-server-port")
(
    cd "$tampered_pid_external_cwd"
    exec -a "dolt sql-server --host 127.0.0.1 --port $tampered_pid_port" sleep 600
) &
guard_server_pid=$!
for _ in $(seq 1 50); do
    if [ "$(readlink "/proc/$guard_server_pid/cwd" 2>/dev/null || true)" = \
        "$tampered_pid_external_cwd" ]; then
        break
    fi
    sleep 0.02
done
printf '%s\n' "$guard_server_pid" > \
    "$tampered_pid_workspace/.git/bd-migration-owned-dolt-server.pid"
if cleanup_workspace "$tampered_pid_workspace"; then
    fail "cleanup trusted an owned-server PID rooted outside its workspace"
fi
[ -d "$tampered_pid_workspace" ] ||
    fail "cleanup deleted a workspace after owned-server PID validation failed"
kill -0 "$guard_server_pid" 2>/dev/null || {
    guard_server_pid=""
    fail "cleanup killed a process after owned-server PID validation failed"
}
kill -9 -- "$guard_server_pid" 2>/dev/null || true
wait "$guard_server_pid" 2>/dev/null || true
guard_server_pid=""
rm -f "$tampered_pid_workspace/.git/bd-migration-owned-dolt-server.pid"
cleanup_workspace "$tampered_pid_workspace" ||
    fail "could not clean up the rejected owned-PID workspace safely"

port_unknown_ws="$tmp/port-workspace-unknown-occupancy"
mkdir -p "$port_unknown_ws/.git"
if (
    migration_server_port_in_use() { return 2; }
    reserve_migration_server_port "$port_unknown_ws"
); then
    fail "historical server port reservation treated unknown occupancy as free"
fi
[ ! -e "$port_unknown_ws/.git/bd-migration-server-port" ] &&
    [ ! -e "$port_unknown_ws/.git/bd-migration-server-port-lock" ] ||
    fail "failed historical server port reservation left workspace markers"

runtime_bin_dir="$tmp/runtime-bin"
mkdir -p "$runtime_bin_dir"
cat > "$runtime_bin_dir/dolt" <<'EOF'
#!/bin/bash
printf 'dolt version %s\n' "${FAKE_DOLT_VERSION:-unknown}"
EOF
chmod +x "$runtime_bin_dir/dolt"
if ! PATH="$runtime_bin_dir:$PATH" FAKE_DOLT_VERSION=2.1.8 \
    verify_strict_historical_runtime v0.57.0; then
    fail "qualified v0.57.0 Dolt runtime was rejected"
fi
if PATH="$runtime_bin_dir:$PATH" FAKE_DOLT_VERSION=2.1.9 \
    verify_strict_historical_runtime v0.57.0 >/dev/null 2>&1; then
    fail "unqualified v0.57.0 Dolt runtime was accepted"
fi
if ! PATH="$runtime_bin_dir:$PATH" FAKE_DOLT_VERSION=1.84.0 \
    verify_strict_historical_runtime v0.62.0; then
    fail "qualified v0.62.0 Dolt runtime was rejected"
fi
if PATH="$runtime_bin_dir:$PATH" FAKE_DOLT_VERSION=1.84.1 \
    verify_strict_historical_runtime v0.62.0 >/dev/null 2>&1; then
    fail "unqualified v0.62.0 Dolt runtime was accepted"
fi
verify_strict_historical_runtime v0.49.6 ||
    fail "a release without an external Dolt requirement was rejected"

printf 'not the release archive' > "$tmp/archive.tar.gz"
if OS=linux ARCH=amd64 verify_release_archive v0.49.6 "$tmp/archive.tar.gz" >/dev/null 2>&1; then
    fail "tampered release archive was accepted"
fi
if OS=linux ARCH=amd64 verify_release_archive v0.55.4 "$tmp/archive.tar.gz" >/dev/null 2>&1; then
    fail "tampered v0.55.4 release archive was accepted"
fi
if OS=linux ARCH=amd64 verify_release_archive v0.57.0 "$tmp/archive.tar.gz" >/dev/null 2>&1; then
    fail "tampered v0.57.0 release archive was accepted"
fi
if OS=linux ARCH=amd64 verify_release_archive v0.62.0 "$tmp/archive.tar.gz" >/dev/null 2>&1; then
    fail "tampered v0.62.0 release archive was accepted"
fi
if OS=linux ARCH=amd64 verify_release_archive v0.63.3 "$tmp/archive.tar.gz" >/dev/null 2>&1; then
    fail "tampered v0.63.3 release archive was accepted"
fi

strict_fixture_has_expected_features v0.49.6 epic task bug dependency standalone closed label comment ||
    fail "complete source fixture was rejected"
strict_fixture_has_expected_features v0.55.4 epic task bug dependency standalone closed label comment ||
    fail "complete v0.55.4 source fixture was rejected"
strict_fixture_has_expected_features v0.57.0 epic task bug dependency standalone closed label comment ||
    fail "complete v0.57.0 source fixture was rejected"
strict_fixture_has_expected_features v0.62.0 epic task bug dependency standalone closed label comment ||
    fail "complete v0.62.0 source fixture was rejected"
strict_fixture_has_expected_features v0.63.3 epic task bug dependency standalone closed label comment ||
    fail "complete v0.63.3 source fixture was rejected"
if strict_fixture_has_expected_features v0.49.6 epic task bug standalone closed label >/dev/null 2>&1; then
    fail "source fixture without dependency was accepted"
fi
if strict_fixture_has_expected_features v0.49.6 epic task bug dependency standalone closed label >/dev/null 2>&1; then
    fail "source fixture without comment was accepted"
fi
if strict_fixture_has_expected_features v0.62.0 epic task bug standalone closed label comment >/dev/null 2>&1; then
    fail "v0.62.0 source fixture without dependency was accepted"
fi
if strict_fixture_has_expected_features v0.62.0 epic task bug dependency standalone closed label >/dev/null 2>&1; then
    fail "v0.62.0 source fixture without comment was accepted"
fi

# A strict fixture must construct its canonical parent relationship directly.
# Keep this hermetic: a fake bd proves a clean cache cannot introduce a probe,
# and that a qualified release which rejects --parent blocks fixture creation.
(
    strict_fixture_ws="$tmp/strict-fixture-workspace"
    strict_fixture_bin_dir="$tmp/strict-fixture-bin"
    strict_fixture_bin="$strict_fixture_bin_dir/bd"
    strict_fixture_calls="$strict_fixture_bin_dir/calls"
    GATES_CACHE="$tmp/strict-fixture-cache/feature-gates.cache"
    mkdir -p "$strict_fixture_ws" "$strict_fixture_bin_dir" "$(dirname "$GATES_CACHE")"
    cat > "$strict_fixture_bin" <<'EOF'
#!/bin/bash
set -euo pipefail
bin_dir="$(cd "$(dirname "$0")" && pwd)"
printf ' <%s>' "$@" >> "$bin_dir/calls"
printf '\n' >> "$bin_dir/calls"

case "${1:-}" in
    create)
        if [ -e "$bin_dir/reject-parent" ] && [[ " $* " == *" --parent "* ]]; then
            exit 71
        fi
        case "$*" in
            *"__probe__"*) printf '%s\n' 'strict-probe' ;;
            *"Migration epic"*) printf '%s\n' 'strict-epic' ;;
            *"Migration task alpha"*) printf '%s\n' 'strict-task' ;;
            *"Migration bug beta"*) printf '%s\n' 'strict-bug' ;;
            *"Standalone detailed task"*) printf '%s\n' 'strict-standalone' ;;
            *"Already closed issue"*) printf '%s\n' 'strict-closed' ;;
            *) exit 72 ;;
        esac
        ;;
    dep|close|label|comments)
        ;;
    *)
        exit 73
        ;;
esac
EOF
    chmod +x "$strict_fixture_bin"

    STRICT_MODE=true
    create_dataset "$strict_fixture_ws" "$strict_fixture_bin" v0.62.0 >/dev/null ||
        fail "strict fixture construction rejected direct parent creation"
    [ "${DATASET_FEATURES[*]}" = "epic task bug dependency standalone closed label comment" ] ||
        fail "strict fixture construction changed the public eight-feature manifest"
    [ ! -e "$GATES_CACHE" ] ||
        fail "strict fixture construction consulted or populated the feature-gate cache"
    if grep -Fq '__probe__' "$strict_fixture_calls"; then
        fail "strict fixture construction created a parent-support probe"
    fi
    grep -Fq '<create> <--silent> <--title> <Migration task alpha> <--type> <task> <--priority> <1> <--parent> <strict-epic>' \
        "$strict_fixture_calls" ||
        fail "strict fixture did not construct its canonical task with --parent directly"

    printf '%s\n' 'v0.62.0:parent_child=no' > "$GATES_CACHE"
    : > "$strict_fixture_calls"
    create_dataset "$strict_fixture_ws" "$strict_fixture_bin" v0.62.0 >/dev/null ||
        fail "strict fixture construction trusted a negative feature-cache entry"
    grep -Fq '<create> <--silent> <--title> <Migration task alpha> <--type> <task> <--priority> <1> <--parent> <strict-epic>' \
        "$strict_fixture_calls" ||
        fail "strict fixture omitted --parent after a negative feature-cache entry"
    if grep -Fq '__probe__' "$strict_fixture_calls"; then
        fail "strict fixture probed after a negative feature-cache entry"
    fi
    [ "$(cat "$GATES_CACHE")" = 'v0.62.0:parent_child=no' ] ||
        fail "strict fixture construction rewrote the feature-gate cache"

    : > "$strict_fixture_calls"
    touch "$strict_fixture_bin_dir/reject-parent"
    if create_dataset "$strict_fixture_ws" "$strict_fixture_bin" v0.62.0 >/dev/null 2>&1; then
        fail "strict fixture ignored a qualified release rejecting --parent"
    fi
    if grep -Fq '__probe__' "$strict_fixture_calls"; then
        fail "strict unsupported-parent failure ran a feature probe"
    fi
)

declare -gA DATASET_IDS=(
    [epic]="old-epic"
    [standalone]="old-standalone"
    [closed]="old-closed"
    [task]="old-task"
    [bug]="old-bug"
)
printf '%s\n' '[
  {"id":"old-epic","title":"Migration epic","description":"Epic for migration testing","priority":2,"issue_type":"epic","status":"open"},
  {"id":"old-standalone","title":"Standalone detailed task","description":"This task has a detailed description for fidelity testing.","notes":"Historical notes must survive the upgrade.","design":"Historical design must survive the upgrade.","acceptance_criteria":"Historical acceptance criteria must survive the upgrade.","external_ref":"legacy-upgrade-42","status":"open"},
  {"id":"old-closed","title":"Already closed issue","status":"closed"},
  {"id":"old-task","title":"Implement core feature","status":"open","parent":"old-epic","dependencies":[{"id":"old-epic","dependency_type":"parent-child"}],"labels":["urgent"],"comments":[{"author":"legacy-author","text":"Historical comment must survive the upgrade."}]},
  {"id":"old-bug","title":"Fix migration blocker","status":"open","dependencies":[{"id":"old-task","dependency_type":"blocks"}]}
]' > "$tmp/fixture.json"
strict_snapshot_has_expected_fixture v0.49.6 "$tmp/fixture.json" ||
    fail "exact v0.49.6 source fixture was rejected"
strict_snapshot_has_expected_fixture v0.55.4 "$tmp/fixture.json" ||
    fail "exact v0.55.4 source fixture was rejected"
strict_snapshot_has_expected_fixture v0.57.0 "$tmp/fixture.json" ||
    fail "exact v0.57.0 source fixture was rejected"
strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture.json" ||
    fail "exact v0.62.0 source fixture was rejected"
strict_snapshot_has_expected_fixture v0.63.3 "$tmp/fixture.json" ||
    fail "exact v0.63.3 source fixture was rejected"
jq 'map(if .id == "old-task" then del(.parent) else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-parentless-task.json"
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-parentless-task.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture with a parentless canonical task was accepted"
fi
jq 'map(if .id == "old-task" then
        .dependencies[0].dependency_type = "blocks"
    else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-wrong-parent-child-type.json"
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-wrong-parent-child-type.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture with the wrong parent-child dependency type was accepted"
fi
jq 'map(if .id == "old-bug" then
        .dependencies[0].dependency_type = "related"
    else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-wrong-blocks-type.json"
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-wrong-blocks-type.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture with the wrong blocks dependency type was accepted"
fi
jq 'map(if .id == "old-task" then
        .dependencies += [{"id":"old-closed","dependency_type":"related"}]
    else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-extra-task-dependency.json"
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-extra-task-dependency.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture with an extra task dependency was accepted"
fi
jq 'map(if .id == "old-bug" then
        .dependencies += [{"id":"old-closed","dependency_type":"related"}]
    else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-extra-bug-dependency.json"
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-extra-bug-dependency.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture with an extra bug dependency was accepted"
fi
for issue_id in old-epic old-standalone old-closed; do
    jq --arg id "$issue_id" 'map(if .id == $id then
            .dependencies = [{"id":"old-task","dependency_type":"related"}]
        else . end)' \
        "$tmp/fixture.json" > "$tmp/fixture-unexpected-$issue_id-dependency.json"
    if strict_snapshot_has_expected_fixture \
        v0.62.0 "$tmp/fixture-unexpected-$issue_id-dependency.json" >/dev/null 2>&1; then
        fail "v0.62.0 source fixture accepted an unexpected dependency on $issue_id"
    fi
done
jq 'map(select(.id != "old-epic"))' "$tmp/fixture.json" > "$tmp/fixture-four-items.json"
for version in v0.49.6 v0.55.4 v0.57.0 v0.62.0 v0.63.3; do
    if strict_snapshot_has_expected_fixture "$version" "$tmp/fixture-four-items.json" >/dev/null 2>&1; then
        fail "$version source fixture with four items was accepted"
    fi
done
jq '. + [{"id":"old-extra","title":"Unexpected extra issue"}]' \
    "$tmp/fixture.json" > "$tmp/fixture-six-items.json"
for version in v0.49.6 v0.55.4 v0.57.0 v0.62.0 v0.63.3; do
    if strict_snapshot_has_expected_fixture "$version" "$tmp/fixture-six-items.json" >/dev/null 2>&1; then
        fail "$version source fixture with six items was accepted"
    fi
done
jq 'map(if .id == "old-epic" then .issue_type = "task" else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-wrong-epic.json"
for version in v0.49.6 v0.55.4 v0.57.0 v0.62.0 v0.63.3; do
    if strict_snapshot_has_expected_fixture "$version" "$tmp/fixture-wrong-epic.json" >/dev/null 2>&1; then
        fail "$version source fixture with an inexact epic was accepted"
    fi
done
jq 'map(if .id == "old-standalone" then .external_ref = null else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-missing-rich-field.json"
if strict_snapshot_has_expected_fixture v0.49.6 "$tmp/fixture-missing-rich-field.json" >/dev/null 2>&1; then
    fail "source fixture without the exact rich fields was accepted"
fi
if strict_snapshot_has_expected_fixture v0.55.4 "$tmp/fixture-missing-rich-field.json" >/dev/null 2>&1; then
    fail "v0.55.4 source fixture without the exact rich fields was accepted"
fi
if strict_snapshot_has_expected_fixture v0.57.0 "$tmp/fixture-missing-rich-field.json" >/dev/null 2>&1; then
    fail "v0.57.0 source fixture without the exact rich fields was accepted"
fi
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-missing-rich-field.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture without the exact rich fields was accepted"
fi
if strict_snapshot_has_expected_fixture v0.63.3 "$tmp/fixture-missing-rich-field.json" >/dev/null 2>&1; then
    fail "v0.63.3 source fixture without the exact rich fields was accepted"
fi
jq 'map(if .id == "old-task" then .labels = [] else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-missing-label.json"
if strict_snapshot_has_expected_fixture v0.49.6 "$tmp/fixture-missing-label.json" >/dev/null 2>&1; then
    fail "source fixture without the exact label was accepted"
fi
if strict_snapshot_has_expected_fixture v0.55.4 "$tmp/fixture-missing-label.json" >/dev/null 2>&1; then
    fail "v0.55.4 source fixture without the exact label was accepted"
fi
if strict_snapshot_has_expected_fixture v0.57.0 "$tmp/fixture-missing-label.json" >/dev/null 2>&1; then
    fail "v0.57.0 source fixture without the exact label was accepted"
fi
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-missing-label.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture without the exact label was accepted"
fi
if strict_snapshot_has_expected_fixture v0.63.3 "$tmp/fixture-missing-label.json" >/dev/null 2>&1; then
    fail "v0.63.3 source fixture without the exact label was accepted"
fi
jq 'map(if .id == "old-bug" then .dependencies = [] else . end)' \
    "$tmp/fixture.json" > "$tmp/fixture-missing-dependency.json"
if strict_snapshot_has_expected_fixture v0.49.6 "$tmp/fixture-missing-dependency.json" >/dev/null 2>&1; then
    fail "source fixture without the exact dependency was accepted"
fi
if strict_snapshot_has_expected_fixture v0.55.4 "$tmp/fixture-missing-dependency.json" >/dev/null 2>&1; then
    fail "v0.55.4 source fixture without the exact dependency was accepted"
fi
if strict_snapshot_has_expected_fixture v0.57.0 "$tmp/fixture-missing-dependency.json" >/dev/null 2>&1; then
    fail "v0.57.0 source fixture without the exact dependency was accepted"
fi
if strict_snapshot_has_expected_fixture v0.62.0 "$tmp/fixture-missing-dependency.json" >/dev/null 2>&1; then
    fail "v0.62.0 source fixture without the exact dependency was accepted"
fi
if strict_snapshot_has_expected_fixture v0.63.3 "$tmp/fixture-missing-dependency.json" >/dev/null 2>&1; then
    fail "v0.63.3 source fixture without the exact dependency was accepted"
fi

mkdir -p "$tmp/source/.beads"
printf 'original sqlite bytes' > "$tmp/source/.beads/beads.db"
printf 'original sqlite config' > "$tmp/source/.beads/config.yaml"
source_manifest=$(classic_sqlite_artifact_manifest "$tmp/source/.beads")
mv -f "$tmp/source/.beads/beads.db" "$tmp/source/.beads/beads.db.pre-migration"
mv -f "$tmp/source/.beads/config.yaml" "$tmp/source/.beads/config.yaml.pre-migration"
verify_retained_sqlite_source "$tmp/source/.beads" "$source_manifest" ||
    fail "unchanged retained SQLite source was rejected"
printf 'corruption' >> "$tmp/source/.beads/config.yaml.pre-migration"
if verify_retained_sqlite_source "$tmp/source/.beads" "$source_manifest" >/dev/null 2>&1; then
    fail "mutated retained SQLite source was accepted"
fi

mkdir -p "$tmp/collision/.beads"
printf 'current' > "$tmp/collision/.beads/beads.db"
printf 'current config' > "$tmp/collision/.beads/config.yaml"
printf 'stale config' > "$tmp/collision/.beads/config.yaml.pre-migration"
if preserve_sqlite_source_artifacts "$tmp/collision" >/dev/null 2>&1; then
    fail "stale rollback collision was accepted"
fi
[ "$(cat "$tmp/collision/.beads/beads.db")" = "current" ] ||
    fail "rollback collision mutated the active source"
[ ! -e "$tmp/collision/.beads/beads.db.pre-migration" ] ||
    fail "rollback preflight left a partial backup before reporting collision"

fingerprint_root="$tmp/fingerprint-source/.beads"
mkdir -p "$fingerprint_root/nested"
printf 'stable bytes' > "$fingerprint_root/nested/data"
ln -s nested/data "$fingerprint_root/data-link"
fingerprint_one=$(source_artifact_fingerprint "$fingerprint_root") ||
    fail "stable historical source could not be fingerprinted"
fingerprint_two=$(source_artifact_fingerprint "$fingerprint_root") ||
    fail "stable historical source could not be fingerprinted twice"
[ "$fingerprint_one" = "$fingerprint_two" ] ||
    fail "stable historical source produced different fingerprints"

if (
    find() { command find "$@"; return 1; }
    source_artifact_fingerprint "$fingerprint_root"
) >/dev/null 2>&1; then
    fail "historical source fingerprint ignored a failed find"
fi
if (
    stat() { return 1; }
    source_artifact_fingerprint "$fingerprint_root"
) >/dev/null 2>&1; then
    fail "historical source fingerprint ignored a failed stat"
fi
if (
    sha256_file() {
        if [ "$1" = "./nested/data" ]; then
            return 1
        fi
        sha256sum -- "$1" | awk '{print $1}'
    }
    source_artifact_fingerprint "$fingerprint_root"
) >/dev/null 2>&1; then
    fail "historical source fingerprint ignored a failed checksum"
fi
if (
    sha256_file() {
        if [[ "$1" == */bd-source-fingerprint.* ]]; then
            return 1
        fi
        sha256sum -- "$1" | awk '{print $1}'
    }
    source_artifact_fingerprint "$fingerprint_root"
) >/dev/null 2>&1; then
    fail "historical source fingerprint ignored a failed final digest"
fi
if (
    readlink() { return 1; }
    source_artifact_fingerprint "$fingerprint_root"
) >/dev/null 2>&1; then
    fail "historical source fingerprint ignored a failed readlink"
fi
mkfifo "$fingerprint_root/unsupported-fifo"
if source_artifact_fingerprint "$fingerprint_root" >/dev/null 2>&1; then
    fail "historical source fingerprint accepted a special file"
fi
rm -f "$fingerprint_root/unsupported-fifo"
printf 'changed bytes' >> "$fingerprint_root/nested/data"
fingerprint_changed=$(source_artifact_fingerprint "$fingerprint_root") ||
    fail "changed historical source could not be fingerprinted"
[ "$fingerprint_changed" != "$fingerprint_one" ] ||
    fail "historical source fingerprint ignored changed file bytes"

mkdir -p "$tmp/legacy-source/.beads/dolt/nested"
printf 'legacy table bytes' > "$tmp/legacy-source/.beads/dolt/nested/table.dat"
printf 'legacy metadata' > "$tmp/legacy-source/.beads/metadata.json"
printf 'legacy config json' > "$tmp/legacy-source/.beads/config.json"
printf 'legacy config yaml' > "$tmp/legacy-source/.beads/config.yaml"
legacy_manifest=$(legacy_dolt_artifact_manifest "$tmp/legacy-source/.beads")
preserve_legacy_dolt_source "$tmp/legacy-source" "$legacy_manifest" ||
    fail "unchanged legacy Dolt source could not be preserved"
verify_retained_legacy_dolt_source "$tmp/legacy-source/.beads" "$legacy_manifest" ||
    fail "unchanged retained legacy Dolt source was rejected"
printf 'corruption' >> "$tmp/legacy-source/.beads/legacy-dolt.pre-migration/config.yaml"
if verify_retained_legacy_dolt_source "$tmp/legacy-source/.beads" "$legacy_manifest" >/dev/null 2>&1; then
    fail "mutated retained legacy Dolt source was accepted"
fi

mkdir -p "$tmp/legacy-collision/.beads/dolt" \
    "$tmp/legacy-collision/.beads/legacy-dolt.pre-migration/dolt"
printf 'active legacy data' > "$tmp/legacy-collision/.beads/dolt/table.dat"
printf 'active metadata' > "$tmp/legacy-collision/.beads/metadata.json"
printf 'stale legacy data' > "$tmp/legacy-collision/.beads/legacy-dolt.pre-migration/dolt/table.dat"
collision_manifest=$(legacy_dolt_artifact_manifest "$tmp/legacy-collision/.beads")
if preserve_legacy_dolt_source "$tmp/legacy-collision" "$collision_manifest" >/dev/null 2>&1; then
    fail "stale legacy Dolt rollback collision was accepted"
fi
[ "$(legacy_dolt_artifact_manifest "$tmp/legacy-collision/.beads")" = "$collision_manifest" ] ||
    fail "legacy Dolt rollback collision mutated the active source"
if find "$tmp/legacy-collision/.beads" -maxdepth 1 \
    -name '.legacy-dolt.pre-migration.tmp.*' -print -quit | grep -q .; then
    fail "legacy Dolt rollback collision left a partial temporary backup"
fi

mkdir -p "$tmp/legacy-partial/.beads/dolt"
printf 'active legacy data' > "$tmp/legacy-partial/.beads/dolt/table.dat"
printf 'active metadata' > "$tmp/legacy-partial/.beads/metadata.json"
partial_manifest=$(legacy_dolt_artifact_manifest "$tmp/legacy-partial/.beads")
cp() {
    local arg
    for arg in "$@"; do
        if [[ "$arg" == */metadata.json ]]; then
            return 1
        fi
    done
    command cp "$@"
}
if preserve_legacy_dolt_source "$tmp/legacy-partial" "$partial_manifest" >/dev/null 2>&1; then
    unset -f cp
    fail "partial legacy Dolt rollback copy was accepted"
fi
unset -f cp
[ ! -e "$tmp/legacy-partial/.beads/legacy-dolt.pre-migration" ] ||
    fail "partial legacy Dolt rollback copy published an incomplete backup"
if find "$tmp/legacy-partial/.beads" -maxdepth 1 \
    -name '.legacy-dolt.pre-migration.tmp.*' -print -quit | grep -q .; then
    fail "partial legacy Dolt rollback copy left a temporary backup"
fi
[ "$(legacy_dolt_artifact_manifest "$tmp/legacy-partial/.beads")" = "$partial_manifest" ] ||
    fail "partial legacy Dolt rollback copy mutated the active source"

legacy_extra_ws="$tmp/legacy-extra"
mkdir -p "$legacy_extra_ws/.beads/dolt"
printf 'active data' > "$legacy_extra_ws/.beads/dolt/table.dat"
printf 'active metadata' > "$legacy_extra_ws/.beads/metadata.json"
legacy_extra_manifest=$(legacy_dolt_artifact_manifest "$legacy_extra_ws/.beads")
preserve_legacy_dolt_source "$legacy_extra_ws" "$legacy_extra_manifest" ||
    fail "could not create exact rollback source for extra-inventory test"
printf 'stale extra' > "$legacy_extra_ws/.beads/legacy-dolt.pre-migration/unexpected"
if verify_retained_legacy_dolt_source \
    "$legacy_extra_ws/.beads" "$legacy_extra_manifest" >/dev/null 2>&1; then
    fail "retained legacy Dolt source accepted unexpected top-level content"
fi
if preserve_legacy_dolt_source "$legacy_extra_ws" "$legacy_extra_manifest" >/dev/null 2>&1; then
    fail "legacy Dolt preservation reused a rollback source with extra content"
fi
[ "$(legacy_dolt_artifact_manifest "$legacy_extra_ws/.beads")" = "$legacy_extra_manifest" ] ||
    fail "extra rollback collision mutated the active legacy source"

legacy_race_ws="$tmp/legacy-publish-race"
legacy_race_calls="$tmp/legacy-publish-race.calls"
legacy_race_old_bin="$tmp/fake-race-old-bd"
legacy_race_candidate_bin="$tmp/fake-race-candidate-bd"
legacy_race_before="$tmp/legacy-publish-race-before.json"
mkdir -p "$legacy_race_ws/.beads/dolt"
printf 'active race data' > "$legacy_race_ws/.beads/dolt/table.dat"
printf 'active race metadata' > "$legacy_race_ws/.beads/metadata.json"
legacy_race_manifest=$(legacy_dolt_artifact_manifest "$legacy_race_ws/.beads")
printf '%s\n' '[{"id":"race-1"}]' > "$legacy_race_before"
cat > "$legacy_race_old_bin" <<'EOF'
#!/bin/bash
printf 'old:%s\n' "$*" >> "$LEGACY_RACE_CALLS"
exit 2
EOF
cat > "$legacy_race_candidate_bin" <<'EOF'
#!/bin/bash
printf 'candidate:%s\n' "$*" >> "$LEGACY_RACE_CALLS"
exit 2
EOF
chmod +x "$legacy_race_old_bin" "$legacy_race_candidate_bin"
export LEGACY_RACE_CALLS="$legacy_race_calls"
: > "$legacy_race_calls"
if (
    stop_dolt_server() { :; }
    publish_legacy_dolt_rollback() {
        local source="$1"
        local destination="$2"
        mkdir -p "$destination"
        printf 'racer sentinel' > "$destination/racer"
        command mv --no-target-directory --no-clobber --no-copy -- "$source" "$destination"
    }
    recipe_server_to_embedded \
        "$legacy_race_ws" "$legacy_race_old_bin" "$legacy_race_candidate_bin" \
        v0.55.4 "$legacy_race_before"
) >/dev/null 2>&1; then
    fail "legacy Dolt rollback publication accepted a racing destination"
fi
[ ! -s "$legacy_race_calls" ] ||
    fail "rollback publication race invoked a migration binary"
[ "$(legacy_dolt_artifact_manifest "$legacy_race_ws/.beads")" = "$legacy_race_manifest" ] ||
    fail "rollback publication race mutated the active legacy source"
[ "$(cat "$legacy_race_ws/.beads/legacy-dolt.pre-migration/racer")" = "racer sentinel" ] ||
    fail "rollback publication race replaced the competing destination"
if find "$legacy_race_ws/.beads" -maxdepth 2 \
    -name '.legacy-dolt.pre-migration.tmp.*' -print -quit | grep -q .; then
    fail "rollback publication race left a temporary copy"
fi

stop_refusal_ws="$tmp/stop-refusal-workspace"
stop_refusal_calls="$tmp/stop-refusal.calls"
mkdir -p "$stop_refusal_ws/.beads/dolt"
printf 'active stop-refusal data' > "$stop_refusal_ws/.beads/dolt/table.dat"
printf 'active stop-refusal metadata' > "$stop_refusal_ws/.beads/metadata.json"
stop_refusal_fingerprint=$(source_artifact_fingerprint "$stop_refusal_ws/.beads")
export LEGACY_RACE_CALLS="$stop_refusal_calls"
: > "$stop_refusal_calls"
if (
    stop_dolt_server() { return 1; }
    recipe_server_to_embedded \
        "$stop_refusal_ws" "$legacy_race_old_bin" "$legacy_race_candidate_bin" \
        v0.55.4 "$legacy_race_before"
) >/dev/null 2>&1; then
    fail "server bridge continued after server-stop verification failed"
fi
[ ! -s "$stop_refusal_calls" ] ||
    fail "server-stop verification failure invoked a migration binary"
[ "$(source_artifact_fingerprint "$stop_refusal_ws/.beads")" = "$stop_refusal_fingerprint" ] ||
    fail "server-stop verification failure mutated the active source"
[ ! -e "$stop_refusal_ws/.beads/legacy-dolt.pre-migration" ] ||
    fail "server-stop verification failure created a rollback tree"

private_v062_ws="$tmp/private-v062-refusal-workspace"
private_v062_effect_calls="$tmp/private-v062-refusal.effects"
private_v062_binary_calls="$tmp/private-v062-refusal.binaries"
mkdir -p "$private_v062_ws/.beads/dolt"
printf 'active private-route data' > "$private_v062_ws/.beads/dolt/table.dat"
printf 'active private-route metadata' > "$private_v062_ws/.beads/metadata.json"
private_v062_fingerprint=$(source_artifact_fingerprint "$private_v062_ws/.beads")
export LEGACY_RACE_CALLS="$private_v062_binary_calls"
: > "$private_v062_effect_calls"
: > "$private_v062_binary_calls"
private_v062_output=""
if private_v062_output=$(
    stop_dolt_server() { printf 'stop\n' >> "$private_v062_effect_calls"; }
    start_owned_migration_dolt_server() {
        printf 'start\n' >> "$private_v062_effect_calls"
    }
    preserve_legacy_dolt_source() {
        printf 'preserve\n' >> "$private_v062_effect_calls"
    }
    recipe_server_to_embedded \
        "$private_v062_ws" "$legacy_race_old_bin" "$legacy_race_candidate_bin" \
        v0.62.0 "$legacy_race_before"
); then
    fail "private server-to-embedded recipe accepted v0.62.0"
fi
grep -Fq 'v0.62.0 must use the public migration bridge' <<< "$private_v062_output" ||
    fail "private server-to-embedded recipe did not explain the v0.62.0 refusal"
[ ! -s "$private_v062_effect_calls" ] ||
    fail "private v0.62.0 recipe refusal reached a migration effect"
[ ! -s "$private_v062_binary_calls" ] ||
    fail "private v0.62.0 recipe refusal invoked a historical or candidate binary"
[ "$(source_artifact_fingerprint "$private_v062_ws/.beads")" = \
    "$private_v062_fingerprint" ] ||
    fail "private v0.62.0 recipe refusal mutated the historical source"
[ ! -e "$private_v062_ws/.beads/legacy-dolt.pre-migration" ] ||
    fail "private v0.62.0 recipe refusal created a rollback tree"

[ "$(server_bridge_strategy v0.55.4)" = "native_export" ] ||
    fail "v0.55.4 did not select its pinned server bridge strategy"
[ "$(server_bridge_strategy v0.57.0)" = "native_export_show_comments" ] ||
    fail "v0.57.0 did not select its lossless export+show server bridge strategy"
for unsupported_version in v0.56.1 v0.58.0 v0.62.0 v9.9.9; do
    if server_bridge_strategy "$unsupported_version" >/dev/null 2>&1; then
        fail "$unsupported_version unexpectedly selected a server bridge strategy"
    fi
done

unsupported_ws="$tmp/unsupported-server-bridge"
unsupported_calls="$tmp/unsupported-server-bridge.calls"
mkdir -p "$unsupported_ws/.beads/dolt"
printf 'unsupported data' > "$unsupported_ws/.beads/dolt/table.dat"
unsupported_fingerprint=$(source_artifact_fingerprint "$unsupported_ws/.beads")
export LEGACY_RACE_CALLS="$unsupported_calls"
: > "$unsupported_calls"
if recipe_server_to_embedded \
    "$unsupported_ws" "$legacy_race_old_bin" "$legacy_race_candidate_bin" \
    v0.56.1 "$legacy_race_before" >/dev/null 2>&1; then
    fail "unqualified v0.56.1 server bridge was accepted"
fi
[ ! -s "$unsupported_calls" ] ||
    fail "unqualified server bridge invoked a migration binary"
[ "$(source_artifact_fingerprint "$unsupported_ws/.beads")" = "$unsupported_fingerprint" ] ||
    fail "unqualified server bridge mutated the historical source"

RESULT_PATHS=("v0.49.6 → candidate")
RESULT_STATUSES=("MANUAL")
RESULT_DETAILS=("recipe: sqlite_to_current, 0 fidelity violations")
RESULT_RECIPES=("sqlite_to_current")
RESULT_VIOLATIONS=("0")
strict_results_match MANUAL sqlite_to_current || fail "qualified result was rejected"

cleanup_blocked_result=$(
    RESULT_PATHS=()
    RESULT_STATUSES=()
    RESULT_DETAILS=()
    RESULT_RECIPES=()
    RESULT_VIOLATIONS=()
    cleanup_workspace() { return 1; }
    record_result_after_workspace_cleanup \
        "/tmp/bd-migration-ABC123" "v0.57.0 → candidate" \
        "MANUAL" "recipe passed" "server_to_embedded" "0" || true
    printf '%s|%s|%s\n' \
        "${RESULT_STATUSES[0]}" "${RESULT_RECIPES[0]}" "${RESULT_DETAILS[0]}"
)
[[ "$cleanup_blocked_result" == BLOCKED\|\|*preserved* ]] ||
    fail "cleanup verification failure did not override a successful lane result"

RESULT_STATUSES=("SKIP")
if strict_results_match MANUAL sqlite_to_current >/dev/null 2>&1; then
    fail "SKIP result was accepted"
fi
RESULT_STATUSES=("MANUAL")
RESULT_VIOLATIONS=("1")
if strict_results_match MANUAL sqlite_to_current >/dev/null 2>&1; then
    fail "fidelity violation was accepted"
fi
RESULT_VIOLATIONS=("0")
if strict_results_match AUTO sqlite_to_current >/dev/null 2>&1; then
    fail "outcome drift was accepted"
fi
if strict_results_match MANUAL different_recipe >/dev/null 2>&1; then
    fail "recipe drift was accepted"
fi

STRICT_MODE=true
printf '%s\n' \
    '[{"id":"old-1","title":"One","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[],"labels":[],"comment_count":0}]' \
    > "$tmp/before.json"
printf '%s\n' \
    '[{"id":"old-1","title":"One","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[{"id":"invented"}],"labels":["invented"],"comment_count":1}]' \
    > "$tmp/after-invented.json"
if check_fidelity v0.49.6 "$tmp/before.json" "$tmp/after-invented.json" >/dev/null 2>&1; then
    fail "strict fidelity accepted invented collections"
fi
printf '%s\n' \
    '[{"id":"old-1","title":"One","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[],"labels":[],"comments":[{"author":"legacy-author","text":"before"}]}]' \
    > "$tmp/before-comment.json"
printf '%s\n' \
    '[{"id":"old-1","title":"One","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[],"labels":[],"comments":[{"author":"legacy-author","text":"after"}]}]' \
    > "$tmp/after-comment.json"
if check_fidelity v0.49.6 "$tmp/before-comment.json" "$tmp/after-comment.json" >/dev/null 2>&1; then
    fail "strict fidelity accepted changed comment text"
fi
printf '%s\n' \
    '[{"id":"old-task","title":"Child","description":"","priority":2,"issue_type":"task","status":"open","parent":"old-epic","dependencies":[{"id":"old-epic","dependency_type":"parent-child"}],"labels":[],"comments":[]}]' \
    > "$tmp/before-relationships.json"
printf '%s\n' \
    '[{"id":"old-task","title":"Child","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[{"depends_on_id":"old-epic","type":"parent-child"}],"labels":[],"comments":[]}]' \
    > "$tmp/after-parent-lost.json"
if check_fidelity v0.62.0 "$tmp/before-relationships.json" "$tmp/after-parent-lost.json" >/dev/null 2>&1; then
    fail "strict fidelity accepted post-upgrade parent loss"
fi
printf '%s\n' \
    '[{"id":"old-task","title":"Child","description":"","priority":2,"issue_type":"task","status":"open","parent":"old-epic","dependencies":[{"depends_on_id":"old-epic","type":"blocks"}],"labels":[],"comments":[]}]' \
    > "$tmp/after-dependency-type-drift.json"
if check_fidelity v0.62.0 "$tmp/before-relationships.json" "$tmp/after-dependency-type-drift.json" >/dev/null 2>&1; then
    fail "strict fidelity accepted dependency-type drift"
fi
printf '%s\n' \
    '[{"id":"old-task","title":"Child","description":"","priority":2,"issue_type":"task","status":"open","parent":"old-epic","dependencies":[{"depends_on_id":"old-epic","type":"parent-child"}],"labels":[],"comments":[]}]' \
    > "$tmp/after-normalized-relationships.json"
check_fidelity v0.62.0 "$tmp/before-relationships.json" "$tmp/after-normalized-relationships.json" >/dev/null ||
    fail "strict fidelity rejected equivalent historical dependency shapes"

printf '%s\n' \
    '[{"id":"old-task","title":"Child","description":"","priority":2,"issue_type":"task","status":"open","dependencies":[{"id":"old-epic","dependency_type":"blocks"}],"labels":[],"comments":[]}]' \
    > "$tmp/after-nonstrict-relationship-drift.json"
STRICT_MODE=false
check_fidelity v0.62.0 "$tmp/before-relationships.json" "$tmp/after-nonstrict-relationship-drift.json" >/dev/null ||
    fail "non-strict fidelity started enforcing parent or dependency types"
STRICT_MODE=true

snapshot_contract_ws="$tmp/snapshot-contract-workspace"
snapshot_contract_bin="$tmp/fake-snapshot-contract-bd"
mkdir -p "$snapshot_contract_ws"
cat > "$snapshot_contract_bin" <<'EOF'
#!/bin/bash
case "$1" in
    list)
        case "$SNAPSHOT_LIST_SHAPE" in
            array) printf '%s\n' '[{"id":"old-1","title":"One"}]' ;;
            empty-id) printf '%s\n' '[{"id":"","title":"One"}]' ;;
            object) printf '%s\n' '{"id":"old-1","title":"One"}' ;;
            invalid) printf '%s\n' 'not JSON' ;;
            *) exit 2 ;;
        esac
        [ "$SNAPSHOT_FAIL_COMMAND" != "list" ]
        ;;
    show)
        printf '%s\n' '[{"id":"old-1","title":"One"}]'
        [ "$SNAPSHOT_FAIL_COMMAND" != "show" ]
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$snapshot_contract_bin"
DATASET_IDS=([one]="old-1")

assert_strict_snapshot_rejected() {
    local name="$1"
    local list_shape="$2"
    local fail_command="$3"
    export SNAPSHOT_LIST_SHAPE="$list_shape"
    export SNAPSHOT_FAIL_COMMAND="$fail_command"
    if capture_snapshot "$snapshot_contract_ws" "$snapshot_contract_bin" \
        > "$tmp/rejected-snapshot.json" 2>/dev/null; then
        fail "strict snapshot accepted $name"
    fi
}

assert_strict_snapshot_rejected "valid list JSON from a nonzero command" array list
assert_strict_snapshot_rejected "valid show JSON from a nonzero command" array show
assert_strict_snapshot_rejected "malformed list JSON" invalid none
assert_strict_snapshot_rejected "a list JSON object" object none
assert_strict_snapshot_rejected "a list item with an empty id" empty-id none

blocker_contract_ws="$tmp/blocker-contract-workspace"
blocker_contract_bin="$tmp/fake-blocker-contract-bd"
mkdir -p "$blocker_contract_ws"
cat > "$blocker_contract_bin" <<'EOF'
#!/bin/bash
case "$1" in
    blocked)
        printf '%s\n' '[{"id":"old-bug"}]'
        [ "$BLOCKER_FAIL_COMMAND" != "blocked" ]
        ;;
    ready)
        if [ -e "$BLOCKER_STATE" ]; then
            printf '%s\n' '[{"id":"old-bug"}]'
        else
            printf '%s\n' '[{"id":"old-task"}]'
        fi
        [ "$BLOCKER_FAIL_COMMAND" != "ready" ]
        ;;
    close)
        : > "$BLOCKER_STATE"
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$blocker_contract_bin"
DATASET_FEATURES=("dependency")
DATASET_IDS=([task]="old-task" [bug]="old-bug")
export BLOCKER_STATE="$tmp/blocker-contract-closed"

assert_blocker_command_failures_counted() {
    local command="$1"
    local expected_violations="$2"
    local violations=0
    export BLOCKER_FAIL_COMMAND="$command"
    rm -f "$BLOCKER_STATE"
    check_blocker_paths "$blocker_contract_ws" "$blocker_contract_bin" \
        >/dev/null 2>&1 || violations=$?
    [ "$violations" -eq "$expected_violations" ] ||
        fail "nonzero $command produced $violations blocker violations, want $expected_violations"
}

assert_blocker_command_failures_counted blocked 1
assert_blocker_command_failures_counted ready 2

jsonl_contract_snapshot="$tmp/jsonl-contract-snapshot.json"
jsonl_contract_file="$tmp/jsonl-contract.jsonl"
printf '%s\n' '[{"id":"jsonl-1"},{"id":"jsonl-2"}]' > "$jsonl_contract_snapshot"
printf '%s\n' '{"id":"jsonl-2"}' '{"id":"jsonl-1"}' > "$jsonl_contract_file"
migration_jsonl_matches_snapshot "$jsonl_contract_file" "$jsonl_contract_snapshot" ||
    fail "valid reordered historical JSONL did not match its source snapshot"

assert_jsonl_contract_rejected() {
    local name="$1"
    shift
    printf '%s\n' "$@" > "$jsonl_contract_file"
    if migration_jsonl_matches_snapshot \
        "$jsonl_contract_file" "$jsonl_contract_snapshot" >/dev/null 2>&1; then
        fail "historical JSONL contract accepted $name"
    fi
}

assert_jsonl_contract_rejected "malformed JSON" 'not JSON'
assert_jsonl_contract_rejected "a blank record" '{"id":"jsonl-1"}' '   ' '{"id":"jsonl-2"}'
assert_jsonl_contract_rejected "a duplicate id" '{"id":"jsonl-1"}' '{"id":"jsonl-1"}'
assert_jsonl_contract_rejected "a missing id" '{"title":"missing"}' '{"id":"jsonl-2"}'
assert_jsonl_contract_rejected "an empty id" '{"id":""}' '{"id":"jsonl-2"}'
assert_jsonl_contract_rejected "an array record" '[{"id":"jsonl-1"}]' '{"id":"jsonl-2"}'
assert_jsonl_contract_rejected "an extra id" '{"id":"jsonl-1"}' '{"id":"jsonl-2"}' '{"id":"jsonl-3"}'
assert_jsonl_contract_rejected "a missing source id" '{"id":"jsonl-1"}'
printf '%s\n' '{"id":"jsonl-1"} {"id":"jsonl-2"}' > "$jsonl_contract_file"
if migration_jsonl_matches_snapshot \
    "$jsonl_contract_file" "$jsonl_contract_snapshot" >/dev/null 2>&1; then
    fail "historical JSONL contract accepted two records on one line"
fi

v062_derived_before="$tmp/v062-derived-before.json"
v062_derived_export="$tmp/v062-derived-export.jsonl"
v062_derived_show="$tmp/v062-derived-show.jsonl"
v062_changed_export="$tmp/v062-changed-export.jsonl"
v062_changed_show="$tmp/v062-changed-show.jsonl"
printf '%s\n' '[
  {"id":"v62-epic","title":"Legacy epic","issue_type":"epic","epic_closeable":true,"epic_closed_children":1,"epic_total_children":2,"comments":[]}
]' > "$v062_derived_before"
printf '%s\n' \
    '{"id":"v62-epic","title":"Legacy epic","issue_type":"epic","dependency_count":0,"comment_count":0}' \
    > "$v062_derived_export"
printf '%s\n' \
    '{"id":"v62-epic","title":"Legacy epic","issue_type":"epic","epic_closeable":false,"epic_closed_children":0,"epic_total_children":3,"comments":[]}' \
    > "$v062_derived_show"

v057_export_matches_snapshot \
    "$v062_derived_export" "$v062_derived_before" v0.62.0 ||
    fail "v0.62.0 export comparison rejected differences limited to derived epic fields"
if v057_export_matches_snapshot \
    "$v062_derived_export" "$v062_derived_before" v0.57.0 >/dev/null 2>&1; then
    fail "v0.57.0 export comparison normalized v0.62.0-only derived epic fields"
fi
v057_export_and_show_comments_agree \
    "$v062_derived_export" "$v062_derived_show" \
    "$v062_derived_before" v0.62.0 ||
    fail "v0.62.0 show comparison rejected differences limited to derived epic fields"
if v057_export_and_show_comments_agree \
    "$v062_derived_export" "$v062_derived_show" \
    "$v062_derived_before" v0.57.0 >/dev/null 2>&1; then
    fail "v0.57.0 show comparison normalized v0.62.0-only derived epic fields"
fi

jq -c '.title = "Changed epic"' \
    "$v062_derived_export" > "$v062_changed_export"
if v057_export_matches_snapshot \
    "$v062_changed_export" "$v062_derived_before" v0.62.0 >/dev/null 2>&1; then
    fail "v0.62.0 export comparison normalized a non-derived title change"
fi
jq -c '.title = "Changed epic"' \
    "$v062_derived_show" > "$v062_changed_show"
if v057_export_and_show_comments_agree \
    "$v062_derived_export" "$v062_changed_show" \
    "$v062_derived_before" v0.62.0 >/dev/null 2>&1; then
    fail "v0.62.0 show comparison normalized a non-derived title change"
fi

# v0.57.0's native export preserves issue/label/dependency records and a
# comment_count, but omits comment bodies. Its release-specific bridge must use
# `export -o PATH`, enrich each exported ID from `show ID --json`, and finish
# validating the list/export/show consensus before invoking the candidate.
v057_before="$tmp/v057-before.json"
v057_old_bin="$tmp/fake-v0.57.0-bd"
v057_candidate_bin="$tmp/fake-v0.57.0-candidate-bd"
v057_old_calls="$tmp/v057-old.calls"
v057_candidate_calls="$tmp/v057-candidate.calls"
printf '%s\n' '[
  {"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"id":"v57-bug","dependency_type":"parent-child"}],"comments":[{"id":7,"issue_id":"v57-task","author":"legacy-author","text":"v0.57 comment body","created_at":"2025-01-02T03:04:05Z"}]},
  {"id":"v57-bug","title":"Legacy bug","dependencies":[{"id":"v57-task","dependency_type":"blocks"}],"comments":[]}
]' > "$v057_before"
cat > "$v057_old_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$V057_OLD_CALLS"

write_valid_export() {
    printf '%s\n' \
        '{"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"issue_id":"v57-task","depends_on_id":"v57-bug","type":"parent-child","metadata":"{}"}],"dependency_count":0,"comment_count":1}' \
        '{"id":"v57-bug","title":"Legacy bug","dependencies":[{"issue_id":"v57-bug","depends_on_id":"v57-task","type":"blocks","metadata":"{}"}],"dependency_count":1,"comment_count":0}' \
        > "$1"
}

write_valid_task_show() {
    printf '%s\n' '[{"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"id":"v57-bug","dependency_type":"parent-child"}],"comments":[{"id":7,"issue_id":"v57-task","author":"legacy-author","text":"v0.57 comment body","created_at":"2025-01-02T03:04:05Z"}]}]'
}

write_valid_bug_show() {
    printf '%s\n' '[{"id":"v57-bug","title":"Legacy bug","dependencies":[{"id":"v57-task","dependency_type":"blocks"}],"comments":[]}]'
}

case "$1" in
    export)
        # v0.57.0 removed v0.55.4's --format flag. Pin the actual release CLI.
        [ "$#" -eq 3 ] && [ "$2" = "-o" ] && [ -n "$3" ] || exit 2
        case "${V057_MODE:-valid}" in
            export-missing)
                printf '%s\n' \
                    '{"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"issue_id":"v57-task","depends_on_id":"v57-bug","type":"parent-child","metadata":"{}"}],"dependency_count":0,"comment_count":1}' \
                    > "$3"
                ;;
            export-extra)
                write_valid_export "$3"
                printf '%s\n' \
                    '{"id":"v57-extra","title":"Unexpected","comment_count":0}' \
                    >> "$3"
                ;;
            export-duplicate)
                write_valid_export "$3"
                printf '%s\n' \
                    '{"id":"v57-task","title":"Duplicate","comment_count":1}' \
                    >> "$3"
                ;;
            export-core-changed)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Changed task"/' "$3"
                ;;
            export-label-changed)
                write_valid_export "$3"
                sed -i 's/"labels":\["urgent"\]/"labels":[]/' "$3"
                ;;
            export-dependency-changed)
                write_valid_export "$3"
                sed -i 's/"depends_on_id":"v57-task"/"depends_on_id":"v57-other"/' "$3"
                ;;
            export-unsupported-field)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Legacy task","quality_score":0.5/' "$3"
                ;;
            export-unsupported-creator)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Legacy task","creator":{"type":"human","id":"legacy"}/' "$3"
                ;;
            export-unsupported-validations)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Legacy task","validations":[{"validator":"legacy"}]/' "$3"
                ;;
            export-unsupported-holder)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Legacy task","holder":"legacy-agent"/' "$3"
                ;;
            export-unsupported-closed-session)
                write_valid_export "$3"
                sed -i 's/"title":"Legacy task"/"title":"Legacy task","closed_by_session":"legacy-session"/' "$3"
                ;;
            export-dependency-metadata)
                write_valid_export "$3"
                sed -i 's/"metadata":"{}"/"metadata":"legacy-edge-data"/' "$3"
                ;;
            *)
                write_valid_export "$3"
                ;;
        esac
        ;;
    show)
        shift
        id=""
        json=false
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --json) json=true ;;
                --id=*)
                    [ -z "$id" ] || exit 2
                    id="${1#--id=}"
                    ;;
                --id)
                    shift
                    [ "$#" -gt 0 ] && [ -z "$id" ] || exit 2
                    id="$1"
                    ;;
                --*) exit 2 ;;
                *)
                    [ -z "$id" ] || exit 2
                    id="$1"
                    ;;
            esac
            shift
        done
        $json && [ -n "$id" ] || exit 2
        if [ "$id" = "v57-task" ]; then
            case "${V057_MODE:-valid}" in
                show-fail)
                    write_valid_task_show
                    exit 1
                    ;;
                show-malformed) printf '%s\n' 'not JSON' ;;
                show-object) printf '%s\n' '{"id":"v57-task","title":"Legacy task","comments":[]}' ;;
                show-empty) printf '%s\n' '[]' ;;
                show-wrong-id) printf '%s\n' '[{"id":"v57-other","comments":[]}]' ;;
                show-duplicate)
                    printf '%s\n' '[{"id":"v57-task","comments":[]},{"id":"v57-task","comments":[]}]'
                    ;;
                show-core-changed)
                    printf '%s\n' '[{"id":"v57-task","title":"Changed task","labels":["urgent"],"dependencies":[{"id":"v57-bug","dependency_type":"parent-child"}],"comments":[{"id":7,"issue_id":"v57-task","author":"legacy-author","text":"v0.57 comment body","created_at":"2025-01-02T03:04:05Z"}]}]'
                    ;;
                comment-missing)
                    printf '%s\n' '[{"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"id":"v57-bug","dependency_type":"parent-child"}],"comments":[]}]'
                    ;;
                comment-changed)
                    printf '%s\n' '[{"id":"v57-task","title":"Legacy task","labels":["urgent"],"dependencies":[{"id":"v57-bug","dependency_type":"parent-child"}],"comments":[{"id":7,"issue_id":"v57-task","author":"legacy-author","text":"changed body","created_at":"2025-01-02T03:04:05Z"}]}]'
                    ;;
                *) write_valid_task_show ;;
            esac
        elif [ "$id" = "v57-bug" ]; then
            write_valid_bug_show
        else
            exit 2
        fi
        ;;
    *)
        exit 2
        ;;
esac
EOF
cat > "$v057_candidate_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$V057_CANDIDATE_CALLS"
[ "$1" = "init" ] || exit 2
for arg in "$@"; do
    if [ "$arg" = "--from-jsonl" ]; then
        jq -se '
            length == 2 and
            ([.[].id] | sort) == ["v57-bug", "v57-task"] and
            ([.[] | select(.id == "v57-task")] | length) == 1 and
            (first(.[] | select(.id == "v57-task")) |
                .comment_count == 1 and
                (.comments | length) == 1 and
                .comments[0].author == "legacy-author" and
                .comments[0].text == "v0.57 comment body") and
            (first(.[] | select(.id == "v57-bug")) |
                .comment_count == 0 and ((.comments // []) | length) == 0)
        ' .beads/issues.jsonl >/dev/null
        exit
    fi
done
exit 1
EOF
chmod +x "$v057_old_bin" "$v057_candidate_bin"

prepare_v057_workspace() {
    local ws="$1"
    mkdir -p "$ws/.beads/dolt"
    printf 'v0.57 legacy Dolt bytes' > "$ws/.beads/dolt/table.dat"
    printf 'v0.57 legacy metadata' > "$ws/.beads/metadata.json"
    printf '%s\n' '{"id":"v57-task","title":"Original passive export"}' \
        > "$ws/.beads/issues.jsonl"
}

v057_happy_ws="$tmp/v057-happy-workspace"
prepare_v057_workspace "$v057_happy_ws"
v057_happy_manifest=$(legacy_dolt_artifact_manifest "$v057_happy_ws/.beads")
v057_happy_original_jsonl=$(sha256_file "$v057_happy_ws/.beads/issues.jsonl")
export V057_MODE=valid
export V057_OLD_CALLS="$v057_old_calls"
export V057_CANDIDATE_CALLS="$v057_candidate_calls"
: > "$v057_old_calls"
: > "$v057_candidate_calls"
if ! (
    stop_dolt_server() { :; }
    recipe_server_to_embedded \
        "$v057_happy_ws" "$v057_old_bin" "$v057_candidate_bin" \
        v0.57.0 "$v057_before"
) >/dev/null; then
    fail "v0.57.0 export+show bridge did not produce a lossless candidate import"
fi
grep -E "^export -o $v057_happy_ws/\.beads/\.issues\.jsonl\.migration\.tmp\." \
    "$v057_old_calls" >/dev/null ||
    fail "v0.57.0 bridge did not use its release-specific native export syntax"
if grep -q -- '--format' "$v057_old_calls"; then
    fail "v0.57.0 bridge used the unsupported historical --format flag"
fi
[ "$(grep -c '^show ' "$v057_old_calls")" -eq 2 ] ||
    fail "v0.57.0 bridge did not issue exactly one show query per exported id"
grep '^show ' "$v057_old_calls" | grep 'v57-task' >/dev/null ||
    fail "v0.57.0 bridge did not enrich v57-task"
grep '^show ' "$v057_old_calls" | grep 'v57-bug' >/dev/null ||
    fail "v0.57.0 bridge did not enrich v57-bug"
jq -se '
    length == 2 and
    (first(.[] | select(.id == "v57-task")) |
        .comment_count == 1 and
        (.comments | length) == 1 and
        .comments[0].author == "legacy-author" and
        .comments[0].text == "v0.57 comment body")
' "$v057_happy_ws/.beads/issues.jsonl" >/dev/null ||
    fail "v0.57.0 bridge did not publish the show-enriched comment body"
verify_retained_legacy_dolt_source \
    "$v057_happy_ws/.beads" "$v057_happy_manifest" ||
    fail "v0.57.0 bridge did not retain an exact rollback source"
[ "$(sha256_file "$v057_happy_ws/.beads/legacy-dolt.pre-migration/issues.jsonl")" = \
    "$v057_happy_original_jsonl" ] ||
    fail "v0.57.0 bridge did not retain the original passive JSONL"

assert_v057_bridge_rejected() {
    local mode="$1"
    local description="$2"
    local ws="$tmp/v057-reject-$mode"
    local before_manifest original_jsonl after_manifest

    prepare_v057_workspace "$ws"
    before_manifest=$(legacy_dolt_artifact_manifest "$ws/.beads")
    original_jsonl=$(sha256_file "$ws/.beads/issues.jsonl")
    export V057_MODE="$mode"
    : > "$v057_old_calls"
    : > "$v057_candidate_calls"

    if (
        stop_dolt_server() { :; }
        recipe_server_to_embedded \
            "$ws" "$v057_old_bin" "$v057_candidate_bin" \
            v0.57.0 "$v057_before"
    ) >/dev/null 2>&1; then
        fail "v0.57.0 bridge accepted $description"
    fi
    [ ! -s "$v057_candidate_calls" ] ||
        fail "$description invoked the candidate before lossless extraction completed"
    after_manifest=$(legacy_dolt_artifact_manifest "$ws/.beads") ||
        fail "$description removed the active legacy source"
    [ "$after_manifest" = "$before_manifest" ] ||
        fail "$description mutated the active legacy source"
    [ "$(sha256_file "$ws/.beads/issues.jsonl")" = "$original_jsonl" ] ||
        fail "$description replaced the original passive JSONL"
    verify_retained_legacy_dolt_source "$ws/.beads" "$before_manifest" ||
        fail "$description did not leave an exact rollback source"
    if find "$ws/.beads" -maxdepth 1 \
        \( -name '.issues.jsonl.migration.tmp.*' -o \
           -name '.issues.jsonl.enriched.tmp.*' -o \
           -name '.issues.jsonl.show.tmp.*' \) \
        -print -quit | grep -q .; then
        fail "$description left an extraction staging file"
    fi
    case "$mode" in
        export-*)
            if grep -q '^show ' "$v057_old_calls"; then
                fail "$description invoked show after export inventory validation failed"
            fi
            ;;
    esac
}

assert_v057_bridge_rejected export-missing "an export missing a listed id"
assert_v057_bridge_rejected export-extra "an export with an unlisted id"
assert_v057_bridge_rejected export-duplicate "an export with a duplicate id"
assert_v057_bridge_rejected export-core-changed "an export with changed core issue data"
assert_v057_bridge_rejected export-label-changed "an export with changed labels"
assert_v057_bridge_rejected export-dependency-changed "an export with changed dependencies"
assert_v057_bridge_rejected export-unsupported-field "an export with candidate-unsupported issue data"
assert_v057_bridge_rejected export-unsupported-creator "an export with a candidate-unsupported creator"
assert_v057_bridge_rejected export-unsupported-validations "an export with candidate-unsupported validations"
assert_v057_bridge_rejected export-unsupported-holder "an export with a candidate-unsupported holder"
assert_v057_bridge_rejected export-unsupported-closed-session "an export with a candidate-unsupported close session"
assert_v057_bridge_rejected export-dependency-metadata "an export with candidate-unsupported dependency metadata"
assert_v057_bridge_rejected show-fail "a nonzero show command with valid-looking JSON"
assert_v057_bridge_rejected show-malformed "malformed show JSON"
assert_v057_bridge_rejected show-object "a show object instead of a one-item array"
assert_v057_bridge_rejected show-empty "a show result missing its requested id"
assert_v057_bridge_rejected show-wrong-id "a show result with a mismatched id"
assert_v057_bridge_rejected show-duplicate "a show result with a duplicate id"
assert_v057_bridge_rejected show-core-changed "a show result with changed core issue data"
assert_v057_bridge_rejected comment-missing "a show result missing an exported comment"
assert_v057_bridge_rejected comment-changed "a show result with changed comment text"

server_export_ws="$tmp/server-export-workspace"
server_export_calls="$tmp/server-export-calls"
server_export_old_bin="$tmp/fake-v0.55.4-bd"
server_export_candidate_bin="$tmp/fake-candidate-bd"
server_export_before="$tmp/server-export-before.json"
mkdir -p "$server_export_ws/.beads/dolt"
printf 'legacy Dolt data' > "$server_export_ws/.beads/dolt/table.dat"
printf 'legacy metadata' > "$server_export_ws/.beads/metadata.json"
printf '%s\n' '{"id":"old-task","title":"stale passive export"}' \
    > "$server_export_ws/.beads/issues.jsonl"
server_export_original_jsonl=$(sha256_file "$server_export_ws/.beads/issues.jsonl")
: > "$server_export_calls"
printf '%s\n' '[{"id":"old-task","title":"Implement core feature"}]' > "$server_export_before"
cat > "$server_export_old_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SERVER_EXPORT_CALLS"
case "$1" in
    list)
        printf '%s\n' '[{"id":"old-task","title":"Implement core feature","comment_count":1}]'
        ;;
    export)
        [ "$#" -eq 5 ] && [ "$2" = "--format" ] && [ "$3" = "jsonl" ] &&
            [ "$4" = "-o" ] && [ -n "$5" ] || exit 2
        printf '%s\n' '{"id":"old-task","title":"Implement core feature","comments":[{"author":"legacy-author","text":"Historical comment must survive the upgrade."}]}' > "$5"
        ;;
    *)
        exit 2
        ;;
esac
EOF
cat > "$server_export_candidate_bin" <<'EOF'
#!/bin/bash
[ "$1" = "init" ] || exit 2
for arg in "$@"; do
    if [ "$arg" = "--from-jsonl" ]; then
        jq -e 'select(.id == "old-task") | any(.comments[]?; .author == "legacy-author" and .text == "Historical comment must survive the upgrade.")' \
            .beads/issues.jsonl >/dev/null
        exit
    fi
done
exit 1
EOF
chmod +x "$server_export_old_bin" "$server_export_candidate_bin"
export SERVER_EXPORT_CALLS="$server_export_calls"
if ! (
    stop_dolt_server() { :; }
    recipe_server_to_embedded \
        "$server_export_ws" "$server_export_old_bin" "$server_export_candidate_bin" \
        v0.55.4 "$server_export_before"
) >/dev/null; then
    fail "server-to-embedded recipe lost comments exposed only by historical export"
fi
grep -E "^export --format jsonl -o $server_export_ws/\.beads/\.issues\.jsonl\.migration\.tmp\." \
    "$server_export_calls" >/dev/null ||
    fail "server-to-embedded recipe did not invoke historical export with an output path"
jq -e 'select(.id == "old-task") | any(.comments[]?; .author == "legacy-author" and .text == "Historical comment must survive the upgrade.")' \
    "$server_export_ws/.beads/issues.jsonl" >/dev/null ||
    fail "server-to-embedded JSONL export omitted the historical comment body"
[ "$(sha256_file "$server_export_ws/.beads/legacy-dolt.pre-migration/issues.jsonl")" = \
    "$server_export_original_jsonl" ] ||
    fail "server-to-embedded recipe did not retain the original passive JSONL"

server_export_fail_ws="$tmp/server-export-failure-workspace"
server_export_fail_old_bin="$tmp/fake-failing-v0.55.4-bd"
server_export_fail_candidate_bin="$tmp/fake-unexpected-candidate-bd"
server_export_fail_candidate_calls="$tmp/server-export-failure-candidate-calls"
mkdir -p "$server_export_fail_ws/.beads/dolt"
printf 'active legacy Dolt data' > "$server_export_fail_ws/.beads/dolt/table.dat"
printf 'active legacy metadata' > "$server_export_fail_ws/.beads/metadata.json"
server_export_fail_manifest=$(legacy_dolt_artifact_manifest "$server_export_fail_ws/.beads")
cat > "$server_export_fail_old_bin" <<'EOF'
#!/bin/bash
[ "$1" = "export" ] || exit 2
exit 1
EOF
cat > "$server_export_fail_candidate_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$SERVER_EXPORT_FAIL_CANDIDATE_CALLS"
exit 1
EOF
chmod +x "$server_export_fail_old_bin" "$server_export_fail_candidate_bin"
export SERVER_EXPORT_FAIL_CANDIDATE_CALLS="$server_export_fail_candidate_calls"
: > "$server_export_fail_candidate_calls"
if (
    stop_dolt_server() { :; }
    recipe_server_to_embedded \
        "$server_export_fail_ws" "$server_export_fail_old_bin" \
        "$server_export_fail_candidate_bin" v0.55.4 "$server_export_before"
) >/dev/null; then
    fail "server-to-embedded recipe accepted a failed historical export"
fi
server_export_fail_after=$(legacy_dolt_artifact_manifest "$server_export_fail_ws/.beads") ||
    fail "failed historical export removed the active legacy source"
[ "$server_export_fail_after" = "$server_export_fail_manifest" ] ||
    fail "failed historical export mutated the active legacy source"
[ ! -s "$server_export_fail_candidate_calls" ] ||
    fail "failed historical export still invoked the candidate"
verify_retained_legacy_dolt_source \
    "$server_export_fail_ws/.beads" "$server_export_fail_manifest" ||
    fail "failed historical export corrupted the retained rollback source"

server_export_malformed_ws="$tmp/server-export-malformed-workspace"
server_export_malformed_old_bin="$tmp/fake-malformed-v0.55.4-bd"
mkdir -p "$server_export_malformed_ws/.beads/dolt"
printf 'active malformed-test data' > "$server_export_malformed_ws/.beads/dolt/table.dat"
printf 'active malformed-test metadata' > "$server_export_malformed_ws/.beads/metadata.json"
server_export_malformed_manifest=$(legacy_dolt_artifact_manifest "$server_export_malformed_ws/.beads")
cat > "$server_export_malformed_old_bin" <<'EOF'
#!/bin/bash
[ "$1" = "export" ] && [ "$4" = "-o" ] && [ -n "$5" ] || exit 2
printf '%s\n' 'not JSONL' > "$5"
EOF
chmod +x "$server_export_malformed_old_bin"
: > "$server_export_fail_candidate_calls"
if (
    stop_dolt_server() { :; }
    recipe_server_to_embedded \
        "$server_export_malformed_ws" "$server_export_malformed_old_bin" \
        "$server_export_fail_candidate_bin" v0.55.4 "$server_export_before"
) >/dev/null; then
    fail "server-to-embedded recipe accepted malformed historical JSONL"
fi
[ ! -s "$server_export_fail_candidate_calls" ] ||
    fail "malformed historical export still invoked the candidate"
[ "$(legacy_dolt_artifact_manifest "$server_export_malformed_ws/.beads")" = \
    "$server_export_malformed_manifest" ] ||
    fail "malformed historical export mutated the active legacy source"
[ ! -e "$server_export_malformed_ws/.beads/issues.jsonl" ] ||
    fail "malformed historical export was published"
if find "$server_export_malformed_ws/.beads" -maxdepth 1 \
    -name '.issues.jsonl.migration.tmp.*' -print -quit | grep -q .; then
    fail "malformed historical export left a temporary file"
fi

server_export_symlink_ws="$tmp/server-export-symlink-workspace"
server_export_symlink_target="$tmp/server-export-symlink-target"
mkdir -p "$server_export_symlink_ws/.beads/dolt"
printf 'active symlink-test data' > "$server_export_symlink_ws/.beads/dolt/table.dat"
printf 'external sentinel' > "$server_export_symlink_target"
ln -s "$server_export_symlink_target" "$server_export_symlink_ws/.beads/issues.jsonl"
if recipe_server_to_embedded \
    "$server_export_symlink_ws" "$server_export_fail_old_bin" \
    "$server_export_fail_candidate_bin" v0.55.4 "$server_export_before" \
    >/dev/null 2>&1; then
    fail "server-to-embedded recipe accepted a symlinked JSONL destination"
fi
[ "$(cat "$server_export_symlink_target")" = "external sentinel" ] ||
    fail "server-to-embedded recipe followed a symlinked JSONL destination"
[ ! -e "$server_export_symlink_ws/.beads/legacy-dolt.pre-migration" ] ||
    fail "unsafe JSONL destination was detected only after rollback mutation"

rollback_corruption_ws="$tmp/rollback-corruption-workspace"
rollback_corruption_old_bin="$tmp/fake-rollback-corrupting-v0.55.4-bd"
rollback_corruption_candidate_calls="$tmp/rollback-corruption-candidate.calls"
mkdir -p "$rollback_corruption_ws/.beads/dolt"
printf 'active corruption-test data' > "$rollback_corruption_ws/.beads/dolt/table.dat"
printf 'active corruption-test metadata' > "$rollback_corruption_ws/.beads/metadata.json"
printf 'active corruption-test config' > "$rollback_corruption_ws/.beads/config.yaml"
cat > "$rollback_corruption_old_bin" <<'EOF'
#!/bin/bash
[ "$1" = "export" ] && [ "$4" = "-o" ] && [ -n "$5" ] || exit 2
printf '%s\n' '{"id":"old-task","title":"Implement core feature"}' > "$5"
printf 'corrupted during export' >> .beads/legacy-dolt.pre-migration/metadata.json
EOF
chmod +x "$rollback_corruption_old_bin"
export SERVER_EXPORT_FAIL_CANDIDATE_CALLS="$rollback_corruption_candidate_calls"
: > "$rollback_corruption_candidate_calls"
if (
    stop_dolt_server() { :; }
    recipe_server_to_embedded \
        "$rollback_corruption_ws" "$rollback_corruption_old_bin" \
        "$server_export_fail_candidate_bin" v0.55.4 "$server_export_before"
) >/dev/null 2>&1; then
    fail "server-to-embedded recipe accepted rollback corruption during export"
fi
[ ! -s "$rollback_corruption_candidate_calls" ] ||
    fail "rollback corruption during export still invoked the candidate"
[ "$(cat "$rollback_corruption_ws/.beads/metadata.json")" = \
    "active corruption-test metadata" ] ||
    fail "rollback corruption caused active metadata deletion"
[ "$(cat "$rollback_corruption_ws/.beads/config.yaml")" = \
    "active corruption-test config" ] ||
    fail "rollback corruption changed active config"
[ "$(cat "$rollback_corruption_ws/.beads/dolt/table.dat")" = \
    "active corruption-test data" ] ||
    fail "rollback corruption changed active Dolt data"

metadata_removal_ws="$tmp/metadata-removal-failure-workspace"
metadata_removal_old_calls="$tmp/metadata-removal-old.calls"
metadata_removal_candidate_calls="$tmp/metadata-removal-candidate.calls"
mkdir -p "$metadata_removal_ws/.beads/dolt"
printf 'active removal-test data' > "$metadata_removal_ws/.beads/dolt/table.dat"
printf 'active removal-test metadata' > "$metadata_removal_ws/.beads/metadata.json"
export SERVER_EXPORT_CALLS="$metadata_removal_old_calls"
export SERVER_EXPORT_FAIL_CANDIDATE_CALLS="$metadata_removal_candidate_calls"
: > "$metadata_removal_old_calls"
: > "$metadata_removal_candidate_calls"
if (
    stop_dolt_server() { :; }
    rm() {
        local arg
        for arg in "$@"; do
            if [[ "$arg" == */metadata.json ]]; then
                return 1
            fi
        done
        command rm "$@"
    }
    recipe_server_to_embedded \
        "$metadata_removal_ws" "$server_export_old_bin" \
        "$server_export_fail_candidate_bin" v0.55.4 "$server_export_before"
) >/dev/null; then
    fail "server-to-embedded recipe ignored active metadata removal failure"
fi
[ ! -s "$metadata_removal_candidate_calls" ] ||
    fail "active metadata removal failure still invoked the candidate"
[ "$(cat "$metadata_removal_ws/.beads/metadata.json")" = \
    "active removal-test metadata" ] ||
    fail "active metadata removal failure changed metadata"
[ "$(cat "$metadata_removal_ws/.beads/dolt/table.dat")" = \
    "active removal-test data" ] ||
    fail "active metadata removal failure changed Dolt data"

probe_list_ws="$tmp/probe-list-workspace"
probe_list_bin="$tmp/fake-probe-list-bd"
mkdir -p "$probe_list_ws"
cat > "$probe_list_bin" <<'EOF'
#!/bin/bash
[ "$1" = "list" ] || exit 2
printf '%s' "$PROBE_LIST_OUTPUT"
exit "$PROBE_LIST_EXIT"
EOF
chmod +x "$probe_list_bin"

assert_probe_list_rejected() {
    local name="$1"
    local output="$2"
    local exit_code="$3"
    export PROBE_LIST_OUTPUT="$output"
    export PROBE_LIST_EXIT="$exit_code"
    if candidate_list_has_nonempty_issue_ids "$probe_list_ws" "$probe_list_bin"; then
        fail "candidate list probe accepted $name"
    fi
}

assert_probe_list_rejected "invalid output" 'not JSON' 0
assert_probe_list_rejected "valid JSON from a nonzero command" '[{"id":"old-1"}]' 1
assert_probe_list_rejected "an empty array" '[]' 0
assert_probe_list_rejected "a JSON object" '{"id":"old-1"}' 0
assert_probe_list_rejected "an empty issue id" '[{"id":""}]' 0
assert_probe_list_rejected "a non-string issue id" '[{"id":7}]' 0
assert_probe_list_rejected "multiple JSON documents" $'[{"id":"old-1"}]\n[{"id":"old-2"}]' 0
export PROBE_LIST_OUTPUT='[{"id":"old-1"},{"id":"old-2"}]'
export PROBE_LIST_EXIT=0
candidate_list_has_nonempty_issue_ids "$probe_list_ws" "$probe_list_bin" ||
    fail "candidate list probe rejected a valid nonempty issue array"

probe_flow_bin="$tmp/fake-probe-flow-bd"
cat > "$probe_flow_bin" <<'EOF'
#!/bin/bash
printf '%s\n' "$1" >> "$PROBE_FLOW_LOG"
case "$PROBE_FLOW_MODE:$1" in
    first-list-mutation:list)
        printf 'mutated\n' >> .beads/source-marker
        exit 1
        ;;
    init-mutation:list|safe-failure:list)
        exit 1
        ;;
    init-mutation:init)
        printf 'mutated\n' >> .beads/source-marker
        exit 1
        ;;
    safe-failure:init)
        exit 1
        ;;
    second-list-mutation:list|retry-success:list)
        count=0
        [ ! -f "$PROBE_FLOW_STATE" ] || count=$(cat "$PROBE_FLOW_STATE")
        count=$((count + 1))
        printf '%s\n' "$count" > "$PROBE_FLOW_STATE"
        if [ "$count" -eq 1 ]; then
            exit 1
        fi
        if [ "$PROBE_FLOW_MODE" = "second-list-mutation" ]; then
            printf 'mutated\n' >> .beads/source-marker
            printf '%s\n' '[]'
        else
            printf '%s\n' '[{"id":"old-1"}]'
        fi
        ;;
    second-list-mutation:init|retry-success:init)
        exit 0
        ;;
    *)
        exit 2
        ;;
esac
EOF
chmod +x "$probe_flow_bin"

assert_probe_flow() {
    local mode="$1"
    local expected_status="$2"
    local expected_calls="$3"
    local ws="$tmp/probe-flow-$mode"
    local status=0
    local actual_calls
    local source_fingerprint

    mkdir -p "$ws/.beads"
    printf 'original\n' > "$ws/.beads/source-marker"
    export PROBE_FLOW_MODE="$mode"
    export PROBE_FLOW_LOG="$tmp/probe-flow-$mode.calls"
    export PROBE_FLOW_STATE="$tmp/probe-flow-$mode.state"
    : > "$PROBE_FLOW_LOG"
    rm -f "$PROBE_FLOW_STATE"
    source_fingerprint=$(source_artifact_fingerprint "$ws/.beads") ||
        fail "could not fingerprint fake probe source for $mode"

    if (
        stop_dolt_server() { :; }
        probe_candidate_direct_upgrade "$ws" "$probe_flow_bin" \
            "$source_fingerprint" true
    ); then
        status=0
    else
        status=$?
    fi

    [ "$status" -eq "$expected_status" ] ||
        fail "candidate probe $mode returned $status, want $expected_status"
    actual_calls=$(paste -sd, "$PROBE_FLOW_LOG")
    [ "$actual_calls" = "$expected_calls" ] ||
        fail "candidate probe $mode called $actual_calls, want $expected_calls"
}

assert_probe_flow first-list-mutation 2 list
assert_probe_flow init-mutation 2 list,init
assert_probe_flow second-list-mutation 2 list,init,list
assert_probe_flow safe-failure 1 list,init
assert_probe_flow retry-success 0 list,init,list

fake="$tmp/fake-bd"
printf '%s\n' \
    '#!/bin/bash' \
    'if [ "$1" = "list" ]; then printf '\''[{"id":"old-1"},{"id":"old-2"}]\n'\''; exit 0; fi' \
    'if [ "$1" = "show" ] && [ "$2" = "old-1" ]; then printf '\''[{"id":"old-1","title":"One"}]\n'\''; exit 0; fi' \
    'exit 1' > "$fake"
chmod +x "$fake"
DATASET_IDS=([one]="old-1" [two]="old-2")
if capture_snapshot "$tmp" "$fake" > "$tmp/partial.json" 2>/dev/null; then
    fail "strict snapshot accepted a failed bd show"
fi

echo "strict-mode-test: PASS"
