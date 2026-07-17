#!/usr/bin/env bash
# Red contract test for scripts/canary/deploy_currency_check.sh.
#
# Stage 1 intentionally lands this before the script exists. At current HEAD
# the test should fail only at the missing-script precondition; once Stage 2
# adds the script, the scenarios below become the executable behavior contract.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/canary/deploy_currency_check.sh"

PASS_COUNT=0
FAIL_COUNT=0

RUN_STDERR=""
RUN_EXIT_CODE=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

NOW_ISO="2026-07-08T12:00:00Z"
NOW_EPOCH="1783512000"
THRESHOLD_HOURS="24"

DEPLOYED_SHA="1111111111111111111111111111111111111111"
MIRROR_HEAD_SHA="2222222222222222222222222222222222222222"
UNKNOWN_DEPLOYED_SHA="ffffffffffffffffffffffffffffffffffffffff"

write_alert_dispatch_override() {
    local override_path="$1"
    cat > "$override_path" <<'OVERRIDE'
send_critical_alert() {
    : "${ALERT_DISPATCH_CALL_LOG:?ALERT_DISPATCH_CALL_LOG is required}"

    local channel="${1:-}"
    local webhook_url="${2:-}"
    local title="${3:-}"
    local message="${4:-}"
    local source="${5:-}"
    local nonce="${6:-}"
    local environment="${7:-}"

    {
        printf 'channel=%s\n' "$channel"
        printf 'webhook_url=%s\n' "$webhook_url"
        printf 'title=%s\n' "$title"
        printf 'message=%s\n' "$message"
        printf 'source=%s\n' "$source"
        printf 'nonce=%s\n' "$nonce"
        printf 'environment=%s\n' "$environment"
    } >> "$ALERT_DISPATCH_CALL_LOG"
}
OVERRIDE
}

write_version_fixture() {
    local path="$1"
    local mirror_sha="$2"
    local build_time="${3:-2026-07-08T11:45:00Z}"
    cat > "$path" <<EOF_VERSION
{"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mirror_sha":"$mirror_sha","synced_at":"2026-07-08T11:30:00Z","build_time":"$build_time"}
EOF_VERSION
}

write_commits_main_fixture() {
    local path="$1"
    local sha="$2"
    local committed_at="$3"
    cat > "$path" <<EOF_HEAD
{"sha":"$sha","commit":{"committer":{"date":"$committed_at"}}}
EOF_HEAD
}

write_compare_fixture() {
    local path="$1"
    local status="$2"
    local ahead_by="$3"
    shift 3

    python3 - "$path" "$status" "$ahead_by" "$@" <<'PY'
import json
import sys

path, status, ahead_by, *dates = sys.argv[1:]
commits = []
for index, date_value in enumerate(dates, start=1):
    commits.append({
        "sha": f"{index:040d}",
        "commit": {
            "committer": {
                "date": date_value,
            },
        },
    })

with open(path, "w", encoding="utf-8") as f:
    json.dump({"status": status, "ahead_by": int(ahead_by), "commits": commits}, f)
    f.write("\n")
PY
}

write_mock_curl() {
    local path="$1"
    cat > "$path" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail

: "${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
printf '%s\n' "$*" >> "$CURL_CALL_LOG"

url=""
output_file=""
write_format=""
next_is_output=0
next_is_write=0
for arg in "$@"; do
    if [ "$next_is_output" -eq 1 ]; then
        output_file="$arg"
        next_is_output=0
        continue
    fi
    if [ "$next_is_write" -eq 1 ]; then
        write_format="$arg"
        next_is_write=0
        continue
    fi
    case "$arg" in
        -o|--output)
            next_is_output=1
            ;;
        -w|--write-out)
            next_is_write=1
            ;;
        http://*|https://*)
            url="$arg"
            ;;
    esac
done

emit_response() {
    local status="$1"
    local body_path="$2"
    if [ -n "$output_file" ]; then
        cat "$body_path" > "$output_file"
    else
        cat "$body_path"
    fi
    if [ -n "$write_format" ]; then
        printf '%s' "${write_format//%\{http_code\}/$status}"
    fi
}

if [[ "$url" == *"/version" ]]; then
    if [ "${MOCK_VERSION_FAIL:-0}" = "1" ]; then
        echo "mock /version failure" >&2
        exit 56
    fi
    emit_response "200" "$MOCK_VERSION_JSON"
    exit 0
