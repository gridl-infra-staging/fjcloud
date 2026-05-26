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
LAST_PROBE_OUTPUT_DIR=""
LAST_SUMMARY_PATH=""

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

case "${AWS_STUB_SCENARIO:-all_degraded}" in
    all_degraded)
        exit 2
        ;;
    healthy)
        if [ "${1:-}" = "sts" ] && [ "${2:-}" = "get-caller-identity" ]; then
            printf '111111111111\n'
            exit 0
        fi

        if [ "${1:-}" = "sns" ] && [ "${2:-}" = "list-subscriptions-by-topic" ]; then
            cat <<'JSON'
{"Subscriptions":[]}
JSON
            exit 0
        fi

        if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
            cat <<'JSON'
{"Parameter":{"Version":1,"LastModifiedDate":"2026-05-22T00:00:00.000Z"}}
JSON
            exit 0
        fi
        ;;
esac

exit 2
EOF
    chmod +x "${stub_dir}/aws"

    cat > "${stub_dir}/dig" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '203.0.113.10\n'
EOF
    chmod +x "${stub_dir}/dig"

    cat > "${stub_dir}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${CURL_STUB_LOG_PATH:-}" ]; then
    printf '%s\n' "$*" >> "$CURL_STUB_LOG_PATH"
fi

output_file=""
write_out=""
url=""
args=("$@")
i=0
while [ $i -lt ${#args[@]} ]; do
    arg="${args[$i]}"
    case "$arg" in
        -o)
            i=$((i + 1))
            output_file="${args[$i]}"
            ;;
        -w)
            i=$((i + 1))
            write_out="${args[$i]}"
            ;;
        -H|-u|--max-time)
            i=$((i + 1))
            ;;
        -s|-S)
            ;;
        http://*|https://*)
            url="$arg"
            ;;
    esac
    i=$((i + 1))
done

status="200"
body='{}'
scenario="${CURL_STUB_SCENARIO:-healthy}"

if [ "$scenario" = "healthy" ]; then
    case "$url" in
        https://api.cloudflare.com/client/v4/accounts)
            body='{"success":true,"result":[{"id":"acct_test_123"}]}'
            ;;
        https://api.cloudflare.com/client/v4/accounts/acct_test_123/pages/projects)
            body='{"success":true,"result":[{"name":"flapjack-cloud"}]}'
            ;;
        https://api.cloudflare.com/client/v4/accounts/acct_test_123/pages/projects/flapjack-cloud)
            body='{"success":true,"result":{"name":"flapjack-cloud","domains":["example.com"],"latest_deployment":{"id":"dep_latest","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://latest.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"canonical_deployment":{"id":"dep_canonical","environment":"production","created_on":"2026-05-22T00:00:00Z","url":"https://canonical.example.com","latest_stage":{"status":"success"},"deployment_trigger":{"metadata":{"branch":"main"}}},"deployment_configs":{"preview":{"env_vars":{"PREVIEW_TOKEN":{"type":"secret_text"}}},"production":{"env_vars":{"PROD_TOKEN":{"type":"secret_text"}}}}}}'
            ;;
        https://api.stripe.com/v1/webhook_endpoints?limit=20)
            body='{"data":[]}'
            ;;
        https://api.stripe.com/v1/account)
            body='{"settings":{"payments":{"statement_descriptor":"FJ CLOUD"}},"business_profile":{"support_email":"ops@example.com","url":"https://example.com","name":"FJ Cloud"}}'
            ;;
        https://api.privacy.com/v1/cards?page_size=1)
            body='{}'
            ;;
        https://api.staging.flapjack.foo/health|https://api.flapjack.foo/health)
            body='{"ok":true}'
            ;;
        *)
            body='{}'
            status='200'
            ;;
    esac
elif [ "$scenario" = "missing_provenance" ]; then
    case "$url" in
        https://api.cloudflare.com/client/v4/accounts)
            body='{"success":true,"result":[{"id":"acct_test_123"}]}'
            ;;
        https://api.cloudflare.com/client/v4/accounts/acct_test_123/pages/projects)
            body='{"success":true,"result":[{"name":"flapjack-cloud"}]}'
            ;;
        https://api.cloudflare.com/client/v4/accounts/acct_test_123/pages/projects/flapjack-cloud)
            body='{"success":true,"result":{"name":"flapjack-cloud","deployment_configs":{"preview":{"env_vars":{"PREVIEW_TOKEN":{"type":"secret_text"}}},"production":{"env_vars":{"PROD_TOKEN":{"type":"secret_text"}}}}}}'
            ;;
        https://api.stripe.com/v1/webhook_endpoints?limit=20)
            body='{"data":[]}'
            ;;
        https://api.privacy.com/v1/cards?page_size=1)
            body='{}'
            ;;
        https://api.staging.flapjack.foo/health|https://api.flapjack.foo/health)
            body='{"ok":true}'
            ;;
        *)
            body='{}'
            status='200'
            ;;
    esac
