#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/local_real_pipeline_probe.sh.
#
# This owner answers "did this pipeline run produce this exact row value?".
# Every specimen is a local JSON fixture — the test starts no Docker, Postgres,
# flapjack, AWS, or live collector. It proves the classifier fails for a real
# defect (each FAIL branch) and passes only when every invariant holds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

PROBE="$REPO_ROOT/scripts/local_real_pipeline_probe.sh"
FIXTURE_DIR="$SCRIPT_DIR/fixtures/local_real_pipeline_probe"
TMP_PATHS=()
KNOWN_ANSWER_CASES=0
# Every distinct classifier reason exercised by a fixture case, space-separated.
# Used to prove the test denominator covers every named branch.
COVERED_REASONS=""
LEAK_GUARD_REGEX='(/tmp/|/private/|/User''s/|postgres(ql)?://|sk_''live|whsec''_|eyJ|stage1_secret)'

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

run_probe_fixture() {
    local fixture="$1" out_path="$2" err_path="$3" rc_path="$4"
    set +e
    bash "$PROBE" --assert-evidence "$fixture" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" > "$rc_path"
    set -e
}

stdout_matches_single_status_line() {
    local out_path="$1" expected_line="$2" expected_path
    expected_path="$(mktemp)"
    register_tmp_path "$expected_path"
    printf '%s\n' "$expected_line" > "$expected_path"
    cmp -s "$expected_path" "$out_path"
}

assert_stdout_exact_status_line() {
    local out_path="$1" expected_line="$2" msg="$3"
    if stdout_matches_single_status_line "$out_path" "$expected_line"; then
        pass "$msg"
    else
        fail "$msg (stdout must be exactly one status line ending in one newline)"
    fi
}

assert_file_empty_bytes() {
    local abs_path="$1" msg="$2" byte_count
    byte_count="$(wc -c < "$abs_path" | tr -d ' ')"
    assert_eq "$byte_count" "0" "$msg"
}

# Assert one fixture yields the exact status token and exit code, emits exactly
# one well-formed token, and leaks no path or secret-like material.
assert_probe_result() {
    local fixture_name="$1" expected_rc="$2" expected_line="$3"
    local tmp fixture out err rc
    fixture="$FIXTURE_DIR/$fixture_name"
    assert_file_exists "$fixture" "fixture $fixture_name exists"
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    run_probe_fixture "$fixture" "$out" "$err" "$rc"
    KNOWN_ANSWER_CASES=$((KNOWN_ANSWER_CASES + 1))
    COVERED_REASONS+=" ${expected_line##*reason=}"

    assert_eq "$(cat "$rc")" "$expected_rc" "$fixture_name exits with the expected status"
    assert_stdout_exact_status_line "$out" "$expected_line" \
        "$fixture_name emits the exact single-line status token"
    assert_eq \
        "$(grep -Ec '^LOCAL_REAL_PIPELINE_STATUS: (PASS|FAIL) reason=[a-z_]+$' "$out" || true)" \
        "1" \
        "$fixture_name emits exactly one complete status token"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "$fixture_name stdout omits paths and secret-like material"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "$fixture_name stderr omits paths and secret-like material"
}

# ============================================================================
# Tests
# ============================================================================

test_pass_and_fail_branch_contract() {
    assert_probe_result pass_fresh_exact.json 0 \
        "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"
    assert_probe_result fail_not_cleared.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared"
    assert_probe_result fail_absent.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent"
    assert_probe_result fail_zero_rows_affected.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=zero_rows_affected"
    assert_probe_result fail_stale.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=stale"
    assert_probe_result fail_seeded_value_mismatch.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=value_mismatch"
}

