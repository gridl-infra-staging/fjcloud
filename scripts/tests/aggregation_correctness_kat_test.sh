#!/usr/bin/env bash
# Hermetic tests for scripts/aggregation_correctness_kat.sh.
#
# The real KAT is a live-stack proof. These tests replace only W2's sourced run
# module and classifier CLI with local fakes so wrapper glue, ordered
# composition, query parsing, and zero-tolerance assertions stay fast.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

KAT="$REPO_ROOT/scripts/aggregation_correctness_kat.sh"
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

assert_file_empty_bytes() {
    local abs_path="$1" msg="$2" byte_count
    byte_count="$(wc -c <"$abs_path" | tr -d ' ')"
    assert_eq "$byte_count" "0" "$msg"
}

write_fixture_run_module() {
    local path="$1"
    cat >"$path" <<'SH'
#!/usr/bin/env bash

LRP_DRIVEN_REGION="us-east-1"
LRP_TARGET_DATE=""
LRP_CUSTOMER_ID=""
LRP_EVIDENCE_FILE=""

fixture_event() {
    printf '%s\n' "$1" >>"$KAT_TEST_EVENTS"
}

probe_fail() {
    printf 'LOCAL_REAL_PIPELINE_STATUS: FAIL reason=%s\n' "$1"
    exit 1
}

pipeline_teardown() {
    local rc=$?
    fixture_event teardown
    return "$rc"
}

lrp_pg_text_literal() {
    local value="$1"
    value="$(printf '%s' "$value" | sed "s/'/''/g")"
    printf "'%s'" "$value"
}

lrp_pg_utc_day_start_expr() {
    local day_literal
    day_literal="$(lrp_pg_text_literal "$1")"
    printf "(%s || ' 00:00:00+00')::timestamptz" "$day_literal"
}

lrp_prepare_env() { fixture_event prepare_env; }
lrp_create_evidence_file_and_trap() {
    fixture_event create_evidence_file_and_trap
    LRP_EVIDENCE_FILE="$KAT_TEST_STATE/evidence.json"
    : >"$LRP_EVIDENCE_FILE"
    trap pipeline_teardown EXIT
}
lrp_bring_up_stack() { fixture_event bring_up_stack; }
lrp_resolve_target() {
    fixture_event resolve_target
    LRP_CUSTOMER_ID="11111111-2222-3333-4444-555555555555"
}
lrp_capture_and_clear() {
    fixture_event capture_and_clear
    LRP_TARGET_DATE="2026-07-25"
}
lrp_start_agent_and_read_pre() { fixture_event start_agent_and_read_pre; }
lrp_drive_traffic() {
    fixture_event "drive_traffic writes=${LRP_DRIVE_WRITES} searches=${LRP_DRIVE_SEARCHES}"
}
lrp_await_delta_and_read_post() { fixture_event await_delta_and_read_post; }
lrp_aggregate() { fixture_event aggregate; }
lrp_build_evidence() {
    fixture_event build_evidence
    printf '{}\n' >"$LRP_EVIDENCE_FILE"
}

run_local_psql() {
    fixture_event query_usage
    printf '%s\n' "$*" >>"$KAT_TEST_SQL_LOG"
    case "${KAT_TEST_MODE:-success}" in
        query_error)
            echo "psql fixture failure" >&2
            return 1
            ;;
        *)
            printf '%s\n' "$KAT_TEST_SQL_ROW"
            ;;
    esac
}
SH
    chmod +x "$path"
}

write_fixture_classifier() {
    local path="$1"
    cat >"$path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ] || [ "${1:-}" != "--assert-evidence" ]; then
    echo "unexpected classifier invocation" >&2
    exit 2
fi
printf '%s\n' "assert_evidence $2" >>"$KAT_TEST_EVENTS"

case "${KAT_TEST_MODE:-success}" in
    classifier_fail)
        printf '%s\n' "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=value_mismatch"
        exit 1
        ;;
    classifier_malformed)
        printf '%s\n' "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"
        printf '%s\n' "extra line"
        exit 0
        ;;
    *)
        printf '%s\n' "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"
        exit 0
        ;;
esac
SH
    chmod +x "$path"
}

build_fixture_tree() {
    local tmp="$1" fixture_scripts="$tmp/scripts"
    mkdir -p "$fixture_scripts/lib"
    cp "$KAT" "$fixture_scripts/aggregation_correctness_kat.sh"
    write_fixture_run_module "$fixture_scripts/lib/local_real_pipeline_run.sh"
    write_fixture_classifier "$fixture_scripts/local_real_pipeline_probe.sh"
}

