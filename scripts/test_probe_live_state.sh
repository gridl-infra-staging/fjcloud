#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "${REPO_ROOT}/scripts/tests/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "${REPO_ROOT}/scripts/tests/lib/assertions.sh"

PROBE_SCRIPT_DEFAULT="${REPO_ROOT}/scripts/probe_live_state.sh"
TMP_PATHS=()
ORDER_MARKER_LINE=0

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

register_tmp_path() {
    local path="$1"
    TMP_PATHS+=("$path")
}

create_temp_bundle_summary() {
    local result_variable="$1" bundle_dir
    bundle_dir="$(mktemp -d)"
    TMP_PATHS+=("$bundle_dir")
    printf -v "$result_variable" '%s' "$bundle_dir/SUMMARY.md"
}

create_stubbed_vendor_tools() {
    local stub_dir="$1"
    mkdir -p "$stub_dir"

    cat > "${stub_dir}/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${AWS_STUB_LOG_PATH:-}" ]; then
    printf '%s\n' "$*" >> "$AWS_STUB_LOG_PATH"
fi

case "${AWS_STUB_SCENARIO:-}" in
    all_degraded)
        exit 2
        ;;
    healthy|fleet_contract|fleet_pointer_missing)
        if [ "${1:-}" = "sts" ] && [ "${2:-}" = "get-caller-identity" ]; then
            cat <<'JSON'
{"UserId":"AIDATEST","Account":"ACCOUNT_PLACEHOLDER","Arn":"arn:aws:iam::ACCOUNT_PLACEHOLDER:user/test"}
JSON
            exit 0
        fi

        if [ "${1:-}" = "sns" ] && [ "${2:-}" = "list-topics" ]; then
            cat <<'JSON'
{"Topics":[{"TopicArn":"arn:aws:sns:us-east-1:ACCOUNT_PLACEHOLDER:fjcloud-alerts-staging"},{"TopicArn":"arn:aws:sns:us-east-1:ACCOUNT_PLACEHOLDER:fjcloud-alerts-prod"}]}
JSON
            exit 0
        fi

        if [ "${1:-}" = "sns" ] && [ "${2:-}" = "list-subscriptions-by-topic" ]; then
            cat <<'JSON'
{"Subscriptions":[]}
JSON
            exit 0
        fi

        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "describe-parameters" ]; then
            cat <<'JSON'
{"Parameters":[{"Name":"/fjcloud/staging/database_url","Type":"SecureString","Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/last_deploy_sha","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/canary_quiet_until","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/cloudflare_zone_id","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/dns_domain","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/ses_configuration_set","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/algolia_migration_enabled","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/database_url","Type":"SecureString","Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/last_deploy_sha","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/canary_quiet_until","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/cloudflare_zone_id","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/dns_domain","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/ses_configuration_set","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/algolia_migration_enabled","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"}]}
JSON
            exit 0
        fi

        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
            param_name=""
            query_value=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--name" ] && [ "${2:-}" != "" ]; then
                    param_name="$2"
                fi
                if [ "$1" = "--query" ] && [ "${2:-}" != "" ]; then
                    query_value="$2"
                fi
                if [ -n "$param_name" ] && [ -n "$query_value" ]; then
                    break
                fi
                shift
            done
            if [ -n "$param_name" ]; then
                if [ "$query_value" = "Parameter.Value" ]; then
                    case "$param_name" in
                        /fjcloud/prod/stripe_secret_key)
                            printf 'sk_%s_probe_dummy\n' live
                            exit 0
                            ;;
                        /fjcloud/staging/aws_ami_id)
                            if [ "${AWS_STUB_SCENARIO:-}" = "fleet_pointer_missing" ]; then
                                printf 'An error occurred (ParameterNotFound) when calling the GetParameter operation: parameter not found\n' >&2
                                exit 254
                            fi
                            echo "ami-070b3dfb46c944d7e"
                            exit 0
                            ;;
                        /fjcloud/prod/aws_ami_id)
                            if [ "${AWS_STUB_SCENARIO:-}" = "fleet_pointer_missing" ]; then
                                printf 'An error occurred (ParameterNotFound) when calling the GetParameter operation: parameter not found\n' >&2
                                exit 254
                            fi
                            echo "ami-078228dbe86117d85"
                            exit 0
                            ;;
                        /fjcloud/staging/aws_subnet_id)
                            if [ "${AWS_STUB_SCENARIO:-}" = "fleet_pointer_missing" ]; then
                                printf 'An error occurred (ParameterNotFound) when calling the GetParameter operation: parameter not found\n' >&2
                                exit 254
                            fi
                            echo "subnet-staging"
                            exit 0
                            ;;
                        /fjcloud/prod/aws_subnet_id)
                            if [ "${AWS_STUB_SCENARIO:-}" = "fleet_pointer_missing" ]; then
                                printf 'An error occurred (ParameterNotFound) when calling the GetParameter operation: parameter not found\n' >&2
                                exit 254
                            fi
                            echo "subnet-prod"
                            exit 0
                            ;;
                    esac
                fi
                cat <<'JSON'
{"Parameter":{"Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"}}
JSON
                exit 0
            fi
        fi

        if [ "${1:-}" = "ec2" ] && [ "${2:-}" = "describe-instances" ]; then
            has_starting_token=0
            has_no_paginate=0
            for arg in "$@"; do
                if [ "$arg" = "--starting-token" ]; then
                    has_starting_token=1
                fi
                if [ "$arg" = "--no-paginate" ]; then
                    has_no_paginate=1
                fi
            done
            if [ "$has_starting_token" -eq 1 ] && [ "$has_no_paginate" -eq 1 ]; then
                printf 'aws: error: argument --starting-token: not allowed with argument --no-paginate\n' >&2
                exit 252
            fi
            if [ "${AWS_STUB_SCENARIO:-}" = "fleet_contract" ] && [ "$has_starting_token" -eq 0 ]; then
                cat <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-staging","State":{"Name":"running"},"ImageId":"ami-070b3dfb46c944d7e","SubnetId":"subnet-staging","Tags":[{"Key":"Name","Value":"fj-staging"},{"Key":"customer_id","Value":"cust-staging"},{"Key":"node_id","Value":"node-staging"},{"Key":"managed-by","Value":"fjcloud"}]}]}],"NextToken":"page-2"}
JSON
            else
                cat <<'JSON'
{"Reservations":[{"Instances":[{"InstanceId":"i-prod","State":{"Name":"running"},"ImageId":"ami-078228dbe86117d85","SubnetId":"subnet-prod","Tags":[{"Key":"Name","Value":"fj-prod"},{"Key":"customer_id","Value":"cust-prod"},{"Key":"node_id","Value":"node-prod"},{"Key":"managed-by","Value":"fjcloud"}]}]}]}
JSON
            fi
            exit 0
        fi

        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "describe-instance-information" ]; then
            cat <<'JSON'
{"InstanceInformationList":[{"InstanceId":"i-staging","PingStatus":"Online","LastPingDateTime":"2026-05-22T00:00:00Z"},{"InstanceId":"i-prod","PingStatus":"Online","LastPingDateTime":"2026-05-22T00:00:00Z"}]}
JSON
            exit 0
        fi
        ;;
esac

exit 2
EOF
    chmod +x "${stub_dir}/aws"

    cat > "${stub_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${CURL_STUB_LOG_PATH:-}" ]; then
    printf '%s\n' "$*" >> "$CURL_STUB_LOG_PATH"
