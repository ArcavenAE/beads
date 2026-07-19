#!/bin/bash
# Workspace helpers — create isolated git repos, run bd commands, cleanup.

# NOTE: BEADS_TEST_MODE is intentionally NOT set to 1 here.
# Setting it disables Dolt server auto-start and forces port 1 in server-era
# versions (v0.50–v0.62), which makes every create/list command fail.
# The migration harness runs in isolated temp-dir workspaces, so there is no
# risk of polluting a production database.  Telemetry is opt-in (needs
# BD_OTEL_METRICS_URL) and prompts are avoided by piping </dev/null.
export BEADS_TEST_MODE="${BEADS_TEST_MODE:-0}"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null

# Timeout for bd operations (seconds). Prevents hangs from dolt server
# startup, embedded engine locks, etc.  Server-era versions may need the
# full 30 s for a cold Dolt auto-start.
BD_OP_TIMEOUT="${BD_OP_TIMEOUT:-30}"
BD_OP_KILL_AFTER="${BD_OP_KILL_AFTER:-5s}"
MIGRATION_DOLT_READY_ATTEMPTS_MAX=200
MIGRATION_DOLT_READY_TIMEOUT_MAX=120

migration_validate_operation_timeouts() {
    local kill_seconds

    [[ "$BD_OP_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "$BD_OP_TIMEOUT" -le 300 ] || return 1
    [[ "$BD_OP_KILL_AFTER" =~ ^([1-9][0-9]*)(s)?$ ]] || return 1
    kill_seconds="${BASH_REMATCH[1]}"
    [ "$kill_seconds" -le 60 ]
}

migration_validate_readiness_settings() {
    local attempts="$1"
    local delay="$2"
    local ready_timeout="$3"

    [[ "$attempts" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "$attempts" -le "$MIGRATION_DOLT_READY_ATTEMPTS_MAX" ] || return 1
    [[ "$delay" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]] || return 1
    [[ "$ready_timeout" =~ ^[1-9][0-9]*$ ]] || return 1
    [ "$ready_timeout" -le "$MIGRATION_DOLT_READY_TIMEOUT_MAX" ]
}

migration_server_port_in_use() {
    local port="$1"
    local hex table status
    local inspected=false

    [[ "$port" =~ ^[0-9]+$ ]] || return 2
    hex=$(printf '%04X' "$port") || return 2
    for table in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$table" ] || continue
        inspected=true
        if awk -v suffix=":$hex" '
            $4 == "0A" && substr($2, length($2) - length(suffix) + 1) == suffix {
                found = 1
            }
            END { exit(found ? 0 : 1) }
        ' "$table"; then
            return 0
        else
            status=$?
            [ "$status" -eq 1 ] || return 2
        fi
    done
    if ! $inspected; then
        command -v lsof >/dev/null 2>&1 || return 2
        if lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1; then
            return 0
        else
            status=$?
            [ "$status" -eq 1 ] || return 2
        fi
    fi
    return 1
}

migration_port_reservation_root() {
    local root
    root="${TMPDIR:-/tmp}/bd-migration-server-ports-$(id -u)"
    if [ -L "$root" ]; then
        return 1
    fi
    if [ ! -d "$root" ]; then
        if ! mkdir -m 700 -- "$root" 2>/dev/null; then
            [ -d "$root" ] && [ ! -L "$root" ] || return 1
        fi
    fi
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    [ "$(stat -c '%u' -- "$root")" = "$(id -u)" ] || return 1
    chmod 700 -- "$root" || return 1
    printf '%s\n' "$root"
}

reap_stale_migration_port_reservations() {
    local root="$1"
    local lock owner_file owner port status stale

    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    for lock in "$root"/2????; do
        [ -e "$lock" ] || continue
        [ -d "$lock" ] && [ ! -L "$lock" ] || continue
        port="${lock##*/}"
        owner_file="$lock/owner"
        owner=""
        if [ -f "$owner_file" ] && [ ! -L "$owner_file" ]; then
            owner=$(cat "$owner_file" 2>/dev/null) || owner=""
        fi
        if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
            continue
        fi
        if migration_server_port_in_use "$port"; then
            continue
        else
            status=$?
            [ "$status" -eq 1 ] || continue
        fi
        stale="$lock.stale.$BASHPID.$RANDOM"
        if mv --no-target-directory --no-clobber -- "$lock" "$stale" 2>/dev/null; then
            rm -rf -- "$stale"
        fi
    done
}

reserve_migration_server_port() {
    local ws="$1"
    local git_dir="$ws/.git"
    local port_file="$git_dir/bd-migration-server-port"
    local lock_file="$git_dir/bd-migration-server-port-lock"
    local root attempt port lock status

    [ -d "$git_dir" ] && [ ! -L "$git_dir" ] || return 1
    if [ -e "$port_file" ] || [ -L "$port_file" ] || \
        [ -e "$lock_file" ] || [ -L "$lock_file" ]; then
        return 1
    fi
    root=$(migration_port_reservation_root) || return 1
    reap_stale_migration_port_reservations "$root" || return 1

    for ((attempt = 0; attempt < 256; attempt++)); do
        port=$((20000 + ((BASHPID + RANDOM + attempt * 997) % 10000)))
        lock="$root/$port"
        if ! mkdir -- "$lock" 2>/dev/null; then
            continue
        fi
        if ! printf '%s\n' "$$" > "$lock/owner"; then
            rm -f -- "$lock/owner"
            rmdir -- "$lock" 2>/dev/null || true
            return 1
        fi
        if migration_server_port_in_use "$port"; then
            rm -f -- "$lock/owner"
            rmdir -- "$lock" || return 1
            continue
        else
            status=$?
            if [ "$status" -ne 1 ]; then
                rm -f -- "$lock/owner"
                rmdir -- "$lock" 2>/dev/null || true
                return 1
            fi
        fi
        if ! printf '%s\n' "$port" > "$port_file" || \
            ! printf '%s\n' "$lock" > "$lock_file"; then
            rm -f -- "$port_file" "$lock_file"
            rm -f -- "$lock/owner"
            rmdir -- "$lock" 2>/dev/null || true
            return 1
        fi
        return 0
    done
    return 1
}

release_migration_server_port() {
    local ws="$1"
    local git_dir="$ws/.git"
    local port_file="$git_dir/bd-migration-server-port"
    local lock_file="$git_dir/bd-migration-server-port-lock"
    local root port lock owner

    if [ ! -e "$port_file" ] && [ ! -L "$port_file" ] && \
        [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]; then
        return 0
    fi
    [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1
    port=$(cat "$port_file") || return 1
    lock=$(cat "$lock_file") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1
    root=$(migration_port_reservation_root) || return 1
    [ "$lock" = "$root/$port" ] || return 1
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || return 1
    owner=$(cat "$lock/owner") || return 1
    [ "$owner" = "$$" ] || return 1
    rm -f -- "$lock/owner" || return 1
    rmdir -- "$lock" || return 1
    rm -f -- "$port_file" "$lock_file" || return 1
    [ ! -e "$port_file" ] && [ ! -L "$port_file" ] && \
        [ ! -e "$lock_file" ] && [ ! -L "$lock_file" ]
}

prepare_migration_subprocess_home() {
    local ws="$1"
    local private_root home dir

    [ -d "$ws" ] && [ ! -L "$ws" ] || return 1
    [ "$(stat -c '%u' -- "$ws")" = "$(id -u)" ] || return 1
    if [ -d "$ws/.git" ] && [ ! -L "$ws/.git" ]; then
        private_root="$ws/.git"
    else
        private_root="$ws"
    fi
    home="$private_root/bd-migration-home"
    for dir in \
        "$home" "$home/.config" "$home/.cache" "$home/.local" \
        "$home/.local/share" "$home/.local/state" \
        "$private_root/bd-migration-tmp" "$private_root/bd-migration-runtime"; do
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
            [ "$(stat -c '%u' -- "$dir")" = "$(id -u)" ] || return 1
        else
            mkdir -m 700 -- "$dir" || return 1
        fi
        chmod 700 -- "$dir" || return 1
    done
    printf '%s\n' "$home"
}

migration_subprocess_environment() {
    local ws="$1"
    local result_name="$2"
    local subprocess_home private_root
    local -n result="$result_name"

    subprocess_home=$(prepare_migration_subprocess_home "$ws") || return 1
    if [ -d "$ws/.git" ] && [ ! -L "$ws/.git" ]; then
        private_root="$ws/.git"
    else
        private_root="$ws"
    fi
    # shellcheck disable=SC2034 # result is populated through the caller's nameref.
    result=(
        env -i
        "PATH=$PATH"
        "HOME=$subprocess_home"
        "XDG_CONFIG_HOME=$subprocess_home/.config"
        "XDG_CACHE_HOME=$subprocess_home/.cache"
        "XDG_DATA_HOME=$subprocess_home/.local/share"
        "XDG_STATE_HOME=$subprocess_home/.local/state"
        "XDG_RUNTIME_DIR=$private_root/bd-migration-runtime"
        "TMPDIR=$private_root/bd-migration-tmp"
        "GIT_CONFIG_NOSYSTEM=1"
        "GIT_CONFIG_GLOBAL=/dev/null"
        "GIT_TERMINAL_PROMPT=0"
        "USER=migration-test"
        "LOGNAME=migration-test"
        "SHELL=/bin/bash"
        "LANG=C.UTF-8"
        "LC_ALL=C.UTF-8"
        "TZ=UTC"
        "TERM=dumb"
    )
}

new_workspace() (
    local dir
    local env_name

    while IFS= read -r env_name; do
        case "$env_name" in
            GIT_*) unset "$env_name" ;;
        esac
    done < <(compgen -e)
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_TERMINAL_PROMPT=0

    dir=$(mktemp -d /tmp/bd-migration-XXXXXX) || return 1
    if ! git -C "$dir" init --quiet || \
        ! git -C "$dir" config core.hooksPath .git/hooks || \
        ! git -C "$dir" config user.name "migration-test" || \
        ! git -C "$dir" config user.email "test@beads.test" || \
        ! touch "$dir/.gitkeep" || \
        ! git -C "$dir" add . || \
        ! git -C "$dir" commit --quiet -m "initial"; then
        rm -rf -- "$dir"
        return 1
    fi
    if ! reserve_migration_server_port "$dir"; then
        rm -rf -- "$dir"
        return 1
    fi
    if ! prepare_migration_subprocess_home "$dir" >/dev/null; then
        release_migration_server_port "$dir" || true
        rm -rf -- "$dir"
        return 1
    fi
    echo "$dir"
)

bd_in() {
    local ws="$1"
    local bin="$2"
    local port_file="$ws/.git/bd-migration-server-port"
    local prestarted_file="$ws/.git/bd-migration-prestarted-server"
    local port=""
    local auto_start=1 env_name prestarted_port
    local -a clean_env
    shift 2
    migration_validate_operation_timeouts || return 1
    if [ -e "$port_file" ] || [ -L "$port_file" ]; then
        [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
        port=$(cat "$port_file") || return 1
        [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1
    fi
    if [ -e "$prestarted_file" ] || [ -L "$prestarted_file" ]; then
        [ -f "$prestarted_file" ] && [ ! -L "$prestarted_file" ] || return 1
        prestarted_port=$(cat "$prestarted_file") || return 1
        [ -n "$port" ] && [ "$prestarted_port" = "$port" ] || return 1
        auto_start=0
    fi
    migration_subprocess_environment "$ws" clean_env || return 1
    clean_env+=(
        "BEADS_TEST_MODE=0"
        "BEADS_NO_DAEMON=1"
        "BEADS_DOLT_AUTO_START=$auto_start"
        "BD_NON_INTERACTIVE=1"
        "BD_NO_PAGER=1"
        "BD_DISABLE_METRICS=1"
        "BD_DISABLE_EVENT_FLUSH=1"
        "NO_COLOR=1"
        "CI=1"
    )
    if [ -n "$port" ]; then
        clean_env+=("BEADS_DOLT_SERVER_PORT=$port")
    fi
    for env_name in \
        BLOCKER_FAIL_COMMAND BLOCKER_STATE LEGACY_RACE_CALLS \
        PROBE_FLOW_LOG PROBE_FLOW_MODE PROBE_FLOW_STATE \
        PROBE_LIST_EXIT PROBE_LIST_OUTPUT \
        SERVER_EXPORT_CALLS SERVER_EXPORT_FAIL_CANDIDATE_CALLS \
        SNAPSHOT_FAIL_COMMAND SNAPSHOT_LIST_SHAPE \
        V057_CANDIDATE_CALLS V057_MODE V057_OLD_CALLS; do
        if [[ -v "$env_name" ]]; then
            clean_env+=("$env_name=${!env_name}")
        fi
    done
    (cd "$ws" && "${clean_env[@]}" timeout \
        --kill-after="$BD_OP_KILL_AFTER" "$BD_OP_TIMEOUT" "$bin" "$@")
}

# Create an issue, returning just the ID on stdout.
# Tries --silent first, falls back to parsing output.
bd_create() {
    local ws="$1"
    local bin="$2"
    shift 2
    local id
    id=$(bd_in "$ws" "$bin" create --silent "$@" 2>/dev/null) && [ -n "$id" ] && echo "$id" && return 0
    id=$(bd_in "$ws" "$bin" create "$@" 2>&1 | grep -oP 'Created issue: \K\S+' || true)
    [ -n "$id" ] && echo "$id" && return 0
    return 1
}

migration_workspace_owned_by_harness() {
    local ws="$1"
    local git_dir port_file lock_file root port lock owner

    [[ "$ws" =~ ^/tmp/bd-migration-[[:alnum:]]{6}$ ]] || return 1
    [ -d "$ws" ] && [ ! -L "$ws" ] || return 1
    [ "$(stat -c '%u' -- "$ws")" = "$(id -u)" ] || return 1

    git_dir="$ws/.git"
    port_file="$git_dir/bd-migration-server-port"
    lock_file="$git_dir/bd-migration-server-port-lock"
    [ -d "$git_dir" ] && [ ! -L "$git_dir" ] || return 1
    [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
    [ -f "$lock_file" ] && [ ! -L "$lock_file" ] || return 1

    port=$(cat "$port_file") || return 1
    lock=$(cat "$lock_file") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1
    root="${TMPDIR:-/tmp}/bd-migration-server-ports-$(id -u)"
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    [ "$(stat -c '%u' -- "$root")" = "$(id -u)" ] || return 1
    [ "$lock" = "$root/$port" ] || return 1
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    [ -f "$lock/owner" ] && [ ! -L "$lock/owner" ] || return 1
    owner=$(cat "$lock/owner") || return 1
    [ "$owner" = "$$" ]
}

migration_process_command_line() {
    local pid="$1"

    if [ -r "/proc/$pid/cmdline" ]; then
        tr '\0' ' ' < "/proc/$pid/cmdline"
        return
    fi
    ps -p "$pid" -o command= 2>/dev/null
}

migration_process_cwd() {
    local pid="$1"

    if [ -L "/proc/$pid/cwd" ]; then
        readlink "/proc/$pid/cwd" 2>/dev/null
        return
    fi
    command -v lsof >/dev/null 2>&1 || return 1
    lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1
}

migration_process_stat_field() {
    local pid="$1"
    local field_index="$2"
    local stat_line remainder
    local -a fields

    [[ "$field_index" =~ ^[0-9]+$ ]] || return 1
    IFS= read -r stat_line 2>/dev/null < "/proc/$pid/stat" || return 1
    [[ "$stat_line" == *") "* ]] || return 1
    remainder="${stat_line##*) }"
    read -r -a fields <<< "$remainder"
    [ "${#fields[@]}" -gt "$field_index" ] || return 1
    printf '%s\n' "${fields[$field_index]}"
}

migration_process_start_time() {
    local value
    value=$(migration_process_stat_field "$1" 19) || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

migration_process_state() {
    migration_process_stat_field "$1" 0
}

migration_process_parent_pid() {
    local value
    value=$(migration_process_stat_field "$1" 1) || return 1
    [[ "$value" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

migration_path_identity() {
    local path="$1"
    [ -e "$path" ] && [ ! -L "$path" ] || return 1
    stat -Lc '%d:%i' -- "$path"
}

MIGRATION_PROVISIONAL_OWNED_WS=""
MIGRATION_PROVISIONAL_OWNED_PID=""
MIGRATION_PROVISIONAL_OWNED_START=""
MIGRATION_PROVISIONAL_OWNED_PARENT=""
MIGRATION_PROVISIONAL_OWNED_IDENTITY=()

migration_begin_provisional_owned_process() {
    MIGRATION_PROVISIONAL_OWNED_WS="$1"
    MIGRATION_PROVISIONAL_OWNED_PID="$2"
    MIGRATION_PROVISIONAL_OWNED_START="$3"
    MIGRATION_PROVISIONAL_OWNED_PARENT="$BASHPID"
    MIGRATION_PROVISIONAL_OWNED_IDENTITY=()
}

migration_clear_provisional_owned_process() {
    local ws="$1"

    [ "$MIGRATION_PROVISIONAL_OWNED_WS" = "$ws" ] || return 0
    MIGRATION_PROVISIONAL_OWNED_WS=""
    MIGRATION_PROVISIONAL_OWNED_PID=""
    MIGRATION_PROVISIONAL_OWNED_START=""
    MIGRATION_PROVISIONAL_OWNED_PARENT=""
    MIGRATION_PROVISIONAL_OWNED_IDENTITY=()
}

migration_provisional_owned_process_matches() {
    local ws="$1"
    local current_start current_parent

    [ "$MIGRATION_PROVISIONAL_OWNED_WS" = "$ws" ] || return 1
    [ "$MIGRATION_PROVISIONAL_OWNED_PARENT" = "$BASHPID" ] || return 1
    current_start=$(migration_process_start_time "$MIGRATION_PROVISIONAL_OWNED_PID") || return 1
    [ "$current_start" = "$MIGRATION_PROVISIONAL_OWNED_START" ] || return 1
    current_parent=$(migration_process_parent_pid "$MIGRATION_PROVISIONAL_OWNED_PID") || return 1
    [ "$current_parent" = "$MIGRATION_PROVISIONAL_OWNED_PARENT" ] || return 1
    jobs -pr | grep -Fqx -- "$MIGRATION_PROVISIONAL_OWNED_PID"
}

migration_owned_process_shape() {
    local pid="$1"
    local dolt_bin="$2"
    local port="$3"
    local -a arguments

    [ -r "/proc/$pid/cmdline" ] || return 1
    mapfile -d '' -t arguments < "/proc/$pid/cmdline" 2>/dev/null || return 1
    if [ "${#arguments[@]}" -eq 6 ] &&
        [ "${arguments[0]}" = "$dolt_bin" ] &&
        [ "${arguments[1]}" = "sql-server" ] &&
        [ "${arguments[2]}" = "--host" ] &&
        [ "${arguments[3]}" = "127.0.0.1" ] &&
        [ "${arguments[4]}" = "--port" ] &&
        [ "${arguments[5]}" = "$port" ]; then
        printf '%s\n' binary
    elif [ "${#arguments[@]}" -eq 7 ] &&
        [ "${arguments[1]}" = "$dolt_bin" ] &&
        [ "${arguments[2]}" = "sql-server" ] &&
        [ "${arguments[3]}" = "--host" ] &&
        [ "${arguments[4]}" = "127.0.0.1" ] &&
        [ "${arguments[5]}" = "--port" ] &&
        [ "${arguments[6]}" = "$port" ]; then
        printf '%s\n' script
    else
        return 1
    fi
}

migration_capture_owned_process_identity() {
    local pid="$1"
    local ws="$2"
    local dolt_bin="$3"
    local port="$4"
    local result_name="$5"
    local start_time start_time_after process_exe_identity
    local launch_identity launch_mode cwd dolt_root cwd_identity
    local -n output_ref="$result_name"

    start_time=$(migration_process_start_time "$pid") || return 1
    launch_mode=$(migration_owned_process_shape "$pid" "$dolt_bin" "$port") || return 1
    cwd=$(migration_process_cwd "$pid") || return 1
    dolt_root=$(cd -P -- "$ws/.beads/dolt" 2>/dev/null && pwd) || return 1
    [ "$cwd" = "$dolt_root" ] || return 1
    cwd_identity=$(stat -Lc '%d:%i' -- "/proc/$pid/cwd" 2>/dev/null) || return 1
    [ "$cwd_identity" = "$(migration_path_identity "$dolt_root")" ] || return 1
    process_exe_identity=$(stat -Lc '%d:%i' -- "/proc/$pid/exe" 2>/dev/null) || return 1
    launch_identity=$(migration_path_identity "$dolt_bin") || return 1
    [[ "$dolt_bin" != *$'\n'* ]] || return 1
    start_time_after=$(migration_process_start_time "$pid") || return 1
    [ "$start_time_after" = "$start_time" ] || return 1
    output_ref=(
        "$pid" "$start_time" "$process_exe_identity" "$dolt_bin"
        "$launch_identity" "$launch_mode" "$cwd_identity"
    )
}

migration_owned_process_matches_identity() {
    local pid="$1"
    local ws="$2"
    local identity_name="$3"
    local port start_time process_exe_identity
    local dolt_bin launch_identity expected_mode cwd_identity
    local current_start current_mode current_cwd_identity dolt_root
    local -n identity_ref="$identity_name"

    [ "${#identity_ref[@]}" -eq 7 ] || return 1
    [ "${identity_ref[0]}" = "$pid" ] || return 1
    start_time="${identity_ref[1]}"
    process_exe_identity="${identity_ref[2]}"
    dolt_bin="${identity_ref[3]}"
    launch_identity="${identity_ref[4]}"
    expected_mode="${identity_ref[5]}"
    cwd_identity="${identity_ref[6]}"
    [[ "$start_time" =~ ^[0-9]+$ ]] || return 1
    [ "$expected_mode" = "binary" ] || [ "$expected_mode" = "script" ] || return 1
    port=$(cat "$ws/.git/bd-migration-server-port") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1
    current_start=$(migration_process_start_time "$pid") || return 1
    [ "$current_start" = "$start_time" ] || return 1
    [ "$(migration_path_identity "$dolt_bin")" = "$launch_identity" ] || return 1
    [ "$(stat -Lc '%d:%i' -- "/proc/$pid/exe" 2>/dev/null)" = "$process_exe_identity" ] || return 1
    current_mode=$(migration_owned_process_shape "$pid" "$dolt_bin" "$port") || return 1
    [ "$current_mode" = "$expected_mode" ] || return 1
    current_cwd_identity=$(stat -Lc '%d:%i' -- "/proc/$pid/cwd" 2>/dev/null) || return 1
    [ "$current_cwd_identity" = "$cwd_identity" ] || return 1
    dolt_root=$(cd -P -- "$ws/.beads/dolt" 2>/dev/null && pwd) || return 1
    [ "$(migration_path_identity "$dolt_root")" = "$cwd_identity" ] || return 1
    current_start=$(migration_process_start_time "$pid") || return 1
    [ "$current_start" = "$start_time" ]
}

migration_read_owned_process_identity() {
    local ws="$1"
    local result_name="$2"
    local identity_file="$ws/.git/bd-migration-owned-dolt-server.identity"
    local -a reread
    # shellcheck disable=SC2178 # output_ref names the caller's array.
    local -n output_ref="$result_name"

    [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
    [ "$(stat -c '%u' -- "$identity_file")" = "$(id -u)" ] || return 1
    mapfile -t output_ref < "$identity_file" || return 1
    [ "${#output_ref[@]}" -eq 7 ] || return 1
    mapfile -t reread < "$identity_file" || return 1
    [ "${#reread[@]}" -eq 7 ] || return 1
    [ "${output_ref[*]}" = "${reread[*]}" ]
}

migration_owned_process_matches_launch() {
    local pid="$1"
    local ws="$2"
    local dolt_bin="$3"
    local port="$4"
    local -a identity

    migration_capture_owned_process_identity \
        "$pid" "$ws" "$dolt_bin" "$port" identity || return 1
    [ "${#identity[@]}" -eq 7 ]
}

migration_pid_belongs_to_workspace() {
    local pid="$1"
    local ws="$2"
    local pidfile_name="$3"
    local command_line="" cwd="" dolt_root=""
    local -a owned_identity

    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || return 1
    command_line=$(migration_process_command_line "$pid") || return 1
    [ -n "$command_line" ] || return 1

    case "$pidfile_name" in
        dolt-server.pid)
            [[ "$command_line" == *dolt* ]] && [[ "$command_line" == *sql-server* ]] || return 1
            cwd=$(migration_process_cwd "$pid") || return 1
            dolt_root=$(cd -P -- "$ws/.beads/dolt" 2>/dev/null && pwd) || return 1
            [ "$cwd" = "$dolt_root" ] || [[ "$cwd" == "$dolt_root/"* ]]
            ;;
        bd-migration-owned-dolt-server.pid)
            migration_read_owned_process_identity "$ws" owned_identity || return 1
            migration_owned_process_matches_identity "$pid" "$ws" owned_identity
            ;;
        dolt-monitor.pid)
            [[ "$command_line" == *bd* ]] && [[ "$command_line" == *idle-monitor* ]] &&
                [[ "$command_line" == *"$ws"* ]]
            ;;
        daemon.pid)
            [[ "$command_line" == *bd* ]] && [[ "$command_line" == *daemon* ]] &&
                [[ "$command_line" == *"$ws"* ]]
            ;;
        *)
            return 1
            ;;
    esac
}

migration_publish_owned_process_identity() {
    local ws="$1"
    local identity_name="$2"
    local git_dir="$ws/.git"
    local pid_file="$git_dir/bd-migration-owned-dolt-server.pid"
    local identity_file="$git_dir/bd-migration-owned-dolt-server.identity"
    local pid_tmp="$pid_file.tmp.$BASHPID.$RANDOM"
    local identity_tmp="$identity_file.tmp.$BASHPID.$RANDOM"
    local -n identity_ref="$identity_name"

    [ "${#identity_ref[@]}" -eq 7 ] || return 1
    if [ -e "$pid_file" ] || [ -L "$pid_file" ] ||
        [ -e "$identity_file" ] || [ -L "$identity_file" ]; then
        return 1
    fi
    if ! (
        set -o noclobber
        umask 077
        printf '%s\n' "${identity_ref[@]}" > "$identity_tmp" &&
            printf '%s\n' "${identity_ref[0]}" > "$pid_tmp"
    ) 2>/dev/null; then
        rm -f -- "$pid_tmp" "$identity_tmp"
        return 1
    fi
    if ! mv --no-target-directory --no-clobber -- "$identity_tmp" "$identity_file"; then
        rm -f -- "$pid_tmp" "$identity_tmp"
        return 1
    fi
    if ! mv --no-target-directory --no-clobber -- "$pid_tmp" "$pid_file"; then
        rm -f -- "$pid_tmp"
        if [ -f "$identity_file" ] && [ ! -L "$identity_file" ]; then
            rm -f -- "$identity_file"
        fi
        return 1
    fi
    return 0
}

migration_signal_owned_process() {
    local signal_name="$1"
    local pid="$2"

    [ "$signal_name" = "TERM" ] || [ "$signal_name" = "KILL" ] || return 1
    kill "-$signal_name" -- "$pid"
}

migration_wait_process_exit_by_start_time() {
    local pid="$1"
    local expected_start="$2"
    local attempts="$3"
    local attempt current_start state

    for ((attempt = 0; attempt < attempts; attempt++)); do
        if [ ! -e "/proc/$pid" ]; then
            wait "$pid" 2>/dev/null || true
            return 0
        fi
        current_start=$(migration_process_start_time "$pid" 2>/dev/null) || {
            [ -e "/proc/$pid" ] || {
                wait "$pid" 2>/dev/null || true
                return 0
            }
            sleep 0.05
            continue
        }
        [ "$current_start" = "$expected_start" ] || return 2
        state=$(migration_process_state "$pid" 2>/dev/null) || {
            [ -e "/proc/$pid" ] || {
                wait "$pid" 2>/dev/null || true
                return 0
            }
            sleep 0.05
            continue
        }
        case "$state" in
            Z|X|x)
                wait "$pid" 2>/dev/null || true
                return 0
                ;;
        esac
        sleep 0.05
    done
    return 1
}

migration_wait_provisional_owned_process_exit() {
    local attempts="$2"

    migration_wait_process_exit_by_start_time \
        "$MIGRATION_PROVISIONAL_OWNED_PID" \
        "$MIGRATION_PROVISIONAL_OWNED_START" "$attempts"
}

migration_terminate_provisional_owned_process() {
    local ws="$1"
    local wait_status=0 state

    if [ ! -e "/proc/$MIGRATION_PROVISIONAL_OWNED_PID" ]; then
        wait "$MIGRATION_PROVISIONAL_OWNED_PID" 2>/dev/null || true
        return 0
    fi
    state=$(migration_process_state "$MIGRATION_PROVISIONAL_OWNED_PID" 2>/dev/null) || return 1
    case "$state" in
        Z|X|x)
            wait "$MIGRATION_PROVISIONAL_OWNED_PID" 2>/dev/null || true
            return 0
            ;;
    esac
    migration_provisional_owned_process_matches "$ws" || return 1
    migration_signal_owned_process TERM "$MIGRATION_PROVISIONAL_OWNED_PID" || return 1
    migration_wait_provisional_owned_process_exit "$ws" 40 || wait_status=$?
    if [ "$wait_status" -eq 0 ]; then
        return 0
    fi
    [ "$wait_status" -eq 1 ] || return 1
    migration_provisional_owned_process_matches "$ws" || return 1
    migration_signal_owned_process KILL "$MIGRATION_PROVISIONAL_OWNED_PID" || return 1
    migration_wait_provisional_owned_process_exit "$ws" 40
}

migration_wait_owned_process_exit() {
    local pid="$1"
    local identity_name="$3"
    local attempts="$4"
    local -n identity_ref="$identity_name"

    [ "${#identity_ref[@]}" -eq 7 ] || return 2
    [ "${identity_ref[0]}" = "$pid" ] || return 2
    migration_wait_process_exit_by_start_time \
        "$pid" "${identity_ref[1]}" "$attempts"
}

migration_terminate_owned_process() {
    local pid="$1"
    local ws="$2"
    local identity_name="$3"
    local wait_status=0 state

    if [ ! -e "/proc/$pid" ]; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    state=$(migration_process_state "$pid" 2>/dev/null) || {
        [ -e "/proc/$pid" ] || {
            wait "$pid" 2>/dev/null || true
            return 0
        }
        return 1
    }
    case "$state" in
        Z|X|x)
            wait "$pid" 2>/dev/null || true
            return 0
            ;;
    esac
    migration_owned_process_matches_identity "$pid" "$ws" "$identity_name" || return 1
    migration_signal_owned_process TERM "$pid" || return 1
    migration_wait_owned_process_exit "$pid" "$ws" "$identity_name" 40 || wait_status=$?
    if [ "$wait_status" -eq 0 ]; then
        return 0
    fi
    [ "$wait_status" -eq 1 ] || return 1
    migration_owned_process_matches_identity "$pid" "$ws" "$identity_name" || return 1
    migration_signal_owned_process KILL "$pid" || return 1
    migration_wait_owned_process_exit "$pid" "$ws" "$identity_name" 40
}

migration_wait_server_port_free() {
    local ws="$1"
    local port status=0 attempt

    port=$(cat "$ws/.git/bd-migration-server-port") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1
    for ((attempt = 0; attempt < 100; attempt++)); do
        if migration_server_port_in_use "$port"; then
            sleep 0.05
            continue
        else
            status=$?
            [ "$status" -eq 1 ] || return 1
            return 0
        fi
    done
    return 1
}

migration_remove_provisional_identity_files() {
    local ws="$1"
    local pid_file="$ws/.git/bd-migration-owned-dolt-server.pid"
    local identity_file="$ws/.git/bd-migration-owned-dolt-server.identity"
    local -a recorded_identity

    if [ -e "$pid_file" ] || [ -L "$pid_file" ]; then
        [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
        [ "$(cat "$pid_file")" = "$MIGRATION_PROVISIONAL_OWNED_PID" ] || return 1
    fi
    if [ -e "$identity_file" ] || [ -L "$identity_file" ]; then
        [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
        [ "${#MIGRATION_PROVISIONAL_OWNED_IDENTITY[@]}" -eq 7 ] || return 1
        mapfile -t recorded_identity < "$identity_file" || return 1
        [ "${recorded_identity[*]}" = "${MIGRATION_PROVISIONAL_OWNED_IDENTITY[*]}" ] || return 1
    fi
    rm -f -- "$pid_file" "$identity_file" || return 1
    [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ] &&
        [ ! -e "$identity_file" ] && [ ! -L "$identity_file" ]
}

migration_rollback_provisional_owned_process() {
    local ws="$1"

    if ! migration_terminate_provisional_owned_process "$ws" ||
        ! migration_wait_server_port_free "$ws" ||
        ! migration_remove_provisional_identity_files "$ws"; then
        echo "provisional owned Dolt server rollback failed; preserved at $ws" >&2
        return 1
    fi
    migration_clear_provisional_owned_process "$ws"
}

migration_owned_identity_files_match() {
    local ws="$1"
    local identity_name="$2"
    local pid_file="$ws/.git/bd-migration-owned-dolt-server.pid"
    local -a recorded_identity
    local -n identity_ref="$identity_name"

    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    [ "$(cat "$pid_file")" = "${identity_ref[0]}" ] || return 1
    migration_read_owned_process_identity "$ws" recorded_identity || return 1
    [ "${recorded_identity[*]}" = "${identity_ref[*]}" ]
}

migration_remove_owned_identity_files() {
    local ws="$1"
    local identity_name="$2"
    local pid_file="$ws/.git/bd-migration-owned-dolt-server.pid"
    local identity_file="$ws/.git/bd-migration-owned-dolt-server.identity"

    migration_owned_identity_files_match "$ws" "$identity_name" || return 1
    rm -f -- "$pid_file" "$identity_file" || return 1
    [ ! -e "$pid_file" ] && [ ! -L "$pid_file" ] &&
        [ ! -e "$identity_file" ] && [ ! -L "$identity_file" ]
}

migration_rollback_started_server() {
    local ws="$1"
    local identity_name="$2"
    local remove_prestarted_marker="$3"
    local prestarted_file="$ws/.git/bd-migration-prestarted-server"
    local -n identity_ref="$identity_name"

    if ! migration_terminate_owned_process "${identity_ref[0]}" "$ws" "$identity_name" ||
        ! migration_wait_server_port_free "$ws" ||
        ! migration_remove_owned_identity_files "$ws" "$identity_name"; then
        echo "owned Dolt server rollback failed; preserved at $ws" >&2
        return 1
    fi
    if $remove_prestarted_marker; then
        rm -f -- "$prestarted_file" || {
            echo "owned Dolt server rollback failed to remove its mode marker; preserved at $ws" >&2
            return 1
        }
        [ ! -e "$prestarted_file" ] && [ ! -L "$prestarted_file" ] || return 1
    fi
    migration_clear_provisional_owned_process "$ws"
}

owned_migration_dolt_server_ready() {
    local ws="$1"
    local dolt_bin="$2"
    local port="$3"
    local pid="$4"
    local attempts="${MIGRATION_DOLT_READY_ATTEMPTS:-100}"
    local delay="${MIGRATION_DOLT_READY_DELAY:-0.1}"
    local ready_timeout="${MIGRATION_DOLT_READY_TIMEOUT:-30}"
    local attempt deadline
    local -a clean_env

    migration_validate_readiness_settings \
        "$attempts" "$delay" "$ready_timeout" || return 1
    migration_subprocess_environment "$ws" clean_env || return 1
    deadline=$((SECONDS + ready_timeout))
    for ((attempt = 0; attempt < attempts; attempt++)); do
        [ "$SECONDS" -lt "$deadline" ] || return 1
        migration_pid_belongs_to_workspace \
            "$pid" "$ws" "bd-migration-owned-dolt-server.pid" || return 1
        if "${clean_env[@]}" timeout --kill-after=1s 2s \
            "$dolt_bin" --host 127.0.0.1 --port "$port" \
                --no-tls sql -q 'SELECT 1' \
            >/dev/null 2>&1; then
            return 0
        fi
        [ "$SECONDS" -lt "$deadline" ] || return 1
        [ "$delay" = "0" ] || sleep "$delay"
    done
    return 1
}

migration_owned_dolt_sql() {
    local ws="$1"
    local database="$2"
    local query="$3"
    local git_dir="$ws/.git"
    local port_file="$git_dir/bd-migration-server-port"
    local pid_file="$git_dir/bd-migration-owned-dolt-server.pid"
    local prestarted_file="$git_dir/bd-migration-prestarted-server"
    local expected_query="SELECT value AS schema_version FROM config WHERE \`key\` = 'schema_version'"
    local dolt_bin port marker_port pid
    local -a clean_env

    migration_validate_operation_timeouts || return 1
    migration_workspace_owned_by_harness "$ws" || return 1
    [[ "$database" =~ ^[[:alnum:]_][[:alnum:]_-]*$ ]] || return 1
    [ "${#database}" -le 64 ] || return 1
    [ "$query" = "$expected_query" ] || return 1
    [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
    [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
    [ -f "$prestarted_file" ] && [ ! -L "$prestarted_file" ] || return 1
    port=$(cat "$port_file") || return 1
    marker_port=$(cat "$prestarted_file") || return 1
    pid=$(cat "$pid_file") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] && [ "$marker_port" = "$port" ] || return 1
    migration_pid_belongs_to_workspace \
        "$pid" "$ws" "bd-migration-owned-dolt-server.pid" || return 1
    dolt_bin=$(command -v dolt) || return 1
    dolt_bin=$(readlink -f -- "$dolt_bin") || return 1
    [ -f "$dolt_bin" ] && [ -x "$dolt_bin" ] || return 1
    migration_subprocess_environment "$ws" clean_env || return 1
    "${clean_env[@]}" timeout --kill-after="$BD_OP_KILL_AFTER" \
        "$BD_OP_TIMEOUT" "$dolt_bin" \
        --host 127.0.0.1 --port "$port" --no-tls --use-db "$database" \
        sql -r json -q "$query"
}

start_owned_migration_dolt_server() {
    local ws="$1"
    local git_dir="$ws/.git"
    local beads_dir="$ws/.beads"
    local dolt_root="$beads_dir/dolt"
    local port_file="$git_dir/bd-migration-server-port"
    local pid_file="$git_dir/bd-migration-owned-dolt-server.pid"
    local identity_file="$git_dir/bd-migration-owned-dolt-server.identity"
    local prestarted_file="$git_dir/bd-migration-prestarted-server"
    local log_file="$git_dir/bd-migration-owned-dolt-server.log"
    local dolt_bin port pid="" existing_pid="" marker_port="" status attempt
    local provisional_start=""
    local marker_tmp="$prestarted_file.tmp.$BASHPID.$RANDOM"
    local remove_prestarted_marker=true captured=false
    local -a clean_env owned_identity

    migration_validate_operation_timeouts || return 1
    migration_workspace_owned_by_harness "$ws" || return 1
    [ -f "$port_file" ] && [ ! -L "$port_file" ] || return 1
    port=$(cat "$port_file") || return 1
    [[ "$port" =~ ^2[0-9]{4}$ ]] || return 1

    if [ -e "$prestarted_file" ] || [ -L "$prestarted_file" ]; then
        [ -f "$prestarted_file" ] && [ ! -L "$prestarted_file" ] || return 1
        marker_port=$(cat "$prestarted_file") || return 1
        [ "$marker_port" = "$port" ] || return 1
        remove_prestarted_marker=false
    fi
    dolt_bin=$(command -v dolt) || return 1
    dolt_bin=$(readlink -f -- "$dolt_bin") || return 1
    [ -f "$dolt_bin" ] && [ -x "$dolt_bin" ] || return 1
    if [ -e "$pid_file" ] || [ -L "$pid_file" ] ||
        [ -e "$identity_file" ] || [ -L "$identity_file" ]; then
        [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
        [ -f "$identity_file" ] && [ ! -L "$identity_file" ] || return 1
        existing_pid=$(cat "$pid_file") || return 1
        migration_pid_belongs_to_workspace \
            "$existing_pid" "$ws" "bd-migration-owned-dolt-server.pid" || return 1
        owned_migration_dolt_server_ready "$ws" "$dolt_bin" "$port" "$existing_pid" ||
            return 1
        if [ ! -e "$prestarted_file" ]; then
            (set -o noclobber; umask 077; printf '%s\n' "$port" > "$marker_tmp") \
                2>/dev/null || return 1
            mv --no-target-directory --no-clobber -- "$marker_tmp" "$prestarted_file" || {
                rm -f -- "$marker_tmp"
                return 1
            }
        fi
        [ -f "$prestarted_file" ] && [ ! -L "$prestarted_file" ] &&
            [ "$(cat "$prestarted_file")" = "$port" ] &&
            migration_pid_belongs_to_workspace \
                "$existing_pid" "$ws" "bd-migration-owned-dolt-server.pid"
        return
    fi

    if [ -e "$beads_dir" ] || [ -L "$beads_dir" ]; then
        [ -d "$beads_dir" ] && [ ! -L "$beads_dir" ] || return 1
        [ "$(stat -c '%u' -- "$beads_dir")" = "$(id -u)" ] || return 1
    else
        mkdir -m 700 -- "$beads_dir" || return 1
    fi
    if [ -e "$dolt_root" ] || [ -L "$dolt_root" ]; then
        [ -d "$dolt_root" ] && [ ! -L "$dolt_root" ] || return 1
        [ "$(stat -c '%u' -- "$dolt_root")" = "$(id -u)" ] || return 1
    else
        mkdir -m 700 -- "$dolt_root" || return 1
    fi
    migration_subprocess_environment "$ws" clean_env || return 1
    if [ -e "$dolt_root/.dolt" ] || [ -L "$dolt_root/.dolt" ]; then
        [ -d "$dolt_root/.dolt" ] && [ ! -L "$dolt_root/.dolt" ] || return 1
        [ "$(stat -c '%u' -- "$dolt_root/.dolt")" = "$(id -u)" ] || return 1
    elif ! (
        cd -P -- "$dolt_root" &&
            "${clean_env[@]}" timeout --kill-after="$BD_OP_KILL_AFTER" \
                "$BD_OP_TIMEOUT" "$dolt_bin" init \
                --name migration-test --email test@beads.test --initial-branch main
    ) >/dev/null 2>&1; then
        return 1
    fi
    [ -d "$dolt_root/.dolt" ] && [ ! -L "$dolt_root/.dolt" ] || return 1

    if migration_server_port_in_use "$port"; then
        return 1
    else
        status=$?
        [ "$status" -eq 1 ] || return 1
    fi
    if [ -e "$log_file" ] || [ -L "$log_file" ]; then
        [ -f "$log_file" ] && [ ! -L "$log_file" ] || return 1
        [ "$(stat -c '%u' -- "$log_file")" = "$(id -u)" ] || return 1
    fi
    : >> "$log_file" || return 1
    (
        cd -P -- "$dolt_root" || exit 1
        exec "${clean_env[@]}" "$dolt_bin" sql-server \
            --host 127.0.0.1 --port "$port"
    ) >> "$log_file" 2>&1 < /dev/null &
    pid=$!
    provisional_start=$(migration_process_start_time "$pid") || {
        wait "$pid" 2>/dev/null || true
        return 1
    }
    migration_begin_provisional_owned_process "$ws" "$pid" "$provisional_start"

    for ((attempt = 0; attempt < 100; attempt++)); do
        if migration_capture_owned_process_identity \
            "$pid" "$ws" "$dolt_bin" "$port" owned_identity; then
            captured=true
            break
        fi
        [ -e "/proc/$pid" ] || break
        sleep 0.02
    done
    if ! $captured; then
        migration_rollback_provisional_owned_process "$ws" || true
        return 1
    fi
    MIGRATION_PROVISIONAL_OWNED_IDENTITY=("${owned_identity[@]}")
    if ! migration_publish_owned_process_identity "$ws" owned_identity; then
        if migration_owned_identity_files_match "$ws" owned_identity; then
            migration_rollback_started_server \
                "$ws" owned_identity "$remove_prestarted_marker" || true
        else
            migration_rollback_provisional_owned_process "$ws" || true
        fi
        return 1
    fi
    if ! owned_migration_dolt_server_ready "$ws" "$dolt_bin" "$port" "$pid"; then
        migration_rollback_started_server \
            "$ws" owned_identity "$remove_prestarted_marker" || true
        return 1
    fi
    if [ ! -e "$prestarted_file" ]; then
        if ! (set -o noclobber; umask 077; printf '%s\n' "$port" > "$marker_tmp") \
                2>/dev/null ||
            ! mv --no-target-directory --no-clobber -- "$marker_tmp" "$prestarted_file"; then
            rm -f -- "$marker_tmp"
            migration_rollback_started_server \
                "$ws" owned_identity "$remove_prestarted_marker" || true
            return 1
        fi
    fi
    if [ -f "$pid_file" ] && [ ! -L "$pid_file" ] &&
        [ "$(cat "$pid_file")" = "$pid" ] &&
        [ -f "$identity_file" ] && [ ! -L "$identity_file" ] &&
        [ -f "$prestarted_file" ] && [ ! -L "$prestarted_file" ] &&
        [ "$(cat "$prestarted_file")" = "$port" ] &&
        migration_pid_belongs_to_workspace \
            "$pid" "$ws" "bd-migration-owned-dolt-server.pid"; then
        migration_clear_provisional_owned_process "$ws"
        return 0
    fi
    migration_rollback_started_server \
        "$ws" owned_identity "$remove_prestarted_marker" || true
    return 1
}

stop_dolt_server() {
    local ws="$1"
    local pid="" pidfile_name=""
    local owned_pid="" owned_state=""
    local owned_pid_file="$ws/.git/bd-migration-owned-dolt-server.pid"
    local owned_identity_file="$ws/.git/bd-migration-owned-dolt-server.identity"
    local -a owned_identity
    migration_workspace_owned_by_harness "$ws" || return 1
    if [ "$MIGRATION_PROVISIONAL_OWNED_WS" = "$ws" ] &&
        { [ ! -f "$owned_pid_file" ] || [ -L "$owned_pid_file" ] ||
            [ ! -f "$owned_identity_file" ] || [ -L "$owned_identity_file" ]; }; then
        migration_rollback_provisional_owned_process "$ws" || return 1
    fi
    if [ -e "$owned_pid_file" ] || [ -L "$owned_pid_file" ] ||
        [ -e "$owned_identity_file" ] || [ -L "$owned_identity_file" ]; then
        [ -f "$owned_pid_file" ] && [ ! -L "$owned_pid_file" ] || return 1
        [ -f "$owned_identity_file" ] && [ ! -L "$owned_identity_file" ] || return 1
        owned_pid=$(cat "$owned_pid_file") || return 1
        [[ "$owned_pid" =~ ^[0-9]+$ ]] && [ "$owned_pid" -gt 1 ] || return 1
        migration_read_owned_process_identity "$ws" owned_identity || return 1
        [ "${owned_identity[0]}" = "$owned_pid" ] || return 1
        if [ -e "/proc/$owned_pid" ]; then
            owned_state=$(migration_process_state "$owned_pid" 2>/dev/null) || {
                [ -e "/proc/$owned_pid" ] && return 1
                owned_state=""
            }
            case "$owned_state" in
                ""|Z|X|x) ;;
                *)
                    migration_owned_process_matches_identity \
                        "$owned_pid" "$ws" owned_identity || return 1
                    migration_terminate_owned_process \
                        "$owned_pid" "$ws" owned_identity || return 1
                    ;;
            esac
            wait "$owned_pid" 2>/dev/null || true
        fi
    fi
    for pidfile in "$ws/.beads/dolt-monitor.pid" "$ws/.beads/daemon.pid" "$ws/.beads/dolt-server.pid"; do
        if [ -f "$pidfile" ] && [ ! -L "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null) || true
            pidfile_name="${pidfile##*/}"
            if migration_pid_belongs_to_workspace "$pid" "$ws" "$pidfile_name"; then
                kill -9 -- "$pid" 2>/dev/null || true
            fi
        fi
    done
    migration_wait_server_port_free "$ws" || return 1
    if [ -n "$owned_pid" ]; then
        migration_remove_owned_identity_files "$ws" owned_identity || return 1
        migration_clear_provisional_owned_process "$ws"
    fi
    rm -f "$ws/.beads/bd.sock" "$ws/.beads/dolt-server.lock" 2>/dev/null || true
}

cleanup_workspace() {
    local ws="$1"
    migration_workspace_owned_by_harness "$ws" || return 1
    stop_dolt_server "$ws" || return 1
    release_migration_server_port "$ws" || return 1
    rm -rf -- "$ws"
}