# The seed in scripts/seed_local.sh writes identical 250000/25000 counters to
# many usage_daily rows (every day of the cycle, multiple regions), so matching
# counters alone do not prove the intended specimen. PASS must additionally
# prove the returned row's own identity matches the requested customer, region,
# and date. Each fixture mutates exactly one identity component so every part of
# the identity contract is independently load-bearing.
test_row_identity_must_match_requested_specimen() {
    assert_probe_result fail_row_identity_customer_mismatch.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=row_identity_mismatch"
    assert_probe_result fail_row_identity_region_mismatch.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=row_identity_mismatch"
    assert_probe_result fail_row_identity_date_mismatch.json 1 \
        "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=row_identity_mismatch"
}

test_malformed_evidence_contract() {
    local malformed_case
    for malformed_case in \
        fail_malformed.json \
        fail_duplicate_keys.json \
        malformed_empty_document.json \
        malformed_missing_field.json \
        malformed_extra_field.json \
        malformed_unsupported_schema.json \
        malformed_wrong_type.json \
        malformed_negative_counter.json \
        malformed_invalid_date.json \
        malformed_non_padded_date.json \
        malformed_invalid_timestamp.json \
        malformed_non_utc_timestamp.json \
        malformed_space_separated_timestamp.json \
        malformed_lowercase_t_timestamp.json \
        malformed_partial_absence.json; do
        assert_probe_result "$malformed_case" 1 \
            "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=malformed"
    done
}

test_cli_failure_contract() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"

    # Stage 2: zero arguments now selects full pipeline mode, so the obsolete
    # zero-argument CLI-failure assertion is gone. An UNKNOWN flag is still a
    # pure CLI failure (usage + exit 2) that never touches the live stack.
    set +e
    bash "$PROBE" --bogus-flag >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "an unknown flag is a CLI failure"
    assert_file_empty_bytes "$out" "unknown-flag CLI failure emits no stdout bytes"
    assert_contains "$(cat "$err")" "usage:" "unknown-flag CLI failure emits a usage diagnostic"

    set +e
    bash "$PROBE" --assert-evidence "$tmp/missing.json" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "unreadable evidence is a CLI failure"
    assert_file_empty_bytes "$out" "unreadable evidence emits no stdout bytes"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "unreadable evidence diagnostic omits the supplied host path"

    set +e
    bash "$PROBE" --assert-evidence "$FIXTURE_DIR/pass_fresh_exact.json" extra >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "an extra positional argument is a CLI failure"
    assert_file_empty_bytes "$out" "extra-argument CLI failure emits no stdout bytes"
}

test_stdout_shape_guard_rejects_contract_breaking_files() {
    local tmp good extra_blank blank_only
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    good="$tmp/good.txt"
    extra_blank="$tmp/extra_blank.txt"
    blank_only="$tmp/blank_only.txt"

    printf '%s\n' "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" > "$good"
    printf '%s\n\n' "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" > "$extra_blank"
    printf '\n\n' > "$blank_only"

    if stdout_matches_single_status_line "$good" \
        "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"; then
        pass "stdout guard accepts exactly one status line"
    else
        fail "stdout guard rejects a valid single status line"
    fi
    if stdout_matches_single_status_line "$extra_blank" \
        "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"; then
        fail "stdout guard rejects trailing blank status output"
    else
        pass "stdout guard rejects trailing blank status output"
    fi
    if stdout_matches_single_status_line "$blank_only" \
        "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified"; then
        fail "stdout guard rejects blank-only status output"
    else
        pass "stdout guard rejects blank-only status output"
    fi
}