fi

request_url="${*: -1}"
if [[ "$request_url" == "https://api.stripe.com/v1/balance" ]]; then
    printf '{}\n200\n'
    exit 0
fi

out_file=""
data_file=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "-o" ] && [ "${2:-}" != "" ]; then
        out_file="$2"
        shift 2
        continue
    fi
    if [ "$1" = "--data" ] && [ "${2:-}" != "" ]; then
        case "$2" in
            @*) data_file="${2#@}" ;;
        esac
        shift 2
        continue
    fi
    shift
done

if [ -n "${CURL_STUB_LOG_PATH:-}" ] && [ -n "$data_file" ] && [ -r "$data_file" ]; then
    printf 'request_body=%s\n' "$(tr -d '\n' < "$data_file")" >> "$CURL_STUB_LOG_PATH"
fi

write_curl_json_response() {
    local payload="$1"
    if [ -n "$out_file" ]; then
        printf '%s\n' "$payload" > "$out_file"
        printf '200'
    else
        printf '%s\n' "$payload"
    fi
}

if [[ "$request_url" == "https://api.stripe.com/v1/account" ]]; then
    case "${STRIPE_ACCOUNT_STUB_SCENARIO:-ready}" in
        invalid_json)
            write_curl_json_response '{not-json'
            ;;
        not_ready)
            write_curl_json_response '{"charges_enabled":true,"payouts_enabled":false,"details_submitted":true,"requirements":{"currently_due":["external_account"],"past_due":[],"disabled_reason":"requirements.past_due"}}'
            ;;
        *)
            write_curl_json_response '{"charges_enabled":true,"payouts_enabled":true,"details_submitted":true,"requirements":{"currently_due":[],"past_due":[],"disabled_reason":null},"settings":{"payments":{"statement_descriptor":"FJCLOUD"}},"business_profile":{"support_email":"support@example.com","url":"https://example.com","name":"Example"}}'
            ;;
    esac
    exit 0
fi

if [[ "$request_url" == "https://api.cloudflare.com/client/v4/accounts" ]]; then
    write_curl_json_response '{"success":true,"result":[{"id":"test_account","name":"Test Account"}]}'
    exit 0
fi

if [[ "$request_url" == *"/pages/projects" && "$request_url" != *"/pages/projects/"* ]]; then
    write_curl_json_response '{"success":true,"result":[{"name":"flapjack-cloud","deployment_configs":{"preview":{"env_vars":{"PREVIEW_TOKEN":{"type":"secret_text","value":"preview-secret"},"PUBLIC_URL":{"type":"plain_text","value":"https://preview.example.com"}}},"production":{"env_vars":{"PROD_TOKEN":{"type":"secret_text","value":"prod-secret"},"API_BASE_URL":{"type":"plain_text","value":"https://api.example.com"}}}}}]}'
    exit 0
fi

if [[ "$request_url" == *"/pages/projects/flapjack-cloud" ]]; then
    write_curl_json_response '{"success":true,"result":{"name":"flapjack-cloud","domains":["example.com"],"latest_deployment":{"production_branch":"main","id":"dep_latest","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://latest.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"canonical_deployment":{"id":"dep_canonical","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://canonical.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"deployment_configs":{"preview":{"env_vars":{"PREVIEW_TOKEN":{"type":"secret_text","value":"preview-secret"},"PUBLIC_URL":{"type":"plain_text","value":"https://preview.example.com"}}},"production":{"env_vars":{"PROD_TOKEN":{"type":"secret_text","value":"prod-secret"},"API_BASE_URL":{"type":"plain_text","value":"https://api.example.com"}}}}}}'
    exit 0
fi

if [[ "$request_url" == */public/infrastructure ]]; then
    write_curl_json_response '{"regions":[{"region":"shared","provider":"aws","provider_location":"us-test-1","display_name":"Test AWS","health":"operational","vm_count":2}],"overall":{"availability_pct":100.0,"total_regions":1,"total_vms":2}}'
    exit 0
fi

if [[ "$request_url" == */admin/tenants ]]; then
    write_curl_json_response '[{"id":"aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa","name":"demo-shared-free","email":"demo-shared-free@synthetic-seed.invalid","status":"active"}]'
    exit 0
fi

if [[ "$request_url" == */admin/tokens ]]; then
    write_curl_json_response '{"token":"tenant-token-redacted","expires_at":"2026-05-22T00:01:00Z"}'
    exit 0
fi

if [[ "$request_url" == */indexes/demo-shared-free/browse ]]; then
    case "${CURL_BROWSE_RESPONSE_SCENARIO:-exact_hit}" in
        top_level_objectid)
            write_curl_json_response '{"objectID":"doc-0","hits":[]}'
            ;;
        nested_objectid)
            write_curl_json_response '{"hits":[{"wrapper":{"objectID":"doc-0"}}]}'
            ;;
        *)
            write_curl_json_response '{"hits":[{"objectID":"doc-0","body":"Deterministic content 547345cae1cef37239ddbf234790d2b1"}]}'
            ;;
    esac
    exit 0
fi

exit 7
EOF
    chmod +x "${stub_dir}/curl"

    cat > "${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${GH_STUB_LOG_PATH:-}" ]; then
    printf '%s\n' "$*" >> "$GH_STUB_LOG_PATH"
fi

if [ "${GH_STUB_SCENARIO:-healthy}" = "all_degraded" ]; then
    exit 2
fi

if [ "${1:-}" = "secret" ] && [ "${2:-}" = "list" ]; then
    cat <<'JSON'
[{"name":"DEPLOY_IAM_ROLE_ARN"}]
JSON
    exit 0
fi

if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
    cat <<'JSON'
[{"createdAt":"2026-05-22T00:00:00Z","headSha":"abcdef123456","status":"completed","conclusion":"success","url":"https://example.com/run/1"}]
JSON
    exit 0
fi

exit 2
EOF
    chmod +x "${stub_dir}/gh"
}

assert_pattern_appears_after() {
    local artifact_path="$1" pattern="$2" label="$3"
    local line_number
    line_number="$(grep -nE "$pattern" "$artifact_path" | head -n1 | cut -d: -f1 || true)"

    if [ -z "$line_number" ]; then
        fail "${label} is present"
        return
    fi

    if [ "$line_number" -le "$ORDER_MARKER_LINE" ]; then
        fail "${label} appears in required order"
        return
    fi

    pass "${label} is present in required order"
    ORDER_MARKER_LINE="$line_number"
}

extract_vendor_row_block() {
    local artifact_path="$1" vendor_id="$2"
    awk -v section_name="### ${vendor_id}" '
        $0 == section_name { in_section = 1; next }
        in_section && /^### / { exit }
        in_section { print }
    ' "$artifact_path"
}

extract_vendor_status() {
    local artifact_path="$1" vendor_id="$2"
    extract_vendor_row_block "$artifact_path" "$vendor_id" \
        | sed -n 's/^- status: //p' \
        | head -n1
}

assert_file_contains() {
    local abs_path="$1" expected_substr="$2" msg="$3"

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$abs_path')"
        return
    fi

    if grep -Fq -- "$expected_substr" "$abs_path"; then
        pass "$msg"
    else
        fail "$msg (expected substring '$expected_substr' in '$abs_path')"
    fi
}

