# Stage 3 Summary - 2026-07-10 Current Main Billing Rehearsal

## Bundle Of Record

This stage evaluates `docs/runbooks/evidence/staging-billing-rehearsal/20260710T162220Z_current_main/`.

## Deployed Target

- Dev SHA: `e1db1f6d8b879f6d858970dc73c292a1df58168e`
- Staging mirror SHA reported by `/version`: `8073bf44df45a29cbee869bc37074e02c6aae434`
- Build time: `2026-07-10T16:03:46Z`
- Synced at: `2026-07-10T15:58:28Z`

## Commands Used

Local deploy gate:

```bash
bash scripts/local-ci.sh --fast
```

Staging sync and version convergence:

```bash
debbie sync staging
curl -fsS https://api.staging.flapjack.foo/version | jq .
```

Reset gates:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 193638a5-35f7-407f-a734-3f73de224336
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 9ef0c894-b3f1-4d78-bc50-949433ded7b3
```

Final live rehearsal:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --month 2026-07 --confirm-live-mutation
```

The final live command emitted artifact dir `/var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//fjcloud_staging_billing_rehearsal_20260710T162220Z_900`.

## Copied Owner Artifacts

- `summary.json`
- `billing_run.json`
- `invoice_rows.json`
- `webhook.json`
- `invoice_email.json`
- `steps/`
- `version.json`
- `reset_193638a5_summary.json`
- `reset_9ef0c894_summary.json`

## Machine Validation

```bash
jq -e '.result == "passed" and .classification == "rehearsal_completed"' docs/runbooks/evidence/staging-billing-rehearsal/20260710T162220Z_current_main/summary.json
jq -e '.payload.evidence_source == "aws_cloudwatch_logs_ses_send_events" and .payload.emails_with_messages == 2 and (.payload.ses_message_ids | length) == 2 and (.payload.missing_invoice_ids | length) == 0' docs/runbooks/evidence/staging-billing-rehearsal/20260710T162220Z_current_main/invoice_email.json
jq -r '.payload.invoice_ids[]?' docs/runbooks/evidence/staging-billing-rehearsal/20260710T162220Z_current_main/billing_run.json
jq -r '.payload.missing_invoice_ids[]?' docs/runbooks/evidence/staging-billing-rehearsal/20260710T162220Z_current_main/invoice_email.json
```

## Owner Classification

Copied `summary.json`:

- `result`: `passed`
- `classification`: `rehearsal_completed`
- `detail`: `Live billing mutation completed with DB, webhook, and invoice-email evidence.`

Supporting copied artifacts:

- `billing_run.json`: `result=passed`, `classification=billing_run_succeeded`, invoice IDs `cf65e829-4948-41b2-9081-4640c2e0b61b` and `9e2cc75a-558c-476c-8a7c-55b501c81c12`.
- `invoice_rows.json`: `result=passed`, `classification=invoice_rows_ready`.
- `webhook.json`: `result=passed`, `classification=webhook_ready`.
- `invoice_email.json`: `result=passed`, `classification=invoice_email_ready`, `evidence_source=aws_cloudwatch_logs_ses_send_events`, `emails_with_messages=2`, `missing_invoice_ids=0`.

## Verdict

`rehearsal_completed`.

The canonical staging billing rehearsal now reaches billing, invoice-row, webhook, and SES invoice-email evidence closure. The SES evidence is sourced from CloudWatch Logs events emitted by the SES configuration-set event destination and correlated by the `invoice_id` message tag.
