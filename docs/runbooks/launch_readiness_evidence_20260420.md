# Launch Readiness Evidence — 2026-04-20

Concise launch-readiness evidence snapshot for the current checked-in repo state.

This file is intentionally not a second roadmap. It links the canonical docs that own the underlying status and records the exact evidence surfaces a future session should check first.
For the evergreen checklist shell that points at those owners, use [`docs/runbooks/beta_launch_readiness.md`](./beta_launch_readiness.md).

## Summary Table

| Area                      | Status                                   | Evidence                                                                                                                                                                            | Next Owner                               |
| ------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------- |
| Local signoff             | COMPLETE (local evidence)                | Canonical local signoff contract in [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md) and the Apr 19 run-scoped pass referenced by current roadmap/priorities status | None for local-only scope                |
| Staging infra             | DEPLOYED                                 | [`docs/runbooks/staging-evidence.md`](./staging-evidence.md) and [`docs/runbooks/staging-validation-20260409.md`](./staging-validation-20260409.md)                                 | Infra / launch docs                      |
| Browser signoff           | COMPLETE (supported-runtime local slice) | Current checked-in browser status in [`ROADMAP.md`](../../ROADMAP.md)                                                                                                               | None for current supported-runtime slice |
| Cloudflare and DNS        | COMPLETE for staging public access       | DNS cutover update in [`docs/runbooks/staging-evidence.md`](./staging-evidence.md)                                                                                                  | None unless public DNS changes again     |
| Billing dry run           | PREP COMPLETE, EXECUTION OUTSTANDING     | [`docs/runbooks/staging_billing_dry_run.md`](./staging_billing_dry_run.md), [`ROADMAP.md`](../../ROADMAP.md), [`PRIORITIES.md`](../../PRIORITIES.md)                                | Credentialed staging billing lane        |
| Remaining launch blockers | LIVE CREDENTIALS / EVIDENCE              | Current open items in [`ROADMAP.md`](../../ROADMAP.md) and [`PRIORITIES.md`](../../PRIORITIES.md)                                                                                   | Launch owner                             |

This table is a historical 2026-04-20 snapshot. Current blocker interpretation
must come from canonical owners:
[`docs/runbooks/paid_beta_rc_signoff.md`](./paid_beta_rc_signoff.md) for RC
JSON readiness semantics and
[`docs/runbooks/aws_live_e2e_guardrails.md`](./aws_live_e2e_guardrails.md) for
live wrapper `summary.json` lane semantics.

## Local Signoff

- Canonical command: `bash scripts/local-signoff.sh`
- Canonical scope and proof contract: [`docs/LOCAL_LAUNCH_READINESS.md`](../LOCAL_LAUNCH_READINESS.md)
- Current checked-in status:
  - `ROADMAP.md` and `PRIORITIES.md` treat P0 local simulation as complete.
  - Current roadmap text records SeaweedFS cold-tier local evidence and HA repeatability local evidence as complete from the Apr 19 run-scoped local-signoff pass.
- Historical artifact note:
  - The stopped Apr 19 session recorded an observed temp artifact path at `/var/folders/5y/d6m1nn955w3cb95hg45ljzvr0000gn/T/fjcloud-local-signoff-20260419T225911Z-54599`.
  - That temp artifact is no longer present in this workspace, so treat the checked-in docs above as the durable evidence source.

## Staging Infra

- Canonical infrastructure evidence: [`docs/runbooks/staging-evidence.md`](./staging-evidence.md)
- Historical live validation snapshot: [`docs/runbooks/staging-validation-20260409.md`](./staging-validation-20260409.md)
- Current staging evidence highlights:
  - EC2, API, RDS, and CloudWatch evidence are already captured in the staging evidence bundle.
  - Historical ALB port, EC2 root-volume, and TLS cargo-audit findings are recorded as resolved in code.
  - `psql` missing on EC2 remains a low-priority ops convenience issue.

## Browser Signoff

- Canonical status owner: [`ROADMAP.md`](../../ROADMAP.md)
- Current checked-in status:
  - The supported-runtime live slice passed on `2026-04-20`.
  - The roadmap records passing preflight, shared auth setup, `settings.spec.ts`, `admin/customer-detail.spec.ts`, and `admin/admin-pages.spec.ts`.
- Scope note:
  - This evidence is for the supported-runtime launch slice, not full browser-matrix parity.
  - Full Firefox/WebKit parity remains a future coverage question, not a current launch blocker.

## Cloudflare And DNS

- Canonical staging DNS evidence: [`docs/runbooks/staging-evidence.md`](./staging-evidence.md)
- Current checked-in status from the `2026-04-21 DNS Cutover Update` section:
  - Public staging domain: `flapjack.foo`
  - ACM certificate status: `ISSUED`
  - SES identity and DKIM status: `SUCCESS`
  - Public health check at `https://api.flapjack.foo/health` returned `200`
- Implication:
  - Cloudflare/DNS is no longer the primary staging blocker if the staging evidence doc is the source of truth.
  - The remaining environment-blocked item in that same runbook is Stripe staging credentials.

## Billing Dry Run

- Canonical prep runbook: [`docs/runbooks/staging_billing_dry_run.md`](./staging_billing_dry_run.md)
- Current checked-in status:
  - Safe preflight/prep is implemented.
  - Full credentialed staging billing evidence is still outstanding.
- Canonical open-work item:
  - `ROADMAP.md` still tracks “End-to-end billing dry-run evidence against a credentialed test environment” as open.
- Command surface for the prep lane:
  - `bash scripts/staging_billing_dry_run.sh --check --env-file .secret/.env.secret`

## Deferred And Future

- Live credential validation for AWS/Stripe/GitHub Actions
- Credentialed staging billing dry run
- AWS live-infra E2E guardrails
- Cross-browser expansion beyond the targeted supported-runtime launch slice

## Notes

- This bundle prefers canonical links over copied status text so future updates only have one real owner.
- If roadmap/priorities wording and the staging evidence runbook diverge, use the newer dated evidence section in `docs/runbooks/staging-evidence.md` to determine whether Cloudflare/DNS is still actually blocking staging.
- Do not add copied status tables that restate wrapper `summary.json` output, `ROADMAP.md`, or `PRIORITIES.md`.