assert_file_occurrence_count() {
    local abs_path="$1" expected_substr="$2" expected_count="$3" msg="$4"
    local actual_count

    if [ ! -f "$abs_path" ]; then
        fail "$msg (missing '$abs_path')"
        return
    fi

    actual_count="$(grep -F -- "$expected_substr" "$abs_path" | wc -l | tr -d ' ')"
    if [ "$actual_count" = "$expected_count" ]; then
        pass "$msg"
    else
        fail "$msg (expected $expected_count occurrences of '$expected_substr' in '$abs_path', got $actual_count)"
    fi
}

validate_summary_row_contract() {
    local artifact_path="$1" vendor_id="$2"
    local section_block status_line agent_line finding_line raw_line

    section_block="$(extract_vendor_row_block "$artifact_path" "$vendor_id")"
    if [ -z "$section_block" ]; then
        fail "row ${vendor_id} has content"
        return
    fi

    status_line="$(printf '%s\n' "$section_block" | sed -n '1p')"
    if [[ "$status_line" =~ ^-\ status:\ (OK|DRIFT|STALE|ACTION_REQUIRED|PROBE_ERROR|SKIP_NO_CREDS)$ ]]; then
        pass "row ${vendor_id} starts with status enum"
    else
        fail "row ${vendor_id} starts with status enum"
    fi

    agent_line="$(printf '%s\n' "$section_block" | sed -n '2p')"
    if [[ "$agent_line" =~ ^-\ agent_executable:\ (true|false)$ ]]; then
        pass "row ${vendor_id} has agent_executable boolean"
    else
        fail "row ${vendor_id} has agent_executable boolean"
    fi

    finding_line="$(printf '%s\n' "$section_block" | sed -n '3p')"
    if [[ "$finding_line" =~ ^-\ finding:\ .+ ]]; then
        pass "row ${vendor_id} has finding line"
    else
        fail "row ${vendor_id} has finding line"
    fi

    raw_line="$(printf '%s\n' "$section_block" | sed -n '4p')"
    if [[ "$raw_line" =~ ^-\ raw:\ [a-z0-9_./-]+$ ]]; then
        pass "row ${vendor_id} has raw artifact path"
    else
        fail "row ${vendor_id} has raw artifact path"
    fi
}

validate_live_state_artifact() {
    local artifact_path="$1"
    local leak_guard_regex
    leak_guard_regex='(sk_'
    leak_guard_regex="${leak_guard_regex}"'(live|test)_[A-Za-z0-9]+|pk_(live|test)_[A-Za-z0-9]+|rk_(live|test)_[A-Za-z0-9]+|whsec'
    leak_guard_regex="${leak_guard_regex}"'_[A-Za-z0-9]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)'
    local vendor_id
    local -a ordered_patterns=(
        '^# fjcloud live-state snapshot — [0-9]{8}T[0-9]{6}Z$'
        '^Generated by `scripts/probe_live_state.sh`'
        '^### stripe_canonical$'
        '^### aws_sns_staging$'
        '^### aws_ssm_staging$'
        '^### cloudflare_pages$'
        '^### api_health$'
        '^### fleet_dataplane$'
        '^### flapjack_build_identity$'
        '^### staging_rds$'
        '^### privacy_com$'
    )
    local -a pattern_labels=(
        'document title'
        'generator line'
        'stripe row heading'
        'staging SNS row heading'
        'staging SSM row heading'
        'cloudflare pages row heading'
        'api health row heading'
        'fleet dataplane row heading'
        'flapjack build identity row heading'
        'staging RDS row heading'
        'privacy row heading'
    )
    local -a required_vendor_rows=(
        stripe_canonical
        stripe_webhook_endpoints
        aws_sns_staging
        aws_ssm_staging
        cloudflare_pages
        api_health
        fleet_dataplane
        flapjack_build_identity
        staging_rds
        privacy_com
    )

    assert_file_exists "$artifact_path" "artifact file exists at requested path"
    ORDER_MARKER_LINE=0

    for i in "${!ordered_patterns[@]}"; do
        assert_pattern_appears_after \
            "$artifact_path" \
            "${ordered_patterns[$i]}" \
            "${pattern_labels[$i]}"
    done

    for vendor_id in "${required_vendor_rows[@]}"; do
        validate_summary_row_contract "$artifact_path" "$vendor_id"
    done

    assert_file_not_matching_regex \
        "$artifact_path" \
        "$leak_guard_regex" \
        "artifact excludes secret-like token patterns"
}

run_fixture_mode() {
    validate_live_state_artifact "${LIVE_STATE_ARTIFACT}"
}

run_default_mode() {
    local output_path
    create_temp_bundle_summary output_path

    if [ ! -f "$PROBE_SCRIPT_DEFAULT" ] || [ ! -r "$PROBE_SCRIPT_DEFAULT" ]; then
        fail "default mode intentionally red: missing or unreadable ${PROBE_SCRIPT_DEFAULT}"
        run_test_summary
    fi

    if LIVE_STATE_OUTPUT_PATH="$output_path" bash "$PROBE_SCRIPT_DEFAULT"; then
        pass "default mode writes probe output via LIVE_STATE_OUTPUT_PATH"
    else
        fail "default mode probe invocation failed"
        run_test_summary
    fi

    validate_live_state_artifact "$output_path"
    assert_file_exists "$(dirname "$output_path")/manifest.txt" \
        "default mode writes the manifest beside the requested summary"
}

run_all_degraded_exit_code_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_rc
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"

    probe_rc=0
    if (
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="all_degraded" \
        GH_STUB_SCENARIO="all_degraded" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    ); then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe exits zero when all sections are degraded"
    assert_file_exists "$output_path" "all-degraded run still writes an artifact"
    if grep -Eq '^- status: (ACTION_REQUIRED|PROBE_ERROR|DRIFT|STALE|SKIP_NO_CREDS)$' "$output_path"; then
        pass "all-degraded run records at least one non-OK status"
    else
        fail "all-degraded run records at least one non-OK status"
    fi
}

run_cloudflare_fallback_empty_export_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_rc
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=stripe_live_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF
    cat > "$fallback_secret_path" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    if (
        export CLOUDFLARE_ACCOUNT_ID=""
        export CLOUDFLARE_GLOBAL_API_KEY=""
        export CLOUDFLARE_EMAIL=""
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    ); then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe succeeds with stubbed healthy vendors"
    cloudflare_status="$(extract_vendor_status "$output_path" "cloudflare_pages")"
    if [ "$cloudflare_status" != "SKIP_NO_CREDS" ] && [ -n "$cloudflare_status" ]; then
        pass "Cloudflare fallback fills intentionally empty exported auth vars"
    else
        fail "Cloudflare fallback fills intentionally empty exported auth vars"
    fi
}

run_ssm_scope_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_rc
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=stripe_live_probe_dummy
EOF
    cat > "$fallback_secret_path" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    if (
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    ); then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe succeeds for scoped SSM aws-stub run"
    if grep -Eq -- '--name /fjcloud/($|[[:space:]])' "$aws_log_path"; then
        fail "SSM probe avoids broad /fjcloud/ parameter scope"
    else
        pass "SSM probe avoids broad /fjcloud/ parameter scope"
    fi
    if grep -Eq -- '--name /fjcloud/staging/' "$aws_log_path" \
        && grep -Eq -- '--name /fjcloud/prod/' "$aws_log_path"; then
        pass "SSM probe queries staging and prod scoped prefixes"
    else
        fail "SSM probe queries staging and prod scoped prefixes"
    fi
}

