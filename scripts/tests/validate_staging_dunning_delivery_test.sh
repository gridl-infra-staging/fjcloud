#!/usr/bin/env bash
# Tests for scripts/validate_staging_dunning_delivery.sh
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

json_field() {
    python3 - "$1" "$2" <<PY
import json
import sys

obj = json.loads(sys.argv[1])
value = obj.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

json_transition_field() {
    local payload="$1" transition="$2" field="$3"
    python3 - "$payload" "$transition" "$field" <<PY 2>/dev/null || echo ""
import json
import sys

payload = json.loads(sys.argv[1])
transition = sys.argv[2]
field = sys.argv[3]
for item in payload.get("transitions", []):
    if item.get("transition") == transition:
        value = item.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

create_mock_rehearsal_runner() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

env_file=""
month=""
confirm=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env-file)
            env_file="$2"
            shift 2
            ;;
        --month)
            month="$2"
            shift 2
            ;;
        --confirm-live-mutation)
            confirm=1
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [ -z "$env_file" ] || [ -z "$month" ] || [ "$confirm" -ne 1 ]; then
    cat <<JSON
{"result":"blocked","classification":"mock_rehearsal_args_invalid","detail":"missing required args","artifact_dir":""}
JSON
    exit 1
fi

artifact_dir="${TMPDIR:-/tmp}/mock_stage3_rehearsal_${RANDOM}"
mkdir -p "$artifact_dir"

cat > "$artifact_dir/invoice_rows.json" <<JSON
{"name":"invoice_rows","result":"passed","classification":"invoice_rows_ready","detail":"ok","payload":{"required_invoice_ids":["inv_suspended_001","inv_failed_001","inv_recovered_001"],"rows":[{"invoice_id":"inv_failed_001","email":"alpha@example.test"},{"invoice_id":"inv_suspended_001","email":"alpha@example.test"},{"invoice_id":"inv_recovered_001","email":"alpha@example.test"}],"transition_invoice_ids":{"failed":"inv_failed_001","suspended":"inv_suspended_001","recovered":"inv_recovered_001"}}}
JSON

cat > "$artifact_dir/webhook.json" <<JSON
{"name":"webhook","result":"passed","classification":"webhook_ready","detail":"ok","payload":{"required_invoice_ids":["inv_suspended_001","inv_failed_001","inv_recovered_001"],"transition_invoice_ids":{"failed":"inv_failed_001","suspended":"inv_suspended_001","recovered":"inv_recovered_001"}}}
JSON

cat <<JSON
{"result":"passed","classification":"rehearsal_completed","detail":"ok","artifact_dir":"$artifact_dir"}
JSON
MOCK
    chmod +x "$path"
}

create_mock_aws() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

mode="${DUNNING_VALIDATOR_MOCK_MODE:-happy}"

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    if [[ "$mode" == "duplicate_invoice_ids" ]]; then
        cat <<JSON
{"Contents":[
  {"Key":"e2e-emails/run-001/failed-wrong-subject.eml","LastModified":"2026-05-16T01:00:00Z"},
  {"Key":"e2e-emails/run-001/failed-correct.eml","LastModified":"2026-05-16T01:00:01Z"},
  {"Key":"e2e-emails/run-001/suspended-correct.eml","LastModified":"2026-05-16T01:00:02Z"},
  {"Key":"e2e-emails/run-001/recovered-correct.eml","LastModified":"2026-05-16T01:00:03Z"}
]}
JSON
        exit 0
    fi
    cat <<JSON
{"Contents":[
  {"Key":"e2e-emails/run-001/failed.eml","LastModified":"2026-05-16T01:00:00Z"},
  {"Key":"e2e-emails/run-001/suspended.eml","LastModified":"2026-05-16T01:00:01Z"},
  {"Key":"e2e-emails/run-001/recovered.eml","LastModified":"2026-05-16T01:00:02Z"}
]}
JSON
    exit 0
fi

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

    case "$key" in
        *failed-wrong-subject.eml)
            subject="Payment retries exhausted"
            body_invoice_id="inv_failed_001"
            ;;
        *failed-correct.eml)
            subject="Payment retry scheduled"
            body_invoice_id="inv_failed_001"
            ;;
        *suspended-correct.eml)
            subject="Payment retries exhausted"
            body_invoice_id="inv_suspended_001"
            ;;
        *recovered-correct.eml)
            subject="Payment recovered"
            body_invoice_id="inv_recovered_001"
            ;;
        *failed.eml)
            subject="Payment retry scheduled"
            body_invoice_id="inv_failed_001"
            ;;
        *suspended.eml)
            subject="Payment retries exhausted"
            body_invoice_id="inv_suspended_001"
            ;;
        *recovered.eml)
            subject="Payment recovered"
            body_invoice_id="inv_recovered_001"
            ;;
        *)
            echo "unexpected key: $key" >&2
            exit 90
            ;;
    esac

    if [[ "$mode" == "subject_mismatch" && "$key" == *suspended.eml ]]; then
        subject="Wrong subject"
    fi
    if [[ "$mode" == "invoice_missing" && "$key" == *recovered.eml ]]; then
        body_invoice_id="not-the-invoice"
    fi

    cat > "$output_path" <<RFC822