run_kat_fixture() {
    local mode="$1" sql_row="$2"
    local tmp
    tmp="$(mktemp -d)"
    register_tmp_path "$tmp"
    build_fixture_tree "$tmp"

    KAT_FIXTURE_OUT="$tmp/out.txt"
    KAT_FIXTURE_ERR="$tmp/err.txt"
    KAT_FIXTURE_EVENTS="$tmp/events.log"
    KAT_FIXTURE_SQL="$tmp/sql.log"
    KAT_FIXTURE_STATE="$tmp"
    : >"$KAT_FIXTURE_EVENTS"
    : >"$KAT_FIXTURE_SQL"

    set +e
    env -i \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$HOME" \
        KAT_TEST_MODE="$mode" \
        KAT_TEST_STATE="$tmp" \
        KAT_TEST_EVENTS="$KAT_FIXTURE_EVENTS" \
        KAT_TEST_SQL_LOG="$KAT_FIXTURE_SQL" \
        KAT_TEST_SQL_ROW="$sql_row" \
        bash "$tmp/scripts/aggregation_correctness_kat.sh" >"$KAT_FIXTURE_OUT" 2>"$KAT_FIXTURE_ERR"
    KAT_FIXTURE_RC=$?
    set -e
    KAT_FIXTURE_STDOUT="$(cat "$KAT_FIXTURE_OUT")"
    KAT_FIXTURE_STDERR="$(cat "$KAT_FIXTURE_ERR")"
}

assert_kat_failure() {
    local mode="$1" sql_row="$2" reason="$3" expected_detail="$4"
    run_kat_fixture "$mode" "$sql_row"
    assert_ne "$KAT_FIXTURE_RC" "0" "$reason exits non-zero"
    assert_contains "$KAT_FIXTURE_STDOUT" "AGGREGATION_CORRECTNESS_KAT: FAIL reason=$reason" \
        "$reason emits its specific failure reason"
    assert_contains "$KAT_FIXTURE_STDOUT" "$expected_detail" \
        "$reason includes expected and actual evidence"
    assert_not_contains "$KAT_FIXTURE_STDOUT" "AGGREGATION_CORRECTNESS_KAT: PASS" \
        "$reason never emits final KAT PASS"
}

test_success_composes_w2_pipeline_and_reports_known_answer() {
    run_kat_fixture success "1|12|5|12|5"

    assert_eq "$KAT_FIXTURE_RC" "0" "KAT wrapper succeeds when classifier, daily row, and raw sums match"
    assert_contains "$KAT_FIXTURE_STDOUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "KAT prints the canonical W2 classifier PASS before its own success"
    assert_contains "$KAT_FIXTURE_STDOUT" "AGGREGATION_CORRECTNESS_KAT: PASS" \
        "KAT emits one final PASS status"
    assert_contains "$KAT_FIXTURE_STDOUT" "pipeline_executed=true" \
        "KAT PASS carries a non-vacuous live-run denominator"
    assert_contains "$KAT_FIXTURE_STDOUT" "driven_writes=11 driven_searches=5" \
        "KAT PASS reports the driven wrapper knobs"
    assert_contains "$KAT_FIXTURE_STDOUT" "write_arithmetic=1+11=12 expected_searches=5" \
        "KAT PASS reports the hand calculation"
    assert_contains "$KAT_FIXTURE_STDOUT" "daily_write_operations=12 daily_search_requests=5 raw_write_sum=12 raw_search_sum=5" \
        "KAT PASS reports exact daily counters and raw sums"

    local expected_events
    expected_events="$(cat <<'EOF'
prepare_env
create_evidence_file_and_trap
bring_up_stack
resolve_target
capture_and_clear
start_agent_and_read_pre
drive_traffic writes=11 searches=5
await_delta_and_read_post
aggregate
build_evidence
assert_evidence
query_usage
teardown
EOF
)"
    assert_eq "$(sed "s# $KAT_FIXTURE_STATE/evidence.json##" "$KAT_FIXTURE_EVENTS")" "$expected_events" \
        "KAT composes W2 stage functions, classifier, query, and teardown in order"
}

test_classifier_pass_is_required_before_known_answer_queries() {
    run_kat_fixture classifier_fail "1|12|5|12|5"

    assert_ne "$KAT_FIXTURE_RC" "0" "classifier failure exits non-zero"
    assert_contains "$KAT_FIXTURE_STDOUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=value_mismatch" \
        "classifier failure keeps W2's exact verdict visible"
    assert_contains "$KAT_FIXTURE_STDOUT" "AGGREGATION_CORRECTNESS_KAT: FAIL reason=classifier_failed" \
        "classifier failure becomes a hard KAT failure"
    assert_not_contains "$(cat "$KAT_FIXTURE_EVENTS")" "query_usage" \
        "KAT does not query or assert known answers after classifier failure"
}

