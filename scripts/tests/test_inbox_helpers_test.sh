#!/usr/bin/env bash
# Tests for scripts/lib/test_inbox_helpers.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_helpers.sh"

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

test_inbox_helpers_mock_aws_body() {
    cat <<'MOCK'
set -euo pipefail

log_path="${TEST_INBOX_HELPERS_AWS_CALL_LOG:-}"
if [[ -n "$log_path" ]]; then
    echo "$*" >> "$log_path"
fi
list_mode="${TEST_INBOX_HELPERS_LIST_MODE:-found_immediately}"
count_file="${TEST_INBOX_HELPERS_LIST_COUNT_FILE:-}"
nonce="${TEST_INBOX_HELPERS_NONCE:-missingnonce}"

if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    case "${TEST_INBOX_HELPERS_STS_MODE:-success}" in
        failure)
            echo "simulated sts failure" >&2
            exit 43
            ;;
        no_credentials)
            echo 'aws: [ERROR]: An error occurred (NoCredentials): Unable to locate credentials. You can configure credentials by running "aws login".' >&2
            exit 253
            ;;
    esac
    cat <<'JSON'
{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"test-user"}
JSON
    exit 0
fi

if [[ "${1:-}" == "sesv2" && "${2:-}" == "send-email" ]]; then
    cat <<'JSON'
{"MessageId":"helper-message-1"}
JSON
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    has_continuation_token=0
    for arg in "$@"; do
        if [[ "$arg" == "--continuation-token" ]]; then
            has_continuation_token=1
            break
        fi
    done
    if [[ -z "$count_file" || ! -f "$count_file" ]]; then
        echo "missing count file for list-objects mock" >&2
        exit 97
    fi
    current_count="$(cat "$count_file")"
    current_count=$((current_count + 1))
    printf '%s\n' "$current_count" > "$count_file"
    case "$list_mode" in
        found_immediately)
            cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml"}]}
JSON
            ;;
        found_after_two)
            if [ "$current_count" -lt 3 ]; then
                cat <<'JSON'
{"Contents":[]}
JSON
            else
                cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml"}]}
JSON
            fi
            ;;
        body_only_match)
            cat <<'JSON'
{"Contents":[{"Key":"e2e-emails/ses-delivery-object-001"}]}
JSON
            ;;
        paginated_two_pages)
            if [[ "$has_continuation_token" -eq 0 ]]; then
                cat <<'JSON'
{"Contents":[{"Key":"e2e-emails/nonmatching-first-page-object"}],"NextContinuationToken":"page-2-token"}
JSON
            else
                cat <<JSON
{"Contents":[{"Key":"e2e-emails/${nonce}.eml"}]}
JSON
            fi
            ;;
        run_scoped_keys)
            cat <<'JSON'
{"Contents":[
  {"Key":"e2e-emails/run-001/failed.eml","LastModified":"2026-05-16T01:00:00Z"},
  {"Key":"e2e-emails/run-001/suspended.eml","LastModified":"2026-05-16T01:00:01Z"},
  {"Key":"e2e-emails/run-001/recovered.eml","LastModified":"2026-05-16T01:00:02Z"}
]}
JSON
            ;;
        run_scoped_unsorted_with_invalid_timestamps)
            cat <<'JSON'
{"Contents":[
  {"Key":"e2e-emails/run-002/invalid-ts.eml","LastModified":"not-a-timestamp"},
  {"Key":"e2e-emails/run-002/newest.eml","LastModified":"2026-05-16T01:00:03Z"},
  {"Key":"e2e-emails/run-002/missing-ts.eml"},
  {"Key":"e2e-emails/run-002/second-newest.eml","LastModified":"2026-05-16T01:00:02Z"},
  {"Key":"e2e-emails/run-002/oldest.eml","LastModified":"2026-05-16T01:00:01Z"}
]}
JSON
            ;;
        never_found)
            cat <<'JSON'
{"Contents":[]}
JSON
            ;;
        *)
            echo "unknown TEST_INBOX_HELPERS_LIST_MODE: $list_mode" >&2
            exit 91
            ;;
    esac
    exit 0
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "get-object" ]]; then
    output_path="${@: -1}"
    cp "${TEST_INBOX_HELPERS_RFC822_FIXTURE:?missing fixture path}" "$output_path"
    cat <<'JSON'
{"ETag":"fixture"}
JSON
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 92
MOCK
}

