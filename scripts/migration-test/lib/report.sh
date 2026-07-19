#!/bin/bash
# Results tracking and report generation.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

# Parallel arrays for tracking results
declare -a RESULT_PATHS=()
declare -a RESULT_STATUSES=()     # AUTO, MANUAL, BLOCKED, SKIP
declare -a RESULT_DETAILS=()
declare -a RESULT_RECIPES=()      # recipe name if MANUAL
declare -a RESULT_VIOLATIONS=()   # fidelity violation count

record_result() {
    local path="$1"       # e.g. "v0.49.6 → candidate" or "v0.49.6 → v0.57.0 → candidate"
    local status="$2"     # AUTO, MANUAL, BLOCKED, SKIP
    local detail="$3"     # human-readable detail
    local recipe="${4:-}"
    local violations="${5:-0}"

    RESULT_PATHS+=("$path")
    RESULT_STATUSES+=("$status")
    RESULT_DETAILS+=("$detail")
    RESULT_RECIPES+=("$recipe")
    RESULT_VIOLATIONS+=("$violations")
}

record_result_after_workspace_cleanup() {
    local ws="$1"
    local path="$2"
    local status="$3"
    local detail="$4"
    local recipe="${5:-}"
    local violations="${6:-0}"

    if ! cleanup_workspace "$ws"; then
        record_result "$path" "BLOCKED" \
            "could not prove isolated workspace cleanup; preserved at $ws" "" "$violations"
        return 1
    fi
    record_result "$path" "$status" "$detail" "$recipe" "$violations"
}

print_results_table() {
    echo ""
    echo -e "${BOLD}Migration Test Results${NC}"
    echo ""
    printf "%-40s %-8s %-4s %s\n" "Upgrade Path" "Status" "Viol" "Detail"
    printf "%-40s %-8s %-4s %s\n" "------------" "------" "----" "------"

    for i in "${!RESULT_PATHS[@]}"; do
        local path="${RESULT_PATHS[$i]}"
        local status="${RESULT_STATUSES[$i]}"
        local detail="${RESULT_DETAILS[$i]}"
        local violations="${RESULT_VIOLATIONS[$i]}"

        case "$status" in
            AUTO)    printf "%-40s ${GREEN}%-8s${NC} %-4s %s\n" "$path" "$status" "$violations" "$detail" ;;
            MANUAL)  printf "%-40s ${YELLOW}%-8s${NC} %-4s %s\n" "$path" "$status" "$violations" "$detail" ;;
            BLOCKED) printf "%-40s ${RED}%-8s${NC} %-4s %s\n" "$path" "$status" "$violations" "$detail" ;;
            SKIP)    printf "%-40s ${YELLOW}%-8s${NC} %-4s %s\n" "$path" "$status" "$violations" "$detail" ;;
        esac
    done
}

# Print stepping-stone instructions for paths that need manual steps.
print_upgrade_instructions() {
    local has_manual=false
    for i in "${!RESULT_STATUSES[@]}"; do
        if [ "${RESULT_STATUSES[$i]}" = "MANUAL" ]; then
            has_manual=true
            break
        fi
    done

    if ! $has_manual; then return; fi

    echo ""
    echo -e "${BOLD}Upgrade Instructions${NC}"
    echo ""

    for i in "${!RESULT_PATHS[@]}"; do
        local status="${RESULT_STATUSES[$i]}"
        [ "$status" != "MANUAL" ] && continue

        local path="${RESULT_PATHS[$i]}"
        local recipe="${RESULT_RECIPES[$i]}"
        local detail="${RESULT_DETAILS[$i]}"

        echo -e "  ${YELLOW}${path}${NC}"
        echo "    Recipe: $recipe"
        echo "    Detail: $detail"
        echo ""
    done
}

# GitHub Actions markdown summary
print_ci_summary() {
    if [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
        return
    fi

    local auto=0 manual=0 blocked=0 skip=0
    for status in "${RESULT_STATUSES[@]}"; do
        case "$status" in
            AUTO) auto=$((auto + 1)) ;;
            MANUAL) manual=$((manual + 1)) ;;
            BLOCKED) blocked=$((blocked + 1)) ;;
            SKIP) skip=$((skip + 1)) ;;
        esac
    done

    {
        echo "## Migration Test Results"
        echo ""
        echo "| Upgrade Path | Status | Violations | Detail |"
        echo "|---|---|---|---|"
        for i in "${!RESULT_PATHS[@]}"; do
            local path="${RESULT_PATHS[$i]}"
            local status="${RESULT_STATUSES[$i]}"
            local detail="${RESULT_DETAILS[$i]}"
            local violations="${RESULT_VIOLATIONS[$i]}"
            local icon=""
            case "$status" in
                AUTO) icon="✅" ;;
                MANUAL) icon="🔧" ;;
                BLOCKED) icon="❌" ;;
                SKIP) icon="⏭️" ;;
            esac
            echo "| ${path} | ${icon} ${status} | ${violations} | ${detail} |"
        done
        echo ""
        echo "**${auto} auto, ${manual} manual, ${blocked} blocked, ${skip} skipped**"
    } >> "$GITHUB_STEP_SUMMARY"
}

print_summary_line() {
    local auto=0 manual=0 blocked=0 skip=0
    for status in "${RESULT_STATUSES[@]}"; do
        case "$status" in
            AUTO) auto=$((auto + 1)) ;;
            MANUAL) manual=$((manual + 1)) ;;
            BLOCKED) blocked=$((blocked + 1)) ;;
            SKIP) skip=$((skip + 1)) ;;
        esac
    done

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    local total=$((auto + manual + blocked + skip))
    if [ "$blocked" -eq 0 ]; then
        echo -e "  ${GREEN}${auto} auto${NC}, ${YELLOW}${manual} manual${NC}, ${blocked} blocked, ${skip} skipped (of ${total})"
    else
        echo -e "  ${auto} auto, ${manual} manual, ${RED}${blocked} BLOCKED${NC}, ${skip} skipped (of ${total})"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# strict_results_match enforces the single-path release-gate contract after a
# run has populated the result arrays. Human output remains unchanged; strict
# callers get a nonzero exit for every unqualified outcome.
strict_results_match() {
    local expected_status="$1"
    local expected_recipe="$2"

    if [ "${#RESULT_STATUSES[@]}" -ne 1 ]; then
        echo "STRICT: expected exactly one result, got ${#RESULT_STATUSES[@]}" >&2
        return 1
    fi

    local status="${RESULT_STATUSES[0]}"
    local recipe="${RESULT_RECIPES[0]}"
    local violations="${RESULT_VIOLATIONS[0]}"
    if [ "$status" = "SKIP" ] || [ "$status" = "BLOCKED" ]; then
        echo "STRICT: unqualified result status $status" >&2
        return 1
    fi
    if ! [[ "$violations" =~ ^[0-9]+$ ]] || [ "$violations" -ne 0 ]; then
        echo "STRICT: fidelity/blocker violations=$violations" >&2
        return 1
    fi
    if [ "$status" != "$expected_status" ]; then
        echo "STRICT: outcome drifted from $expected_status to $status" >&2
        return 1
    fi
    if [ "$recipe" != "$expected_recipe" ]; then
        echo "STRICT: recipe drifted from $expected_recipe to ${recipe:-none}" >&2
        return 1
    fi
}