From: sender@example.com
To: receiver@example.com
Subject: $subject

Invoice reference: $body_invoice_id
RFC822

    cat <<JSON
{"ETag":"mock"}
JSON
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 91
MOCK
    chmod +x "$path"
}

write_env_file() {
    local path="$1" staging_url="$2"
    cat > "$path" <<ENVFILE
STAGING_API_URL=$staging_url
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/run-001/
SES_REGION=us-east-1
ENVFILE
}

run_validator() {
    local mode="$1" env_file="$2" mock_dir="$3" rehearsal_script="$4"
    DUNNING_VALIDATOR_MOCK_MODE="$mode" \
        STAGING_DUNNING_REHEARSAL_SCRIPT="$rehearsal_script" \
        PATH="$mock_dir:$PATH" \
        TMPDIR="$mock_dir" \
        bash "$REPO_ROOT/scripts/validate_staging_dunning_delivery.sh" \
            --env-file "$env_file" \
            --month 2026-03 \
            --confirm-live-mutation 2>&1
}

test_validator_happy_path_reports_per_transition_invoice_ids() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should pass on happy-path fixtures"
    assert_valid_json "$output" "validator happy output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "validator happy output should report result=passed"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "validator happy output should report verified classification"
    assert_eq "$(json_transition_field "$output" "failed" "invoice_id")" "inv_failed_001" "failed transition should preserve deterministic invoice id"
    assert_eq "$(json_transition_field "$output" "suspended" "invoice_id")" "inv_suspended_001" "suspended transition should preserve deterministic invoice id"
    assert_eq "$(json_transition_field "$output" "recovered" "invoice_id")" "inv_recovered_001" "recovered transition should preserve deterministic invoice id"
    assert_eq "$(json_transition_field "$output" "failed" "result")" "passed" "failed transition should pass on matching subject/body"
    assert_eq "$(json_transition_field "$output" "suspended" "result")" "passed" "suspended transition should pass on matching subject/body"
    assert_eq "$(json_transition_field "$output" "recovered" "result")" "passed" "recovered transition should pass on matching subject/body"
}

test_validator_accepts_sanctioned_staging_hostname_contract() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should accept the sanctioned staging host contract"
    assert_valid_json "$output" "sanctioned staging host output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "validator should pass on sanctioned staging host contract"
}

test_validator_fails_when_rfc822_subject_assertion_is_missing() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://staging-api.example.test"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator subject_mismatch "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when expected RFC822 subject assertion is missing"
    assert_valid_json "$output" "subject mismatch output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_subject_or_body_mismatch" "subject mismatch should emit stable classifier"
    assert_eq "$(json_transition_field "$output" "suspended" "result")" "failed" "suspended transition should fail when subject mismatches"
}

test_validator_continues_scanning_after_first_invoice_id_hit() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator duplicate_invoice_ids "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should continue scanning until subject/body also match the transition"
    assert_valid_json "$output" "duplicate invoice-id output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "duplicate invoice-id fixtures should still validate"
    assert_eq "$(json_transition_field "$output" "failed" "result")" "passed" "failed transition should pass by matching the correct RFC822 object"
    assert_eq "$(json_transition_field "$output" "failed" "s3_object_key")" "e2e-emails/run-001/failed-correct.eml" "failed transition should bind to the subject-correct message"
}

test_validator_fails_closed_for_non_staging_hostname() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.example.test"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail closed for non-staging API hostname"
    assert_valid_json "$output" "non-staging hostname output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "non_staging_api_hostname" "non-staging hostname should emit stable classifier"
}

echo "=== validate_staging_dunning_delivery.sh tests ==="
test_validator_happy_path_reports_per_transition_invoice_ids
test_validator_accepts_sanctioned_staging_hostname_contract
test_validator_fails_when_rfc822_subject_assertion_is_missing
test_validator_continues_scanning_after_first_invoice_id_hit
test_validator_fails_closed_for_non_staging_hostname

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
