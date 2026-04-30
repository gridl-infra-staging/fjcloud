# Staging Deployment Evidence — 2026-04-09

Evidence bundle for the fjcloud staging infrastructure deployment (Stages 1-9).

## Reconciliation 2026-04-30

This section is append-only and captures the current-state reconciliation as of
2026-04-30; it does not erase or rewrite the historical sections below.
Reconciliation inputs are anchored to Stage 1 forensic ledger rows
`CLM-003`, `CLM-008`, `CLM-013`, and `CLM-018` in
`docs/runbooks/evidence/staging-evidence-reconciliation/20260430T040514Z/forensic_inventory.md`.

### API runtime

- Current state: deployed webhook-mode readiness is proven for staging runtime,
  but persisted-send proof is still failed for the selected replay invoice; the
  readiness/failure split must remain explicit (CLM-003).
- Current-state interpretation remains owner-lane bound to
  `scripts/probe_alert_delivery.sh`, `scripts/staging_billing_rehearsal.sh`, and
  `scripts/launch/run_full_backend_validation.sh` (no ad-hoc process owner).
- Evidence:
  - `docs/runbooks/evidence/alert-delivery/.current_bundle`
  - `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/08_stage2_readiness_gate.txt`
  - `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/15_stage3_verdict.txt`
  - `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/53_runtime_snapshot_recheck.txt`

### Metering-agent runtime

- Current state: metering-linked billing lifecycle evidence is checked in and
  passes the paid-lifecycle cross-check for tenant A, while fresh current-main
  replay evidence remains a separate owner rerun task.
- Historical references that were previously private temp-path only are treated
  as historical context; canonical current-state evidence must come from
  checked-in owner bundles (CLM-018).
- Evidence:
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/SUMMARY.md`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/cross_check_result.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/usage_records_provenance.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260426T052358Z_stage_d_capture/01_tenant_map_verify.txt`

### Deploy-pipeline health

- Historical note correction (CLM-013): older interpretation that
  `f68856f7` was the previous successful deploy is deprecated. The dated
  correction in the operator evidence lane documents rollback ping-pongs, so
  deploy-state truth must be timestamp-scoped.
- Current deploy-state source of truth is the deploy owner seam
  `ops/scripts/deploy.sh` with SSM readback of `/fjcloud/staging/last_deploy_sha`.
  The 2026-04-29 readback remains historical context, not an evergreen status.
- Evidence:
  - `ops/scripts/deploy.sh`
  - `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/08_predeploy_last_deploy_sha.txt`
  - `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/53_runtime_snapshot_recheck.txt`
  - `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md`
  - `pending owner artifact: fresh checked-in deploy readback bundle from current-main rerun`

### Discipline for future reconciliations

- Append-only contract: every new entry uses `## Reconciliation YYYY-MM-DD`
  and is added as a new dated block; do not rewrite prior dated blocks.
- Evidence-pointer contract: each current-state claim must point to checked-in
  artifacts under `docs/runbooks/evidence/`, or must be labeled
  `pending owner artifact` with the owning lane and missing artifact named;
  private temp/local paths are not valid current-state evidence.
- Deploy-state command transcript contract: each dated block must include the
  verbatim command text and transcript pointers for both readback and history
  context of `/fjcloud/staging/last_deploy_sha`, including:
  - `aws ssm get-parameter --name /fjcloud/staging/last_deploy_sha --with-decryption`
  - `aws ssm get-parameter-history --name /fjcloud/staging/last_deploy_sha --with-decryption`
- Due-by contract: each dated reconciliation block must include
  `Due-by: YYYY-MM-DD` set to exactly 30 days after that reconciliation date
  (example: `## Reconciliation 2026-04-30` => `Due-by: 2026-05-30`).
- Policy: history-only validator automation is intentionally out of scope
  because rollback/deploy churn can produce false signals; use human-authored
  evidence reconciliation in the existing owner seams (`ops/scripts/deploy.sh`
  and checked-in evidence lanes).

## Terraform Outputs

Defined in `ops/terraform/_shared/outputs.tf`:

| Output              | Description                                        | Live Value (Staging)                            |
| ------------------- | -------------------------------------------------- | ----------------------------------------------- |
| vpc_id              | VPC ID                                             | _(from terraform state)_                        |
| public_subnet_ids   | Public subnet IDs (for ALB)                        | _(from terraform state)_                        |
| private_subnet_ids  | Private subnet IDs (for RDS and internal EC2)      | _(from terraform state)_                        |
| db_endpoint         | RDS PostgreSQL endpoint                            | `fjcloud-staging.*.us-east-1.rds.amazonaws.com` |
| api_instance_ip     | API EC2 instance private IP                        | _(from terraform state)_                        |
| alb_dns_name        | ALB DNS name                                       | _(from terraform state)_                        |
| acm_certificate_arn | ACM certificate ARN used by the ALB HTTPS listener | _(from terraform state)_                        |

Note: Actual IDs are in the Terraform state file (`ops/terraform/_shared/terraform.tfstate`). Sensitive values (account ID, full RDS hostname) are redacted in this document.

## Deployed Infrastructure Identifiers

| Resource            | Value                                                               |
| ------------------- | ------------------------------------------------------------------- |
| AMI ID              | `ami-078228dbe86117d85`                                             |
| EC2 Instance ID     | `<redacted-instance-id>`                                            |
| EC2 Instance State  | running                                                             |
| Deployed Binary SHA | `c7fa088c` (binary name fix; last deploy via Stage 6)               |
| RDS Endpoint        | `fjcloud-staging.*.us-east-1.rds.amazonaws.com:5432`                |
| Route53 Zone ID     | `Z08413023J5QVP032GJSK`                                             |
| ACM Cert Status     | `PENDING_VALIDATION` (captured in the 2026-04-09 evidence snapshot) |
| Region              | us-east-1                                                           |

