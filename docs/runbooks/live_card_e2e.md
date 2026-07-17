# Live Card E2E Operator Runbook

## Purpose

Execute the existing live-card owners for Privacy.com -> Stripe -> batch billing
-> webhook convergence, and preserve run-scoped evidence artifacts.

## Scope

- In scope: operator execution of existing owner scripts and tests only.
- In scope: evidence capture and blocker triage based on emitted classifications.
- Out of scope: new billing/webhook/runtime behavior or parallel mutation flows.

## Canonical Owners (No Parallel Flow)

- Main runner: `scripts/launch/live_card_e2e_test.sh`
  - owner functions: `parse_args`, `run_sweeper`, `run_billing_trigger`,
    `run_invoice_webhook_convergence`, `cleanup_resources`
- Upstream gates:
  - `scripts/lib/privacy_com_client_test.sh`
  - `scripts/launch/privacy_card_sweeper_test.sh`

## Prerequisites And Env Contract

- Environment-variable definitions live in `docs/env-vars.md` (SSOT).
- Privacy.com env loading/validation owner:
  `scripts/lib/privacy_com_client.sh::privacy_com_require_env`.
- Stripe live-key/cutover checks owner: `scripts/lib/stripe_checks.sh`.
- Admin API auth contract is owned by `admin_call` callers using `API_URL` +
  `ADMIN_KEY` (as consumed by `live_card_e2e_test.sh`).
- This runbook references owner contracts; it does not redefine variable
  semantics.

## Canonical Guarded Command Sequence

1. Focused gate chain:

```bash
bash scripts/lib/privacy_com_client_test.sh
bash scripts/launch/privacy_card_sweeper_test.sh
```

2. Production mutation run:

```bash
bash scripts/launch/live_card_e2e_test.sh --env=prod
```

3. Repo validation gates:

```bash
bash scripts/check-sizes.sh
bash scripts/local-ci.sh --full
```

## Safety And Spend Controls

- Live Stripe mutation is hard-gated: `STRIPE_LIVE_CUTOVER` must be literal `1`.
- Sweeper runs before card creation (`run_sweeper` precedes mutation steps).
- Webhook convergence polling is bounded by:
  `LIVE_E2E_CONVERGENCE_ATTEMPTS` and
  `LIVE_E2E_CONVERGENCE_SLEEP_SECONDS`.
- Cleanup is trap-backed: `exit_trap` invokes `cleanup_resources` on exit.
- Failure class is emitted in run `summary.json` via `classification`.

## Evidence Contract And Rerun Triage

- Run artifacts root:
  `docs/runbooks/evidence/privacy_com_contract/live_card_e2e/`.
- Canonical evidence index:
  `docs/runbooks/evidence/privacy_com_contract/README.md`.
- Required run artifact: `<run_id>/summary.json` (+ `logs/` captures when
  emitted by the owner).

### Known External Blocker Path

If `<run_id>/summary.json` reports
`classification=privacy_card_create_failed` and Privacy.com returns `HTTP 405`
with `max allowed Card limit` semantics:

1. Confirm gate chain still passes (`privacy_com_client_test.sh`,
   `privacy_card_sweeper_test.sh`).
2. Record the failing run directory under the evidence index.
3. Treat as external capacity unblock dependency (not a repo mutation-path
   owner gap) unless owner contract tests fail.

## Doc-Contract Validation

Re-validate owner alignment after edits:

```bash
bash scripts/launch/live_card_e2e_test_dryrun_test.sh
bash scripts/check-sizes.sh
```
