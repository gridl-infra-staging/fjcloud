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

- Domain identity created via CLI (no Terraform resource)
- Identity verification status: `SUCCESS` in the 2026-04-21 DNS cutover update
- DKIM verification status: `SUCCESS` in the 2026-04-21 DNS cutover update
- SSM parameters mapped: `ses_from_address` and `ses_region` via `ops/scripts/lib/generate_ssm_env.sh`
- Canonical live-send evidence owner: `scripts/launch/ses_deliverability_evidence.sh` (run-scoped `summary.json` verdicts)
- Code path: `infra/api/src/services/email.rs` SesConfig validation
- RC-ready interpretation for credentialed SES/webhook/billing proof is owned by
  `docs/runbooks/paid_beta_rc_signoff.md` and must be read from coordinator
  output instead of this historical evidence page.
- Current launch blockers and prioritization are tracked in `README.md`, `PRIORITIES.md`, and `ROADMAP.md`.

### Stripe Billing

- Product/price IDs: **not yet provisioned** (ENV-BLOCKED)
- SSM parameters for `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET`: not set
- Unblock criteria: provision Stripe test-mode credentials in SSM
- Wrapper-level live evidence interpretation is owned by
  `docs/runbooks/aws_live_e2e_guardrails.md` (`checks`,
  `credentialed_checks`, `external_blockers`, `overall_verdict`).
- Local/mock pass results do not satisfy credentialed billing/webhook/SES proof.

### Health Check

- API responds `{"status":"ok"}` on port 3001 via SSM `curl http://127.0.0.1:3001/health`
- RDS TCP connectivity confirmed on port 5432 (psql not installed; bash `/dev/tcp` test)
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

### 4. Missing psql on EC2 (LOW)

`ops/terraform/compute/main.tf` user_data installs `aws-cli jq` only; no `postgresql16` package.

- **Impact**: Cannot query RDS directly from EC2. TCP fallback worked for validation.
- **Complication**: Modifying user_data forces EC2 instance replacement. Bundle with other TF changes.

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
  --env-file /Users/stuart/repos/gridl/fjcloud/.secret/.env.secret \
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
- If required live prerequisites are missing, the wrapper records a `blocked`
  verdict in `summary.json` and exits `0`; `fail` means an executed owner
  assertion failed and needs triage via the captured logs.

## Current External Blockers

- Stripe staging credentials remain environment-blocked.
- SES deliverability evidence status (2026-04-23): identity/DKIM readiness remains
  `SUCCESS`, and the preserved Stage 3 wrapper artifact is blocked rather than a
  passing live-send proof. See `docs/runbooks/email-production.md` for the
  current `fjcloud_ses_deliverability_evidence_*` artifact path and field-level
  interpretation.
- SES deliverability current state: the repo-local secret inventory parses
  through `scripts/lib/env.sh` `load_env_file` and now provides canonical
  `SES_FROM_ADDRESS=system@flapjack.foo` / `SES_REGION=us-east-1` inputs for the
  wrapper. A 2026-04-23 wrapper rerun proved sender readiness through the
  inherited `flapjack.foo` domain identity/DKIM path, then stopped with
  `overall_verdict=blocked` because the SES account remains sandboxed
  (`ProductionAccessEnabled=false`).
- SES deliverability unblock condition: request/obtain SES production access for
  the `us-east-1` account, then rerun
  `scripts/launch/ses_deliverability_evidence.sh`; do not claim first-send or
  inbox deliverability proof until a canonical wrapper run reports
  `overall_verdict: "pass"` in `summary.json`.
- The cold-storage SSE representation note is non-blocking provider-representation
  noise; see the Terraform Drift Summary above.
- RDS restore proof remains open after a gated staging run attempted on
  `2026-04-22` ended with wrapper `status=fail` / `result=fail` while the target
  remained `backing-up`; cleanup completed after the temporary target was
  deleted, and no proof file was created under
  `docs/runbooks/evidence/database-recovery/`.
- Next step: run a future gated restore that reaches `available`, execute the
  runbook sanity SQL, and write the redacted verification log under
  `docs/runbooks/evidence/database-recovery/`.
- Current authoritative blocker/prioritization context lives in `README.md`,
  `PRIORITIES.md`, and `ROADMAP.md`.
