#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/local_real_pipeline_probe.sh.
#
# This owner answers "did this pipeline run produce this exact row value?".
# Every specimen is local — the test starts no Docker, Postgres, flapjack, AWS,
# or live collector. The local-real-pipeline-contract gate supplies the repo's
# existing node/Vitest install for emitted-oracle parser validation. The suite
# proves each classifier defect and passes only when every invariant holds.

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
LRP_ORACLE_FILE="$(
    SCRIPT_DIR="$REPO_ROOT/scripts" REPO_ROOT="$REPO_ROOT" bash -c '
        source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
        printf "%s\n" "$LRP_ORACLE_FILE"
    '
)"
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

# Temp directory with every symlink already resolved. Required wherever a
# specimen supplies LRP_ORACLE_FILE: the emitter rejects symlinked output-path
# components, and the platform temp root itself is symlinked (/var ->
# /private/var), so an unresolved mktemp path would make the symlink
# assertions below pass for the wrong reason.
make_physical_tmp_dir() {
    local created
    created="$(mktemp -d)"
    register_tmp_path "$created"
    (cd "$created" && pwd -P)
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
    local gate_body freshness_line contract_suite_line

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
    assert_eq \
        "$(printf '%s\n' "$gate_body" | grep -Fxc '    node_modules_fresh_or_fail || return $?' || true)" \
        "1" \
        "local-real-pipeline gate reuses the one node_modules freshness owner"
    assert_contains "$gate_body" 'scripts/tests/local_real_pipeline_probe_test.sh' \
        "local-real-pipeline gate runs the hermetic contract suite"
    freshness_line="$(printf '%s\n' "$gate_body" | grep -nF \
        '    node_modules_fresh_or_fail || return $?' | head -1 | cut -d: -f1)"
    contract_suite_line="$(printf '%s\n' "$gate_body" | grep -nF \
        'scripts/tests/local_real_pipeline_probe_test.sh' | head -1 | cut -d: -f1)"
    assert_order "$freshness_line" "$contract_suite_line" \
        "node_modules freshness is checked before the parser-backed shell suite"
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
# stay inside literals), "shared_customer_decoy" (another shared-plan row must
# not displace the canonical seeded customer), "fail_generated_clock", or
# "indeterminate_classifier". Echoes the fixture root.
build_full_mode_fixture() {
    local mode="$1" state_dir="$2"
    local fixture_root fscripts fbin
    fixture_root="$(make_physical_tmp_dir)"
    fscripts="$fixture_root/scripts"
    fbin="$fixture_root/bin"
    mkdir -p "$fscripts/lib" "$fbin" "$state_dir"

    cp "$REPO_ROOT/scripts/local_real_pipeline_probe.sh" "$fscripts/"
    cp "$REPO_ROOT/scripts/lib/"*.sh "$fscripts/lib/"
    write_mock_script "$fscripts/lib/process.sh" '
kill_pid_file() {
  echo stopagent >> "$LRP_TEST_STATE/events.log"
  if [ "${LRP_TEST_MODE:-}" = "fail_agent_stop" ]; then
    echo "metering agent stop failed" >&2
    return 1
  fi
  touch "$LRP_TEST_STATE/agent_stopped"
}'
    if [ "$mode" = "indeterminate_classifier" ]; then
        mv "$fscripts/local_real_pipeline_probe.sh" "$fscripts/local_real_pipeline_probe_real.sh"
        write_mock_script "$fscripts/local_real_pipeline_probe.sh" '
if [ "${1:-}" = "--assert-evidence" ]; then
  exit 2
fi
exec bash "$(dirname "$0")/local_real_pipeline_probe_real.sh" "$@"'
    fi

    # --- sibling orchestration stubs (repo-relative) ------------------------
    write_mock_script "$fscripts/local_demo.sh" '
DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${1:-}" = "--prepare-env-only" ]; then
  {
    echo "DATABASE_URL=postgresql://probe@127.0.0.1:5432/fjcloud_probe"
    echo "FLAPJACK_REGIONS=us-east-1:7700 eu-west-1:7701 eu-central-1:7702"
    echo "FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000"
    echo "ADMIN_KEY=fixture_admin_value"
  } > "$DIR/.env.local"
fi
exit 0'
    write_mock_script "$fscripts/local-dev-up.sh" 'echo devup >> "$LRP_TEST_STATE/events.log"; exit 0'
    write_mock_script "$fscripts/api-dev.sh" 'exit 0'
    write_mock_script "$fscripts/seed_local.sh" 'echo seed >> "$LRP_TEST_STATE/events.log"; exit 0'
    write_mock_script "$fscripts/start-metering.sh" '
echo startmeter >> "$LRP_TEST_STATE/events.log"
first_stat="$(cat "${PROC_ROOT:-}/stat" 2>/dev/null || true)"
sleep 0.3
second_stat="$(cat "${PROC_ROOT:-}/stat" 2>/dev/null || true)"
proc_snapshot_valid=false
if grep -q "^MemTotal:" "${PROC_ROOT:-}/meminfo" 2>/dev/null &&
   grep -q "^MemAvailable:" "${PROC_ROOT:-}/meminfo" 2>/dev/null &&
   grep -q ":" "${PROC_ROOT:-}/net/dev" 2>/dev/null &&
   [ -n "$first_stat" ] && [ "$first_stat" != "$second_stat" ]; then
  proc_snapshot_valid=true
fi
printf "VM_ID=%s\nHOST_METRICS_ENABLED=%s\nHOST_METRICS_INTERVAL_SECS=%s\nPROC_ROOT=%s\nPROC_SNAPSHOT_VALID=%s\n" \
  "${VM_ID:-}" "${HOST_METRICS_ENABLED:-}" "${HOST_METRICS_INTERVAL_SECS:-}" \
  "${PROC_ROOT:-}" "$proc_snapshot_valid" \
  > "$LRP_TEST_STATE/metering_env"
touch "$LRP_TEST_STATE/agent_started"
exit 0'
    write_mock_script "$fscripts/local-dev-down.sh" 'echo devdown >> "$LRP_TEST_STATE/events.log"; exit 0'
    write_mock_script "$fbin/date" '
if [ "$#" -eq 2 ] && [ "$1" = "-u" ] && [ "$2" = "+%F" ]; then
  printf "2026-07-24\n"
  exit 0
fi
/bin/date "$@"'
    write_mock_script "$fbin/uname" 'printf "Darwin\n"'
    write_mock_script "$fbin/sysctl" '
case "${2:-}" in
  hw.memsize) printf "8589934592\n" ;;
  hw.ncpu) printf "8\n" ;;
  *) exit 1 ;;
