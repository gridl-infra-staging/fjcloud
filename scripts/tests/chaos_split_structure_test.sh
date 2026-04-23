#!/usr/bin/env bash
# Static structural contract for the chaos test split.
#
# This audit is intentionally red until the chaos suite is split into:
# - small wrapper: scripts/tests/chaos_test.sh
# - focused suites: kill-region, restart-region, ha-failover
# - chaos-only helper module in scripts/tests/lib/chaos_test_helpers.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

# Canonical split contract block: one source of truth for paths and caps.
readonly CHAOS_WRAPPER_PATH="scripts/tests/chaos_test.sh"
readonly CHAOS_KILL_REGION_SUITE_PATH="scripts/tests/chaos_kill_region_test.sh"
readonly CHAOS_RESTART_REGION_SUITE_PATH="scripts/tests/chaos_restart_region_test.sh"
readonly CHAOS_HA_FAILOVER_SUITE_PATH="scripts/tests/chaos_ha_failover_proof_test.sh"
readonly CHAOS_STRUCTURE_AUDIT_PATH="scripts/tests/chaos_split_structure_test.sh"
readonly CHAOS_TESTS_DIRMAP_PATH="scripts/tests/DIRMAP.md"
readonly CHAOS_HELPERS_PATH="scripts/tests/lib/chaos_test_helpers.sh"
readonly SHARED_TEST_HELPERS_PATH="scripts/tests/lib/test_helpers.sh"
readonly PRIORITIES_PATH="PRIORITIES.md"
readonly ROADMAP_PATH="ROADMAP.md"
readonly IMPLEMENTED_ROADMAP_PATH="roadmap/implemented.md"
readonly PHASE6_RISK_REGISTER_PATH="docs/checklists/apr21_pm_2_post_phase6_gaps_and_risks.md"
readonly WRAPPER_MAX_LINES=120
readonly FOCUSED_SUITE_MAX_LINES=800
readonly HELPER_SHARED_MIN_LINE=6
readonly HELPER_SHARED_MAX_LINE=13
readonly CHAOS_ENTRYPOINT_PATTERN='^[[:space:]]*main[[:space:]]+"[$]@"[[:space:]]*$'

CHAOS_FOCUSED_SUITES=(
    "$CHAOS_KILL_REGION_SUITE_PATH"
    "$CHAOS_RESTART_REGION_SUITE_PATH"
    "$CHAOS_HA_FAILOVER_SUITE_PATH"
)

CHAOS_REFERENCE_AUDIT_ROOTS=(
    "README.md"
    "$PRIORITIES_PATH"
    "$ROADMAP_PATH"
    "docs"
    "scripts"
    "roadmap"
)

CHAOS_FOCUSED_SUITE_REFERENCE_ALLOWLIST=(
    "$CHAOS_WRAPPER_PATH"
    "$CHAOS_STRUCTURE_AUDIT_PATH"
    "$CHAOS_TESTS_DIRMAP_PATH"
)

CHAOS_FOCUSED_SUITE_REFERENCE_ALLOWLIST+=("${CHAOS_FOCUSED_SUITES[@]}")

CHAOS_WRAPPER_ORDERED_CALL_PATTERNS=(
    '^[[:space:]]*(bash[[:space:]]+)?"?[$./{}[:alnum:]_-]*chaos_kill_region_test\.sh"?([[:space:];]|$)'
    '^[[:space:]]*(bash[[:space:]]+)?"?[$./{}[:alnum:]_-]*chaos_restart_region_test\.sh"?([[:space:];]|$)'
    '^[[:space:]]*(bash[[:space:]]+)?"?[$./{}[:alnum:]_-]*chaos_ha_failover_proof_test\.sh"?([[:space:];]|$)'
)

line_count_for_file() {
    local abs_path="$1"
    wc -l < "$abs_path" | tr -d ' '
}

function_body_for_function_definition() {
    local abs_path="$1"
    local function_name="$2"
    awk -v fname="$function_name" '
        BEGIN { in_function=0; depth=0 }
        {
            if (!in_function && $0 ~ "^" fname "\\(\\)[[:space:]]*\\{") {
                in_function=1
                depth=1
                next
            }
            if (!in_function) {
                next
            }

            line=$0
            open_count=gsub(/\{/, "{", line)
            line=$0
            close_count=gsub(/\}/, "}", line)

            if (depth + open_count - close_count <= 0) {
                exit
            }

            print $0
            depth += open_count - close_count
        }
    ' "$abs_path"
}

first_non_comment_line_matching_regex_in_text() {
    local text="$1"
    local regex="$2"
    local line=""
    line="$(awk -v regex="$regex" '
        $0 ~ /^[[:space:]]*#/ { next }
        $0 ~ regex { print NR; exit }
    ' <<< "$text")"
    if [ -z "$line" ]; then
        echo "0"
    else
        echo "$line"
    fi
}

