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
# response. Embeds a unique nonce in the alert title so the operator can
# visually confirm in Discord/Slack that the message arrived (a 2xx alone proves
# dispatch, not destination delivery — Discord/Slack accept invalid embed JSON
# with 2xx in some cases).
#
# Scope (what this probe IS NOT): does NOT verify that the running fjcloud-api
# process picked up the SLACK_WEBHOOK_URL/DISCORD_WEBHOOK_URL env vars. To
# verify that part of the chain, after a deploy run:
#   journalctl -u fjcloud-api | grep "alert webhook configured"
# Both "Slack alert webhook configured" and/or "Discord alert webhook configured"
# log lines should appear (emitted by infra/api/src/startup.rs::init_alert_service
# at lines 395-400). If they do NOT, the SSM mapping in
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
#
# Exit codes:
#   0  All configured webhooks returned 2xx.
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

# Generate a unique nonce so the operator can disambiguate THIS probe's message
# from previous ones in the Discord/Slack channel. ${RANDOM} is bash-builtin and
# always available — no python3 dependency for this trivial use.
NONCE="probe-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
SLACK_URL="${SLACK_WEBHOOK_URL:-}"
DISCORD_URL="${DISCORD_WEBHOOK_URL:-}"
ENVIRONMENT="${ENVIRONMENT:-unknown}"
PROBE_SOURCE="probe_alert_delivery.sh"

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

    if send_critical_alert "$channel" "$webhook_url" "$TITLE" "$MESSAGE" "$PROBE_SOURCE" "$NONCE" "$ENVIRONMENT"; then
        CHANNEL_RESULT="ok"
        return 0
    fi

    CHANNEL_RESULT="fail"
    return 1
}

probe_channel "slack" "$SLACK_URL" || ANY_FAILED=1
SLACK_RESULT="$CHANNEL_RESULT"

probe_channel "discord" "$DISCORD_URL" || ANY_FAILED=1
DISCORD_RESULT="$CHANNEL_RESULT"

# Summary line — single source for log aggregation / cron grep.
echo "==> probe summary: nonce=${NONCE} slack=${SLACK_RESULT} discord=${DISCORD_RESULT} env=${ENVIRONMENT}"
echo "==> visually confirm the alert with title containing '${NONCE}' arrived in the channel(s) above"

if [[ "$ANY_FAILED" == "1" ]]; then
    exit 2
fi

exit 0
