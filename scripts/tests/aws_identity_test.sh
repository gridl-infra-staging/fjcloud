#!/usr/bin/env bash
# Tests for scripts/lib/aws_identity.sh — the shared AWS caller-identity triage
# SSOT. The load-bearing case is test_recovers_from_polluted_ambient_via_secret_file:
# stale ambient AWS_* that STS rejects, plus a VALID key in the secret file, must
# RECOVER (not skip). That is the exact 5-week bug this library was written to kill,
# and the assertion fails against any implementation that lacks the unset+reload step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

# System under test.
source "$REPO_ROOT/scripts/lib/aws_identity.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Configurable mock `aws`. Behavior is driven by env vars the test exports:
#   AWS_ID_MOCK_MODE      success | no_credentials | invalid | key_gated
#   AWS_ID_MOCK_GOOD_KEY  (key_gated) the AWS_ACCESS_KEY_ID value that authenticates
# In key_gated mode STS succeeds ONLY when the currently-loaded AWS_ACCESS_KEY_ID
# matches the designated good key — this simulates "ambient key rejected, secret
# file key accepted" so recovery is observable end to end.
mock_aws_body() {
    cat <<'MOCK'
set -euo pipefail
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    case "${AWS_ID_MOCK_MODE:-success}" in
        success)
            echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/ambient","UserId":"u"}'
            exit 0 ;;
        no_credentials)
            echo 'Unable to locate credentials. You can configure credentials by running "aws configure".' >&2
            exit 253 ;;
        invalid)
            echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.' >&2
            exit 254 ;;
        key_gated)
            if [[ "${AWS_ACCESS_KEY_ID:-}" == "${AWS_ID_MOCK_GOOD_KEY:-__none__}" ]]; then
                echo '{"Account":"999999999999","Arn":"arn:aws:iam::999999999999:user/recovered","UserId":"u"}'
                exit 0
            fi
            echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.' >&2
            exit 254 ;;
    esac
fi
echo "unexpected aws call: $*" >&2
exit 99
MOCK
}

# Run aws_identity_ensure in an isolated subshell (recovery mutates AWS_* in the
# caller's env, so isolation keeps cases independent) and emit a parseable line:
#   rc|status|account|source|diagnostic
# The output globals contain no '|' so it is a safe field delimiter.
run_ensure() {
    local mock_dir="$1" secret_file="$2"; shift 2
    # Remaining args are KEY=VALUE env assignments for this invocation.
    (
        export PATH="$mock_dir:$PATH"
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN FJCLOUD_SECRET_FILE
        local kv
        for kv in "$@"; do export "${kv?}"; done
        local rc=0
        aws_identity_ensure "$secret_file" >/dev/null 2>&1 || rc=$?
        printf '%s|%s|%s|%s|%s\n' "$rc" "$AWS_IDENTITY_STATUS" "$AWS_IDENTITY_ACCOUNT" "$AWS_IDENTITY_SOURCE" "$AWS_IDENTITY_DIAGNOSTIC"
    )
}

test_valid_ambient_identity_passes() {
    local mock_dir result rc status account
    mock_dir="$(new_mock_command_dir "aws" "$(mock_aws_body)")"
    result="$(run_ensure "$mock_dir" "/nonexistent/secret" AWS_ID_MOCK_MODE=success AWS_ACCESS_KEY_ID=AMBIENT AWS_SECRET_ACCESS_KEY=s)"
    rm -rf "$mock_dir"
    IFS='|' read -r rc status account _ _ <<< "$result"
    assert_eq "$rc" "0" "valid ambient identity returns 0"
    assert_eq "$status" "valid" "valid ambient identity reports status=valid"
    assert_eq "$account" "123456789012" "valid ambient identity parses the account id"
}

test_missing_cli_reports_cli_missing() {
    local empty_dir result rc status
    empty_dir="$(mktemp -d)"  # PATH with no `aws` on it; `command -v` is a builtin so it still runs
    result="$(
        export PATH="$empty_dir"
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN FJCLOUD_SECRET_FILE
        rc=0; aws_identity_ensure "/nonexistent/secret" >/dev/null 2>&1 || rc=$?
        printf '%s|%s\n' "$rc" "$AWS_IDENTITY_STATUS"
    )"
    rm -rf "$empty_dir"
    IFS='|' read -r rc status <<< "$result"
    assert_eq "$rc" "1" "missing aws CLI returns 1"
    assert_eq "$status" "cli_missing" "missing aws CLI reports status=cli_missing"
}

