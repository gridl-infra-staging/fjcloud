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
mode="${STAGE4_REHEARSAL_FIXTURE_MODE:-happy}"
call_log="${STAGE4_REHEARSAL_CALL_LOG:-}"

env_file=""
month=""
confirm=0
reset_mode=0
confirm_test_tenant=""
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
        --reset-test-state)
            reset_mode=1
            shift
            ;;
        --confirm-test-tenant)
            confirm_test_tenant="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -n "$call_log" ]]; then
    printf 'reset_mode=%s confirm=%s month=%s tenant=%s env_file=%s\n' \
        "$reset_mode" "$confirm" "$month" "$confirm_test_tenant" "$env_file" >> "$call_log"
fi

if [[ "$reset_mode" == "1" ]]; then
    cat <<JSON
{"result":"passed","classification":"reset_completed","detail":"ok","artifact_dir":""}
JSON
    exit 0
fi

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

if [[ "$mode" == "transition_ids_missing" ]]; then
    cat > "$artifact_dir/invoice_rows.json" <<JSON
{"name":"invoice_rows","result":"passed","classification":"invoice_rows_ready","detail":"ok","payload":{"required_invoice_ids":["inv_suspended_001","inv_failed_001","inv_recovered_001"],"rows":[{"invoice_id":"inv_failed_001","email":"alpha@example.test"},{"invoice_id":"inv_suspended_001","email":"alpha@example.test"},{"invoice_id":"inv_recovered_001","email":"alpha@example.test"}]}}
JSON
    cat > "$artifact_dir/webhook.json" <<JSON
{"name":"webhook","result":"passed","classification":"webhook_ready","detail":"ok","payload":{"required_invoice_ids":["inv_suspended_001","inv_failed_001","inv_recovered_001"]}}
JSON
fi

if [[ "$mode" == "transition_ids_missing_live_shape" ]]; then
    cat > "$artifact_dir/invoice_rows.json" <<JSON
{"name":"invoice_rows","result":"passed","classification":"invoice_rows_ready","detail":"ok","payload":{"required_invoice_ids":["inv_failed_001","inv_recovered_001"],"rows":[{"invoice_id":"inv_failed_001","stripe_invoice_id":"in_failed_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_failed_opaque_url","email":"alpha@example.test"},{"invoice_id":"inv_recovered_001","stripe_invoice_id":"in_recovered_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_recovered_opaque_url","email":"alpha@example.test"}]}}
JSON
    cat > "$artifact_dir/webhook.json" <<JSON
{"name":"webhook","result":"passed","classification":"webhook_ready","detail":"ok","payload":{"required_invoice_ids":["inv_failed_001","inv_recovered_001"],"rows":[{"invoice_id":"inv_failed_001","stripe_invoice_id":"in_failed_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_failed_opaque_url"},{"invoice_id":"inv_recovered_001","stripe_invoice_id":"in_recovered_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_recovered_opaque_url"}]}}
JSON
fi

if [[ "$mode" == "transition_ids_present_live_shape" ]]; then
    cat > "$artifact_dir/invoice_rows.json" <<JSON
{"name":"invoice_rows","result":"passed","classification":"invoice_rows_ready","detail":"ok","payload":{"required_invoice_ids":["inv_failed_001","inv_suspended_001"],"rows":[{"invoice_id":"inv_failed_001","stripe_invoice_id":"in_failed_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_failed_opaque_url","email":"alpha@example.test"},{"invoice_id":"inv_suspended_001","stripe_invoice_id":"in_suspended_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_suspended_opaque_url","email":"alpha@example.test"}],"transition_invoice_ids":{"failed":"inv_failed_001","suspended":"inv_suspended_001","recovered":"inv_failed_001"}}}
JSON
    cat > "$artifact_dir/webhook.json" <<JSON
{"name":"webhook","result":"passed","classification":"webhook_ready","detail":"ok","payload":{"required_invoice_ids":["inv_failed_001","inv_suspended_001"],"rows":[{"invoice_id":"inv_failed_001","stripe_invoice_id":"in_failed_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_failed_opaque_url"},{"invoice_id":"inv_suspended_001","stripe_invoice_id":"in_suspended_live_001","hosted_invoice_url":"https://invoice.stripe.com/i/acct_test/live_suspended_opaque_url"}],"transition_invoice_ids":{"failed":"inv_failed_001","suspended":"inv_suspended_001","recovered":"inv_failed_001"}}}
JSON
fi

