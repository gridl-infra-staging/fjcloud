#!/usr/bin/env bash
# probe_alert_delivery.sh — synthetic critical alert delivery probe
#
# Purpose: verify that the Slack and/or Discord webhook URLs configured for the
# fjcloud alert pipeline ACTUALLY accept incoming POSTs. This catches:
#   - typo'd or rotated webhook URLs
#   - revoked/disabled webhooks at the destination
#   - DNS / TLS / connectivity regressions to hooks.slack.com / discord.com
#
# Scope (what this probe IS): direct POST to the webhook URL, asserts a 2xx
# response. In `--readback` / `--live` mode for Discord, it also requires the
# webhook response body to echo the probe nonce back. Default mode remains a
# reachability/status check only.
#
# Scope (what this probe IS NOT): does NOT verify that the running fjcloud-api
# process picked up the SLACK_WEBHOOK_URL/DISCORD_WEBHOOK_URL env vars. To
# verify that part of the chain, after a deploy run:
#   journalctl -u fjcloud-api | grep "alert webhook configured"
# Both "Slack alert webhook configured" and/or "Discord alert webhook configured"
# log lines should appear (emitted by infra/api/src/startup.rs::init_alert_service
# at lines 424 and 427 respectively; line numbers may drift, but the function
# name `init_alert_service` is the stable anchor). If they do NOT, the SSM mapping in
# ops/scripts/lib/generate_ssm_env.sh was not picked up — see
# docs/runbooks/alerting.md for the cause.
#
# Why direct-POST instead of going through the API:
#   - No admin /probe endpoint exists today; adding one is scope creep for Phase 0.
#   - T1.7 (Stream E in Phase 1) covers the API-internal path with wiremock.
#   - Combining direct-POST + the journalctl log check is a strong-enough end-
#     to-end signal for now.
#
# Usage:
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/... DISCORD_WEBHOOK_URL=... \
#       bash scripts/probe_alert_delivery.sh
#   ... bash scripts/probe_alert_delivery.sh --readback
#   ... bash scripts/probe_alert_delivery.sh --live
#
# Exit codes:
#   0  All configured webhooks passed their configured proof mode.
#   1  Misconfiguration — neither env var set (script can't probe nothing).
#   2  At least one configured webhook returned non-2xx or failed to connect.
#
# Recommended cron cadence (per T1.0 in chats/apr26_2pm_1_beta_launch_test_plan.md):
#   weekly on the staging deploy, plus on-demand during alert wiring rotations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SECRET_FILE="${FJCLOUD_SECRET_FILE:-./.secret/.env.secret}"
# shellcheck source=scripts/lib/alert_dispatch.sh
source "$SCRIPT_DIR/lib/alert_dispatch.sh"

# Generate a unique nonce so the probe can correlate its own payload against the
# Discord readback body in `--readback` / `--live` mode. ${RANDOM} is
# bash-builtin and always available — no python3 dependency for this trivial use.
NONCE="probe-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
SLACK_URL="${SLACK_WEBHOOK_URL:-}"
DISCORD_URL="${DISCORD_WEBHOOK_URL:-}"
ENVIRONMENT="${ENVIRONMENT:-unknown}"
PROBE_SOURCE="probe_alert_delivery.sh"
READBACK_MODE_ENV="${READBACK_MODE:-0}"
READBACK_MODE=0

is_truthy() {
    local value="${1:-}"
    local normalized
    normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if is_truthy "$READBACK_MODE_ENV"; then
    READBACK_MODE=1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --readback|--live)
            READBACK_MODE=1
            ;;
        --help|-h)
            cat <<'EOF'
Usage: bash scripts/probe_alert_delivery.sh [--readback|--live]

Options:
  --readback  Require Discord nonce confirmation in webhook response body.
  --live      Alias for --readback; retained for operator workflow clarity.
EOF
            exit 0
            ;;
        *)
            echo "ERROR: unsupported argument: $1" >&2
            exit 1
            ;;
    esac
    shift
done

if [[ -z "$SLACK_URL" && -z "$DISCORD_URL" ]]; then
    cat >&2 <<EOF
ERROR: neither SLACK_WEBHOOK_URL nor DISCORD_WEBHOOK_URL is set.
Cannot probe an empty webhook configuration.

To debug locally:
  . scripts/lib/env.sh && load_env_file $DEFAULT_SECRET_FILE
  bash scripts/probe_alert_delivery.sh

To debug on a deployed instance:
  source /etc/fjcloud/env
  bash scripts/probe_alert_delivery.sh

See docs/runbooks/alerting.md for the operator setup procedure.
EOF
    exit 1
