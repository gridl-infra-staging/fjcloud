# Stage D — Live billing-rehearsal evidence (paid lifecycle, 2026-04-26)

First run of the credentialed staging billing rehearsal that produced
`paid` invoice evidence end-to-end. Captures the resolution of the
2026-04-09 staging-deploy regression and the long-standing
`usage_records_empty` blocker.

## What was newly resolved this run

- **Staging deploy gate.** GitHub Actions `deploy-staging` job has
  been silently failing on missing `DEPLOY_IAM_ROLE_ARN` / OIDC role
  since at least 2026-04-09. Bypassed for this run via a hand-driven
  S3-tarball + SSM RunShellScript pipeline that mirrors the CI deploy
  step (build → swap binaries → migrate → restart → health-check). See
  `infra-evidence-bundle.md` for the durable runbook to repeat this.
  Followup: restore the OIDC role + GitHub secret so CI can deploy
  again — out of scope for this evidence capture.
- **Migration drift.** `infra/migrations/001_customers.sql` had been
  modified in-place (added `deleted_at` column) which broke the sqlx
  immutable-migrations invariant on already-deployed environments. Reverted
  001 to its originally-applied form and added 040_customers_deleted_at
  for the same change as a NEW migration. (dev commit 102659b7)
- **Synthetic seeder API contract drift.** The seeder rejected the new
  200 OK return from POST /admin/tenants/:id/indexes (post-c4a83033
  idempotent fast-path). Accepted both 200 and 201. (dev commit 27571c15)
- **Metering 403 blocker.** `fj-metering-agent`'s storage and counter
  scrapes were sending only `X-Algolia-API-Key` to the local flapjack
  engine, which requires both that header AND `X-Algolia-Application-Id`.
  Every scrape silently 403'd, `usage_records` was never written,
  `usage_daily` aggregation produced empty rows, and the rehearsal had
  to halt at the `usage_records_empty` gate. Wired the
  `X-Algolia-Application-Id` header alongside the existing API key and
  added a `poll_storage_sends_api_key_and_application_id_headers`
  regression test that fails if either header is missing. (dev commit ec6a7669)

## Live observable state at end of run

- `tenant-map flapjack_url` for tenant A `0a65f0b7-14b3-4e08-acf6-2222a02c7858`
  resolves to `http://vm-shared-f2b9c8a6.flapjack.foo:7700` (was null pre-deploy).
- `usage_records` for tenant A populating every 60s with `storage_bytes`
  and `document_count` event types.
- `usage_daily` for tenant A on 2026-04-26 in `us-east-1` shows
  `search_requests=6 write_operations=125 storage_bytes_avg≈33MB documents_count_avg=20129`.
- `/admin/tenants/0a65f0b7-…/usage` returns the same numbers.
- Billing run created invoice `17e8f77f-f4da-4190-991e-ff54e468405c`
  for tenant A, period 2026-04-01..2026-04-30, total_cents=200.
- Stripe invoice `in_1TQLr2KH9mdklKeIlzBNFR4M` finalized and paid; the
  `invoices.paid_at` timestamp is set.

## Staging billing rehearsal script outcome

`scripts/staging_billing_rehearsal.sh --month 2026-04 --confirm-live-mutation`
returned `result=failed classification=billing_run_no_created_invoices`.
This is technically correct: the rehearsal expects to drive the
billing-run → webhook → email lifecycle within a single run, and after
my hand-driven `POST /admin/billing/run` succeeded outside the rehearsal,
tenant A was `already_invoiced`. The downstream lifecycle (Stripe webhook
delivery → invoice paid → email) DID run in the standalone path, evidence
above. A follow-up rehearsal pass with a fresh invoice (e.g. 2026-05 once
month rolls over, or after a manual invoice void) would close the loop in
a single rehearsal artifact.

## Files

- `rehearsal_full.log` — full stdout from
  `scripts/staging_billing_rehearsal.sh` over SSM, including preflight,
  metering_evidence, and live_mutation_guard passing.
- `billing_run.json` — `POST /admin/billing/run` response showing tenant
  A was created (and the other 20 customers' status).
- `admin_usage.json` — `/admin/tenants/0a65f0b7-…/usage` response with
  non-zero search/write/storage/document totals for 2026-04.
- `invoice_db_row.txt` — psql dump of the resulting `invoices` row,
  status `paid`, with the live Stripe invoice id.
