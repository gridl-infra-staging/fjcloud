# Local Launch Readiness

Local-only signoff checklist for Flapjack Cloud before AWS credentials, real Stripe, SES, DNS, or production cloud providers enter the picture.

This document answers one question: what do we need to prove locally to believe the product is operationally polished enough for live-customer launch work?

## Purpose

- Keep local launch validation in one place instead of spreading it across `README.md`, `ROADMAP.md`, browser specs, and runbooks.
- Define what is in scope for local confidence now.
- Define what is explicitly deferred until live-credential validation.
- Give each validation workstream a concrete pass bar and evidence expectation.

## Canonical Docs

- Setup and troubleshooting: [`docs/LOCAL_DEV.md`](./LOCAL_DEV.md)
- Day-to-day operator commands: [`docs/runbooks/local-dev.md`](./runbooks/local-dev.md)
- Paid-beta RC coordinator usage: [`docs/runbooks/paid_beta_rc_signoff.md`](./runbooks/paid_beta_rc_signoff.md)
- Execution checklist: [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](./checklists/LOCAL_SIGNOFF_CHECKLIST.md)
- Evidence template: [`docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`](./checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md)
- Latest evidence snapshot: [`docs/runbooks/launch_readiness_evidence_20260420.md`](./runbooks/launch_readiness_evidence_20260420.md)
- Current project status and priorities: [`ROADMAP.md`](../ROADMAP.md)
- Environment variable contract: [`docs/env-vars.md`](./env-vars.md)
- Browser testing standards: [`BROWSER_TESTING_STANDARDS_2.md`](../BROWSER_TESTING_STANDARDS_2.md)

## In Scope

Local launch readiness covers everything below without real AWS, Stripe, SES, or DNS dependencies:

- Customer signup and login in local-dev mode
- Onboarding and customer dashboard access
- Multi-user isolation with multiple customers active at once
- Multi-region index creation against seeded local/shared VM inventory
- Document ingest, search, delete, and index detail flows
- Billing estimate visibility and synthetic-usage validation
- Customer self-service account deletion
- Admin customer list, detail, filters, suspend/reactivate, and impersonation flows
- Local failover and crash/restart validation that can run against local processes or mocks
- Local load and latency baselines for critical customer and admin routes

## Explicitly Out Of Scope

These are launch-critical later, but they are not part of local-only signoff:

- Real AWS provisioning, Route53, or cloud IAM validation
- Real Stripe payment collection, hosted checkout, or internet-facing webhook delivery
- Real SES email delivery outside the local Mailpit inbox or production email verification
- Production DNS, TLS, CDN, or internet-facing deployment checks
- GitHub Actions secrets, cron, or production scheduler validation

## Local-Only Limitations

These capabilities are simulated or absent in local mode. Operators should not
expect them to work end-to-end locally:

- **No real money movement** — local billing runs through `LocalStripeService`, so invoice generation, webhook dispatch, and `paid` transitions can run offline, but no hosted checkout or payment collection is validated.
- **No cloud-provisioned multi-region infrastructure** — when `FLAPJACK_REGIONS` is set and `seed_local.sh` runs, the local stack creates cross-region replicas across distinct region pairs (e.g., `us-east-1→eu-west-1`, `eu-west-1→us-east-1`), providing a working multi-region topology sufficient for failover proof. However, all regions are backed by local flapjack processes and `provider: local` inventory rows — no cloud provisioners are called.
- **No AWS SSM** — `ENVIRONMENT=local` plus `NODE_SECRET_BACKEND=memory` keeps node API keys in-process. There is no SSM parameter store interaction.
- **No external email deliverability proof** — when `MAILPIT_API_URL` is set and SES vars are absent, email goes to `MailpitEmailService`. Local signoff proves inbox delivery to Mailpit, not real internet delivery or SES reputation.
- **No production object-storage proof** — local cold storage can run against SeaweedFS via `COLD_STORAGE_*`, but this validates the local S3-compatible path only, not production Garage/S3 operations.
- **No production DNS/TLS** — all services run on `localhost` loopback ports without certificates.

## Local Startup Status (Resolved 2026-03-26)

The three startup failures previously listed here (SES, S3, encryption key) are now resolved. When `ENVIRONMENT=local` (or `dev` / `development`), `NODE_SECRET_BACKEND=memory`, and the relevant env vars are absent, the API uses `NoopEmailService`, `InMemoryObjectStore`, and a deterministic dev key. See [`docs/LOCAL_DEV.md`](./LOCAL_DEV.md) and [`docs/env-vars.md`](./env-vars.md) for the authoritative local runtime contract.