esac'
    write_mock_script "$fbin/vm_stat" '
printf "%s\n" \
  "Mach Virtual Memory Statistics: (page size of 4096 bytes)" \
  "Pages free: 100000." \
  "Pages active: 900000." \
  "Pages inactive: 500000." \
  "Pages speculative: 100000." \
  "Pages wired down: 497152."'
    write_mock_script "$fbin/netstat" '
printf "%s\n" \
  "Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll" \
  "lo0 16384 <Link#1> 0 0 0 1000 0 0 2000 0" \
  "en0 1500 <Link#2> 0 0 0 3000 0 0 4000 0"'
    write_mock_script "$fbin/ps" 'printf "25.0\n15.0\n"'

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
echo "2026-07-24T00:05:05.000000Z  INFO aggregation_job: aggregation complete target_date=$1 rows_affected=1"
echo "[aggregation-job] Aggregation complete for $1."
exit 0'
    fi

    write_full_mode_curl_stub "$fbin/curl"
    write_full_mode_psql_stub "$fbin/psql"

    if [ "$mode" = "fail_aggregation" ]; then
        local fixture_oracle
        fixture_oracle="$fixture_root/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
        mkdir -p "$(dirname "$fixture_oracle")"
        printf '{"stale":true}\n' >"$fixture_oracle"
        printf '{"temporary":"stale"}\n' >"${fixture_oracle}.tmp.stale"
    fi

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
    *fixture_admin_value*) touch "$STATE/admin_key_argv_exposed" ;;
    @*)
      if grep -qx "x-admin-key: fixture_admin_value" "${a#@}" 2>/dev/null; then
        touch "$STATE/admin_key_header_seen"
      fi
      ;;
  esac
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
  */admin/vms)
    printf "%s\n" \
      "[{\"id\":\"00000000-0000-4000-8000-000000000101\",\"region\":\"us-east-1\",\"provider\":\"local\",\"hostname\":\"local-dev-us-east-1\",\"flapjack_url\":\"http://127.0.0.1:7700\",\"capacity\":{\"max_tenants\":10,\"max_indexes\":20},\"current_load\":{\"tenants\":2,\"indexes\":3},\"status\":\"active\",\"tenant_count\":2,\"index_count\":3,\"health\":\"healthy\",\"created_at\":\"2026-07-23T23:00:00Z\",\"updated_at\":\"2026-07-24T00:00:03Z\"},{\"id\":\"00000000-0000-4000-8000-000000000201\",\"region\":\"eu-west-1\",\"provider\":\"local\",\"hostname\":\"local-dev-eu-west-1\",\"flapjack_url\":\"http://127.0.0.1:7701\",\"capacity\":{\"max_tenants\":12,\"max_indexes\":24},\"current_load\":{\"tenants\":1,\"indexes\":2},\"status\":\"active\",\"tenant_count\":1,\"index_count\":2,\"health\":\"unhealthy\",\"created_at\":\"2026-07-23T23:01:00Z\",\"updated_at\":\"2026-07-24T00:00:03Z\"},{\"id\":\"00000000-0000-4000-8000-000000000301\",\"region\":\"eu-central-1\",\"provider\":\"local\",\"hostname\":\"local-dev-eu-central-1\",\"flapjack_url\":\"http://127.0.0.1:7702\",\"capacity\":{\"max_tenants\":8,\"max_indexes\":16},\"current_load\":{\"tenants\":0,\"indexes\":0},\"status\":\"active\",\"tenant_count\":0,\"index_count\":0,\"health\":\"unknown\",\"created_at\":\"2026-07-23T23:02:00Z\",\"updated_at\":\"2026-07-24T00:00:03Z\"},{\"id\":\"00000000-0000-4000-8000-000000000999\",\"region\":\"us-east-1\",\"provider\":\"local\",\"hostname\":\"retired-decoy\",\"flapjack_url\":\"http://127.0.0.1:7799\",\"capacity\":{\"max_tenants\":99},\"current_load\":{\"tenants\":99},\"status\":\"decommissioned\",\"tenant_count\":99,\"index_count\":99,\"health\":\"healthy\",\"created_at\":\"2026-07-20T00:00:00Z\",\"updated_at\":\"2026-07-20T00:00:00Z\"}]"
    ;;
  */admin/vms/00000000-0000-4000-8000-000000000101/host-metrics)
    # Model a valid SLOW run: the agent keeps sampling, so the sample available
    # right after agent start is superseded once the permitted next-scrape wait
    # and aggregation have elapsed. Publication must use the later sample.
    if grep -q "^aggregation\$" "$STATE/events.log" 2>/dev/null &&
       [ ! -f "$STATE/agent_stopped" ]; then
      printf "%s\n" \
        "{\"id\":\"10000000-0000-4000-8000-000000000002\",\"vm_id\":\"00000000-0000-4000-8000-000000000101\",\"collected_at\":\"2026-07-24T00:05:08.000000Z\",\"cpu_pct\":27.5,\"mem_used_bytes\":5120,\"mem_total_bytes\":8192,\"disk_used_bytes\":16400,\"disk_total_bytes\":32768,\"net_rx_bytes\":9123,\"net_tx_bytes\":9456,\"created_at\":\"2026-07-24T00:05:08.100000Z\"}"
    else
      printf "%s\n" \
        "{\"id\":\"10000000-0000-4000-8000-000000000001\",\"vm_id\":\"00000000-0000-4000-8000-000000000101\",\"collected_at\":\"2026-07-24T00:00:04.000000Z\",\"cpu_pct\":12.5,\"mem_used_bytes\":4096,\"mem_total_bytes\":8192,\"disk_used_bytes\":16384,\"disk_total_bytes\":32768,\"net_rx_bytes\":123,\"net_tx_bytes\":456,\"created_at\":\"2026-07-24T00:00:04.100000Z\"}"
    fi
    ;;
  *:9091/health)
    if [ ! -f "$STATE/agent_started" ]; then
      printf "{\"status\":\"ok\",\"last_scrape_at\":null}\n"
    elif traffic_done; then
      printf "{\"status\":\"ok\",\"last_scrape_at\":\"2026-07-24T00:05:00.000000Z\"}\n"
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
  *"FROM customers"*)
      if [ "${LRP_TEST_MODE:-}" = "shared_customer_decoy" ] &&
         [[ "$sql" != *"email = '"'"'dev@example.com'"'"'"* ]]; then
        printf "11111111-1111-4111-8111-111111111111\n"
      else
        printf "%s\n" "$customer_value"
      fi ;;
  *"to_char(now()"*)
      # Sequenced DB clock for one slow run: probe_started_at, then the
      # pre-publication host-sample refresh floor, then generated_at.
      clock_calls=$(( $(cat "$STATE/clock_calls" 2>/dev/null || echo 0) + 1 ))
      printf "%s" "$clock_calls" > "$STATE/clock_calls"
      case "$clock_calls" in
        1) printf "2026-07-24T00:00:00.000000Z\n" ;;
        2) printf "2026-07-24T00:05:06.000000Z\n" ;;
        *) if [ "${LRP_TEST_MODE:-}" = "fail_generated_clock" ]; then
             echo "generated_at clock unavailable" >&2
             exit 1
           fi
           printf "2026-07-24T00:05:10.000000Z\n" ;;
      esac ;;
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
        "$(searches_now)" "$(writes_now)" "2026-07-24T00:05:05.000000Z" \
        "$customer_value" "us-east-1" "$(date -u +%F)" ;;
  *)                              : ;;
