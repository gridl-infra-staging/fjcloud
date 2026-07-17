# Stage 2 Summary - 20260709T144534Z Current-Main Rerun

## Bundle Of Record
This bundle preserves the Stage 2 owner rehearsal emitted by
`scripts/staging_billing_rehearsal.sh` for current `main`.

Final verdict: red. The preserved `summary.json` is the run-level single source
of truth and reports `result="failed"` with
`classification="invoice_email_ses_not_ready"`.

## Pre-Mutation Eligibility Snapshot
Pre-reset live-state probe:
- stdout: `probe_live_state.stdout.txt`
- stderr: `probe_live_state.stderr.txt`
- emitted summary path: `probe_live_state_summary_path.txt`
- copied summary: `pre_mutation_live_state_SUMMARY.md`

Post-probe deploy gate:
- `post_probe_deploy_status.stdout.json` reported
  `dev_main_sha=2439169a1b9a85b454a63c15ee05879d6ea60465`,
  `envs.staging.dev_sha=2439169a1b9a85b454a63c15ee05879d6ea60465`,
  `mirror_sha=3bab197306dff4afc2e21a4e6be3d6ff8408b78c`, and
  `commits_behind_main="0"`.
- `post_probe_health.stdout.json` reported `{"status":"ok"}`.
- `post_probe_billing_surface_diff.txt` is empty.

## Commands
Initial checklist-prescribed reset:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 193638a5-35f7-407f-a734-3f73de224336
```

First live run:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --month 2026-07 --confirm-live-mutation
```

The first live run exited 0 but reported
`billing_run_repeat_pass_existing_same_month_invoice` for the second allowlisted
tenant. A second owner reset was run for that same allowlisted tenant before the
final live attempt:

```bash
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --reset-test-state --confirm-test-tenant 9ef0c894-b3f1-4d78-bc50-949433ded7b3
bash scripts/staging_billing_rehearsal.sh --env-file .secret/.env.secret --month 2026-07 --confirm-live-mutation
```

## Artifact Inventory
Preserved from the final live artifact directory:
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

Additional stdout and command captures:
- `reset_stdout.json`
- `live_stdout.json`
- `reset_summary_fields.txt`
- `live_summary_fields.txt`
- `initial_reset_stdout.json`
- `first_live_stdout.json`
- `initial_reset_summary_fields.txt`
- `first_live_summary_fields.txt`
- `reset_command.txt`
- `live_command.txt`
- `initial_reset_command.txt`
- `first_live_command.txt`

## Machine Verdict
Required green gate:

```bash
jq -e '.result == "passed" and .classification == "rehearsal_completed"' docs/runbooks/evidence/staging-billing-rehearsal/20260709T144534Z_current_main/summary.json
```

Result: failed with exit 1.

Observed run-level failure:

```text
classification=invoice_email_ses_not_ready
detail=SES SendEmail CloudTrail evidence is missing invoice-ID-correlated sends. (attempts=15).
```

## Stage 3 Handoff
Do not hand-edit these artifacts or soften the classification. Stage 3 should
root-cause why the existing owner path reached billing, invoice rows, and
webhook evidence but did not converge on invoice-ID-correlated SES SendEmail
CloudTrail evidence within the owner retry budget.
