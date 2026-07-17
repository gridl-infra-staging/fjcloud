# Staging Billing Rehearsal Repeatability Evidence

Pointer-only owner for the June 2026 same-month staging billing rehearsal
repeatability proof.

Operational procedure remains owned by
`docs/runbooks/staging_billing_dry_run.md` and
`scripts/staging_billing_rehearsal.sh`. This runbook only records where the
durable, machine-readable proof lives.

## Purpose

- Point to the pre-mutation live-state baseline for the repeatability rehearsal.
- Point to the direct repeatability runs that prove same-month reruns classify
  as `billing_run_repeat_pass_existing_same_month_invoice`.
- Point to the staging-only RC dry-run summary that shows the delegated
  `staging_billing_rehearsal` step passed while unrelated RC lanes kept the
  overall verdict failing.

## Non-Goals

- Do not duplicate the rehearsal run/reset procedure.
- Do not copy JSON blobs, invoice identifiers, customer details, secrets, or
  local artifact paths into this runbook.
- Do not close webhook, browser, SES, roadmap, or launch-status lanes here.

## Evidence Pointers

Stage 3 baseline snapshot:

- `docs/live-state/20260611T003355Z/`
- `docs/live-state/20260611T003355Z/SUMMARY.md`

This is the pre-mutation live-state baseline captured by
`scripts/probe_live_state.sh`.

Stage 4 direct repeatability bundle:

- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/`
- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_1.stdout.json`
- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_2.stdout.json`
- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_1_artifacts/`
- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_2_artifacts/`

The direct run JSON files are the machine-readable owners for the repeat-pass
classification:
`billing_run_repeat_pass_existing_same_month_invoice`.

Stage 4 staging-only RC dry-run pointer:

- `docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/rc_summary.json`

The RC summary records the `staging_billing_rehearsal` step as passing. The
overall staging-only verdict remains failing because unrelated RC lanes did not
pass.

## Reproducible Validation

Validate the evidence paths:

```bash
test -d docs/live-state/20260611T003355Z &&
test -f docs/live-state/20260611T003355Z/SUMMARY.md &&
test -d docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z &&
test -d docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_1_artifacts &&
test -d docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_2_artifacts
```

Validate both direct run summaries:

```bash
jq -e '.result == "passed" and .classification == "billing_run_repeat_pass_existing_same_month_invoice"' \
  docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_1.stdout.json

jq -e '.result == "passed" and .classification == "billing_run_repeat_pass_existing_same_month_invoice"' \
  docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/direct_run_2.stdout.json
```

Validate the RC summary pointer:

```bash
jq -e '.steps[] | select(.name == "staging_billing_rehearsal") | .status == "pass" and (.reason == null or .reason == "")' \
  docs/runbooks/evidence/staging-billing-rehearsal-repeatability/20260611T005107Z/rc_summary.json
```

Audit this pointer owner:

```bash
grep -n "20260611T003355Z\|20260611T005107Z\|billing_run_repeat_pass_existing_same_month_invoice" \
  docs/runbooks/staging_billing_rehearsal_repeatability.md
```