run_ssm_ami_pointer_capture_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_rc
    local bundle_dir staging_raw prod_raw
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=stripe_live_probe_dummy
EOF
    cat > "$fallback_secret_path" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    if (
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    ); then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe succeeds for SSM AMI pointer capture run"
    bundle_dir="$(dirname "$output_path")"
    staging_raw="${bundle_dir}/aws_ssm_staging.txt"
    prod_raw="${bundle_dir}/aws_ssm_prod.txt"

    assert_file_exists "$staging_raw" "staging SSM raw output file is created"
    assert_file_exists "$prod_raw" "prod SSM raw output file is created"
    assert_file_contains "$staging_raw" "aws_ami_id=ami-070b3dfb46c944d7e" "staging SSM raw output includes aws_ami_id pointer value"
    assert_file_contains "$prod_raw" "aws_ami_id=ami-078228dbe86117d85" "prod SSM raw output includes aws_ami_id pointer value"
    assert_file_contains "$staging_raw" "=== /fjcloud/staging/algolia_migration_enabled ===" "staging SSM raw output includes Algolia migration metadata heading"
    assert_file_contains "$prod_raw" "=== /fjcloud/prod/algolia_migration_enabled ===" "prod SSM raw output includes Algolia migration metadata heading"
}

assert_cloudflare_pages_json_has_no_env_values() {
    local json_path="$1" label="$2"

    if python3 - "$json_path" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())

def walk(node):
    if isinstance(node, dict):
        if "env_vars" in node and isinstance(node["env_vars"], dict):
            for var_name, var_spec in node["env_vars"].items():
                if isinstance(var_spec, dict) and "value" in var_spec:
                    raise SystemExit(f"env var {var_name} still has a value field")
        for value in node.values():
            walk(value)
    elif isinstance(node, list):
        for value in node:
            walk(value)

walk(data)
PY
    then
        pass "$label omits env var value fields"
    else
        fail "$label omits env var value fields"
    fi
}

run_cloudflare_pages_raw_json_redaction_regression() {
    local output_path primary_secret_path stub_dir aws_log_path probe_rc bundle_dir
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY=sk_test_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    if (
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    ); then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe succeeds for Cloudflare Pages redaction regression"
    bundle_dir="$(dirname "$output_path")"
    assert_cloudflare_pages_json_has_no_env_values \
        "${bundle_dir}/cf_pages_projects.json" \
        "Cloudflare Pages projects raw JSON"
    assert_cloudflare_pages_json_has_no_env_values \
        "${bundle_dir}/cf_pages_project_flapjack_cloud.json" \
        "Cloudflare Pages project detail raw JSON"
    assert_file_contains \
        "${bundle_dir}/cloudflare_pages.txt" \
        "names=['API_BASE_URL', 'PROD_TOKEN']" \
        "Cloudflare Pages summary still records production env var names"
}

run_stripe_account_status_parse_error_regression() {
    local output_path primary_secret_path stub_dir aws_log_path probe_output probe_rc
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY=stripe_live_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    if probe_output="$(
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        STRIPE_ACCOUNT_STUB_SCENARIO="invalid_json" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    2>&1)"; then
        probe_rc=0
    else
        probe_rc=$?
    fi

    assert_eq "$probe_rc" "0" "probe stays exit-zero when Stripe account status parsing fails"
    assert_not_contains "$probe_output" "Traceback" "probe suppresses parser traceback for malformed Stripe account JSON"
    assert_eq \
        "$(extract_vendor_status "$output_path" "stripe_account_config")" \
        "PROBE_ERROR" \
        "stripe_account_config reports parser failure as probe error"
    assert_eq \
        "$(extract_vendor_status "$output_path" "stripe_account_status")" \
        "PROBE_ERROR" \
        "stripe_account_status reports parser failure as probe error"
}

run_stdout_path_contract_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_stdout probe_rc
    create_temp_bundle_summary output_path
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=stripe_live_probe_dummy
EOF
    cat > "$fallback_secret_path" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    probe_rc=0
    probe_stdout="$(
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    )" || probe_rc=$?

    assert_eq "$probe_rc" "0" "probe succeeds for stdout path contract run"
    assert_eq "$probe_stdout" "$output_path" "probe stdout is exactly the artifact path"
    validate_live_state_artifact "$probe_stdout"
}

run_alternate_output_bundle_isolation_regression() {
    local temp_root alternate_work canonical_work bundle_dir stub_dir
    local primary_secret fallback_secret fleet_stub identity_stub
    local summary_path alternate_rc canonical_rc timestamp canonical_summary
    temp_root="$(mktemp -d)"
    register_tmp_path "$temp_root"
    alternate_work="$temp_root/alternate_work"
    canonical_work="$temp_root/canonical_work"
    bundle_dir="$temp_root/bundle"
    stub_dir="$temp_root/bin"
    primary_secret="$temp_root/env.secret"
    fallback_secret="$temp_root/fallback.secret"
    fleet_stub="$temp_root/fleet_probe"
    identity_stub="$temp_root/identity_probe"
    summary_path="$bundle_dir/SUMMARY.md"
    mkdir -p "$alternate_work" "$canonical_work" "$bundle_dir"
    : > "$primary_secret"
    : > "$fallback_secret"

    create_stubbed_vendor_tools "$stub_dir"
    write_stub_fleet_dataplane_probe "$fleet_stub"
    write_stub_build_identity_probe "$identity_stub"

    alternate_rc=0
    if (
        cd "$alternate_work"
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="all_degraded" \
        GH_STUB_SCENARIO="all_degraded" \
        FJCLOUD_SECRET_FILE="$primary_secret" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$summary_path" \
        STUB_FLEET_RESULT="missing_credentials" \
        FLEET_DATAPLANE_PROBE="$fleet_stub" \
        STUB_CLASS_STAGING="setup_infra" \
        STUB_CLASS_PROD="setup_infra" \
        FLAPJACK_BUILD_IDENTITY_PROBE="$identity_stub" \
        bash "$PROBE_SCRIPT_DEFAULT" >/dev/null
    ); then
        alternate_rc=0
    else
        alternate_rc=$?
    fi

    assert_eq "$alternate_rc" "0" "alternate output run succeeds with hermetic stubs"
    assert_file_exists "$summary_path" "alternate summary is written at the requested path"
    assert_file_exists "$bundle_dir/manifest.txt" "alternate output owns its sibling manifest"
    assert_file_exists "$bundle_dir/fleet_dataplane.json" "alternate output owns its sibling fleet evidence"
    timestamp="$(sed -n 's/^# fjcloud live-state snapshot — //p' "$summary_path" | head -n1)"
    canonical_summary="$alternate_work/docs/live-state/$timestamp/SUMMARY.md"
    if [ -e "$canonical_summary" ]; then
        fail "alternate output never copies stubbed summary into canonical docs/live-state"
    else
        pass "alternate output never copies stubbed summary into canonical docs/live-state"
    fi

    canonical_rc=0
    if (
        cd "$canonical_work"
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="all_degraded" \
        GH_STUB_SCENARIO="all_degraded" \
        FJCLOUD_SECRET_FILE="$primary_secret" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        STUB_FLEET_RESULT="missing_credentials" \
        FLEET_DATAPLANE_PROBE="$fleet_stub" \
        FLAPJACK_BUILD_IDENTITY_PROBE="$identity_stub" \
        bash "$PROBE_SCRIPT_DEFAULT" >/dev/null 2>&1
    ); then
        canonical_rc=0
    else
        canonical_rc=$?
    fi

    assert_eq "$canonical_rc" "2" "stubbed fleet classifier requires alternate output isolation"
    if [ -d "$canonical_work/docs/live-state" ]; then
        fail "rejected stubbed classifier creates no canonical live-state bundle"
    else
        pass "rejected stubbed classifier creates no canonical live-state bundle"
    fi
}

