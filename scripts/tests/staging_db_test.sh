#!/usr/bin/env bash
# Regression tests for scripts/lib/staging_db.sh.
#
# Focus: ensure staging_db_run_sql treats successful SSM output as success,
# retries nonterminal statuses, and safely quotes shell-sensitive SQL inputs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

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
    mkdir -p "$TEST_TMP_DIR/bin"
    : >"$TEST_TMP_DIR/aws_calls.log"
}

make_mock_aws() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

echo "$*" >> "${TEST_TMP_DIR}/aws_calls.log"

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    printf "cmd-test-123\n"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    printf "{\"status\":\"Success\",\"stdout\":\"42\",\"stderr\":\"\"}\n"
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

make_mock_aws_pending_then_success() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

state_file="${TEST_TMP_DIR}/poll_count"
count=0
if [ -f "$state_file" ]; then
    count="$(cat "$state_file")"
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    printf "cmd-test-123\n"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    count=$((count + 1))
    printf "%s" "$count" > "$state_file"
    if [ "$count" -eq 1 ]; then
        printf "{\"status\":\"InProgress\",\"stdout\":\"\",\"stderr\":\"\"}\n"
    else
        printf "{\"status\":\"Success\",\"stdout\":\"43\",\"stderr\":\"\"}\n"
    fi
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

make_mock_aws_capture_parameters() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    shift 2
    params=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--parameters" ]; then
            params="$2"
            break
        fi
        shift
    done
    params_path="${params#file://}"
    cp "$params_path" "${TEST_TMP_DIR}/captured_parameters.json"
    printf "cmd-test-123\n"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    printf "{\"status\":\"Success\",\"stdout\":\"44\",\"stderr\":\"\"}\n"
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

make_mock_aws_paginated_json_capture() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

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

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    shift 2
    params=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--parameters" ]; then
            params="$2"
            break
        fi
        shift
    done
    params_path="${params#file://}"
    sql="$(extract_sql_from_parameters_file "$params_path")"

    cmd_id="cmd_${RANDOM}_$$"
    stdout_payload="[]"
    if [[ "$sql" == *"LIMIT 3"* && "$sql" == *"OFFSET 0"* ]]; then
        stdout_payload="[{\"id\":\"row-1\"}] --output truncated--"
    elif [[ "$sql" == *"LIMIT 1"* && "$sql" == *"OFFSET 0"* ]]; then
        stdout_payload="[{\"id\":\"row-1\"}]"
    elif [[ "$sql" == *"LIMIT 1"* && "$sql" == *"OFFSET 1"* ]]; then
        stdout_payload="[{\"id\":\"row-2\"}]"
    fi

    printf "%s" "$stdout_payload" > "${TEST_TMP_DIR}/$cmd_id.stdout"
    printf "%s\n" "$cmd_id"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    shift 2
    cmd_id=""
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--command-id" ]; then
            cmd_id="$2"
            break
        fi
        shift
    done
    stdout_payload="$(cat "${TEST_TMP_DIR}/$cmd_id.stdout")"
    /usr/bin/python3 - "$stdout_payload" <<'"'"'PY'"'"'
import json
import sys

print(json.dumps({"status": "Success", "stdout": sys.argv[1], "stderr": ""}))
PY
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

make_mock_aws_cross_env_resolution() {
    write_mock_script "$TEST_TMP_DIR/bin/aws" '
set -euo pipefail

echo "$*" >> "${TEST_TMP_DIR}/aws_calls.log"

if [ "${1:-}" = "ec2" ] && [ "${2:-}" = "describe-instances" ]; then
    if [[ "$*" == *"Values=fjcloud-api-prod"* ]]; then
        printf "i-prod-123\n"
        exit 0
    fi
    if [[ "$*" == *"Values=fjcloud-api-staging"* ]]; then
        printf "i-staging-456\n"
        exit 0
    fi
    echo "unexpected describe-instances filters: $*" >&2
    exit 1
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
    shift 2
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--instance-ids" ]; then
            printf "%s\n" "$2" >> "${TEST_TMP_DIR}/send_instance_ids.log"
            break
        fi
        shift
    done
    printf "cmd-test-123\n"
    exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
    printf "{\"status\":\"Success\",\"stdout\":\"ok\",\"stderr\":\"\"}\n"
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
'
}

test_staging_db_run_sql_parses_success_status_from_ssm_text_output() {
    make_test_tmp_dir
    make_mock_aws

    local output
    output="$(
        TEST_TMP_DIR="$TEST_TMP_DIR" \
        PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SSM_INSTANCE_ID="i-test-123" \
        DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url" \
        AWS_DEFAULT_REGION="us-east-1" \
        bash -c '
            set -euo pipefail
            source "'"$REPO_ROOT"'/scripts/lib/staging_db.sh"
            staging_db_run_sql "postgres://user:pass@db.example.test:5432/fjcloud" "SELECT 42;"
        '
    )"

    assert_eq "$output" "42" "staging_db_run_sql should return stdout when SSM status is Success"
}

