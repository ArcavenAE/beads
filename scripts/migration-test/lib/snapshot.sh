#!/bin/bash
# Snapshot capture and fidelity checking.
# Captures full JSON state of all issues, then compares field-by-field.

# Capture a full JSON snapshot of all issues in a workspace.
# Output: JSON array with one object per issue, sorted by title.
#
# Uses `bd list --json` which includes all fields we need for fidelity
# checking (id, title, status, priority, issue_type, comment_count, etc.)
# For richer data (labels, dependencies), also calls `bd show` per issue.
capture_snapshot() {
    local ws="$1"
    local bin="$2"

    # bd list --json returns a flat array of issue objects
    local list_json
    if ! list_json=$(bd_in "$ws" "$bin" list --json -n 0 --all 2>/dev/null); then
        echo "  FIDELITY: bd list failed while capturing snapshot" >&2
        echo "[]"
        return 1
    fi

    if ${STRICT_MODE:-false} && ! jq -e '
        type == "array" and
        length > 0 and
        all(.[];
            type == "object" and
            ((.id? | type) == "string") and
            ((.id? | length) > 0))
        ' >/dev/null 2>&1 <<< "$list_json"; then
        echo "  FIDELITY: bd list returned an invalid snapshot inventory" >&2
        echo "[]"
        return 1
    fi

    if [ -z "$list_json" ] || [ "$list_json" = "null" ] || [ "$list_json" = "[]" ]; then
        echo "[]"
        return 1
    fi

    # Extract IDs for detailed show queries
    local ids
    ids=$(echo "$list_json" | jq -r '.[].id // empty' 2>/dev/null) || true

    if [ -z "$ids" ]; then
        # No IDs extractable, return list output as-is
        echo "$list_json" | jq -S 'sort_by(.title // "")' 2>/dev/null || echo "$list_json"
        return 0
    fi

    # Collect detailed show output for each issue.
    # bd show --json returns an ARRAY (even for one item), so we flatten.
    local items="[]"
    while IFS= read -r id; do
        [ -z "$id" ] && continue
        local show_json
        # Current binaries require --include-comments for full bodies; older
        # releases included them by default and reject the newer flag.
        local show_ok=false
        if show_json=$(bd_in "$ws" "$bin" show "$id" --json --include-comments 2>/dev/null); then
            show_ok=true
        elif show_json=$(bd_in "$ws" "$bin" show "$id" --json 2>/dev/null); then
            show_ok=true
        fi
        if ! $show_ok; then
            echo "  FIDELITY: bd show failed for listed source id $id" >&2
            return 1
        fi
        if ${STRICT_MODE:-false} && ! jq -e --arg id "$id" '
            (if type == "array" then . else [.] end) |
            length == 1 and
            (.[0] | type == "object") and
            ((.[0].id? | type) == "string") and
            .[0].id == $id
            ' >/dev/null 2>&1 <<< "$show_json"; then
            echo "  FIDELITY: bd show returned an invalid snapshot for source id $id" >&2
            return 1
        fi
        if [ -n "$show_json" ] && [ "$show_json" != "null" ]; then
            # show returns an array — concatenate it
            items=$(echo "$items" | jq --argjson arr "$show_json" \
                'if ($arr | type) == "array" then . + $arr else . + [$arr] end' 2>/dev/null) || true
        fi
    done <<< "$ids"

    if ${STRICT_MODE:-false}; then
        local list_ids show_ids expected_id
        list_ids=$(echo "$list_json" | jq -c '[.[].id // empty] | sort' 2>/dev/null) || return 1
        show_ids=$(echo "$items" | jq -c '[.[].id // empty] | sort' 2>/dev/null) || return 1
        if [ "$show_ids" != "$list_ids" ]; then
            echo "  FIDELITY: list/show id inventories differ" >&2
            return 1
        fi
        for expected_id in "${DATASET_IDS[@]:-}"; do
            if ! echo "$items" | jq -e --arg id "$expected_id" 'any(.[]; .id == $id)' >/dev/null 2>&1; then
                echo "  FIDELITY: required source id $expected_id is absent from snapshot" >&2
                return 1
            fi
        done
    fi

    # Sort by title for stable comparison
    echo "$items" | jq -S 'sort_by(.title // "")' 2>/dev/null || echo "$items"
}