# A stub build-identity probe: emits one JSON classification line per --env,
# driven by STUB_CLASS_STAGING / STUB_CLASS_PROD, with installed-byte + runtime
# identity evidence populated so we can prove the live-state row carries real
# engine evidence and never an AMI/S3-only record.
write_stub_build_identity_probe() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
env=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --env) env="$2"; shift 2 ;;
        *) shift ;;
    esac
done
case "$env" in
    staging) cls="${STUB_CLASS_STAGING:-pass}" ;;
    prod) cls="${STUB_CLASS_PROD:-pass}" ;;
    *) cls="investigate" ;;
esac
reason="match"
case "$cls" in
    real_defect) reason="build_id_mismatch" ;;
    setup_infra) reason="missing_expected_identity" ;;
    investigate) reason="legacy_malformed_health" ;;
esac
printf '{"probe":"flapjack_build_identity","env":"%s","classification":"%s","reason":"%s","installed_sha256":"sha-installed-%s","expected_sha256":"sha-installed-%s","runtime_version":"1.0.10","detail":"stub"}\n' \
    "$env" "$cls" "$reason" "$env" "$env"
STUB
    chmod +x "$path"
}

write_stub_fleet_dataplane_probe() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
case "${STUB_FLEET_RESULT:-ok}" in
    ok)
        printf 'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n'
        exit 0
        ;;
    missing_credentials)
        printf 'FLEET_STATUS: ACTION_REQUIRED reason=missing_credentials\n'
        exit 1
        ;;
    drift)
        printf 'FLEET_STATUS: DRIFT reason=ami_mismatch\n'
        exit 1
        ;;
    stale)
        printf 'FLEET_STATUS: STALE reason=non_running_instance\n'
        exit 1
        ;;
    probe_error)
        printf 'FLEET_STATUS: PROBE_ERROR reason=required_read_failed\n'
        exit 1
        ;;
    mismatch)
        printf 'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n'
        exit 1
        ;;
    no_token)
        printf 'diagnostic without token\n'
        exit 1
        ;;
    empty_token)
        printf 'FLEET_STATUS:  reason=missing_credentials\n'
        exit 1
        ;;
    multiple)
        printf 'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n'
        printf 'FLEET_STATUS: DRIFT reason=ami_mismatch\n'
        exit 1
        ;;
    valid_with_diagnostic)
        printf 'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n'
        printf 'diagnostic line\n'
        exit 0
        ;;
    trailing_blank)
        printf 'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n\n'
        exit 0
        ;;
    unknown)
        printf 'FLEET_STATUS: BAD reason=bad\n'
        exit 1
        ;;
    empty)
        exit 1
        ;;
esac
STUB
    chmod +x "$path"
}

run_live_state_with_fleet_probe() {
    local aws_scenario="$1" fleet_result="$2"
    local secret_mode="${3:-fleet_specific}"
    local browse_response_scenario="${4:-exact_hit}"
    local stub_dir primary_secret fallback_secret probe_stub output_path aws_log curl_log
    stub_dir="$(mktemp -d)"; TMP_PATHS+=("$stub_dir")
    primary_secret="$(mktemp)"; register_tmp_path "$primary_secret"
    fallback_secret="$(mktemp)"; register_tmp_path "$fallback_secret"
    probe_stub="$(mktemp)"; register_tmp_path "$probe_stub"
    create_temp_bundle_summary output_path
    aws_log="$(mktemp)"; register_tmp_path "$aws_log"
    curl_log="$(mktemp)"; register_tmp_path "$curl_log"

    create_stubbed_vendor_tools "$stub_dir"
    write_stub_build_identity_probe "$stub_dir/flapjack_identity"
    write_stub_fleet_dataplane_probe "$probe_stub"
    case "$secret_mode" in
        fleet_specific)
            cat > "$primary_secret" <<'EOF'
STRIPE_SECRET_KEY=sk_test_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
FLEET_STAGING_ADMIN_KEY=staging-admin-redacted
FLEET_PROD_ADMIN_KEY=prod-admin-redacted
EOF
            ;;
        canonical_admin)
            cat > "$primary_secret" <<'EOF'
STRIPE_SECRET_KEY=sk_test_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
ADMIN_KEY=canonical-admin-redacted
API_URL=https://api.staging-canonical.example
EOF
            ;;
        canonical_admin_with_staging_override)
            cat > "$primary_secret" <<'EOF'
STRIPE_SECRET_KEY=sk_test_probe_dummy
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
ADMIN_KEY=canonical-admin-redacted
API_URL=https://api.staging-canonical.example
FLEET_STAGING_API_URL=https://api.staging-override.example
EOF
            ;;
        *)
            fail "unknown fleet secret mode: $secret_mode"
            ;;
    esac
    cat > "$fallback_secret" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="$aws_scenario" \
        AWS_DEFAULT_REGION="us-test-1" \
        GH_STUB_SCENARIO="healthy" \
        AWS_STUB_LOG_PATH="$aws_log" \
        CURL_STUB_LOG_PATH="$curl_log" \
        FJCLOUD_SECRET_FILE="$primary_secret" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        STUB_CLASS_STAGING="pass" \
        STUB_CLASS_PROD="pass" \
        CURL_BROWSE_RESPONSE_SCENARIO="$browse_response_scenario" \
        FLAPJACK_BUILD_IDENTITY_PROBE="$stub_dir/flapjack_identity" \
        STUB_FLEET_RESULT="$fleet_result" \
        FLEET_DATAPLANE_PROBE="$probe_stub" \
        bash "$PROBE_SCRIPT_DEFAULT" >/dev/null 2>&1 || true

    printf '%s|%s|%s\n' "$output_path" "$aws_log" "$curl_log"
}

run_flapjack_build_identity_probe() {
    # args: stub_class_staging stub_class_prod -> prints isolated SUMMARY path
    local class_staging="$1" class_prod="$2"
    local stub_dir primary_secret fallback_secret probe_stub output_path
    stub_dir="$(mktemp -d)"; TMP_PATHS+=("$stub_dir")
    primary_secret="$(mktemp)"; register_tmp_path "$primary_secret"
    fallback_secret="$(mktemp)"; register_tmp_path "$fallback_secret"
    probe_stub="$(mktemp)"; register_tmp_path "$probe_stub"
    create_temp_bundle_summary output_path

    create_stubbed_vendor_tools "$stub_dir"
    write_stub_build_identity_probe "$probe_stub"
    cat > "$primary_secret" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=stripe_live_probe_dummy
EOF
    cat > "$fallback_secret" <<'EOF'
CLOUDFLARE_ACCOUNT_ID=test_account
CLOUDFLARE_GLOBAL_API_KEY=test_key
CLOUDFLARE_EMAIL=test@example.com
EOF

    PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="healthy" \
        GH_STUB_SCENARIO="healthy" \
        FJCLOUD_SECRET_FILE="$primary_secret" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret" \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        STUB_CLASS_STAGING="$class_staging" \
        STUB_CLASS_PROD="$class_prod" \
        FLAPJACK_BUILD_IDENTITY_PROBE="$probe_stub" \
        bash "$PROBE_SCRIPT_DEFAULT" >/dev/null 2>&1 || true
    printf '%s\n' "$output_path"
}