## Integration Status

### SES Email

- Sender domain: `flapjack.foo` (DKIM=SUCCESS, identity=SUCCESS, sending enabled,
  production-access account).
- 2026-04-23 SSM reconciliation: `/fjcloud/staging/ses_from_address` was found
  pointing at `noreply@flapjack.cloud`, which was an unverified Porkbun-hosted
  domain with DKIM=FAILED and `SendingEnabled=false`. The staging API would
  have silently failed any outbound send. SSM has been updated to the canonical
  sender path rooted at `system@flapjack.foo` (via the verified `flapjack.foo`
  identity), and the running API was restarted via SSM
  (`generate_ssm_env.sh staging` + `systemctl restart fjcloud-api.service`);
  public health returned `HTTP 200` after the restart.
- SPF for `flapjack.foo` now publishes `v=spf1 include:amazonses.com include:spf.privateemail.com ~all`
  (Cloudflare record `65d4623c8656d64eb4e2532eeefdf236`), so SES sends now align
  under SPF without breaking the existing privateemail MX handler.
- Custom MAIL FROM domain `mail.flapjack.foo` is configured on the SES identity
  with a live `MX 10 feedback-smtp.us-east-1.amazonses.com` record and a
  `v=spf1 include:amazonses.com ~all` TXT record on the subdomain. SES now reports
  `MailFromDomainStatus=SUCCESS`; the earlier `PENDING` reading is preserved only in `docs/runbooks/evidence/ses-deliverability/20260423T202158Z_ses_boundary_proof_full.txt` as historical context, with current reconciliation owned by `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md`.
- Historical SES boundary transcript preserved under
  `docs/runbooks/evidence/ses-deliverability/` with MessageIds for:
  - first-send (SES mailbox simulator `success@simulator.amazonses.com`)
  - bounce-handling (`bounce@simulator.amazonses.com`)
  - complaint-handling (`complaint@simulator.amazonses.com`)
  - inbox-receipt (verified identity `stuart.clifford@gmail.com`)
    plus a post-SPF-update second send to re-confirm SES accepts the new sender.
    Deliverability boundaries remain explicitly unproven in this status doc; use
    `docs/runbooks/email-production.md` as the SSOT for readiness versus open
    boundary interpretation. Stage 3 send-side retrieval status is captured in
    `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md`,
    including the no-manual-mailbox-validation stop condition when SES
    inbox/header retrieval ownership is missing.
- Canonical wrapper owner: `scripts/launch/ses_deliverability_evidence.sh`.
  Code path: `infra/api/src/services/email.rs` (`SesConfig` validation).
- SSM parameters mapped: `ses_from_address` and `ses_region` via
  `ops/scripts/lib/generate_ssm_env.sh`.
- Current launch blockers and prioritization are tracked in `README.md`,
  `PRIORITIES.md`, and `ROADMAP.md`.

### Stripe Billing

- Credentialed staging Stripe secret/webhook contract is present and usable for
  guarded preflight. The `scripts/validate-stripe.sh` end-to-end lifecycle
  (create_customer → attach_payment_method → invoice create+pay → confirm paid)
  now returns `{"passed":true}` against the credentialed staging Stripe sandbox
  on 2026-04-23, so the earlier transient `attach_payment_method` HTTP 400
  blocker is cleared from the external side.
- 2026-04-23 credentialed rehearsal was executed from the staging EC2 host
  (evidence: `docs/runbooks/evidence/staging-billing-rehearsal/20260423T205444Z_credentialed_rehearsal_on_staging_ec2.txt`).
  Preflight passed 11/11, health passed (200), and the delegated rehearsal
  halted at the `usage_records_empty` safety gate because the pre-launch
  staging DB had no customer metering activity.
