# First 4 hours monitor — dispatch record

## Window

| Field | Value |
|---|---|
| Bundle id | `20260505T192351Z_prod_first_4h` |
| Start (UTC) | 2026-05-05T19:23:51Z |
| Expected end (UTC) | 2026-05-05T23:23:51Z (start + 4h) |
| Cadence | 30 min × 8 ticks |
| Origin host | local operator workstation (this clone) |
| Target environment | staging (verified deploy seam — see Env prerequisites) |

## Detached monitor process

| Field | Value |
|---|---|
| PID file | `monitor.pid` |
| PID (this dispatch) | `75308` |
| Foreground command (NOT used) | `bash run_monitor.sh` |
| Detached command (USED) | `nohup bash docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/run_monitor.sh >docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/nohup.out 2>&1 &` |
| Stdout / stderr log | `nohup.out` |
| Per-run log | `runner.log` |
| Per-tick command-level log | `tick.log` |
| Pass/fail snapshots | `poll.jsonl` (one record per check per tick) |
| Page-path escalations | `pages.jsonl` (one record per critical-fail check) |

## Stop / inspect commands

```bash
# Stop the monitor early (Stage 7 may want this if a critical alert fires)
kill "$(cat docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/monitor.pid)"

# Inspect liveness
ps -p "$(cat docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/monitor.pid)" -o pid,etime,command

# Tail current tick log
tail -n 60 docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/runner.log
tail -n 80 docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/tick.log

# Count ticks and escalations
wc -l docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/poll.jsonl
wc -l docs/runbooks/evidence/launch-rc-runs/20260505T192351Z_prod_first_4h/pages.jsonl

# Stage 7 closeout one-liner (consume the latest bundle)
LATEST=$(ls -1d docs/runbooks/evidence/launch-rc-runs/*_prod_first_4h | tail -1)
tail -n 200 "$LATEST/poll.jsonl"; wc -l "$LATEST/poll.jsonl" "$LATEST/pages.jsonl"
grep -c '"passed":false' "$LATEST/poll.jsonl" || true
```

## Env prerequisites (verified at dispatch)

| Seam | Verification at dispatch | Result |
|---|---|---|
| AWS SSM exec to staging EC2 | `bash scripts/launch/ssm_exec_staging.sh "echo SSM_PROBE_OK; date -u"` | OK — `SSM_PROBE_OK` plus current host time returned |
| Discord alert webhook reachable | `DISCORD_WEBHOOK_URL=$(aws ssm get-parameter --name /fjcloud/staging/discord_webhook_url --with-decryption ...) bash scripts/probe_alert_delivery.sh --live` | OK — `[OK] discord: HTTP 200 (readback nonce confirmed)` |
| Deployed API not in log-only fallback | `journalctl -u fjcloud-api ... grep "alert webhook configured\|No webhook URLs"` (run via SSM) | OK — `Discord alert webhook configured` line emitted at 2026-05-04T09:17:44Z, no `No webhook URLs` line in 7-day window |
| Database access (rollup freshness) | Routed via `scripts/launch/ssm_exec_staging.sh` to invoke psql against `$DATABASE_URL` on the staging API host. `PRODUCTION_DB_DSN` not exported locally; SSM seam used per checklist guidance. | seam available |
| AWS CLI / IAM | `aws cloudwatch describe-alarms --region us-east-1 ...` is invoked from local operator (no SSM). | local AWS creds in repo `.secret/.env.secret` |

## Owner mapping (no parallel paths)

| Probe | Owner |
|---|---|
| 30-min cadence | `docs/checklists/PAID_BETA_LAUNCH_CHECKLIST.md` `## First 4 hours` |
| API / metering / Stripe error inspection | `docs/runbooks/launch-backend.md` Step 4 |
| CloudWatch alarm state | `docs/checklists/PAID_BETA_LAUNCH_CHECKLIST.md` |
| Rollup freshness | `scripts/lib/metering_checks.sh::check_rollup_current` (and `scripts/validate-metering.sh`) routed via `scripts/launch/ssm_exec_staging.sh` |
| Customer-loop probe | `scripts/canary/customer_loop_synthetic.sh` (default mode; `--live` is charge-creating and not used per tick) |
| Page-path proof | `scripts/probe_alert_delivery.sh` + `docs/runbooks/alerting.md` |
| Stripe webhook persistence inspection (on-demand) | `GET /admin/webhook-events?stripe_event_id=<id>` → `infra/api/src/routes/admin/webhook_events.rs::get_webhook_event` → `WebhookEventRepo::find_by_stripe_event_id` |

## Webhook event id source

No new live-money mutation is performed by this dispatch. If Stage 7 needs a
webhook persistence spot check, source the event id from the most recent
committed live-money artifact under `docs/runbooks/evidence/launch-rc-runs/`
(e.g. `20260503T054250Z_phase_g_live_probe_GREEN/05_stripe_events.json`). Only
fall back to `scripts/canary/customer_loop_synthetic.sh`'s live branch
(`run_live_webhook_verify_step`) if no reusable event id exists.

## Coordination note

Stage 7 is the verdict / GREEN-YELLOW-RED stage. It should consume **this
bundle** (the newest `*_prod_first_4h/` directory) and write its overall
verdict directly into the pre-seeded `SUMMARY.md` here. Do not create a
second summary path.
