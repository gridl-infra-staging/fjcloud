#!/usr/bin/env bash
# Contract tests for Stage 2 email/SES probes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_helpers.sh"

run_command_capture() {
    local stdout_file stderr_file
    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    if "$@" >"$stdout_file" 2>"$stderr_file"; then
        RUN_EXIT_CODE=0
    else
        RUN_EXIT_CODE=$?
    fi
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    rm -f "$stdout_file" "$stderr_file"
}

run_verify_probe_with_mocks() {
    local verify_script="$1"
    local tmp_dir env_file state_file sql_count_file stdout_file stderr_file

    tmp_dir="$(mktemp -d)"
    env_file="$tmp_dir/probe.env"
    state_file="$tmp_dir/mock_state_nonce.txt"
    sql_count_file="$tmp_dir/mock_sql_count.txt"
    stdout_file="$tmp_dir/stdout.log"
    stderr_file="$tmp_dir/stderr.log"

    cat > "$env_file" <<'EOF_ENV'
API_URL=https://api.staging.flapjack.foo
APP_BASE_URL=https://app.staging.flapjack.foo
DATABASE_URL=postgres://ignored:ignored@localhost:5432/fjcloud
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/
INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS=2
INBOUND_ROUNDTRIP_POLL_SLEEP_SEC=0
VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS=3
VERIFY_EMAIL_DB_POLL_SLEEP_SEC=0
EOF_ENV

    cat > "$tmp_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_file="${PROBE_VERIFY_MOCK_STATE_FILE:?missing PROBE_VERIFY_MOCK_STATE_FILE}"
last_arg="${@: -1}"

if [[ "$*" == *"-X POST"* && "$last_arg" == *"/auth/register" ]]; then
    payload=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -d)
                payload="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    nonce="$(
        python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
email = payload.get("email", "")
print(email.split("@", 1)[0])
PY
    )"
    printf '%s\n' "$nonce" > "$state_file"
    printf '{"customer_id":"customer-stage2-verify-probe"}\n201\n'
    exit 0
fi

if [[ "$*" == *"-o /dev/null"* && "$*" == *"%{http_code}"* ]]; then
    printf '200'
    exit 0
fi

echo "unexpected curl invocation: $*" >&2
exit 64
MOCK
    chmod +x "$tmp_dir/curl"

    cat > "$tmp_dir/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_file="${PROBE_VERIFY_MOCK_STATE_FILE:?missing PROBE_VERIFY_MOCK_STATE_FILE}"
nonce="$(cat "$state_file" 2>/dev/null || true)"
if [[ -z "$nonce" ]]; then
    nonce="verifyprobe-mock-nonce"
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml","LastModified":"2026-05-28T03:00:00Z"}]}
JSON
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "get-object" ]]; then
    output_path="${@: -1}"
    cat > "$output_path" <<RFC822
From: system@flapjack.foo
To: ${nonce}@test.flapjack.foo
Subject: Verify email

Click to verify: https://app.staging.flapjack.foo/verify-email/token-stage2-contract
probe nonce: ${nonce}
RFC822
    cat <<'JSON'
{"ETag":"mock"}
JSON
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 65
MOCK
    chmod +x "$tmp_dir/aws"

    cat > "$tmp_dir/mock_ssm_exec.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count_file="${PROBE_VERIFY_SQL_COUNT_FILE:?missing PROBE_VERIFY_SQL_COUNT_FILE}"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

if [[ "$count" -lt 2 ]]; then
    printf 'false\n'
else
    printf 'true\n'
fi
MOCK
    chmod +x "$tmp_dir/mock_ssm_exec.sh"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        PROBE_VERIFY_MOCK_STATE_FILE="$state_file" \
        PROBE_VERIFY_SQL_COUNT_FILE="$sql_count_file" \
        PROBE_SSM_EXEC_STAGING_SCRIPT="$tmp_dir/mock_ssm_exec.sh" \
        bash "$verify_script" --env-file "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_SQL_QUERY_CALLS="$(cat "$sql_count_file" 2>/dev/null || echo 0)"

    rm -rf "$tmp_dir"
}