if [[ "$mode" == "transition_ids_missing_no_invoice_ids" ]]; then
    cat > "$artifact_dir/invoice_rows.json" <<JSON
{"name":"invoice_rows","result":"passed","classification":"invoice_rows_ready","detail":"ok","payload":{"required_invoice_ids":[],"rows":[]}}
JSON
    cat > "$artifact_dir/webhook.json" <<JSON
{"name":"webhook","result":"passed","classification":"webhook_ready","detail":"ok","payload":{"required_invoice_ids":[]}}
JSON
fi

if [[ "$mode" == "invoice_email_delegated" ]]; then
    cat <<JSON
{"result":"failed","classification":"invoice_email_evidence_delegated","detail":"MAILPIT_API_URL is not configured; staging runtime invoice email evidence remains delegated to SES-backed proof.","artifact_dir":"$artifact_dir"}
JSON
    exit 1
fi

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

if [[ "${AWS_ACCESS_KEY_ID:-}" == "stale-parent-key" ]]; then
    echo "stale parent AWS credential reached mock AWS" >&2
    exit 97
fi

if [[ "${1:-}" == "s3api" && "${2:-}" == "list-objects-v2" ]]; then
    if [[ "$mode" == "no_inbound_messages" ]]; then
        cat <<JSON
{"Contents":[]}
JSON
        exit 0
    fi
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
    if [[ "$mode" == "two_invoice_transition_messages" && "$key" == *suspended.eml ]]; then
        body_invoice_id="inv_failed_001"
    fi
    if [[ "$mode" == "stripe_hosted_body" ]]; then
        case "$key" in
            *failed.eml)  body_invoice_id="https://invoice.stripe.com/i/acct_test/live_failed_opaque_url" ;;
            *suspended.eml) body_invoice_id="https://invoice.stripe.com/i/acct_test/live_failed_opaque_url" ;;
            *recovered.eml) body_invoice_id="https://invoice.stripe.com/i/acct_test/live_recovered_opaque_url" ;;
        esac
    fi
    if [[ "$mode" == "single_invoice_replay_messages" ]]; then
        body_invoice_id="inv_failed_001"
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

if [[ "${1:-}" == "ssm" && "${2:-}" == "get-parameter" ]]; then
    name=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --name)
                name="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    case "$name" in
        */admin_key)
            printf '%s\n' "staging-admin-contract"
            ;;
        */database_url)
            printf '%s\n' "postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev"
            ;;
        */dns_domain)
            printf '%s\n' "staging.example.test"
            ;;
        */stripe_secret_key)
            printf '%s\n' "sk_test_rehearsal_contract"
            ;;
        */ses_from_address)
            printf '%s\n' "system@example.test"
            ;;
        */stripe_webhook_secret)
            printf '%s\n' "whsec_rehearsal_contract"
            ;;
        *)
            printf '%s\n' "None"
            ;;
    esac
    exit 0
fi

echo "unexpected aws command: $*" >&2
exit 91
MOCK
    chmod +x "$path"
}

create_mock_replay_fixture() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
call_log="${STAGE4_REPLAY_CALL_LOG:-}"
if [[ -n "$call_log" ]]; then
    printf '%s\n' "$*" >> "$call_log"
fi
cat <<JSON
{"result":"passed","classification":"webhook_post_succeeded","mode":"run","target_url":"https://api.staging.flapjack.foo/webhooks/stripe","stripe_webhook_secret":"REDACTED","event_id":"evt_mock","timestamp":"1704067200","payload":"<omitted in run mode>","stripe_signature":"<omitted in run mode>","detail":"webhook endpoint returned HTTP 200","steps":[],"elapsed_ms":1}
JSON
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
    run_validator_with_args "$mode" "$env_file" "$mock_dir" "$rehearsal_script" \
        --env-file "$env_file" \
        --month 2026-03 \
        --confirm-live-mutation
}

