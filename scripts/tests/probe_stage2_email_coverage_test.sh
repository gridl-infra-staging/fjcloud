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
    local page_success="${2:-true}"
    local app_base_contract="${3:-direct}"
    local hydrator_contract="${4:-success}"
    local db_contract="${5:-direct}"
    local db_behavior="${6:-delayed_success}"
    local tmp_dir env_file state_file sql_count_file sql_capture_file curl_capture_file stdout_file stderr_file

    tmp_dir="$(mktemp -d)"
    env_file="$tmp_dir/probe.env"
    state_file="$tmp_dir/mock_state_nonce.txt"
    sql_count_file="$tmp_dir/mock_sql_count.txt"
    sql_capture_file="$tmp_dir/mock_sql_capture.txt"
    curl_capture_file="$tmp_dir/mock_curl_urls.txt"
    stdout_file="$tmp_dir/stdout.log"
    stderr_file="$tmp_dir/stderr.log"

    cat > "$env_file" <<EOF_ENV
API_URL=https://api.staging.flapjack.foo
$(if [[ "$app_base_contract" = "direct" ]]; then printf '%s\n' "APP_BASE_URL=https://app.staging.flapjack.foo"; fi)
$(if [[ "$app_base_contract" = "prehydrated_staging" ]]; then printf '%s\n' "STAGING_CLOUD_URL=https://cloud.staging.flapjack.foo"; fi)
$(if [[ "$db_contract" = "direct" || "$db_contract" = "local_psql" ]]; then printf '%s\n' "DATABASE_URL=postgres://ignored:ignored@localhost:5432/fjcloud"; fi)
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/
INBOUND_ROUNDTRIP_POLL_MAX_ATTEMPTS=2
INBOUND_ROUNDTRIP_POLL_SLEEP_SEC=0
VERIFY_EMAIL_DB_POLL_MAX_ATTEMPTS=3
VERIFY_EMAIL_DB_POLL_SLEEP_SEC=0
EOF_ENV

    if [[ "$hydrator_contract" = "failure" ]]; then
        cat > "$tmp_dir/mock_hydrator.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "mock hydrator could not read staging SSM" >&2
exit 22
MOCK
    else
        cat > "$tmp_dir/mock_hydrator.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" != "staging" ]]; then
    echo "expected staging environment" >&2
    exit 1
fi
printf 'export STAGING_CLOUD_URL=%q\n' "https://cloud.staging.flapjack.foo"
printf 'export STAGING_API_URL=%q\n' "https://api.staging.flapjack.foo"
MOCK
    fi
    chmod +x "$tmp_dir/mock_hydrator.sh"

    cat > "$tmp_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
state_file="${PROBE_VERIFY_MOCK_STATE_FILE:?missing PROBE_VERIFY_MOCK_STATE_FILE}"
curl_capture_file="${PROBE_VERIFY_CURL_CAPTURE_FILE:?missing PROBE_VERIFY_CURL_CAPTURE_FILE}"
last_arg="${@: -1}"
printf '%s\n' "$last_arg" >> "$curl_capture_file"

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

if [[ "$*" == *"/verify-email/"* && "$*" != *"-X POST"* ]]; then
    page_success="${PROBE_VERIFY_MOCK_PAGE_SUCCESS:-true}"
    printf '<div data-testid="verify-result" data-success="%s">content</div>\n200\n' "$page_success"
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
sql_capture_file="${PROBE_VERIFY_SQL_CAPTURE_FILE:?missing PROBE_VERIFY_SQL_CAPTURE_FILE}"
db_behavior="${PROBE_VERIFY_DB_BEHAVIOR:-delayed_success}"
printf '%s\n%s\n' "---sql-command---" "$1" >> "$sql_capture_file"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$db_behavior" in
    delayed_success)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        elif [[ "$count" -lt 3 ]]; then
            printf 'false\n'
        else
            printf 'true\n'
        fi
        ;;
    wrong_db)
        printf 'absent\n'
        ;;
    product_red)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        else
            printf 'false\n'
        fi
        ;;
    sql_failure)
        echo "mock SSM visibility read failed" >&2
        exit 77
        ;;
    *)
        echo "unknown PROBE_VERIFY_DB_BEHAVIOR: $db_behavior" >&2
        exit 66
        ;;
