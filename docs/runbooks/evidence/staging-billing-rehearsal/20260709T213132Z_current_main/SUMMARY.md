# Stage 2 Summary - 2026-07-09 Current Main Billing Rehearsal

## Bundle Of Record

This stage evaluates `docs/runbooks/evidence/staging-billing-rehearsal/20260709T213132Z_current_main/`.

## Commands Used

Setup:

```bash
RUN_TS="$(date -u +%Y%m%dT%H%M%SZ)"
EVIDENCE_DIR="docs/runbooks/evidence/staging-billing-rehearsal/${RUN_TS}_current_main"
mkdir -p "$EVIDENCE_DIR"
scripts/staging_billing_rehearsal.sh --help
cat docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/SUMMARY.md
```

Credential derivation ran in a no-echo shell. The first reset used the first allowlisted tenant, then the first live run classified as `billing_run_repeat_pass_existing_same_month_invoice`. The final accepted reset reran with that live tenant only after confirming it was present in `FJCLOUD_TEST_TENANT_IDS`; raw secret and tenant allowlist values were not printed.

Final reset gate:

```bash
scripts/staging_billing_rehearsal.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --reset-test-state --confirm-test-tenant "$ALLOWLISTED_TENANT_UUID" > "$EVIDENCE_DIR/reset.stdout.json"
jq -e '.result=="passed" and .classification=="reset_completed"' "$EVIDENCE_DIR/reset.stdout.json"
```

Final live rehearsal:

```bash
scripts/staging_billing_rehearsal.sh --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --month "$BILLING_MONTH" --confirm-live-mutation > "$EVIDENCE_DIR/live.stdout.json"
LIVE_ARTIFACT_DIR="$(jq -r '.artifact_dir' "$EVIDENCE_DIR/live.stdout.json")"
test -d "$LIVE_ARTIFACT_DIR"
cp "$LIVE_ARTIFACT_DIR"/summary.json "$LIVE_ARTIFACT_DIR"/billing_run.json "$LIVE_ARTIFACT_DIR"/invoice_rows.json "$LIVE_ARTIFACT_DIR"/webhook.json "$LIVE_ARTIFACT_DIR"/invoice_email.json "$EVIDENCE_DIR"/
```

## Copied Owner Artifacts

- `summary.json`
- `billing_run.json`
- `invoice_rows.json`
- `webhook.json`
- `invoice_email.json`
- `reset.stdout.json`
- `live.stdout.json`

## Owner Classification

Copied `summary.json`:

- `result`: `failed`
- `classification`: `invoice_email_ses_not_ready`
- `detail`: `SES SendEmail CloudTrail evidence is missing invoice-ID-correlated sends. (attempts=15).`

Supporting copied artifacts:

- `billing_run.json`: `result=passed`, `classification=billing_run_succeeded`, `invoice_ids` count 2.
- `invoice_rows.json`: `result=passed`, `classification=invoice_rows_ready`.
- `webhook.json`: `result=passed`, `classification=webhook_ready`.
- `invoice_email.json`: `result=failed`, `classification=invoice_email_ses_not_ready`, `emails_required=2`, `emails_with_messages=0`.

## Verdict

`invoice_email_ses_not_ready`.

The canonical staging billing rehearsal reached billing, invoice-row, and webhook evidence closure, then parked on missing SES SendEmail CloudTrail evidence for the created invoice IDs. No lane-owned rehearsal owner defect was fixed in this stage.