test_classifier_has_no_live_side_effects() {
    local tmp stub_dir log out err rc command_name before after
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"
    mkdir -p "$stub_dir"
    log="$tmp/live_calls.log"
    : > "$log"
    # Shadow every live command the harness must never touch in Stage 1. Each
    # stub records its invocation and exits non-zero, so any accidental call
    # both leaves a trace and would break the PASS verdict.
    for command_name in aws curl psql ssh; do
        write_mock_script "$stub_dir/$command_name" \
            "printf '%s\\n' '$command_name called' >> '$log'; exit 99"
    done
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    # Pre-create the capture files so the before/after snapshot only detects
    # artifacts the classifier itself would leave behind.
    : > "$out"
    : > "$err"
    : > "$rc"
    before="$(ls -1A "$tmp" | sort)"

    SENTINEL_SECRET="stage1_secret_should_not_leak" \
        DATABASE_URL="postgresql://secret-user:secret-password@private-db/fjcloud" \
        PATH="$stub_dir:$PATH" \
        run_probe_fixture "$FIXTURE_DIR/pass_fresh_exact.json" "$out" "$err" "$rc"
    after="$(ls -1A "$tmp" | sort)"

    assert_eq "$(cat "$rc")" "0" "classifier stays green with live-command stubs first on PATH"
    assert_eq "$(cat "$log")" "" "classifier invokes no live command"
    assert_eq "$after" "$before" "classifier creates no artifact next to the fixture temp"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "side-effect guard stdout omits sentinel secrets and paths"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "side-effect guard stderr omits sentinel secrets and paths"

    # Strip comment lines first: a header comment that names the sibling probe
    # to document the ownership boundary is fine; an executable line that
    # sources a secret file or invokes the sibling probe is not.
    if grep -v '^[[:space:]]*#' "$PROBE" \
        | grep -Eq 'probe_usage_rollup_freshness\.sh|\.secret/|\.env\.local'; then
        fail "classifier references no secret source or sibling live probe"
    else
        pass "classifier references no secret source or sibling live probe"
    fi
}

test_local_ci_registration_is_complete() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local gate_name="local-real-pipeline-contract"
    local gate_body

    assert_eq \
        "$(grep -Fxc '#                    local-real-pipeline-contract,' "$local_ci" || true)" \
        "1" \
        "local-ci usage help names the local-real-pipeline gate exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_local_real_pipeline_contract() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines the local-real-pipeline gate function exactly once"
    assert_eq \
        "$(grep -Fxc 'schedule local-real-pipeline-contract' "$local_ci" || true)" \
        "1" \
        "local-ci fast scheduler names the local-real-pipeline gate exactly once"
    assert_eq \
        "$(grep -Fxc '            local-real-pipeline-contract) run_gate local-real-pipeline-contract gate_local_real_pipeline_contract ;;' "$local_ci" || true)" \
        "1" \
        "local-ci dispatches the local-real-pipeline gate exactly once"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci summary-only inventory names the local-real-pipeline gate exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci unknown-gate help names the local-real-pipeline gate exactly once"
    assert_eq "$(grep -Fo "$gate_name" "$local_ci" | wc -l | tr -d ' ')" "6" \
        "local-ci has exactly the six intended local-real-pipeline gate registrations"

    gate_body="$(sed -n '/^gate_local_real_pipeline_contract()/,/^}/p' "$local_ci")"
    assert_contains "$gate_body" 'scripts/tests/local_real_pipeline_probe_test.sh' \
        "local-real-pipeline gate runs the hermetic contract suite"
    assert_not_contains "$gate_body" 'scripts/local_real_pipeline_probe.sh' \
        "local-real-pipeline gate does not invoke the zero-argument live probe"
    assert_not_contains "$gate_body" '--negative-seeded' \
        "local-real-pipeline gate does not invoke negative-seeded live mode"
    assert_not_contains "$gate_body" '--negative-nodrive' \
        "local-real-pipeline gate does not invoke negative-nodrive live mode"
}

test_named_branch_denominator_is_complete() {
    local required_reason
    for required_reason in \
        verified \
        absent \
        value_mismatch \
        stale \
        zero_rows_affected \
        not_cleared \
        row_identity_mismatch \
        malformed; do
        assert_contains " $COVERED_REASONS " " $required_reason " \
            "denominator proves the $required_reason branch ran"
    done
    # PASS, the seven FAIL branches, plus every malformed sub-case must all run.
    if [ "$KNOWN_ANSWER_CASES" -ge 21 ]; then
        pass "known-answer denominator is complete ($KNOWN_ANSWER_CASES cases)"
    else
        fail "known-answer denominator too small ($KNOWN_ANSWER_CASES cases)"
    fi
}