esac
MOCK
    chmod +x "$tmp_dir/mock_ssm_exec.sh"

    cat > "$tmp_dir/psql" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count_file="${PROBE_VERIFY_SQL_COUNT_FILE:?missing PROBE_VERIFY_SQL_COUNT_FILE}"
sql_capture_file="${PROBE_VERIFY_SQL_CAPTURE_FILE:?missing PROBE_VERIFY_SQL_CAPTURE_FILE}"
db_behavior="${PROBE_VERIFY_DB_BEHAVIOR:-delayed_success}"
sql_query=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c)
            sql_query="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
printf '%s\n%s\n' "---sql-command---" "$sql_query" >> "$sql_capture_file"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$db_behavior" in
    delayed_success)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        elif [[ "$count" -lt 3 ]]; then
            printf 'false\n'
        else
            printf 'true\n'
        fi
        ;;
    wrong_db)
        printf 'absent\n'
        ;;
    product_red)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        else
            printf 'false\n'
        fi
        ;;
    sql_failure)
        echo "mock local psql visibility read failed" >&2
        exit 77
        ;;
    *)
        echo "unknown PROBE_VERIFY_DB_BEHAVIOR: $db_behavior" >&2
        exit 66
        ;;
esac
MOCK
    chmod +x "$tmp_dir/psql"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        AWS_SSM_INSTANCE_ID="$(if [[ "$db_contract" = "local_psql" ]]; then printf 'i-stage2-local'; fi)" \
        PROBE_VERIFY_MOCK_STATE_FILE="$state_file" \
        PROBE_VERIFY_MOCK_PAGE_SUCCESS="$page_success" \
        PROBE_VERIFY_SQL_COUNT_FILE="$sql_count_file" \
        PROBE_VERIFY_SQL_CAPTURE_FILE="$sql_capture_file" \
        PROBE_VERIFY_CURL_CAPTURE_FILE="$curl_capture_file" \
        PROBE_VERIFY_DB_BEHAVIOR="$db_behavior" \
        PROBE_SSM_EXEC_STAGING_SCRIPT="$tmp_dir/mock_ssm_exec.sh" \
        STAGING_TOOL_ENV_HYDRATOR_SCRIPT="$tmp_dir/mock_hydrator.sh" \
        bash "$verify_script" --env-file "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_SQL_QUERY_CALLS="$(cat "$sql_count_file" 2>/dev/null || echo 0)"
    RUN_SQL_CAPTURE="$(cat "$sql_capture_file" 2>/dev/null || true)"
    RUN_FIRST_SQL_CAPTURE="$(awk '
        /^---sql-command---$/ {
            seen += 1
            if (seen == 2) {
                exit
            }
            next
        }
        seen == 1 { print }
    ' "$sql_capture_file" 2>/dev/null || true)"
    RUN_CURL_URLS="$(cat "$curl_capture_file" 2>/dev/null || true)"

    rm -rf "$tmp_dir"
}

