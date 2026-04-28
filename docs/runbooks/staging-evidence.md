# Staging Deployment Evidence — 2026-04-09

Evidence bundle for the fjcloud staging infrastructure deployment (Stages 1-9).

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
| EC2 Instance ID     | `i-0afc7651593f12372`                                               |
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
  Tenant A provisioning reached `tenant mapping ready at /tmp/seed-synthetic-demo-shared-free.json`
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
  with the live evidence log preserved at
  `/tmp/seed_evidence/seed_synthetic_20260425T200706Z.log` and the canonical
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
  (`in_1TQLr2KH9mdklKeIlzBNFR4M`) was produced end-to-end. Full
  evidence: `docs/runbooks/evidence/staging-billing-rehearsal/20260426T060756Z_paid_lifecycle/SUMMARY.md`.
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
  eval "$(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)"
  bash scripts/launch/capture_stage_d_evidence.sh
  ```

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
  `/Users/stuart/.matt/projects/fjcloud_dev-fbeae273/apr23_pm_6_launch_coordination_and_rc_signoff.md-998f7042/artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_result.json`
  records `ready=false` / `verdict=fail`, and includes a delegated billing step
  failure (`reason=staging_api_url_missing`) in that preserved run context.
- Canonical billing-portal verdict (latest Stage 2-4 evidence as of 2026-04-25):
  Stage 2 primary summary
  `/var/folders/5y/d6m1nn955w3cb95hg45ljzvr0000gn/T/fjcloud_stage2_billing_portal_20260425T052647Z_88178/primary_web_proof_summary.json`
  (`timestamp_utc=2026-04-25T05:27:18.996197+00:00`,
  `classification=precondition_blocked`) shows deployed `/dashboard/billing`
  proof is blocked by staging auth/preconditions, Stage 4 never opened, and no
  checked-in `/billing/portal` defect has been proven. Owner-only raw artifacts
  remain under
  `/var/folders/5y/d6m1nn955w3cb95hg45ljzvr0000gn/T/fjcloud_stage2_billing_portal_20260425T052647Z_88178`
  (including `primary_web_proof_summary.json`).
- Billing rerun ownership stays with `scripts/staging_billing_rehearsal.sh`,
  while cross-lane no-launch/readiness orchestration remains
  `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...`.
- Wrapper-level live evidence interpretation is owned by
  `docs/runbooks/aws_live_e2e_guardrails.md` (`checks`,
  `credentialed_checks`, `external_blockers`, `overall_verdict`).
- Local/mock pass results do not satisfy credentialed billing/webhook/SES proof.

### AWS Budget And Spend Alerting

- Budget: `fjcloud-staging-monthly` at $600/month (created 2026-04-23 via
  `aws budgets create-budget` against account 213880904778, region us-east-1).
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
  `/Users/stuart/.matt/projects/fjcloud_dev-fbeae273/apr23_pm_6_launch_coordination_and_rc_signoff.md-998f7042/artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_result.json`
  is authoritative for launch status (`timestamp=2026-04-24T00:38:19Z`,
  `ready=false`, `verdict=fail`).
- Latest Stage 7 runtime wrapper rerun artifact:
  `/Users/stuart/.matt/projects/fjcloud_dev-17570fdc/live_e2e_runtime_rerun_artifacts/fjcloud_live_e2e_evidence_20260424T215911Z_59523/summary.json`
  recorded `overall_verdict=fail` (`checks[0].name=runtime_smoke`,
  `checks[0].status=fail`, `checks[0].exit_code=27`). Triage owner log:
  `/Users/stuart/.matt/projects/fjcloud_dev-17570fdc/live_e2e_runtime_rerun_artifacts/fjcloud_live_e2e_evidence_20260424T215911Z_59523/logs/runtime_smoke.log`.
  Delegated owner command remains `ops/terraform/tests_stage7_runtime_smoke.sh`
  via `scripts/launch/live_e2e_evidence.sh`.
- A fresh direct runtime-owner rerun on 2026-04-25 passed after the checked-in
  DNS contract was reconciled to the live provider truth. Rerun command:
  `bash ops/terraform/tests_stage7_runtime_smoke.sh --env staging --domain flapjack.foo --ami-id ami-078228dbe86117d85 --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`.
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
  rerun cleared that route and wrote
  `/tmp/seed-synthetic-demo-shared-free.json`. The current blocker is the next
  direct-node step in `scripts/launch/seed_synthetic_traffic.sh`:
  `GET http://vm-shared-f2b9c8a6.flapjack.foo:7700/internal/storage` returns
  HTTP 403 `{"message":"Invalid Application-ID or API key","status":403}`,
  so fresh `usage_records` evidence is still not produced.
- Preserved paid-beta RC no-launch reasons map to these owner artifacts and
  rerun commands:
  - `backend_launch_gate` failed (`commerce: check_stripe_key_present, check_stripe_key_live, check_stripe_webhook_secret_present, check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current`);
    owner artifact:
    `/Users/stuart/.matt/projects/fjcloud_dev-fbeae273/apr23_pm_6_launch_coordination_and_rc_signoff.md-998f7042/artifacts/stage_03_paid_beta_rc/rc_run_20260424T003133Z/coordinator_artifacts/backend_gate_2026-04-23_203814.json`.
  - `local_signoff` failed (`reason=local_signoff_failed`); rerun through
    `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...`.
  - `ses_readiness` was blocked (`reason=credentialed_ses_identity_missing`);
    delegated owner commands/docs remain `scripts/validate_ses_readiness.sh`,
    `scripts/launch/ses_deliverability_evidence.sh`, and
    `docs/runbooks/email-production.md`.
  - `staging_billing_rehearsal` failed (`reason=staging_api_url_missing`);
    delegated owner command remains `scripts/staging_billing_rehearsal.sh`.
  - Browser lane failed in preserved RC (`browser_preflight_failed`,
    `browser_auth_setup_failed`); delegated owner command remains
    `scripts/e2e-preflight.sh` with coordinator-owned orchestration. That
    lane was rerun on 2026-04-25: `bash scripts/tests/e2e_preflight_test.sh`
    and `cd web && npm run check` passed, and the preflight owner was tightened
    so `BASE_URL`-unset runs stay aligned with Playwright's generated local
    admin-key fallback. The same owner rerun still fails in the live local
    path, though: `bash scripts/e2e-preflight.sh` reports
    `http://localhost:3001/health` unreachable, `cd web && npx playwright test
    tests/fixtures/auth.setup.ts tests/fixtures/admin.auth.setup.ts
    --project=setup:user --project=setup:admin` leaves `setup:user` on
    `/login` with `Authentication service is unavailable. Please verify
    API_URL and try again.`, and `setup:admin` hits a server-rendered
    `/admin/login` 500 (`support_reference=web-1bb22071fcb3`). A read-only
    public spot check at `2026-04-25T02:01:52Z` (`2026-04-24 22:01 EDT`)
    still returned HTTP 200 for `https://api.flapjack.foo/health`,
    `https://cloud.flapjack.foo/login`, and
    `https://cloud.flapjack.foo/admin/login`, while bogus-credential
    `POST https://api.flapjack.foo/auth/login` returned the expected HTTP 400
    `invalid email or password`, so the current blocker is the local browser
    owner rerun rather than those public surfaces being down.
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
  evidence passed at `/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867/summary.json`
  (`overall_verdict=pass`; readiness/account/identity/recipient/send-attempt
  gates all `pass`). See `docs/runbooks/email-production.md` for field-level
  interpretation and historical blocked-path context.
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