else
    status='503'
    body='{}'
fi

if [ -n "$output_file" ]; then
    printf '%s\n' "$body" > "$output_file"
fi

if [ -n "$write_out" ]; then
    printf '%s' "$status"
elif [ -z "$output_file" ]; then
    printf '%s\n' "$body"
fi
EOF
    chmod +x "${stub_dir}/curl"
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

validate_summary_row_contract() {
    local artifact_path="$1" vendor_id="$2"
    local section_block status_line agent_line finding_line raw_line

    section_block="$(awk -v vendor_id="$vendor_id" '
        $0 == "### " vendor_id { in_section = 1; next }
        in_section && /^### / { exit }
        in_section { print }
    ' "$artifact_path")"

    if [ -z "$section_block" ]; then
        fail "row ${vendor_id} has content"
        return
    fi

    status_line="$(printf '%s\n' "$section_block" | sed -n '1p')"
    if [[ "$status_line" =~ ^-\ status:\ (OK|DRIFT|STALE|ACTION_REQUIRED|PROBE_ERROR|SKIP_NO_CREDS)$ ]]; then
        pass "row ${vendor_id} has valid status vocabulary"
    else
        fail "row ${vendor_id} has valid status vocabulary"
        return
    fi

    agent_line="$(printf '%s\n' "$section_block" | sed -n '2p')"
    if [[ "$agent_line" =~ ^-\ agent_executable:\ (true|false)$ ]]; then
        pass "row ${vendor_id} has agent_executable flag"
    else
        fail "row ${vendor_id} has agent_executable flag"
        return
    fi

    finding_line="$(printf '%s\n' "$section_block" | sed -n '3p')"
    if [[ "$finding_line" =~ ^-\ finding:\ .+ ]]; then
        pass "row ${vendor_id} has finding line"
    else
        fail "row ${vendor_id} has finding line"
        return
    fi

    raw_line="$(printf '%s\n' "$section_block" | sed -n '4p')"
    if [[ "$raw_line" =~ ^-\ raw:\ .+ ]]; then
        pass "row ${vendor_id} has raw file pointer"
    else
        fail "row ${vendor_id} has raw file pointer"
    fi
}

validate_live_state_artifact() {
    local artifact_path="$1"
    local leak_guard_regex='(sk_(live|test)_[A-Za-z0-9]+|pk_(live|test)_[A-Za-z0-9]+|rk_(live|test)_[A-Za-z0-9]+|whsec_[A-Za-z0-9]+|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]+|eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)'
    local -a ordered_patterns=(
        '^# fjcloud live-state snapshot — [0-9]{8}T[0-9]{6}Z$'
        '^### stripe_canonical$'
        '^### aws_sns_staging$'
        '^### aws_ssm_staging$'
        '^### cloudflare_pages$'
        '^### privacy_com$'
    )
    local -a pattern_labels=(
        'document title'
        'stripe row heading'
        'sns row heading'
        'ssm row heading'
        'cloudflare pages row heading'
        'privacy row heading'
    )

    assert_file_exists "$artifact_path" "artifact file exists at requested path"
    ORDER_MARKER_LINE=0

    for i in "${!ordered_patterns[@]}"; do
        assert_pattern_appears_after \
            "$artifact_path" \
            "${ordered_patterns[$i]}" \
            "${pattern_labels[$i]}"
    done

    validate_summary_row_contract "$artifact_path" "stripe_canonical"
    validate_summary_row_contract "$artifact_path" "cloudflare_pages"
    validate_summary_row_contract "$artifact_path" "aws_ssm_staging"

    assert_file_not_matching_regex \
        "$artifact_path" \
        "$leak_guard_regex" \
        "artifact excludes secret-like token patterns"
}

extract_probe_output_dir() {
    local probe_stdout="$1"
    printf '%s\n' "$probe_stdout" | sed -n 's/^Probe complete: //p' | tail -n1
}

