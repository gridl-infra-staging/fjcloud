#!/usr/bin/env bash
# Contract tests for scripts/probe_organic_alert_dispatch.sh.
#
# The live staging probe is intentionally stateful and not a per-commit gate, so
# these tests lock local-only safety rails: preflight validation, SSM error
# propagation, replay-fixture failure behavior, and static contract constants.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_organic_alert_dispatch.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_TMP_DIR=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
    mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/state" "$TEST_TMP_DIR/evidence"
    : >"$TEST_TMP_DIR/empty.env"
    write_mock_script "$TEST_TMP_DIR/bin/sleep" 'exit 0'
}

make_mock_aws() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

: "${PROBE_AWS_STATE_DIR:?PROBE_AWS_STATE_DIR is required}"
: "${PROBE_AWS_SQL_LOG:?PROBE_AWS_SQL_LOG is required}"

flag_value() {
    local flag="$1"
    shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "$flag" ]; then
            printf "%s" "${2:-}"
            return 0
        fi
        shift
    done
    return 1
}

extract_sql_from_parameters_file() {
    /usr/bin/python3 - "$1" <<'"'"'PY'"'"'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)
commands = payload.get("commands", [])
print(commands[0] if commands else "", end="")
PY
}

extract_first_uuid() {
    /usr/bin/python3 - "$1" <<'"'"'PY'"'"'
import re
import sys

match = re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", sys.argv[1], re.I)
print(match.group(0) if match else "", end="")
PY
}

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
    name="$(flag_value --name "$@")"

    if [ -n "${MOCK_AWS_FAIL_GET_PARAMETER_NAME:-}" ] && [ "$name" = "$MOCK_AWS_FAIL_GET_PARAMETER_NAME" ]; then
        echo "mocked get-parameter failure for $name" >&2
        exit 1
    fi

    case "$name" in
        /fjcloud/staging/database_url)
            printf "postgres://probe_user:probe_pass@db.example.test:5432/fjcloud\n"
            ;;
        /fjcloud/staging/discord_webhook_url)
            printf "https://discord.example.test/api/webhooks/123/abc\n"
            ;;
        /fjcloud/staging/stripe_webhook_secret)
            printf "whsec_probe_fixture_secret\n"
            ;;
        /fjcloud/staging/last_deploy_sha)
            printf "deadbeefcafebabefeedface0123456789abcdef\n"
            ;;
        *)
            echo "unexpected get-parameter name: $name" >&2
            exit 1
            ;;
    esac
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    params_file="$(flag_value --parameters "$@")"
    params_file="${params_file#file://}"
    sql="$(extract_sql_from_parameters_file "$params_file")"
    printf "%s\n---\n" "$sql" >> "$PROBE_AWS_SQL_LOG"

    cmd_id="cmd_${RANDOM}_$$"
    stdout=""
    case "$sql" in
        *"INSERT INTO customers"*)
            stdout="$(extract_first_uuid "$sql")"
            ;;
        *"INSERT INTO invoices"*)
            stdout="$(extract_first_uuid "$sql")"
            ;;
        *"SELECT id::text || '\''|'\'' || delivery_status FROM alerts"*)
            stdout="${MOCK_AWS_ALERT_QUERY_ROW:-}"
            ;;
    esac

    printf "%s" "$stdout" > "$PROBE_AWS_STATE_DIR/$cmd_id.stdout"
    printf "%s\n" "$cmd_id"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    cmd_id="$(flag_value --command-id "$@")"
    printf "Success\n"
    if [ -f "$PROBE_AWS_STATE_DIR/$cmd_id.stdout" ]; then
        cat "$PROBE_AWS_STATE_DIR/$cmd_id.stdout"
    fi
    printf "\n"
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

make_failing_replay_fixture() {
    write_mock_script "$TEST_TMP_DIR/replay_fixture_stub.sh" '
set -euo pipefail
echo "STUB_FIXTURE_FAILED" >&2
exit 1
'
}