# ============================================================================
# Full (default) mode — hermetic two-scrape orchestration contract
# ============================================================================
#
# The default (zero-argument) path drives the real local stack. These tests
# exercise it hermetically: a temporary repo-shaped scripts/ tree copies the
# probe and its source-only libraries, replaces every sibling orchestration
# script with a deterministic stub, and puts scripted curl/DB command stubs on
# PATH. No Docker/Postgres/flapjack/API is started. The stubs record an ordered
# event trail so the tests can prove the load-bearing two-scrape bracket:
# baseline scrape (PRE) before traffic, traffic before the delta scrape (POST),
# aggregation after POST, and teardown last on both success and failure.

FULL_MODE_FIXED_UUID="2f1c9a4b-0000-4000-8000-00000000abcd"

# Build the repo-shaped fixture. Modes: "success" (whole bracket reaches PASS),
# "negative_seeded" (seeded usage_daily row remains live), "negative_nodrive"
# (cleared scope with no driven traffic), "fail_aggregation" (a post-startup
# stub failure to prove teardown still runs), "fail_evidence_query"
# (usage_daily evidence read fails after aggregation), or
# "sql_injection_customer" (customer_id contains SQL metacharacters that must
# stay inside literals). Echoes the fixture root.
build_full_mode_fixture() {
    local mode="$1" state_dir="$2"
    local fixture_root fscripts fbin
    fixture_root="$(mktemp -d)"; register_tmp_path "$fixture_root"
    fscripts="$fixture_root/scripts"
    fbin="$fixture_root/bin"
    mkdir -p "$fscripts/lib" "$fbin" "$state_dir"

    cp "$REPO_ROOT/scripts/local_real_pipeline_probe.sh" "$fscripts/"
    cp "$REPO_ROOT/scripts/lib/"*.sh "$fscripts/lib/"

    # --- sibling orchestration stubs (repo-relative) ------------------------
    write_mock_script "$fscripts/local_demo.sh" '
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--prepare-env-only" ]; then
  {
    echo "DATABASE_URL=postgresql://probe@127.0.0.1:5432/fjcloud_probe"
    echo "FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
    echo "FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000"
  } > "$DIR/.env.local"
fi
exit 0'
    write_mock_script "$fscripts/local-dev-up.sh" 'echo devup >> "$LRP_TEST_STATE/events.log"; exit 0'
    write_mock_script "$fscripts/api-dev.sh" 'exit 0'
    write_mock_script "$fscripts/seed_local.sh" 'echo seed >> "$LRP_TEST_STATE/events.log"; exit 0'
    write_mock_script "$fscripts/start-metering.sh" \
        'echo startmeter >> "$LRP_TEST_STATE/events.log"; touch "$LRP_TEST_STATE/agent_started"; exit 0'
    write_mock_script "$fscripts/local-dev-down.sh" 'echo devdown >> "$LRP_TEST_STATE/events.log"; exit 0'

    if [ "$mode" = "fail_aggregation" ]; then
        write_mock_script "$fscripts/run-aggregation-job.sh" \
            'echo aggregation >> "$LRP_TEST_STATE/events.log"; echo "boom: aggregation job failed" >&2; exit 1'
    elif [ "$mode" = "negative_nodrive" ]; then
        write_mock_script "$fscripts/run-aggregation-job.sh" '
echo aggregation >> "$LRP_TEST_STATE/events.log"
echo "2026-07-24T00:00:05.000000Z  INFO aggregation_job: aggregation complete target_date=$1 rows_affected=0"
echo "[aggregation-job] Aggregation complete for $1."
exit 0'
    else
        write_mock_script "$fscripts/run-aggregation-job.sh" '
echo aggregation >> "$LRP_TEST_STATE/events.log"
echo "2026-07-24T00:00:05.000000Z  INFO aggregation_job: aggregation complete target_date=$1 rows_affected=1"
echo "[aggregation-job] Aggregation complete for $1."
exit 0'
    fi

    write_full_mode_curl_stub "$fbin/curl"
    write_full_mode_psql_stub "$fbin/psql"

    printf '%s\n' "$fixture_root"
}