test_no_credentials_without_secret_file_reports_no_credentials() {
    local mock_dir result rc status diag
    mock_dir="$(new_mock_command_dir "aws" "$(mock_aws_body)")"
    result="$(run_ensure "$mock_dir" "/nonexistent/secret" AWS_ID_MOCK_MODE=no_credentials)"
    rm -rf "$mock_dir"
    IFS='|' read -r rc status _ _ diag <<< "$result"
    assert_eq "$rc" "1" "empty credential chain returns 1"
    assert_eq "$status" "no_credentials" "empty credential chain reports status=no_credentials"
    assert_contains "$diag" "could not locate credentials" "no_credentials diagnostic names the locate-credentials failure"
}

test_recovers_from_polluted_ambient_via_secret_file() {
    # The regression case. Ambient key is rejected; the secret file holds the
    # good key. Must RECOVER, export the good creds, and name the pollution.
    local mock_dir secret_file result rc status account source diag
    mock_dir="$(new_mock_command_dir "aws" "$(mock_aws_body)")"
    secret_file="$(mktemp)"
    printf 'AWS_ACCESS_KEY_ID=GOODKEY\nAWS_SECRET_ACCESS_KEY=goodsecret\n' > "$secret_file"

    result="$(run_ensure "$mock_dir" "$secret_file" \
        AWS_ID_MOCK_MODE=key_gated AWS_ID_MOCK_GOOD_KEY=GOODKEY \
        AWS_ACCESS_KEY_ID=BADKEY AWS_SECRET_ACCESS_KEY=badsecret)"

    rm -rf "$mock_dir" "$secret_file"
    IFS='|' read -r rc status account source diag <<< "$result"
    assert_eq "$rc" "0" "polluted ambient + valid secret key recovers (returns 0)"
    assert_eq "$status" "recovered" "polluted ambient + valid secret key reports status=recovered"
    assert_eq "$account" "999999999999" "recovery uses the secret-file key's identity"
    assert_contains "$diag" "pollution" "recovery diagnostic names environment pollution, not a dead credential"
}

test_recovery_failure_when_secret_key_also_rejected() {
    # Ambient AND secret-file keys both rejected — no false recovery.
    local mock_dir secret_file result rc status
    mock_dir="$(new_mock_command_dir "aws" "$(mock_aws_body)")"
    secret_file="$(mktemp)"
    printf 'AWS_ACCESS_KEY_ID=ALSOBAD\nAWS_SECRET_ACCESS_KEY=s\n' > "$secret_file"

    result="$(run_ensure "$mock_dir" "$secret_file" \
        AWS_ID_MOCK_MODE=key_gated AWS_ID_MOCK_GOOD_KEY=GOODKEY \
        AWS_ACCESS_KEY_ID=BADKEY AWS_SECRET_ACCESS_KEY=s)"

    rm -rf "$mock_dir" "$secret_file"
    IFS='|' read -r rc status _ _ _ <<< "$result"
    assert_eq "$rc" "1" "both-keys-rejected returns 1 (no false recovery)"
    assert_eq "$status" "invalid_credentials" "both-keys-rejected reports status=invalid_credentials"
}

test_is_valid_wrapper_true_on_recovery() {
    local mock_dir secret_file rc
    mock_dir="$(new_mock_command_dir "aws" "$(mock_aws_body)")"
    secret_file="$(mktemp)"
    printf 'AWS_ACCESS_KEY_ID=GOODKEY\nAWS_SECRET_ACCESS_KEY=goodsecret\n' > "$secret_file"
    rc="$(
        export PATH="$mock_dir:$PATH"
        unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN FJCLOUD_SECRET_FILE
        export AWS_ID_MOCK_MODE=key_gated AWS_ID_MOCK_GOOD_KEY=GOODKEY
        export AWS_ACCESS_KEY_ID=BADKEY AWS_SECRET_ACCESS_KEY=b
        if aws_identity_is_valid "$secret_file" >/dev/null 2>&1; then echo 0; else echo 1; fi
    )"
    rm -rf "$mock_dir" "$secret_file"
    assert_eq "$rc" "0" "aws_identity_is_valid returns true (0) when identity is recovered"
}

test_valid_ambient_identity_passes
test_missing_cli_reports_cli_missing
test_no_credentials_without_secret_file_reports_no_credentials
test_recovers_from_polluted_ambient_via_secret_file
test_recovery_failure_when_secret_key_also_rejected
test_is_valid_wrapper_true_on_recovery

echo "----"
echo "aws_identity_test: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
