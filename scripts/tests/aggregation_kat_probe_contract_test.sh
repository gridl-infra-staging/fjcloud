#!/usr/bin/env bash
# Hermetic contract-marker tests for W2's local real-pipeline probe bundle.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

FIXTURE_DIR="$SCRIPT_DIR/fixtures/aggregation_kat_probe_contract"
SCRIPT_UNDER_TEST="$SCRIPT_DIR/aggregation_kat_probe_contract_test.sh"
TMP_PATHS=()

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

check_probe_contract_text() {
    local source_bundle_path="$1" bundle_path marker_id
    bundle_path="$(mktemp)"
    register_tmp_path "$bundle_path"
    write_active_contract_text "$source_bundle_path" >"$bundle_path"

    for marker_id in "${MARKER_IDS[@]}"; do
        if ! probe_contract_marker_present "$bundle_path" "$marker_id"; then
            printf '%s\n' "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:$marker_id"
            return 1
        fi
    done
    printf '%s\n' "AGGREGATION_KAT_PROBE_CONTRACT: PASS found=$(joined_marker_ids)"
    return 0
}

write_active_contract_text() {
    local bundle_path="$1"
    awk '
        function double_quote_is_escaped(line, quote_pos, backslash_count, idx) {
            backslash_count = 0
            for (idx = quote_pos - 1; idx >= 1; idx--) {
                if (substr(line, idx, 1) != "\\") {
                    break
                }
                backslash_count++
            }
            return backslash_count % 2 == 1
        }
        function shell_comment_start(line, pos, char, prev) {
            for (pos = 1; pos <= length(line); pos++) {
                char = substr(line, pos, 1)
                prev = pos == 1 ? "" : substr(line, pos - 1, 1)
                if (char == "'"'"'" && !in_double) {
                    in_single = !in_single
                } else if (char == "\"" && !in_single &&
                        !double_quote_is_escaped(line, pos)) {
                    in_double = !in_double
                } else if (char == "#" && !in_single && !in_double &&
                        (pos == 1 || prev ~ /[[:space:];&|()]/)) {
                    return pos
                }
            }
            return 0
        }
        {
            comment_pos = shell_comment_start($0)
            if (comment_pos > 0) {
                print substr($0, 1, comment_pos - 1)
            } else {
                print
            }
        }
    ' "$bundle_path"
}

joined_marker_ids() {
    local IFS=,
    printf '%s' "${MARKER_IDS[*]}"
}

has_text() {
    local bundle_path="$1" needle="$2"
    grep -Fq -- "$needle" "$bundle_path"
}

has_all_text() {
    local bundle_path="$1" needle
    shift
    for needle in "$@"; do
        has_text "$bundle_path" "$needle" || return 1
    done
}

line_starts_with_call() {
    local expected_call="$1"
    awk -v expected_call="$expected_call" '
        {
            trimmed = $0
            sub(/^[[:space:]]+/, "", trimmed)
            if (index(trimmed, expected_call) != 1) {
                exit 1
            }
            next_char = substr(trimmed, length(expected_call) + 1, 1)
            if (next_char == "" || next_char ~ /[[:space:];&|)]/) {
                exit 0
            }
            exit 1
        }
    '
}

function_body_has_all_text() {
    local bundle_path="$1" function_name="$2" function_body needle
    shift 2
    function_body="$(
        awk -v declaration="${function_name}() {" '
            index($0, declaration) == 1 { in_function = 1 }
            in_function {
                print
                if ($0 ~ /^}[[:space:]]*$/) {
                    exit
                }
            }
        ' "$bundle_path"
    )"
    [ -n "$function_body" ] || return 1
    for needle in "$@"; do
        grep -Fq -- "$needle" <<<"$function_body" || return 1
    done
}

function_body_has_call() {
    local bundle_path="$1" function_name="$2" expected_call="$3" function_body
    function_body="$(
        awk -v declaration="${function_name}() {" '
            index($0, declaration) == 1 { in_function = 1 }
            in_function {
                print
                if ($0 ~ /^}[[:space:]]*$/) {
                    exit
                }
            }
        ' "$bundle_path"
    )"
    [ -n "$function_body" ] || return 1
    while IFS= read -r line; do
        if line_starts_with_call "$expected_call" <<<"$line"; then
            return 0
        fi
    done <<<"$function_body"
    return 1
}

