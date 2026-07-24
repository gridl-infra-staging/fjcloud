#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2030,SC2031
# Hermetic safety-contract tests for validate_vm_autorepair_detection.sh.
#
# Every external seam is replaced with a deterministic fixture. The suite
# proves that destructive AWS calls remain unreachable until the local
# database, explicit allowlist, and customer-tag interlocks have all passed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/validate_vm_autorepair_detection.sh"
LOCAL_CI_SCRIPT="$REPO_ROOT/scripts/local-ci.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

TEST_TMP_DIR=""
RUN_EXIT_CODE=0
RUN_STDOUT=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

write_executable() {
    local path="$1"
    shift
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' "$@"
    } > "$path"
    chmod +x "$path"
}

prepare_fixture() {
    cleanup_test_tmp_dir
    unset FJCLOUD_VM_AUTOREPAIR_SECRET_FILE
    unset TEST_DATABASE_URL
    unset MOCK_INITIAL_INVENTORY_COUNT
    unset MOCK_MISSING_AWS_CONFIG
    unset MOCK_ALLOWLIST_TAMPER
    unset MOCK_CUSTOMER_TAG_COUNT
    unset MOCK_USE_DEFAULT_DATABASE_URL
    unset MOCK_API_START_FAILURE
    TEST_TMP_DIR="$(mktemp -d)"
    mkdir -p "$TEST_TMP_DIR/bin" "$TEST_TMP_DIR/evidence"

    cat > "$TEST_TMP_DIR/env.secret" <<'EOF'
AWS_ACCESS_KEY_ID=fixture-access-key
AWS_SECRET_ACCESS_KEY=fixture-secret-key
AWS_DEFAULT_REGION=us-east-1
ADMIN_KEY=fixture-admin-key
EOF

    write_executable "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail
printf "%s | access_key=%s\n" "$*" "${AWS_ACCESS_KEY_ID:-missing}" >> "$MOCK_AWS_LOG"
command_group="${1:-} ${2:-}"
case "$command_group" in
    "sts get-caller-identity")
        printf "%s\n" "111122223333"
        ;;
    "ssm get-parameter")
        parameter_name=""
        while [ "$#" -gt 0 ]; do
            if [ "$1" = "--name" ]; then
                parameter_name="${2:-}"
                break
            fi
            shift
        done
        case "$parameter_name" in
            */aws_ami_id) value="ami-fixture" ;;
            */aws_subnet_id) value="subnet-fixture" ;;
            */aws_security_group_ids) value="sg-fixture" ;;
            */aws_key_pair_name) value="fixture-keypair" ;;
            */aws_instance_profile_name) value="fixture-profile" ;;
            *) exit 9 ;;
        esac
        if [ "${MOCK_MISSING_AWS_CONFIG:-}" = "AWS_AMI_ID" ] &&
            [ "$parameter_name" = "/fjcloud/staging/aws_ami_id" ]; then
            value="None"
        fi
        printf "%s\n" "$value"
        ;;
    "ec2 run-instances")
        printf "%s\n" "i-stage4-fixture"
        ;;
    "ec2 wait")
        if [ "${3:-}" = "instance-running" ]; then
            allowlist="$(printf "%s\n" "$MOCK_EVIDENCE_ROOT"/*/instance_allowlist.txt)"
            case "${MOCK_ALLOWLIST_TAMPER:-}" in
                missing) rm -f "$allowlist" ;;
                different) printf "%s\n" "i-not-lane-owned" > "$allowlist" ;;
            esac
        fi
        ;;
    "ec2 describe-tags")
        printf "%s\n" "${MOCK_CUSTOMER_TAG_COUNT:-0}"
        ;;
    "ec2 terminate-instances")
        touch "$MOCK_INSTANCE_TERMINATED_FILE"
        printf "%s\n" "terminated"
        ;;
    "ec2 describe-instances")
        if [[ " $* " == *"State.Name"* ]]; then
            if [ -f "$MOCK_INSTANCE_TERMINATED_FILE" ]; then
                printf "%s\n" "terminated"
            else
                printf "%s\n" "running"
            fi
        else
            printf "%s\n" "${MOCK_MANAGED_INSTANCE_IDS:-}"
        fi
        ;;
    *)
        printf "unexpected aws invocation: %s\n" "$*" >&2
        exit 8
        ;;
esac
'

    write_executable "$TEST_TMP_DIR/bin/sqlx" '