source_helpers() {
    # shellcheck source=../lib/test_inbox_helpers.sh
    source "$REPO_ROOT/scripts/lib/test_inbox_helpers.sh"
}

test_nonce_subject_body_contract() {
    local nonce subject body
    source_helpers

    nonce="$(test_inbox_generate_nonce)"
    subject="$(test_inbox_build_probe_subject "$nonce")"
    body="$(test_inbox_build_probe_body "$nonce")"

    assert_contains "$nonce" "inbound-probe" "nonce should use inbound-probe prefix"
    assert_contains "$subject" "$nonce" "probe subject should include nonce"
    assert_contains "$body" "$nonce" "probe body should include nonce"
}

test_poll_finds_matching_s3_object_after_retries() {
    local mock_dir call_log count_file fixture_file found_key
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fixture

fixture body
RFC822

    found_key="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_after_two" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-nonce" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_find_matching_object_key "flapjack-cloud-releases" "e2e-emails/" "helper-nonce" "us-east-1" "4" "0"
    )"

    rm -rf "$mock_dir"

    assert_eq "$found_key" "e2e-emails/helper-nonce.eml" "poll helper should return matching S3 key after retries"
}

test_poll_finds_object_when_nonce_exists_only_in_rfc822_payload() {
    local mock_dir call_log count_file fixture_file found_key get_object_count
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fjcloud inbound roundtrip probe helper-body-only-nonce

Inbound roundtrip probe nonce=helper-body-only-nonce
RFC822

    found_key="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="body_only_match" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-body-only-nonce" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_find_matching_object_key "flapjack-cloud-releases" "e2e-emails/" "helper-body-only-nonce" "us-east-1" "2" "0"
    )"

    get_object_count="$(grep -c '^s3api get-object ' "$call_log" || true)"
    rm -rf "$mock_dir"

    assert_eq "$found_key" "e2e-emails/ses-delivery-object-001" "poll helper should match object when nonce is only in RFC822 payload"
    assert_eq "$get_object_count" "1" "poll helper should fetch candidate RFC822 payload when nonce is absent from key names"
}

test_poll_scans_paginated_s3_listings() {
    local mock_dir call_log count_file fixture_file found_key list_call_count
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fixture

fixture body
RFC822

    found_key="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="paginated_two_pages" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-paginated-nonce" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_find_matching_object_key "flapjack-cloud-releases" "e2e-emails/" "helper-paginated-nonce" "us-east-1" "1" "0"
    )"

    list_call_count="$(grep -c '^s3api list-objects-v2 ' "$call_log" || true)"
    rm -rf "$mock_dir"

    assert_eq "$found_key" "e2e-emails/helper-paginated-nonce.eml" "poll helper should find a nonce match from a continuation page"
    assert_eq "$list_call_count" "2" "poll helper should request the next page when NextContinuationToken is present"
}

test_poll_times_out_with_timeout_exit_code() {
    local mock_dir call_log count_file fixture_file exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fixture

fixture body
RFC822

    TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="never_found" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-timeout" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_find_matching_object_key "flapjack-cloud-releases" "e2e-emails/" "helper-timeout" "us-east-1" "2" "0" >/dev/null 2>&1 || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "124" "poll helper should return timeout exit code 124 when key is not found"
}

test_fetch_rfc822_reads_message_content() {
    local mock_dir call_log count_file fixture_file fetched
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fetched-fixture

fixture body fetch test
RFC822

    fetched="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_immediately" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-fetch" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_fetch_rfc822 "flapjack-cloud-releases" "e2e-emails/helper-fetch.eml" "us-east-1"
    )"

    rm -rf "$mock_dir"

    assert_contains "$fetched" "fetched-fixture" "fetch helper should return raw RFC822 payload"
    assert_contains "$fetched" "fixture body fetch test" "fetch helper should preserve RFC822 body"
}

