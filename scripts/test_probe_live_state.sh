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
    healthy)
        if [ "${1:-}" = "sts" ] && [ "${2:-}" = "get-caller-identity" ]; then
            cat <<'JSON'
{"UserId":"AIDATEST","Account":"111111111111","Arn":"arn:aws:iam::111111111111:user/test"}
JSON
            exit 0
        fi

        if [ "${1:-}" = "sns" ] && [ "${2:-}" = "list-topics" ]; then
            cat <<'JSON'
{"Topics":[{"TopicArn":"arn:aws:sns:us-east-1:111111111111:fjcloud-alerts-staging"},{"TopicArn":"arn:aws:sns:us-east-1:111111111111:fjcloud-alerts-prod"}]}
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
{"Parameters":[{"Name":"/fjcloud/staging/database_url","Type":"SecureString","Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/last_deploy_sha","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/canary_quiet_until","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/cloudflare_zone_id","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/dns_domain","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/staging/ses_configuration_set","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/database_url","Type":"SecureString","Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/last_deploy_sha","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/canary_quiet_until","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/cloudflare_zone_id","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/dns_domain","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"},{"Name":"/fjcloud/prod/ses_configuration_set","Type":"String","Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"}]}
JSON
            exit 0
        fi

        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
            param_name=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--name" ] && [ "${2:-}" != "" ]; then
                    param_name="$2"
                    break
                fi
                shift
            done
            if [ -n "$param_name" ]; then
                cat <<'JSON'
{"Parameter":{"Version":3,"LastModifiedDate":"2026-05-22T00:00:00.000Z"}}
JSON
                exit 0
            fi
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

if [[ "$request_url" == *"/pages/projects/flapjack-cloud" ]]; then
    cat <<'JSON'
{"success":true,"result":{"name":"flapjack-cloud","domains":["example.com"],"latest_deployment":{"production_branch":"main","id":"dep_latest","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://latest.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"canonical_deployment":{"id":"dep_canonical","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://canonical.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"deployment_configs":{"preview":{"env_vars":{"PREVIEW_TOKEN":{"type":"secret_text"}}},"production":{"env_vars":{"PROD_TOKEN":{"type":"secret_text"}}}}}}
JSON
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
    local leak_guard_regex='(sk_(live|test)_[A-Za-z0-9]+|pk_(live|test)_[A-Za-z0-9]+|rk_(live|test)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)'
    local vendor_id
    local -a ordered_patterns=(
        '^# fjcloud live-state snapshot — [0-9]{8}T[0-9]{6}Z$'
        '^Generated by `scripts/probe_live_state.sh`'
        '^### stripe_canonical$'
        '^### aws_sns_staging$'
        '^### aws_ssm_staging$'
        '^### cloudflare_pages$'
        '^### api_health$'
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
    local output_path timestamp canonical_summary
    output_path="$(mktemp)"
    register_tmp_path "$output_path"

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
    timestamp="$(sed -n 's/^# fjcloud live-state snapshot — //p' "$output_path" | head -n1)"
    canonical_summary="${REPO_ROOT}/docs/live-state/${timestamp}/SUMMARY.md"
    assert_file_exists "$canonical_summary" "default mode also writes canonical docs/live-state summary"
}

run_all_degraded_exit_code_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_rc
    output_path="$(mktemp)"
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$output_path"
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
    output_path="$(mktemp)"
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$output_path"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=sk_live_probe_dummy
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
    output_path="$(mktemp)"
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$output_path"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=sk_live_probe_dummy
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

run_stdout_path_contract_regression() {
    local output_path primary_secret_path fallback_secret_path stub_dir aws_log_path probe_stdout probe_rc
    output_path="$(mktemp)"
    primary_secret_path="$(mktemp)"
    fallback_secret_path="$(mktemp)"
    stub_dir="$(mktemp -d)"
    aws_log_path="$(mktemp)"
    register_tmp_path "$output_path"
    register_tmp_path "$primary_secret_path"
    register_tmp_path "$fallback_secret_path"
    register_tmp_path "$aws_log_path"
    TMP_PATHS+=("$stub_dir")

    create_stubbed_vendor_tools "$stub_dir"
    cat > "$primary_secret_path" <<'EOF'
STRIPE_SECRET_KEY_flapjack_cloud=sk_live_probe_dummy
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
        LIVE_STATE_OUTPUT_PATH="$output_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    )" || probe_rc=$?

    assert_eq "$probe_rc" "0" "probe succeeds for stdout path contract run"
    assert_eq "$probe_stdout" "$output_path" "probe stdout is exactly the artifact path"
    validate_live_state_artifact "$probe_stdout"
}

if [ -n "${LIVE_STATE_ARTIFACT:-}" ]; then
    run_fixture_mode
else
    run_default_mode
    run_all_degraded_exit_code_regression
    run_cloudflare_fallback_empty_export_regression
    run_ssm_scope_regression
    run_stdout_path_contract_regression
fi

run_test_summary
