# Stage 3 Summary - 20260709T151136Z Current-Main Rerun

## Bundle Of Record

This bundle preserves the Stage 3 wrapper-owned rehearsal emitted by
`scripts/staging_billing_rehearsal.sh` after the SES CloudTrail pagination
regression was fixed in the rehearsal evidence owner.

Final verdict: red. The preserved `summary.json` is the run-level single source
of truth and reports `result="failed"` with
`classification="invoice_email_ses_not_ready"`.

## Commands

Allowlisted reset for the failed-transition tenant:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 193638a5-35f7-407f-a734-3f73de224336
```

Allowlisted reset for the suspended-transition tenant:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 9ef0c894-b3f1-4d78-bc50-949433ded7b3
```

Final live mutation attempt:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --month 2026-07 --confirm-live-mutation
```

The final live command exited 1 with:

```text
classification=invoice_email_ses_not_ready
detail=SES SendEmail CloudTrail evidence is missing invoice-ID-correlated sends. (attempts=15).
```

## Artifact Inventory

Preserved from the final live artifact directory printed in `live_stdout.json`:

- `summary.json`
- `steps/preflight.json`
- `steps/health.json`
- `steps/metering_evidence.json`
- `steps/live_mutation_guard.json`
- `steps/live_mutation_attempt.json`
- `billing_run.json`
- `invoice_rows.json`
- `webhook.json`
- `invoice_email.json`

Additional command captures:

- `reset_tenant_1_command.txt`
- `reset_tenant_1_stdout.json`
- `reset_tenant_1_stderr.txt`
- `reset_tenant_1_exit.txt`
- `reset_tenant_1_summary_fields.txt`
- `reset_tenant_2_command.txt`
- `reset_tenant_2_stdout.json`
- `reset_tenant_2_stderr.txt`
- `reset_tenant_2_exit.txt`
- `reset_tenant_2_summary_fields.txt`
- `live_command.txt`
- `live_stdout.json`
- `live_stderr.txt`
- `live_exit.txt`
- `live_summary_fields.txt`

## Diagnosis

The lane-owned rehearsal defect was CloudTrail pagination: the SES fallback path
only evaluated the first `lookup-events` page. The focused regression in
`scripts/tests/staging_billing_rehearsal_test.sh` now proves the Mailpit-absent
path follows `NextToken` and finds invoice-correlated SES events on a later page.

After that fix, this live rerun still reached billing, invoice rows, and webhook
evidence, then failed only at SES invoice-email evidence:

- `billing_run.json` reports `classification="billing_run_succeeded"` and
  `POST /admin/billing/run returned 2 created invoice(s).`
- `invoice_rows.json` reports `classification="invoice_rows_ready"` for two
  required invoice IDs.
- `webhook.json` reports `classification="webhook_ready"` for the same two
  required invoice IDs.
- `invoice_email.json` reports `emails_required=2`, `emails_with_messages=0`,
  and missing invoice IDs `fc8d7af6-d5fa-4b61-b33f-612d8d3dbad0` and
  `daf86172-6c20-44ba-907e-d928b69983fd`.

## Machine Verdict

Required green gate:

```bash
jq -e '.result == "passed" and .classification == "rehearsal_completed"' docs/runbooks/evidence/staging-billing-rehearsal/20260709T151136Z_current_main/summary.json
```

Result: failed with exit 1.

Product-defect handoff:
`chats/icg/stubs/jul07_3pm_15_invoice_email_ses_send_gap.md`.

Do not hand-edit these artifacts or soften the classification. The preserved
red verdict is the honest Stage 3 outcome after the lane-owned evidence
pagination bug was removed.