# Unit-test the classification->row-status mapping by loading the two mapping
# functions straight out of probe_live_state.sh (they are the single source of
# truth for the translation). This avoids spinning up a full live-state run per
# mapping case — every arm is exercised directly and fast.
run_flapjack_build_identity_mapping_regression() {
    local mapper ranker
    mapper="$(sed -n '/^flapjack_build_identity_row_status()/,/^}/p' "$PROBE_SCRIPT_DEFAULT")"
    ranker="$(sed -n '/^flapjack_build_identity_status_rank()/,/^}/p' "$PROBE_SCRIPT_DEFAULT")"
    if [ -z "$mapper" ] || [ -z "$ranker" ]; then
        fail "probe_live_state.sh owns the flapjack classification->status mapping"
        return
    fi
    eval "$mapper"
    eval "$ranker"

    assert_eq "$(flapjack_build_identity_row_status pass "")" "OK" \
        "pass maps to OK"
    assert_eq "$(flapjack_build_identity_row_status real_defect build_id_mismatch)" "ACTION_REQUIRED" \
        "real_defect maps to ACTION_REQUIRED"
    assert_eq "$(flapjack_build_identity_row_status investigate legacy_malformed_health)" "PROBE_ERROR" \
        "investigate maps to PROBE_ERROR"
    assert_eq "$(flapjack_build_identity_row_status setup_infra missing_expected_identity)" "SKIP_NO_CREDS" \
        "setup_infra missing manifest/env prerequisite maps to SKIP_NO_CREDS"
    assert_eq "$(flapjack_build_identity_row_status setup_infra ssm_unreachable)" "SKIP_NO_CREDS" \
        "setup_infra missing AWS/SSM access maps to SKIP_NO_CREDS"
    assert_eq "$(flapjack_build_identity_row_status setup_infra some_other_prereq)" "PROBE_ERROR" \
        "setup_infra with a non-creds broken prerequisite maps to PROBE_ERROR"

    # Worst-status-wins ordering: a real defect on any env dominates an OK env.
    if [ "$(flapjack_build_identity_status_rank ACTION_REQUIRED)" -gt "$(flapjack_build_identity_status_rank OK)" ] \
        && [ "$(flapjack_build_identity_status_rank PROBE_ERROR)" -gt "$(flapjack_build_identity_status_rank SKIP_NO_CREDS)" ]; then
        pass "row status severity ranks ACTION_REQUIRED and PROBE_ERROR above quieter statuses"
    else
        fail "row status severity ranks ACTION_REQUIRED and PROBE_ERROR above quieter statuses"
    fi
}

# One end-to-end run with a stubbed probe proves the row carries real
# installed-byte + runtime engine evidence (never an AMI/S3-only record) and is
# wired in after api_health.
run_flapjack_build_identity_evidence_regression() {
    local summary raw_file status section

    summary="$(run_flapjack_build_identity_probe pass pass)"
    validate_summary_row_contract "$summary" "flapjack_build_identity"
    ORDER_MARKER_LINE=0
    assert_pattern_appears_after "$summary" '^### api_health$' "api_health row heading present"
    assert_pattern_appears_after "$summary" '^### flapjack_build_identity$' "flapjack build-identity row appears after api_health"

    status="$(extract_vendor_status "$summary" "flapjack_build_identity")"
    assert_eq "$status" "OK" "matching installed-byte + runtime identity maps to OK end-to-end"

    raw_file="$(dirname "$summary")/flapjack_build_identity.txt"
    assert_file_exists "$raw_file" "flapjack build-identity raw artifact is written"
    assert_file_contains "$raw_file" "installed_sha256" \
        "raw artifact records installed-byte evidence, not AMI/S3 metadata alone"
    assert_file_contains "$raw_file" "runtime_version" \
        "raw artifact records runtime identity evidence"
    # The row must not be an AMI/S3-only record: no AMI id or S3 object-version
    # oracle tokens may stand in for the installed-byte/runtime evidence.
    assert_file_not_matching_regex "$raw_file" 'ami-[0-9a-f]{8,}' \
        "flapjack build-identity evidence does not use an AMI id as the oracle"
    assert_file_not_matching_regex "$raw_file" '(ETag|VersionId|s3://)' \
        "flapjack build-identity evidence does not use S3 metadata as the oracle"

    # The probe_live_state.sh Flapjack section must source its oracle from the
    # Stage 1 manifest/env contract, never from AMI/Packer/S3 deployment metadata.
    section="$(sed -n '/7b. Flapjack engine build identity/,/8. Staging RDS/p' "$PROBE_SCRIPT_DEFAULT" \
        | sed '/^[[:space:]]*#/d')"
    assert_not_contains "$section" "aws_ami_id" "flapjack section does not read AMI tags as the oracle"
    assert_not_contains "$section" "custom_data" "flapjack section does not read Packer custom data as the oracle"
    assert_not_contains "$section" "ETag" "flapjack section does not read S3 ETags as the oracle"
}

run_fleet_dataplane_mapping_regression() {
    local classifier_validator mapper reason_mapper
    classifier_validator="$(sed -n '/^fleet_dataplane_probe_valid_classification()/,/^}/p' "$PROBE_SCRIPT_DEFAULT")"
    mapper="$(sed -n '/^fleet_dataplane_probe_row_status()/,/^}/p' "$PROBE_SCRIPT_DEFAULT")"
    reason_mapper="$(sed -n '/^fleet_dataplane_probe_reason()/,/^}/p' "$PROBE_SCRIPT_DEFAULT")"
    if [ -z "$classifier_validator" ] || [ -z "$mapper" ] || [ -z "$reason_mapper" ]; then
        fail "probe_live_state.sh owns the fleet token->status/reason mapping"
        return
    fi
    eval "$classifier_validator"
    eval "$mapper"
    eval "$reason_mapper"

    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: OK reason=healthy_nonempty_fleet" 0)" "OK" \
        "fleet OK token with exit 0 maps to OK"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: ACTION_REQUIRED reason=missing_credentials" 1)" "ACTION_REQUIRED" \
        "fleet ACTION_REQUIRED token with exit 1 maps to ACTION_REQUIRED"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: DRIFT reason=ami_mismatch" 1)" "DRIFT" \
        "fleet DRIFT token with exit 1 maps to DRIFT"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: STALE reason=non_running_instance" 1)" "STALE" \
        "fleet STALE token with exit 1 maps to STALE"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: PROBE_ERROR reason=required_read_failed" 1)" "PROBE_ERROR" \
        "fleet PROBE_ERROR token with exit 1 maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS: OK reason=healthy_nonempty_fleet" 1)" "PROBE_ERROR" \
        "fleet token/exit mismatch maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status "" 1)" "PROBE_ERROR" \
        "empty fleet output maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status "FLEET_STATUS:  reason=missing_credentials" 1)" "PROBE_ERROR" \
        "empty fleet status token maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status $'\nFLEET_STATUS: OK reason=healthy_nonempty_fleet' 0)" "PROBE_ERROR" \
        "leading blank fleet stdout line maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status $'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n\n' 0)" "PROBE_ERROR" \
        "trailing blank fleet stdout line maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status $'FLEET_STATUS: OK reason=healthy_nonempty_fleet\ndiagnostic line' 0)" "PROBE_ERROR" \
        "valid fleet token plus diagnostic stdout maps to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_row_status $'FLEET_STATUS: OK reason=healthy_nonempty_fleet\nFLEET_STATUS: DRIFT reason=ami_mismatch' 1)" "PROBE_ERROR" \
        "two valid fleet tokens map to PROBE_ERROR"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS: OK reason=healthy_nonempty_fleet" 0)" "healthy_nonempty_fleet" \
        "fleet OK token preserves classifier reason"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS: ACTION_REQUIRED reason=missing_credentials" 1)" "missing_credentials" \
        "fleet recognized non-green token preserves classifier reason"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS: STALE reason=non_running_instance" 1)" "non_running_instance" \
        "fleet STALE token preserves classifier reason"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS: PROBE_ERROR reason=required_read_failed" 1)" "required_read_failed" \
        "fleet PROBE_ERROR token preserves classifier reason"
    assert_eq "$(fleet_dataplane_probe_reason "" 1)" "classifier_output_invalid" \
        "empty fleet output reason fails closed"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS:  reason=missing_credentials" 1)" "classifier_output_invalid" \
        "empty fleet status token reason fails closed"
    assert_eq "$(fleet_dataplane_probe_reason $'\nFLEET_STATUS: OK reason=healthy_nonempty_fleet' 0)" "classifier_output_invalid" \
        "leading blank fleet stdout line reason fails closed"
    assert_eq "$(fleet_dataplane_probe_reason $'FLEET_STATUS: OK reason=healthy_nonempty_fleet\n\n' 0)" "classifier_output_invalid" \
        "trailing blank fleet stdout line reason fails closed"
    assert_eq "$(fleet_dataplane_probe_reason $'FLEET_STATUS: PROBE_ERROR reason=required_read_failed\ndiagnostic line' 1)" "classifier_output_invalid" \
        "malformed multi-line PROBE_ERROR output reason fails closed"
    assert_eq "$(fleet_dataplane_probe_reason "FLEET_STATUS: OK reason=healthy_nonempty_fleet" 1)" "classifier_output_invalid" \
        "token/exit mismatch reason fails closed"
}

