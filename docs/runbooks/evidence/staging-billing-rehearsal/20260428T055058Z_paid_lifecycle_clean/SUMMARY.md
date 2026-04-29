# Stage 1 Summary — 2026-04-28 Paid Lifecycle Bundle

## Bundle Of Record
This stage evaluates only `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/` as the bundle of record.
`docs/runbooks/evidence/staging-billing-rehearsal/20260426T060756Z_paid_lifecycle/SUMMARY.md` was used only as formatting precedent.

## Artifact Inventory
Present artifacts:
- `summary.json`
- `billing_run.json`
- `invoice_rows.json`
- `webhook.json`
- `invoice_email.json`
- `reset_summary_fields.txt`
- `live_summary_fields.txt`
- `invoice_db_row.json`
- `invoice_line_items.json`
- `customer_billing_context.json`
- `rate_card_selection.json`
- `customer_rate_override.json`
- `usage_daily_replay_rows.json`
- `usage_records_provenance.json`
- `cross_check_result.json`
- `cross_check_computation.md`

## Owner-Shape Contract (Required vs Optional/Delegated)
Owner scripts reviewed:
- `scripts/staging_billing_rehearsal.sh`
- `scripts/lib/staging_billing_rehearsal_flow.sh`
- `scripts/lib/staging_billing_rehearsal_reset.sh`
- shape/evidence owners used by the wrapper: `scripts/lib/staging_billing_rehearsal_impl.sh`, `scripts/lib/staging_billing_rehearsal_evidence.sh`, `scripts/lib/staging_billing_rehearsal_email_evidence.sh`, `scripts/lib/staging_billing_rehearsal_live_mutation.sh`

Current required fields:
- `billing_run.json`: created invoice IDs extracted from `response.results[].status=="created"`.
- `invoice_rows.json`: each required invoice ID must have `stripe_invoice_id`, `paid_at`, and `email`; missing any of these is `invoice_rows_missing_required_fields`.
- `webhook.json`: each required invoice ID must have `processed_at` set for `invoice.payment_succeeded` correlation.
- `summary.json`: success path ends at `classification="rehearsal_completed"`.

Current optional/delegated path:
- `invoice_email.json` may intentionally be delegated when `MAILPIT_API_URL` is unset; classification is `invoice_email_evidence_delegated` with empty `required_pairs` payload and SES-backed owner noted as authoritative.

## Invoice/Webhook Lifecycle Consistency Checks
Observed values:
- Created invoice ID (`billing_run.json`): `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3`
- Invoice row ID (`invoice_rows.json`): `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3`
- Webhook row ID (`webhook.json`): `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3`
- Stripe invoice ID (rows + webhook): `in_1TR4Y2KH9mdklKeI6OXXpo17`
- `paid_at` present: `2026-04-28T05:51:09Z`
- `processed_at` present: `2026-04-28T05:51:09Z`

Verdict:
- `created_ids == invoice_row_ids == webhook_ids`: PASS
- No ID-set mismatch found.

## Reset/Live Consistency Checks
Field captures:
- `reset_summary_fields.txt`: `classification=reset_completed`, artifact dir `/tmp/fjcloud_staging_billing_rehearsal_20260428T055100Z_13642`
- `live_summary_fields.txt`: `classification=rehearsal_completed`, artifact dir `/tmp/fjcloud_staging_billing_rehearsal_20260428T055105Z_13831`
- `summary.json`: `result=passed`, `classification=rehearsal_completed`

Interpretation:
- Reset evidence reflects a separate, earlier reset lane and does not contradict paid-lifecycle evidence.
- The later live classification (`rehearsal_completed`) aligns with paid invoice row + paid webhook timestamps in this bundle.

## Amount Cross-Check Verdict
`CROSS_CHECK_PASSED`