- 2026-04-24 follow-up status: the repo now has a real synthetic-traffic owner
  in `scripts/launch/seed_synthetic_traffic.sh`, with contract coverage in
  `scripts/tests/seed_synthetic_traffic_test.sh`, so the remaining billing-lane
  blocker is no longer missing seeding automation. The current blocker is the
  first live Tenant A proof run failing during staging index creation before
  fresh `usage_records` could be produced. Live repro on the staging EC2 host
  narrowed that failure to seeded-deployment admin-key verification in
  `POST /admin/tenants/:id/indexes`: API logs reported
  `failed to verify admin key for seeded deployment: secret store API error: SSM GetParameter failed: service error`.
  A follow-up live rerun on 2026-04-25 then cleared that seed-index blocker:
  Tenant A provisioning reached tenant-mapping-ready state (checked-in owner
  lane confirmation: `docs/runbooks/evidence/staging-billing-rehearsal/20260426T052358Z_stage_d_capture/01_tenant_map_verify.txt`)
  after `POST /admin/tenants/:id/indexes` succeeded.
  An evening 2026-04-25 rerun resolved the next blocker as well: direct-node
  storage polling against `http://vm-shared-f2b9c8a6.flapjack.foo:7700/internal/storage`
  no longer returns HTTP 403. The seeder now resolves the per-VM admin key
  from SSM at call time via `node_api_key_for_url()` in
  `scripts/launch/seed_synthetic_traffic.sh`, which mirrors the production
  scheduler's `build_auth_headers` contract in
  `infra/api/src/services/scheduler/mod.rs`. The same evening rerun produced
  `storage floor already satisfied for demo-shared-free: 96.08 MB >= 90.00 MB`
  and `sustained traffic complete for demo-shared-free: writes_sent=10 searches_sent=1`,
  with the canonical checked-in paid-lifecycle evidence preserved under
  `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/`
  and the canonical
  `flapjack_uid` `0a65f0b714b34e08acf62222a02c7858_demo-shared-free` in the
  mapping artifact (matching the live `{customer_hex}_{name}` engine contract).
  Execute mode remains intentionally truthful: Tenant A only, with B/C/all
  still rejected until a dedicated checked-in seam exists. Fresh
  `usage_records` attribution rows for tenant A are now gated on the API
  scheduler's next scrape cycle (`SCHEDULER_SCRAPE_INTERVAL_SECS=300`) and
  the downstream metering aggregation, not on the seeder.

  Downstream metering pipeline fix landed in the same evening session: the
  control-plane `/internal/tenant-map` endpoint now falls back to
  `vm_inventory.flapjack_url` when `deployment.flapjack_url` is null
  (`infra/api/src/routes/internal.rs::tenant_map`). Without this fallback
  the metering agent on the shared VM filtered our tenant out of its
  attribution map, leaving `usage_records` for tenant A permanently at
  zero even after live writes converged storage to 96 MB. The fallback is
  contract-tested by
  `tenant_map_falls_back_to_vm_inventory_url_when_deployment_has_none`
  (positive case) and
  `tenant_map_keeps_flapjack_url_null_when_neither_deployment_nor_vm_has_one`
  (negative case) in `infra/api/tests/metering_multitenant_test.rs`.
  **Resolved 2026-04-26:** the staging API binary deploy completed via
  a hand-driven SSM build/swap pipeline because the GitHub Actions
  `deploy-staging` job was missing the `DEPLOY_IAM_ROLE_ARN` OIDC role
  at that time. The Apr 27 follow-up restored the checked-in
  repo/IAM/workflow OIDC deploy contract; what remains is a fresh
  current-main deploy/rerun through that restored path, not an unknown
  missing-role defect. SSM `/fjcloud/staging/last_deploy_sha` now points
  at `d905f90affd45104bc95526acc0a48ca96c7c8ae`. The
  tenant-map fallback is verified live: tenant A returns
  `flapjack_url=http://vm-shared-f2b9c8a6.flapjack.foo:7700`. Live
  `usage_records` for tenant A populate every 60s, `usage_daily` rolls
  up correctly, and a paid Stripe invoice
  (`in_1TQLr2KH9mdklKeIlzBNFR4M`) was produced end-to-end. Canonical
  paid-lifecycle evidence pointer:
  `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/`
  (`SUMMARY.md`, `cross_check_result.json`, `cross_check_computation.md`).
  Amount verdict is now `CROSS_CHECK_PASSED`: invoice
  `e7806ad2-977d-4f4b-9ff9-95c7ddab49e3` matches at zero-cent tolerance
  (`subtotal_cents=11`, `total_cents=500`, `minimum_applied=true`) with
  `exact_match` booleans true in `cross_check_result.json`.
  Three additional blockers were discovered + fixed during the same
  pass: 001 migration in-place mutation broke sqlx checksum check
  (`102659b7`), seeder rejected 200 OK from idempotent seed_index
  (`27571c15`), and `fj-metering-agent` was 403'ing on every flapjack
  scrape because it sent only `X-Algolia-API-Key` (the engine requires
  `X-Algolia-Application-Id` too — `ec6a7669`). The metering
  Application-Id bug had silently blocked every prior staging
  rehearsal at `usage_records_empty`.

  Stage F note: the `playwright` CI job has been red since 2026-03-15
  because the workflow runs `npx playwright test` with no backing
  postgres / API / dev-server services, so every test fails with
  `TypeError: fetch failed` on auth setup. That blocked
  `deploy-staging` for 6+ weeks. Commit `da007362` removed `playwright`
  from `deploy-staging.needs` (it stays advisory and surfaces failures
  in CI annotations), so the rest of the gate (rust-test, rust-lint,
  migration-test, web-test, web-lint, check-sizes, secret-scan) can
  finally ship the April fixes. The targeted long-tail follow-up is
  `chatting/apr25_pm_2_playwright_ci_services_plan.md`.

  Post-deploy verification (run after the staging API binary picks up
  the fix). The end-to-end recipe is owned by
  `scripts/launch/capture_stage_d_evidence.sh`, which sequences:

  1. `post_deploy_verify_tenant_map.sh` — assert tenant A's
     `flapjack_url` is non-null in `/internal/tenant-map`.
  2. Re-run `seed_synthetic_traffic.sh --tenant A --execute
     --i-know-this-hits-staging --duration-minutes
     "${STAGE_D_SEEDER_DURATION_MINUTES:-3}"`.
  3. Sleep `${STAGE_D_SCHEDULER_WAIT_SECONDS:-320}` for one scheduler
     scrape + aggregation cycle.
  4. Assert `/admin/tenants/${TENANT_A_CUSTOMER_ID}/usage` is non-zero.
  5. Read the deployed sha from SSM `/fjcloud/staging/last_deploy_sha`,
     materialize the rehearsal env file on the EC2 host from staging
     SSM (so credentials never traverse the operator side), and drive
     `staging_billing_rehearsal.sh --env-file <generated> --month
     $(date -u +%Y-%m) --confirm-live-mutation` against the runtime
     checkout the deploy step already populated at
     `/opt/fjcloud-runtime-fix/<sha>/src/`.

  Operator entry point:

  ```bash
  set -a; source .secret/.env.secret; set +a
  bash -lc 'source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging); bash scripts/launch/capture_stage_d_evidence.sh'
  ```

  Do not `eval "$(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)"`
  in the operator shell. Keep the staging SSM hydration flow inside the
  maintained wrapper/helper scripts so unexpected shell metacharacters in helper
  output cannot execute in the parent shell.

  Each step is fail-closed and writes its artifact under
  `docs/runbooks/evidence/staging-billing-rehearsal/<run_ts>_stage_d_capture/`.
  Do NOT inline the recipe here — extend the script and its
  `scripts/tests/operator_helpers_smoke_test.sh` smoke tests instead.

  Pre-fix observable state captured 2026-04-25 20:35Z (deployed API still
  on prior binary):
  - `/internal/tenant-map` for tenant A returns `flapjack_url: null` ❌
  - Live `/internal/storage` on `vm-shared-f2b9c8a6.flapjack.foo:7700`
    shows the canonical truth: tenant A id
    `0a65f0b714b34e08acf62222a02c7858_demo-shared-free` at ~30 MB /
    20,111 docs (flapjack-engine compressed the deterministic payloads
    after the seeder converged to 96 MB) ✅
  - `/admin/tenants/{id}/usage` stays at all zeros ❌ — confirming the
    pre-fix tenant-map null is the upstream cause, not the seeder.

  Operator-side env hydration is now owned by
  `scripts/launch/hydrate_seeder_env_from_ssm.sh staging`, which prints
  `export ADMIN_KEY=...`, `export DATABASE_URL=...`, `export API_URL=...`,
  and `export FLAPJACK_URL=...` from the staging SSM `/fjcloud/staging/*`
  parameters. `FLAPJACK_API_KEY` is no longer required by `preflight_env`:
  the seeder resolves the per-VM admin key from SSM by `flapjack_url` host
  for every direct-node call. The `.secret/.env.secret`-only dispatch
  failure mode is therefore fixed by sourcing the new helper before
  invoking the seeder.