run_validator_with_args() {
    local mode="$1" env_file="$2" mock_dir="$3" rehearsal_script="$4"
    shift 4
    DUNNING_VALIDATOR_MOCK_MODE="$mode" \
        STAGE4_REHEARSAL_FIXTURE_MODE="${STAGE4_REHEARSAL_FIXTURE_MODE:-happy}" \
        STAGING_DUNNING_REHEARSAL_SCRIPT="$rehearsal_script" \
        STAGING_DB_QUERY_SCRIPT="${STAGING_DB_QUERY_SCRIPT:-/nonexistent/ssm_exec_staging.sh}" \
        PATH="$mock_dir:$PATH" \
        TMPDIR="$mock_dir" \
        bash "$REPO_ROOT/scripts/validate_staging_dunning_delivery.sh" \
            "$@" 2>&1
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

test_validator_resets_allowlisted_tenants_before_live_mutation() {
    local mock_dir env_file rehearsal_script output exit_code call_log calls
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    call_log="$mock_dir/rehearsal_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'FJCLOUD_TEST_TENANT_IDS=11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(STAGE4_REHEARSAL_CALL_LOG="$call_log" run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?
    calls="$(cat "$call_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should still pass when allowlisted reset runs first"
    assert_valid_json "$output" "allowlisted reset output should be valid JSON"
    assert_contains "$calls" "reset_mode=1 confirm=0 month=2026-03 tenant=11111111-1111-1111-1111-111111111111" \
        "validator should reset the first allowlisted tenant before live mutation"
    assert_contains "$calls" "reset_mode=1 confirm=0 month=2026-03 tenant=22222222-2222-2222-2222-222222222222" \
        "validator should reset the second allowlisted tenant before live mutation"
    assert_contains "$calls" "reset_mode=0 confirm=1 month=2026-03 tenant=" \
        "validator should still invoke the live mutation rehearsal after resets"
}

test_validator_clears_stale_parent_aws_before_hydration() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(AWS_ACCESS_KEY_ID=stale-parent-key run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" \
        "validator should ignore stale caller AWS credentials when hydrating canonical staging env"
    assert_valid_json "$output" "stale-parent-aws output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" \
        "validator should get past SSM hydration with env-file/mock AWS credentials"
    assert_not_contains "$output" "staging_ssm_hydration_failed" \
        "stale caller AWS credentials must not block validator hydration"
}

test_validator_accepts_rehearsal_delegated_invoice_email_evidence() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(STAGE4_REHEARSAL_FIXTURE_MODE=invoice_email_delegated run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should continue when rehearsal delegates invoice email evidence to SES/S3"
    assert_valid_json "$output" "delegated invoice email output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "delegated invoice email path should still verify dunning delivery"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "delegated invoice email path should preserve validator success classifier"
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

test_validator_derives_staging_api_url_from_api_url_when_missing() {
    # Repo-curated .env.secret files set API_URL but not STAGING_API_URL — the
    # staging hydration contract at scripts/launch/hydrate_seeder_env_from_ssm.sh
    # defines STAGING_API_URL="${API_URL}". The validator must honor that
    # contract so the prescribed env file does not get rejected as
    # non_staging_api_hostname.
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    cat > "$env_file" <<ENVFILE
API_URL=https://api.flapjack.foo
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/run-001/
SES_REGION=us-east-1
ENVFILE
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should derive STAGING_API_URL from API_URL when the env file only sets API_URL"
    assert_valid_json "$output" "API_URL-fallback output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "validator should pass when STAGING_API_URL is derived from API_URL"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "API_URL-fallback should still verify dunning delivery end-to-end"
}

test_validator_blocks_when_both_staging_api_url_and_api_url_are_missing() {
    # Defense-in-depth: when neither STAGING_API_URL nor API_URL is set, the
    # validator must still fail closed with the stable non_staging_api_hostname
    # classification so SSM re-runs can distinguish "missing contract" from
    # "non-staging hostname" failure modes via the detail field.
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    cat > "$env_file" <<ENVFILE
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/run-001/
SES_REGION=us-east-1
ENVFILE
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail closed when neither STAGING_API_URL nor API_URL is set"
    assert_valid_json "$output" "missing-both-urls output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "non_staging_api_hostname" "missing-both-urls should keep the stable hostname classifier"
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

test_validator_requires_explicit_month_and_confirmation() {
    local mock_dir env_file rehearsal_script missing_month_output missing_month_exit missing_confirm_output missing_confirm_exit
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    missing_month_output="$(
        run_validator_with_args happy "$env_file" "$mock_dir" "$rehearsal_script" \
            --env-file "$env_file" \
            --confirm-live-mutation
    )" || missing_month_exit=$?

    missing_confirm_output="$(
        run_validator_with_args happy "$env_file" "$mock_dir" "$rehearsal_script" \
            --env-file "$env_file" \
            --month 2026-03
    )" || missing_confirm_exit=$?

    rm -rf "$mock_dir"

    assert_eq "${missing_month_exit:-0}" "1" "validator should fail closed when month is missing"
    assert_valid_json "$missing_month_output" "missing-month output should be valid JSON"
    assert_eq "$(json_field "$missing_month_output" "result")" "blocked" "missing month should block live mutation"
    assert_eq "$(json_field "$missing_month_output" "classification")" "live_mutation_confirmation_required" "missing month should emit stable guard classification"

    assert_eq "${missing_confirm_exit:-0}" "1" "validator should fail closed when confirmation flag is missing"
    assert_valid_json "$missing_confirm_output" "missing-confirm output should be valid JSON"
    assert_eq "$(json_field "$missing_confirm_output" "result")" "blocked" "missing confirmation should block live mutation"
    assert_eq "$(json_field "$missing_confirm_output" "classification")" "live_mutation_confirmation_required" "missing confirmation should emit stable guard classification"
}

test_validator_rejects_repo_default_env_filename() {
    local mock_dir default_env rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    default_env="$mock_dir/.env.local"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$default_env" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(
        run_validator_with_args happy "$default_env" "$mock_dir" "$rehearsal_script" \
            --env-file "$default_env" \
            --month 2026-03 \
            --confirm-live-mutation
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should reject repo-default env filenames"
    assert_valid_json "$output" "repo-default-env output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "blocked" "repo-default env filename should block execution"
    assert_eq "$(json_field "$output" "classification")" "repo_default_env_file_rejected" "repo-default env filename should emit stable guard classification"
}

test_validator_reports_rehearsal_owner_failure_details() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/failing_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_aws "$mock_dir/aws"
    cat > "$rehearsal_script" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"result":"failed","classification":"billing_run_no_created_invoices","detail":"Batch billing response had no created invoice IDs"}