set -euo pipefail
printf "%s\n" "$*" >> "$MOCK_SQLX_LOG"
if [ "${1:-}" = "database" ] && [ "${2:-}" = "drop" ]; then
    touch "$MOCK_DATABASE_DROPPED_FILE"
fi
'

    write_executable "$TEST_TMP_DIR/bin/psql" '
set -euo pipefail
printf "%s\n" "$*" >> "$MOCK_PSQL_LOG"
if [[ "$*" == *"INSERT INTO vm_inventory"* ||
      "$*" == *"customer_tenants WHERE vm_id"* ||
      "$*" == *"pg_database WHERE datname"* ]]; then
    printf "%s\n" "psql fixture: variables are not expanded in -c arguments" >&2
    exit 3
fi
stdin_sql="$(cat)"
arguments="$* $stdin_sql"
if [[ "$arguments" == *"INSERT INTO vm_inventory"* ]]; then
    touch "$MOCK_INVENTORY_SEEDED_FILE"
    printf "%s\n" "44444444-4444-4444-4444-444444444444"
elif [[ "$arguments" == *"SELECT count(*) FROM vm_inventory"* ]]; then
    if [ -f "$MOCK_INVENTORY_SEEDED_FILE" ]; then
        printf "%s\n" "1"
    else
        printf "%s\n" "${MOCK_INITIAL_INVENTORY_COUNT:-0}"
    fi
elif [[ "$arguments" == *"customer_tenants"* ]]; then
    printf "%s\n" "0"
elif [[ "$arguments" == *"pg_database"* ]]; then
    if [ -f "$MOCK_DATABASE_DROPPED_FILE" ]; then
        printf "%s\n" "0"
    else
        printf "%s\n" "1"
    fi
else
    printf "%s\n" "0"
fi
'

    write_executable "$TEST_TMP_DIR/bin/curl" '
set -euo pipefail
printf "%s\n" "$*" >> "$MOCK_CURL_LOG"
if [[ " $* " == *"/health"* ]]; then
    [ "${MOCK_API_START_FAILURE:-0}" != "1" ]
    exit
fi
if [[ " $* " == *"/lifecycle-events"* ]]; then
    cat <<JSON
[{"event_type":"detected_dead","detail":{}},{"event_type":"replacement_refused","detail":{"guardrail":"kill_switch_disabled"}}]
JSON
    exit 0
fi
printf "%s\n" "{}"
'

    write_executable "$TEST_TMP_DIR/bin/cargo" '
set -euo pipefail
if [ "${1:-}" = "build" ]; then
    exit 0
fi
printf "%s|%s|%s|%s|%s\n" \
    "${ENVIRONMENT:-}" \
    "${NODE_SECRET_BACKEND:-}" \
    "${FJCLOUD_VM_AUTOREPAIR_ENABLED:-}" \
    "${DATABASE_URL:-}" \
    "${LOCAL_DEV_FLAPJACK_URL-unset}" > "$MOCK_API_ENV_LOG"
printf "%s\n" "{\"fields\":{\"message\":\"VM autorepair liveness observed\",\"liveness\":\"EngineDown\"}}"
if [ "${MOCK_API_START_FAILURE:-0}" = "1" ]; then
    printf "%s\n" "ERROR fixture API startup failed safely" >&2
    exit 17
fi
trap "exit 0" TERM INT
while :; do
    /bin/sleep 1
done
'

    write_executable "$TEST_TMP_DIR/bin/sleep" 'exit 0'
}