# Deterministic curl stub. Status calls (`-w '%{http_code}'`) return 200 and
# record driven traffic; body calls return scripted agent-health / /metrics /
# tenant-map payloads. /metrics counters rise with recorded traffic so
# POST-minus-PRE equals exactly the driven counts.
write_full_mode_curl_stub() {
    write_mock_script "$1" '
STATE="$LRP_TEST_STATE"
customer_value="$LRP_TEST_UUID"
if [ "${LRP_TEST_MODE:-}" = "sql_injection_customer" ]; then
  printf -v customer_value "%s\047;DROP/*x*/TABLE/*x*/usage_daily;--" "$LRP_TEST_UUID"
fi
uid="$(printf "%s" "$customer_value" | tr -d "-" | tr "[:upper:]" "[:lower:]")_test-index"
url=""; has_w=0; method="GET"; prev=""
for a in "$@"; do
  case "$a" in
    -w) has_w=1 ;;
    http://*|https://*) url="$a" ;;
  esac
  case "$prev" in -X) method="$a" ;; esac
  prev="$a"
done

writes_now() { [ -f "$STATE/writes" ] && wc -l < "$STATE/writes" | tr -d " " || echo 0; }
searches_now() { [ -f "$STATE/searches" ] && wc -l < "$STATE/searches" | tr -d " " || echo 0; }
traffic_done() { [ -s "$STATE/writes" ] && [ -s "$STATE/searches" ]; }

if [ "$has_w" = "1" ]; then
  case "$url" in
    */1/indexes/*/batch) echo write >> "$STATE/events.log"; echo w >> "$STATE/writes" ;;
    */1/indexes/*/query) echo search >> "$STATE/events.log"; echo s >> "$STATE/searches" ;;
  esac
  printf "200"
  exit 0
fi

case "$url" in
  *:9091/health)
    if [ ! -f "$STATE/agent_started" ]; then
      printf "{\"status\":\"ok\",\"last_scrape_at\":null}\n"
    elif traffic_done; then
      printf "{\"status\":\"ok\",\"last_scrape_at\":\"2026-07-24T00:00:02.000000Z\"}\n"
    else
      printf "{\"status\":\"ok\",\"last_scrape_at\":\"2026-07-24T00:00:01.000000Z\"}\n"
    fi
    ;;
  */metrics)
    echo metrics >> "$STATE/events.log"
    printf "flapjack_search_requests_total{index=\"%s\"} %s\n" "$uid" "$((100 + $(searches_now)))"
    printf "flapjack_write_operations_total{index=\"%s\"} %s\n" "$uid" "$((50 + $(writes_now)))"
    ;;
  */internal/tenant-map)
    printf "[{\"tenant_id\":\"test-index\",\"flapjack_uid\":\"%s\",\"customer_id\":\"%s\",\"flapjack_url\":\"http://127.0.0.1:7700\",\"tier\":\"shared\"}]\n" "$uid" "$customer_value"
    ;;
esac
exit 0'
}

# Deterministic psql stub. Answers each scoped query by SQL shape: fixed
# customer UUID, canonical UTC clock, zero-after-clear counts, both delta event
# types only once traffic landed, no date straddle, and a usage_daily row whose
# counters equal the driven traffic (so they equal /metrics POST-minus-PRE).
write_full_mode_psql_stub() {
    write_mock_script "$1" '
STATE="$LRP_TEST_STATE"
sql=""; prev=""
for a in "$@"; do
  case "$prev" in -*c) sql="$a" ;; esac
  prev="$a"