Reason:
- Stage 2 proof owner `infra/api/tests/billing_regression_test.rs::shared_plan_staging_bundle_known_answer_regression` was rerun and passed against this bundle before publishing this verdict.
- Machine-readable verdict SSOT is `cross_check_result.json`, which records persisted invoice values (`invoice_db_row.json`) and Stage 2 generated known-answer values at zero-cent tolerance (`exact_match.subtotal_cents=true`, `exact_match.total_cents=true`, `exact_match.minimum_applied=true`).
- Operator-readable derivation is `cross_check_computation.md`, which cites the same SSOT and the one-line-item replay basis from `invoice_line_items.json`.
- Usage provenance companions now share the same replay slice: `usage_daily_replay_rows.json` contains only pre-invoice aggregates, and `usage_records_provenance.json` contains only raw rows for those captured day/region keys whose `recorded_at` does not exceed the matching replay aggregate cutoff or `invoice_db_row.created_at`.

## Deferred Dependencies / Open Questions
- Open questions: none.

## Exact Verification Commands Used
```bash
# 1) Bundle core extraction (summary + lifecycle artifacts)
jq -c '{result,classification,detail,artifact_dir,planned_steps,steps:[.steps[]|{name,result,classification,detail}]}' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/summary.json
jq -c '{name,result,classification,invoice_ids:.payload.invoice_ids,invoices_created:.payload.response.invoices_created,created_results:[.payload.response.results[]|select(.status=="created")|{customer_id,invoice_id}]}' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/billing_run.json
jq -c '{name,result,classification,required_invoice_ids:.payload.required_invoice_ids,rows:.payload.rows}' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/invoice_rows.json
jq -c '{name,result,classification,required_invoice_ids:.payload.required_invoice_ids,rows:.payload.rows}' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/webhook.json
jq -c '{name,result,classification,detail,payload}' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/invoice_email.json

# 2) ID-set comparison across billing_run/invoice_rows/webhook
created_ids=$(jq -r '.payload.invoice_ids[]?' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/billing_run.json | sort -u)
row_ids=$(jq -r '.payload.rows[].invoice_id' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/invoice_rows.json | sort -u)
webhook_ids=$(jq -r '.payload.rows[].invoice_id' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/webhook.json | sort -u)
[ "$created_ids" = "$row_ids" ] && echo created_vs_rows=match || echo created_vs_rows=mismatch
[ "$row_ids" = "$webhook_ids" ] && echo rows_vs_webhook=match || echo rows_vs_webhook=mismatch

# 3) Reset/live field capture check
cat docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/reset_summary_fields.txt docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/live_summary_fields.txt

# 4) Pricing SSOT + known-answer branch reference (read-only grep)
rg -n "storage_rate_per_mb_month|shared_minimum_spend_cents|dec!\(0.05\)|500" infra/billing/src/rate_card.rs infra/api/tests/billing_regression_test.rs

# 5) Observed-amount retrieval attempt from real owner (deferred)
source scripts/lib/env.sh
source scripts/lib/psql_path.sh
load_env_file .env.local.pre-signoff-backup
invoice_id=$(jq -r '.payload.invoice_ids[0]' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/billing_run.json)
psql -tAq "$DATABASE_URL" -c "SET statement_timeout TO 10000; SELECT id::text, customer_id::text, plan, subtotal_cents, total_cents, minimum_spend_applied, stripe_invoice_id, to_char(period_start,'YYYY-MM-DD'), to_char(period_end,'YYYY-MM-DD'), to_char(paid_at AT TIME ZONE 'utc','YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') FROM invoices WHERE id = '$invoice_id'::uuid;"
# Result in this session: connection refused to localhost:35432
```

## Source Citations
- Bundle artifacts:
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/summary.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/billing_run.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/invoice_rows.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/webhook.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/invoice_email.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/reset_summary_fields.txt`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/live_summary_fields.txt`
- Artifact-shape owners:
  - `scripts/staging_billing_rehearsal.sh`
  - `scripts/lib/staging_billing_rehearsal_impl.sh`
  - `scripts/lib/staging_billing_rehearsal_evidence.sh`
  - `scripts/lib/staging_billing_rehearsal_email_evidence.sh`
  - `scripts/lib/staging_billing_rehearsal_live_mutation.sh`
  - `scripts/lib/staging_billing_rehearsal_flow.sh`
  - `scripts/lib/staging_billing_rehearsal_reset.sh`
- Pricing SSOT and branch reference:
  - `infra/billing/src/rate_card.rs`
  - `infra/api/tests/billing_regression_test.rs`