JSON
exit 1
MOCK
    chmod +x "$rehearsal_script"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?
    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when rehearsal owner exits non-zero"
    assert_valid_json "$output" "rehearsal failure output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "failed" "rehearsal failure should emit failed result"
    assert_eq "$(json_field "$output" "classification")" "rehearsal_failed" "rehearsal failure should map to stable validator classification"
    assert_contains "$output" "billing_run_no_created_invoices" "rehearsal failure details should preserve owner-side classification for diagnosis"
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

test_validator_fails_when_inbound_message_listing_is_empty() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator no_inbound_messages "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when inbound RFC822 listing is empty"
    assert_valid_json "$output" "empty inbound listing output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "failed" "empty inbound listing should emit failed result"
    assert_eq "$(json_field "$output" "classification")" "inbound_messages_missing" "empty inbound listing should emit stable classification"
    assert_eq "$(json_transition_field "$output" "failed" "result")" "" "transition assertions should not run when no inbound objects are listed"
}

test_validator_fails_when_transition_invoice_mapping_is_missing() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_no_invoice_ids \
            run_validator happy "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when rehearsal artifacts omit transition invoice mapping"
    assert_valid_json "$output" "missing-transition-map output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "failed" "missing-transition-map should emit failed result"
    assert_eq "$(json_field "$output" "classification")" "transition_invoice_mapping_missing" "missing-transition-map should emit stable classification"
}

test_validator_derives_transition_invoice_ids_from_inbound_messages_when_rehearsal_map_is_missing() {
    local mock_dir env_file rehearsal_script replay_script replay_log output exit_code replay_calls
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?
    replay_calls="$(cat "$replay_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should derive transition invoice ids from matching inbound messages"
    assert_valid_json "$output" "derived-transition-map output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "derived-transition-map output should preserve success classification"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_failed --next-payment-attempt" \
        "validator should replay retry-scheduled payment failure through the existing webhook fixture"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_failed --next-payment-attempt null --attempt-count 2" \
        "validator should replay exhausted payment failure through the existing webhook fixture"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_succeeded" \
        "validator should replay recovery payment success through the existing webhook fixture"
    assert_eq "$(json_transition_field "$output" "failed" "invoice_id")" "inv_failed_001" "failed transition should bind to the failed invoice id"
    assert_eq "$(json_transition_field "$output" "suspended" "invoice_id")" "inv_failed_001" "suspended transition may share the failed invoice id in live artifacts"
    assert_eq "$(json_transition_field "$output" "recovered" "invoice_id")" "inv_recovered_001" "recovered transition should bind to the recovered invoice id"
}

