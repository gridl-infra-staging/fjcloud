# Beta Launch Readiness Checklist

This evergreen launch gate is the canonical checklist shell for paid-beta launch decisions.
The historical snapshot remains `docs/runbooks/launch_readiness_evidence_20260420.md` and is
kept as historical context only.

Mutable blocker interpretation stays owned by `ROADMAP.md`, `PRIORITIES.md`, and
`docs/runbooks/staging-evidence.md`. Paid-beta RC readiness semantics and delegated proof
meaning stay owned by `docs/runbooks/paid_beta_rc_signoff.md`.

This document is not a second roadmap and must not duplicate wrapper verdict tables.
It only points to current owners and acceptance contracts.

## Launch Status Authority

- [ ] Reconfirm preserved Stage 3 paid-beta RC ownership before interpreting launch state.
      Owner: `ROADMAP.md`, `PRIORITIES.md`, `docs/runbooks/staging-evidence.md`, `docs/runbooks/paid_beta_rc_signoff.md`, `scripts/launch/run_full_backend_validation.sh --paid-beta-rc`
      Acceptance: The checklist mirrors the preserved coordinator artifact pointer, `ready=false`, `verdict=fail`, and the RC rerun owner command without copying blocker prose.
      Status: Preserved artifact remains `/Users/stuart/.matt/projects/fjcloud_dev-fbeae273/apr23_pm_6_launch_coordination_and_rc_signoff.md-998f7042/artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_result.json` with `ready=false` and `verdict=fail`.

## Billing And Metering Proof Owners

- [ ] Keep synthetic-traffic and billing rehearsal lanes anchored to existing owners.
      Owner: `scripts/launch/seed_synthetic_traffic.sh`, `docs/launch/synthetic_traffic_seeder_plan.md`, `scripts/staging_billing_rehearsal.sh`
      Acceptance: Synthetic traffic and credentialed billing evidence stay delegated to their canonical owners, and `docs/runbooks/staging_billing_dry_run.md` remains the rehearsal runbook reference.
      Status: The seeder is now implemented in-repo and covered by `scripts/tests/seed_synthetic_traffic_test.sh`, but its truthful live surface is still partial: execute mode supports Tenant A only and rejects B/C/all. The 2026-04-26 metering runtime fixes resolved the earlier direct-node `GET /internal/storage` HTTP 403 path, so the remaining work is a fresh current-main Tenant A rerun plus canonical evidence artifacts rather than re-debugging that storage poll.
      Supplementary dispatch prerequisite: dispatches that source only `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret` still miss `DATABASE_URL`, `API_URL`, `ADMIN_KEY`, and `FLAPJACK_URL`; use the canonical hydration owner in `docs/launch/synthetic_traffic_seeder_plan.md` instead of treating that env gap as the current billing blocker.

- [ ] Keep `/billing/portal` ownership anchored to the landed backend/frontend seams.
      Owner: `chats/icg/apr24_1pm_t2_3_stripe_customer_portal.md`, `infra/api/src/router/route_assembly.rs`, `docs/screen_specs/dashboard_billing.md`, `web/tests/e2e-ui/full/billing.spec.ts`, `web/tests/e2e-ui/full/dashboard.spec.ts`
      Acceptance: Readiness notes point at the landed route owner, billing-page action, and tests without overstating live credentialed proof beyond what the checked-in evidence supports.
      Status: `POST /billing/portal` and `/dashboard/billing` ownership remain landed in the listed backend/frontend seams. As of 2026-04-25, billing-portal proof remains blocked by staging auth/preconditions (`classification=precondition_blocked`), Stage 4 never opened, and no checked-in `/billing/portal` defect is proven; see `docs/runbooks/staging-evidence.md` for the canonical artifact pointers and detailed verdict.

## Runtime And Infra Wrapper Owners