fi

if [[ "$READBACK_MODE" == "1" && -z "$DISCORD_URL" ]]; then
    cat >&2 <<'EOF'
ERROR: --live/--readback requires DISCORD_WEBHOOK_URL.
Slack has no automated readback path, so status-only probing would be a false positive.
EOF
    exit 1
fi

# Track per-channel results so a partial-delivery scenario (Slack ok, Discord
# down) still surfaces clearly in the exit code AND in the operator log.
SLACK_RESULT="skipped"
DISCORD_RESULT="skipped"
ANY_FAILED=0

# Title pattern is intentionally human-recognizable: "[fjcloud probe ENV] ..."
# so it stands out in the channel even when real alerts are noisy.
TITLE="[fjcloud probe ${ENVIRONMENT}] Synthetic critical alert ${NONCE}"
MESSAGE="If you see this in your Discord/Slack channel, alert delivery is working. Nonce: ${NONCE}. Environment: ${ENVIRONMENT}. Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)."

probe_channel() {
    local channel="$1"
    local webhook_url="$2"

    CHANNEL_RESULT="skipped"
    if [[ -z "$webhook_url" ]]; then
        return 0
    fi

    if [[ "$channel" == "discord" && "$READBACK_MODE" == "1" ]]; then
        if probe_discord_with_readback "$webhook_url"; then
            CHANNEL_RESULT="ok"
            return 0
        fi
        CHANNEL_RESULT="fail"
        return 1
    fi

    if send_critical_alert "$channel" "$webhook_url" "$TITLE" "$MESSAGE" "$PROBE_SOURCE" "$NONCE" "$ENVIRONMENT"; then
        CHANNEL_RESULT="ok"
        return 0
    fi

    CHANNEL_RESULT="fail"
    return 1
}

probe_discord_with_readback() {
    local webhook_url="$1"
    local payload readback_url body_file curl_output http_code curl_status curl_error response_body

    payload="$(build_discord_critical_payload "$TITLE" "$MESSAGE" "$PROBE_SOURCE" "$NONCE" "$ENVIRONMENT")"
    readback_url="$(discord_readback_url "$webhook_url")"
    body_file="$(mktemp)"

    if [[ ! "$readback_url" =~ ^https://[^[:space:]]+$ ]]; then
        echo "[FAIL] discord: webhook URL must use https://" >&2
        rm -f "$body_file"
        return 1
    fi

    curl_output=$(curl -sSL \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o "$body_file" \
        -w '%{http_code}' \
        --max-time 10 \
        "$readback_url" 2>&1) || {
        curl_status=$?
        curl_error="$curl_output"
        if [[ -z "$curl_error" ]]; then
            curl_error="curl exited with status $curl_status"
        fi
        echo "[FAIL] discord: transport error (curl exit $curl_status): $curl_error" >&2
        rm -f "$body_file"
        return 1
    }

    http_code="$curl_output"
    if [[ ! "$http_code" =~ ^2 ]]; then
        echo "[FAIL] discord: HTTP $http_code (expected 2xx)" >&2
        rm -f "$body_file"
        return 1
    fi

    response_body="$(cat "$body_file" 2>/dev/null || true)"
    rm -f "$body_file"
    if [[ "$response_body" != *"$NONCE"* ]]; then
        echo "[FAIL] discord: readback confirmation missing nonce '$NONCE'" >&2
        return 1
    fi

    echo "[OK]   discord: HTTP $http_code (readback nonce confirmed)"
    return 0
}

probe_channel "slack" "$SLACK_URL" || ANY_FAILED=1
SLACK_RESULT="$CHANNEL_RESULT"

probe_channel "discord" "$DISCORD_URL" || ANY_FAILED=1
DISCORD_RESULT="$CHANNEL_RESULT"

# Summary line — single source for log aggregation / cron grep.
echo "==> probe summary: nonce=${NONCE} slack=${SLACK_RESULT} discord=${DISCORD_RESULT} env=${ENVIRONMENT}"
if [[ "$READBACK_MODE" == "1" && -n "$DISCORD_URL" ]]; then
    echo "==> discord delivery proof: automated nonce readback confirmed"
elif [[ -n "$DISCORD_URL" ]]; then
    echo "==> discord delivery proof is status-only in default mode; rerun with --live or --readback for automated nonce confirmation"
elif [[ -n "$SLACK_URL" ]]; then
    echo "==> slack delivery proof is status-only; no automated readback is implemented"
fi

if [[ "$ANY_FAILED" == "1" ]]; then
    exit 2
fi

exit 0