**Rule: The local dev stack must start and run with ZERO external service dependencies.** No AWS, no live Stripe, no SES, and no real cloud object storage. Docker (for Postgres, SeaweedFS, and Mailpit) plus a local flapjack binary are the only requirements.

## Orchestrator Contract

The canonical local signoff entry point is `./scripts/local-signoff.sh`. It:

1. Validates the strict signoff env via `require_strict_signoff_env` (requires
   `STRIPE_LOCAL_MODE=1`, `MAILPIT_API_URL`, `STRIPE_WEBHOOK_SECRET`,
   `COLD_STORAGE_ENDPOINT`, `COLD_STORAGE_BUCKET`, `COLD_STORAGE_REGION`,
   `FLAPJACK_REGIONS`, `DATABASE_URL`; rejects `SKIP_EMAIL_VERIFICATION`).
2. Creates a run-scoped artifact directory under `${TMPDIR:-/tmp}/fjcloud-local-signoff-*`.
3. Delegates in deterministic order to three proof-owner scripts:
   - `scripts/local-signoff-commerce.sh` — billing, email, and local commerce mocks
   - `scripts/local-signoff-cold-storage.sh` — SeaweedFS-backed cold-storage round-trip
   - `scripts/chaos/ha-failover-proof.sh` — HA failover kill/detect/promote/recover cycle
4. Uses **fail-fast** semantics: if a proof fails, later proofs are skipped.
5. Writes `summary.json` to the artifact directory with per-proof status
   (`pass`, `fail`, or `not_run`) and failure classification.
6. Prints a human summary with per-proof `PASS`, `FAIL`, or `SKIP` labels.

Use `--only {commerce|cold-storage|ha}` to rerun a single proof after a failure.

## Entry Criteria

Before running the launch-readiness matrix, complete the local stack bring-up:

- Configure `.env.local` with the recommended local-only toggles — see [`docs/LOCAL_DEV.md`](./LOCAL_DEV.md) Environment Files for the canonical values.
- Use the **strict local signoff** profile when gathering launch evidence: all env vars listed in `require_strict_signoff_env` must be set, and `SKIP_EMAIL_VERIFICATION` must be unset so the signup email flow is observable.
- Follow [`docs/checklists/LOCAL_SIGNOFF_CHECKLIST.md`](./checklists/LOCAL_SIGNOFF_CHECKLIST.md) for the exact execution order and pass bar.

## Must-Pass Areas

### 1. Customer Lifecycle

Prove:

- New local customers can sign up, log in, and land in the dashboard
- Fresh signup can emit a verification email into Mailpit when strict signoff toggles are used
- Customers can create indexes, ingest documents, search them, and delete them
- Customers can see billing estimates when synthetic usage exists
- Customers can delete their own account and cannot continue using that session afterward

Evidence:

- Passing browser specs for signup, login, settings, index lifecycle, and billing-estimate visibility
- Notes on any flows that still require seeded data or a disposable throwaway account

### 2. Multi-User Isolation

Prove:

- At least two customers can coexist in the same local stack
- Same index names do not leak metadata or search results across tenants
- Auth cookies and direct route access stay tenant-scoped

Evidence:

- Passing isolation coverage
- At least one journey using two or more independently created customers

### 3. Multi-Region Behavior

Prove:

- Local users can create indexes in multiple seeded regions
- Region-specific placements show up correctly in UI/API surfaces
- Customer-visible flows still work when indexes span more than one region

Evidence:

- Browser and API coverage using more than one seeded region
- Notes on any region-change or replica behavior backed by local processes rather than cloud-provisioned infrastructure

### 4. Admin And Support Workflows

Prove:

- Admin can find customers, open detail pages, filter by status, and inspect usage surfaces
- Admin can suspend/reactivate customers locally
- Admin can impersonate a customer, see the banner, and safely return to the exact admin detail page
- Admin can soft-delete a customer without breaking list filtering

Evidence:

- Passing deterministic admin browser specs
- No stale "not implemented" skip reasons for already-shipped admin features

### 5. Billing, Email, And Local Commerce Mocks

Prove:

- Usage metering and aggregation can be exercised with local or synthetic data
- Billing estimates render with believable line items
- LocalStripeService can finalize invoices and dispatch the local webhook path without real Stripe credentials
- Mailpit captures verification or invoice-ready emails when strict signoff toggles are used
- `scripts/seed_local.sh` auto-runs `/admin/customers/:id/sync-stripe` when `STRIPE_LOCAL_MODE=1`, so seeded local users start with Stripe linkage

Evidence:

- Commerce proof artifacts from `./scripts/local-signoff.sh` (delegated to `scripts/local-signoff-commerce.sh`); for a scoped rerun use `--only commerce`
- Mailpit evidence for the email paths exercised
- Explicit notes on what is mocked and what remains deferred to live Stripe or SES validation

