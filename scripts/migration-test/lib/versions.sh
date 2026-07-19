#!/bin/bash
# Storage era definitions and upgrade path matrix.

# Representative versions for each storage era.
# Format: era_name|representative_version|storage_dir|description
ERAS=(
    "sqlite|v0.49.6|beads.db|SQLite era (pre-Dolt)"
    "dolt_server|v0.62.0|dolt|Dolt server mode"
    "embedded_current|v0.63.3|embeddeddolt|Current embedded Dolt"
)

# Direct upgrade paths to test: source_version
DIRECT_PATHS=(
    "v0.49.6"
    "v0.57.0"
    "v0.62.0"
    "v0.63.3"
)

# Classic SQLite files that must be retained byte-for-byte for rollback before
# the manual bridge removes the active copies.
declare -ar CLASSIC_SQLITE_ROLLBACK_FILES=(
    "beads.db"
    "beads.db-wal"
    "beads.db-shm"
    "metadata.json"
    "config.json"
    "config.yaml"
)

# Legacy Dolt-server metadata that must be retained with the dolt/ directory
# before the manual bridge clears the active source.
declare -ar LEGACY_DOLT_ROLLBACK_FILES=(
    "metadata.json"
    "config.json"
    "config.yaml"
    "issues.jsonl"
)

# Release artifacts and expected qualification outcomes for strict CI lanes.
# Strict entries are deliberately explicit: adding a historical lane requires
# reviewing the official asset, checksum, source capabilities, and supported
# migration outcome instead of silently discovering them at runtime.
declare -Ar STRICT_RELEASE_ASSETS=(
    ["v0.49.6|linux|amd64"]="beads_0.49.6_linux_amd64.tar.gz"
    ["v0.55.4|linux|amd64"]="beads_0.55.4_linux_amd64.tar.gz"
    ["v0.57.0|linux|amd64"]="beads_0.57.0_linux_amd64.tar.gz"
    ["v0.62.0|linux|amd64"]="beads_0.62.0_linux_amd64.tar.gz"
    ["v0.63.3|linux|amd64"]="beads_0.63.3_linux_amd64.tar.gz"
)
declare -Ar STRICT_RELEASE_SHA256=(
    ["v0.49.6|linux|amd64"]="8546dc9a47e11dc31ac2bc9a0224a9c690975e91850932cbb62623053fbb7db8"
    ["v0.55.4|linux|amd64"]="e0fa25456dd82890230eef17653448a0bf995104c78864be91c5ed84426a5f49"
    ["v0.57.0|linux|amd64"]="f8629d5627bed7d25f06f92334addc171d679f9aed9d08c5d42a9684205dc04b"
    ["v0.62.0|linux|amd64"]="4cca7265b22e5c3ca8d62ab0b9752bec31f68b7f5fa636282a4c7e5454c35535"
    ["v0.63.3|linux|amd64"]="5f4efd2e010209b3f381dbcd783b2a3a652f50ea72f40ef04c8ba434d408bf9e"
)
declare -Ar STRICT_EXPECTED_STATUSES=(
    ["v0.49.6"]="MANUAL"
    ["v0.55.4"]="MANUAL"
    ["v0.57.0"]="MANUAL"
    ["v0.62.0"]="MANUAL"
    ["v0.63.3"]="AUTO"
)
declare -Ar STRICT_EXPECTED_RECIPES=(
    ["v0.49.6"]="sqlite_to_current"
    ["v0.55.4"]="server_to_embedded"
    ["v0.57.0"]="server_to_embedded"
    ["v0.62.0"]="public_v062_bridge"
    ["v0.63.3"]=""
)
declare -Ar STRICT_EXPECTED_FEATURES=(
    ["v0.49.6"]="epic task bug dependency standalone closed label comment"
    ["v0.55.4"]="epic task bug dependency standalone closed label comment"
    ["v0.57.0"]="epic task bug dependency standalone closed label comment"
    ["v0.62.0"]="epic task bug dependency standalone closed label comment"
    ["v0.63.3"]="epic task bug dependency standalone closed label comment"
)
declare -Ar SERVER_BRIDGE_STRATEGIES=(
    ["v0.55.4"]="native_export"
    ["v0.57.0"]="native_export_show_comments"
)
declare -Ar SERVER_BOOTSTRAP_STRATEGIES=(
    ["v0.62.0"]="prestarted_server"
)
declare -Ar STRICT_REQUIRED_DOLT_VERSIONS=(
    ["v0.57.0"]="2.1.8"
    ["v0.62.0"]="1.84.0"
)
declare -Ar STRICT_REQUIRED_DOLT_SHA256=(
    ["v0.57.0|linux|amd64"]="f66318f08ed66e409fc39363ae0fff8ce6fbf6dba9f5bac632b91527b9632a74"
    ["v0.62.0|linux|amd64"]="afcdaa9530ae0b4f317ed6041a41d20096e156b2556eb0e03c7c57a624ccc0b3"
)