run_reset_probe_with_mocks() {
    local reset_script="$1"
    local tmp_dir env_file state_file sql_count_file stdout_file stderr_file

    tmp_dir="$(mktemp -d)"
    env_file="$tmp_dir/probe.env"
    state_file="$tmp_dir/mock_state_nonce.txt"
    sql_count_file="$tmp_dir/mock_sql_count.txt"
    stdout_file="$tmp_dir/stdout.log"
    stderr_file="$tmp_dir/stderr.log"

    cat > "$env_file" <<'EOF_ENV'
API_URL=https://api.staging.flapjack.foo
DATABASE_URL=postgres://ignored:ignored@localhost:5432/fjcloud
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/
INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS=2
INBOUND_ROUNDTRIP_POLL_SLEEP_SEC=0
RESET_TOKEN_POLL_MAX_ATTEMPTS=3
RESET_TOKEN_POLL_SLEEP_SEC=0
EOF_ENV

    cat > "$tmp_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_file="${PROBE_RESET_MOCK_STATE_FILE:?missing PROBE_RESET_MOCK_STATE_FILE}"
last_arg="${@: -1}"

if [[ "$*" == *"-X POST"* ]]; then
    payload=""
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            -d)
                payload="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$last_arg" == *"/auth/register" ]]; then
        nonce="$(
            python3 - "$payload" <<'PY'
import json
import sys
payload = json.loads(sys.argv[1])
email = payload.get("email", "")
print(email.split("@", 1)[0])
PY
        )"
        printf '%s\n' "$nonce" > "$state_file"
        printf '{"customer_id":"customer-stage2-reset-probe"}\n201\n'
        exit 0
    fi

    if [[ "$last_arg" == *"/auth/forgot-password" ]]; then
        printf '{"message":"password reset initiated"}\n200\n'
        exit 0
    fi

    if [[ "$last_arg" == *"/auth/reset-password" ]]; then
        printf '{"message":"password has been reset"}\n200\n'
        exit 0
    fi

    if [[ "$last_arg" == *"/auth/login" ]]; then
        printf '{"token":"jwt-stage2-reset","customer_id":"customer-stage2-reset-probe"}\n200\n'
        exit 0
    fi
fi

echo "unexpected curl invocation: $*" >&2
exit 64
MOCK
    chmod +x "$tmp_dir/curl"

    cat > "$tmp_dir/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_file="${PROBE_RESET_MOCK_STATE_FILE:?missing PROBE_RESET_MOCK_STATE_FILE}"
nonce="$(cat "$state_file" 2>/dev/null || true)"
if [[ -z "$nonce" ]]; then
    nonce="resetprobe-mock-nonce"
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml","LastModified":"2026-05-28T03:00:00Z"}]}
JSON
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "get-object" ]]; then
    output_path="${@: -1}"
    cat > "$output_path" <<RFC822
From: system@flapjack.foo
To: ${nonce}@test.flapjack.foo
Subject: Reset password

Click to reset: https://app.staging.flapjack.foo/reset-password/token-stage2-contract
probe nonce: ${nonce}
RFC822
    cat <<'JSON'
{"ETag":"mock"}
JSON
    exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 65
MOCK
    chmod +x "$tmp_dir/aws"

    cat > "$tmp_dir/mock_ssm_exec.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count_file="${PROBE_RESET_SQL_COUNT_FILE:?missing PROBE_RESET_SQL_COUNT_FILE}"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

if [[ "$count" -lt 2 ]]; then
    printf 'present\n'
else
    printf 'cleared\n'
fi
MOCK
    chmod +x "$tmp_dir/mock_ssm_exec.sh"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        PROBE_RESET_MOCK_STATE_FILE="$state_file" \
        PROBE_RESET_SQL_COUNT_FILE="$sql_count_file" \
        PROBE_SSM_EXEC_STAGING_SCRIPT="$tmp_dir/mock_ssm_exec.sh" \
        bash "$reset_script" --env-file "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_SQL_QUERY_CALLS="$(cat "$sql_count_file" 2>/dev/null || echo 0)"

    rm -rf "$tmp_dir"
}

