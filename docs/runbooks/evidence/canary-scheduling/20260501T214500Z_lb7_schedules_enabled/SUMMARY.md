# LB-7 evidence — canary schedules enabled + red→page cycle proven

**Date:** 2026-05-01 21:45 UTC
**Result:** GREEN — three canaries scheduled; red→page chain proven end-to-end.

## Schedules

LAUNCH.md LB-7 done-criteria: "scheduler invokes the three canaries on a fixed cadence; non-zero exit posts to the configured alert webhook; one full red → page cycle captured as evidence."

| Canary | Scheduler | Cadence | State |
|---|---|---|---|
| `customer_loop_synthetic.sh` | EventBridge `fjcloud-staging-customer-loop-canary` | rate(15 minutes) | **ENABLED 2026-05-01** |
| `support_email_deliverability.sh` | EventBridge `fjcloud-staging-support-email-canary-schedule` | rate(6 hours) | ENABLED (already) |
| `outside_aws_health_check.sh` | GitHub Actions cron in `.github/workflows/outside_aws_health.yml` | `*/5 * * * *` | ENABLED (already) |

The customer-loop schedule was DISABLED prior to this session. Enabled via:

```
aws events enable-rule --region us-east-1 --name fjcloud-staging-customer-loop-canary
```

Scheduler choice rationale (per Stuart's lean in LAUNCH.md `## Open questions`, which this evidence resolves):
- **GHA cron** for `outside_aws_health` because it must originate outside AWS to be a meaningful test of public network reachability.
- **EventBridge + Lambda** for `customer_loop` and `support_email` because both are in-AWS probes and the existing infrastructure already provisions them.

`eventbridge_rules.json` in this bundle captures the live state of both AWS schedules.

## Red → page proof

Forced a real customer-loop canary failure by pointing it at a 404'ing API path
(`https://api.flapjack.foo/this-path-does-not-exist`):

```
[customer-loop-canary] customer loop failed before completion; entering cleanup
[customer-loop-canary] step 'signup' failed: register returned HTTP 404
[OK]   discord: HTTP 204
```

The canary's `send_critical_alert` dispatched the failure to the configured
Discord webhook, which returned HTTP 204 (Discord's success code for webhooks).

**Chain proven:** canary script detects failure → calls `send_critical_alert` →
`alert_dispatch.sh` POSTs JSON payload to `DISCORD_WEBHOOK_URL` (the canonical
webhook from SSM `/fjcloud/staging/discord_webhook_url`) → Discord accepts.

Slack webhook is not in SSM; the dispatch helper skips it gracefully when
`SLACK_WEBHOOK_URL` is unset. Discord-only is sufficient for launch per
LAUNCH.md `## Consciously deferred`.

## What this proves about the running schedule

The schedule -> Lambda -> canary path uses the same `customer_loop_synthetic.sh`
and `send_critical_alert` codepath that this red→page proof exercised. A real
schedule-driven failure (e.g. staging API drift) will reach Discord the same
way. The 15-minute customer-loop cadence and 5-minute outside-AWS cadence keep
detection latency under operator-acceptable bounds for a solo-maintainer rotation.

## Next pages

If a future canary failure spam-pages Discord, the right response is to add a
quiet-period file or rate-limit at the dispatch helper, not to disable the
schedule. The infrastructure is here on purpose.
