# Phase G live invoice probe — GREEN (2026-05-03 05:42 UTC)

First real-money charge through fjcloud's live Stripe integration. End-to-end:
SetupIntent attach → live invoice → live charge → Stripe webhook → API ack.
Refund webhook revealed a production hardening bug; fix landed in same session.

## Headline

**$1.00 charged to Privacy.com card ending 4338 on live Stripe account
`acct_1SyNWBGXI8zVz4UH` (flapjack-cloud). All 8 invoice/charge events
delivered to staging API webhook with `pending_webhooks=0`.**

Refund of the same charge then revealed a real bug:
`charge.refunded` returned 500 from staging API because the PG repo
`find_latest_invoice_id_by_payment_intent` used `fetch_one` instead of
`fetch_optional`, erroring with `RowNotFound` when no prior
`invoice.payment_succeeded` event existed for that payment_intent. **Fix
shipped in commit a4b22f93 + regression test `pg_webhook_event_repo_test.rs`
in the same session.**

## Phases

### Phase F2 — `pk_live` rotation (autonomous)

- `aws ssm put-parameter --name /fjcloud/staging/stripe_publishable_key`
  rotated from `pk_test_*` to `pk_live_51SyNWBGXI8zVz4UHsfZZt...`.
- `generate_ssm_env.sh staging && systemctl restart fjcloud-api` regenerated
  `/etc/fjcloud/env` and restarted the API. Startup logs show
  `Stripe configured`, `API listening on 0.0.0.0:3001`. Live mode end-to-end.

### Phase G1 — Privacy.com card attach (autonomous via SetupIntent)

