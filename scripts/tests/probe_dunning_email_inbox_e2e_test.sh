#!/usr/bin/env bash
# Contract tests for scripts/probe_dunning_email_inbox_e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_dunning_email_inbox_e2e.sh"

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

run_probe() {
    local tmp_dir="$1"
    local env_file="$2"

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        STAGING_DUNNING_VALIDATOR_SCRIPT="$tmp_dir/mock_validator.sh" \
        bash "$PROBE_SCRIPT" "$env_file" --month 2026-05 >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

write_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
STAGING_API_URL=https://api.flapjack.foo
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/run-001/
SES_REGION=us-east-1
ENVFILE
}

write_mock_aws() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "s3api" && "${2:-}" == "get-object" ]]; then
    output_path="${@: -1}"
    key=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --key)
                key="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    if [[ "$key" == *"invoice-link.eml" ]]; then
        cat > "$output_path" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: Payment retry scheduled

Hosted invoice URL: https://invoice.stripe.com/i/acct_test_123?invoice=inv_failed_001
RFC822
    else
        cat > "$output_path" <<'RFC822'
From: sender@example.com
To: receiver@example.com
Subject: Payment retry scheduled

No hosted invoice URL in this fixture.
RFC822
    fi

    cat <<'JSON'
{"ETag":"mock"}
JSON
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 91
MOCK
    chmod +x "$path"
}

write_mock_validator() {
    local path="$1"
    local mode="$2"

    # Build script body in-place so we can embed temporary paths safely.
    case "$mode" in
        success)
            cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${TMPDIR:-/tmp}/probe_dunning_success_${RANDOM}"
mkdir -p "$artifact_dir"
cat > "$artifact_dir/inbound_s3_scope.txt" <<'SCOPE'
region=us-east-1
s3_uri=s3://flapjack-cloud-releases/e2e-emails/run-001/
SCOPE
cat <<JSON
{"result":"passed","classification":"dunning_delivery_verified","artifact_dir":"$artifact_dir","transitions":[{"transition":"failed","s3_object_key":"e2e-emails/run-001/no-link.eml"},{"transition":"recovered","s3_object_key":"e2e-emails/run-001/invoice-link.eml"}]}
JSON
MOCK
            ;;
        owner_failed)
            cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"result":"failed","classification":"billing_run_no_created_invoices","artifact_dir":"","transitions":[]}
JSON
exit 0
MOCK
            ;;
        missing_scope_artifact)
            cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${TMPDIR:-/tmp}/probe_dunning_missing_scope_${RANDOM}"
mkdir -p "$artifact_dir"
cat <<JSON
{"result":"passed","classification":"dunning_delivery_verified","artifact_dir":"$artifact_dir","transitions":[]}
JSON
MOCK
            ;;
        missing_region)
            cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${TMPDIR:-/tmp}/probe_dunning_missing_region_${RANDOM}"
mkdir -p "$artifact_dir"
cat > "$artifact_dir/inbound_s3_scope.txt" <<'SCOPE'
s3_uri=s3://flapjack-cloud-releases/e2e-emails/run-001/
SCOPE
cat <<JSON
{"result":"passed","classification":"dunning_delivery_verified","artifact_dir":"$artifact_dir","transitions":[{"transition":"failed","s3_object_key":"e2e-emails/run-001/invoice-link.eml"}]}
JSON
MOCK
            ;;
        no_hosted_invoice_url)
            cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${TMPDIR:-/tmp}/probe_dunning_no_link_${RANDOM}"
mkdir -p "$artifact_dir"
cat > "$artifact_dir/inbound_s3_scope.txt" <<'SCOPE'
region=us-east-1
s3_uri=s3://flapjack-cloud-releases/e2e-emails/run-001/
SCOPE
cat <<JSON
{"result":"passed","classification":"dunning_delivery_verified","artifact_dir":"$artifact_dir","transitions":[{"transition":"failed","s3_object_key":"e2e-emails/run-001/no-link.eml"}]}
JSON
MOCK
            ;;
        *)
            echo "unknown validator mode: $mode" >&2
            return 1
            ;;
    esac

    chmod +x "$path"
}

test_validator_failure_bubbles_owner_classification() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    mkdir -p "$tmp_dir/bin"
    env_file="$tmp_dir/staging.env"
    write_env_file "$env_file"
    write_mock_validator "$tmp_dir/mock_validator.sh" "owner_failed"
    write_mock_aws "$tmp_dir/bin/aws"

    run_probe "$tmp_dir" "$env_file"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "probe should fail when validator owner result is not passed"
    assert_contains "$RUN_STDERR" "classification='billing_run_no_created_invoices'" "probe should surface owner classification in runtime failure"
}

test_missing_inbound_scope_artifact_fails_closed() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    mkdir -p "$tmp_dir/bin"
    env_file="$tmp_dir/staging.env"
    write_env_file "$env_file"
    write_mock_validator "$tmp_dir/mock_validator.sh" "missing_scope_artifact"
    write_mock_aws "$tmp_dir/bin/aws"

    run_probe "$tmp_dir" "$env_file"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "probe should fail when inbound scope artifact is missing"
    assert_contains "$RUN_STDERR" "expected artifact missing" "probe should emit missing-artifact failure detail"
}

test_missing_region_in_scope_file_is_precondition_failure() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    mkdir -p "$tmp_dir/bin"
    env_file="$tmp_dir/staging.env"
    write_env_file "$env_file"
    write_mock_validator "$tmp_dir/mock_validator.sh" "missing_region"
    write_mock_aws "$tmp_dir/bin/aws"

    run_probe "$tmp_dir" "$env_file"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "3" "probe should precondition-fail when artifact scope omits region"
    assert_contains "$RUN_STDERR" "SES region missing from artifact" "missing-region precondition should be explicit"
}

test_success_emits_terminus_with_hosted_invoice_url() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    mkdir -p "$tmp_dir/bin"
    env_file="$tmp_dir/staging.env"
    write_env_file "$env_file"
    write_mock_validator "$tmp_dir/mock_validator.sh" "success"
    write_mock_aws "$tmp_dir/bin/aws"

    run_probe "$tmp_dir" "$env_file"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "probe should succeed when an RFC822 payload includes hosted invoice URL"
    assert_contains "$RUN_STDOUT" "validator_classification=dunning_delivery_verified" "success output should preserve validator classification"
    assert_contains "$RUN_STDOUT" "TERMINUS: body contains hosted invoice url transition=recovered" "success output should emit required terminus"
    assert_contains "$RUN_STDOUT" "https://invoice.stripe.com/" "terminus output should include hosted invoice URL"
}

test_runtime_failure_when_no_hosted_invoice_url_found() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    mkdir -p "$tmp_dir/bin"
    env_file="$tmp_dir/staging.env"
    write_env_file "$env_file"
    write_mock_validator "$tmp_dir/mock_validator.sh" "no_hosted_invoice_url"
    write_mock_aws "$tmp_dir/bin/aws"

    run_probe "$tmp_dir" "$env_file"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "probe should fail when no hosted invoice URL is found"
    assert_contains "$RUN_STDERR" "did not contain a Stripe hosted invoice URL" "no-link failure should explain missing hosted URL contract"
}

main() {
    echo "=== probe_dunning_email_inbox_e2e tests ==="

    test_validator_failure_bubbles_owner_classification
    test_missing_inbound_scope_artifact_fails_closed
    test_missing_region_in_scope_file_is_precondition_failure
    test_success_emits_terminus_with_hosted_invoice_url
    test_runtime_failure_when_no_hosted_invoice_url_found

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