main() {
    local verify_script="$REPO_ROOT/scripts/probe_verify_email_clickthrough_e2e.sh"
    local reset_script="$REPO_ROOT/scripts/probe_password_reset_clickthrough_e2e.sh"
    local dunning_script="$REPO_ROOT/scripts/probe_dunning_email_inbox_e2e.sh"
    local support_script="$REPO_ROOT/scripts/probe_inbound_support_routing_e2e.sh"
    local bounce_script="$REPO_ROOT/scripts/probe_bounce_alert_discord_readback.sh"
    local validate_script="$REPO_ROOT/scripts/validate_staging_dunning_delivery.sh"
    local helper_script="$REPO_ROOT/scripts/lib/clickthrough_probe_common.sh"

    assert_file_exists "$verify_script" "verify clickthrough probe exists"
    assert_file_exists "$reset_script" "reset clickthrough probe exists"
    assert_file_exists "$dunning_script" "dunning inbox probe exists"
    assert_file_exists "$support_script" "support routing probe exists"
    assert_file_exists "$bounce_script" "bounce alert probe exists"
    assert_file_exists "$validate_script" "staging dunning validator exists"
    assert_file_exists "$helper_script" "clickthrough shared helper exists"
    assert_eq "$(if [[ -x "$verify_script" ]]; then echo yes; else echo no; fi)" "yes" "verify clickthrough probe stays executable for the Stage 2 runner"
    assert_eq "$(if [[ -x "$reset_script" ]]; then echo yes; else echo no; fi)" "yes" "reset clickthrough probe stays executable for the Stage 2 runner"
    assert_eq "$(if [[ -x "$validate_script" ]]; then echo yes; else echo no; fi)" "yes" "staging dunning validator stays executable for the Stage 2 runner"

    local helper_source
    helper_source="$(read_file_content "$helper_script")"
    assert_contains "$helper_source" "SSM_EXEC_STAGING_SCRIPT_DEFAULT" "clickthrough helper defines staging SSM owner seam default"
    assert_not_contains "$helper_source" 'psql -v ON_ERROR_STOP=1 -X -t -A "$DATABASE_URL"' "clickthrough helper avoids local psql direct DB reads"

    run_command_capture bash "$verify_script"
    assert_eq "$RUN_EXIT_CODE" "2" "verify probe enforces usage exit"

    run_command_capture bash "$verify_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "verify probe precondition-fails when env file is missing"

    run_verify_probe_with_mocks "$verify_script"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should tolerate delayed email_verified_at convergence"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus on success"
    assert_eq "$RUN_SQL_QUERY_CALLS" "2" "verify probe should poll email_verified_at until it flips true"

    run_command_capture bash "$reset_script"
    assert_eq "$RUN_EXIT_CODE" "2" "reset probe enforces usage exit"

    run_command_capture bash "$reset_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "reset probe precondition-fails when env file is missing"

    run_reset_probe_with_mocks "$reset_script"
    assert_eq "$RUN_EXIT_CODE" "0" "reset probe should tolerate delayed password_reset_token clearance"
    assert_contains "$RUN_STDOUT" "TERMINUS: login succeeded with new password" "reset probe should emit login success terminus on success"
    assert_eq "$RUN_SQL_QUERY_CALLS" "2" "reset probe should poll password_reset_token until it clears"

    run_command_capture bash "$dunning_script"
    assert_eq "$RUN_EXIT_CODE" "2" "dunning probe enforces usage exit"

    run_command_capture bash "$dunning_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "dunning probe precondition-fails when env file missing"

    run_command_capture bash "$support_script"
    assert_eq "$RUN_EXIT_CODE" "0" "support routing probe succeeds"
    assert_contains "$RUN_STDOUT" "TERMINUS: operator-only delegation to support_email_probe.md" "support probe prints required terminus line"

    local mock_dir
    mock_dir="$(mktemp -d)"
    write_mock_script "$mock_dir/mock_probe_alert_delivery.sh" "$(cat <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "--readback" ]]; then
    echo "expected --readback arg" >&2
    exit 1
fi
echo "==> probe summary: nonce=nonce-from-alert-owner slack=skipped discord=ok env=staging"
MOCK
)"
    chmod 0644 "$mock_dir/mock_probe_alert_delivery.sh"
    run_command_capture env SES_FROM_ADDRESS="sender@example.com" SES_REGION="us-east-1" PROBE_ALERT_DELIVERY_SCRIPT="$mock_dir/mock_probe_alert_delivery.sh" bash "$bounce_script"
    rm -rf "$mock_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "bounce alert probe succeeds when owner readback script is readable and confirms nonce"
    assert_contains "$RUN_STDOUT" "TERMINUS: discord message contains nonce" "bounce probe prints nonce terminus"
    assert_contains "$RUN_STDOUT" "nonce=nonce-from-alert-owner" "bounce probe surfaces nonce from probe_alert_delivery owner output"

    run_test_summary
}

main "$@"