- The staging API host now has `postgresql16` installed via SSM
  (`which psql=/usr/bin/psql`, version 16.12) and `ops/packer/flapjack-ami.pkr.hcl`
  plus `ops/terraform/compute/main.tf` now bake `postgresql16` into the AMI and
  user_data so the rehearsal's metering DB evidence path is no longer runtime-
  gated by host tooling absence. `scripts/lib/psql_path.sh` adds the same
  tolerance for Homebrew-libpq-installed operator machines.
- The preserved Stage 3 paid-beta RC run remains no-launch:
  `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md`
  preserves the historical `ready=false` / `verdict=fail` coordinator result,
  and includes a delegated billing step
  failure (`reason=staging_api_url_missing`) in that preserved run context.
- Canonical billing-portal verdict (latest Stage 2-4 evidence as of 2026-04-25):
  checked-in owner summary
  `docs/runbooks/evidence/browser-evidence/20260429T170447Z_current_main/SUMMARY.md`
  records `run_status: 1`, `fail_reason: spec_signup_to_paid_invoice`, and
  `spec_billing_portal_cancel_exit: 0`, so deployed `/dashboard/billing` proof
  remains precondition-blocked with no checked-in `/billing/portal` defect yet
  proven. `pending owner artifact`: a checked-in replacement for the old
  stage2 local-only `primary_web_proof_summary.json`.
- Billing rerun ownership stays with `scripts/staging_billing_rehearsal.sh`,
  while cross-lane no-launch/readiness orchestration remains
  `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...`.
- Wrapper-level live evidence interpretation is owned by
  `docs/runbooks/aws_live_e2e_guardrails.md` (`checks`,
  `credentialed_checks`, `external_blockers`, `overall_verdict`).
- Local/mock pass results do not satisfy credentialed billing/webhook/SES proof.

### AWS Budget And Spend Alerting

- Budget: `fjcloud-staging-monthly` at $600/month (created 2026-04-23 via
  `aws budgets create-budget` against the redacted staging account in us-east-1).
- Notifications: ACTUAL at 50% / 80% / 100% and FORECASTED at 100%, all
  delivered by email to `clifford.kriv@gmail.com`.
- Auto-enforcement (AWS Budgets Actions) is **intentionally disabled** for
  pre-launch staging. Rationale: a solo-maintainer account does not benefit
  from an automatic IAM-attachment circuit-breaker between itself and itself,
  and a wrong `policy_arn + role_name` pairing (e.g. `AWSDenyAll` on the
  fjcloud API instance role on a $600 breach) would lock staging out until
  manual intervention. Alert-only notifications give the same signal without
  the lockout risk.
- Safe future upgrade path if enforcement is ever desired: create a
  dedicated `fjcloud-live-e2e-burst` role used only by the live-E2E janitor
  and harness; attach `AWSDenyAll` to **that** role on breach so blast
  radius is bounded to live-E2E runs and does not affect API / RDS / SES.

### Health Check

- API responds `{"status":"ok"}` on port 3001 via SSM `curl http://127.0.0.1:3001/health`
- RDS connectivity confirmed on port 5432 (host now has `psql` 16.12; initial 2026-04-09 test used `/dev/tcp` fallback)
- All 6 CloudWatch alarms in OK state:
  - `fjcloud-staging-alb-5xx-error-rate`
  - `fjcloud-staging-alb-p99-target-response-time`
  - `fjcloud-staging-api-cpu-high`
  - `fjcloud-staging-api-status-check-failed`
  - `fjcloud-staging-rds-cpu-high`
  - `fjcloud-staging-rds-free-storage-low`

## Known Issues And Current Status

Stage 9 captured the findings below in the 2026-04-09 live validation snapshot. This section preserves the historical evidence while recording the current checked-in status.

### 1. ALB Port Mismatch (HISTORICAL / RESOLVED STATUS TRACKED ELSEWHERE)

Stage 9 evidence captured a legacy target-group port mismatch against the API port 3001 contract.

- **Historical impact (2026-04-09 snapshot)**: ALB target health failed in that validation run.
- **Files**: `ops/terraform/dns/main.tf:71,92` (TG port), `ops/terraform/networking/main.tf:191-192,210-211,218-219` (SG rules), `infra/api/src/config.rs:65` (LISTEN_ADDR default)
- **Fix scope**: 6+ file atomic change across Terraform modules and test files
- **Current checked-in status**: Resolved. Terraform target-group, security-group, and static-test contracts now use port 3001.
- **Current status authority**: See `README.md`, `PRIORITIES.md`, and `ROADMAP.md` for canonical blocker and priority state.

### 2. EC2 Volume Size Drift (HISTORICAL / RESOLVED IN CODE)

