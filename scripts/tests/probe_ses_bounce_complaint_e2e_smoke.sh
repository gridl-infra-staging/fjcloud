#!/usr/bin/env bash
# Smoke tests for scripts/probe_ses_bounce_complaint_e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_ses_bounce_complaint_e2e.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

json_get_top_field() {
    local json="$1" field="$2"
    python3 - "$json" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

json_get_step_field() {
    local json="$1" step_name="$2" field="$3"
    python3 - "$json" "$step_name" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

mock_psql_body() {
    cat <<'MOCK'
set -euo pipefail
: "${PROBE_TEST_PSQL_LOG:?missing PROBE_TEST_PSQL_LOG}"
printf '%s\n' "$*" >> "$PROBE_TEST_PSQL_LOG"

query="${*: -1}"
mode="${PROBE_TEST_PSQL_MODE:-success}"

if [[ "$query" == *"INSERT INTO customers"* ]]; then
    echo "11111111-1111-1111-1111-111111111111"
    exit 0
fi

if [[ "$query" == *"DELETE FROM email_log"* || "$query" == *"DELETE FROM email_suppression"* || "$query" == *"DELETE FROM audit_log"* ]]; then
    echo "DELETE 1"
    exit 0
fi

if [[ "$query" == *"UPDATE customers"* && "$query" == *"status = 'deleted'"* ]]; then
    echo "1"
    exit 0
fi

if [[ "$query" == *"FROM email_suppression"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        exit 0
    fi
    if [[ "$query" == *"suppression_reason"* ]]; then
        if [[ "${PROBE_TEST_MODE:-bounce}" == "bounce" ]]; then
            echo "bounce_permanent_general"
        else
            echo "complaint"
        fi
    elif [[ "$query" == *"source"* ]]; then
        echo "ses_sns_webhook"
    fi
    exit 0
fi

if [[ "$query" == *"COUNT(*)::BIGINT FROM audit_log"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        echo "0"
    else
        echo "1"
    fi
    exit 0
fi

if [[ "$query" == *"FROM email_log"* && "$query" == *"delivery_status = 'suppressed'"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        echo "0"
    else
        echo "1"
    fi
    exit 0
fi

if [[ "$mode" == "db_fail" ]]; then
    echo "simulated psql failure" >&2
    exit 1
fi

echo ""
MOCK
}

mock_customer_broadcast_body() {
    cat <<'MOCK'
set -euo pipefail
: "${PROBE_TEST_BROADCAST_LOG:?missing PROBE_TEST_BROADCAST_LOG}"
printf '%s\n' "$*" >> "$PROBE_TEST_BROADCAST_LOG"

subject=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --subject)
            subject="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ "${PROBE_TEST_BROADCAST_MODE:-success}" == "bad_json" ]]; then
    echo "not-json"
    exit 0
fi

if [[ "$subject" == *"-second"* ]]; then
    echo '{"mode":"live_send","suppressed_count":1,"attempted_count":2,"success_count":1,"failure_count":0}'
else
    echo '{"mode":"live_send","suppressed_count":0,"attempted_count":2,"success_count":2,"failure_count":0}'
fi
MOCK
}

setup_mock_env() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/psql" "$(mock_psql_body)"
    write_mock_script "$tmp_dir/mock_customer_broadcast.sh" "$(mock_customer_broadcast_body)"
}

make_env_file() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL=postgres://user:pass@localhost:5432/fjcloud
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF_ENV
}

run_probe() {
    local tmp_dir="$1"
    local mode="$2"
    local env_file="$3"
    shift 3

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        PROBE_TEST_PSQL_LOG="$tmp_dir/psql.log" \
        PROBE_TEST_BROADCAST_LOG="$tmp_dir/broadcast.log" \
        CUSTOMER_BROADCAST_SCRIPT="$tmp_dir/mock_customer_broadcast.sh" \
        SES_PROBE_POLL_MAX_ATTEMPTS=2 \
        SES_PROBE_POLL_SLEEP_SEC=1 \
        "$@" \
        bash "$PROBE_SCRIPT" "$mode" "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_probe_script_exists() {
    if [ -f "$PROBE_SCRIPT" ]; then
        pass "probe script should exist"
    else
        fail "probe script should exist at $PROBE_SCRIPT"
    fi
}

test_missing_mode_and_env_file_fails_with_usage_json() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"
    RUN_EXIT_CODE=0
    env -i HOME="$tmp_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing args should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing args should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing args JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "Usage" "missing args detail should include usage guidance"
}

test_invalid_mode_fails_before_external_calls() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "hard-bounce" "$env_file" "PROBE_TEST_MODE=bounce"

    local psql_calls="0"
    if [ -f "$tmp_dir/psql.log" ]; then
        psql_calls="$(wc -l < "$tmp_dir/psql.log" | tr -d "[:space:]")"
    fi

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "invalid mode should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "invalid mode should emit machine-readable JSON"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "Invalid mode" "invalid mode detail should be explicit"
    assert_eq "$psql_calls" "0" "invalid mode should not execute DB calls"
}

test_missing_required_env_fails_preflight() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    cat > "$env_file" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL=postgres://user:pass@localhost:5432/fjcloud
SES_REGION=us-east-1
EOF_ENV
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing SES_FROM_ADDRESS should fail preflight"
    assert_valid_json "$RUN_STDOUT" "preflight failure should emit machine-readable JSON"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "SES_FROM_ADDRESS" "missing env detail should name SES_FROM_ADDRESS"
}

test_poll_timeout_emits_machine_readable_failure() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce" "PROBE_TEST_PSQL_MODE=timeout"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "poll timeout should fail with runtime exit code"
    assert_valid_json "$RUN_STDOUT" "poll timeout should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "passed")" "false" "poll_sns_side_effects should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "detail")" "Timed out" "poll timeout detail should be explicit"
    assert_contains "$psql_log" "UPDATE customers" "poll timeout should still soft-delete seeded probe customer"
    assert_contains "$psql_log" "status = 'deleted'" "poll timeout cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "poll timeout cleanup should target only the seeded probe customer id"
}

test_first_response_contract_failure_still_cleans_probe_customer() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "complaint" "$env_file" "PROBE_TEST_MODE=complaint" "PROBE_TEST_BROADCAST_MODE=bad_json"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "first response contract failure should exit with runtime code"
    assert_valid_json "$RUN_STDOUT" "response contract failure should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "first_live_send" "passed")" "false" "first_live_send should report passed=false on contract failure"
    assert_contains "$psql_log" "UPDATE customers" "response contract failure should still soft-delete seeded probe customer"
    assert_contains "$psql_log" "status = 'deleted'" "response contract cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "response contract cleanup should target only the seeded probe customer id"
}