esac
exit 0'
}

# Run the probe in full mode against a fixture. Echoes nothing; sets globals
# FULL_MODE_RC, FULL_MODE_OUT, FULL_MODE_EVENTS, FULL_MODE_SQL_LOG, and
# FULL_MODE_FIXTURE_ROOT.
run_full_mode_probe() {
    local mode="$1" probe_arg="${2:-}" tmp state_dir fixture_root out
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    state_dir="$tmp/state"
    out="$tmp/out.txt"
    fixture_root="$(build_full_mode_fixture "$mode" "$state_dir")"
    # BSD mktemp leaves suffix-bearing X templates literal. Keep that stale
    # historical filename occupied so full mode proves it requests a genuinely
    # unique evidence path instead of colliding before its EXIT trap is armed.
    : >"$tmp/local_real_pipeline_evidence.XXXXXX.json"
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
        LRP_NATIVE_PROC_ROOT="$state_dir/missing-native-proc" \
        LRP_HOST_METRICS_TIMEOUT=1 \
        LRP_SCRAPE_TIMEOUT=8 \
        LRP_API_READY_TIMEOUT=8 \
        LRP_HTTP_READY_TIMEOUT=8 \
        bash "$fixture_root/scripts/local_real_pipeline_probe.sh" "$@" >"$out" 2>"$tmp/err.txt"
    FULL_MODE_RC=$?
    set -e
    FULL_MODE_OUT="$(cat "$out")"
    FULL_MODE_EVENTS="$state_dir/events.log"
    FULL_MODE_SQL_LOG="$state_dir/sql.log"
    FULL_MODE_FIXTURE_ROOT="$fixture_root"
}