test_validator_replays_dunning_webhooks_when_transition_map_is_present() {
    local mock_dir env_file rehearsal_script replay_script replay_log psql_log output exit_code replay_calls psql_calls
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"
    psql_log="$mock_dir/psql_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$psql_log"
done
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_present_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            run_validator single_invoice_replay_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?
    replay_calls="$(cat "$replay_log" 2>/dev/null || true)"
    psql_calls="$(cat "$psql_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should pass after replaying dunning webhooks even when transition map exists"
    assert_valid_json "$output" "transition-map-replay output should be valid JSON"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_failed --next-payment-attempt" \
        "validator must replay retry-scheduled payment failure when rehearsal already includes transition_invoice_ids"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_failed --next-payment-attempt null --attempt-count 2" \
        "validator must replay retries-exhausted payment failure when rehearsal already includes transition_invoice_ids"
    assert_contains "$replay_calls" "--invoice-id in_failed_live_001 --event-type invoice.payment_succeeded" \
        "validator must replay recovery payment success when rehearsal already includes transition_invoice_ids"
    assert_contains "$psql_calls" "status = 'finalized'" \
        "validator must reset the replay invoice before replay even when transition map exists"
    assert_eq "$(json_transition_field "$output" "failed" "invoice_id")" "inv_failed_001" \
        "failed transition should assert against the replay target invoice"
    assert_eq "$(json_transition_field "$output" "suspended" "invoice_id")" "inv_failed_001" \
        "suspended transition should assert against the replay target invoice generated by retry exhaustion"
    assert_eq "$(json_transition_field "$output" "recovered" "invoice_id")" "inv_failed_001" \
        "recovered transition should assert against the replay target invoice generated by recovery replay"
}

test_validator_defaults_inbound_scope_when_env_omits_optional_inbox_vars() {
    local mock_dir env_file rehearsal_script output exit_code artifact_dir inbound_scope
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"

    cat > "$env_file" <<ENVFILE
API_URL=https://api.flapjack.foo
ENVFILE
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?
    artifact_dir="$(json_field "$output" "artifact_dir")"
    inbound_scope="$(cat "$artifact_dir/inbound_s3_scope.txt" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should use canonical inbound defaults when optional inbox vars are omitted"
    assert_valid_json "$output" "default-inbound-scope output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "default-inbound-scope should emit passed result"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "default-inbound-scope should still verify dunning delivery"
    assert_contains "$inbound_scope" "region=us-east-1" "validator should persist the default SES region for the clickthrough wrapper"
    assert_contains "$inbound_scope" "s3_uri=s3://flapjack-cloud-releases/e2e-emails/" "validator should persist the default inbound S3 URI for the clickthrough wrapper"
}

create_failing_reset_mock_rehearsal() {
    # Writes a rehearsal mock that, when invoked with --reset-test-state, returns a
    # JSON failure payload mirroring the real staging_billing_rehearsal.sh contract for
    # an unreachable reset DB. Non-reset invocations return passed (they should never
    # run, because the validator must short-circuit on the reset failure).
    local path="$1" exit_code="$2"
    cat > "$path" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
reset_mode=0
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --reset-test-state) reset_mode=1; shift;;
        *) shift;;
    esac
done

if [[ "\$reset_mode" == "1" ]]; then
    cat <<'JSON'
{"result":"blocked","classification":"reset_customer_lookup_query_failed","detail":"psql exit 21: could not connect to Postgres at staging-rds.internal"}
JSON
    exit ${exit_code}
fi

cat <<'JSON'
{"result":"passed","classification":"rehearsal_completed","detail":"ok","artifact_dir":""}
JSON
exit 0
MOCK
    chmod +x "$path"
}

test_validator_propagates_nested_reset_classification() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/failing_reset_rehearsal.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'FJCLOUD_TEST_TENANT_IDS=11111111-1111-1111-1111-111111111111\n' >> "$env_file"
    create_failing_reset_mock_rehearsal "$rehearsal_script" 1
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when reset rehearsal blocks"
    assert_valid_json "$output" "reset propagation output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "failed" "reset failure should emit failed result"
    assert_eq "$(json_field "$output" "classification")" "rehearsal_reset_failed" \
        "outer classification should remain rehearsal_reset_failed (stable contract)"
    local detail
    detail="$(json_field "$output" "detail")"
    assert_contains "$detail" "reset_customer_lookup_query_failed" \
        "top-level detail must include nested rehearsal classification (currently swallowed)"
    assert_contains "$detail" "could not connect to Postgres" \
        "top-level detail must include nested rehearsal detail for diagnosis"
}

