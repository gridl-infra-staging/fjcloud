#!/usr/bin/env bash
# Hermetic known-answer tests for scripts/probe_usage_rollup_freshness.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

PROBE="$REPO_ROOT/scripts/probe_usage_rollup_freshness.sh"
METERING_CHECKS="$REPO_ROOT/scripts/lib/metering_checks.sh"
TMP_PATHS=()
KNOWN_ANSWER_CASES=0
LEAK_GUARD_REGEX='(/tmp/|/private/|/User''s/|postgres(ql)?://|sk_''live|whsec''_|eyJ|stage2_secret)'

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    TMP_PATHS+=("$1")
}

write_evidence() {
    local path="$1" scenario="$2"
    case "$scenario" in
        fresh)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":7,"fresh_rows":3,"latest_aggregated_at":"2026-07-23T12:34:56Z"}' > "$path"
            ;;
        empty)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":0,"fresh_rows":0,"latest_aggregated_at":null}' > "$path"
            ;;
        stale)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":4,"fresh_rows":0,"latest_aggregated_at":"2026-07-20T12:34:56+00:00"}' > "$path"
            ;;
        query_failed)
            printf '%s\n' '{"schema_version":1,"query_outcome":"failed"}' > "$path"
            ;;
        empty_document)
            : > "$path"
            ;;
        invalid_json)
            printf '%s\n' '{not-json' > "$path"
            ;;
        duplicate_keys)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":0,"total_rows":1,"fresh_rows":0,"latest_aggregated_at":null}' > "$path"
            ;;
        unsupported_schema)
            printf '%s\n' \
                '{"schema_version":2,"query_outcome":"ok","total_rows":0,"fresh_rows":0,"latest_aggregated_at":null}' > "$path"
            ;;
        missing_field)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":1,"latest_aggregated_at":"2026-07-23T12:34:56Z"}' > "$path"
            ;;
        fresh_exceeds_total)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":1,"fresh_rows":2,"latest_aggregated_at":"2026-07-23T12:34:56Z"}' > "$path"
            ;;
        zero_with_timestamp)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":0,"fresh_rows":0,"latest_aggregated_at":"2026-07-23T12:34:56Z"}' > "$path"
            ;;
        rows_without_timestamp)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":1,"fresh_rows":0,"latest_aggregated_at":null}' > "$path"
            ;;
        non_utc_timestamp)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":1,"fresh_rows":0,"latest_aggregated_at":"2026-07-23T12:34:56-04:00"}' > "$path"
            ;;
        wrong_types)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":true,"fresh_rows":"0","latest_aggregated_at":null}' > "$path"
            ;;
        failed_with_database_output)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"failed","total_rows":0,"fresh_rows":0,"latest_aggregated_at":null}' > "$path"
            ;;
        extra_field)
            printf '%s\n' \
                '{"schema_version":1,"query_outcome":"ok","total_rows":0,"fresh_rows":0,"latest_aggregated_at":null,"detail":"guess"}' > "$path"
            ;;
        extra_output)
            printf '%s\n%s\n' \
                '{"schema_version":1,"query_outcome":"failed"}' \
                '{"schema_version":1,"query_outcome":"failed"}' > "$path"
            ;;
        *)
            return 1
            ;;
    esac
}

run_probe_path() {
    local probe_path="$1" evidence="$2" out_path="$3" err_path="$4" rc_path="$5"
    set +e
    bash "$probe_path" --evidence "$evidence" >"$out_path" 2>"$err_path"
    printf '%s\n' "$?" > "$rc_path"
    set -e
}

assert_probe_result() {
    local scenario="$1" expected_rc="$2" expected_line="$3"
    local tmp evidence out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    evidence="$tmp/evidence.json"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    write_evidence "$evidence" "$scenario"
    run_probe_path "$PROBE" "$evidence" "$out" "$err" "$rc"
    KNOWN_ANSWER_CASES=$((KNOWN_ANSWER_CASES + 1))

    assert_eq "$(cat "$rc")" "$expected_rc" "$scenario exits with the expected status"
    assert_eq "$(cat "$out")" "$expected_line" "$scenario emits the exact freshness token"
    assert_eq \
        "$(grep -Ec '^USAGE_ROLLUP_FRESHNESS_STATUS: (OK|ACTION_REQUIRED|PROBE_ERROR) reason=[a-z0-9_]+$' "$out" || true)" \
        "1" \
        "$scenario emits exactly one complete freshness token"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "$scenario stdout omits paths and secret-like material"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "$scenario stderr omits paths and secret-like material"
}