run_target() {
    local target_pid elapsed=0

    RUN_EXIT_CODE=0
    RUN_STDOUT=""
    (
        export PATH="$TEST_TMP_DIR/bin:$PATH"
        export FJCLOUD_VM_AUTOREPAIR_TEST_MODE=1
        export FJCLOUD_VM_AUTOREPAIR_SECRET_FILE="${FJCLOUD_VM_AUTOREPAIR_SECRET_FILE:-$TEST_TMP_DIR/env.secret}"
        export FJCLOUD_VM_AUTOREPAIR_EVIDENCE_ROOT="$TEST_TMP_DIR/evidence"
        export FJCLOUD_VM_AUTOREPAIR_API_PORT=18981
        export FJCLOUD_VM_AUTOREPAIR_S3_PORT=18982
        export FJCLOUD_VM_AUTOREPAIR_ENGINE_PORT=18983
        export FJCLOUD_VM_AUTOREPAIR_POLL_SECONDS=0
        export FJCLOUD_VM_AUTOREPAIR_MAX_POLLS=4
        if [ "${MOCK_USE_DEFAULT_DATABASE_URL:-0}" = "1" ]; then
            unset DATABASE_URL
        else
            export DATABASE_URL="${TEST_DATABASE_URL:-postgres://fixture:fixture@127.0.0.1:5432/fjcloud_fixture}"
        fi
        export AWS_ACCESS_KEY_ID="ambient-key-must-be-cleared"
        export AWS_SECRET_ACCESS_KEY="ambient-secret-must-be-cleared"
        export AWS_DEFAULT_REGION="eu-west-1"
        export MOCK_AWS_LOG="$TEST_TMP_DIR/aws.log"
        export MOCK_SQLX_LOG="$TEST_TMP_DIR/sqlx.log"
        export MOCK_PSQL_LOG="$TEST_TMP_DIR/psql.log"
        export MOCK_CURL_LOG="$TEST_TMP_DIR/curl.log"
        export MOCK_API_ENV_LOG="$TEST_TMP_DIR/api_env.log"
        export MOCK_INSTANCE_TERMINATED_FILE="$TEST_TMP_DIR/instance_terminated"
        export MOCK_DATABASE_DROPPED_FILE="$TEST_TMP_DIR/database_dropped"
        export MOCK_INVENTORY_SEEDED_FILE="$TEST_TMP_DIR/inventory_seeded"
        export MOCK_EVIDENCE_ROOT="$TEST_TMP_DIR/evidence"
        bash "$TARGET_SCRIPT"
    ) > "$TEST_TMP_DIR/run.out" 2>&1 &
    target_pid=$!

    while kill -0 "$target_pid" 2>/dev/null && [ "$elapsed" -lt 200 ]; do
        /bin/sleep 0.05
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$target_pid" 2>/dev/null; then
        kill "$target_pid" 2>/dev/null || true
        wait "$target_pid" 2>/dev/null || true
        RUN_EXIT_CODE=124
    else
        wait "$target_pid" || RUN_EXIT_CODE=$?
    fi
    RUN_STDOUT="$(cat "$TEST_TMP_DIR/run.out")"
}

assert_failed_before_termination() {
    local message="$1"
    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "$message"
    else
        fail "$message (target unexpectedly succeeded)"
    fi
    if [ ! -f "$TEST_TMP_DIR/aws.log" ] ||
        ! grep -q "ec2 terminate-instances" "$TEST_TMP_DIR/aws.log"; then
        pass "$message leaves destructive AWS termination unreachable"
    else
        fail "$message reached ec2 terminate-instances"
    fi
}

test_static_owner_contract() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "proof script should exist"
        return
    fi

    local script_content local_ci_content
    script_content="$(cat "$TARGET_SCRIPT")"
    local_ci_content="$(cat "$LOCAL_CI_SCRIPT")"

    assert_contains "$script_content" 'source "$SCRIPT_DIR/lib/env.sh"' \
        "proof script should source the environment owner"
    assert_contains "$script_content" 'source "$SCRIPT_DIR/lib/http_json.sh"' \
        "proof script should source the admin HTTP owner"
    assert_contains "$script_content" 'source "$SCRIPT_DIR/lib/health.sh"' \
        "proof script should source the health polling owner"
    assert_contains "$script_content" "admin_call" \
        "proof script should use admin_call for lifecycle events"
    assert_contains "$script_content" "/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret" \
        "proof script should pin the authorized AWS secret source"
    assert_contains "$script_content" "cleanup()" \
        "proof script should define re-entrant cleanup"
    assert_contains "$script_content" "CLEANUP_STARTED" \
        "cleanup should contain an executable re-entry guard"
    assert_not_contains "$script_content" "pkill" \
        "proof script should never broadly kill shared processes"
    assert_not_contains "$script_content" "killall" \
        "proof script should never broadly kill shared processes"
    assert_contains "$local_ci_content" "scripts/tests/validate_vm_autorepair_detection_test.sh" \
        "fast local CI should own the proof-script contract"

    if bash -n "$TARGET_SCRIPT"; then
        pass "proof script should pass bash syntax validation"
    else
        fail "proof script should pass bash syntax validation"
    fi
}

test_missing_secret_fails_closed() {
    prepare_fixture
    export FJCLOUD_VM_AUTOREPAIR_SECRET_FILE="$TEST_TMP_DIR/missing.secret"
    run_target
    assert_failed_before_termination "missing secret should fail closed"
}

test_non_loopback_database_fails_closed() {
    prepare_fixture
    export TEST_DATABASE_URL="postgres://fixture:fixture@db.internal:5432/fjcloud_fixture"
    run_target
    assert_failed_before_termination "non-loopback DATABASE_URL should fail closed"
    unset TEST_DATABASE_URL
}