source_artifact_fingerprint() {
    local beads_dir="$1"
    local manifest_file digest

    [ -d "$beads_dir" ] && [ ! -L "$beads_dir" ] || return 1
    manifest_file=$(mktemp "${TMPDIR:-/tmp}/bd-source-fingerprint.XXXXXX") || return 1
    if ! (
        set -o pipefail
        cd "$beads_dir" || exit 1
        find . -mindepth 1 -print0 | LC_ALL=C sort -z | while IFS= read -r -d '' path; do
            local mode checksum target
            if [ -L "$path" ]; then
                target=$(readlink -- "$path") || exit 1
                printf 'link\0%s\0%s\0' "$path" "$target" || exit 1
            elif [ -d "$path" ]; then
                mode=$(stat -c '%a' -- "$path") || exit 1
                printf 'directory\0%s\0%s\0' "$path" "$mode" || exit 1
            elif [ -f "$path" ]; then
                mode=$(stat -c '%a' -- "$path") || exit 1
                checksum=$(sha256_file "$path") || exit 1
                printf 'file\0%s\0%s\0%s\0' "$path" "$mode" "$checksum" || exit 1
            else
                echo "  FIDELITY: unsupported path in historical source tree: $beads_dir/$path" >&2
                exit 1
            fi
        done
    ) > "$manifest_file"; then
        rm -f "$manifest_file"
        return 1
    fi
    digest=$(sha256_file "$manifest_file") || {
        rm -f "$manifest_file"
        return 1
    }
    rm -f "$manifest_file"
    printf '%s\n' "$digest"
}