### 6. Local Object Storage And Cold Restore

Prove:

- Strict signoff env uses SeaweedFS-backed cold storage rather than `InMemoryObjectStore`
- The evidence records whether a live local snapshot/restore round-trip was exercised
- The canonical cold-storage signoff command exercises a full snapshot/restore round-trip against SeaweedFS

Evidence:

- Cold-storage proof artifacts from `./scripts/local-signoff.sh` (delegated to `scripts/local-signoff-cold-storage.sh`); for a scoped rerun use `--only cold-storage`
- JSON and operator-readable evidence files emitted to the run-scoped artifact directory
- Explicit blocker text if the wrapper fails or the local stack is unavailable

### 7. Reliability, Failover, And Recovery

Prove:

- Local health-monitor logic detects unhealthy flapjack targets
- Recovery paths restore healthy status after restart
- Customer-visible flows remain available when one local flapjack target is interrupted, to the extent the local harness supports it

Evidence:

- Passing pure Rust recovery-cycle tests
- Any live local crash/restart checks record the observed promotion/recovery behavior and timing, or name the blocker exactly

### 8. Load And SLA Baselines

Prove:

- Core routes have local baseline numbers for search, ingest, index creation, admin customer list, and billing estimate access
- The harness produces repeatable local evidence rather than ad hoc screenshots only

Evidence:

- k6 or harness output checked into an agreed evidence location
- Baseline summary with pass/fail against a local target, not production assumptions

## Workstream Charters

### Workstream 1: Local Stack Validation And Runbook Hardening

Focus:

- Exercise the merged no-cloud stack end to end
- Tighten `scripts/seed_local.sh`, `scripts/local-dev-up.sh`, and the operator docs when reality differs from docs
- Add missing local evidence capture steps when manual validation reveals a gap, especially for Mailpit, SeaweedFS, and strict-signoff env selection

### Workstream 2: Browser Suite Cleanup And Expansion

Focus:

- Remove stale "feature missing" assumptions
- Prefer deterministic locally seeded coverage over env-conditional skips
- Expand multi-user, multi-region, and multi-plan journeys from the current isolation baseline

### Workstream 3: Local Billing, Reliability, And Load Validation

Focus:

- Run billing dry runs against local mocks or synthetic usage
- Execute health-monitor and failover validation that works without cloud credentials
- Capture SeaweedFS and local-email evidence alongside the billing path
- Capture local load baselines and define the gaps that only staging/live credentials can close

## Blocker Classification

The orchestrator's `classify_failure` function normalizes every proof failure
into one of four classes. Use these labels in evidence notes, deferred-item
lists, and handoff summaries:

| Class | Meaning |
|-------|---------|
| `local_harness_gap` | Missing mock, stub, or test fixture — a local tooling limitation, not a product defect |
| `live_credential_required` | Failure requires real credentials (AWS, Stripe, SES) that the local stack cannot provide |
| `intentional_product_deferral` | Feature is intentionally deferred or not yet implemented |
| `test_or_proof_failure` | Actual test or proof failure that does not match the above categories |

## Evidence Expectations

Each workstream should leave behind:

- The exact commands run (starting from `./scripts/local-signoff.sh`)
- Per-proof status from the orchestrator summary (`PASS`, `FAIL`, or `SKIP`)
- The orchestrator artifact directory path and `summary.json` location
- Any blockers classified using the four labels above
- Whether the run was local-only, mocked, or partially deferred

If a scenario is skipped, the skip reason must name the current blocker, not project history.
Store transient evidence artifacts outside the repo tree.

Use [`docs/checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md`](./checklists/LOCAL_SIGNOFF_EVIDENCE_TEMPLATE.md)
to keep those notes consistent across sessions.

## Documentation Workflow Rules

- Any merged behavior change must update the relevant doc in the same PR.
- `README.md` stays high-level and stable; current status belongs in `ROADMAP.md`.
- Local setup and troubleshooting live in `docs/LOCAL_DEV.md`.
- Local launch validation scope lives in this file.
- Environment variable additions or behavior changes must update `docs/env-vars.md`.
- Runbooks should link to canonical docs instead of duplicating long setup guidance.
- Browser test comments and skip reasons must describe the current blocker only.
- Do not leave "not implemented" comments in tests after the feature ships.
- Keep local-only validation clearly separate from live-credential validation.

## Exit Condition

Local launch-readiness docs are complete when a new teammate can answer "what are we proving locally before AWS and Stripe?" by reading this file plus `docs/LOCAL_DEV.md`, without needing handoff context from chat.