done
printf "%s\n" "$sql" >> "$STATE/sql.log"
customer_value="$LRP_TEST_UUID"
if [ "${LRP_TEST_MODE:-}" = "sql_injection_customer" ]; then
  printf -v customer_value "%s\047;DROP/*x*/TABLE/*x*/usage_daily;--" "$LRP_TEST_UUID"
fi
writes_now() { [ -f "$STATE/writes" ] && wc -l < "$STATE/writes" | tr -d " " || echo 0; }
searches_now() { [ -f "$STATE/searches" ] && wc -l < "$STATE/searches" | tr -d " " || echo 0; }
traffic_done() { [ -s "$STATE/writes" ] && [ -s "$STATE/searches" ]; }

case "$sql" in
  *"FROM customers"*)             printf "%s\n" "$customer_value" ;;
  *"to_char(now()"*)              printf "2026-07-24T00:00:00.000000Z\n" ;;
  DELETE*)                        : ;;
  *"count(DISTINCT event_type)"*) if traffic_done; then echo 2; else echo 0; fi ;;
  *"NOT (recorded_at"*)           echo 0 ;;
  *"SELECT (SELECT count(*)"*)    echo 0 ;;
  *"search_requests,write_operations,to_char(aggregated_at"*)
      if [ "${LRP_TEST_MODE:-}" = "negative_seeded" ]; then
        printf "250000|25000|%s|%s|%s|%s\n" \
          "2026-07-24T00:00:05.000000Z" "$customer_value" "us-east-1" "2026-07-24"
        exit 0
      fi
      if [ "${LRP_TEST_MODE:-}" = "fail_evidence_query" ]; then
        echo "usage_daily read failed" >&2
        exit 1
      fi
      if [ "${LRP_TEST_MODE:-}" = "negative_nodrive" ]; then
        exit 0
      fi
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$(searches_now)" "$(writes_now)" "2026-07-24T00:00:05.000000Z" \
        "$customer_value" "us-east-1" "2026-07-24" ;;
  *)                              : ;;
esac
exit 0'
}

# Run the probe in full mode against a fixture. Echoes nothing; sets globals
# FULL_MODE_RC, FULL_MODE_OUT, FULL_MODE_EVENTS, FULL_MODE_SQL_LOG.
run_full_mode_probe() {
    local mode="$1" probe_arg="${2:-}" tmp state_dir fixture_root out
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    state_dir="$tmp/state"
    out="$tmp/out.txt"
    fixture_root="$(build_full_mode_fixture "$mode" "$state_dir")"
    set --
    if [ -n "$probe_arg" ]; then
        set -- "$probe_arg"
    fi

    set +e
    env -i \
        PATH="$fixture_root/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$HOME" \
        TMPDIR="$tmp" \
        LRP_TEST_STATE="$state_dir" \
        LRP_TEST_UUID="$FULL_MODE_FIXED_UUID" \
        LRP_TEST_MODE="$mode" \
        LRP_SCRAPE_TIMEOUT=8 \
        LRP_API_READY_TIMEOUT=8 \
        LRP_HTTP_READY_TIMEOUT=8 \
        bash "$fixture_root/scripts/local_real_pipeline_probe.sh" "$@" >"$out" 2>"$tmp/err.txt"
    FULL_MODE_RC=$?
    set -e
    FULL_MODE_OUT="$(cat "$out")"
    FULL_MODE_EVENTS="$state_dir/events.log"
    FULL_MODE_SQL_LOG="$state_dir/sql.log"
}

# First line number of an exact event tag (empty if absent).
first_event_line() { grep -n "^$2\$" "$1" 2>/dev/null | head -1 | cut -d: -f1; }
last_event_line() { grep -n "^$2\$" "$1" 2>/dev/null | tail -1 | cut -d: -f1; }