run_oracle_output_preparation() {
    local output_path="$1" tmp="$2"
    set +e
    env -i \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME="$HOME" \
        SCRIPT_DIR="$REPO_ROOT/scripts" \
        REPO_ROOT="$tmp/repo" \
        LRP_ORACLE_FILE="$output_path" \
        bash -c '
            source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
            lrp_prepare_oracle_output
        ' >"$tmp/out" 2>"$tmp/err"
    ORACLE_PREPARE_RC=$?
    set -e
    ORACLE_PREPARE_OUT="$(cat "$tmp/out")"
}

# Invoke the canonical TypeScript parser through its existing Vitest owner.
# This runs after the env -i probe sandbox returns because that PATH has no node.
oracle_specimen_is_accepted() {
    REAL_PIPELINE_ORACLE_SPECIMEN="$1" npm --prefix "$REPO_ROOT/web" test -- \
        tests/fixtures/real_pipeline_oracle_specimen.test.ts
}

test_oracle_bridge_accepts_valid_and_propagates_rejections() {
    local specimen_dir="$REPO_ROOT/web/tests/fixtures/real_pipeline_oracle_specimens"
    local tmp out err rc specimen_name
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/vitest.out"; err="$tmp/vitest.err"
    set +e
    oracle_specimen_is_accepted "$specimen_dir/accepts_minimal_pass.json" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "0" \
        "shell bridge accepts the positive specimen through the canonical parser"
    for specimen_name in \
        rejects_extra_top_level_key.json \
        rejects_metering_delta_mismatch.json; do
        set +e
        oracle_specimen_is_accepted "$specimen_dir/$specimen_name" >"$out" 2>"$err"
        rc=$?
        set -e
        assert_ne "$rc" "0" \
            "shell bridge propagates the parser rejection for $specimen_name"
    done
}