test_validator_resets_invoice_status_before_dunning_replay() {
    local mock_dir env_file rehearsal_script replay_script replay_log psql_log output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"
    psql_log="$mock_dir/psql_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$psql_log"
done
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?
    local psql_calls replay_calls
    psql_calls="$(cat "$psql_log" 2>/dev/null || true)"
    replay_calls="$(cat "$replay_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should pass when invoice status is reset before replay"
    assert_valid_json "$output" "invoice-reset-before-replay output should be valid JSON"
    assert_contains "$psql_calls" "UPDATE invoices SET status" \
        "validator must reset invoice status to finalized before dunning webhook replay"
    assert_contains "$psql_calls" "paid_at = NULL" \
        "validator must clear paid_at before dunning webhook replay"
    assert_contains "$replay_calls" "--event-type invoice.payment_failed" \
        "replay must still run after invoice status reset"
}

test_validator_restores_invoice_status_after_replay_failure() {
    local mock_dir env_file rehearsal_script replay_script replay_log psql_log output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"
    psql_log="$mock_dir/psql_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"

    # Failing replay fixture: logs invocation then exits non-zero on first call.
    cat > "$replay_script" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
call_log="\${STAGE4_REPLAY_CALL_LOG:-}"
if [[ -n "\$call_log" ]]; then
    printf '%s\n' "\$*" >> "\$call_log"
fi
exit 1
MOCK
    chmod +x "$replay_script"

    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$psql_log"
done
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?
    local psql_calls
    psql_calls="$(cat "$psql_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_ne "${exit_code:-0}" "0" "validator must exit non-zero when dunning replay fails"
    assert_eq "$(json_field "$output" "classification")" "dunning_webhook_replay_failed" \
        "classification must surface dunning replay failure"
    assert_contains "$psql_calls" "status = 'finalized'" \
        "validator must still record the pre-replay reset SQL even on failure"
    assert_contains "$psql_calls" "status = 'paid'" \
        "validator must restore invoice status to paid even when dunning replay fails, so staging is not left in 'finalized'"
}

test_validator_resets_invoice_status_before_replay_then_restores_after() {
    local mock_dir env_file rehearsal_script replay_script replay_log psql_log output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"
    psql_log="$mock_dir/psql_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$psql_log"
done
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?
    local psql_calls
    psql_calls="$(cat "$psql_log" 2>/dev/null || true)"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should pass with restore step"
    assert_contains "$psql_calls" "status = 'paid'" \
        "validator must restore invoice status to paid after dunning replay completes"
}

test_validator_matches_dunning_emails_with_stripe_hosted_url() {
    local mock_dir env_file rehearsal_script replay_script replay_log output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    cat > "$mock_dir/psql" <<'MOCK'
#!/usr/bin/env bash
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            run_validator stripe_hosted_body "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" \
        "validator should match dunning emails even when body contains Stripe hosted URL instead of fjcloud UUID"
    assert_valid_json "$output" "stripe-hosted-body output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" \
        "validator must accept Stripe hosted invoice URL in email body as a valid invoice match"
    assert_eq "$(json_transition_field "$output" "failed" "result")" "passed" \
        "failed transition should pass when body contains Stripe invoice ID from hosted URL"
    assert_eq "$(json_transition_field "$output" "suspended" "result")" "passed" \
        "suspended transition should pass when body contains Stripe invoice ID from hosted URL"
    assert_eq "$(json_transition_field "$output" "recovered" "result")" "passed" \
        "recovered transition should pass when body contains Stripe invoice ID from hosted URL"
}

test_validator_reset_db_unreachable_emits_precondition_classification() {
    local mock_dir env_file rehearsal_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/failing_reset_rehearsal_21.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'FJCLOUD_TEST_TENANT_IDS=11111111-1111-1111-1111-111111111111\n' >> "$env_file"
    create_failing_reset_mock_rehearsal "$rehearsal_script" 21
    create_mock_aws "$mock_dir/aws"

    output="$(run_validator happy "$env_file" "$mock_dir" "$rehearsal_script")" || exit_code=$?

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "1" "validator should fail when rehearsal exits with psql connection code"
    assert_valid_json "$output" "reset psql-unreachable output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "rehearsal_reset_failed" \
        "outer classification should remain rehearsal_reset_failed for psql exit 21"
    local detail
    detail="$(json_field "$output" "detail")"
    assert_contains "$detail" "reset_customer_lookup_query_failed" \
        "top-level detail must carry the nested classification so SSM in-VPC re-runs can distinguish db-unreachable from bad tenant"
}

