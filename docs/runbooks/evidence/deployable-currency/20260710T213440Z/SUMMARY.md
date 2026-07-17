# Deployable-currency SSOT — evidence bundle (20260710T213440Z)

Closes Stage 3 of the deployable-service currency-diff lane: the filename-level
classifier now has a real coded consumer, and this bundle proves the classifier
and consumer agree with a hunk-level read of HEAD.

## Owners

- **Classifier (single source of truth):** `scripts/lib/deployable_currency.sh`
  — filename-level allowlist derived from the deploy jobs in
  `.github/workflows/ci.yml`; emits `deployable_drift` / `doc_only_ahead`.
- **Consumer wiring:** `scripts/launch/post_wave_a_sync_prod.sh::check_only()`
  — reads the two booleans from the `scripts/deploy_status.sh --json` envelope
  and renders a currency status (`behind` / `converged (doc-only ahead)` /
  `current` / `unknown`). `commits_behind_main` stays as a secondary signal.

## Why (c734c false-skip motivation)

Raw `commits_behind_main` floats ahead on non-deployable commits (`chats/**`,
`matt:`/`wip:` bookkeeping, `DIRMAP.md`). That false "behind" signal made batman
`c734c` skip a whole staging billing rehearsal it should have run (see
`chats/icg/jul10_pm_4_deployable_service_currency_diff.md` and the ROADMAP P1
billing-rehearsal note). The filename-level classifier separates deployable
drift from a doc-only lead so consumers stop false-skipping.

## Artifacts

- [`finding.md`](./finding.md) — filename-level verdict for `e1db1f6d8..HEAD`
  (`deployable_drift=true` via `email.rs`) + hunk-level proof the ahead edits are
  doc-comment-only, so the compiled binary is byte-identical.
- [`email_billing_ahead.diff`](./email_billing_ahead.diff) — the raw
  `git diff e1db1f6d8..HEAD -- infra/api/src/services/email.rs infra/billing`.
- [`deploy_status_prod.json`](./deploy_status_prod.json) — live at-HEAD prod
  verdict from `scripts/deploy_status.sh --json --env prod`.
- [`deployable_currency_test.log`](./deployable_currency_test.log) — classifier
  known-answer suite (51 passed, 0 failed).
- [`post_wave_a_sync_prod_test.log`](./post_wave_a_sync_prod_test.log) — consumer
  suite incl. the two new converged/behind tests (43 passed, 0 failed).