strict_release_asset() {
    local value="${STRICT_RELEASE_ASSETS["$1|$2|$3"]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

strict_release_sha256() {
    local value="${STRICT_RELEASE_SHA256["$1|$2|$3"]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

strict_expected_status() {
    local value="${STRICT_EXPECTED_STATUSES[$1]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

strict_expected_recipe() {
    local key="$1"
    [[ ${STRICT_EXPECTED_RECIPES["$key"]+present} == present ]] || return 1
    printf '%s\n' "${STRICT_EXPECTED_RECIPES["$key"]}"
}

strict_expected_features() {
    local value="${STRICT_EXPECTED_FEATURES[$1]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

server_bridge_strategy() {
    local value="${SERVER_BRIDGE_STRATEGIES[$1]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

server_bootstrap_strategy() {
    local value="${SERVER_BOOTSTRAP_STRATEGIES[$1]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

strict_required_dolt_version() {
    local value="${STRICT_REQUIRED_DOLT_VERSIONS[$1]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

strict_required_dolt_sha256() {
    local value="${STRICT_REQUIRED_DOLT_SHA256["$1|$2|$3"]:-}"
    [ -n "$value" ] || return 1
    printf '%s\n' "$value"
}

# Local strict-runtime gate. This is deliberately version-string-only: it
# confirms the resolved dolt reports the pinned historical version, nothing
# more. Authoritative binary-integrity enforcement (sha256 of the downloaded
# release archive against strict_required_dolt_sha256) is CI-side, in
# .github/workflows/migration-test.yml. We do not checksum the local dolt here
# because a developer's installed dolt 1.84.0 can be a legitimately different
# build (package manager, `go install`, other arch) with a different hash, so
# enforcing the release-archive SHA against an arbitrary local binary would
# reject authentic runtimes. CI owns integrity; this only pins the version.
verify_strict_historical_runtime() {
    local version="$1"
    local expected output

    if ! expected=$(strict_required_dolt_version "$version"); then
        return 0
    fi
    command -v dolt >/dev/null 2>&1 || return 1
    output=$(dolt version 2>/dev/null) || return 1
    grep -Fqx "dolt version $expected" <<< "$output"
}

strict_fixture_has_expected_features() {
    local version="$1"
    shift
    local expected feature actual
    expected=$(strict_expected_features "$version") || return 1
    actual=" $* "
    for feature in $expected; do
        if [[ "$actual" != *" $feature "* ]]; then
            printf 'missing required source feature %s for %s\n' "$feature" "$version" >&2
            return 1
        fi
    done
}

# Stepping-stone paths: version1,version2,...,versionN
# Each version upgrades to the next, then finally to candidate.
#
# NOTE: Multi-hop paths through old releases are not a supported upgrade path.
# Old binaries (v0.57.0, v0.55.4, v0.63.3) have inherent bugs that cannot be
# patched retroactively. Users should always upgrade directly to the latest
# release — the direct paths above cover all supported eras.
STEPPING_STONE_PATHS=()

# Semver comparison: returns 0 if $1 <= $2
version_lte() {
    local v1="${1#v}"
    local v2="${2#v}"
    [ "$(printf '%s\n%s\n' "$v1" "$v2" | sort -V | head -1)" = "$v1" ]
}

# Semver comparison: returns 0 if $1 < $2
version_lt() {
    local v1="${1#v}"
    local v2="${2#v}"
    [ "$v1" != "$v2" ] && version_lte "$1" "$2"
}

# Returns the era name for a given version.
get_era() {
    local version="$1"
    if version_lt "$version" "v0.50.0"; then
        echo "sqlite"
    elif version_lt "$version" "v0.63.3"; then
        echo "dolt_server"
    else
        echo "embedded_current"
    fi
}