test_successful_probe_runs_two_broadcasts_and_emits_passing_json() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "complaint" "$env_file" "PROBE_TEST_MODE=complaint"

    local broadcast_calls
    broadcast_calls="$(wc -l < "$tmp_dir/broadcast.log" | tr -d "[:space:]")"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "successful probe should exit 0"
    assert_valid_json "$RUN_STDOUT" "successful probe should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "true" "successful probe JSON should report passed=true"
    assert_eq "$broadcast_calls" "2" "successful probe should execute two broadcast calls"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "first_live_send" "passed")" "true" "first_live_send step should pass"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "second_live_send" "passed")" "true" "second_live_send step should pass"
    assert_contains "$psql_log" "UPDATE customers" "successful probe should soft-delete probe customer after assertions"
    assert_contains "$psql_log" "status = 'deleted'" "cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "cleanup should target only the seeded probe customer id"
}

main() {
    echo "=== probe_ses_bounce_complaint_e2e smoke tests ==="

    test_probe_script_exists
    test_missing_mode_and_env_file_fails_with_usage_json
    test_invalid_mode_fails_before_external_calls
    test_missing_required_env_fails_preflight
    test_poll_timeout_emits_machine_readable_failure
    test_first_response_contract_failure_still_cleans_probe_customer
    test_successful_probe_runs_two_broadcasts_and_emits_passing_json

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