test_committed_redacted_oracle_stays_parser_valid() {
    local oracle_path tmp out err rc
    oracle_path="$REPO_ROOT/docs/runbooks/evidence/local-real-pipeline-oracle/2026_07_26_stage_03/oracle_redacted.json"
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/vitest.out"; err="$tmp/vitest.err"

    set +e
    oracle_specimen_is_accepted "$oracle_path" >"$out" 2>"$err"
    rc=$?
    set -e

    assert_eq "$rc" "0" \
        "committed stage-3 redacted oracle stays accepted by the canonical parser bridge"
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

test_full_mode_emits_parser_valid_oracle() {
    run_full_mode_probe success
    local fixture_oracle state_dir
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    state_dir="$(dirname "$FULL_MODE_EVENTS")"

    if [ -f "$state_dir/admin_key_header_seen" ]; then
        pass "authenticated oracle requests deliver ADMIN_KEY through a curl header file"
    else
        fail "authenticated oracle requests deliver ADMIN_KEY through a curl header file"
    fi
    if [ ! -e "$state_dir/admin_key_argv_exposed" ]; then
        pass "authenticated oracle requests keep ADMIN_KEY out of curl argv"
    else
        fail "authenticated oracle requests keep ADMIN_KEY out of curl argv"
    fi

    # This stronger gate requires Stage 2's fixture psql/curl stubs to serve VM
    # inventory and host-metric rows, not only the current metering counters.
    if [ -f "$fixture_oracle" ]; then
        pass "full mode emits the canonical real-pipeline oracle file"
    else
        fail "full mode emits the canonical real-pipeline oracle file (missing '$fixture_oracle')"
        fail "canonical parser accepts the emitted full-mode oracle (oracle file is missing)"
        fail "emitted oracle contains the exact metering known answers (oracle file is missing)"
        fail "emitted oracle selects and instruments the deterministic driven-region VM (oracle file is missing)"
        fail "emitted oracle contains exact per-region and fleet summaries (oracle file is missing)"
        fail "emitted oracle publishes the host sample refreshed just before serialization (oracle file is missing)"
        fail "emitted oracle never republishes the sample cached before the scrape wait (oracle file is missing)"
        return
    fi
    if python3 - "$fixture_oracle" <<'PY'
import os
import sys

assert os.stat(sys.argv[1]).st_mode & 0o777 == 0o600
PY
    then
        pass "emitted oracle is private mode 0600"
    else
        fail "emitted oracle is private mode 0600"
    fi
    if ! compgen -G "${fixture_oracle}.tmp.*" >/dev/null; then
        pass "successful publication leaves no oracle temporary candidate"
    else
        fail "successful publication leaves no oracle temporary candidate"
    fi

    if oracle_specimen_is_accepted "$fixture_oracle"; then
        pass "canonical parser accepts the emitted full-mode oracle"
    else
        fail "canonical parser accepts the emitted full-mode oracle"
    fi

    if python3 - "$fixture_oracle" "$FULL_MODE_FIXED_UUID" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    oracle = json.load(handle)
customer_id = sys.argv[2]
expected_uid = customer_id.replace("-", "").lower() + "_test-index"

metering = oracle["metering"]
assert {
    "customer_id": metering["customer_id"],
    "index_name": metering["index_name"],
    "flapjack_uid": metering["flapjack_uid"],
    "region": metering["region"],
    "target_date": metering["target_date"],
    "expected_search_requests": metering["expected_search_requests"],
    "expected_write_operations": metering["expected_write_operations"],
    "pre_search_requests": metering["pre_search_requests"],
    "pre_write_operations": metering["pre_write_operations"],
    "post_search_requests": metering["post_search_requests"],
    "post_write_operations": metering["post_write_operations"],
} == {
    "customer_id": customer_id,
    "index_name": "test-index",
    "flapjack_uid": expected_uid,
    "region": "us-east-1",
    "target_date": "2026-07-24",
    "expected_search_requests": 8,
    "expected_write_operations": 6,
    "pre_search_requests": 100,
    "pre_write_operations": 50,
    "post_search_requests": 108,
    "post_write_operations": 56,
}
assert metering["usage_daily"] == {
    "customer_id": customer_id,
    "region": "us-east-1",
    "target_date": "2026-07-24",
    "search_requests": 8,
    "write_operations": 6,
    "rows_affected": 1,
    "aggregated_at": "2026-07-24T00:05:05.000000Z",
}
PY
    then
        pass "emitted oracle contains the exact metering known answers"
    else
        fail "emitted oracle contains the exact metering known answers"
    fi

    local selected_vm="00000000-0000-4000-8000-000000000101"
    local metering_env
    metering_env="$(cat "$(dirname "$FULL_MODE_EVENTS")/metering_env" 2>/dev/null || true)"
    assert_contains "$metering_env" "VM_ID=$selected_vm" \
        "metering launch receives the deterministic driven-region VM identity"
    assert_contains "$metering_env" "HOST_METRICS_ENABLED=true" \
        "metering launch opts into host metrics"
    if grep -q '^HOST_METRICS_INTERVAL_SECS=5$' <<<"$metering_env" &&
        grep -Eq '^PROC_ROOT=/.+/.local/real_pipeline_proc\.[0-9]+$' <<<"$metering_env" &&
        grep -q '^PROC_SNAPSHOT_VALID=true$' <<<"$metering_env"; then
        pass "metering launch uses the short interval and an advancing proc-compatible source"
    else
        fail "metering launch uses the short interval and an advancing proc-compatible source"
    fi

    if python3 - "$fixture_oracle" "$selected_vm" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    oracle = json.load(handle)
selected_vm = sys.argv[2]
topology = oracle["topology"]
assert topology["selected_vm_id"] == selected_vm
assert [vm["id"] for vm in topology["vms"]] == [
    "00000000-0000-4000-8000-000000000301",
    "00000000-0000-4000-8000-000000000201",
    selected_vm,
]
assert topology["regions"] == [
    {"region": "eu-central-1", "vm_count": 1, "healthy_count": 0,
     "unhealthy_count": 0, "unknown_count": 1, "tenant_count": 0, "index_count": 0},
    {"region": "eu-west-1", "vm_count": 1, "healthy_count": 0,
     "unhealthy_count": 1, "unknown_count": 0, "tenant_count": 1, "index_count": 2},
    {"region": "us-east-1", "vm_count": 1, "healthy_count": 1,
     "unhealthy_count": 0, "unknown_count": 0, "tenant_count": 2, "index_count": 3},
]
assert topology["totals"] == {
    "vm_count": 3, "healthy_count": 1, "unhealthy_count": 1,
    "unknown_count": 1, "tenant_count": 3, "index_count": 5,
}
PY
    then
        pass "emitted oracle contains exact per-region and fleet summaries"
    else
        fail "emitted oracle contains exact per-region and fleet summaries"
    fi

    if python3 - "$fixture_oracle" "$selected_vm" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    oracle = json.load(handle)
assert oracle["host_metrics"] == {
    "max_sample_age_seconds": 120,
    "samples": [{
        "id": "10000000-0000-4000-8000-000000000002",
        "vm_id": sys.argv[2],
        "collected_at": "2026-07-24T00:05:08.000000Z",
        "cpu_pct": 27.5,
        "mem_used_bytes": 5120,
        "mem_total_bytes": 8192,
        "disk_used_bytes": 16400,
        "disk_total_bytes": 32768,
        "net_rx_bytes": 9123,
        "net_tx_bytes": 9456,
        "created_at": "2026-07-24T00:05:08.100000Z",
    }],
}
PY
    then
        pass "emitted oracle publishes the host sample refreshed just before serialization"
    else
        fail "emitted oracle publishes the host sample refreshed just before serialization"
    fi

    # The slow-run fixture keeps the agent's first sample well outside
    # max_sample_age_seconds at publication time, so republishing the cached
    # capture instead of refreshing it is a detectable regression.
    if ! grep -q '10000000-0000-4000-8000-000000000001' "$fixture_oracle"; then
        pass "emitted oracle never republishes the sample cached before the scrape wait"
    else
        fail "emitted oracle never republishes the sample cached before the scrape wait"
    fi
}

test_oracle_output_path_rejects_symlinks_and_non_regular_files() {
    local tmp victim output real_parent linked_parent
    tmp="$(make_physical_tmp_dir)"
    real_parent="$tmp/real-parent"
    mkdir -p "$tmp/repo" "$tmp/output" "$real_parent"
    victim="$tmp/victim"
    printf 'must-survive\n' >"$victim"

    # Positive control: a symlink-free path must be ACCEPTED, so the rejection
    # assertions below cannot pass merely because the guard rejects everything.
    run_oracle_output_preparation "$real_parent/oracle.json" "$tmp"
    assert_eq "$ORACLE_PREPARE_RC" "0" "oracle preparation accepts a symlink-free output path"
    run_oracle_output_preparation "$tmp/created-parent/oracle.json" "$tmp"
    assert_eq "$ORACLE_PREPARE_RC" "0" \
        "oracle preparation creates an absent symlink-free output parent"
    if [ -d "$tmp/created-parent" ]; then
        pass "oracle preparation creates the absent output parent in place"
    else
        fail "oracle preparation creates the absent output parent in place"
    fi

    output="$tmp/output/oracle.json"
    ln -s "$victim" "$output"
    run_oracle_output_preparation "$output" "$tmp"
    assert_ne "$ORACLE_PREPARE_RC" "0" "oracle preparation rejects a symlink output"
    assert_contains "$ORACLE_PREPARE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=env_prep" \
        "symlink output rejection uses the fail-closed status path"
    assert_eq "$(cat "$victim")" "must-survive" \
        "oracle preparation never follows an output symlink"

    linked_parent="$tmp/linked-parent"
    ln -s "$real_parent" "$linked_parent"
    run_oracle_output_preparation "$linked_parent/oracle.json" "$tmp"
    assert_ne "$ORACLE_PREPARE_RC" "0" "oracle preparation rejects a symlink output parent"
    if [ ! -e "$real_parent/oracle.json" ]; then
        pass "oracle preparation never writes through a symlink parent"
    else
        fail "oracle preparation never writes through a symlink parent"
    fi

    # A real leaf directory reached through a symlinked ANCESTOR is the case a
    # single immediate-parent test misses: mkdir, mktemp, and mv all follow the
    # earlier link and publish outside the operator-selected tree.
    local linked_ancestor
    mkdir -p "$real_parent/nested"
    linked_ancestor="$tmp/linked-ancestor"
    ln -s "$real_parent" "$linked_ancestor"
    run_oracle_output_preparation "$linked_ancestor/nested/oracle.json" "$tmp"
    assert_ne "$ORACLE_PREPARE_RC" "0" "oracle preparation rejects a symlinked output ancestor"
    assert_contains "$ORACLE_PREPARE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=env_prep" \
        "symlinked-ancestor rejection uses the fail-closed status path"
    if [ ! -e "$real_parent/nested/oracle.json" ]; then
        pass "oracle preparation never writes through a symlinked ancestor"
    else
        fail "oracle preparation never writes through a symlinked ancestor"
    fi

    # An ancestor symlink must also be rejected when the leaf does not exist
    # yet, because the `mkdir -p` that creates it would follow the link first.
    run_oracle_output_preparation "$linked_ancestor/absent/oracle.json" "$tmp"
    assert_ne "$ORACLE_PREPARE_RC" "0" \
        "oracle preparation rejects a symlinked ancestor before creating the leaf"
    if [ ! -e "$real_parent/absent" ]; then
        pass "oracle preparation creates no directory through a symlinked ancestor"
    else
        fail "oracle preparation creates no directory through a symlinked ancestor"
    fi

    output="$tmp/output/non-regular"
    mkdir "$output"
    run_oracle_output_preparation "$output" "$tmp"
    assert_ne "$ORACLE_PREPARE_RC" "0" "oracle preparation rejects a non-regular output"
}

test_oracle_publication_inputs_fail_closed() {
    local fixture_oracle
    run_full_mode_probe fail_generated_clock
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    assert_ne "$FULL_MODE_RC" "0" "generated_at DB-clock failure exits non-zero"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=oracle" \
        "generated_at DB-clock failure emits the oracle FAIL path"
    assert_not_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "generated_at DB-clock failure withholds the captured PASS"
    if [ ! -e "$fixture_oracle" ] && ! compgen -G "${fixture_oracle}.tmp.*" >/dev/null; then
        pass "generated_at DB-clock failure leaves no oracle or temporary candidate"
    else
        fail "generated_at DB-clock failure leaves no oracle or temporary candidate"
    fi

    run_full_mode_probe indeterminate_classifier
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    assert_ne "$FULL_MODE_RC" "0" "indeterminate classifier exits non-zero"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=classifier" \
        "indeterminate classifier emits the classifier FAIL path"
    assert_not_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "indeterminate classifier never exposes a PASS token"
    if [ ! -e "$fixture_oracle" ] && ! compgen -G "${fixture_oracle}.tmp.*" >/dev/null; then
        pass "indeterminate classifier leaves no oracle or temporary candidate"
    else
        fail "indeterminate classifier leaves no oracle or temporary candidate"
    fi
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

    local fixture_oracle
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    assert_not_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "post-startup failure never prints a PASS token"
    if [ ! -e "$fixture_oracle" ] && [ ! -L "$fixture_oracle" ]; then
        pass "post-startup failure removes the stale oracle without replacement"
    else
        fail "post-startup failure removes the stale oracle without replacement"
    fi
    if ! compgen -G "${fixture_oracle}.tmp.*" >/dev/null; then
        pass "post-startup failure leaves no oracle temporary candidate"
    else
        fail "post-startup failure leaves no oracle temporary candidate"
    fi
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

test_full_mode_fails_loud_when_agent_stop_fails() {
    local ev fixture_oracle aggregation stopagent devdown
    run_full_mode_probe fail_agent_stop

    assert_ne "$FULL_MODE_RC" "0" "full mode exits non-zero when the metering-agent stop helper fails"
    assert_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=agent_stop" \
        "agent-stop helper failure emits the runner-owned FAIL token"
    assert_not_contains "$FULL_MODE_OUT" "LOCAL_REAL_PIPELINE_STATUS: PASS reason=verified" \
        "agent-stop helper failure withholds the captured PASS token"

    ev="$FULL_MODE_EVENTS"
    aggregation="$(first_event_line "$ev" aggregation)"
    stopagent="$(first_event_line "$ev" stopagent)"
    devdown="$(last_event_line "$ev" devdown)"
    assert_order "$aggregation" "$stopagent" "agent-stop helper is invoked after aggregation"
    assert_order "$stopagent" "$devdown" "teardown still runs after an agent-stop helper failure"

    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    if [ ! -e "$fixture_oracle" ] && ! compgen -G "${fixture_oracle}.tmp.*" >/dev/null; then
        pass "agent-stop helper failure leaves no oracle or temporary candidate"
    else
        fail "agent-stop helper failure leaves no oracle or temporary candidate"
    fi
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

test_full_mode_resolves_the_canonical_seeded_customer() {
    run_full_mode_probe shared_customer_decoy

    assert_eq "$FULL_MODE_RC" "0" \
        "full mode ignores unrelated shared-plan customers and resolves the canonical seed user"
    assert_contains "$(cat "$FULL_MODE_SQL_LOG")" "email = 'dev@example.com'" \
        "target lookup is pinned to the canonical local seed email"
}

test_full_mode_rejects_header_injection_bytes() {
    local tmp fixture_root out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    fixture_root="$tmp/fixture"
    mkdir -p "$fixture_root/scripts/lib"

    cp \
        "$REPO_ROOT/scripts/lib/local_real_pipeline_run.sh" \
        "$REPO_ROOT/scripts/lib/local_real_pipeline_oracle.sh" \
        "$fixture_root/scripts/lib/"
    write_mock_script "$fixture_root/scripts/lib/env.sh" ':'
    write_mock_script "$fixture_root/scripts/lib/flapjack_regions.sh" ':'
    write_mock_script "$fixture_root/scripts/lib/local_db_access.sh" ':'
    write_mock_script "$fixture_root/scripts/lib/process.sh" ':'
    write_mock_script "$fixture_root/scripts/lib/local_seed_contract.sh" '
LOCAL_SEED_PRIMARY_INDEX_REGION="us-east-1"
LOCAL_SEED_PRIMARY_INDEX_NAME="test-index"'

    out="$tmp/out.txt"
    err="$tmp/err.txt"

    set +e
    env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
        bash -lc '
set -euo pipefail
SCRIPT_DIR="'"$fixture_root"'/scripts"
REPO_ROOT="'"$fixture_root"'"
source "$SCRIPT_DIR/lib/local_real_pipeline_run.sh"
lrp_require_safe_header_value FLAPJACK_ADMIN_KEY $'"'"'fj_local_dev_admin_key\r\nX-Evil: injected'"'"'
' >"$out" 2>"$err"
    rc=$?
    set -e

    assert_eq "$rc" "1" \
        "header-bearing auth values with CR/LF fail closed before any curl call"
    assert_contains "$(cat "$out")" "LOCAL_REAL_PIPELINE_STATUS: FAIL reason=env_prep" \
        "unsafe header bytes surface the existing env_prep failure token"
    assert_contains "$(cat "$err")" "FLAPJACK_ADMIN_KEY contains CR/LF bytes" \
        "stderr explains that CR/LF auth bytes are rejected"
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
    local fixture_oracle
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    if [ ! -e "$fixture_oracle" ] && [ ! -L "$fixture_oracle" ]; then
        pass "negative seeded mode remains oracle-emission-free"
    else
        fail "negative seeded mode remains oracle-emission-free"
    fi
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
    local fixture_oracle
    fixture_oracle="$FULL_MODE_FIXTURE_ROOT/${LRP_ORACLE_FILE#"$REPO_ROOT"/}"
    if [ ! -e "$fixture_oracle" ] && [ ! -L "$fixture_oracle" ]; then
        pass "negative nodrive mode remains oracle-emission-free"
    else
        fail "negative nodrive mode remains oracle-emission-free"
    fi
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
    test_oracle_bridge_accepts_valid_and_propagates_rejections
    test_committed_redacted_oracle_stays_parser_valid
    test_full_mode_success_two_scrape_order_and_pass
    test_full_mode_emits_parser_valid_oracle
    test_oracle_output_path_rejects_symlinks_and_non_regular_files
    test_oracle_publication_inputs_fail_closed
    test_full_mode_teardown_on_post_startup_failure
    test_full_mode_fails_loud_when_evidence_query_fails
    test_full_mode_fails_loud_when_agent_stop_fails
    test_full_mode_escapes_sql_metacharacters_in_customer_id
    test_full_mode_resolves_the_canonical_seeded_customer
    test_full_mode_rejects_header_injection_bytes
    test_negative_seeded_mode_fails_with_seeded_row_and_teardown
    test_negative_nodrive_mode_fails_absent_after_clear_and_teardown

    run_test_summary
}

main "$@"