test_aws_backed_helpers_validate_required_args() {
    local mock_dir call_log count_file fixture_file send_exit poll_exit fetch_exit
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: validation

body
RFC822

    TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_immediately" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-validate" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_send_probe_email "" "nonce@test.flapjack.foo" "" "subject" "body" >/dev/null 2>&1 || send_exit=$?

    TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_immediately" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-validate" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_find_matching_object_key "" "e2e-emails/" "helper-validate" "" "2" "0" >/dev/null 2>&1 || poll_exit=$?

    TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_immediately" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-validate" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_fetch_rfc822 "" "e2e-emails/helper-validate.eml" "" >/dev/null 2>&1 || fetch_exit=$?

    rm -rf "$mock_dir"

    assert_eq "${send_exit:-0}" "2" "send helper should fail fast on missing required args"
    assert_eq "${poll_exit:-0}" "2" "poll helper should fail fast on missing required args"
    assert_eq "${fetch_exit:-0}" "2" "fetch helper should fail fast on missing required args"
}

test_inbox_prereqs_report_missing_aws_binary() {
    local empty_path output exit_code
    source_helpers

    empty_path="$(mktemp -d)"
    output="$(
        PATH="$empty_path" \
        test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" 2>&1
    )" || exit_code=$?

    rm -rf "$empty_path"
    assert_eq "${exit_code:-0}" "100" "inbox prereq helper should skip when aws CLI is unavailable"
    assert_contains "$output" "probe_env_gap_aws_credentials_unavailable" "missing aws CLI should emit canonical unavailable token"
}

test_inbox_prereqs_report_missing_credential_chain() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    output="$(
        TEST_INBOX_HELPERS_STS_MODE="no_credentials" \
        PATH="$mock_dir:$PATH" \
        test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "100" "inbox prereq helper should skip when AWS credential chain is absent"
    assert_contains "$output" "probe_env_gap_aws_credentials_unavailable" "missing credential chain should emit canonical unavailable token"
    assert_contains "$output" "aws sts get-caller-identity could not locate credentials" "missing credential chain should emit precise detail"
}

test_inbox_prereqs_report_invalid_aws_credentials() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    output="$(
        TEST_INBOX_HELPERS_STS_MODE="failure" \
        AWS_ACCESS_KEY_ID="AKIA_TEST_INBOX_HELPERS" \
        AWS_SECRET_ACCESS_KEY="test-secret" \
        PATH="$mock_dir:$PATH" \
        test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "100" "inbox prereq helper should skip when aws credentials are invalid"
    assert_contains "$output" "probe_env_gap_aws_credentials_invalid" "invalid aws credentials should emit canonical invalid token"
}

test_inbox_prereqs_recover_polluted_ambient_via_secret_file() {
    # Regression for the 2026-07-08 root cause: stale ambient AWS_* that STS
    # rejects, combined with a VALID key in the operator secret file, must let
    # inbox prereqs PASS (exit 0) via aws_identity recovery — NOT skip with
    # probe_env_gap_aws_credentials_invalid. Before the aws_identity integration
    # this returned 100 (the false env-gap skip that stalled the canary/RC for
    # ~5 weeks). The mock gates STS success on AWS_ACCESS_KEY_ID=GOODKEY so the
    # ambient BADKEY is rejected and only the secret-file key authenticates.
    local mock_dir secret_file exit_code=0
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(cat <<'MOCK'
set -euo pipefail
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    if [[ "${AWS_ACCESS_KEY_ID:-}" == "GOODKEY" ]]; then
        echo '{"Account":"999999999999","Arn":"arn:aws:iam::999999999999:user/recovered","UserId":"u"}'
        exit 0
    fi
    echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.' >&2
    exit 254
fi
exit 0
MOCK
)")"
    secret_file="$(mktemp)"
    printf 'AWS_ACCESS_KEY_ID=GOODKEY\nAWS_SECRET_ACCESS_KEY=goodsecret\n' > "$secret_file"

    (
        export PATH="$mock_dir:$PATH"
        export FJCLOUD_SECRET_FILE="$secret_file"
        export AWS_ACCESS_KEY_ID=BADKEY AWS_SECRET_ACCESS_KEY=badsecret
        test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" >/dev/null 2>&1
    ) || exit_code=$?

    rm -rf "$mock_dir" "$secret_file"
    assert_eq "${exit_code:-0}" "0" "inbox prereq helper recovers from polluted ambient AWS_* using the secret file's valid key"
}

test_inbox_prereqs_accept_default_credential_chain_without_env_selectors() {
    local mock_dir call_log exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    : > "$call_log"

    (
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
            PATH="$mock_dir:$PATH" \
            test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" >/dev/null 2>&1
    ) || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "inbox prereq helper should accept a successful default AWS credential chain"
    assert_contains "$(cat "$call_log")" "sts get-caller-identity" \
        "default credential chain should be validated with sts"

    rm -rf "$mock_dir"
}