branch_body_has_call() {
    local bundle_path="$1" branch_header="$2" expected_call="$3"
    awk -v branch_header="$branch_header" -v expected_call="$expected_call" '
        function line_starts_with_call(line, trimmed, next_char) {
            trimmed = line
            sub(/^[[:space:]]+/, "", trimmed)
            if (index(trimmed, expected_call) != 1) {
                return 0
            }
            next_char = substr(trimmed, length(expected_call) + 1, 1)
            return next_char == "" || next_char ~ /[[:space:];&|)]/
        }
        index($0, branch_header) {
            match($0, /^[[:space:]]*/)
            branch_indent = substr($0, RSTART, RLENGTH)
            in_branch = 1
            next
        }
        in_branch && substr($0, 1, length(branch_indent)) == branch_indent {
            branch_line = substr($0, length(branch_indent) + 1)
            if (branch_line ~ /^elif[[:space:]]/ ||
                    branch_line == "else" || branch_line ~ /^else[[:space:]]/ ||
                    branch_line == "fi" || branch_line ~ /^fi[[:space:]]/) {
                exit !found_needle
            }
        }
        in_branch && line_starts_with_call($0) { found_needle = 1 }
        END { if (!in_branch || !found_needle) exit 1 }
    ' "$bundle_path"
}

function_body_has_text_in_order() {
    local bundle_path="$1" function_name="$2" earlier_text="$3" later_text="$4"
    awk -v declaration="${function_name}() {" \
        -v earlier_text="$earlier_text" -v later_text="$later_text" '
        index($0, declaration) == 1 { in_function = 1 }
        !in_function { next }
        found_earlier {
            if (index($0, later_text)) {
                found_later = 1
                exit 0
            }
        }
        !found_earlier {
            earlier_pos = index($0, earlier_text)
            if (earlier_pos) {
                found_earlier = 1
                later_tail = substr($0, earlier_pos + length(earlier_text))
                if (index(later_tail, later_text)) {
                    found_later = 1
                    exit 0
                }
            }
        }
        /^}[[:space:]]*$/ { exit 1 }
        END {
            if (!in_function || !found_earlier || !found_later) {
                exit 1
            }
        }
    ' "$bundle_path"
}

function_loop_calls() {
    local bundle_path="$1" function_name="$2" loop_header="$3" call="$4"
    awk -v declaration="${function_name}() {" -v loop_header="$loop_header" -v call="$call" '
        function line_starts_with_call(line, trimmed, next_char) {
            trimmed = line
            sub(/^[[:space:]]+/, "", trimmed)
            if (index(trimmed, call) != 1) {
                return 0
            }
            next_char = substr(trimmed, length(call) + 1, 1)
            return next_char == "" || next_char ~ /[[:space:];&|)]/
        }
        index($0, declaration) == 1 { in_function = 1 }
        !in_function { next }
        index($0, loop_header) {
            in_loop = 1
            if (line_starts_with_call($0)) {
                found_call = 1
            }
            next
        }
        in_loop && line_starts_with_call($0) { found_call = 1 }
        in_loop && /^[[:space:]]*done[[:space:]]*$/ { exit !found_call }
        /^}[[:space:]]*$/ { exit 1 }
        END { if (!in_loop || !found_call) exit 1 }
    ' "$bundle_path"
}

