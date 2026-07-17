# Stage 5 Alert-Delivery Evidence — 20260505T080631Z

## Verdict: GREEN (alert infrastructure scope)

Both deployed-host alert proof halves passed:

| Check | Result | Evidence |
|-------|--------|----------|
| Startup webhook mode | PASS | Journal: "Discord alert webhook configured" at 2026-05-04T09:17:44Z |
| Destination reachability | PASS | Discord HTTP 200, nonce readback confirmed (probe-20260505T080616Z-6508) |

## Scope

This bundle proves ONLY:
1. The deployed staging API (`init_alert_service` in `infra/api/src/startup.rs`) loaded the Discord webhook URL from `/etc/fjcloud/env` and initialized in webhook delivery mode.
2. The configured Discord webhook URL accepts a synthetic POST and echoes the nonce back (proving the destination is live and correctly configured).

## Explicitly excluded

- Organic in-process alert dispatch (handle_retry_scheduled → AlertService → webhook)
- `alerts.delivery_status='sent'` persistence in the database
- Stripe invoice.payment_failed replay integration
- Browser/UI layer verification

For the stronger full-path proof including persisted send, see:
`docs/runbooks/evidence/alert-delivery/20260501T193623Z_current_main_GREEN/SUMMARY.md`

## Stage 4 browser gate note

The newest Stage 4 browser evidence (`20260505T072141Z_current_main`) is RED due to a Stripe.js loading issue in the frontend. The alert webhook infrastructure is architecturally independent of the browser/Stripe.js layer — they share no code paths, configuration, or deployment artifacts. The deployed host SHA agreement with Stage 3 is confirmed (`5a57ea6a...`).

## Owner seams verified

- `scripts/launch/ssm_exec_staging.sh` — host execution wrapper (no changes needed)
- `scripts/probe_alert_delivery.sh` + `scripts/lib/alert_dispatch.sh` — webhook transport (no changes needed)
- `ops/scripts/lib/generate_ssm_env.sh` — SSM→env mapping (no changes needed)
- `infra/api/src/startup.rs::init_alert_service` — startup mode wiring (no changes needed)

## Deploy context

- Deployed SHA: `5a57ea6a280a1d63b54957b3732dcf8cc0a08c2e`
- Stage 3 bundle: `docs/runbooks/evidence/staging-deploy/20260505T063307Z_current_main_sync/`
- Service start: Mon 2026-05-04 09:17:44 UTC
- Branch: `stream-e-deploy-proof`