test_failure_reasons_are_specific_and_red_capable() {
    assert_kat_failure success "0||||" "daily_row_count_mismatch" "expected=1 actual=0"
    assert_kat_failure success "2|12|5|12|5" "daily_row_count_mismatch" "expected=1 actual=2"
    assert_kat_failure success "1|abc|5|12|5" "non_integer_field" "field=daily_write_operations actual=abc"
    assert_kat_failure success "1|25000|250000|25000|250000" "seed_values_survived" \
        "rejected_write_operations=25000 rejected_search_requests=250000"
    assert_kat_failure success "1|11|5|12|5" "daily_write_mismatch" "expected=12 actual=11"
    assert_kat_failure success "1|12|4|12|5" "daily_search_mismatch" "expected=5 actual=4"
    assert_kat_failure success "1|12|5|11|5" "raw_write_sum_mismatch" "expected=12 actual=11"
    assert_kat_failure success "1|12|5|12|4" "raw_search_sum_mismatch" "expected=5 actual=4"
    assert_kat_failure success "1|12|5|12|6" "raw_search_sum_mismatch" "expected=5 actual=6"
    assert_kat_failure query_error "1|12|5|12|5" "kat_query_failed" "scope_customer=11111111-2222-3333-4444-555555555555"
}

test_classifier_output_shape_is_exact() {
    assert_kat_failure classifier_malformed "1|12|5|12|5" "classifier_malformed" \
        "expected=LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"
}

test_query_is_scoped_to_customer_region_and_half_open_day() {
    run_kat_fixture success "1|12|5|12|5"

    local sql_log
    sql_log="$(cat "$KAT_FIXTURE_SQL")"
    assert_contains "$sql_log" "customer_id='11111111-2222-3333-4444-555555555555'" \
        "KAT query is scoped to LRP_CUSTOMER_ID"
    assert_contains "$sql_log" "region='us-east-1'" \
        "KAT query is scoped to LRP_DRIVEN_REGION"
    assert_contains "$sql_log" "date='2026-07-25'::date" \
        "KAT query is scoped to LRP_TARGET_DATE"
    assert_contains "$sql_log" "recorded_at >= ('2026-07-25' || ' 00:00:00+00')::timestamptz" \
        "KAT raw sums use a UTC day start inclusive bound"
    assert_contains "$sql_log" "recorded_at < (('2026-07-25' || ' 00:00:00+00')::timestamptz + interval '1 day')" \
        "KAT raw sums use a UTC next-day exclusive bound"
    assert_contains "$sql_log" "event_type = 'write_operations'" \
        "KAT query separately sums write_operations"
    assert_contains "$sql_log" "event_type = 'search_requests'" \
        "KAT query separately sums search_requests"
}

test_wrapper_static_contract() {
    local script_text
    script_text="$(cat "$KAT")"
    assert_contains "$script_text" 'set -uo pipefail' \
        "KAT matches W2's non-errexit shell mode when sourcing the run module"
    assert_not_contains "$script_text" 'set -euo pipefail' \
        "KAT does not enable errexit around W2's explicit failure handling"
    assert_contains "$script_text" 'SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
        "KAT initializes SCRIPT_DIR for W2's sourceable module"
    assert_contains "$script_text" 'REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"' \
        "KAT initializes REPO_ROOT for W2's sourceable module"
    assert_contains "$script_text" 'LRP_DRIVE_WRITES=11' \
        "KAT sets W2 driven writes to 11"
    assert_contains "$script_text" 'LRP_DRIVE_SEARCHES=5' \
        "KAT sets W2 driven searches to 5"
    assert_contains "$script_text" 'source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"' \
        "KAT sources the W2 run module"
    assert_not_contains "$script_text" 'source "$SCRIPT_DIR/local_real_pipeline_probe.sh"' \
        "KAT does not source the dispatching probe wrapper"
}

main() {
    echo "=== aggregation_correctness_kat.sh tests ==="
    echo ""

    test_success_composes_w2_pipeline_and_reports_known_answer
    test_classifier_pass_is_required_before_known_answer_queries
    test_failure_reasons_are_specific_and_red_capable
    test_classifier_output_shape_is_exact
    test_query_is_scoped_to_customer_region_and_half_open_day
    test_wrapper_static_contract

    run_test_summary
}

main "$@"