fi

if [[ "$url" == *"/commits/main" ]]; then
    if [ "${MOCK_GITHUB_FAIL_ENDPOINT:-}" = "commits_main" ]; then
        echo "mock GitHub commits/main failure" >&2
        exit 56
    fi
    emit_response "200" "$MOCK_COMMITS_MAIN_JSON"
    exit 0
fi

if [[ "$url" == *"/compare/"* ]]; then
    if [ "${MOCK_COMPARE_HTTP_STATUS:-200}" = "404" ]; then
        if [ -n "$output_file" ]; then
            printf '{"message":"Not Found"}\n' > "$output_file"
        else
            printf '{"message":"Not Found"}\n'
        fi
        if [ -n "$write_format" ]; then
            printf '%s' "${write_format//%\{http_code\}/404}"
            exit 0
        fi
        exit 22
    fi
    if [ "${MOCK_GITHUB_FAIL_ENDPOINT:-}" = "compare" ]; then
        echo "mock GitHub compare failure" >&2
        exit 56
    fi
    emit_response "200" "$MOCK_COMPARE_JSON"
    exit 0
fi

echo "unexpected curl URL: $url" >&2
exit 97
MOCK_CURL
    chmod +x "$path"
}

setup_case_workspace() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    : > "$tmp_dir/curl_calls.log"
    : > "$tmp_dir/alert_calls.log"

    write_mock_curl "$tmp_dir/bin/curl"
    write_alert_dispatch_override "$tmp_dir/alert_dispatch_override.sh"
    write_version_fixture "$tmp_dir/version.json" "$DEPLOYED_SHA"
    write_commits_main_fixture "$tmp_dir/commits_main.json" "$MIRROR_HEAD_SHA" "$NOW_ISO"
    write_compare_fixture "$tmp_dir/compare.json" "identical" "0"
}