test_known_answer_contract() {
    assert_probe_result fresh 0 \
        "USAGE_ROLLUP_FRESHNESS_STATUS: OK reason=fresh_rollups_present"
    assert_probe_result empty 1 \
        "USAGE_ROLLUP_FRESHNESS_STATUS: ACTION_REQUIRED reason=no_rollups"
    assert_probe_result stale 1 \
        "USAGE_ROLLUP_FRESHNESS_STATUS: ACTION_REQUIRED reason=rollups_stale"
    assert_probe_result query_failed 1 \
        "USAGE_ROLLUP_FRESHNESS_STATUS: PROBE_ERROR reason=query_failed"

    local malformed_case
    for malformed_case in \
        empty_document \
        invalid_json \
        duplicate_keys \
        unsupported_schema \
        missing_field \
        fresh_exceeds_total \
        zero_with_timestamp \
        rows_without_timestamp \
        non_utc_timestamp \
        wrong_types \
        failed_with_database_output \
        extra_field \
        extra_output; do
        assert_probe_result "$malformed_case" 1 \
            "USAGE_ROLLUP_FRESHNESS_STATUS: PROBE_ERROR reason=malformed_evidence"
    done
}

test_cli_failure_contract() {
    local tmp out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    out="$tmp/out.txt"
    err="$tmp/err.txt"

    set +e
    bash "$PROBE" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "missing --evidence is a CLI failure"
    assert_eq "$(cat "$out")" "" "CLI failure emits no classification token"
    assert_contains "$(cat "$err")" "usage:" "CLI failure emits a sanitized usage diagnostic"

    set +e
    bash "$PROBE" --evidence "$tmp/missing.json" >"$out" 2>"$err"
    rc=$?
    set -e
    assert_eq "$rc" "2" "unreadable evidence is a CLI failure"
    assert_eq "$(cat "$out")" "" "unreadable evidence emits no classification token"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "unreadable evidence diagnostic omits the supplied host path"
}

test_metering_sql_has_one_freshness_owner() {
    local predicate current_sql evidence_sql
    # shellcheck disable=SC1090
    source "$METERING_CHECKS"
    predicate="$(metering_rollup_freshness_predicate_sql)"
    current_sql="$(metering_rollup_current_sql)"
    evidence_sql="$(metering_rollup_freshness_evidence_sql)"

    assert_eq "$predicate" "aggregated_at >= NOW() - INTERVAL '48 hours'" \
        "the existing 48-hour predicate has one reusable owner"
    assert_eq "$current_sql" "SELECT COUNT(*) FROM usage_daily WHERE $predicate" \
        "the public rollup-current SQL preserves its exact behavior"
    assert_eq "$(grep -Fo "$predicate" <<<"$evidence_sql" | wc -l | tr -d ' ')" "1" \
        "the evidence SQL reuses the canonical predicate exactly once"
    assert_contains "$evidence_sql" "'schema_version', 1" \
        "the evidence SQL emits schema version 1"
    assert_contains "$evidence_sql" "'query_outcome', 'ok'" \
        "the evidence SQL records successful query provenance"
    assert_contains "$evidence_sql" "'total_rows', COUNT(*)" \
        "the evidence SQL computes total rows"
    assert_contains "$evidence_sql" "'fresh_rows', COUNT(*) FILTER" \
        "the evidence SQL computes fresh rows in the database"
    assert_contains "$evidence_sql" "'latest_aggregated_at', to_char(MAX(aggregated_at) AT TIME ZONE 'UTC'," \
        "the evidence SQL normalizes the latest rollup timestamp to UTC before serialization"
    assert_contains "$evidence_sql" "YYYY-MM-DD\"T\"HH24:MI:SS.US\"Z\"" \
        "the evidence SQL emits a classifier-compatible UTC timestamp string"
    assert_not_contains "$evidence_sql" "'latest_aggregated_at', MAX(aggregated_at)" \
        "the evidence SQL does not serialize session-local timestamps"
    assert_contains "$evidence_sql" "COPY (" \
        "the evidence SQL uses COPY for header-free machine-readable output"
    assert_contains "$evidence_sql" ") TO STDOUT;" \
        "the evidence SQL emits exactly the selected JSON record"
}

