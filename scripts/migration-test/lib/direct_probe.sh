#!/bin/bash
# Candidate direct-upgrade probe helpers.

candidate_list_has_nonempty_issue_ids() {
    local ws="$1"
    local bin="$2"
    local output

    if ! output=$(bd_in "$ws" "$bin" list --json -n 0 --all 2>/dev/null); then
        return 1
    fi

    jq -e -s '
        length == 1 and
        (.[0] |
            type == "array" and
            length > 0 and
            all(.[];
                type == "object" and
                ((.id? | type) == "string") and
                ((.id? | length) > 0)))
    ' >/dev/null 2>&1 <<< "$output"
}

DIRECT_PROBE_FAILURE_DETAIL=""

candidate_probe_source_is_unchanged() {
    local ws="$1"
    local expected_fingerprint="$2"
    local stage="$3"
    local actual_fingerprint

    if ! stop_dolt_server "$ws"; then
        DIRECT_PROBE_FAILURE_DETAIL="could not prove the historical server stopped after candidate $stage"
        return 1
    fi
    if ! actual_fingerprint=$(source_artifact_fingerprint "$ws/.beads"); then
        DIRECT_PROBE_FAILURE_DETAIL="could not fingerprint historical source tree after candidate $stage"
        return 1
    fi
    if [ "$actual_fingerprint" != "$expected_fingerprint" ]; then
        DIRECT_PROBE_FAILURE_DETAIL="candidate $stage mutated the historical source tree"
        return 1
    fi
}

probe_candidate_direct_upgrade() {
    local ws="$1"
    local bin="$2"
    local expected_fingerprint="${3:-}"
    local strict="${4:-false}"

    DIRECT_PROBE_FAILURE_DETAIL=""
    if $strict && [ -z "$expected_fingerprint" ]; then
        DIRECT_PROBE_FAILURE_DETAIL="strict candidate probe has no historical source fingerprint"
        return 2
    fi

    if candidate_list_has_nonempty_issue_ids "$ws" "$bin"; then
        return 0
    fi
    if $strict && ! candidate_probe_source_is_unchanged \
        "$ws" "$expected_fingerprint" "list probe"; then
        return 2
    fi

    if ! bd_in "$ws" "$bin" init --quiet --non-interactive --prefix smoke \
        </dev/null >/dev/null 2>&1; then
        if $strict && ! candidate_probe_source_is_unchanged \
            "$ws" "$expected_fingerprint" "init probe"; then
            return 2
        fi
        return 1
    fi

    if candidate_list_has_nonempty_issue_ids "$ws" "$bin"; then
        return 0
    fi
    if $strict && ! candidate_probe_source_is_unchanged \
        "$ws" "$expected_fingerprint" "post-init list probe"; then
        return 2
    fi
    return 1
}
