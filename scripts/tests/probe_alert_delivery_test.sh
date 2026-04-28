#!/usr/bin/env bash
# Tests for scripts/probe_alert_delivery.sh extraction seam + behavior contract.
#
# Locks the probe's observable behavior while allowing an internal refactor:
# - missing webhook env exits 1 with current guidance text
# - all configured webhooks 2xx => exit 0 and success summary/log lines
# - partial delivery failure => exit 2 with per-channel pass/fail and summary
# - transport contract remains pinned (POST, content-type, -w, timeout)
# - payload contract remains pinned (critical colors + probe-owned metadata)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_alert_delivery.sh"
ALERT_DISPATCH_LIB="$REPO_ROOT/scripts/lib/alert_dispatch.sh"

PASS_COUNT=0
FAIL_COUNT=0

RUN_STDOUT=""
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

make_curl_mock() {
    local bin_dir="$1"
    cat > "$bin_dir/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

: "${CURL_ARGS_LOG:?CURL_ARGS_LOG is required}"
: "${CURL_PAYLOAD_DIR:?CURL_PAYLOAD_DIR is required}"

printf '%s\n' "$@" >> "$CURL_ARGS_LOG"
printf '\n' >> "$CURL_ARGS_LOG"

payload=""
expect_value_for=""
url=""

for arg in "$@"; do
    if [ -n "$expect_value_for" ]; then
        case "$expect_value_for" in
            d)
                payload="$arg"
                ;;
        esac
        expect_value_for=""
        continue
    fi

    case "$arg" in
        -d|--data|--data-raw)
            expect_value_for="d"
            ;;
        -*)
            ;;
        *)
            url="$arg"
            ;;
    esac
done

channel="generic"
http_code="${MOCK_CURL_HTTP_CODE:-200}"
exit_code="${MOCK_CURL_EXIT_CODE:-0}"
if [[ "$url" == *"slack"* ]]; then
    channel="slack"
    http_code="${MOCK_CURL_HTTP_CODE_SLACK:-$http_code}"
    exit_code="${MOCK_CURL_EXIT_CODE_SLACK:-$exit_code}"
elif [[ "$url" == *"discord"* ]]; then
    channel="discord"
    http_code="${MOCK_CURL_HTTP_CODE_DISCORD:-$http_code}"
    exit_code="${MOCK_CURL_EXIT_CODE_DISCORD:-$exit_code}"
fi

printf '%s\n' "$url" > "$CURL_PAYLOAD_DIR/${channel}_url.log"
printf '%s\n' "$payload" > "$CURL_PAYLOAD_DIR/${channel}_payload.json"

if [ "$exit_code" -ne 0 ]; then
    if [ -n "${MOCK_CURL_STDERR:-}" ]; then
        printf '%s\n' "$MOCK_CURL_STDERR" >&2
    fi
    exit "$exit_code"
fi

printf '%s' "$http_code"
MOCK
    chmod +x "$bin_dir/curl"
}

run_probe() {
    local tmp_dir="$1"
    shift

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        ENVIRONMENT="staging" \
        "$@" \
        bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

setup_probe_mock_env() {
    local tmp_dir="$1"

    mkdir -p "$tmp_dir/bin" "$tmp_dir/payloads"
    make_curl_mock "$tmp_dir/bin"
}

extract_nonce_from_summary() {
    local summary_text="$1"
    printf '%s\n' "$summary_text" | sed -n "s/.*nonce=\([^ ]*\).*/\1/p" | head -n 1
}

extract_payload_roundtrip_values() {
    local payload_kind="$1"
    local payload_json="$2"

    JSON_PAYLOAD="$payload_json" python3 - "$payload_kind" <<'PY'
import json
import os
import sys

payload = json.loads(os.environ["JSON_PAYLOAD"])
kind = sys.argv[1]
body = payload["attachments"][0] if kind == "slack" else payload["embeds"][0]
print(json.dumps([
    body["title"],
    body.get("text", body.get("description")),
    body["fields"][0]["value"],
    body["fields"][2]["value"],
]))
PY
}

test_probe_sources_shared_alert_dispatch_helper() {
    local probe_contents
    probe_contents="$(cat "$PROBE_SCRIPT")"

    assert_contains "$probe_contents" "scripts/lib/alert_dispatch.sh" \
        "probe script should source shared alert dispatch helper"
    assert_contains "$probe_contents" "send_critical_alert" \
        "probe script should route delivery via send_critical_alert helper"
    if [ -f "$ALERT_DISPATCH_LIB" ]; then
        pass "shared alert dispatch helper file exists"
    else
        fail "shared alert dispatch helper file should exist"
    fi
}

test_missing_webhooks_exit_one_and_keep_guidance() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/curl" 'exit 99'

    run_probe "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "probe should exit 1 when no webhook environment variables are configured"
    assert_contains "$RUN_STDERR" "ERROR: neither SLACK_WEBHOOK_URL nor DISCORD_WEBHOOK_URL is set." \
        "missing-webhook error should preserve existing wording"
    assert_contains "$RUN_STDERR" "See docs/runbooks/alerting.md for the operator setup procedure." \
        "missing-webhook guidance should still reference alerting runbook"
    assert_contains "$RUN_STDERR" "./.secret/.env.secret" \
        "missing-webhook guidance should point at the repo-local default secret file"
    assert_not_contains "$RUN_STDERR" "gridl-infra-dev" \
        "missing-webhook guidance should not point at a machine-specific repo path"
    assert_eq "$RUN_STDOUT" "" \
        "probe should not emit success summary lines when it exits before probing"
}