- [ ] Keep runtime and infra evidence delegated to wrapper and runtime-smoke owners.
      Owner: `scripts/launch/live_e2e_evidence.sh`, `ops/terraform/tests_stage7_runtime_smoke.sh`, `docs/runbooks/aws_live_e2e_guardrails.md`, `docs/runbooks/staging-evidence.md`, `chats/icg/apr24_1pm_t2_1_stage7_runtime_rerun.md`
      Acceptance: Runtime readiness references wrapper and runtime-smoke owners directly and does not restate wrapper `summary.json` interpretation tables.
      Status: Runtime evidence updates remain pointer-based through staging evidence plus wrapper artifacts; the preserved 2026-04-24 wrapper artifact is still historically red, but a fresh direct `ops/terraform/tests_stage7_runtime_smoke.sh` rerun passed on 2026-04-25 after the checked-in DNS contract was reconciled to the live ALB/Pages split. Runtime-smoke is no longer an active blocker; keep wrapper-scoped reruns delegated if launch packaging needs a fresh top-level artifact.

## SES Deliverability Owners

- [ ] Keep SES sender identity and residual deliverability boundaries delegated to canonical owners.
      Owner: `docs/runbooks/email-production.md`, `scripts/validate_ses_readiness.sh`, `scripts/launch/ses_deliverability_evidence.sh`, `docs/runbooks/evidence/ses-deliverability/`, `chats/icg/apr24_1pm_t1_2_ses_boundary_proof.md`
      Acceptance: `system@flapjack.foo` remains the canonical sender identity, and SPF, MAIL FROM, bounce/complaint, first-send, and inbox-receipt boundaries remain explicitly unproven until owner evidence lands.
      Status: Current committed evidence remains under `docs/runbooks/evidence/ses-deliverability/`, including `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/`. Sender identity, DKIM, SPF, and custom MAIL FROM reconciliation are preserved; first-send retrieval plus bounce/complaint/inbox proof remain explicitly open.

## Customer-Facing Surface Owners

- [ ] Keep legal-route ownership anchored to landed public route files and existing risk owner notes.
      Owner: `web/src/routes/terms/+page.svelte`, `web/src/routes/privacy/+page.svelte`, `web/src/routes/dpa/+page.svelte`, `docs/checklists/apr21_pm_2_post_phase6_gaps_and_risks.md`
      Acceptance: Legal route ownership stays tied to the landed route files, with downstream verification explicitly cited via `docs/screen_specs/landing.md`, `docs/screen_specs/beta.md`, and `web/tests/e2e-ui/full/public-pages.spec.ts`.
      Status: Landed legal routes remain the canonical repo-owned legal surface; downstream screen-spec and browser-route verification coverage remains pointer-owned by `docs/screen_specs/landing.md`, `docs/screen_specs/beta.md`, and `web/tests/e2e-ui/full/public-pages.spec.ts`.

- [ ] Keep `/pricing` ownership anchored to the landed public-route seam.
      Owner: `chats/icg/apr24_1pm_t1_3_pricing_page_route.md`, `web/src/lib/pricing.ts`, `docs/screen_specs/landing.md`, `web/src/routes/pricing/+page.svelte`, `docs/screen_specs/pricing.md`
      Acceptance: Readiness notes point at the landed route, its screen spec, and its component/browser coverage without duplicating pricing constants outside the existing pricing owner.
      Status: `/pricing` is now implemented in-repo as a public route backed by `MARKETING_PRICING`, with `docs/screen_specs/pricing.md`, route-level tests, and public-pages browser coverage preserving the current contract.

## External And Operator Obligations

- [ ] Track non-repo legal and operator obligations with explicit external-owner labels.
      Owner: external-owner:legal_counsel, external-owner:beta_operator
      Acceptance: External legal approvals, policy acknowledgements, and operator runtime obligations are tracked by named external owners; repo docs only store owner pointers and evidence seams.
      Status: External obligations remain open until external owners provide sign-off artifacts referenced by canonical repo owners.