test_staging_db_run_sql_retries_nonterminal_ssm_status_until_success() {
    make_test_tmp_dir
    make_mock_aws_pending_then_success

    local output
    output="$(
        TEST_TMP_DIR="$TEST_TMP_DIR" \
        PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SSM_INSTANCE_ID="i-test-123" \
        DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url" \
        AWS_DEFAULT_REGION="us-east-1" \
        bash -c '
            set -euo pipefail
            source "'"$REPO_ROOT"'/scripts/lib/staging_db.sh"
            staging_db_run_sql "postgres://user:pass@db.example.test:5432/fjcloud" "SELECT 43;"
        '
    )"

    assert_eq "$output" "43" "staging_db_run_sql should continue polling while SSM status is nonterminal"
}

test_staging_db_run_sql_shell_escapes_sql_and_password_in_ssm_payload() {
    make_test_tmp_dir
    make_mock_aws_capture_parameters

    local output
    output="$(
        TEST_TMP_DIR="$TEST_TMP_DIR" \
        PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SSM_INSTANCE_ID="i-test-123" \
        DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url" \
        SQL_TEXT='SELECT 44; echo "$USER";' \
        AWS_DEFAULT_REGION="us-east-1" \
        bash -c '
            set -euo pipefail
            source "'"$REPO_ROOT"'/scripts/lib/staging_db.sh"
            staging_db_run_sql "postgres://dbuser:pa\$\$word@db.example.test:5432/fjcloud" "$SQL_TEXT"
        '
    )"

    assert_eq "$output" "44" "staging_db_run_sql should still return stdout with quoted credentials and SQL"
    local params_payload
    params_payload="$(read_file_content "$TEST_TMP_DIR/captured_parameters.json")"
    assert_contains "$params_payload" "PGPASSWORD='pa\$\$word'" "SSM payload safely shell-quotes password containing shell metacharacters"
    assert_contains "$params_payload" "-c 'SELECT 44; echo \\\"\$USER\\\";'" "SSM payload safely shell-quotes SQL argument as one psql -c token"
}

test_staging_db_run_sql_json_array_paginated_recovers_from_truncated_page() {
    make_test_tmp_dir
    make_mock_aws_paginated_json_capture

    local output
    output="$(
        TEST_TMP_DIR="$TEST_TMP_DIR" \
        PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        SSM_INSTANCE_ID="i-test-123" \
        DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url" \
        AWS_DEFAULT_REGION="us-east-1" \
        bash -c '
            set -euo pipefail
            source "'"$REPO_ROOT"'/scripts/lib/staging_db.sh"
            base_sql="SELECT '\''row-1'\''::text AS id UNION ALL SELECT '\''row-2'\''::text AS id ORDER BY id"
            staging_db_run_sql_json_array_paginated "postgres://user:pass@db.example.test:5432/fjcloud" "$base_sql" 3
        '
    )"

    assert_eq "$output" '[{"id":"row-1"},{"id":"row-2"}]' \
        "paginated JSON capture should retry with smaller pages when SSM output is truncated"
}

test_staging_db_run_sql_resolves_env_specific_instances_within_single_shell() {
    make_test_tmp_dir
    make_mock_aws_cross_env_resolution

    TEST_TMP_DIR="$TEST_TMP_DIR" \
    PATH="$TEST_TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    AWS_DEFAULT_REGION="us-east-1" \
    bash -c '
        set -euo pipefail
        source "'"$REPO_ROOT"'/scripts/lib/staging_db.sh"
        db_url="postgres://user:pass@db.example.test:5432/fjcloud"
        DATABASE_URL_SSM_PARAM="/fjcloud/prod/database_url"
        staging_db_run_sql "$db_url" "SELECT 1;" >/dev/null
        DATABASE_URL_SSM_PARAM="/fjcloud/staging/database_url"
        staging_db_run_sql "$db_url" "SELECT 1;" >/dev/null
    '

    local aws_calls
    aws_calls="$(read_file_content "$TEST_TMP_DIR/aws_calls.log")"
    assert_contains "$aws_calls" "Values=fjcloud-api-prod" "prod run resolves prod API instance"
    assert_contains "$aws_calls" "Values=fjcloud-api-staging" "staging run resolves staging API instance"

    local send_instances
    send_instances="$(read_file_content "$TEST_TMP_DIR/send_instance_ids.log")"
    assert_eq "$send_instances" $'i-prod-123\ni-staging-456' "send-command targets prod then staging instances in order"
}

test_staging_db_run_sql_parses_success_status_from_ssm_text_output
test_staging_db_run_sql_retries_nonterminal_ssm_status_until_success
test_staging_db_run_sql_shell_escapes_sql_and_password_in_ssm_payload
test_staging_db_run_sql_json_array_paginated_recovers_from_truncated_page
test_staging_db_run_sql_resolves_env_specific_instances_within_single_shell
run_test_summary