test_inbox_prereqs_report_missing_inbox_env() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    output="$(
        PATH="$mock_dir:$PATH" \
        test_inbox_require_aws_inbox_prereqs "" "" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "100" "inbox prereq helper should skip when inbox env is missing"
    assert_contains "$output" "probe_env_gap_aws_inbox_env_missing" "missing inbox env should emit canonical inbox-env token"
}

test_inbox_prereqs_reject_bad_helper_inputs_as_arg_errors() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    output="$(
        PATH="$mock_dir:$PATH" \
        test_inbox_require_aws_inbox_prereqs "not-s3" "test.flapjack.foo" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "2" "inbox prereq helper should keep caller bugs as arg errors"
    assert_contains "$output" "invalid S3 URI" "bad prereq helper S3 input should emit parse owner error"
}

test_list_recent_object_keys_validates_required_args() {
    local mock_dir call_log count_file fixture_file list_exit
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: validation

body
RFC822

    TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="found_immediately" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-list-validate" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_list_recent_object_keys_json "" "e2e-emails/" "us-east-1" "25" >/dev/null 2>&1 || list_exit=$?

    rm -rf "$mock_dir"
    assert_eq "${list_exit:-0}" "2" "list helper should fail fast on missing required args"
}

test_list_recent_object_keys_reports_aws_failure() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/aws" <<'MOCK'
#!/usr/bin/env bash
echo "simulated list failure" >&2
exit 42
MOCK
    chmod +x "$mock_dir/aws"

    output="$(
        PATH="$mock_dir:$PATH" \
        test_inbox_list_recent_object_keys_json "flapjack-cloud-releases" "e2e-emails/" "us-east-1" "25" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "1" "list helper should return 1 when aws list call fails"
    assert_contains "$output" "aws s3api list-objects-v2 failed for s3://flapjack-cloud-releases/e2e-emails/" \
        "list helper should emit owner error when aws list call fails"
}

test_fetch_rfc822_reports_aws_failure_after_prereqs_pass() {
    local mock_dir output exit_code
    source_helpers

    mock_dir="$(mktemp -d)"
    cat > "$mock_dir/aws" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    cat <<'JSON'
{"Account":"123456789012"}
JSON
    exit 0
fi
echo "simulated get-object failure" >&2
exit 44
MOCK
    chmod +x "$mock_dir/aws"

    PATH="$mock_dir:$PATH" \
        test_inbox_require_aws_inbox_prereqs "s3://flapjack-cloud-releases/e2e-emails/" "test.flapjack.foo" >/dev/null
    output="$(
        PATH="$mock_dir:$PATH" \
        test_inbox_fetch_rfc822 "flapjack-cloud-releases" "e2e-emails/helper-fetch.eml" "us-east-1" 2>&1
    )" || exit_code=$?

    rm -rf "$mock_dir"
    assert_eq "${exit_code:-0}" "1" "fetch helper should return 1 when aws get-object call fails"
    assert_contains "$output" "aws s3api get-object failed for s3://flapjack-cloud-releases/e2e-emails/helper-fetch.eml" \
        "fetch helper should emit owner error when aws get-object call fails"
}

test_extract_verify_token_reads_path_style_link() {
    local payload extracted
    source_helpers

    payload="$(cat <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: Verify your email
Content-Type: text/html; charset=utf-8

<p>Click <a href="https://cloud.flapjack.foo/verify-email/test_token_path_123">verify</a></p>
RFC822
)"

    extracted="$(test_inbox_extract_verify_token_from_rfc822 "$payload")"
    assert_eq "$extracted" "test_token_path_123" "extract helper should parse /verify-email/{token} links"
}

test_extract_verify_token_supports_legacy_query_shape() {
    local payload extracted
    source_helpers

    payload="$(cat <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: Verify your email
Content-Type: text/plain; charset=utf-8

Legacy verify link: https://cloud.flapjack.foo/verify-email?token=legacy_query_token_456
RFC822
)"

    extracted="$(test_inbox_extract_verify_token_from_rfc822 "$payload")"
    assert_eq "$extracted" "legacy_query_token_456" "extract helper should support legacy query token links"
}