# Validate the exact source values that make a strict historical fixture
# meaningful. Without this check, an unsupported create flag can silently
# disappear from both snapshots and produce a false fidelity pass.
strict_snapshot_has_expected_fixture() {
    local version="$1"
    local snapshot="$2"

    case "$version" in
        v0.49.6|v0.55.4|v0.57.0|v0.62.0|v0.63.3)
            local epic_id="${DATASET_IDS[epic]:-}"
            local standalone_id="${DATASET_IDS[standalone]:-}"
            local closed_id="${DATASET_IDS[closed]:-}"
            local task_id="${DATASET_IDS[task]:-}"
            local bug_id="${DATASET_IDS[bug]:-}"
            [ -n "$epic_id" ] && [ -n "$standalone_id" ] && [ -n "$closed_id" ] && \
                [ -n "$task_id" ] && [ -n "$bug_id" ] || return 1
            jq -e \
                --arg epic "$epic_id" \
                --arg standalone "$standalone_id" \
                --arg closed "$closed_id" \
                --arg task "$task_id" \
                --arg bug "$bug_id" '
                length == 5 and
                any(.[];
                    .id == $epic and
                    .title == "Migration epic" and
                    .description == "Epic for migration testing" and
                    .priority == 2 and
                    .issue_type == "epic" and
                    .status == "open" and
                    ((.dependencies // []) | length == 0)) and
                any(.[];
                    .id == $standalone and
                    .title == "Standalone detailed task" and
                    .description == "This task has a detailed description for fidelity testing." and
                    .notes == "Historical notes must survive the upgrade." and
                    .design == "Historical design must survive the upgrade." and
                    .acceptance_criteria == "Historical acceptance criteria must survive the upgrade." and
                    .external_ref == "legacy-upgrade-42" and
                    ((.dependencies // []) | length == 0)) and
                any(.[];
                    .id == $closed and
                    .status == "closed" and
                    ((.dependencies // []) | length == 0)) and
                any(.[];
                    .id == $task and
                    .parent == $epic and
                    ((.dependencies // [] |
                        map({
                            id: (.id // .depends_on_id),
                            type: (.dependency_type // .type)
                        }) |
                        sort_by(.id, .type)) ==
                        [{id: $epic, type: "parent-child"}]) and
                    ((.labels // []) | index("urgent") != null) and
                    ((.comments // [] | map({author, text})) |
                        index({"author":"legacy-author","text":"Historical comment must survive the upgrade."}) != null)) and
                any(.[];
                    .id == $bug and
                    ((.dependencies // [] |
                        map({
                            id: (.id // .depends_on_id),
                            type: (.dependency_type // .type)
                        }) |
                        sort_by(.id, .type)) ==
                        [{id: $task, type: "blocks"}]))
                ' "$snapshot" >/dev/null 2>&1 || {
                    echo "  FIDELITY: $version source fixture is missing exact required values" >&2
                    return 1
                }
            ;;
        *)
            echo "  FIDELITY: no exact source-fixture contract for $version" >&2
            return 1
            ;;
    esac
}

classic_sqlite_artifact_manifest() {
    local beads_dir="$1"
    local suffix="${2:-}"
    local relative path checksum found_database=false

    for relative in "${CLASSIC_SQLITE_ROLLBACK_FILES[@]}"; do
        path="$beads_dir/${relative}${suffix}"
        if [ -e "$path" ]; then
            if [ ! -f "$path" ]; then
                echo "  FIDELITY: rollback artifact is not a regular file: $path" >&2
                return 1
            fi
            checksum=$(sha256_file "$path") || return 1
            printf '%s=%s\n' "$relative" "$checksum"
            [ "$relative" = "beads.db" ] && found_database=true
        fi
    done
    $found_database || {
        echo "  FIDELITY: classic SQLite database is missing" >&2
        return 1
    }
}

verify_retained_sqlite_source() {
    local beads_dir="$1"
    local expected_manifest="$2"
    local actual_manifest
    actual_manifest=$(classic_sqlite_artifact_manifest "$beads_dir" ".pre-migration") || return 1
    if [ "$actual_manifest" != "$expected_manifest" ]; then
        echo "  FIDELITY: retained classic SQLite rollback artifacts changed" >&2
        return 1
    fi
}

legacy_dolt_artifact_manifest() {
    local root="$1"
    local dolt_dir="$root/dolt"
    local manifest_file digest relative path mode checksum

    if [ -L "$root" ] || [ ! -d "$root" ]; then
        echo "  FIDELITY: legacy Dolt artifact root is not a regular directory: $root" >&2
        return 1
    fi
    if [ -L "$dolt_dir" ] || [ ! -d "$dolt_dir" ]; then
        echo "  FIDELITY: legacy Dolt source is not a regular directory: $dolt_dir" >&2
        return 1
    fi

    manifest_file=$(mktemp "${TMPDIR:-/tmp}/bd-legacy-dolt-manifest.XXXXXX") || return 1
    if ! (
        set -o pipefail
        cd "$root" || exit 1

        if ! find dolt -mindepth 0 -print0 | sort -z | while IFS= read -r -d '' path; do
            if [ -L "$path" ]; then
                echo "  FIDELITY: symlink in legacy Dolt source: $root/$path" >&2
                exit 1
            elif [ -d "$path" ]; then
                mode=$(stat -c '%a' -- "$path") || exit 1
                printf 'directory\0%s\0%s\0' "$path" "$mode"
            elif [ -f "$path" ]; then
                mode=$(stat -c '%a' -- "$path") || exit 1
                checksum=$(sha256_file "$path") || exit 1
                printf 'file\0%s\0%s\0%s\0' "$path" "$mode" "$checksum"
            else
                echo "  FIDELITY: non-regular path in legacy Dolt source: $root/$path" >&2
                exit 1
            fi
        done; then
            exit 1
        fi

        for relative in "${LEGACY_DOLT_ROLLBACK_FILES[@]}"; do
            path="$relative"
            if [ -L "$path" ]; then
                echo "  FIDELITY: symlink rollback artifact: $root/$path" >&2
                exit 1
            fi
            if [ -e "$path" ]; then
                if [ ! -f "$path" ]; then
                    echo "  FIDELITY: rollback artifact is not a regular file: $root/$path" >&2
                    exit 1
                fi
                mode=$(stat -c '%a' -- "$path") || exit 1
                checksum=$(sha256_file "$path") || exit 1
                printf 'file\0%s\0%s\0%s\0' "$path" "$mode" "$checksum"
            fi
        done
    ) > "$manifest_file"; then
        rm -f "$manifest_file"
        return 1
    fi

    digest=$(sha256_file "$manifest_file") || {
        rm -f "$manifest_file"
        return 1
    }
    rm -f "$manifest_file"
    printf '%s\n' "$digest"
}

verify_retained_legacy_dolt_source() {
    local beads_dir="$1"
    local expected_manifest="$2"
    local retained="$beads_dir/legacy-dolt.pre-migration"

    verify_legacy_dolt_rollback_root "$retained" "$expected_manifest"
}

legacy_dolt_rollback_inventory_is_exact() {
    local root="$1"
    local inventory_file name allowed relative invalid_name=""

    if [ -L "$root" ] || [ ! -d "$root" ]; then
        echo "  FIDELITY: retained legacy Dolt source is not a regular directory: $root" >&2
        return 1
    fi
    inventory_file=$(mktemp "${TMPDIR:-/tmp}/bd-legacy-dolt-inventory.XXXXXX") || return 1
    if ! find "$root" -mindepth 1 -maxdepth 1 -printf '%f\0' > "$inventory_file"; then
        rm -f "$inventory_file"
        return 1
    fi

    while IFS= read -r -d '' name; do
        allowed=false
        if [ "$name" = "dolt" ]; then
            allowed=true
        else
            for relative in "${LEGACY_DOLT_ROLLBACK_FILES[@]}"; do
                if [ "$name" = "$relative" ]; then
                    allowed=true
                    break
                fi
            done
        fi
        if ! $allowed; then
            invalid_name="$name"
            break
        fi
    done < "$inventory_file"
    rm -f "$inventory_file"
    if [ -n "$invalid_name" ]; then
        echo "  FIDELITY: unexpected path in retained legacy Dolt source: $root/$invalid_name" >&2
        return 1
    fi
}

verify_legacy_dolt_rollback_root() {
    local root="$1"
    local expected_manifest="$2"
    local actual_manifest

    if [ -z "$expected_manifest" ]; then
        echo "  FIDELITY: expected legacy Dolt rollback manifest is empty" >&2
        return 1
    fi
    legacy_dolt_rollback_inventory_is_exact "$root" || return 1
    actual_manifest=$(legacy_dolt_artifact_manifest "$root") || return 1
    if [ "$actual_manifest" != "$expected_manifest" ]; then
        echo "  FIDELITY: retained legacy Dolt rollback artifacts changed" >&2
        return 1
    fi
}

# Compare two snapshots and report fidelity.
# Returns the number of fidelity violations found.
check_fidelity() {
    local version="$1"
    local before="$2"
    local after="$3"
    local violations=0

    # Check we have data in both snapshots
    local before_count after_count
    before_count=$(jq 'length' "$before" 2>/dev/null) || before_count=0
    after_count=$(jq 'length' "$after" 2>/dev/null) || after_count=0

    if [ "$before_count" -eq 0 ]; then
        echo "  FIDELITY: no items in before-snapshot (nothing to compare)"
        return 0
    fi

    if [ "$after_count" -eq 0 ]; then
        echo -e "  ${RED:-}FIDELITY VIOLATION: all $before_count items lost after upgrade${NC:-}"
        return "$before_count"
    fi

    if [ "$after_count" -lt "$before_count" ]; then
        echo -e "  ${RED:-}FIDELITY VIOLATION: item count dropped from $before_count to $after_count${NC:-}"
        violations=$(( before_count - after_count ))
    fi
    if ${STRICT_MODE:-false} && [ "$after_count" -gt "$before_count" ]; then
        echo -e "  ${RED:-}FIDELITY VIOLATION: item count grew from $before_count to $after_count${NC:-}"
        violations=$(( violations + after_count - before_count ))
    fi

    # Critical invariant fields to check.
    # bd uses "issue_type" not "type" in its JSON output.
    local INVARIANTS=("title" "description" "priority" "issue_type")
    if ${STRICT_MODE:-false}; then
        INVARIANTS+=("id" "notes" "design" "acceptance_criteria" "external_ref" "status" "parent")
    fi

    local i=0
    while [ "$i" -lt "$before_count" ]; do
        local title
        title=$(jq -r ".[$i].title // \"\"" "$before" 2>/dev/null)

        # Skip items with no title (probe issues, etc.)
        if [ -z "$title" ] || [ "$title" = "__probe__" ]; then
            i=$((i + 1))
            continue
        fi

        # Find matching item in after-snapshot by title
        local match
        match=$(jq --arg t "$title" '[.[] | select(.title == $t)] | .[0]' "$after" 2>/dev/null)

        if [ -z "$match" ] || [ "$match" = "null" ]; then
            echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' missing after upgrade${NC:-}"
            violations=$((violations + 1))
            i=$((i + 1))
            continue
        fi
        if ${STRICT_MODE:-false}; then
            local match_count
            match_count=$(jq --arg t "$title" '[.[] | select(.title == $t)] | length' "$after" 2>/dev/null) || match_count=0
            if [ "$match_count" -ne 1 ]; then
                echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' has $match_count post-upgrade matches, want exactly 1${NC:-}"
                violations=$((violations + 1))
            fi
        fi

        # Check each invariant field
        for field in "${INVARIANTS[@]}"; do
            local before_val after_val
            if ${STRICT_MODE:-false}; then
                before_val=$(jq -c --arg field "$field" ".[$i] | .[\$field]" "$before" 2>/dev/null)
                after_val=$(echo "$match" | jq -c --arg field "$field" '.[ $field ]' 2>/dev/null)
            else
                before_val=$(jq -r ".[$i].${field} // \"\"" "$before" 2>/dev/null)
                after_val=$(echo "$match" | jq -r ".${field} // \"\"" 2>/dev/null)

                # Skip fields unavailable in the historical source version.
                [ -z "$before_val" ] && continue
                [ "$before_val" = "null" ] && continue
            fi

            if [ "$before_val" != "$after_val" ]; then
                echo -e "  ${RED:-}FIDELITY VIOLATION: '$title'.${field}: '$before_val' -> '$after_val'${NC:-}"
                violations=$((violations + 1))
            fi
        done

        # Check status category (open vs closed)
        local before_status after_status
        before_status=$(jq -r ".[$i].status // \"\"" "$before" 2>/dev/null)
        after_status=$(echo "$match" | jq -r ".status // \"\"" 2>/dev/null)
        if ! ${STRICT_MODE:-false} && [ -n "$before_status" ] && [ -n "$after_status" ]; then
            local before_closed after_closed
            before_closed=$(echo "$before_status" | grep -ciE "closed|done|resolved" || true)
            after_closed=$(echo "$after_status" | grep -ciE "closed|done|resolved" || true)
            if [ "$before_closed" -ne "$after_closed" ]; then
                echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' status category changed: '$before_status' -> '$after_status'${NC:-}"
                violations=$((violations + 1))
            fi
        fi

        # Check dependency preservation
        local before_deps after_deps
        if ${STRICT_MODE:-false}; then
            before_deps=$(jq -c ".[$i].dependencies // [] |
                map({
                    id: (.id // .depends_on_id),
                    type: (.dependency_type // .type)
                }) | sort_by(.id, .type)" "$before" 2>/dev/null)
            after_deps=$(echo "$match" | jq -c '.dependencies // [] |
                map({
                    id: (.id // .depends_on_id),
                    type: (.dependency_type // .type)
                }) | sort_by(.id, .type)' 2>/dev/null)
        else
            before_deps=$(jq -r ".[$i].dependencies // [] | [.[].id // .] | sort | join(\",\")" "$before" 2>/dev/null)
            after_deps=$(echo "$match" | jq -r ".dependencies // [] | [.[].id // .] | sort | join(\",\")" 2>/dev/null)
        fi
        if { ${STRICT_MODE:-false} || [ -n "$before_deps" ]; } && [ "$before_deps" != "$after_deps" ]; then
            echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' dependencies changed: '$before_deps' -> '$after_deps'${NC:-}"
            violations=$((violations + 1))
        fi

        # Check comment preservation. Strict mode compares the user-authored
        # text, not only the count, so content rewrites cannot pass.
        local before_comments after_comments
        if ${STRICT_MODE:-false}; then
            before_comments=$(jq -c ".[$i].comments // [] | map({author: (.author // \"\"), text: (.text // \"\")}) | sort_by(.author, .text)" "$before" 2>/dev/null)
            after_comments=$(echo "$match" | jq -c '.comments // [] | map({author: (.author // ""), text: (.text // "")}) | sort_by(.author, .text)' 2>/dev/null)
        else
            before_comments=$(jq -r ".[$i].comment_count // (.comments // [] | length) // 0" "$before" 2>/dev/null)
            after_comments=$(echo "$match" | jq -r ".comment_count // (.comments // [] | length) // 0" 2>/dev/null)
            [ -z "$before_comments" ] && before_comments=0
            [ -z "$after_comments" ] && after_comments=0
        fi
        if { ${STRICT_MODE:-false} || [ "$before_comments" != "0" ]; } && [ "$before_comments" != "$after_comments" ]; then
            echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' comments changed: $before_comments -> $after_comments${NC:-}"
            violations=$((violations + 1))
        fi

        # Check label preservation
        local before_labels after_labels
        before_labels=$(jq -r ".[$i].labels // [] | sort | join(\",\")" "$before" 2>/dev/null)
        after_labels=$(echo "$match" | jq -r ".labels // [] | sort | join(\",\")" 2>/dev/null)
        if { ${STRICT_MODE:-false} || [ -n "$before_labels" ]; } && [ "$before_labels" != "$after_labels" ]; then
            echo -e "  ${RED:-}FIDELITY VIOLATION: '$title' labels changed: '$before_labels' -> '$after_labels'${NC:-}"
            violations=$((violations + 1))
        fi

        i=$((i + 1))
    done

    if [ "$violations" -eq 0 ]; then
        echo -e "  ${GREEN:-}FIDELITY: all $before_count items verified, no violations${NC:-}"
    fi

    return "$violations"
}

# Post-upgrade blocker-query assertions.
#
# check_fidelity (above) only reads back list/show JSON — it never exercises
# bd's blocker-aware query paths (bd ready, bd blocked) or bd close on a
# migrated DB. That is exactly the surface of the historical "bd close"
# errno 1105 failure on a stale post-migration dependency schema (mybd-ihg5,
# verified manually for the 1.0.5 release in mybd-kdxj). This function gives
# that path permanent regression coverage.
#
# Uses the BUG->TASK dependency created by create_dataset() (features.sh):
# `dep add "$bug_id" "$task_id"` means the bug DEPENDS ON the task, i.e. the
# task is the blocker and the bug is the blocked dependent. Requires
# DATASET_IDS[task] and DATASET_IDS[bug] to be set and "dependency" to be
# present in DATASET_FEATURES; skips gracefully (0 violations) when the
# source version's dataset has no dependency (e.g. `dep add` unsupported).
#
# Args: ws bin
# Returns the number of violations found.
check_blocker_paths() {
    local ws="$1"
    local bin="$2"
    local violations=0

    local has_dep=false
    local f
    for f in "${DATASET_FEATURES[@]:-}"; do
        if [ "$f" = "dependency" ]; then
            has_dep=true
            break
        fi
    done
    if ! $has_dep; then
        echo "  BLOCKER-CHECK: skipped (no dependency in dataset)"
        return 0
    fi

    local blocker_id="${DATASET_IDS[task]:-}"
    local dependent_id="${DATASET_IDS[bug]:-}"
    if [ -z "$blocker_id" ] || [ -z "$dependent_id" ]; then
        echo "  BLOCKER-CHECK: skipped (task/bug id missing from dataset)"
        return 0
    fi

    # 1. bd blocked must list the dependent (bug) while the blocker (task) is
    #    still open — proves is_blocked survived migration on the dependent.
    local blocked_json blocked_status=0
    blocked_json=$(bd_in "$ws" "$bin" blocked --json 2>/dev/null) || blocked_status=$?
    if [ "$blocked_status" -ne 0 ]; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd blocked' exited $blocked_status${NC:-}"
        violations=$((violations + 1))
    fi
    if ! echo "$blocked_json" | jq -e --arg id "$dependent_id" 'any(.[]?; .id == $id)' >/dev/null 2>&1; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd blocked' does not list dependent '$dependent_id' while blocker '$blocker_id' is open${NC:-}"
        violations=$((violations + 1))
    fi

    # 2. bd ready must NOT list the dependent, but MUST list the blocker.
    local ready_json ready_status=0
    ready_json=$(bd_in "$ws" "$bin" ready --json 2>/dev/null) || ready_status=$?
    if [ "$ready_status" -ne 0 ]; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd ready' exited $ready_status${NC:-}"
        violations=$((violations + 1))
    fi
    if echo "$ready_json" | jq -e --arg id "$dependent_id" 'any(.[]?; .id == $id)' >/dev/null 2>&1; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd ready' lists blocked dependent '$dependent_id'${NC:-}"
        violations=$((violations + 1))
    fi
    if ! echo "$ready_json" | jq -e --arg id "$blocker_id" 'any(.[]?; .id == $id)' >/dev/null 2>&1; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd ready' does not list open blocker '$blocker_id'${NC:-}"
        violations=$((violations + 1))
    fi

    # 3. Closing the blocker must succeed on the migrated schema (the errno
    #    1105 surface) and must unblock the dependent (is_blocked recompute).
    if ! bd_in "$ws" "$bin" close "$blocker_id" >/dev/null 2>&1; then
        echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: 'bd close $blocker_id' failed after migration (errno 1105 / stale-schema regression)${NC:-}"
        violations=$((violations + 1))
    else
        local ready_after_json ready_after_status=0
        ready_after_json=$(bd_in "$ws" "$bin" ready --json 2>/dev/null) || ready_after_status=$?
        if [ "$ready_after_status" -ne 0 ]; then
            echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: post-close 'bd ready' exited $ready_after_status${NC:-}"
            violations=$((violations + 1))
        fi
        if ! echo "$ready_after_json" | jq -e --arg id "$dependent_id" 'any(.[]?; .id == $id)' >/dev/null 2>&1; then
            echo -e "  ${RED:-}BLOCKER-CHECK VIOLATION: dependent '$dependent_id' not ready after blocker '$blocker_id' closed${NC:-}"
            violations=$((violations + 1))
        fi
    fi

    if [ "$violations" -eq 0 ]; then
        echo -e "  ${GREEN:-}BLOCKER-CHECK: bd blocked/ready/close all correct on migrated DB${NC:-}"
    fi

    return "$violations"
}