run_fleet_dataplane_missing_creds_regression() {
    local run_info summary raw_file status
    run_info="$(run_live_state_with_fleet_probe all_degraded missing_credentials)"
    summary="${run_info%%|*}"
    validate_summary_row_contract "$summary" "fleet_dataplane"
    status="$(extract_vendor_status "$summary" "fleet_dataplane")"
    assert_eq "$status" "ACTION_REQUIRED" "missing AWS credentials become ACTION_REQUIRED for fleet_dataplane"
    raw_file="$(dirname "$summary")/fleet_dataplane.json"
    assert_file_exists "$raw_file" "fleet dataplane raw evidence file is written"
    assert_file_contains "$raw_file" '"credential_state": "missing"' \
        "fleet dataplane raw evidence records missing credential_state"
    if grep -A4 '^### fleet_dataplane$' "$summary" | grep -q 'SKIP_NO_CREDS'; then
        fail "fleet_dataplane row never uses SKIP_NO_CREDS"
    else
        pass "fleet_dataplane row never uses SKIP_NO_CREDS"
    fi
}

run_fleet_dataplane_probe_output_contract() {
    local case_spec fleet_result expected_status run_info summary status raw_file

    for case_spec in \
        "ok OK" \
        "missing_credentials ACTION_REQUIRED" \
        "drift DRIFT" \
        "stale STALE" \
        "probe_error PROBE_ERROR"; do
        fleet_result="${case_spec%% *}"
        expected_status="${case_spec##* }"
        run_info="$(run_live_state_with_fleet_probe healthy "$fleet_result")"
        summary="${run_info%%|*}"
        validate_summary_row_contract "$summary" "fleet_dataplane"
        status="$(extract_vendor_status "$summary" "fleet_dataplane")"
        assert_eq "$status" "$expected_status" "fleet $fleet_result token creates identical row status"
        if grep -A4 '^### fleet_dataplane$' "$summary" | grep -q 'SKIP_NO_CREDS'; then
            fail "fleet $fleet_result token never maps to SKIP_NO_CREDS"
        else
            pass "fleet $fleet_result token never maps to SKIP_NO_CREDS"
        fi
        raw_file="$(dirname "$summary")/fleet_dataplane.json"
        assert_file_exists "$raw_file" "fleet $fleet_result token writes one raw artifact"
    done

    for fleet_result in mismatch no_token empty empty_token multiple unknown trailing_blank valid_with_diagnostic; do
        run_info="$(run_live_state_with_fleet_probe healthy "$fleet_result")"
        summary="${run_info%%|*}"
        validate_summary_row_contract "$summary" "fleet_dataplane"
        status="$(extract_vendor_status "$summary" "fleet_dataplane")"
        assert_eq "$status" "PROBE_ERROR" "fleet invalid output '$fleet_result' becomes PROBE_ERROR row"
        assert_ne "$status" "" "fleet invalid output '$fleet_result' never creates an empty status"
        assert_ne "$status" "OK" "fleet invalid output '$fleet_result' never maps to OK"
        assert_ne "$status" "SKIP_NO_CREDS" "fleet invalid output '$fleet_result' never maps to SKIP_NO_CREDS"
    done
}

run_fleet_dataplane_collection_contract() {
    local run_info summary aws_log curl_log status
    run_info="$(run_live_state_with_fleet_probe fleet_contract ok)"
    summary="${run_info%%|*}"
    aws_log="$(printf '%s' "$run_info" | cut -d'|' -f2)"
    curl_log="$(printf '%s' "$run_info" | cut -d'|' -f3)"
    status="$(extract_vendor_status "$summary" "fleet_dataplane")"
    assert_eq "$status" "OK" "fleet collection feeds classifier OK token into OK row"
    assert_file_contains "$aws_log" "ec2 describe-instances" "fleet collection calls EC2 describe-instances"
    assert_file_contains "$aws_log" "--filters Name=tag:managed-by,Values=fjcloud" \
        "fleet collection uses the managed-by filter"
    assert_file_contains "$aws_log" "--starting-token page-2" \
        "fleet collection follows EC2 pagination"
    if grep -Eq -- 'ec2 describe-instances .*--no-paginate .*--starting-token' "$aws_log"; then
        fail "fleet collection uses an AWS CLI-supported EC2 continuation contract"
    else
        pass "fleet collection uses an AWS CLI-supported EC2 continuation contract"
    fi
    assert_file_contains "$aws_log" "ssm describe-instance-information" \
        "fleet collection calls SSM instance information"
    assert_file_contains "$aws_log" "/fjcloud/staging/aws_subnet_id" \
        "fleet collection reads staging same-region subnet pointer"
    assert_file_occurrence_count "$aws_log" "/fjcloud/staging/aws_ami_id" "1" \
        "fleet collection reuses staging AMI pointer from existing aws_ssm owner"
    assert_file_occurrence_count "$aws_log" "/fjcloud/prod/aws_ami_id" "1" \
        "fleet collection reuses prod AMI pointer from existing aws_ssm owner"
    assert_file_contains "$curl_log" "/public/infrastructure" \
        "fleet collection discovers public infrastructure"
    assert_file_contains "$curl_log" "/admin/tenants" \
        "fleet collection resolves the existing synthetic tenant"
    assert_file_contains "$curl_log" "/admin/tokens" \
        "fleet collection mints a bounded tenant JWT"
    assert_file_contains "$curl_log" "/indexes/demo-shared-free/browse" \
        "fleet collection uses the corrected browse data-plane read"
    assert_file_contains "$curl_log" '"hitsPerPage":100' \
        "fleet browse request sends the BrowseDocumentsRequest hitsPerPage field"
    if grep -Eq '"limit":' "$curl_log"; then
        fail "fleet browse request omits the rejected limit field"
    else
        pass "fleet browse request omits the rejected limit field"
    fi
    if grep -Eq '(send-command|start-session|run-instances|terminate-instances|/indexes/demo-shared-free/search)' "$aws_log" "$curl_log"; then
        fail "fleet collection avoids forbidden mutation and stale search routes"
    else
        pass "fleet collection avoids forbidden mutation and stale search routes"
    fi
}