test_validator_fails_with_reset_unavailable_when_no_db_access() {
    local mock_dir env_file rehearsal_script replay_script output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"

    write_env_file "$env_file" "https://api.flapjack.foo"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"
    create_mock_aws "$mock_dir/aws"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=0 \
            STAGING_DB_QUERY_SCRIPT="/nonexistent/ssm_exec_staging.sh" \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?

    rm -rf "$mock_dir"

    assert_ne "${exit_code:-0}" "0" "validator must fail when no DB access is available for invoice reset"
    assert_valid_json "$output" "no-db-access output should be valid JSON"
    assert_eq "$(json_field "$output" "classification")" "dunning_invoice_reset_unavailable" \
        "classification must be dunning_invoice_reset_unavailable when neither DB URL nor SSM script is accessible"
}

test_validator_polls_s3_until_dunning_emails_arrive() {
    local mock_dir env_file rehearsal_script replay_script replay_log psql_log output exit_code
    mock_dir="$(mktemp -d)"
    env_file="$mock_dir/staging.env"
    rehearsal_script="$mock_dir/mock_rehearsal.sh"
    replay_script="$mock_dir/mock_replay_fixture.sh"
    replay_log="$mock_dir/replay_calls.log"
    psql_log="$mock_dir/psql_calls.log"
    local s3_list_call_count_file="$mock_dir/s3_list_call_count"
    echo "0" > "$s3_list_call_count_file"

    write_env_file "$env_file" "https://api.flapjack.foo"
    printf 'DATABASE_URL=postgres://mock:mock@localhost:15432/fjcloud_test\n' >> "$env_file"
    create_mock_rehearsal_runner "$rehearsal_script"
    create_mock_replay_fixture "$replay_script"

    cat > "$mock_dir/psql" <<MOCK
#!/usr/bin/env bash
for arg in "\$@"; do
    printf '%s\n' "\$arg" >> "$psql_log"
done
echo "UPDATE 1"
exit 0
MOCK
    chmod +x "$mock_dir/psql"

    cat > "$mock_dir/aws" <<MOCK
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "s3api" && "\${2:-}" == "list-objects-v2" ]]; then
    count=\$(cat "$s3_list_call_count_file")
    count=\$((count + 1))
    echo "\$count" > "$s3_list_call_count_file"
    # Call 1 (pre-replay): 1 placeholder key so the validator passes the non-empty gate.
    # Call 2 (1st post-replay poll): still 1 key — dunning emails not yet delivered.
    # Call 3+ (2nd post-replay poll): 4 keys — placeholder + 3 dunning emails.
    if [[ \$count -le 2 ]]; then
        cat <<JSON
{"Contents":[
  {"Key":"e2e-emails/run-001/placeholder.eml","LastModified":"2026-05-16T00:59:00Z"}
]}
JSON
        exit 0
    fi
    cat <<JSON
{"Contents":[
  {"Key":"e2e-emails/run-001/placeholder.eml","LastModified":"2026-05-16T00:59:00Z"},
  {"Key":"e2e-emails/run-001/failed.eml","LastModified":"2026-05-16T01:00:00Z"},
  {"Key":"e2e-emails/run-001/suspended.eml","LastModified":"2026-05-16T01:00:01Z"},
  {"Key":"e2e-emails/run-001/recovered.eml","LastModified":"2026-05-16T01:00:02Z"}
]}
JSON
    exit 0
fi

if [[ "\${1:-}" == "s3api" && "\${2:-}" == "get-object" ]]; then
    output_path="\${@: -1}"
    key=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --key) key="\$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "\$key" in
        *placeholder.eml) subject="Monthly Invoice"; body_invoice_id="inv_other_999" ;;
        *failed.eml)      subject="Payment retry scheduled"; body_invoice_id="https://invoice.stripe.com/i/acct_test/live_failed_opaque_url" ;;
        *suspended.eml)   subject="Payment retries exhausted"; body_invoice_id="https://invoice.stripe.com/i/acct_test/live_failed_opaque_url" ;;
        *recovered.eml)   subject="Payment recovered"; body_invoice_id="https://invoice.stripe.com/i/acct_test/live_recovered_opaque_url" ;;
        *) echo "unexpected key: \$key" >&2; exit 90 ;;
    esac
    cat > "\$output_path" <<RFC822
