#!/bin/bash
# Recipe: qualified legacy Dolt directory → current embedded Dolt.
#
# Each server-era release needs an explicit extraction strategy. v0.55.4 has
# a lossless native export for the qualified fixture. v0.57.0 needs its native
# export enriched with comment bodies from one-item show queries. v0.56.1 and
# v0.58.0 remain unqualified. v0.62.0 must use the public bridge instead of
# this harness-private recipe.
#
# Strategy:
#   1. Stop any running Dolt server
#   2. Extract the qualified core fixture via the old binary
#   3. Stop server, clear stale metadata, init with candidate
#   4. If candidate DB is empty, reimport from JSONL export
#
# User-facing instructions:
#   Use the pinned migration harness for qualified v0.55.4 and v0.57.0 core
#   fixtures. It stops the historical server, retains a byte-verified rollback
#   tree, extracts and validates JSONL, and only then initializes the candidate.

publish_legacy_dolt_rollback() {
    mv --no-target-directory --no-clobber --no-copy -- "$1" "$2"
}

remove_file_and_verify_absent() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -f -- "$path" || return 1
    fi
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

remove_tree_and_verify_absent() {
    local path="$1"
    if [ -e "$path" ] || [ -L "$path" ]; then
        rm -rf -- "$path" || return 1
    fi
    [ ! -e "$path" ] && [ ! -L "$path" ]
}

migration_jsonl_id_inventory() {
    local path="$1"
    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    jq -erRs '
        (split("\n") |
            if length > 0 and .[-1] == "" then .[:-1] else . end) as $lines |
        if ($lines | length) == 0 or any($lines[]; test("\\S") | not) then
            error("empty or blank JSONL record")
        else
            $lines | map(fromjson) |
            if all(.[];
                type == "object" and
                ((.id? | type) == "string") and
                ((.id? | length) > 0))
            then .[].id | @json
            else error("invalid issue record")
            end
        end
    ' "$path"
}