probe_contract_marker_present() {
    local bundle_path="$1" marker_id="$2"
    case "$marker_id" in
        drives_batch_and_query_endpoints)
            function_body_has_all_text "$bundle_path" "lrp_drive_one_write" \
                "curl" \
                '/1/indexes/$LRP_FLAPJACK_UID/batch' \
                &&
            function_body_has_all_text "$bundle_path" "lrp_drive_one_search" \
                "curl" \
                '/1/indexes/$LRP_FLAPJACK_UID/query'
            ;;
        reads_usage_daily_evidence)
            has_all_text "$bundle_path" \
                "lrp_build_evidence()" \
                "SELECT search_requests,write_operations" \
                "FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date" \
                'doc["row_customer_id"]'
            ;;
        clears_usage_daily_before_run)
            function_body_has_all_text "$bundle_path" "lrp_clear_target_scope" \
                "DELETE FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date" \
                "DELETE FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s AND recorded_at < (%s + interval '1 day')" \
                "SELECT (SELECT count(*) FROM usage_daily" \
                "+ (SELECT count(*) FROM usage_records" \
                'total="$(lrp_psql_scalar "$sql")"' \
                '[ "$total" = "0" ]' \
                'LRP_CLEARED_BEFORE="true"' \
                &&
            function_body_has_text_in_order "$bundle_path" "lrp_clear_target_scope" \
                "DELETE FROM usage_daily WHERE customer_id=%s AND region=%s AND date=%s::date" \
                "SELECT (SELECT count(*) FROM usage_daily" \
                &&
            function_body_has_text_in_order "$bundle_path" "lrp_clear_target_scope" \
                "DELETE FROM usage_records WHERE customer_id=%s AND region=%s AND recorded_at >= %s AND recorded_at < (%s + interval '1 day')" \
                "SELECT (SELECT count(*) FROM usage_daily" \
                &&
            function_body_has_text_in_order "$bundle_path" "lrp_clear_target_scope" \
                "SELECT (SELECT count(*) FROM usage_daily" \
                'total="$(lrp_psql_scalar "$sql")"' \
                &&
            function_body_has_text_in_order "$bundle_path" "lrp_clear_target_scope" \
                'total="$(lrp_psql_scalar "$sql")"' \
                '[ "$total" = "0" ]' \
                &&
            function_body_has_text_in_order "$bundle_path" "lrp_clear_target_scope" \
                '[ "$total" = "0" ]' \
                'LRP_CLEARED_BEFORE="true"'
            ;;
        computes_metrics_delta_oracle)
            has_all_text "$bundle_path" \
                "LRP_EXPECTED_SEARCH" \
                "LRP_EXPECTED_WRITE" \
                'LRP_EXPECTED_SEARCH=$((LRP_POST_SEARCH - LRP_PRE_SEARCH))' \
                'LRP_EXPECTED_WRITE=$((LRP_POST_WRITE - LRP_PRE_WRITE))'
            ;;
        dispatches_assert_evidence_mode)
            function_body_has_call "$bundle_path" "run_assert_evidence_mode" \
                'classify_evidence "$evidence_path"' \
                &&
            branch_body_has_call "$bundle_path" \
                'elif [ "${1:-}" = "--assert-evidence" ]; then' \
                'run_assert_evidence_mode "$2"'
            ;;
        owns_driven_counts)
            function_body_has_all_text "$bundle_path" "lrp_drive_traffic" \
                "LRP_DRIVE_WRITES" \
                "LRP_DRIVE_SEARCHES" \
                "for ((i = 1; i <= LRP_DRIVE_WRITES; i++))" \
                "for ((i = 1; i <= LRP_DRIVE_SEARCHES; i++))" \
                &&
            function_body_has_call "$bundle_path" "lrp_drive_traffic" \
                "lrp_drive_one_write 0" \
                &&
            function_loop_calls "$bundle_path" "lrp_drive_traffic" \
                "for ((i = 1; i <= LRP_DRIVE_WRITES; i++)); do" \
                "lrp_drive_one_write" \
                &&
            function_loop_calls "$bundle_path" "lrp_drive_traffic" \
                "for ((i = 1; i <= LRP_DRIVE_SEARCHES; i++)); do" \
                "lrp_drive_one_search"
            ;;
        *)
            return 1
            ;;
    esac
}

MARKER_IDS=(
    drives_batch_and_query_endpoints
    reads_usage_daily_evidence
    clears_usage_daily_before_run
    computes_metrics_delta_oracle
    dispatches_assert_evidence_mode
    owns_driven_counts
)

run_check_file_mode() {
    local bundle_path="$1"
    check_probe_contract_text "$bundle_path"
}

run_check_stdin_mode() {
    local bundle_path
    bundle_path="$(mktemp)"
    register_tmp_path "$bundle_path"
    cat >"$bundle_path"
    check_probe_contract_text "$bundle_path"
}

run_checker_file() {
    local fixture="$1" out_path="$2" err_path="$3" rc_path="$4"
    set +e
    bash "$SCRIPT_UNDER_TEST" --check-file "$fixture" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" >"$rc_path"
    set -e
}