test_standalone_owner_has_no_live_side_effects() {
    local tmp stub_dir log evidence out err rc command_name before after
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    stub_dir="$tmp/bin"
    mkdir -p "$stub_dir"
    log="$tmp/live_calls.log"
    : > "$log"
    for command_name in aws curl psql ssh ssm_exec_staging.sh; do
        write_mock_script "$stub_dir/$command_name" \
            "printf '%s\\n' '$command_name called' >> '$log'; exit 99"
    done
    evidence="$tmp/evidence.json"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    write_evidence "$evidence" fresh
    : > "$out"
    : > "$err"
    : > "$rc"
    before="$(ls -1A "$tmp" | sort)"

    SENTINEL_SECRET="stage2_secret_should_not_leak" \
        DATABASE_URL="postgresql://secret-user:secret-password@private-db/fjcloud" \
        PATH="$stub_dir:$PATH" \
        run_probe_path "$PROBE" "$evidence" "$out" "$err" "$rc"
    after="$(ls -1A "$tmp" | sort)"

    assert_eq "$(cat "$rc")" "0" "standalone classifier stays green with live-command stubs first on PATH"
    assert_eq "$(cat "$log")" "" "standalone classifier invokes no live collector"
    assert_eq "$after" "$before" "standalone classifier creates no snapshot or manifest artifact"
    assert_file_not_matching_regex "$out" "$LEAK_GUARD_REGEX" \
        "side-effect guard stdout omits sentinel secrets and paths"
    assert_file_not_matching_regex "$err" "$LEAK_GUARD_REGEX" \
        "side-effect guard stderr omits sentinel secrets and paths"

    if grep -Eq '(scripts/|/)(probe_live_state\.sh|staging_db\.sh|ssm_exec_staging\.sh)' "$PROBE"; then
        fail "standalone classifier has no slash-qualified live collector reference"
    else
        pass "standalone classifier has no slash-qualified live collector reference"
    fi
}

test_zero_row_mutation_is_rejected() {
    local tmp mutant evidence out err rc
    tmp="$(mktemp -d)"; register_tmp_path "$tmp"
    mutant="$tmp/probe_mutant.sh"
    evidence="$tmp/evidence.json"
    out="$tmp/out.txt"
    err="$tmp/err.txt"
    rc="$tmp/rc.txt"
    cp "$PROBE" "$mutant"
    sed -i.bak \
        's/("ACTION_REQUIRED", "no_rollups", 1)/("OK", "no_rollups", 0)/' \
        "$mutant"
    rm -f "$mutant.bak"
    write_evidence "$evidence" empty
    run_probe_path "$mutant" "$evidence" "$out" "$err" "$rc"

    assert_contains "$(cat "$out")" "USAGE_ROLLUP_FRESHNESS_STATUS: OK reason=no_rollups" \
        "the isolated mutation changes the zero-row disposition"
    if [ "$(cat "$rc")" = "1" ] \
        && [ "$(cat "$out")" = "USAGE_ROLLUP_FRESHNESS_STATUS: ACTION_REQUIRED reason=no_rollups" ]; then
        fail "the known-answer contract incorrectly accepts the zero-row OK mutant"
    else
        pass "the known-answer contract rejects the zero-row OK mutant"
    fi
}

test_local_ci_registration_is_complete() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"
    local gate_name="usage-rollup-freshness-contract"
    local gate_body

    assert_eq \
        "$(grep -Fxc '#                    usage-rollup-freshness-contract,' "$local_ci" || true)" \
        "1" \
        "local-ci usage help names the usage-rollup gate exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_usage_rollup_freshness_contract() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines the usage-rollup gate function exactly once"
    assert_eq \
        "$(grep -Fxc 'schedule usage-rollup-freshness-contract' "$local_ci" || true)" \
        "1" \
        "local-ci scheduler names the usage-rollup gate exactly once"
    assert_eq \
        "$(grep -Fxc '            usage-rollup-freshness-contract) run_gate usage-rollup-freshness-contract gate_usage_rollup_freshness_contract ;;' "$local_ci" || true)" \
        "1" \
        "local-ci dispatches the usage-rollup gate exactly once"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci summary-only inventory names the usage-rollup gate exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc "$gate_name" || true)" \
        "1" \
        "local-ci unknown-gate help names the usage-rollup gate exactly once"
    assert_eq "$(grep -Fo "$gate_name" "$local_ci" | wc -l | tr -d ' ')" "6" \
        "local-ci has exactly the six intended usage-rollup gate registrations"

    gate_body="$(sed -n '/^gate_usage_rollup_freshness_contract()/,/^}/p' "$local_ci")"
    assert_contains "$gate_body" 'scripts/tests/probe_usage_rollup_freshness_test.sh' \
        "usage-rollup gate runs the standalone classifier contract"
    assert_contains "$gate_body" 'scripts/test_probe_live_state.sh' \
        "usage-rollup gate runs the integrated live-state contract"
}

test_known_answer_contract
test_cli_failure_contract
test_metering_sql_has_one_freshness_owner
test_standalone_owner_has_no_live_side_effects
test_zero_row_mutation_is_rejected
test_local_ci_registration_is_complete

if [ "$KNOWN_ANSWER_CASES" -gt 0 ]; then
    pass "known-answer denominator is nonzero ($KNOWN_ANSWER_CASES cases)"
else
    fail "known-answer denominator must be nonzero"
fi

run_test_summary