assert_order() {
    local before="$1" after="$2" msg="$3"
    if [ -n "$before" ] && [ -n "$after" ] && [ "$before" -lt "$after" ]; then
        pass "$msg"
    else
        fail "$msg (before='$before' after='$after')"
    fi
}

test_full_mode_success_two_scrape_order_and_pass() {
    run_full_mode_probe success

    assert_eq "$FULL_MODE_RC" "0" "full mode succeeds end-to-end"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "full mode prints the PASS verdict from the real classifier CLI"

    local ev="$FULL_MODE_EVENTS"
    local devup seed startmeter first_metrics last_metrics
    local first_write last_write first_search last_search aggregation devdown
    devup="$(first_event_line "$ev" devup)"
    seed="$(first_event_line "$ev" seed)"
    startmeter="$(first_event_line "$ev" startmeter)"
    first_metrics="$(first_event_line "$ev" metrics)"
    last_metrics="$(last_event_line "$ev" metrics)"
    first_write="$(first_event_line "$ev" write)"
    last_write="$(last_event_line "$ev" write)"
    first_search="$(first_event_line "$ev" search)"
    last_search="$(last_event_line "$ev" search)"
    aggregation="$(first_event_line "$ev" aggregation)"
    devdown="$(last_event_line "$ev" devdown)"

    assert_order "$devup" "$seed" "stack comes up before seeding"
    assert_order "$seed" "$startmeter" "seeding before the metering agent starts"
    assert_order "$startmeter" "$first_metrics" "agent starts before the PRE /metrics read"
    assert_order "$first_metrics" "$first_write" "baseline /metrics (PRE) precedes any driven write"
    assert_order "$first_metrics" "$first_search" "baseline /metrics (PRE) precedes any driven search"
    assert_order "$last_write" "$last_metrics" "POST /metrics follows the last driven write"
    assert_order "$last_search" "$last_metrics" "POST /metrics follows the last driven search"
    assert_order "$last_metrics" "$aggregation" "aggregation runs after the POST /metrics read"
    assert_order "$aggregation" "$devdown" "teardown runs after aggregation"

    # Teardown must be the final recorded event on the happy path.
    local final_tag
    final_tag="$(tail -1 "$ev" 2>/dev/null)"
    assert_eq "$final_tag" "devdown" "teardown is the last event on success"
}

test_full_mode_teardown_on_post_startup_failure() {
    run_full_mode_probe fail_aggregation

    assert_ne "$FULL_MODE_RC" "0" "full mode exits non-zero on a post-startup failure"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=aggregation" \
        "post-startup failure emits a loud FAIL status token, never a default-healthy PASS"

    local ev="$FULL_MODE_EVENTS"
    # The stack was brought up and then a post-startup step failed; teardown
    # must still run (trap), and it must be the last recorded event.
    assert_eq "$(tail -1 "$ev" 2>/dev/null)" "devdown" \
        "teardown still runs (and runs last) after a post-startup failure"
    local devup aggregation devdown
    devup="$(first_event_line "$ev" devup)"
    aggregation="$(first_event_line "$ev" aggregation)"
    devdown="$(last_event_line "$ev" devdown)"
    assert_order "$devup" "$aggregation" "failure occurred after the stack came up"
    assert_order "$aggregation" "$devdown" "teardown followed the post-startup failure"
}

test_full_mode_fails_loud_when_evidence_query_fails() {
    run_full_mode_probe fail_evidence_query

    assert_ne "$FULL_MODE_RC" "0" "full mode exits non-zero when usage_daily evidence cannot be read"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=evidence" \
        "evidence query failure must not masquerade as an absent-row classifier verdict"

    local ev="$FULL_MODE_EVENTS"
    assert_eq "$(tail -1 "$ev" 2>/dev/null)" "devdown" \
        "teardown still runs after an evidence-query failure"
    local aggregation devdown
    aggregation="$(first_event_line "$ev" aggregation)"
    devdown="$(last_event_line "$ev" devdown)"
    assert_order "$aggregation" "$devdown" "evidence-query failure still tears down after aggregation"
}