test_extract_subject_and_body_from_rfc822_payload() {
    local payload subject body
    source_helpers

    payload="$(cat <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: Payment recovered
Content-Type: text/plain; charset=utf-8

Invoice reference: inv_recovered_001
RFC822
)"

    subject="$(test_inbox_extract_subject_from_rfc822 "$payload")"
    body="$(test_inbox_extract_body_text_from_rfc822 "$payload")"

    assert_eq "$subject" "Payment recovered" "subject extractor should return RFC822 Subject header"
    assert_contains "$body" "inv_recovered_001" "body extractor should return invoice-id-bearing body text"
}

test_list_s3_object_keys_for_run_scope_returns_recent_keys() {
    local mock_dir call_log count_file fixture_file keys_json
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fixture

fixture body
RFC822

    keys_json="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="run_scoped_keys" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-run-scope" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_list_recent_object_keys_json "flapjack-cloud-releases" "e2e-emails/run-001/" "us-east-1" "25"
    )"

    rm -rf "$mock_dir"

    assert_valid_json "$keys_json" "run-scoped list helper should return JSON array"
    assert_contains "$keys_json" "e2e-emails/run-001/recovered.eml" "run-scoped list helper should include recovered object key"
    assert_contains "$keys_json" "e2e-emails/run-001/failed.eml" "run-scoped list helper should include failed object key"
}

test_list_s3_object_keys_respects_sorting_and_max_keys() {
    local mock_dir call_log count_file fixture_file keys_json expected_json normalized_json
    source_helpers

    mock_dir="$(new_mock_command_dir "aws" "$(test_inbox_helpers_mock_aws_body)")"
    call_log="$mock_dir/aws_calls.log"
    count_file="$mock_dir/list_count.txt"
    fixture_file="$mock_dir/fixture.eml"
    : > "$call_log"
    printf '0\n' > "$count_file"
    cat > "$fixture_file" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: fixture

fixture body
RFC822

    keys_json="$(
        TEST_INBOX_HELPERS_AWS_CALL_LOG="$call_log" \
        TEST_INBOX_HELPERS_LIST_MODE="run_scoped_unsorted_with_invalid_timestamps" \
        TEST_INBOX_HELPERS_LIST_COUNT_FILE="$count_file" \
        TEST_INBOX_HELPERS_NONCE="helper-run-scope-ordering" \
        TEST_INBOX_HELPERS_RFC822_FIXTURE="$fixture_file" \
        PATH="$mock_dir:$PATH" \
        test_inbox_list_recent_object_keys_json "flapjack-cloud-releases" "e2e-emails/run-002/" "us-east-1" "2"
    )"
    rm -rf "$mock_dir"

    assert_valid_json "$keys_json" "sorted list helper should return JSON array"
    expected_json='["e2e-emails/run-002/newest.eml","e2e-emails/run-002/second-newest.eml"]'
    normalized_json="$(python3 - "$keys_json" <<'PY'
import json
import sys
print(json.dumps(json.loads(sys.argv[1]), separators=(",", ":")))
PY
)"
    assert_eq "$normalized_json" "$expected_json" "sorted list helper should return newest keys first and honor max_keys"
}

echo "=== test_inbox_helpers.sh tests ==="
test_nonce_subject_body_contract
test_poll_finds_matching_s3_object_after_retries
test_poll_finds_object_when_nonce_exists_only_in_rfc822_payload
test_poll_scans_paginated_s3_listings
test_poll_times_out_with_timeout_exit_code
test_fetch_rfc822_reads_message_content
test_aws_backed_helpers_validate_required_args
test_inbox_prereqs_report_missing_aws_binary
test_inbox_prereqs_report_missing_credential_chain
test_inbox_prereqs_report_invalid_aws_credentials
test_inbox_prereqs_recover_polluted_ambient_via_secret_file
test_inbox_prereqs_accept_default_credential_chain_without_env_selectors
test_inbox_prereqs_report_missing_inbox_env
test_inbox_prereqs_reject_bad_helper_inputs_as_arg_errors
test_list_recent_object_keys_validates_required_args
test_list_recent_object_keys_reports_aws_failure
test_fetch_rfc822_reports_aws_failure_after_prereqs_pass
test_extract_verify_token_reads_path_style_link
test_extract_verify_token_supports_legacy_query_shape
test_extract_subject_and_body_from_rfc822_payload
test_list_s3_object_keys_for_run_scope_returns_recent_keys
test_list_s3_object_keys_respects_sorting_and_max_keys

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
