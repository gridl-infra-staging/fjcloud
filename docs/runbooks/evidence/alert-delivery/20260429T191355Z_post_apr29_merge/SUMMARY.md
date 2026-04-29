# Alert Delivery Probe — post apr29 merge

- UTC stamp: 20260429T191332Z (run twice within ~30s, both passed)
- Repo SHA at probe time: 733498c2 (dev main)
- Probe mode: --readback (requires Discord nonce confirmation)
- Discord webhook URL source: AWS SSM /fjcloud/staging/discord_webhook_url
- Slack webhook URL source: not configured in SSM staging (skipped)
- Result: discord=ok (HTTP 200, automated nonce readback confirmed)
- Side effect: a synthetic alert message landed in the Discord channel
  associated with the staging webhook. Operator can verify visually if
  desired; the readback proof does not require it.

## What this proves

- The Discord webhook URL stored in SSM at /fjcloud/staging/discord_webhook_url
  is valid, reachable, and accepts POSTs from the operator network egress.
- Discord echoed back our nonce in the webhook response body, proving the
  webhook is actually delivering messages (not silently dropping them).

## What this does NOT yet prove

- That the *deployed staging API process* successfully reads
  DISCORD_WEBHOOK_URL from /etc/fjcloud/env at startup. To prove that,
  after the next deploy, run:
    journalctl -u fjcloud-api --since "5 minutes ago" \
      | grep "Discord alert webhook configured"
  via aws ssm send-command (see OPERATOR_NEXT_STEPS.md Step 4 pattern).
  This was not run in this session; the deploy hasn't happened yet.

## Slack webhook gap

`/fjcloud/staging/slack_webhook_url` does not exist in SSM. Either
intentionally not configured for staging, or a real gap. The probe
treats this as "skipped, skipped, ok" rather than failing. If Slack
delivery is required, add the SSM parameter (probably as SecureString
matching discord_webhook_url's pattern) and re-run probe in --readback
mode.