run_reset_probe_with_mocks() {
    local reset_script="$1"
    local db_contract="${2:-direct}"
    local db_behavior="${3:-delayed_success}"
    local tmp_dir env_file state_file sql_count_file sql_capture_file stdout_file stderr_file

    tmp_dir="$(mktemp -d)"
    env_file="$tmp_dir/probe.env"
    state_file="$tmp_dir/mock_state_nonce.txt"
    sql_count_file="$tmp_dir/mock_sql_count.txt"
    sql_capture_file="$tmp_dir/mock_sql_capture.txt"
    stdout_file="$tmp_dir/stdout.log"
    stderr_file="$tmp_dir/stderr.log"

    cat > "$env_file" <<EOF_ENV
API_URL=https://api.staging.flapjack.foo
$(if [[ "$db_contract" = "direct" || "$db_contract" = "local_psql" ]]; then printf '%s\n' "DATABASE_URL=postgres://ignored:ignored@localhost:5432/fjcloud"; fi)
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
        printf '{"customer_id":"00000000-0000-4000-8000-000000000201"}\n201\n'
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
        printf '{"token":"jwt-stage2-reset","customer_id":"00000000-0000-4000-8000-000000000201"}\n200\n'
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
sql_capture_file="${PROBE_RESET_SQL_CAPTURE_FILE:?missing PROBE_RESET_SQL_CAPTURE_FILE}"
db_behavior="${PROBE_RESET_DB_BEHAVIOR:-delayed_success}"
printf '%s\n%s\n' "---sql-command---" "$1" >> "$sql_capture_file"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$db_behavior" in
    delayed_success)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        elif [[ "$count" -lt 3 ]]; then
            printf 'present\n'
        else
            printf 'cleared\n'
        fi
        ;;
    wrong_db)
        printf 'absent\n'
        ;;
    product_red)
        printf 'present\n'
        ;;
    sql_failure)
        echo "mock SSM visibility read failed" >&2
        exit 77
        ;;
    *)
        echo "unknown PROBE_RESET_DB_BEHAVIOR: $db_behavior" >&2
        exit 66
        ;;
esac
MOCK
    chmod +x "$tmp_dir/mock_ssm_exec.sh"

    cat > "$tmp_dir/psql" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
count_file="${PROBE_RESET_SQL_COUNT_FILE:?missing PROBE_RESET_SQL_COUNT_FILE}"
sql_capture_file="${PROBE_RESET_SQL_CAPTURE_FILE:?missing PROBE_RESET_SQL_CAPTURE_FILE}"
db_behavior="${PROBE_RESET_DB_BEHAVIOR:-delayed_success}"
sql_query=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -c)
            sql_query="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
printf '%s\n%s\n' "---sql-command---" "$sql_query" >> "$sql_capture_file"
count=0
if [[ -f "$count_file" ]]; then
    count="$(cat "$count_file")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"

case "$db_behavior" in
    delayed_success)
        if [[ "$count" -eq 1 ]]; then
            printf 'present\n'
        elif [[ "$count" -lt 3 ]]; then
            printf 'present\n'
        else
            printf 'cleared\n'
        fi
        ;;
    wrong_db)
        printf 'absent\n'
        ;;
    product_red)
        printf 'present\n'
        ;;
    sql_failure)
        echo "mock local psql visibility read failed" >&2
        exit 77
        ;;
    *)
        echo "unknown PROBE_RESET_DB_BEHAVIOR: $db_behavior" >&2
        exit 66
        ;;