The previous handoff assumed the operator would open the saved Stripe-hosted
billing portal URL and attach the card manually (~30 sec). Hosted portal flow
turned out to be unsolvable autonomously: Stripe's portal triggered hCaptcha,
which on first checkbox click escalated to an image puzzle ("drag the crossing
tile..."). Image puzzles are by-design unsolvable headless.

Pivot: SetupIntent + Stripe.js Elements via Playwright on a local HTML page.
Same flow `/dashboard/billing/setup` uses. No portal involvement, no hCaptcha.

Reusable helper landed at `scripts/stripe/attach_card_via_setup_intent.mjs`
(commit 378b209a).

Result: payment method `pm_1TSsd2GXI8zVz4UHWdVzmR4l` (mastercard 4338,
exp 05/2031) attached to `cus_URij8h4pXDprIK`. Set as default via
`POST /v1/customers/{cus}` with `invoice_settings[default_payment_method]`.

See [`02_payment_methods.json`](02_payment_methods.json),
[`01_customer.json`](01_customer.json).

### Phase G2 — Live invoice probe (autonomous)

1. Create `$1` invoice item via `POST /v1/invoiceitems`.
2. Create invoice via `POST /v1/invoices` with
   `pending_invoice_items_behavior=include` (without this, a fresh invoice
   does NOT pick up pending items — caught one wasted invoice during the run).
3. Finalize via `POST /v1/invoices/{id}/finalize`.
4. Pay via `POST /v1/invoices/{id}/pay`.
5. Stripe charges the default PM, generates `ch_3TSse9GXI8zVz4UH1AAaiA2K`
   for $1.00 succeeded against the Mastercard 4338.

See [`03_invoice.json`](03_invoice.json), [`04_charge.json`](04_charge.json).

### Webhook delivery — 8 events, all `pending_webhooks=0`

```
invoice.created           evt_1TSse8GXI8zVz4UH0aS9mVbx
invoice.updated           evt_1TSseAGXI8zVz4UHLzRlfZNm
invoice.finalized         evt_1TSseAGXI8zVz4UHbUlRSwW4
charge.succeeded          evt_3TSse9GXI8zVz4UH1qKcVvgl
invoice.updated           evt_1TSseKGXI8zVz4UHNC6wKAar
invoice.paid              evt_1TSseKGXI8zVz4UHbsnwOtWB
invoice.payment_succeeded evt_1TSseKGXI8zVz4UHbXPaAR1q
invoice_payment.paid      evt_1TSseOGXI8zVz4UHnfAddtmw
```

Confirmed in journalctl on staging EC2: `POST /webhooks/stripe → 200, 8ms`
for each. Signature validated against `whsec_vk7T...` (live webhook secret
in `/fjcloud/staging/stripe_webhook_secret`).

See [`05_stripe_events.json`](05_stripe_events.json).

### Refund — bug surfaced, fix landed

Refund of `ch_3TSse9...` succeeded Stripe-side (`re_3TSse9GXI8zVz4UH1mkp1Zlc`,
amount=100, status=succeeded). But the resulting `charge.refunded` event
hung with `pending_webhooks=1`. Staging API logs:

```
ERROR: internal error: no rows returned by a query that expected to return
       at least one row
ERROR: response failed: Status code: 500 Internal Server Error
```

Root cause: `PgWebhookEventRepo::find_latest_invoice_id_by_payment_intent`
used `sqlx::fetch_one()` for a query whose result is legitimately empty when
no prior `invoice.payment_succeeded` has been recorded for that payment_intent.
The mock repo returned `Ok(None)` correctly, masking the bug from unit tests.

Fix: switch to `fetch_optional` + `Option::flatten`. PG-backed regression
test added at `infra/api/tests/pg_webhook_event_repo_test.rs`. Commit
`a4b22f93`.

This bug would have hit any production refund (whether ad-hoc or admin-triggered)
where the original charge's payment_intent was somehow never associated with a
prior payment_succeeded event in our DB. Common in: ops probes, manual Stripe
Dashboard refunds during incident response, data migrations.

The `pending_webhooks=1` on `charge.refunded` will resolve naturally once
Stripe retries against the deployed fix (Stripe retries failed webhook
deliveries on an exponential backoff schedule for up to 3 days).

## Out-of-band

- **`refund.created` succeeded** (`pending_webhooks=0`) — that handler doesn't
  use the broken lookup. Only `charge.refunded` was affected.
- Privacy.com $2 balance: $1 consumed by the charge, $1 returned by the refund
  (modulo Stripe's holding period). Total spend on the card after this probe:
  $0 net.
- Test invoice `in_1TSsdsGXI8zVz4UH4dcLyHFN` ($0, paid) was created with
  `auto_advance=true` before I realized `pending_invoice_items_behavior=include`
  was needed. $0 paid invoices in Stripe cannot be voided. Cosmetic artifact.

## Out-of-band CI fix

While debugging the webhook bug, I noticed staging CI was failing for the
last 90 minutes: `npm error notsup ... Required: {"node":">=22.0.0"}, Actual:
{"node":"v20.20.2"}`. The adapter-cloudflare migration (`ce4f1984`) bumped
`.nvmrc` to 22 but left `.github/workflows/ci.yml` at `node-version: 20`.
Fixed in commit `378b209a`.

## Phase F+G state at end of session

| Concern | State |
|---|---|
| `sk_live` in SSM | ✅ rotated 2026-05-03 ~01:55 UTC (prior session) |
| `pk_live` in SSM | ✅ rotated 2026-05-03 05:09 UTC (this session) |
| Live webhook secret (`whsec_vk7T...`) in SSM | ✅ rotated prior session, verified again |
| Live customer with PM attached | ✅ `cus_URij8h4pXDprIK` + `pm_1TSsd2GXI8zVz4UHWdVzmR4l` |
| Live charge succeeds | ✅ `ch_3TSse9GXI8zVz4UH1AAaiA2K`, $1, mastercard 4338 |
| Live webhook → API → DB | ✅ 8 events × `pending_webhooks=0`, signature valid |
| Live refund | ✅ `re_3TSse9...` succeeded |
| Live `charge.refunded` webhook → API | 🟡 **500 → fixed in a4b22f93, awaiting deploy** |
| CI gate green | 🟡 **broken by Node version mismatch — fixed in 378b209a** |

After the deploy (auto-triggered by 378b209a sync push):
- staging API picks up the fetch_optional fix
- `charge.refunded` retries succeed → `pending_webhooks=0`

## Commits this session

| sha | summary |
|---|---|
| `a4b22f93` | fix(api): charge.refunded 500 — fetch_one → fetch_optional + regression test |
| `378b209a` | ops: bump CI Node 20→22 + add `attach_card_via_setup_intent.mjs` helper |

Sync to staging: `6bd14e8` (single squash commit).