test_shared_payload_builders_escape_json_special_characters() {
    # shellcheck source=scripts/lib/alert_dispatch.sh
    source "$ALERT_DISPATCH_LIB"

    local tricky_title tricky_message tricky_source tricky_environment
    tricky_title='title "quoted"'
    tricky_message=$'line1\nline2'
    tricky_source='source\path'
    tricky_environment='staging "west"'

    local slack_payload discord_payload slack_roundtrip discord_roundtrip
    slack_payload="$(build_slack_critical_payload "$tricky_title" "$tricky_message" "$tricky_source" "nonce-1" "$tricky_environment")"
    discord_payload="$(build_discord_critical_payload "$tricky_title" "$tricky_message" "$tricky_source" "nonce-1" "$tricky_environment")"

    slack_roundtrip="$(extract_payload_roundtrip_values "slack" "$slack_payload")"
    discord_roundtrip="$(extract_payload_roundtrip_values "discord" "$discord_payload")"

    assert_eq "$slack_roundtrip" "[\"title \\\"quoted\\\"\", \"line1\\nline2\", \"source\\\\path\", \"staging \\\"west\\\"\"]" \
        "Slack payload should round-trip quoted and multiline metadata through valid JSON"
    assert_eq "$discord_roundtrip" "[\"title \\\"quoted\\\"\", \"line1\\nline2\", \"source\\\\path\", \"staging \\\"west\\\"\"]" \
        "Discord payload should round-trip quoted and multiline metadata through valid JSON"
}

test_successful_delivery_pins_transport_payload_and_summary() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    setup_probe_mock_env "$tmp_dir"

    run_probe "$tmp_dir" \
        "SLACK_WEBHOOK_URL=https://mock.slack.local/slack" \
        "DISCORD_WEBHOOK_URL=https://mock.discord.local/discord" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "CURL_PAYLOAD_DIR=$tmp_dir/payloads" \
        "MOCK_CURL_HTTP_CODE_SLACK=200" \
        "MOCK_CURL_HTTP_CODE_DISCORD=204"

    assert_eq "$RUN_EXIT_CODE" "0" "probe should exit 0 when configured channels return 2xx"
    assert_contains "$RUN_STDOUT" "[OK]   slack: HTTP 200" \
        "probe should print per-channel slack success"
    assert_contains "$RUN_STDOUT" "[OK]   discord: HTTP 204" \
        "probe should print per-channel discord success"
    assert_contains "$RUN_STDOUT" "==> probe summary:" \
        "probe should emit summary line"
    assert_contains "$RUN_STDOUT" "slack=ok discord=ok env=staging" \
        "summary should preserve channel status + environment format"
    assert_contains "$RUN_STDOUT" "==> visually confirm the alert with title containing" \
        "probe should emit visual-confirmation line"
    assert_eq "$RUN_STDERR" "" "probe success path should not log failures to stderr"

    local curl_args
    curl_args="$(cat "$tmp_dir/curl_args.log" 2>/dev/null || true)"
    assert_contains "$curl_args" "-X" \
        "transport should include explicit POST verb flag"
    assert_contains "$curl_args" "POST" \
        "transport should use POST"
    assert_contains "$curl_args" "Content-Type: application/json" \
        "transport should send JSON content type"
    assert_contains "$curl_args" "-w" \
        "transport should include curl write-out format flag"
    assert_contains "$curl_args" "%{http_code}" \
        "transport should capture HTTP code via curl write-out format"
    assert_contains "$curl_args" "--max-time" \
        "transport should keep max-time flag"
    assert_contains "$curl_args" "10" \
        "transport should keep current max-time value"

    local summary_nonce slack_payload discord_payload
    summary_nonce="$(extract_nonce_from_summary "$RUN_STDOUT")"
    slack_payload="$(cat "$tmp_dir/payloads/slack_payload.json")"
    discord_payload="$(cat "$tmp_dir/payloads/discord_payload.json")"

    assert_contains "$slack_payload" "\"color\": \"#d00000\"" \
        "Slack payload should preserve critical color"
    assert_contains "$discord_payload" "\"color\": 13631488" \
        "Discord payload should preserve critical color"
    assert_contains "$slack_payload" "\"title\": \"[fjcloud probe staging] Synthetic critical alert" \
        "Slack payload should preserve probe title format"
    assert_contains "$discord_payload" "\"title\": \"[fjcloud probe staging] Synthetic critical alert" \
        "Discord payload should preserve probe title format"
    assert_contains "$slack_payload" "If you see this in your Discord/Slack channel, alert delivery is working." \
        "Slack payload text should preserve probe message wording"
    assert_contains "$discord_payload" "If you see this in your Discord/Slack channel, alert delivery is working." \
        "Discord payload description should preserve probe message wording"
    assert_contains "$slack_payload" "\"title\": \"source\", \"value\": \"probe_alert_delivery.sh\"" \
        "Slack payload should preserve source metadata field"
    assert_contains "$discord_payload" "\"name\": \"source\", \"value\": \"probe_alert_delivery.sh\"" \
        "Discord payload should preserve source metadata field"
    assert_contains "$slack_payload" "\"title\": \"Environment\", \"value\": \"staging\"" \
        "Slack payload should preserve Environment field"
    assert_contains "$discord_payload" "\"name\": \"Environment\", \"value\": \"staging\"" \
        "Discord payload should preserve Environment field"
    assert_contains "$slack_payload" "$summary_nonce" \
        "Slack payload nonce should match summary nonce"
    assert_contains "$discord_payload" "$summary_nonce" \
        "Discord payload nonce should match summary nonce"
}

