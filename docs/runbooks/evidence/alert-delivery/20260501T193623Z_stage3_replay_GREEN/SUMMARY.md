# Stage 3 alert-replay — live e2e GREEN proof

**Date:** 2026-05-01 19:35 UTC
**Result:** PASS — alert with `delivery_status='sent'` persisted within 1s of replay dispatch

## What changed since prior FAIL evidence (20260429T052555Z)

The Apr 29 evidence captured `failed_persisted_send_proof` because the
replayed `invoice.payment_failed` event targeted an invoice already in
`paid` status. `handle_retry_scheduled` (`infra/api/src/routes/webhooks.rs:792`)
explicitly early-returns when `invoice.status != "finalized"`, so the
real `AlertService` path was never invoked.

This run uses a SQL-seeded invoice with `status='finalized'` and a fake
`stripe_invoice_id`. Stripe is NOT touched at all — the handler reads the
invoice from the local fjcloud DB by stripe_invoice_id, so a synthetic
finalized invoice with a unique ID exercises the full handler path
without any Stripe-side state coupling. Avoids the auto-pay-on-finalize
race that the Apr 29 setup hit.

## End-to-end chain proven

1. Seeded:
   - customer (active, placeholder password_hash)
   - invoice (status='finalized', period 2026-04-01..04-30, total 1000 cents,
     stripe_invoice_id='in_stage3_replay_<run_ts>')
2. Baseline alert count for this invoice: 0
3. Replay fixture (`scripts/stripe_webhook_replay_fixture.sh --run --event-type=invoice.payment_failed`)
   built deterministic payload + Stripe signature, POSTed to
   https://api.flapjack.foo/webhooks/stripe — HTTP 200
4. Within 1 second, alert row appeared:
   - severity='warning'
   - title='Payment failed — invoice <invoice_uuid>'
   - delivery_status='sent'
   - metadata.invoice_id matches seeded invoice
   - metadata.attempt_count='1'
   - metadata.next_payment_attempt set
5. Cleanup: DELETE alerts + invoices + customer_tenants + customers; no leakage

## What this proves about the deployed staging API

- AlertService is wired into the webhook handler path
- DISCORD_WEBHOOK_URL (or whichever destination) is configured in
  `/etc/fjcloud/env` and reaches alert dispatch successfully
  (handler reports delivery_status='sent', not 'failed')
- Alert metadata round-trips correctly through the service to the DB
- The invoice.status='finalized' gate works as designed; replay tests
  going forward must seed finalized invoices, not let Stripe auto-advance

## Probe artifact

Run from staging EC2 via SSM exec. Probe + deps fetched from
s3://fjcloud-releases-staging/probes/20260501T193500Z_stage3_replay/.
The wrapping run script (`run_stage3.sh`) is checked into that S3 path
for reproducibility.

## Next

- Update `docs/runbooks/staging-evidence.md` Stage 3 reference to point at
  this bundle
- The legacy 20260429T052555Z bundle should remain in the tree as the
  original failure capture, but `.current_bundle` should advance to this
  GREEN run