run_check() {
    local tmp_dir="$1"
    local webhook_url="${2-https://discord.test/api/webhooks/deploy-currency}"

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        ALERT_DISPATCH_HELPER="$tmp_dir/alert_dispatch_override.sh" \
        ALERT_DISPATCH_CALL_LOG="$tmp_dir/alert_calls.log" \
        CURL_CALL_LOG="$tmp_dir/curl_calls.log" \
        DEPLOY_CURRENCY_ENV_MATRIX="staging|https://api.staging.test/version|gridl-infra-staging/fjcloud" \
        DEPLOY_CURRENCY_NOW_EPOCH="$NOW_EPOCH" \
        DEPLOY_CURRENCY_NOW_ISO="$NOW_ISO" \
        DRIFT_MAX_AGE_HOURS="$THRESHOLD_HOURS" \
        GITHUB_API_BASE="https://api.github.test" \
        GITHUB_TOKEN="mock-github-token" \
        DISCORD_WEBHOOK_URL="$webhook_url" \
        MOCK_VERSION_JSON="$tmp_dir/version.json" \
        MOCK_COMMITS_MAIN_JSON="$tmp_dir/commits_main.json" \
        MOCK_COMPARE_JSON="$tmp_dir/compare.json" \
        MOCK_VERSION_FAIL="${MOCK_VERSION_FAIL:-0}" \
        MOCK_GITHUB_FAIL_ENDPOINT="${MOCK_GITHUB_FAIL_ENDPOINT:-}" \
        MOCK_COMPARE_HTTP_STATUS="${MOCK_COMPARE_HTTP_STATUS:-200}" \
        bash "$CHECK_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

alert_log() {
    local tmp_dir="$1"
    cat "$tmp_dir/alert_calls.log" 2>/dev/null || true
}

curl_log() {
    local tmp_dir="$1"
    cat "$tmp_dir/curl_calls.log" 2>/dev/null || true
}

alert_call_count() {
    local tmp_dir="$1"
    grep -c '^channel=' "$tmp_dir/alert_calls.log" 2>/dev/null || true
}

curl_call_count_matching() {
    local tmp_dir="$1"
    local pattern="$2"
    grep -c "$pattern" "$tmp_dir/curl_calls.log" 2>/dev/null || true
}

assert_alert_count() {
    local tmp_dir="$1"
    local expected="$2"
    local msg="$3"
    assert_eq "$(alert_call_count "$tmp_dir")" "$expected" "$msg"
}

assert_alert_payload_contains_common_breach_fields() {
    local tmp_dir="$1"
    local expected_age="$2"
    local log
    log="$(alert_log "$tmp_dir")"
    assert_contains "$log" "channel=discord" "breach alert uses Discord channel"
    assert_contains "$log" "webhook_url=https://discord.test/api/webhooks/deploy-currency" "breach alert receives configured webhook"
    assert_contains "$log" "environment=staging" "breach alert passes env label as alert environment"
    assert_contains "$log" "message=" "breach alert includes message argument"
    assert_contains "$log" "staging" "breach alert message names env label"
    assert_contains "$log" "$DEPLOYED_SHA" "breach alert message names deployed mirror_sha"
    assert_contains "$log" "$MIRROR_HEAD_SHA" "breach alert message names mirror HEAD sha"
    assert_contains "$log" "oldest undelivered" "breach alert message names oldest-undelivered rule"
    assert_contains "$log" "$expected_age" "breach alert message includes oldest-undelivered age"
}

run_scenario() {
    local name="$1"
    shift
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    setup_case_workspace "$tmp_dir"
    "$@" "$tmp_dir"

    rm -rf "$tmp_dir"
    trap - RETURN
    pass "$name completed"
}

scenario_current_env_no_alert() {
    local tmp_dir="$1"
    write_version_fixture "$tmp_dir/version.json" "$MIRROR_HEAD_SHA"
    write_compare_fixture "$tmp_dir/compare.json" "identical" "0"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "current env exits 0"
    assert_alert_count "$tmp_dir" "0" "current env sends no alert"
    assert_contains "$(curl_log "$tmp_dir")" "/commits/main" "current env probes mirror HEAD"
    assert_contains "$(curl_log "$tmp_dir")" "/compare/${MIRROR_HEAD_SHA}...main" "current env compares deployed mirror_sha to main"
}

scenario_quiet_repo_old_head_no_alert() {
    local tmp_dir="$1"
    write_version_fixture "$tmp_dir/version.json" "$MIRROR_HEAD_SHA" "2026-06-08T12:00:00Z"
    write_commits_main_fixture "$tmp_dir/commits_main.json" "$MIRROR_HEAD_SHA" "2026-06-08T12:00:00Z"
    write_compare_fixture "$tmp_dir/compare.json" "identical" "0"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "quiet repo with 30-day-old HEAD exits 0"
    assert_alert_count "$tmp_dir" "0" "quiet repo with 30-day-old HEAD sends no alert"
}

scenario_in_flight_deploy_no_alert() {
    local tmp_dir="$1"
    write_version_fixture "$tmp_dir/version.json" "$DEPLOYED_SHA" "2026-06-08T12:00:00Z"
    write_compare_fixture "$tmp_dir/compare.json" "ahead" "1" "2026-07-08T11:00:00Z"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "in-flight deploy with 1h-old undelivered commit exits 0"
    assert_alert_count "$tmp_dir" "0" "in-flight deploy with old deployed commit sends no alert"
}

scenario_stale_undelivered_drift_alerts() {
    local tmp_dir="$1"
    write_compare_fixture "$tmp_dir/compare.json" "ahead" "1" "2026-07-07T10:00:00Z"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "stale undelivered drift exits 1"
    assert_alert_count "$tmp_dir" "1" "stale undelivered drift sends exactly one alert"
    assert_alert_payload_contains_common_breach_fields "$tmp_dir" "26h"
}

scenario_continuous_push_drift_alerts() {
    local tmp_dir="$1"
    write_compare_fixture "$tmp_dir/compare.json" "ahead" "40" "2026-07-03T12:00:00Z" "2026-07-08T11:00:00Z"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "continuous-push drift exits 1"
    assert_alert_count "$tmp_dir" "1" "continuous-push drift sends exactly one alert"
    assert_alert_payload_contains_common_breach_fields "$tmp_dir" "120h"
    assert_contains "$(alert_log "$tmp_dir")" "ahead_by=40" "continuous-push alert includes ahead_by count"
}

scenario_threshold_boundary_is_strictly_older_than() {
    local tmp_dir="$1"
    write_compare_fixture "$tmp_dir/compare.json" "ahead" "1" "2026-07-07T12:00:00Z"

    run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "oldest undelivered commit exactly at threshold exits 0"
    assert_alert_count "$tmp_dir" "0" "oldest undelivered commit exactly at threshold sends no alert"
}

scenario_version_failure_alerts() {
    local tmp_dir="$1"
    MOCK_VERSION_FAIL=1 run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "/version failure exits 1"
    assert_alert_count "$tmp_dir" "1" "/version failure sends exactly one alert"
    assert_contains "$(alert_log "$tmp_dir")" "staging" "/version failure alert names env label"
    assert_contains "$(alert_log "$tmp_dir")" "/version probe failed" "/version failure alert names probe failure"
}

scenario_github_failure_retries_once_then_alerts() {
    local tmp_dir="$1"
    MOCK_GITHUB_FAIL_ENDPOINT=commits_main run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "GitHub API failure exits 1 after retry"
    assert_alert_count "$tmp_dir" "1" "GitHub API failure sends exactly one alert"
    assert_contains "$(alert_log "$tmp_dir")" "staging" "GitHub API failure alert names env label"
    assert_contains "$(alert_log "$tmp_dir")" "$DEPLOYED_SHA" "GitHub API failure alert names deployed mirror_sha"
    assert_contains "$(alert_log "$tmp_dir")" "GitHub API probe failed" "GitHub API failure alert names probe failure"
    assert_eq "$(curl_call_count_matching "$tmp_dir" "/commits/main")" "2" "GitHub commits/main failure retries exactly once"
}

scenario_webhook_unset_breach_fails_loud_without_delivery() {
    local tmp_dir="$1"
    write_compare_fixture "$tmp_dir/compare.json" "ahead" "1" "2026-07-07T10:00:00Z"

    run_check "$tmp_dir" ""

    assert_eq "$RUN_EXIT_CODE" "1" "webhook-unset breach exits nonzero"
    assert_alert_count "$tmp_dir" "0" "webhook-unset breach makes no successful delivery call"
    assert_contains "$RUN_STDERR" "ALERT DELIVERY UNCONFIGURED" "webhook-unset breach prints loud delivery-unconfigured line"
}

scenario_compare_404_pages_without_retry() {
    local tmp_dir="$1"
    write_version_fixture "$tmp_dir/version.json" "$UNKNOWN_DEPLOYED_SHA"

    MOCK_COMPARE_HTTP_STATUS=404 run_check "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "definitive compare 404 exits 1"
    assert_alert_count "$tmp_dir" "1" "definitive compare 404 sends exactly one alert"
    assert_contains "$(alert_log "$tmp_dir")" "staging" "compare 404 alert names env label"
    assert_contains "$(alert_log "$tmp_dir")" "$MIRROR_HEAD_SHA" "compare 404 alert names mirror HEAD sha"
    assert_contains "$(alert_log "$tmp_dir")" "$UNKNOWN_DEPLOYED_SHA" "compare 404 alert names unresolvable deployed sha"
    assert_contains "$(alert_log "$tmp_dir")" "unresolvable deployed sha" "compare 404 alert identifies unknown deployed SHA branch"
    assert_eq "$(curl_call_count_matching "$tmp_dir" "/compare/")" "1" "definitive compare 404 does not consume transient retry path"
}

main() {
    echo "=== deploy_currency_check_test.sh ==="
    echo ""

    if [ -f "$CHECK_SCRIPT" ]; then
        pass "deploy-currency check script exists at scripts/canary/deploy_currency_check.sh"
    else
        fail "deploy-currency check script exists at scripts/canary/deploy_currency_check.sh"
        echo ""
        echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
        exit 1
    fi

    run_scenario "current env no-alert scenario" scenario_current_env_no_alert
    run_scenario "quiet repo old-head no-alert scenario" scenario_quiet_repo_old_head_no_alert
    run_scenario "in-flight deploy no-alert scenario" scenario_in_flight_deploy_no_alert
    run_scenario "stale undelivered drift breach scenario" scenario_stale_undelivered_drift_alerts
    run_scenario "continuous-push drift breach scenario" scenario_continuous_push_drift_alerts
    run_scenario "strict threshold boundary scenario" scenario_threshold_boundary_is_strictly_older_than
    run_scenario "/version failure alert scenario" scenario_version_failure_alerts
    run_scenario "GitHub failure retry alert scenario" scenario_github_failure_retries_once_then_alerts
    run_scenario "webhook-unset breach scenario" scenario_webhook_unset_breach_fails_loud_without_delivery
    run_scenario "definitive compare 404 scenario" scenario_compare_404_pages_without_retry

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
