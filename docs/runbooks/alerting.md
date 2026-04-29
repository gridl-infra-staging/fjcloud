# Alerting Runbook

**Status:** active operator runbook (updated 2026-04-27).

## How alert delivery is wired

The API service constructs ONE of two `AlertService` impls at startup, decided by env vars (see [`init_alert_service` in startup.rs](../../infra/api/src/startup.rs#L386-L411)):

| `SLACK_WEBHOOK_URL` | `DISCORD_WEBHOOK_URL` | Service used | DB `delivery_status` |
|---------------------|-----------------------|----------------|----------------------|
| set                 | any                   | `WebhookAlertService` | `sent` / `failed` / `skipped` |
| any                 | set                   | `WebhookAlertService` | `sent` / `failed` / `skipped` |
| unset               | unset                 | `LogAlertService` (fallback) | `logged` |

When `LogAlertService` is in effect, alerts go to `tracing` output and the `alerts` table only — **NO HUMAN CHANNEL IS PAGED**. Every alert quietly enters the DB with `delivery_status='logged'`. This is the silent-failure mode T0.1 audits.

## Severity → channel mapping

Today: a single Slack URL and/or a single Discord URL. All severities go to the same channel(s). Splitting by severity (e.g. `ALERT_CRITICAL_WEBHOOK_URL`) is deferred until first noisy-channel-fatigue (see plan rev 4 Open Question #3).

Severity colors (rendered by Slack/Discord clients):

| Severity | Slack color | Discord color | Source |
|----------|-------------|---------------|--------|
| `info`   | `#36a64f` (green)  | `0x36a64f` | [alerting.rs:34, 43](../../infra/api/src/services/alerting.rs#L34) |
| `warning`| `#daa038` (yellow) | `0xdaa038` | [alerting.rs:35, 44](../../infra/api/src/services/alerting.rs#L35) |
| `critical`| `#d00000` (red)   | `0xd00000` | [alerting.rs:36, 45](../../infra/api/src/services/alerting.rs#L36) |

## Setting webhook URLs (Phase 0 procedure)

Webhook URLs are operator-supplied secrets. They follow the same SSM precedent as `stripe_secret_key` — created via `aws ssm put-parameter`, NOT via terraform (terraform with `lifecycle { ignore_changes = [value] }` would be awkward for an externally-rotated value).

**Two layers must be in sync** for the API to pick up the URLs at startup:

1. **SSM Parameter** — the value lives in `/fjcloud/<env>/{slack,discord}_webhook_url`.
2. **`SSM_TO_ENV` allowlist** in [`ops/scripts/lib/generate_ssm_env.sh`](../../ops/scripts/lib/generate_ssm_env.sh) — maps the SSM param name to the env var name. **Without an entry here, the SSM param is silently skipped** and the API falls back to log-only.

Both layers are landed as of 2026-04-26 (mapping entries exist; SSM param creation is the operator step below).

### Operator setup (per environment)

```bash
# Staging (run with operator AWS credentials):
aws ssm put-parameter \
  --name /fjcloud/staging/slack_webhook_url \
  --value 'https://hooks.slack.com/services/...' \
  --type SecureString \
  --region us-east-1

aws ssm put-parameter \
  --name /fjcloud/staging/discord_webhook_url \
  --value 'https://discord.com/api/webhooks/...' \
  --type SecureString \
  --region us-east-1

# Then redeploy so generate_ssm_env.sh writes /etc/fjcloud/env with the new vars:
bash ops/scripts/deploy.sh staging <SHA>
```

### Rotation (when a webhook URL changes)

Same commands with `--overwrite` added, then redeploy:

```bash
aws ssm put-parameter --overwrite --name /fjcloud/staging/slack_webhook_url --value '...' --type SecureString --region us-east-1
bash ops/scripts/deploy.sh staging <SHA>
```

## Verifying webhook delivery

### Automated (wiremock smoke test) — code path correctness

```bash
cd infra && cargo test -p api --test alerting_webhook_smoke_test -- --ignored
```

Proves the production code path (`WebhookAlertService::send_alert`) actually fires HTTP POSTs with the correct JSON shape. Does NOT prove the live URL is correct or that the running API process is configured.

### Probe script — live webhook URL correctness

```bash
# Local (URLs in your shell env, e.g. loaded from `.secret/.env.secret`):
SLACK_WEBHOOK_URL=... DISCORD_WEBHOOK_URL=... bash scripts/probe_alert_delivery.sh --live

# On a deployed instance:
source /etc/fjcloud/env && bash scripts/probe_alert_delivery.sh --live
```

Probe POSTs a synthetic critical alert with a unique `nonce` in the title to each configured webhook. Default mode asserts only direct webhook acceptance (2xx). `--live` / `--readback` is the Stage 4 validation mode: for Discord it appends `wait=true` and requires the webhook response body to echo the nonce back, which upgrades the probe from transport smoke test to automated delivery readback.

### Live API startup mode (the gap probe doesn't cover)

After redeploying with the new SSM params, on the instance:

```bash
journalctl -u fjcloud-api --since '5 minutes ago' | rg "Slack alert webhook configured|Discord alert webhook configured"
journalctl -u fjcloud-api --since '5 minutes ago' | rg "No webhook URLs — using log-only alert service"
```

Interpretation:

- `Slack alert webhook configured` and/or `Discord alert webhook configured` means webhook delivery mode is active.
- `No webhook URLs — using log-only alert service` means fallback mode is active.

These lines are emitted by [`init_alert_service` in startup.rs](../../infra/api/src/startup.rs#L386-L411). If you expected webhook mode but only see the fallback line, `generate_ssm_env.sh` did not write webhook env vars to `/etc/fjcloud/env` (typically a missing or misnamed `SSM_TO_ENV` mapping).

### Red-green check (verifies the probe itself works)

```bash
# Set the SSM value to a guaranteed-invalid URL, redeploy, run probe — it MUST exit 2.
aws ssm put-parameter --overwrite --name /fjcloud/staging/slack_webhook_url \
  --value 'https://hooks.slack.com/services/INVALID/INVALID/INVALID' \
  --type SecureString --region us-east-1
bash ops/scripts/deploy.sh staging <SHA>
bash scripts/probe_alert_delivery.sh  # should exit 2

# Then restore the real URL via Operator setup commands above.
```

Without this red-green check, "probe exits 0" could be a false positive.

### Probe modes and proof strength

- Default mode: direct POST + 2xx only. Useful for reachability smoke checks, but not sufficient as end-to-end delivery proof.
- `--live` / `--readback` with Discord configured: direct POST + automated nonce readback from the Discord webhook response body. This is the canonical staging proof path.
- `--live` / `--readback` without Discord configured: the probe now fails closed, because Slack has no automated readback path.
- Slack remains status-only in the probe today. If both channels are configured, treat Discord readback as the delivery proof and Slack as advisory redundancy.

## Alert review and manual response workflow

### What `probe_alert_delivery.sh` proves vs does not prove

`bash scripts/probe_alert_delivery.sh --live` verifies direct webhook POST acceptance plus Discord nonce readback when Discord is configured. Default mode without `--live` / `--readback` proves only transport acceptance. The probe does not verify:

- API admin authentication.
- API alert-dispatch code paths.
- `alerts` table persistence before delivery attempts.
- Whether the running API process loaded webhook env vars (use the startup log checks above for that).

### Review persisted alerts in `/admin/alerts`

Use the admin alerts page for persisted-record review:

1. Open `/admin/alerts` (backed by `GET /admin/alerts`).
2. Use the severity filter (`all`, `critical`, `warning`, `info`) to narrow the list.
3. Review each row's timestamp, severity, title, message, and metadata details.
4. Leave the page open while investigating; it auto-refreshes every 15 seconds.

Current surface area is list/filter/review only. There are no built-in response controls on this page.

### Manual operator response steps

1. Confirm the alert in Slack/Discord when webhook mode is enabled, or in API logs when log-only mode is active.
2. Confirm the matching persisted record in `/admin/alerts` and verify metadata for incident context.
3. Record operator confirmation in the incident log or thread used by on-call operators.
4. For customer-facing communication, including public `/status` flips, follow [`docs/runbooks/incident-response.md`](./incident-response.md).

## Operator action items (Phase 0 step 3 — code landed 2026-04-26)

The code-side wiring is complete (SSM_TO_ENV mapping in `generate_ssm_env.sh`, probe script, this runbook). The remaining items require operator AWS credentials and a Slack/Discord webhook URL — autonomous sessions cannot do these:

- [ ] Decide which Slack/Discord channels are the production targets (or "log-only is fine for invite-only beta of 5 customers" — but explicitly choose).
- [ ] If real channels chosen: run the operator setup `aws ssm put-parameter` commands above for `staging`.
- [ ] Redeploy staging via `bash ops/scripts/deploy.sh staging <SHA>`.
- [ ] Run `bash scripts/probe_alert_delivery.sh --live` and capture the Discord nonce-readback success output.
- [ ] Run the red-green check once to confirm the probe is not a false positive.
- [ ] Repeat the operator setup for `prod` when prod is provisioned.

## Stage 2 progress update (2026-04-28)

- Superseded evidence (initial runs before operator secret addition):
  - `docs/runbooks/evidence/alert-webhook/20260428T201000Z_ssm_populate/` — no mutations; both inputs absent.
  - `docs/runbooks/evidence/alert-webhook/20260428T203204Z_ssm_populate/` — Discord via `ssm_existing_value_fallback`.
- **Canonical evidence**: `docs/runbooks/evidence/alert-webhook/20260428T213412Z_ssm_repopulate/`
  - Source: `DISCORD_WEBHOOK_URL` from operator-added canonical secret file, `discord_source_mode=env_secret_canonical`.
  - Command set:
    - `aws sts get-caller-identity` (identity: `stuart-cli`, account `213880904778`)
    - `aws ssm put-parameter --overwrite --type SecureString --name /fjcloud/staging/discord_webhook_url --value <redacted> --region us-east-1`
    - `aws ssm get-parameter --name /fjcloud/staging/discord_webhook_url --with-decryption --query Parameter.{Name:Name,Type:Type,Version:Version,LastModifiedDate:LastModifiedDate} --output json --region us-east-1`
    - `aws ssm get-parameters-by-path --path /fjcloud/staging/ --with-decryption` filtered to `discord_webhook_url|slack_webhook_url`
  - Readback: `/fjcloud/staging/discord_webhook_url` — SecureString, Version 4, LastModified `2026-04-28T17:34:13.622000-04:00`.
  - Structural check confirms Discord path matches `generate_ssm_env.sh` `SSM_TO_ENV` suffix contract; Slack path absent (intentional).
- Slack: `SLACK_WEBHOOK_URL` absent from canonical secret source; not populated in Stage 2.
- Redeploy/runtime proof remains deferred to Stage 3/4.