migration_jsonl_matches_snapshot() {
    local path="$1"
    local snapshot="$2"
    local export_ids expected_ids

    export_ids=$(migration_jsonl_id_inventory "$path" 2>/dev/null) || return 1
    [ -n "$export_ids" ] || return 1
    expected_ids=$(jq -er '
        if type == "array" and length > 0 and
            all(.[];
                type == "object" and
                ((.id? | type) == "string") and
                ((.id? | length) > 0))
        then .[].id | @json
        else error("invalid source snapshot")
        end
    ' "$snapshot" 2>/dev/null) || return 1
    [ -n "$expected_ids" ] || return 1

    [ -z "$(printf '%s\n' "$export_ids" | LC_ALL=C sort | uniq -d)" ] || return 1
    [ -z "$(printf '%s\n' "$expected_ids" | LC_ALL=C sort | uniq -d)" ] || return 1
    [ "$(printf '%s\n' "$export_ids" | LC_ALL=C sort)" = \
        "$(printf '%s\n' "$expected_ids" | LC_ALL=C sort)" ]
}

migration_jsonl_is_snapshot_subset() {
    local path="$1"
    local snapshot="$2"
    local existing_ids expected_ids extra_ids

    [ -f "$path" ] && [ ! -L "$path" ] || return 1
    [ -s "$path" ] || return 0
    existing_ids=$(migration_jsonl_id_inventory "$path" 2>/dev/null) || return 1
    expected_ids=$(jq -er '.[].id | @json' "$snapshot" 2>/dev/null) || return 1
    [ -z "$(printf '%s\n' "$existing_ids" | LC_ALL=C sort | uniq -d)" ] || return 1
    extra_ids=$(comm -23 \
        <(printf '%s\n' "$existing_ids" | LC_ALL=C sort) \
        <(printf '%s\n' "$expected_ids" | LC_ALL=C sort)) || return 1
    [ -z "$extra_ids" ]
}

v057_export_matches_snapshot() {
    local export_path="$1"
    local before_snapshot="$2"
    local version="$3"

    jq -en \
        --slurpfile exports "$export_path" \
        --slurpfile before "$before_snapshot" \
        --arg version "$version" '
        def by_id: map({key: .id, value: .}) | from_entries;
        def normalize_version_derived_fields:
            if $version == "v0.62.0" then
                del(.epic_closeable, .epic_closed_children, .epic_total_children)
            else . end;
        def core:
            normalize_version_derived_fields |
            del(
                .labels,
                .dependencies,
                .dependents,
                .comments,
                .comment_count,
                .dependency_count,
                .dependent_count,
                .parent
            );
        def has_unsupported_issue_data:
            has("crystallizes") or
            has("creator") or
            has("quality_score") or
            has("validations") or
            has("hook_bead") or
            has("role_bead") or
            has("agent_state") or
            has("last_activity") or
            has("role_type") or
            has("rig") or
            has("holder") or
            has("closed_by_session");
        ($exports | by_id) as $export |
        ($before[0] | by_id) as $expected |
        (($export | keys | sort) == ($expected | keys | sort)) and
        ([($export | keys[]) as $id |
            ($export[$id].labels // []) as $export_labels |
            ($expected[$id].labels // []) as $expected_labels |
            ($export[$id].dependencies // []) as $export_dependencies |
            ($expected[$id].dependencies // []) as $expected_dependencies |
            ($export[$id].dependency_count) as $dependency_count |
            ($export[$id].comment_count) as $comment_count |
            (($export[$id] | core) == ($expected[$id] | core)) and
            (($export[$id] | has_unsupported_issue_data) | not) and
            (($export_labels | type) == "array") and
            (all($export_labels[]; type == "string")) and
            (($export_labels | length) == ($export_labels | unique | length)) and
            (($export_labels | sort) == ($expected_labels | sort)) and
            (($export_dependencies | type) == "array") and
            (all($export_dependencies[];
                type == "object" and
                .issue_id == $id and
                ((.depends_on_id? | type) == "string") and
                ((.depends_on_id? | length) > 0) and
                ((.type? | type) == "string") and
                ((.type? | length) > 0) and
                ((.metadata? // "{}") as $metadata |
                    (($metadata | type) == "string") and
                    ((try ($metadata | fromjson) catch null) == {})) and
                ((.thread_id? // "") == ""))) and
            (($dependency_count | type) == "number") and
            ($dependency_count >= 0) and
            (($dependency_count | floor) == $dependency_count) and
            ($dependency_count ==
                ([$export_dependencies[] | select(.type == "blocks")] | length)) and
            (([$export_dependencies[] | {id: .depends_on_id, type: .type}] |
                sort_by(.id, .type)) ==
             ([$expected_dependencies[] | {id: .id, type: .dependency_type}] |
                sort_by(.id, .type))) and
            (($comment_count | type) == "number") and
            ($comment_count >= 0) and
            (($comment_count | floor) == $comment_count)
        ] | all)
    ' >/dev/null 2>&1
}

v057_export_and_show_comments_agree() {
    local export_path="$1"
    local show_path="$2"
    local before_snapshot="$3"
    local version="$4"

    jq -en \
        --slurpfile exports "$export_path" \
        --slurpfile shows "$show_path" \
        --slurpfile before "$before_snapshot" \
        --arg version "$version" '
        def by_id: map({key: .id, value: .}) | from_entries;
        def normalize_version_derived_fields:
            if $version == "v0.62.0" then
                del(.epic_closeable, .epic_closed_children, .epic_total_children)
            else . end;
        ($exports | by_id) as $export |
        ($shows | by_id) as $show |
        ($before[0] | by_id) as $expected |
        (($export | keys | sort) == ($show | keys | sort)) and
        (($export | keys | sort) == ($expected | keys | sort)) and
        ([($export | keys[]) as $id |
            ($export[$id].comment_count) as $count |
            ($show[$id].comments // []) as $comments |
            ($expected[$id].comments // []) as $expected_comments |
            (($count | type) == "number") and
            ($count >= 0) and
            (($count | floor) == $count) and
            (($comments | type) == "array") and
            ($count == ($comments | length)) and
            ($comments == $expected_comments) and
            (($show[$id] | normalize_version_derived_fields) ==
                ($expected[$id] | normalize_version_derived_fields))
        ] | all)
    ' >/dev/null 2>&1
}

enrich_v057_export_comments() {
    local ws="$1"
    local old_bin="$2"
    local export_path="$3"
    local before_snapshot="$4"
    local enriched_path="$5"
    local version="$6"
    local show_path ids encoded_id id show_json show_record
    local extraction_ok=true

    [ -f "$export_path" ] && [ ! -L "$export_path" ] || return 1
    [ -f "$before_snapshot" ] && [ ! -L "$before_snapshot" ] || return 1
    [ -f "$enriched_path" ] && [ ! -L "$enriched_path" ] || return 1
    migration_jsonl_matches_snapshot "$export_path" "$before_snapshot" || return 1
    v057_export_matches_snapshot "$export_path" "$before_snapshot" "$version" || return 1

    show_path=$(mktemp "$ws/.beads/.issues.jsonl.show.tmp.XXXXXX") || return 1
    ids=$(jq -ce '.[] | .id' "$before_snapshot" 2>/dev/null) || extraction_ok=false

    if $extraction_ok; then
        while IFS= read -r encoded_id; do
            id=$(jq -er 'if type == "string" and length > 0 then . else error("invalid id") end' \
                <<< "$encoded_id" 2>/dev/null) || {
                extraction_ok=false
                break
            }
            if ! show_json=$(bd_in "$ws" "$old_bin" show --id="$id" --json 2>/dev/null); then
                extraction_ok=false
                break
            fi
            show_record=$(jq -ce --arg id "$id" '
                if type == "array" and length == 1 and
                    (.[0] | type) == "object" and
                    ((.[0].id? | type) == "string") and
                    .[0].id == $id and
                    ((.[0].comments? // []) | type) == "array"
                then .[0]
                else error("invalid one-item show result")
                end
            ' <<< "$show_json" 2>/dev/null) || {
                extraction_ok=false
                break
            }
            if ! printf '%s\n' "$show_record" >> "$show_path"; then
                extraction_ok=false
                break
            fi
        done <<< "$ids"
    fi

    if $extraction_ok && \
        migration_jsonl_matches_snapshot "$show_path" "$before_snapshot" && \
        v057_export_and_show_comments_agree \
            "$export_path" "$show_path" "$before_snapshot" "$version"; then
        if ! jq -cn \
            --slurpfile exports "$export_path" \
            --slurpfile shows "$show_path" '
            def by_id: map({key: .id, value: .}) | from_entries;
            ($shows | by_id) as $show |
            $exports[] |
            ($show[.id].comments // []) as $comments |
            if ($comments | length) > 0
            then .comments = $comments
            else del(.comments)
            end
        ' > "$enriched_path"; then
            extraction_ok=false
        fi
    else
        extraction_ok=false
    fi

    if $extraction_ok && \
        ! migration_jsonl_matches_snapshot "$enriched_path" "$before_snapshot"; then
        extraction_ok=false
    fi
    if ! remove_file_and_verify_absent "$show_path"; then
        extraction_ok=false
    fi
    if ! $extraction_ok; then
        remove_file_and_verify_absent "$enriched_path" >/dev/null 2>&1 || true
        return 1
    fi
}

preserve_legacy_dolt_source() {
    local ws="$1"
    local expected_manifest="$2"
    local beads_dir="$ws/.beads"
    local backup_dir="$beads_dir/legacy-dolt.pre-migration"
    local temp_dir="$beads_dir/.legacy-dolt.pre-migration.tmp.$$"
    local actual_manifest relative

    if [ -e "$backup_dir" ] || [ -L "$backup_dir" ]; then
        if [ ! -d "$backup_dir" ] || [ -L "$backup_dir" ]; then
            echo "  FAILED: legacy Dolt rollback destination is not a regular directory"
            return 1
        fi
        if ! verify_legacy_dolt_rollback_root "$backup_dir" "$expected_manifest"; then
            echo "  FAILED: legacy Dolt rollback destination contains different source data"
            return 1
        fi
        return 0
    fi

    if [ -e "$temp_dir" ] || [ -L "$temp_dir" ]; then
        echo "  FAILED: temporary legacy Dolt rollback destination already exists"
        return 1
    fi

    actual_manifest=$(legacy_dolt_artifact_manifest "$beads_dir") || return 1
    if [ "$actual_manifest" != "$expected_manifest" ]; then
        echo "  FAILED: active legacy Dolt source changed before backup"
        return 1
    fi

    mkdir "$temp_dir" || return 1
    if ! cp -a -- "$beads_dir/dolt" "$temp_dir/dolt"; then
        rm -rf "$temp_dir"
        echo "  FAILED: could not copy legacy Dolt rollback data"
        return 1
    fi
    for relative in "${LEGACY_DOLT_ROLLBACK_FILES[@]}"; do
        if [ -f "$beads_dir/$relative" ]; then
            if ! cp -p -- "$beads_dir/$relative" "$temp_dir/$relative"; then
                rm -rf "$temp_dir"
                echo "  FAILED: could not copy legacy Dolt rollback metadata"
                return 1
            fi
        fi
    done

    actual_manifest=$(legacy_dolt_artifact_manifest "$temp_dir") || {
        rm -rf "$temp_dir"
        return 1
    }
    if [ "$actual_manifest" != "$expected_manifest" ] || \
        ! verify_legacy_dolt_rollback_root "$temp_dir" "$expected_manifest"; then
        rm -rf "$temp_dir"
        echo "  FAILED: copied legacy Dolt rollback data failed verification"
        return 1
    fi

    if ! publish_legacy_dolt_rollback "$temp_dir" "$backup_dir"; then
        rm -rf "$temp_dir"
        echo "  FAILED: could not publish legacy Dolt rollback data"
        return 1
    fi
    if [ -e "$temp_dir" ] || [ -L "$temp_dir" ] || \
        ! verify_legacy_dolt_rollback_root "$backup_dir" "$expected_manifest"; then
        echo "  FAILED: published legacy Dolt rollback data failed verification"
        return 1
    fi
}

recipe_server_to_embedded() {
    local ws="$1"
    local old_bin="$2"
    local cand_bin="$3"
    local version="$4"
    local before_snapshot="${5:-}"
    local strategy
    local export_path="$ws/.beads/issues.jsonl"
    local existing_export_state="absent"
    local existing_export_checksum=""

    if [ "$version" = "v0.62.0" ]; then
        echo "  FAILED: v0.62.0 must use the public migration bridge"
        return 1
    fi

    echo "  Trying server→embedded recipe..."
    strategy=$(server_bridge_strategy "$version") || {
        echo "  FAILED: no lossless server→embedded recipe is qualified for $version"
        return 1
    }
    case "$strategy" in
        native_export|native_export_show_comments) ;;
        *)
            echo "  FAILED: incomplete server→embedded inputs for $version"
            return 1
            ;;
    esac
    if [ ! -f "$before_snapshot" ] || [ -L "$before_snapshot" ]; then
        echo "  FAILED: incomplete server→embedded inputs for $version"
        return 1
    fi
    if [ -e "$export_path" ] || [ -L "$export_path" ]; then
        if [ -L "$export_path" ] || [ ! -f "$export_path" ] || \
            ! migration_jsonl_is_snapshot_subset "$export_path" "$before_snapshot"; then
            echo "  FAILED: existing historical JSONL is unsafe to replace"
            return 1
        fi
        existing_export_checksum=$(sha256_file "$export_path") || return 1
        existing_export_state="present"
    fi

    # Step 1: Stop any running server (we'll restart via old binary as needed)
    if ! stop_dolt_server "$ws"; then
        echo "  FAILED: could not prove the historical server stopped before rollback capture"
        return 1
    fi

    # Preserve the stopped source before an old export command or candidate
    # probe can update its Dolt working set or metadata.
    local rollback_manifest
    rollback_manifest=$(legacy_dolt_artifact_manifest "$ws/.beads") || {
        echo "  FAILED: could not inventory legacy Dolt rollback source"
        return 1
    }
    preserve_legacy_dolt_source "$ws" "$rollback_manifest" || return 1

    # v0.62 cannot reliably auto-start its historical server on a loaded host.
    # Its workspace marker keeps auto-start disabled, so restart the qualified,
    # harness-owned server against the still-active source before extraction.
    local bootstrap_strategy=""
    bootstrap_strategy=$(server_bootstrap_strategy "$version" 2>/dev/null) || true
    case "$bootstrap_strategy" in
        "") ;;
        prestarted_server)
            if ! start_owned_migration_dolt_server "$ws"; then
                echo "  FAILED: could not restart the qualified historical Dolt server"
                return 1
            fi
            ;;
        *)
            echo "  FAILED: unsupported server bootstrap strategy for $version"
            return 1
            ;;
    esac

    # Step 2: Export data via old binary BEFORE clearing metadata.
    # The old binary needs metadata.json to know it's in server mode and
    # to auto-start its Dolt server. Removing metadata first (as was done
    # previously) makes the old binary unable to find its data. (GH#3071)
    echo "  exporting data via old binary..."
    local export_ok=false
    local historical_export_ok=false
    local export_tmp enriched_tmp="" export_publish_source
    export_tmp=$(mktemp "$ws/.beads/.issues.jsonl.migration.tmp.XXXXXX") || {
        echo "  FAILED: could not create a safe historical export destination"
        return 1
    }
    export_publish_source="$export_tmp"
    case "$strategy" in
        native_export)
            if bd_in "$ws" "$old_bin" export --format jsonl \
                -o "$export_tmp" >/dev/null 2>&1; then
                historical_export_ok=true
            fi
            ;;
        native_export_show_comments)
            if bd_in "$ws" "$old_bin" export -o "$export_tmp" >/dev/null 2>&1; then
                enriched_tmp=$(mktemp "$ws/.beads/.issues.jsonl.enriched.tmp.XXXXXX") || true
                if [ -n "$enriched_tmp" ] && \
                    enrich_v057_export_comments \
                        "$ws" "$old_bin" "$export_tmp" \
                        "$before_snapshot" "$enriched_tmp" "$version"; then
                    export_publish_source="$enriched_tmp"
                    historical_export_ok=true
                fi
            fi
            ;;
    esac

    if $historical_export_ok; then
        local export_destination_unchanged=false
        if [ "$existing_export_state" = "present" ]; then
            if [ -f "$export_path" ] && [ ! -L "$export_path" ] && \
                [ "$(sha256_file "$export_path")" = "$existing_export_checksum" ]; then
                export_destination_unchanged=true
            fi
        elif [ ! -e "$export_path" ] && [ ! -L "$export_path" ]; then
            export_destination_unchanged=true
        fi
        if $export_destination_unchanged && \
            migration_jsonl_matches_snapshot "$export_publish_source" "$before_snapshot" && \
            mv --no-target-directory --force -- "$export_publish_source" "$export_path" && \
            migration_jsonl_matches_snapshot "$export_path" "$before_snapshot"; then
            local export_count
            export_count=$(jq -s 'length' "$export_path" 2>/dev/null) || export_count=0
            echo "  exported $export_count items to JSONL"
            export_ok=true
        fi
    fi
    local staging_cleanup_ok=true
    if ! remove_file_and_verify_absent "$export_tmp"; then
        echo "  FAILED: could not remove the historical export staging file"
        staging_cleanup_ok=false
    fi
    if [ -n "$enriched_tmp" ] && \
        ! remove_file_and_verify_absent "$enriched_tmp"; then
        echo "  FAILED: could not remove the enriched export staging file"
        staging_cleanup_ok=false
    fi
    if ! stop_dolt_server "$ws"; then
        echo "  FAILED: could not prove the historical server stopped after export"
        return 1
    fi
    $staging_cleanup_ok || return 1
    if ! $export_ok; then
        echo "  FAILED: historical export did not produce a nonempty JSONL file"
        return 1
    fi
    if ! verify_legacy_dolt_rollback_root \
        "$ws/.beads/legacy-dolt.pre-migration" "$rollback_manifest"; then
        echo "  FAILED: retained rollback source changed during historical export"
        return 1
    fi

    # Step 3: Clear stale server metadata that causes TCP connect attempts,
    # then try candidate init.
    if ! remove_file_and_verify_absent "$ws/.beads/dolt-server.pid" || \
        ! remove_file_and_verify_absent "$ws/.beads/dolt-server.lock" || \
        ! remove_file_and_verify_absent "$ws/.beads/metadata.json"; then
        echo "  FAILED: could not clear legacy server metadata"
        return 1
    fi

    if bd_in "$ws" "$cand_bin" init --quiet --non-interactive </dev/null >/dev/null 2>&1; then
        # Verify candidate actually has data — init may succeed but create
        # an empty database if it didn't detect the old dolt/ data. (GH#3071)
        if candidate_list_has_nonempty_issue_ids "$ws" "$cand_bin"; then
            echo "  candidate init succeeded with data intact"
            return 0
        fi
        echo "  candidate init returned 0 but database is empty"
    fi

    # Step 4: Candidate init produced an empty DB (or failed).
    # Remove active storage only after the verified rollback copy and JSONL
    # export exist. The old dolt/ is legacy data; embeddeddolt/ (if any) was
    # just created empty by step 3.
    if ! stop_dolt_server "$ws"; then
        echo "  FAILED: could not prove all workspace servers stopped before active-source removal"
        return 1
    fi
    if ! verify_legacy_dolt_rollback_root \
        "$ws/.beads/legacy-dolt.pre-migration" "$rollback_manifest"; then
        echo "  FAILED: retained rollback source changed before active-source removal"
        return 1
    fi
    if ! remove_file_and_verify_absent "$ws/.beads/metadata.json" || \
        ! remove_file_and_verify_absent "$ws/.beads/config.json" || \
        ! remove_file_and_verify_absent "$ws/.beads/config.yaml" || \
        ! remove_tree_and_verify_absent "$ws/.beads/dolt" || \
        ! remove_tree_and_verify_absent "$ws/.beads/embeddeddolt"; then
        echo "  FAILED: could not remove active legacy storage artifacts"
        return 1
    fi

    # Reimport from the JSONL export captured in step 2.
    if $export_ok && [ -s "$ws/.beads/issues.jsonl" ]; then
        echo "  reimporting from JSONL export..."
        if bd_in "$ws" "$cand_bin" init --from-jsonl --quiet --non-interactive </dev/null >/dev/null 2>&1; then
            echo "  candidate init --from-jsonl succeeded"
            return 0
        fi
        echo "  init --from-jsonl failed"
    else
        echo "  no JSONL export available for reimport"
    fi

    echo "  FAILED: could not migrate from server mode"
    return 1
}