test_partial_failure_returns_exit_two_and_keeps_channel_statuses() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    setup_probe_mock_env "$tmp_dir"

    run_probe "$tmp_dir" \
        "SLACK_WEBHOOK_URL=https://mock.slack.local/slack" \
        "DISCORD_WEBHOOK_URL=https://mock.discord.local/discord" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "CURL_PAYLOAD_DIR=$tmp_dir/payloads" \
        "MOCK_CURL_HTTP_CODE_SLACK=500" \
        "MOCK_CURL_HTTP_CODE_DISCORD=204"

    assert_eq "$RUN_EXIT_CODE" "2" \
        "probe should exit 2 when any configured webhook delivery fails"
    assert_contains "$RUN_STDERR" "[FAIL] slack: HTTP 500 (expected 2xx)" \
        "probe should preserve per-channel failure logging"
    assert_contains "$RUN_STDOUT" "[OK]   discord: HTTP 204" \
        "probe should still report passing channels"
    assert_contains "$RUN_STDOUT" "slack=fail discord=ok env=staging" \
        "summary should preserve mixed channel statuses"
}

test_transport_failure_returns_exit_two_and_surfaces_curl_error() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    setup_probe_mock_env "$tmp_dir"

    run_probe "$tmp_dir" \
        "SLACK_WEBHOOK_URL=https://mock.slack.local/slack" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "CURL_PAYLOAD_DIR=$tmp_dir/payloads" \
        "MOCK_CURL_EXIT_CODE_SLACK=7" \
        "MOCK_CURL_STDERR=connection refused"

    assert_eq "$RUN_EXIT_CODE" "2" \
        "probe should exit 2 when curl cannot reach a configured webhook"
    assert_contains "$RUN_STDERR" "[FAIL] slack: transport error (curl exit 7): connection refused" \
        "transport failures should preserve curl error details"
    assert_contains "$RUN_STDOUT" "slack=fail discord=skipped env=staging" \
        "summary should preserve transport-failure channel status"
}

test_non_https_webhook_rejected_before_curl_runs() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"; trap - RETURN' RETURN

    setup_probe_mock_env "$tmp_dir"

    run_probe "$tmp_dir" \
        "SLACK_WEBHOOK_URL=http://mock.slack.local/slack" \
        "CURL_ARGS_LOG=$tmp_dir/curl_args.log" \
        "CURL_PAYLOAD_DIR=$tmp_dir/payloads"

    assert_eq "$RUN_EXIT_CODE" "2" \
        "probe should fail closed when a configured webhook is not HTTPS"
    assert_contains "$RUN_STDERR" "[FAIL] slack: webhook URL must use https://" \
        "non-HTTPS webhook rejection should explain the required scheme"
    assert_contains "$RUN_STDOUT" "slack=fail discord=skipped env=staging" \
        "summary should preserve non-HTTPS rejection channel status"

    if [ -f "$tmp_dir/curl_args.log" ]; then
        fail "probe should reject non-HTTPS webhook URLs before invoking curl"
    else
        pass "probe rejects non-HTTPS webhook URLs before invoking curl"
    fi
}

main() {
    echo "=== probe_alert_delivery.sh tests ==="
    echo ""

    test_probe_sources_shared_alert_dispatch_helper
    test_missing_webhooks_exit_one_and_keep_guidance
    test_shared_payload_builders_escape_json_special_characters
    test_successful_delivery_pins_transport_payload_and_summary
    test_partial_failure_returns_exit_two_and_keeps_channel_statuses
    test_transport_failure_returns_exit_two_and_surfaces_curl_error
    test_non_https_webhook_rejected_before_curl_runs

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