run_fleet_dataplane_browse_parser_contract() {
    local run_info summary raw_file

    run_info="$(run_live_state_with_fleet_probe fleet_contract ok fleet_specific top_level_objectid)"
    summary="${run_info%%|*}"
    raw_file="$(dirname "$summary")/fleet_dataplane.json"
    if python3 - "$raw_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    evidence = json.load(fh)

for env in evidence.get("environments", []):
    count = env.get("data_plane", {}).get("matching_object_count")
    if count != 0:
        raise SystemExit(1)
PY
    then
        pass "browse evidence rejects top-level incidental objectID outside hits"
    else
        fail "browse evidence rejects top-level incidental objectID outside hits"
    fi

    run_info="$(run_live_state_with_fleet_probe fleet_contract ok fleet_specific nested_objectid)"
    summary="${run_info%%|*}"
    raw_file="$(dirname "$summary")/fleet_dataplane.json"
    if python3 - "$raw_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    evidence = json.load(fh)

for env in evidence.get("environments", []):
    count = env.get("data_plane", {}).get("matching_object_count")
    if count != 0:
        raise SystemExit(1)
PY
    then
        pass "browse evidence rejects nested incidental objectID inside hits"
    else
        fail "browse evidence rejects nested incidental objectID inside hits"
    fi
}

run_fleet_dataplane_pointer_missing_contract() {
    local run_info summary aws_log raw_file
    run_info="$(run_live_state_with_fleet_probe fleet_pointer_missing ok)"
    summary="${run_info%%|*}"
    aws_log="$(printf '%s' "$run_info" | cut -d'|' -f2)"
    raw_file="$(dirname "$summary")/fleet_dataplane.json"
    assert_file_exists "$raw_file" "fleet dataplane raw evidence is written for missing pointers"

    assert_file_occurrence_count "$aws_log" "/fjcloud/staging/aws_ami_id" "1" \
        "fleet collection reuses the staging owner's missing AMI outcome"
    assert_file_occurrence_count "$aws_log" "/fjcloud/prod/aws_ami_id" "1" \
        "fleet collection reuses the prod owner's missing AMI outcome"

    if python3 - "$raw_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    evidence = json.load(fh)

for env in evidence.get("environments", []):
    for pointer in env.get("pointers", []):
        for owner in ("subnet", "ami"):
            if pointer.get(owner, {}).get("outcome") != "missing":
                raise SystemExit(1)
PY
    then
        pass "ParameterNotFound pointer reads serialize as missing outcomes"
    else
        fail "ParameterNotFound pointer reads serialize as missing outcomes"
    fi
}

run_fleet_dataplane_canonical_admin_contract() {
    local run_info curl_log
    run_info="$(run_live_state_with_fleet_probe fleet_contract ok canonical_admin)"
    curl_log="$(printf '%s' "$run_info" | cut -d'|' -f3)"

    assert_file_contains "$curl_log" "https://api.staging-canonical.example/public/infrastructure" \
        "fleet collection consumes canonical API_URL for the hydrated target environment"
    assert_file_contains "$curl_log" "https://api.staging-canonical.example/admin/tenants" \
        "fleet collection consumes canonical ADMIN_KEY for the data-plane identity read"
    assert_file_contains "$curl_log" "https://api.staging-canonical.example/indexes/demo-shared-free/browse" \
        "fleet collection can drive browse evidence from the canonical admin contract"
    assert_not_contains "$(read_file_content "$curl_log")" "https://api.flapjack.foo/admin/tenants" \
        "generic ADMIN_KEY is not sent to the unmatched production API"

    run_info="$(run_live_state_with_fleet_probe fleet_contract ok canonical_admin_with_staging_override)"
    curl_log="$(printf '%s' "$run_info" | cut -d'|' -f3)"
    assert_file_contains "$curl_log" "https://api.staging-override.example/public/infrastructure" \
        "fleet collection uses the staging API override as the final target"
    assert_not_contains "$(read_file_content "$curl_log")" "https://api.staging-override.example/admin/tenants" \
        "generic ADMIN_KEY is not sent to the overridden staging API"
    assert_not_contains "$(read_file_content "$curl_log")" "https://api.staging-override.example/indexes/demo-shared-free/browse" \
        "generic ADMIN_KEY cannot drive data-plane browse through an override host"
}

if [ -n "${PROBE_TEST_CASE:-}" ]; then
    case "$PROBE_TEST_CASE" in
        ssm_ami_pointer_capture)
            run_ssm_ami_pointer_capture_regression
            ;;
        cloudflare_pages_raw_json_redaction)
            run_cloudflare_pages_raw_json_redaction_regression
            ;;
        stripe_account_status_parse_error)
            run_stripe_account_status_parse_error_regression
            ;;
        fleet_collection_contract)
            run_fleet_dataplane_collection_contract
            ;;
        fleet_pointer_missing_contract)
            run_fleet_dataplane_pointer_missing_contract
            ;;
        fleet_canonical_admin_contract)
            run_fleet_dataplane_canonical_admin_contract
            ;;
        fleet_browse_parser_contract)
            run_fleet_dataplane_browse_parser_contract
            ;;
        fleet_mapping_contract)
            run_fleet_dataplane_mapping_regression
            ;;
        fleet_probe_output_contract)
            run_fleet_dataplane_probe_output_contract
            ;;
        alternate_output_bundle_isolation)
            run_alternate_output_bundle_isolation_regression
            ;;
        *)
            fail "unknown PROBE_TEST_CASE=$PROBE_TEST_CASE"
            ;;
    esac
elif [ -n "${LIVE_STATE_ARTIFACT:-}" ]; then
    run_fixture_mode
else
    run_default_mode
    run_all_degraded_exit_code_regression
    run_cloudflare_fallback_empty_export_regression
    run_ssm_scope_regression
    run_ssm_ami_pointer_capture_regression
    run_cloudflare_pages_raw_json_redaction_regression
    run_stripe_account_status_parse_error_regression
    run_stdout_path_contract_regression
    run_alternate_output_bundle_isolation_regression
    run_fleet_dataplane_mapping_regression
    run_fleet_dataplane_missing_creds_regression
    run_fleet_dataplane_probe_output_contract
    run_fleet_dataplane_collection_contract
    run_fleet_dataplane_pointer_missing_contract
    run_fleet_dataplane_canonical_admin_contract
    run_fleet_dataplane_browse_parser_contract
    run_flapjack_build_identity_mapping_regression
    run_flapjack_build_identity_evidence_regression
fi

run_test_summary