esac
MOCK
    chmod +x "$tmp_dir/psql"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        AWS_SSM_INSTANCE_ID="$(if [[ "$db_contract" = "local_psql" ]]; then printf 'i-stage2-local'; fi)" \
        PROBE_RESET_MOCK_STATE_FILE="$state_file" \
        PROBE_RESET_SQL_COUNT_FILE="$sql_count_file" \
        PROBE_RESET_SQL_CAPTURE_FILE="$sql_capture_file" \
        PROBE_RESET_DB_BEHAVIOR="$db_behavior" \
        PROBE_SSM_EXEC_STAGING_SCRIPT="$tmp_dir/mock_ssm_exec.sh" \
        bash "$reset_script" --env-file "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
    RUN_SQL_QUERY_CALLS="$(cat "$sql_count_file" 2>/dev/null || echo 0)"
    RUN_SQL_CAPTURE="$(cat "$sql_capture_file" 2>/dev/null || true)"
    RUN_FIRST_SQL_CAPTURE="$(awk '
        /^---sql-command---$/ {
            seen += 1
            if (seen == 2) {
                exit
            }
            next
        }
        seen == 1 { print }
    ' "$sql_capture_file" 2>/dev/null || true)"

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
    assert_contains "$helper_source" "AWS_SSM_INSTANCE_ID" "clickthrough helper can detect in-host SSM execution for local DB reads"
    assert_contains "$helper_source" 'psql -X -t -A -v ON_ERROR_STOP=1 "$DATABASE_URL"' "clickthrough helper uses local psql only after in-host detection"

    run_command_capture bash "$verify_script"
    assert_eq "$RUN_EXIT_CODE" "2" "verify probe enforces usage exit"

    run_command_capture bash "$verify_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "verify probe precondition-fails when env file is missing"

    run_verify_probe_with_mocks "$verify_script"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should tolerate delayed email_verified_at convergence"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus on success"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "verify probe should guard customer visibility before polling email_verified_at until it flips true"

    run_verify_probe_with_mocks "$verify_script" "true" "staging_hydrated"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should derive APP_BASE_URL from hydrated STAGING_CLOUD_URL when curated staging secret only sets API_URL"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus with API_URL-only staging env"
    assert_contains "$RUN_CURL_URLS" "https://cloud.staging.flapjack.foo/verify-email/token-stage2-contract" "verify probe should fetch verify page from canonical staging cloud host"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "verify probe should still guard then poll email_verified_at through SSM helper with API_URL-only staging env"

    run_verify_probe_with_mocks "$verify_script" "true" "staging_hydrated" "failure"
    assert_eq "$RUN_EXIT_CODE" "3" "verify probe should precondition-fail when staging hydration cannot derive APP_BASE_URL"
    assert_contains "$RUN_STDERR" "staging tool env hydration failed" "verify probe should classify missing APP_BASE_URL as staging hydration failure"
    assert_contains "$RUN_STDERR" "mock hydrator could not read staging SSM" "verify probe should preserve hydrator stderr for live env-owner diagnosis"
    assert_not_contains "$RUN_STDERR" "APP_BASE_URL is required" "verify probe should not collapse hydrator failure into the old APP_BASE_URL precondition"

    run_verify_probe_with_mocks "$verify_script" "true" "prehydrated_staging" "failure"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should derive APP_BASE_URL from pre-hydrated STAGING_CLOUD_URL without fresh SSM hydration"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus with pre-hydrated staging cloud env"
    assert_contains "$RUN_CURL_URLS" "https://cloud.staging.flapjack.foo/verify-email/token-stage2-contract" "verify probe should fetch verify page from pre-hydrated canonical staging cloud host"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "verify probe should still guard then poll email_verified_at through SSM helper with pre-hydrated staging cloud env"

    run_verify_probe_with_mocks "$verify_script" "true" "staging_hydrated" "success" "remote_only"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should not require a local DATABASE_URL when DB reads use the SSM helper"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus with remote-only DB reads"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "verify probe should still guard then poll email_verified_at through SSM helper with remote-only DB reads"
    assert_contains "$RUN_SQL_CAPTURE" "email_verified_at" "verify probe should send final email_verified_at assertion through the SSM helper"
    assert_contains "$RUN_SQL_CAPTURE" "source /etc/fjcloud/env" "verify probe SSM command should source the staging host DB environment"
    assert_contains "$RUN_SQL_CAPTURE" "psql -X -t -A -v ON_ERROR_STOP=1" "verify probe should use the shared remote psql command"

    run_verify_probe_with_mocks "$verify_script" "true" "direct" "success" "local_psql"
    assert_eq "$RUN_EXIT_CODE" "0" "verify probe should use local psql when already running on the staging SSM host"
    assert_contains "$RUN_STDOUT" "TERMINUS: email_verified=true" "verify probe should emit email verification terminus with in-host local DB reads"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "verify probe should preserve visibility guard and polling with in-host local DB reads"
    assert_contains "$RUN_SQL_CAPTURE" "email_verified_at" "verify probe local DB path should send final email_verified_at assertion"
    assert_not_contains "$RUN_SQL_CAPTURE" "source /etc/fjcloud/env" "verify probe local DB path should not invoke nested SSM command"

    run_verify_probe_with_mocks "$verify_script" "true" "direct" "success" "direct" "wrong_db"
    assert_eq "$RUN_EXIT_CODE" "1" "verify probe should fail when the API-created customer is absent from the DB control read"
    assert_contains "$RUN_FIRST_SQL_CAPTURE" "SELECT CASE WHEN EXISTS (SELECT 1 FROM customers WHERE id =" "verify probe first DB read should be the customer-existence control query"
    assert_contains "$RUN_FIRST_SQL_CAPTURE" "customer-stage2-verify-probe" "verify probe first DB read should target the API-created customer_id"
    assert_contains "$RUN_STDERR" "probe_env_wrong_db" "verify probe should classify customer visibility drift"
    assert_contains "$RUN_STDERR" "customer-stage2-verify-probe" "verify probe wrong-DB error should include customer_id context"
    assert_not_contains "$RUN_STDERR" "email_verified_at not set" "verify probe wrong-DB guard should not report the later product mutation failure"

    run_verify_probe_with_mocks "$verify_script" "true" "direct" "success" "direct" "sql_failure"
    assert_eq "$RUN_EXIT_CODE" "77" "verify probe should preserve the customer visibility control read exit status"
    assert_contains "$RUN_STDERR" "failed reading customer visibility control" "verify probe should classify SSM SQL failure as a control-read failure"
    assert_contains "$RUN_STDERR" "customer-stage2-verify-probe" "verify probe control-read failure should include customer_id context"
    assert_not_contains "$RUN_STDERR" "customer visibility control returned" "verify probe should not report failed SSM output as a visibility marker"
    assert_not_contains "$RUN_STDERR" "mock SSM visibility read failed" "verify probe should not surface raw SSM failure output as customer visibility state"
    assert_not_contains "$RUN_STDERR" "email_verified_at not set" "verify probe SQL failure should not report the later product mutation failure"

    run_verify_probe_with_mocks "$verify_script" "true" "direct" "success" "direct" "product_red"
    assert_eq "$RUN_EXIT_CODE" "1" "verify probe should still fail product-red when customer exists but email_verified_at never changes"
    assert_contains "$RUN_STDERR" "email_verified_at not set" "verify probe should preserve product mutation failure string"
    assert_not_contains "$RUN_STDERR" "probe_env_wrong_db" "verify probe should not classify product mutation failure as wrong DB"

    run_verify_probe_with_mocks "$verify_script" "false"
    assert_eq "$RUN_EXIT_CODE" "1" "verify probe must reject failure-branch page even on HTTP 200"
    assert_contains "$RUN_STDERR" "failure branch" "verify probe error message mentions failure branch"

    run_command_capture bash "$reset_script"
    assert_eq "$RUN_EXIT_CODE" "2" "reset probe enforces usage exit"

    run_command_capture bash "$reset_script" /tmp/does-not-exist
    assert_eq "$RUN_EXIT_CODE" "3" "reset probe precondition-fails when env file is missing"

    run_reset_probe_with_mocks "$reset_script"
    assert_eq "$RUN_EXIT_CODE" "0" "reset probe should tolerate delayed password_reset_token clearance"
    assert_contains "$RUN_STDOUT" "TERMINUS: login succeeded with new password" "reset probe should emit login success terminus on success"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "reset probe should guard customer visibility before polling password_reset_token until it clears"
    assert_contains "$RUN_SQL_CAPTURE" "WHERE id =" "reset probe DB poll should target the registered customer_id"
    assert_not_contains "$RUN_SQL_CAPTURE" "WHERE email =" "reset probe DB poll should not target customer rows by email"
    assert_contains "$RUN_SQL_CAPTURE" "00000000-0000-4000-8000-000000000201" "reset probe DB poll should include the registered customer UUID"

    run_reset_probe_with_mocks "$reset_script" "remote_only"
    assert_eq "$RUN_EXIT_CODE" "0" "reset probe should not require a local DATABASE_URL when DB reads use the SSM helper"
    assert_contains "$RUN_STDOUT" "TERMINUS: login succeeded with new password" "reset probe should emit login success terminus with remote-only DB reads"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "reset probe should still guard then poll password_reset_token through SSM helper with remote-only DB reads"
    assert_contains "$RUN_SQL_CAPTURE" "password_reset_token IS NULL" "reset probe should send final token-clear assertion through the SSM helper"
    assert_contains "$RUN_SQL_CAPTURE" "source /etc/fjcloud/env" "reset probe SSM command should source the staging host DB environment"
    assert_contains "$RUN_SQL_CAPTURE" "psql -X -t -A -v ON_ERROR_STOP=1" "reset probe should use the shared remote psql command"

    run_reset_probe_with_mocks "$reset_script" "local_psql"
    assert_eq "$RUN_EXIT_CODE" "0" "reset probe should use local psql when already running on the staging SSM host"
    assert_contains "$RUN_STDOUT" "TERMINUS: login succeeded with new password" "reset probe should emit login success terminus with in-host local DB reads"
    assert_eq "$RUN_SQL_QUERY_CALLS" "3" "reset probe should preserve visibility guard and polling with in-host local DB reads"
    assert_contains "$RUN_SQL_CAPTURE" "password_reset_token IS NULL" "reset probe local DB path should send final token-clear assertion"
    assert_not_contains "$RUN_SQL_CAPTURE" "source /etc/fjcloud/env" "reset probe local DB path should not invoke nested SSM command"

    run_reset_probe_with_mocks "$reset_script" "direct" "wrong_db"
    assert_eq "$RUN_EXIT_CODE" "1" "reset probe should fail when the API-created customer is absent from the DB control read"
    assert_contains "$RUN_FIRST_SQL_CAPTURE" "SELECT CASE WHEN EXISTS (SELECT 1 FROM customers WHERE id =" "reset probe first DB read should be the customer-existence control query"
    assert_contains "$RUN_FIRST_SQL_CAPTURE" "00000000-0000-4000-8000-000000000201" "reset probe first DB read should target the API-created customer_id"
    assert_contains "$RUN_STDERR" "probe_env_wrong_db" "reset probe should classify customer visibility drift"
    assert_contains "$RUN_STDERR" "00000000-0000-4000-8000-000000000201" "reset probe wrong-DB error should include customer_id context"
    assert_not_contains "$RUN_STDERR" "password_reset_token not cleared" "reset probe wrong-DB guard should not report the later product mutation failure"

    run_reset_probe_with_mocks "$reset_script" "direct" "sql_failure"
    assert_eq "$RUN_EXIT_CODE" "77" "reset probe should preserve the customer visibility control read exit status"
    assert_contains "$RUN_STDERR" "failed reading customer visibility control" "reset probe should classify SSM SQL failure as a control-read failure"
    assert_contains "$RUN_STDERR" "00000000-0000-4000-8000-000000000201" "reset probe control-read failure should include customer_id context"
    assert_not_contains "$RUN_STDERR" "customer visibility control returned" "reset probe should not report failed SSM output as a visibility marker"
    assert_not_contains "$RUN_STDERR" "mock SSM visibility read failed" "reset probe should not surface raw SSM failure output as customer visibility state"
    assert_not_contains "$RUN_STDERR" "password_reset_token not cleared" "reset probe SQL failure should not report the later product mutation failure"

    run_reset_probe_with_mocks "$reset_script" "direct" "product_red"
    assert_eq "$RUN_EXIT_CODE" "1" "reset probe should still fail product-red when customer exists but password_reset_token never clears"
    assert_contains "$RUN_STDERR" "password_reset_token not cleared" "reset probe should preserve product mutation failure string"
    assert_not_contains "$RUN_STDERR" "probe_env_wrong_db" "reset probe should not classify product mutation failure as wrong DB"

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