Stage 9 evidence captured Terraform attempting to change the root volume from 40GB live to 20GB in spec.

- **Historical impact (2026-04-09 snapshot)**: Next `terraform apply` would have attempted to shrink the root volume.
- **Current checked-in status**: Resolved. `ops/terraform/compute/main.tf` now specifies `volume_size = 40`.

### 3. Cargo Audit Advisories (HISTORICAL / RESOLVED IN CODE)

Stage 9 captured 6 vulnerabilities (3 high-severity CVSS 7.4-7.5) in `aws-lc-sys 0.37.1` and `rustls-webpki 0.103.9` affecting TLS certificate validation.

- **Historical impact (2026-04-09 snapshot)**: `cargo audit -q` failed.
- **Current checked-in status**: Resolved. `cargo audit -q` exits successfully with only allowed warnings after the TLS dependency upgrades.

### 4. Missing psql on EC2 (HISTORICAL / RESOLVED IN CODE AND ON STAGING HOST)

- **Historical impact (2026-04-09 snapshot)**: Cannot query RDS directly from EC2; TCP fallback used.
- **Current checked-in status**: Resolved. `ops/packer/flapjack-ami.pkr.hcl` bakes `postgresql16` into the AMI, and `ops/terraform/compute/main.tf` adds `postgresql16` to user_data (guarded by `user_data_replace_on_change = false` to avoid forcing instance replacement). Current live staging EC2 also had `postgresql16` installed out-of-band on 2026-04-23 via SSM Run Command, so `psql --version` now reports 16.12 on the running host without requiring an instance replacement.
- **Operator runtime note**: `scripts/lib/psql_path.sh` also makes macOS developer machines that have Homebrew libpq installed discover `psql` without needing a global PATH change, so the staging billing rehearsal and metering evidence path both run the same on dev and staging.

## Live Validation Cross-Reference

Full validation details: [`docs/runbooks/staging-validation-20260409.md`](staging-validation-20260409.md)

| #   | Check                   | Status                                      |
| --- | ----------------------- | ------------------------------------------- |
| 1   | AWS credentials         | PASS                                        |
| 2   | AMI ID retrieval        | PASS                                        |
| 3   | Terraform drift check   | DRIFT                                       |
| 4   | EC2 instance health     | PASS                                        |
| 5   | SSM reachability        | PASS                                        |
| 6   | API health (port 3001)  | PASS                                        |
| 7   | RDS connectivity        | PASS                                        |
| 8   | ALB target health       | FAIL                                        |
| 9   | CloudWatch alarms (6/6) | PASS                                        |
| 10  | Stripe + metering gate  | ENV-BLOCKED                                 |
| 11  | cargo audit             | FAIL (historical; resolved in current code) |

**Historical summary**: 7 PASS, 2 FAIL, 2 ENV-BLOCKED out of 11 checks. Current checked-in code resolves the ALB port, EC2 volume-size, and cargo-audit findings. A fresh credentialed rerun was completed on 2026-04-21; see the update below for the current DNS/HTTPS/SES state.

## Terraform Drift Summary