test_full_mode_escapes_sql_metacharacters_in_customer_id() {
    run_full_mode_probe sql_injection_customer

    assert_eq "$FULL_MODE_RC" "0" \
        "full mode should keep SQL metacharacters inside a quoted customer_id literal"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "escaped customer_id should still let the harness finish with a PASS verdict"

    local sql_log
    sql_log="$(cat "$FULL_MODE_SQL_LOG")"
    assert_contains "$sql_log" "${FULL_MODE_FIXED_UUID}'';DROP/*x*/TABLE/*x*/usage_daily;--" \
        "SQL log should show the injected quote doubled inside the SQL literal"
    assert_not_contains "$sql_log" "${FULL_MODE_FIXED_UUID}';DROP/*x*/TABLE/*x*/usage_daily;--" \
        "SQL log should not contain a customer_id that terminates the literal before DROP TABLE"
}

test_negative_seeded_mode_fails_with_seeded_row_and_teardown() {
    run_full_mode_probe negative_seeded --negative-seeded

    assert_ne "$FULL_MODE_RC" "0" "negative seeded mode exits non-zero"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=not_cleared" \
        "negative seeded mode classifies the uncleared seed specimen as FAIL"

    local ev="$FULL_MODE_EVENTS"
    assert_eq "$(tail -1 "$ev" 2>/dev/null)" "devdown" \
        "negative seeded mode still runs teardown last"
    assert_contains "$(cat "$ev")" "seed" \
        "negative seeded mode runs the seed path"
    assert_not_contains "$(cat "$ev")" "startmeter" \
        "negative seeded mode does not start the metering agent"
    assert_not_contains "$(cat "$ev")" "write" \
        "negative seeded mode drives no write traffic"
    assert_not_contains "$(cat "$ev")" "search" \
        "negative seeded mode drives no search traffic"
}

test_negative_nodrive_mode_fails_absent_after_clear_and_teardown() {
    run_full_mode_probe negative_nodrive --negative-nodrive

    assert_ne "$FULL_MODE_RC" "0" "negative nodrive mode exits non-zero"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=absent" \
        "negative nodrive mode classifies the no-row specimen as FAIL"

    local ev="$FULL_MODE_EVENTS"
    assert_eq "$(tail -1 "$ev" 2>/dev/null)" "devdown" \
        "negative nodrive mode still runs teardown last"
    assert_contains "$(cat "$ev")" "seed" \
        "negative nodrive mode runs the seed path before clearing"
    assert_not_contains "$(cat "$ev")" "startmeter" \
        "negative nodrive mode does not start the metering agent"
    assert_not_contains "$(cat "$ev")" "write" \
        "negative nodrive mode drives no write traffic"
    assert_not_contains "$(cat "$ev")" "search" \
        "negative nodrive mode drives no search traffic"
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== local_real_pipeline_probe.sh tests ==="
    echo ""

    test_pass_and_fail_branch_contract
    test_row_identity_must_match_requested_specimen
    test_malformed_evidence_contract
    test_cli_failure_contract
    test_stdout_shape_guard_rejects_contract_breaking_files
    test_classifier_has_no_live_side_effects
    test_local_ci_registration_is_complete
    test_named_branch_denominator_is_complete
    test_full_mode_success_two_scrape_order_and_pass
    test_full_mode_teardown_on_post_startup_failure
    test_full_mode_fails_loud_when_evidence_query_fails
    test_full_mode_escapes_sql_metacharacters_in_customer_id
    test_negative_seeded_mode_fails_with_seeded_row_and_teardown
    test_negative_nodrive_mode_fails_absent_after_clear_and_teardown

    run_test_summary
}

main "$@"