test_nonempty_inventory_fails_closed() {
    prepare_fixture
    export MOCK_INITIAL_INVENTORY_COUNT=1
    run_target
    assert_failed_before_termination "non-empty initial vm_inventory should fail closed"
    unset MOCK_INITIAL_INVENTORY_COUNT
}

test_missing_required_aws_config_fails_closed() {
    prepare_fixture
    export MOCK_MISSING_AWS_CONFIG=AWS_AMI_ID
    run_target
    assert_failed_before_termination "missing required AWS config should fail closed"
    unset MOCK_MISSING_AWS_CONFIG
}

test_missing_allowlist_fails_closed() {
    prepare_fixture
    export MOCK_ALLOWLIST_TAMPER=missing
    run_target
    assert_failed_before_termination "missing allowlist should fail closed"
    unset MOCK_ALLOWLIST_TAMPER
}

test_target_not_allowlisted_fails_closed() {
    prepare_fixture
    export MOCK_ALLOWLIST_TAMPER=different
    run_target
    assert_failed_before_termination "non-allowlisted target should fail closed"
    unset MOCK_ALLOWLIST_TAMPER
}

test_customer_tag_fails_closed() {
    prepare_fixture
    export MOCK_CUSTOMER_TAG_COUNT=1
    run_target
    assert_failed_before_termination "customer_id tag should fail closed"
    unset MOCK_CUSTOMER_TAG_COUNT
}

test_success_path_uses_owned_resources_and_cleans_up() {
    prepare_fixture
    run_target

    assert_eq "$RUN_EXIT_CODE" "0" "fully guarded fixture should complete"
    assert_contains "$(cat "$TEST_TMP_DIR/aws.log")" \
        "ec2 terminate-instances" "success path should terminate the allowlisted instance"
    assert_contains "$(cat "$TEST_TMP_DIR/aws.log")" \
        "access_key=fixture-access-key" "secret file credentials should replace ambient AWS exports"
    assert_not_contains "$(cat "$TEST_TMP_DIR/aws.log")" \
        "access_key=ambient-key-must-be-cleared" "ambient AWS credentials should not reach AWS CLI"
    assert_contains "$(cat "$TEST_TMP_DIR/api_env.log")" \
        "local|memory|false|" "local API should start with autonomous repair disabled"
    assert_contains "$(cat "$TEST_TMP_DIR/api_env.log")" \
        "|unset" "LOCAL_DEV_FLAPJACK_URL should be absent from the API process"
    assert_contains "$(cat "$TEST_TMP_DIR/sqlx.log")" \
        "database drop" "cleanup should drop the temporary database"
    assert_contains "$RUN_STDOUT" \
        "VM autorepair disabled-detection proof passed" "success should report the durable proof verdict"
}

test_default_database_url_is_isolated_loopback() {
    prepare_fixture
    export MOCK_USE_DEFAULT_DATABASE_URL=1
    run_target

    assert_eq "$RUN_EXIT_CODE" "0" \
        "exact command should default to the isolated loopback database server"
    assert_contains "$(cat "$TEST_TMP_DIR/api_env.log")" \
        "127.0.0.1" "default database URL should remain loopback"
}

test_api_start_failure_preserves_sanitized_diagnostic() {
    prepare_fixture
    export MOCK_API_START_FAILURE=1
    run_target

    local failure_log
    failure_log="$(printf '%s\n' "$TEST_TMP_DIR"/evidence/*/api_startup_failure.log)"
    assert_ne "$RUN_EXIT_CODE" "0" "API startup failure should fail the proof"
    if [ -f "$failure_log" ]; then
        pass "API startup failure should preserve a diagnostic"
        assert_contains "$(cat "$failure_log")" \
            "fixture API startup failed safely" "startup diagnostic should retain the cause"
        assert_not_contains "$(cat "$failure_log")" \
            "fixture-secret-key" "startup diagnostic should redact fixture credentials"
    else
        fail "API startup failure should preserve a diagnostic"
    fi
}

test_static_owner_contract
test_missing_secret_fails_closed
test_non_loopback_database_fails_closed
test_nonempty_inventory_fails_closed
test_missing_required_aws_config_fails_closed
test_missing_allowlist_fails_closed
test_target_not_allowlisted_fails_closed
test_customer_tag_fails_closed
test_success_path_uses_owned_resources_and_cleans_up
test_default_database_url_is_isolated_loopback
test_api_start_failure_preserves_sanitized_diagnostic
run_test_summary