From: sender@example.com
To: receiver@example.com
Subject: \$subject

Invoice reference: \$body_invoice_id
RFC822
    cat <<JSON
{"ETag":"mock"}
JSON
    exit 0
fi

if [[ "\${1:-}" == "ssm" && "\${2:-}" == "get-parameter" ]]; then
    name=""
    while [ "\$#" -gt 0 ]; do
        case "\$1" in
            --name) name="\$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    case "\$name" in
        */admin_key) printf '%s\n' "staging-admin-contract" ;;
        */database_url) printf '%s\n' "postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" ;;
        */dns_domain) printf '%s\n' "staging.example.test" ;;
        */stripe_secret_key) printf '%s\n' "sk_test_rehearsal_contract" ;;
        */ses_from_address) printf '%s\n' "system@example.test" ;;
        */stripe_webhook_secret) printf '%s\n' "whsec_rehearsal_contract" ;;
        *) printf '%s\n' "None" ;;
    esac
    exit 0
fi
echo "unexpected aws command: \$*" >&2
exit 91
MOCK
    chmod +x "$mock_dir/aws"

    output="$(
        STAGE4_REHEARSAL_FIXTURE_MODE=transition_ids_missing_live_shape \
            STAGE4_REPLAY_CALL_LOG="$replay_log" \
            STAGING_DUNNING_REPLAY_FIXTURE_SCRIPT="$replay_script" \
            STAGING_DUNNING_REPLAY_INBOX_SETTLE_SECONDS=1 \
            STAGING_DUNNING_REPLAY_INBOX_POLL_TIMEOUT_SECONDS=10 \
            STAGING_DUNNING_REPLAY_INBOX_POLL_INTERVAL_SECONDS=0 \
            run_validator two_invoice_transition_messages "$env_file" "$mock_dir" "$rehearsal_script"
    )" || exit_code=$?

    local s3_call_count
    s3_call_count="$(cat "$s3_list_call_count_file")"

    rm -rf "$mock_dir"

    assert_eq "${exit_code:-0}" "0" "validator should pass after polling finds delayed dunning emails"
    assert_valid_json "$output" "delayed-delivery polling output should be valid JSON"
    assert_eq "$(json_field "$output" "result")" "passed" "validator should verify dunning delivery after polling"
    assert_eq "$(json_field "$output" "classification")" "dunning_delivery_verified" "classification should be dunning_delivery_verified after polling"
    if [[ "$s3_call_count" -lt 3 ]]; then
        fail "validator must poll S3 more than once when first post-replay listing is empty (got $s3_call_count calls)"
    else
        pass "validator polled S3 $s3_call_count times before finding dunning emails"
    fi
}

echo "=== validate_staging_dunning_delivery.sh tests ==="
test_validator_happy_path_reports_per_transition_invoice_ids
test_validator_resets_allowlisted_tenants_before_live_mutation
test_validator_clears_stale_parent_aws_before_hydration
test_validator_accepts_rehearsal_delegated_invoice_email_evidence
test_validator_accepts_sanctioned_staging_hostname_contract
test_validator_derives_staging_api_url_from_api_url_when_missing
test_validator_blocks_when_both_staging_api_url_and_api_url_are_missing
test_validator_fails_when_rfc822_subject_assertion_is_missing
test_validator_continues_scanning_after_first_invoice_id_hit
test_validator_requires_explicit_month_and_confirmation
test_validator_rejects_repo_default_env_filename
test_validator_reports_rehearsal_owner_failure_details
test_validator_fails_closed_for_non_staging_hostname
test_validator_fails_when_inbound_message_listing_is_empty
test_validator_fails_when_transition_invoice_mapping_is_missing
test_validator_derives_transition_invoice_ids_from_inbound_messages_when_rehearsal_map_is_missing
test_validator_replays_dunning_webhooks_when_transition_map_is_present
test_validator_defaults_inbound_scope_when_env_omits_optional_inbox_vars
test_validator_resets_invoice_status_before_dunning_replay
test_validator_resets_invoice_status_before_replay_then_restores_after
test_validator_restores_invoice_status_after_replay_failure
test_validator_matches_dunning_emails_with_stripe_hosted_url
test_validator_propagates_nested_reset_classification
test_validator_reset_db_unreachable_emits_precondition_classification
test_validator_fails_with_reset_unavailable_when_no_db_access
test_validator_polls_s3_until_dunning_emails_arrive

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