run_checker_stdin() {
    local fixture="$1" out_path="$2" err_path="$3" rc_path="$4"
    set +e
    bash "$SCRIPT_UNDER_TEST" --check-stdin <"$fixture" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" >"$rc_path"
    set -e
}

assert_stdout_exact_line() {
    local out_path="$1" expected_line="$2" msg="$3" expected_path
    expected_path="$(mktemp)"
    register_tmp_path "$expected_path"
    printf '%s\n' "$expected_line" >"$expected_path"
    if cmp -s "$expected_path" "$out_path"; then
        pass "$msg"
    else
        fail "$msg (stdout must be exactly '$expected_line')"
    fi
}

assert_checker_result() {
    local mode="$1" fixture_name="$2" expected_rc="$3" expected_line="$4"
    local tmp fixture out err rc
    fixture="$FIXTURE_DIR/$fixture_name"
    assert_file_exists "$fixture" "fixture $fixture_name exists"
    tmp="$(mktemp -d)"
    register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"

    case "$mode" in
        file) run_checker_file "$fixture" "$out" "$err" "$rc" ;;
        stdin) run_checker_stdin "$fixture" "$out" "$err" "$rc" ;;
        *) fail "unknown checker mode $mode"; return ;;
    esac

    assert_eq "$(cat "$rc")" "$expected_rc" "$fixture_name $mode mode exits with the expected status"
    assert_stdout_exact_line "$out" "$expected_line" \
        "$fixture_name $mode mode emits the exact deterministic verdict"
    assert_file_empty_bytes "$err" "$fixture_name $mode mode emits no stderr"
}

assert_file_empty_bytes() {
    local abs_path="$1" msg="$2" byte_count
    byte_count="$(wc -c <"$abs_path" | tr -d ' ')"
    assert_eq "$byte_count" "0" "$msg"
}

test_fixture_contract_verdicts() {
    local pass_line
    pass_line="AGGREGATION_KAT_PROBE_CONTRACT: PASS found=drives_batch_and_query_endpoints,reads_usage_daily_evidence,clears_usage_daily_before_run,computes_metrics_delta_oracle,dispatches_assert_evidence_mode,owns_driven_counts"

    assert_checker_result file good_probe_bundle 0 "$pass_line"
    assert_checker_result file drifted_inert_endpoint_helpers 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:drives_batch_and_query_endpoints"
    assert_checker_result file drifted_missing_usage_daily_delete 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_missing_usage_records_delete 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_missing_usage_records_zero_count 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_search_loop_missing_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_search_loop_commented_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_search_loop_inline_comment_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_search_loop_multiline_quote_commented_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_search_loop_even_backslashes_commented_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_search_loop_quoted_string_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_seed_write_quoted_string_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_write_loop_missing_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:owns_driven_counts"
    assert_checker_result file drifted_assert_helper_inert 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_dispatch_commented_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_dispatch_inline_comment_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_dispatch_quoted_string_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_dispatch_after_else 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_dispatch_after_fi 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_assert_helper_quoted_string_call 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:dispatches_assert_evidence_mode"
    assert_checker_result file drifted_cleared_before_zero_confirm 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_usage_records_delete_after_confirm 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_usage_records_delete_same_line_after_confirm 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_usage_records_delete_commented 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result file drifted_usage_records_delete_unscoped 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
    assert_checker_result stdin good_probe_bundle 0 "$pass_line"
    assert_checker_result stdin drifted_missing_usage_daily_delete 1 \
        "AGGREGATION_KAT_PROBE_CONTRACT: FAIL reason=missing_marker:clears_usage_daily_before_run"
}

main() {
    case "${1:-}" in
        "")
            test_fixture_contract_verdicts
            run_test_summary
            ;;
        --check-file)
            if [ "$#" -ne 2 ]; then
                echo "usage: aggregation_kat_probe_contract_test.sh --check-file <path>" >&2
                exit 2
            fi
            run_check_file_mode "$2"
            ;;
        --check-stdin)
            if [ "$#" -ne 1 ]; then
                echo "usage: aggregation_kat_probe_contract_test.sh --check-stdin" >&2
                exit 2
            fi
            run_check_stdin_mode
            ;;
        *)
            echo "usage: aggregation_kat_probe_contract_test.sh [--check-file <path>|--check-stdin]" >&2
            exit 2
            ;;
    esac
}

main "$@"