run_probe_with_stubs() {
    local aws_scenario="$1"
    local curl_scenario="$2"
    local probe_rc probe_stdout output_dir
    local primary_secret_path fallback_secret_path stub_dir aws_log_path

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
CLOUDFLARE_GLOBAL_API_KEY=test_cf_key
CLOUDFLARE_EMAIL=test@example.com
STRIPE_SECRET_KEY=sk_test_probe_dummy
STRIPE_SECRET_KEY_RESTRICTED=sk_test_probe_dummy_restricted
STRIPE_WEBHOOK_SECRET=whsec_probe_dummy
PRIVACY_PRODUCTION_API_KEY=probe_privacy_key
EOF

    probe_rc=0
    probe_stdout="$(
        PATH="${stub_dir}:$PATH" \
        AWS_STUB_SCENARIO="$aws_scenario" \
        CURL_STUB_SCENARIO="$curl_scenario" \
        AWS_STUB_LOG_PATH="$aws_log_path" \
        FJCLOUD_SECRET_FILE="$primary_secret_path" \
        CLOUDFLARE_FALLBACK_SECRET_FILE="$fallback_secret_path" \
        bash "$PROBE_SCRIPT_DEFAULT"
    )" || probe_rc=$?

    assert_eq "$probe_rc" "0" "probe succeeds with stubbed ${aws_scenario}/${curl_scenario} vendors"

    output_dir="$(extract_probe_output_dir "$probe_stdout")"
    if [ -n "$output_dir" ]; then
        pass "probe stdout includes output directory"
    else
        fail "probe stdout includes output directory"
        run_test_summary
    fi

    LAST_PROBE_OUTPUT_DIR="$output_dir"
    LAST_SUMMARY_PATH="$output_dir/SUMMARY.md"
    validate_live_state_artifact "$LAST_SUMMARY_PATH"
}

assert_cloudflare_provenance_fields() {
    local output_dir="$1"
    local cloudflare_raw_path="$output_dir/cloudflare_pages.txt"

    assert_file_exists "$cloudflare_raw_path" "cloudflare pages raw output exists"

    if grep -Fq 'deployment_branch=main' "$cloudflare_raw_path"; then
        pass "cloudflare raw includes deployment branch"
    else
        fail "cloudflare raw includes deployment branch"
    fi

    if grep -Fq 'deployment_id=dep_latest' "$cloudflare_raw_path"; then
        pass "cloudflare raw includes deployment id"
    else
        fail "cloudflare raw includes deployment id"
    fi

    if grep -Fq 'deployment_created_on=2026-05-22T00:00:00Z' "$cloudflare_raw_path"; then
        pass "cloudflare raw includes deployment created timestamp"
    else
        fail "cloudflare raw includes deployment created timestamp"
    fi

    if grep -Fq 'deployment_url=https://latest.example.com' "$cloudflare_raw_path"; then
        pass "cloudflare raw includes deployment url"
    else
        fail "cloudflare raw includes deployment url"
    fi

    if grep -Fq 'deployment_status=success' "$cloudflare_raw_path"; then
        pass "cloudflare raw includes deployment status"
    else
        fail "cloudflare raw includes deployment status"
    fi
}

run_default_mode() {
    if [ ! -f "$PROBE_SCRIPT_DEFAULT" ] || [ ! -r "$PROBE_SCRIPT_DEFAULT" ]; then
        fail "default mode intentionally red: missing or unreadable ${PROBE_SCRIPT_DEFAULT}"
        run_test_summary
    fi

    run_probe_with_stubs "all_degraded" "healthy"
    assert_cloudflare_provenance_fields "$LAST_PROBE_OUTPUT_DIR"
}

cloudflare_row_has_drift_status() {
    local summary_path="$1"
    local cloudflare_status

    cloudflare_status="$(awk '
        $0 == "### cloudflare_pages" { in_cloudflare = 1; next }
        in_cloudflare && /^### / { exit }
        in_cloudflare && /^- status: / {
            sub(/^- status: /, "", $0)
            print $0
            exit
        }
    ' "$summary_path")"

    [ "$cloudflare_status" = "DRIFT" ]
}

run_cloudflare_status_scope_regression_test() {
    local synthetic_summary
    synthetic_summary="$(mktemp)"
    register_tmp_path "$synthetic_summary"

    cat > "$synthetic_summary" <<'EOF'
### cloudflare_pages
- status: OK
- agent_executable: false
- finding: Cloudflare row is intentionally not drift for this regression fixture
- raw: cloudflare_pages.txt

### privacy_com
- status: DRIFT
- agent_executable: false
- finding: Separate row intentionally drift
- raw: privacy_com.txt
EOF

    if cloudflare_row_has_drift_status "$synthetic_summary"; then
        fail "cloudflare status detector is scoped to cloudflare row only"
    else
        pass "cloudflare status detector is scoped to cloudflare row only"
    fi
}

run_missing_provenance_degraded_mode() {
    run_probe_with_stubs "all_degraded" "missing_provenance"

    if cloudflare_row_has_drift_status "$LAST_SUMMARY_PATH"; then
        pass "cloudflare row degrades when deployment provenance fields are missing"
    else
        fail "cloudflare row degrades when deployment provenance fields are missing"
    fi

    if grep -Fq 'missing provenance fields' "$LAST_SUMMARY_PATH"; then
        pass "cloudflare row finding explains missing provenance fields"
    else
        fail "cloudflare row finding explains missing provenance fields"
    fi
}

if [ -n "${LIVE_STATE_ARTIFACT:-}" ]; then
    validate_live_state_artifact "${LIVE_STATE_ARTIFACT}"
else
    run_cloudflare_status_scope_regression_test
    run_default_mode
    run_missing_provenance_degraded_mode
fi

run_test_summary