run_probe() {
    local -a env_args=(
        "HOME=$TEST_TMP_DIR"
        "TMPDIR=$TEST_TMP_DIR"
        "PATH=$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        "FJCLOUD_SECRET_FILE=$TEST_TMP_DIR/empty.env"
        "ORGANIC_ALERT_EVIDENCE_ROOT=$TEST_TMP_DIR/evidence"
        "AWS_DEFAULT_REGION=us-east-1"
    )
    local stdout_file="$TEST_TMP_DIR/stdout.log"
    local stderr_file="$TEST_TMP_DIR/stderr.log"

    while [ "$#" -gt 0 ]; do
        env_args+=("$1")
        shift
    done

    RUN_EXIT_CODE=0
    env -i "${env_args[@]}" bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_missing_api_url_explicit_empty_exits_one() {
    make_test_tmp_dir
    run_probe "API_URL="

    assert_eq "$RUN_EXIT_CODE" "1" "explicitly empty API_URL should fail closed"
    assert_contains "$RUN_STDOUT" "API_URL was set explicitly but resolved to an empty value" \
        "explicitly empty API_URL should emit stable preflight failure detail"
}

test_wrong_target_url_staging_whitelist_rejection() {
    make_test_tmp_dir
    run_probe "API_URL=https://evil.example.com"

    assert_eq "$RUN_EXIT_CODE" "1" "non-sanctioned API_URL should fail closed"
    assert_contains "$RUN_STDOUT" "API_URL must be the sanctioned staging target" \
        "non-sanctioned API_URL should emit stable staging allowlist failure detail"
    assert_contains "$RUN_STDOUT" "got 'https://evil.example.com'" \
        "non-sanctioned API_URL error should echo rejected URL"
}

test_ssm_shim_failure_propagation() {
    make_test_tmp_dir
    make_mock_aws

    run_probe \
        "PROBE_AWS_STATE_DIR=$TEST_TMP_DIR/state" \
        "PROBE_AWS_SQL_LOG=$TEST_TMP_DIR/sql.log" \
        "SSM_INSTANCE_ID=i-probe-test" \
        "MOCK_AWS_FAIL_GET_PARAMETER_NAME=/fjcloud/staging/database_url"

    assert_eq "$RUN_EXIT_CODE" "1" "DATABASE_URL SSM resolution failure should fail closed"
    assert_contains "$RUN_STDOUT" "Failed to resolve DATABASE_URL from SSM parameter" \
        "DATABASE_URL SSM failure should propagate stable hydrate_database_url error"
}

test_replay_fixture_failure_propagation() {
    make_test_tmp_dir
    make_mock_aws
    make_failing_replay_fixture

    run_probe \
        "PROBE_AWS_STATE_DIR=$TEST_TMP_DIR/state" \
        "PROBE_AWS_SQL_LOG=$TEST_TMP_DIR/sql.log" \
        "SSM_INSTANCE_ID=i-probe-test" \
        "REPLAY_FIXTURE_BIN=$TEST_TMP_DIR/replay_fixture_stub.sh"

    assert_eq "$RUN_EXIT_CODE" "1" "replay fixture non-zero should fail closed"
    assert_contains "$RUN_STDOUT" "Webhook replay fixture exited non-zero" \
        "replay fixture non-zero should propagate stable replay failure detail"

    local sql_history
    sql_history="$(cat "$TEST_TMP_DIR/sql.log" 2>/dev/null || true)"
    assert_contains "$sql_history" "INSERT INTO customers" "probe should seed customer before replay"
    assert_contains "$sql_history" "INSERT INTO invoices" "probe should seed invoice before replay"
    assert_contains "$sql_history" "DELETE FROM alerts WHERE metadata->>'invoice_id'" \
        "probe cleanup should delete invoice-scoped alerts"
    assert_contains "$sql_history" "DELETE FROM invoices" "probe cleanup should delete seeded invoice"
    assert_contains "$sql_history" "DELETE FROM customers" "probe cleanup should delete seeded customer"
}

test_static_contract_assertions() {
    local content
    content="$(cat "$PROBE_SCRIPT")"

    assert_contains "$content" "set -euo pipefail" "probe should keep strict shell mode"
    assert_contains "$content" "trap cleanup EXIT" "probe should keep cleanup EXIT trap"
    assert_contains "$content" "stripe_webhook_secret" \
        "probe should keep stripe_webhook_secret SSM path contract"
    assert_contains "$content" 'SANCTIONED_STAGING_API_URL="https://api.flapjack.foo"' \
        "probe should keep sanctioned staging URL contract"

    local strict_line
    strict_line="$(grep -n "^set -euo pipefail$" "$PROBE_SCRIPT" | cut -d: -f1 | head -n1)"
    assert_eq "$strict_line" "8" "strict mode should remain on line 8"
}

test_missing_api_url_explicit_empty_exits_one
test_wrong_target_url_staging_whitelist_rejection
test_ssm_shim_failure_propagation
test_replay_fixture_failure_propagation
test_static_contract_assertions
run_test_summary