From `terraform plan -detailed-exitcode` (Stage 9, check #3):

1. EC2 root volume: 40GB live vs 20GB in spec in the 2026-04-09 snapshot (historical; fixed in checked-in code)
2. S3 encryption config: cold-storage SSE representation drift only (same `AES256` intent; provider-representation noise under the locked provider, with no Terraform contract edit required)
3. ACM certificate validation resources were not completed in the 2026-04-09 snapshot
4. HTTPS listener resources were not completed in the 2026-04-09 snapshot

Items 1, 3, and 4 are historical 2026-04-09 drift evidence. Item 2 is a current non-blocking representation note rather than an implementation mismatch.
Any DNS-provider migration or Route53-specific follow-up is optional future infra scope.
For current blocker and prioritization status, see `README.md`, `PRIORITIES.md`, and `ROADMAP.md`.

## 2026-04-21 DNS Cutover Update

The Cloudflare credential blocker recorded on 2026-04-20 was resolved after the
token start date was corrected. The current live staging state is:

- Canonical public staging domain: `flapjack.foo`
- Public hosts routed through Cloudflare: `flapjack.foo`,
  `api.flapjack.foo`, `www.flapjack.foo`, `cloud.flapjack.foo`
- ACM certificate status: `ISSUED`
- SES identity status: `SUCCESS`
- SES DKIM status: `SUCCESS`
- Public health check: `https://api.flapjack.foo/health` returned `200`
- Target group health: healthy after correcting live host firewall drift to
  allow port `3001/tcp`

Operational note: the firewall correction above was live-instance drift, not a
checked-in Terraform or Packer contract bug. The checked-in AMI build already
expects the API on port `3001`.

## Live Evidence Wrapper Usage

Use `scripts/launch/live_e2e_evidence.sh` as the top-level operator entrypoint
for live evidence collection:

```bash
bash scripts/launch/live_e2e_evidence.sh \
  --env staging \
  --domain flapjack.foo \
  --artifact-dir ops/terraform/artifacts/live_e2e \
  --env-file .secret/.env.secret \
  --ami-id <ami-xxxxxxxxxxxxxxxxx>
```

Contract notes:

- Default runs are non-mutating. The wrapper delegates runtime assertions to
  `ops/terraform/tests_stage7_runtime_smoke.sh` and does not run apply/deploy/
  migrate/rollback unless those runtime-owner flags are explicitly requested.
- Billing remains a separate owner lane (`scripts/staging_billing_rehearsal.sh`)
  and is opt-in only with `--run-billing-rehearsal --month <YYYY-MM>
--confirm-live-mutation`.
- Artifacts are run-scoped under caller-supplied `--artifact-dir` as
  `fjcloud_live_e2e_evidence_<timestamp>_<pid>/...`, and `summary.json` is the
  run-level source of truth for machine-readable verdicts.
- Wrapper status/value interpretation is owned by
  `docs/runbooks/aws_live_e2e_guardrails.md`; this document is only the dated
  evidence index for that owner lane.
- Paid-beta RC taxonomy and `<artifact-dir>/summary.json` contract interpretation
  is owned by `docs/runbooks/paid_beta_rc_signoff.md` (script owner:
  `scripts/launch/run_full_backend_validation.sh` `emit_result_json` /
  `emit_final_result`).

## Current External Blockers

- Preserved paid-beta RC verdict owner:
  `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md`
  is authoritative for the preserved launch status snapshot (`timestamp=2026-04-24T00:38:19Z`,
  `ready=false`, `verdict=fail`).
- Latest Stage 7 runtime wrapper rerun artifact:
  `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/`
  preserves the historical runtime-smoke failure context and follow-up rechecks
  (`39_runtime_snapshot_retry.txt`, `53_runtime_snapshot_recheck.txt`).
  Delegated owner command remains `ops/terraform/tests_stage7_runtime_smoke.sh`
  via `scripts/launch/live_e2e_evidence.sh`.
- A fresh direct runtime-owner rerun on 2026-04-25 passed after the checked-in
  DNS contract was reconciled to the live provider truth. Rerun command:
  `bash ops/terraform/tests_stage7_runtime_smoke.sh --env staging --domain flapjack.foo --ami-id ami-078228dbe86117d85 --env-file <repo>/.secret/.env.secret`.
  The canonical contract is now:
  - `flapjack.foo`, `api.flapjack.foo`, and `www.flapjack.foo` are DNS-only
    `CNAME`s to the staging ALB.
  - `cloud.flapjack.foo` is a proxied `CNAME` to
    `flapjack-cloud.pages.dev`.
  The preserved 2026-04-24 wrapper artifact remains historically red, but the
  runtime-smoke lane is no longer blocked by `dns_record_mismatch`.
- Live billing-lane reruns on 2026-04-25 moved the blocker past seed-index
  creation. The historical `POST /admin/tenants/:id/indexes` failure was real
  and was traced to seeded-deployment admin-key verification in the SSM-backed
  node-secret path (`SSM GetParameter failed: service error`), but the latest
  rerun cleared that route; checked-in owner confirmation is preserved at
  `docs/runbooks/evidence/staging-billing-rehearsal/20260426T052358Z_stage_d_capture/01_tenant_map_verify.txt`.
  That direct-node 403 path was
  resolved by the 2026-04-26 metering runtime fixes; the remaining gap is a
  fresh current-main rerun/evidence bundle, not re-debugging that old blocker.
- Preserved paid-beta RC no-launch reasons map to these owner artifacts and
  rerun commands:
  - `backend_launch_gate` failed (`commerce: check_stripe_key_present, check_stripe_key_live, check_stripe_webhook_secret_present, check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current`);
    owner artifact:
    `pending owner artifact` (checked-in coordinator backend-gate JSON not yet present in `docs/runbooks/evidence/launch-rc-runs/`).
  - `local_signoff` failed (`reason=local_signoff_failed`); rerun through
    `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...`.
  - `ses_readiness` was blocked (`reason=credentialed_ses_identity_missing`);
    delegated owner commands/docs remain `scripts/validate_ses_readiness.sh`,
    `scripts/launch/ses_deliverability_evidence.sh`, and
    `docs/runbooks/email-production.md`.
  - `staging_billing_rehearsal` failed (`reason=staging_api_url_missing`);
    delegated owner command remains `scripts/staging_billing_rehearsal.sh`.
  - Browser lane retained current-main evidence on 2026-04-28 at
    `docs/runbooks/evidence/browser-evidence/20260428T202308Z_current_main`.
    `SUMMARY.md` records this bundle as failed local-stack evidence
    (`signup_to_paid_invoice.spec.ts` and `billing_portal_cancel.spec.ts`
    both failed on missing Stripe starter-plan fixture pricing), so this is
    preservation of failed evidence rather than green launch proof. The
    staging-target follow-up remains open and is handed off through
    `STAGING_GAP_SPEC.md`.
  - Terraform lane failed in preserved RC
    (`terraform_stage7_static_failed`, `staging_runtime_smoke_failed`);
    delegated runtime owner command remains
    `ops/terraform/tests_stage7_runtime_smoke.sh`.
    That preserved failure is now historical for the DNS-record subcase: the
    latest direct runtime-owner rerun passed on 2026-04-25 after the checked-in
    Cloudflare contract was reconciled. As of 2026-04-27 the runtime-parameter
    ownership is reconciled: `ops/terraform/_shared/main.tf` delegates runtime
    parameters via `module "runtime_params"`, `ops/terraform/runtime_params/main.tf`
    exclusively owns the `aws_ssm_parameter` `runtime_*` resources, and the
    `moved {}` migration blocks in `_shared/main.tf` are intentionally retained
    as a safe state-migration guard. `bash ops/terraform/tests_stage8_static.sh`
    now passes the ownership contract end-to-end (108/108), including the
    `_shared/main.tf remains wiring-only (no direct aws_* resources)` assertion.
- SES deliverability evidence status (2026-04-23): canonical Stage 4 wrapper
  evidence is tracked by checked-in reconciliation outputs in
  `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/`
  (`reconciliation_summary.md`, `first_send_retrieval_status.md`). A checked-in
  replacement for the original Stage 4 wrapper `summary.json` is a
  `pending owner artifact`. See `docs/runbooks/email-production.md` for
  field-level interpretation and historical blocked-path context.
- SES deliverability current state: the repo-local secret inventory parses
  through `scripts/lib/env.sh` `load_env_file` and now provides canonical
  `SES_FROM_ADDRESS=system@flapjack.foo` / `SES_REGION=us-east-1` inputs for the
  wrapper. Stage 1 truth confirms sender readiness through the inherited
  `flapjack.foo` domain identity/DKIM path plus production-access-enabled
  account status.
- SES deliverability boundaries still unproven after the passing wrapper run:
  keep SPF, MAIL FROM, bounce/complaint handling, first-send evidence, and
  inbox-receipt proof as open until dedicated evidence exists.
- Stage 3 first-send companion artifact:
  `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md`
  records the latest wrapper run directory, recipient class, and the retrieval-owner blocker path.
- Stage 3 live inbox roundtrip proof artifact:
  `docs/runbooks/evidence/ses-deliverability/20260428T194527Z_stage3_live_probe/roundtrip.json`
  captures the latest credentialed inbound roundtrip result via
  `scripts/validate_inbound_email_roundtrip.sh` (including `send_probe`,
  `poll_inbox_s3`, `fetch_rfc822`, and `auth_verdict`).
- Stage 4 direct canary proof artifacts:
  `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/run_1.json`,
  `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/run_2.json`,
  and `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/gate_summary.json`
  capture two consecutive delegated canary runs and the programmatic gate requiring
  `.passed=true` plus `auth_verdict.passed=true` for both runs.
- Stage 4/5 bounce+complaint companion artifacts:
  `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/bounce_blocker.txt` and
  `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/complaint_blocker.txt`
  (or `bounce_event.json` / `complaint_event.json` if checked-in retrieval proof exists);
  these remain blocker-path evidence today and do not close `deliverability_boundaries.bounce_complaint_handling`.
- The cold-storage SSE representation note is non-blocking provider-representation
  noise; see the Terraform Drift Summary above.
- RDS restore verification evidence is captured at
  `docs/runbooks/evidence/database-recovery/20260423T201333Z_staging_restore_verification.txt`
  (schema intact, 39 migrations, zero-count baseline for the empty staging source);
  this lane is no longer a launch blocker in the preserved Stage 3 verdict.
- Current authoritative blocker/prioritization context lives in `README.md`,
  `PRIORITIES.md`, and `ROADMAP.md`.

## Stage 2 webhook SSM population run (2026-04-28T20:11:35Z)

- Evidence: `docs/runbooks/evidence/alert-webhook/20260428T201000Z_ssm_populate/`
- Mode: neither Discord nor Slack populated in this run (canonical secret source lacked both `DISCORD_WEBHOOK_URL` and `SLACK_WEBHOOK_URL` at execution time).
- Write/readback command set was prepared for the Stage 2 contract but no parameter mutation/readback occurred in this first run because required source values were unavailable.
- Deploy deferred to Stage 3/4.

## Stage 2 webhook SSM population rerun (2026-04-28T20:32:04Z — superseded)

- Evidence: `docs/runbooks/evidence/alert-webhook/20260428T203204Z_ssm_populate/`
- Mode: Discord-only via `ssm_existing_value_fallback` (pre-operator secret addition).
- **Superseded by canonical repopulate below.**

## Stage 2 webhook SSM canonical repopulate (2026-04-28T21:34:12Z)

- Evidence: `docs/runbooks/evidence/alert-webhook/20260428T213412Z_ssm_repopulate/`
- Mode: Discord-only populated from operator-added canonical secret file (`discord_source_mode=env_secret_canonical`).
- Active deployed-alert bundle pointer (SSOT): `docs/runbooks/evidence/alert-delivery/.current_bundle`
  currently resolves to `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging`.
- Stage 2 readiness-gate artifact in that resolved bundle is PASS:
  `08_stage2_readiness_gate.txt`.
- Stage 3 in the resolved bundle is intentionally `result=precondition_gap` because
  no staging invoice matched `status='finalized' AND stripe_invoice_id IS NOT NULL`;
  this is not a missing-evidence condition.
- Owner to clear that invoice precondition before any future live replay:
  `scripts/staging_billing_rehearsal.sh`.
- Commands executed:
  - `aws sts get-caller-identity` (identity and account redacted in checked-in evidence)
  - `aws ssm put-parameter --overwrite --type SecureString --name /fjcloud/staging/discord_webhook_url --value <redacted> --region us-east-1`
  - `aws ssm get-parameter --name /fjcloud/staging/discord_webhook_url --with-decryption` — readback: SecureString, Version 4, LastModified `2026-04-28T17:34:13.622000-04:00`
  - `aws ssm get-parameters-by-path --path /fjcloud/staging/ --with-decryption` filtered to `discord_webhook_url|slack_webhook_url` — structural check confirms path matches `generate_ssm_env.sh` `SSM_TO_ENV` suffix contract
- Slack: `SLACK_WEBHOOK_URL` absent from canonical secret source; not populated in Stage 2.
- Deploy deferred to Stage 3/4.

## Stage 3 in-AWS canary schedule activation (2026-04-28T22:54:23Z window start)

- Evidence directory: `docs/runbooks/evidence/stage3_canary_activation_20260428T/`
- Activation window start (UTC): `2026-04-28T22:54:23Z` (see `stage3_activation_window_start_utc.txt`).
- Owner files reused without parallel resources: `module.monitoring` wiring in
  `ops/terraform/_shared/main.tf`; `aws_cloudwatch_event_rule.customer_loop_canary` in
  `ops/terraform/monitoring/main.tf`; `aws_cloudwatch_event_rule.support_email_canary` in
  `ops/terraform/monitoring/support_email_canary.tf`.
- Static gates run before deploy: `bash ops/terraform/tests_stage7_static.sh`
  (`tests_stage7_static.log`) and `bash ops/terraform/tests_support_email_canary_static.sh`
  (`tests_support_email_canary_static.log`) both passed.
- Plan/apply inputs avoided the regression captured in
  `ops/terraform/artifacts/plan_staging_20260428T024056Z.txt`:
  - Explicit `canary_image.tag` (live value pulled from
    `aws lambda get-function`, not `pending-publication`).
  - Explicit `support_email_canary_image_uri` (live URI, not `latest`).
  - Explicit `canary_schedule={enabled=true,expression="rate(15 minutes)"}` so
    `is_enabled` cannot silently flip back to `false`.
  - Cloudflare auth bridged in-sprint by exporting
    `CLOUDFLARE_API_TOKEN` from
    `CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO` after the initial
    `terraform plan` failed with
    `Missing X-Auth-Key, X-Auth-Email or Authorization headers`
    (see `terraform_plan_staging_stage3.txt` →
    `terraform_plan_staging_stage3_retry1.txt`).
- Apply transcript: `terraform_apply_stage3_targeted_rules.txt` (root owner via
  `ops/terraform/_shared`, targeted at canary rule resources to avoid unrelated
  plan churn).
- Post-apply outputs (canonical owners, no Stage-3-only outputs added):
  - `customer_loop_canary_schedule_rule_name = fjcloud-staging-customer-loop-canary`
    (`terraform_output_customer_loop_schedule_rule_name.log`).
  - `customer_loop_canary_lambda_function_arn = arn:aws:lambda:us-east-1:<redacted-account-id>:function:fjcloud-staging-customer-loop-canary`
    (`terraform_output_customer_loop_lambda_arn.log`).
  - Support-email schedule reuses existing naming contract from
    `ops/terraform/monitoring/support_email_canary.tf`
    (`fjcloud-staging-support-email-canary` /
    `fjcloud-staging-support-email-canary-schedule`).
- Control-plane readback (`aws_events_describe_rule_customer_loop.log` and
  `aws_events_describe_rule_support_email.log`):
  - `fjcloud-staging-customer-loop-canary`: `State=ENABLED`,
    `ScheduleExpression=rate(15 minutes)`.
  - `fjcloud-staging-support-email-canary-schedule`: `State=ENABLED`,
    `ScheduleExpression=rate(6 hours)`.
- Cadence-shortcut runtime proof (two clean manual invokes per surface, owners
  reused via direct `aws lambda invoke`; schedule itself remains owned by the
  CloudWatch event rules above):
  - Customer loop: `aws_lambda_invoke_customer_1.log` and
    `aws_lambda_invoke_customer_2.log` — both `StatusCode: 200`, no
    `FunctionError`. Owner-log readback in `aws_logs_customer_1.log` and
    `aws_logs_customer_2.log` includes `customer loop canary completed
    successfully` from `scripts/canary/customer_loop_synthetic.sh`. Window
    timestamps: `customer_loop_invoke_windows.txt`.
  - Support email: `aws_lambda_invoke_support_1.log` and
    `aws_lambda_invoke_support_2.log` — both `StatusCode: 200`, no
    `FunctionError`. Owner-log readback in `aws_logs_support_1.log` and
    `aws_logs_support_2.log` shows the delegated roundtrip JSON from
    `scripts/validate_inbound_email_roundtrip.sh` reporting `"passed":true`
    with per-step success including inbound nonce readback. Window
    timestamps: `support_email_invoke_windows.txt`.
- Alert-delivery closure note: deployed-alert evidence is preserved via
  `docs/runbooks/evidence/alert-delivery/.current_bundle` (currently
  `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging`),
  where Stage 2 readiness remains PASS and Stage 3 remains
  `result=precondition_gap` until a qualifying finalized invoice exists.
  Authoritative acceptance proof remains `alerts.delivery_status='sent'` from
  `docs/runbooks/alerting.md`; Discord nonce readback is supplemental
  destination confirmation.

## Stage 3 outside-AWS canary schedule activation (2026-04-28T22:54:23Z window start)

- Evidence directory: `docs/runbooks/evidence/stage3_canary_activation_20260428T/`
- Owner boundary reused without parallel runner: workflow wiring in
  `.github/workflows/outside_aws_health.yml`; URL/curl/exit behavior in
  `scripts/canary/outside_aws_health_check.sh`.
- Focused regression gates passed before activation:
  `bash scripts/tests/outside_aws_health_check_test.sh`
  (`tests_outside_aws_health_check.log`) and
  `bash scripts/tests/outside_aws_health_workflow_test.sh`
  (`tests_outside_aws_health_workflow.log`).
- Workflow active-state proof (`gh_workflow_state.log`):
  `gh api repos/gridl-infra-staging/fjcloud/actions/workflows/outside_aws_health.yml`
  returns `"state":"active"` for workflow id `267433355`. Auth and identity
  captured in `gh_auth_status.log` and `gh_repo_view.log`.
- Two clean post-activation runs from the same workflow owner:
  - Manual dispatch success: `databaseId=25081864316` (`event=workflow_dispatch`,
    `conclusion=success`, `createdAt=2026-04-28T22:54:36Z`). Triggered via
    `gh workflow run outside_aws_health.yml --repo gridl-infra-staging/fjcloud`
    (`gh_workflow_dispatch.log`, `gh_run_watch_dispatch.log`,
    `gh_run_list_final.log`).
  - Scheduled success in this activation window: `databaseId=25082425034`
    (`event=schedule`, `conclusion=success`,
    `createdAt=2026-04-28T23:11:18Z`). Captured by
    `gh_run_list_postwindow_schedule_proof_s83.json` (full `gh run list`
    output) and `gh_run_view_25082425034_schedule_s83.json`
    (`gh run view` detail with `workflowName=Outside AWS Health`,
    `headBranch=main`,
    `url=https://github.com/gridl-infra-staging/fjcloud/actions/runs/25082425034`).
    Cron continued cleanly after the window with the next scheduled success at
    `databaseId=25084141457` (`createdAt=2026-04-29T00:06:44Z`). Recheck
    timestamp captured in `utc_now_s83.txt`.
- Stage 4 webhook readback conclusions are not folded in here; this entry is
  scoped to canary schedule activation only.