first_line_for_function_definition() {
    local abs_path="$1"
    local function_name="$2"
    local line=""
    line="$(awk -v fname="$function_name" '$0 ~ "^" fname "\\(\\)[[:space:]]*\\{" { print NR; exit }' "$abs_path")"
    if [ -z "$line" ]; then
        echo "0"
    else
        echo "$line"
    fi
}

assert_file_has_non_comment_line_matching_regex() {
    local rel_path="$1"
    local regex="$2"
    local msg="$3"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    local file_text
    local line
    file_text="$(cat "$abs_path")"
    line="$(first_non_comment_line_matching_regex_in_text "$file_text" "$regex")"
    if [ "$line" -eq 0 ]; then
        fail "$msg (no matching non-comment line in '$rel_path')"
    else
        pass "$msg"
    fi
}

assert_file_exists() {
    local rel_path="$1"
    local msg="$2"
    if [ -f "$REPO_ROOT/$rel_path" ]; then
        pass "$msg"
    else
        fail "$msg (missing '$rel_path')"
    fi
}

assert_file_at_or_under_line_cap() {
    local rel_path="$1"
    local max_lines="$2"
    local msg="$3"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    local actual_lines
    actual_lines="$(line_count_for_file "$abs_path")"
    if [ "$actual_lines" -le "$max_lines" ]; then
        pass "$msg"
    else
        fail "$msg ('$rel_path' is $actual_lines lines; cap is $max_lines)"
    fi
}

assert_function_in_line_window() {
    local rel_path="$1"
    local function_name="$2"
    local min_line="$3"
    local max_line="$4"
    local msg="$5"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    local line
    line="$(first_line_for_function_definition "$abs_path" "$function_name")"
    if [ "$line" -eq 0 ]; then
        fail "$msg (function '$function_name' missing from '$rel_path')"
    elif [ "$line" -lt "$min_line" ] || [ "$line" -gt "$max_line" ]; then
        fail "$msg (line $line is outside $min_line-$max_line)"
    else
        pass "$msg"
    fi
}

assert_function_absent_from_file() {
    local rel_path="$1"
    local function_name="$2"
    local msg="$3"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    local line
    line="$(first_line_for_function_definition "$abs_path" "$function_name")"
    if [ "$line" -eq 0 ]; then
        pass "$msg"
    else
        fail "$msg (function '$function_name' still defined in '$rel_path' at line $line)"
    fi
}

assert_wrapper_calls_focused_suites_in_order() {
    local rel_path="$1"
    local msg="$2"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    local main_body
    main_body="$(function_body_for_function_definition "$abs_path" "main")"
    if [ -z "$main_body" ]; then
        fail "$msg (main() function body not found in '$rel_path')"
        return
    fi

    local previous_line=0
    local pattern
    for pattern in "${CHAOS_WRAPPER_ORDERED_CALL_PATTERNS[@]}"; do
        local line
        local suite_label="${pattern##*chaos_}"
        suite_label="chaos_${suite_label%%\\.*}.sh"
        line="$(first_non_comment_line_matching_regex_in_text "$main_body" "$pattern")"
        if [ "$line" -eq 0 ]; then
            fail "$msg (main() missing invocation for '$suite_label')"
            return
        fi
        if [ "$line" -le "$previous_line" ]; then
            fail "$msg (main() invocation for '$suite_label' appears out of order)"
            return
        fi
        previous_line="$line"
    done

    pass "$msg"
}

assert_file_does_not_contain_literal() {
    local rel_path="$1"
    local forbidden_literal="$2"
    local msg="$3"
    local abs_path="$REPO_ROOT/$rel_path"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$rel_path')"
        return
    fi

    if rg -F -q -- "$forbidden_literal" "$abs_path"; then
        fail "$msg (found forbidden text in '$rel_path')"
    else
        pass "$msg"
    fi
}

is_path_allowed_for_focused_suite_reference() {
    local rel_path="$1"
    local allowed_path
    for allowed_path in "${CHAOS_FOCUSED_SUITE_REFERENCE_ALLOWLIST[@]}"; do
        if [ "$allowed_path" = "$rel_path" ]; then
            return 0
        fi
    done
    return 1
}

assert_focused_suite_references_scoped_to_allowlist() {
    local suite_path
    for suite_path in "${CHAOS_FOCUSED_SUITES[@]}"; do
        local suite_filename
        suite_filename="$(basename "$suite_path")"

        local search_targets=()
        local search_root
        for search_root in "${CHAOS_REFERENCE_AUDIT_ROOTS[@]}"; do
            search_targets+=("$REPO_ROOT/$search_root")
        done

        local matches
        matches="$(rg -l -F -- "$suite_filename" "${search_targets[@]}" --glob '!*.json' 2>/dev/null || true)"
        if [ -z "$matches" ]; then
            fail "focused suite references for '$suite_filename' should exist in canonical split files"
            return
        fi

        local abs_match_path
        while IFS= read -r abs_match_path; do
            [ -z "$abs_match_path" ] && continue
            local rel_match_path="${abs_match_path#$REPO_ROOT/}"
            if ! is_path_allowed_for_focused_suite_reference "$rel_match_path"; then
                fail "focused suite '$suite_filename' is referenced outside the canonical allowlist (found in '$rel_match_path')"
                return
            fi
        done <<< "$matches"
    done

    pass "focused suite filename references stay scoped to wrapper, structure audit, focused suites, and scripts/tests/DIRMAP.md"
}

test_split_structure_paths_and_sizes() {
    assert_file_at_or_under_line_cap \
        "$CHAOS_WRAPPER_PATH" "$WRAPPER_MAX_LINES" \
        "chaos wrapper stays at or under the small-wrapper cap"

    local suite_path
    for suite_path in "${CHAOS_FOCUSED_SUITES[@]}"; do
        assert_file_at_or_under_line_cap \
            "$suite_path" "$FOCUSED_SUITE_MAX_LINES" \
            "focused chaos suite exists and stays at or under 800 lines: $suite_path"
    done

    assert_file_exists \
        "$CHAOS_HELPERS_PATH" \
        "chaos-only helper module exists at scripts/tests/lib/chaos_test_helpers.sh"
}

test_helper_location_contract() {
    assert_function_in_line_window \
        "$SHARED_TEST_HELPERS_PATH" "write_mock_script" \
        "$HELPER_SHARED_MIN_LINE" "$HELPER_SHARED_MAX_LINE" \
        "write_mock_script remains anchored in scripts/tests/lib/test_helpers.sh lines 6-13"

    assert_function_absent_from_file \
        "$CHAOS_WRAPPER_PATH" "write_mock_script" \
        "chaos wrapper no longer owns write_mock_script"

    assert_function_absent_from_file \
        "$CHAOS_WRAPPER_PATH" "write_mock_lsof_for_pid_file" \
        "chaos wrapper no longer owns write_mock_lsof_for_pid_file"

    assert_function_absent_from_file \
        "$CHAOS_WRAPPER_PATH" "write_mock_lsof_static_pid" \
        "chaos wrapper no longer owns write_mock_lsof_static_pid"

    assert_function_absent_from_file \
        "$CHAOS_WRAPPER_PATH" "write_minimal_ha_failover_curl_mock" \
        "chaos wrapper no longer owns write_minimal_ha_failover_curl_mock"

    assert_function_in_line_window \
        "$CHAOS_HELPERS_PATH" "write_mock_lsof_for_pid_file" \
        "1" "800" \
        "chaos helper module owns write_mock_lsof_for_pid_file"

    assert_function_in_line_window \
        "$CHAOS_HELPERS_PATH" "write_mock_lsof_static_pid" \
        "1" "800" \
        "chaos helper module owns write_mock_lsof_static_pid"

    assert_function_in_line_window \
        "$CHAOS_HELPERS_PATH" "write_minimal_ha_failover_curl_mock" \
        "1" "800" \
        "chaos helper module owns write_minimal_ha_failover_curl_mock"
}

test_aggregate_entrypoint_contract() {
    assert_file_has_non_comment_line_matching_regex \
        "$CHAOS_WRAPPER_PATH" "$CHAOS_ENTRYPOINT_PATTERN" \
        "chaos wrapper keeps main \"\$@\" as the public aggregate entrypoint"

    assert_wrapper_calls_focused_suites_in_order \
        "$CHAOS_WRAPPER_PATH" \
        "chaos wrapper calls kill-region, restart-region, and HA suites in deterministic order"
}

test_reference_and_status_contract() {
    assert_focused_suite_references_scoped_to_allowlist

    assert_file_does_not_contain_literal \
        "$PRIORITIES_PATH" \
        'test-file size cleanup in `scripts/tests/chaos_test.sh`' \
        "priorities no longer describe chaos split as remaining local-stack debt"

    assert_file_does_not_contain_literal \
        "$ROADMAP_PATH" \
        "Split oversized chaos/local evidence tests" \
        "roadmap planned work no longer tracks chaos split as open P3 work"

    assert_file_does_not_contain_literal \
        "$ROADMAP_PATH" \
        'Local evidence test maintenance is still needed: `scripts/tests/chaos_test.sh` is oversized and should be split before additional local-stack assertions are added.' \
        "roadmap open-work section no longer claims chaos_test.sh is oversized debt"

    assert_file_does_not_contain_literal \
        "$IMPLEMENTED_ROADMAP_PATH" \
        'Oversized `chaos_test.sh` split remains deferred.' \
        "implemented roadmap lane no longer says chaos split is deferred"

    assert_file_does_not_contain_literal \
        "$PHASE6_RISK_REGISTER_PATH" \
        'Residual debt: `scripts/tests/chaos_test.sh` is oversized and should be split before more assertions accumulate there.' \
        "phase 6 risk register no longer flags chaos split as residual oversized debt"

    assert_file_does_not_contain_literal \
        "$PHASE6_RISK_REGISTER_PATH" \
        "Split oversized chaos/local evidence test files." \
        "phase 6 suggested promotion order no longer lists chaos split as pending work"
}

main() {
    echo "=== chaos split structure contract tests ==="
    echo ""

    test_split_structure_paths_and_sizes
    test_helper_location_contract
    test_aggregate_entrypoint_contract
    test_reference_and_status_contract

    run_test_summary
}

main "$@"
