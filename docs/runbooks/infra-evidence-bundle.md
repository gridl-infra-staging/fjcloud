# Infrastructure Evidence Bundle

> Date: 2026-02-27
> Stage: Stream G — Stage 4 (Evidence Bundle and Checklist Closeout)
> Status: All scripted validation PASS; AWS runtime items deferred with named owner and unblock conditions

---

## 1. Test Suite Results

All static test suites passing as of 2026-02-26.

| Suite                | File                                                |   Tests | Status       |
| -------------------- | --------------------------------------------------- | ------: | ------------ |
| Provision Bootstrap  | `ops/terraform/tests_provision_bootstrap_static.sh` |      37 | PASS         |
| Bootstrap Validation | `ops/terraform/tests_bootstrap_static.sh`           |      32 | PASS         |
| Deploy Scripts       | `ops/terraform/tests_deploy_scripts_static.sh`      |      67 | PASS         |
| Stage 7 Infra        | `ops/terraform/tests_stage7_static.sh`              |      81 | PASS         |
| Runbook Content      | `ops/terraform/tests_runbooks_static.sh`            |      58 | PASS         |
| **Total**            |                                                     | **275** | **ALL PASS** |

### Additional test suites (pre-existing, not modified by this checklist)

| Suite                 | File                                              | Notes                  |
| --------------------- | ------------------------------------------------- | ---------------------- |
| Stage 1               | `ops/terraform/tests_stage1_static.sh`            | Networking module      |
| Stage 2               | `ops/terraform/tests_stage2_static.sh`            | Compute module         |
| Stage 2 Regression    | `ops/terraform/tests_stage2_static_regression.sh` | Compute regression     |
| Stage 3               | `ops/terraform/tests_stage3_static.sh`            | Data module            |
| Stage 4               | `ops/terraform/tests_stage4_static.sh`            | DNS module             |
| Stage 5               | `ops/terraform/tests_stage5_static.sh`            | Monitoring module      |
| Stage 6               | `ops/terraform/tests_stage6_static.sh`            | Shared config          |
| Stage 7 Secrets       | `ops/terraform/tests_stage7_secrets_static.sh`    | Secret audit           |
| Stage 7 Runtime Smoke | `ops/terraform/tests_stage7_runtime_smoke.sh`     | Runtime (requires AWS) |

---

## 2. Script Inventory

### Operational Scripts

| Script                 | Path                                 | Lines | Purpose                                            |
| ---------------------- | ------------------------------------ | ----: | -------------------------------------------------- |
| deploy.sh              | `ops/scripts/deploy.sh`              |   269 | SSM-based deploy to EC2 instance                   |
| rollback.sh            | `ops/scripts/rollback.sh`            |   200 | SSM-based rollback to previous release             |
| migrate.sh             | `ops/scripts/migrate.sh`             |    45 | Database migration on instance                     |
| provision_bootstrap.sh | `ops/scripts/provision_bootstrap.sh` |   192 | Create bootstrap AWS resources (S3, DynamoDB, SSM) |
| validate_bootstrap.sh  | `ops/scripts/validate_bootstrap.sh`  |   219 | Validate bootstrap resource state                  |
| bootstrap.sh           | `ops/user-data/bootstrap.sh`         |   117 | EC2 user-data bootstrap script                     |
| audit_no_secrets.sh    | `ops/terraform/audit_no_secrets.sh`  |   232 | Secrets audit for Terraform files                  |
| test_helpers.sh        | `ops/terraform/test_helpers.sh`      |   142 | Shared test helper functions                       |

### Test Suites (lines)

| Suite                               | Lines |
| ----------------------------------- | ----: |
| tests_provision_bootstrap_static.sh |   132 |
| tests_bootstrap_static.sh           |   117 |
| tests_deploy_scripts_static.sh      |   159 |
| tests_stage7_static.sh              |   162 |
| tests_runbooks_static.sh            |   143 |

---

## 3. Terraform Module Inventory

6 modules under `ops/terraform/`:

| Module     | .tf Files |     Lines | Purpose                                          |
| ---------- | --------: | --------: | ------------------------------------------------ |
| networking |         4 |       341 | VPC, subnets, gateways, security groups          |
| compute    |         4 |       156 | EC2 instance, SSH key pair                       |
| data       |         4 |       242 | RDS PostgreSQL, SSM parameters, S3 cold tier     |
| dns        |         4 |       243 | Route53 zone, ACM certificate, ALB, listeners    |
| monitoring |         4 |       275 | CloudWatch alarms, SNS topic                     |
| \_shared   |         5 |       183 | Backend config, common variables, provider setup |
| **Total**  |    **25** | **1,440** |                                                  |

---

## 4. CloudWatch Alarm Definitions

6 alarms defined in `ops/terraform/monitoring/main.tf`, all namespaced as `fjcloud-${env}-<suffix>`:

| Alarm                          | Metric                   | Namespace          | Threshold | Period | Eval Periods |
| ------------------------------ | ------------------------ | ------------------ | --------- | -----: | -----------: |
| `api-cpu-high`                 | CPUUtilization           | AWS/EC2            | > 80%     |   300s |            2 |
| `api-status-check-failed`      | StatusCheckFailed        | AWS/EC2            | >= 1      |   300s |            2 |
| `rds-cpu-high`                 | CPUUtilization           | AWS/RDS            | > 80%     |   300s |            2 |
| `rds-free-storage-low`         | FreeStorageSpace         | AWS/RDS            | < 2 GiB   |   300s |            2 |
| `alb-5xx-error-rate`           | Math: 5XX/Total          | AWS/ApplicationELB | > 1%      |   300s |            1 |
| `alb-p99-target-response-time` | TargetResponseTime (p99) | AWS/ApplicationELB | > 2s      |   300s |            1 |

All alarms fire to SNS topic `fjcloud-alerts-${env}`.

---

## 5. Bootstrap Resource Inventory

Resources created by `ops/scripts/provision_bootstrap.sh` and validated by `ops/scripts/validate_bootstrap.sh`:

### S3 Buckets

| Bucket                    | Purpose                      | Versioning | Encryption | Public Access Block |
| ------------------------- | ---------------------------- | :--------: | :--------: | :-----------------: |
| `fjcloud-tfstate-${env}`  | Terraform state storage      |  Enabled   |   AES256   |     All blocked     |
| `fjcloud-releases-${env}` | Release artifacts (binaries) |  Enabled   |     —      |     All blocked     |

### DynamoDB Table

| Table            | Purpose                 | Key Schema        |
| ---------------- | ----------------------- | ----------------- |
| `fjcloud-tflock` | Terraform state locking | `LockID` (String) |

### SSM Parameters

| Parameter                      | Type         | Purpose                      |
| ------------------------------ | ------------ | ---------------------------- |
| `/fjcloud/${env}/database_url` | SecureString | PostgreSQL connection string |

### Route53

| Resource    | Domain         | Purpose                                      |
| ----------- | -------------- | -------------------------------------------- |
| Hosted Zone | `flapjack.foo` | DNS delegation for the canonical public zone |

---

## 6. Runbook Inventory

4 operational runbooks created for this checklist:

| Runbook         | Path                                     | Lines | Purpose                         |
| --------------- | ---------------------------------------- | ----: | ------------------------------- |
| DNS Cutover     | `docs/runbooks/infra-dns-cutover.md`     |   153 | Porkbun → Route53 NS delegation |
| Deploy/Rollback | `docs/runbooks/infra-deploy-rollback.md` |   172 | SSM-based deploy lifecycle      |
| Terraform Apply | `docs/runbooks/infra-terraform-apply.md` |   178 | Staging/prod Terraform workflow |
| Alarm Triage    | `docs/runbooks/infra-alarm-triage.md`    |   274 | CloudWatch alarm investigation  |

Related updates:

- `docs/runbooks/api-deployment.md` — DEPRECATED notice added, points to `infra-deploy-rollback.md`
- `ops/BOOTSTRAP.md` — Updated with `provision_bootstrap.sh` / `validate_bootstrap.sh` references

---

## 7. Runtime Evidence (DEFERRED — owner: Stuart)

The following evidence requires live AWS access and/or DNS delegation to collect. Each item has a named owner and unblock condition.

Future live evidence capture should run through the wrapper entrypoint so each
run produces a single run-level JSON artifact:

```bash
bash scripts/launch/live_e2e_evidence.sh \
  --env staging \
  --domain flapjack.foo \
  --artifact-dir <dir> \
  --env-file /Users/stuart/repos/gridl/fjcloud/.secret/.env.secret \
  --ami-id <ami-xxxxxxxxxxxxxxxxx>
```

Wrapper/owner split for this deferred section:

- Wrapper: `scripts/launch/live_e2e_evidence.sh`
- Runtime owner script: `ops/terraform/tests_stage7_runtime_smoke.sh`
- Credentialed billing owner script: `scripts/staging_billing_rehearsal.sh`

For each rerun, use the generated `summary.json` inside the wrapper run
directory under `--artifact-dir` as the canonical machine-readable verdict
record for this bundle's deferred runtime items.

Current blocker interpretation is owned by:

- `docs/runbooks/paid_beta_rc_signoff.md` for RC `ready`/`verdict` semantics.
- `docs/runbooks/aws_live_e2e_guardrails.md` for live wrapper lane semantics
  (`checks`, `credentialed_checks`, `external_blockers`, `overall_verdict`).

- [ ] `validate_bootstrap.sh staging` output — **Owner:** Stuart. **Blocker:** AWS credentials (`~/.aws/` not configured). **Unblock:** Configure AWS CLI with staging IAM credentials.
- [ ] `validate_bootstrap.sh prod` output — **Owner:** Stuart. **Blocker:** AWS credentials. **Unblock:** Configure AWS CLI with prod IAM credentials.
- [ ] Runtime wrapper rerun evidence (`scripts/launch/live_e2e_evidence.sh`) — **Owner:** Stuart. **Evidence contract:** use the wrapper run directory under `--artifact-dir` and `summary.json` as the run-level source of truth.
- [ ] Current runtime blocker/status authority — **Owner:** Stuart. **Reference:** `docs/runbooks/staging-evidence.md` is the canonical blocker-status document for ACM/ALB/target-health/public-health state.

This section tracks deferred evidence tasks only. Current live ACM/ALB/target/health
status and blocker evolution are maintained in `docs/runbooks/staging-evidence.md`
to avoid stale duplicated per-check status claims in this historical bundle.
Do not copy status tables from wrapper `summary.json`, `ROADMAP.md`, or
`PRIORITIES.md` into this section.

---

## 8. Stream G Stage 2 — Runtime Smoke Foundation Evidence

**Stream:** G — Runtime Unblock and Cutover
**Stage:** 2 — Staging Runtime Completion (runtime assertions wired)
**Captured:** 2026-02-27
**Status:** PASS — all runtime behavioral and static contract tests green

### 8.1 What Was Built

The runtime smoke script (`ops/terraform/tests_stage7_runtime_smoke.sh`) was extended with:

| Feature                             | Detail                                                                                          |
| ----------------------------------- | ----------------------------------------------------------------------------------------------- |
| `runtime_fail()` helper             | Emits `RUNTIME FAIL [<class>]: <message>` + remediation, exits with class-specific code         |
| Exit codes 20–26                    | One per runtime check class (ACM, ALB, TG, health, deploy, migrate, rollback)                   |
| `--run-rollback` / `--rollback-sha` | Opt-in rollback validation with SHA validation                                                  |
| `FJCLOUD_SCRIPTS_DIR` override      | Test-injectable scripts directory (deploy/migrate/rollback)                                     |
| `check_health_once()`               | Extracted single-probe helper used by retry loop and deploy sampler                             |
| `run_deploy_with_health_sampling()` | Runs `deploy.sh` in background; polls health during rollout; exits 24 on any non-200 mid-deploy |
| Migration idempotency check         | Runs migrate.sh twice; second failure exits 25 (`migrate_idempotency`)                          |
| Rollback pipeline                   | Calls `rollback.sh ENV SHA`; exits 26 on failure                                                |

### 8.2 Runtime Assertion Contract

| Check Class         | Exit Code | Constant                 | Assert Function / Call      |
| ------------------- | --------- | ------------------------ | --------------------------- |
| acm_not_issued      | 20        | EXIT_ACM_NOT_ISSUED      | assert_acm_cert_issued      |
| alb_no_listener     | 21        | EXIT_ALB_NO_LISTENER     | assert_alb_https_listener   |
| tg_unhealthy        | 22        | EXIT_TG_UNHEALTHY        | assert_target_group_healthy |
| health_fail         | 23        | EXIT_HEALTH_FAIL         | curl HEALTH_URL             |
| deploy_health_fail  | 24        | EXIT_DEPLOY_HEALTH_FAIL  | post-deploy curl            |
| migrate_fail        | 25        | EXIT_MIGRATE_FAIL        | migrate.sh run 1            |
| migrate_idempotency | 25        | EXIT_MIGRATE_IDEMPOTENCY | migrate.sh run 2            |
| rollback_fail       | 26        | EXIT_ROLLBACK_FAIL       | rollback.sh                 |

### 8.3 Test Evidence

#### Evidence Run 1 — Runtime Behavioral Tests

```
Command  : bash ops/terraform/tests_stage7_runtime_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

```
=== Stage 7 Runtime Behavioral Tests ===

--- ACM cert not ISSUED → exit 20 ---
PASS: ACM cert not ISSUED exits with code 20
PASS: ACM not-ISSUED outputs RUNTIME FAIL [acm_not_issued]
PASS: ACM not-ISSUED remediation mentions cert/validation state

--- No ALB HTTPS listener → exit 21 ---
PASS: No ALB HTTPS listener exits with code 21
PASS: No ALB listener outputs RUNTIME FAIL [alb_no_listener]
PASS: No ALB listener remediation mentions 443/HTTPS

--- Unhealthy target group → exit 22 ---
PASS: Unhealthy target group exits with code 22
PASS: Unhealthy TG outputs RUNTIME FAIL [tg_unhealthy]
PASS: Unhealthy TG remediation mentions health/instance/target

--- Health endpoint non-200 → exit 23 ---
PASS: Health endpoint non-200 exits with code 23
PASS: Health failure outputs RUNTIME FAIL [health_fail]
PASS: Health failure remediation mentions health URL or curl

--- Deploy post-deploy health failure → exit 24 ---
PASS: Post-deploy health failure exits with code 24
PASS: Post-deploy health failure outputs RUNTIME FAIL [deploy_health_fail]

--- Migration failure → exit 25 ---
PASS: Migration failure exits with code 25
PASS: Migration failure outputs RUNTIME FAIL [migrate_fail]

--- Migration non-idempotent re-run → exit 25 ---
PASS: Non-idempotent migration re-run exits with code 25
PASS: Non-idempotent migration outputs RUNTIME FAIL [migrate_idempotency]

--- Rollback failure → exit 26 ---
PASS: Rollback failure exits with code 26
PASS: Rollback failure outputs RUNTIME FAIL [rollback_fail]

--- Deploy rollout probe degradation → exit 24 ---
PASS: Deploy rollout probe failure exits with code 24
PASS: Deploy rollout probe failure outputs RUNTIME FAIL [deploy_health_fail]

--- Post-rollback health failure → exit 23 ---
PASS: Post-rollback health failure exits with code 23
PASS: Post-rollback health failure outputs RUNTIME FAIL [health_fail]

--- Full successful staging sequence (all mocked, all pass) ---
PASS: Full staged sequence exits 0 with all mocks passing
PASS: Full sequence emits completion message

Stage 7 runtime behavioral: 26/26 passed.
```

#### Evidence Run 2 — Runtime Static Contract Tests

```
Command  : bash ops/terraform/tests_stage7_runtime_static.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

```
Stage 7 runtime static contract: 48/48 passed.
```

Checks cover: exit code constants (8), runtime_fail helper (2), FJCLOUD_SCRIPTS_DIR override (2), --run-rollback/--rollback-sha CLI args (4), per-class assert functions (12), deploy/migrate/rollback pipeline wiring (12), ordering after terraform init (4), post-rollback health/TG assertions (4).

#### Evidence Run 3 — Preflight Tests (regression)

```
Command  : bash ops/terraform/tests_stage7_preflight_static.sh && bash ops/terraform/tests_stage7_preflight_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS (no regressions)
```

```
Stage 7 preflight static contract: 22/22 passed.
Stage 7 preflight behavioral: 16/16 passed.
```

---

## 9. Stream G Stage 3 — Metering & Billing Validation Evidence

**Stream:** G — Runtime Unblock and Cutover
**Stage:** 3 — CI/CD Runtime Truth and Bootstrap Parity (metering/billing validation)
**Captured:** 2026-02-27
**Status:** PASS — all metering, billing, reconciliation, and idempotency tests green

### 9.1 What Was Built

| Feature                          | Detail                                                                                                             |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| Validation contract              | `IMPLEMENTATION_CHECKLIST/scripts/lib/metering_validation_contract.md` — formal contract for `BACKEND_LIVE_GATE=1` |
| `validate_metering_capture()`    | Verifies `usage_records.csv` has real ingested data                                                                |
| `validate_rollup_correctness()`  | Verifies deterministic aggregation from `usage_records` to `usage_daily`                                           |
| `validate_billing_pipeline()`    | Verifies summarize/invoice ran on current source, with staleness check                                             |
| `reconcile_decimal_total()`      | Decimal-safe reconciliation (no float drift), minimum spend enforcement                                            |
| `run_monthly_billing_pipeline()` | Full pipeline with idempotency via signature comparison                                                            |
| `create_metering_fixture_data()` | Deterministic test fixture generator                                                                               |
| `metering_run_validations()`     | Gate orchestrator: fail-fast sequential checks with structured JSON                                                |
| Gate integration                 | `live-backend-gate.sh` runs both Stripe (Stage 2) and metering (Stage 3) checks                                    |

### 9.2 Reason Codes

| Code                         | Type     | Source                         |
| ---------------------------- | -------- | ------------------------------ |
| `METERING_USAGE_MISSING`     | blocking | `validate_metering_capture`    |
| `METERING_ROLLUP_MISSING`    | blocking | `validate_rollup_correctness`  |
| `METERING_ROLLUP_MISMATCH`   | blocking | `validate_rollup_correctness`  |
| `BILLING_SUMMARY_MISSING`    | blocking | `validate_billing_pipeline`    |
| `BILLING_INVOICE_MISSING`    | blocking | `validate_billing_pipeline`    |
| `BILLING_PIPELINE_STALE`     | blocking | `validate_billing_pipeline`    |
| `BILLING_DECIMAL_MISMATCH`   | blocking | `reconcile_decimal_total`      |
| `BILLING_MIN_SPEND_MISMATCH` | blocking | `reconcile_decimal_total`      |
| `METERING_CAPTURE_OK`        | pass     | `validate_metering_capture`    |
| `METERING_ROLLUP_OK`         | pass     | `validate_rollup_correctness`  |
| `BILLING_PIPELINE_OK`        | pass     | `validate_billing_pipeline`    |
| `BILLING_DECIMAL_OK`         | pass     | `reconcile_decimal_total`      |
| `BILLING_PIPELINE_RUN_OK`    | pass     | `run_monthly_billing_pipeline` |
| `BILLING_IDEMPOTENT_REPLAY`  | pass     | `run_monthly_billing_pipeline` |

### 9.3 Test Evidence

#### Evidence Run 1 — Metering/Billing Unit Tests

```
Command  : bash scripts/tests/metering_billing_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (7/7 tests)
```

Tests: metering capture fail, rollup fail, billing pipeline fail, decimal mismatch, min spend, monthly path + idempotency, structured reason codes.

#### Evidence Run 2 — Gate Integration Tests

```
Command  : bash scripts/tests/gate_metering_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (2/2 tests)
```

Tests: gate blocks on missing metering (exit 1, `METERING_USAGE_MISSING`), gate passes with valid data (exit 0, `"result": "pass"`).

#### Evidence Run 3 — Idempotency Verification

```
Command  : run_monthly_billing_pipeline (first run) then run_monthly_billing_pipeline (replay)
Timestamp: 2026-02-27
Verdict  : PASS
```

First run: `BILLING_PIPELINE_RUN_OK` with signature `units=300,total=15.00`.
Replay: `BILLING_IDEMPOTENT_REPLAY` — no duplicate side effects.

#### Evidence Run 4 — Decimal Reconciliation

```
Command  : reconcile_decimal_total with matching, mismatching, and min-spend-violating inputs
Timestamp: 2026-02-27
Verdict  : PASS (all cases produce expected reason codes)
```

- `reconcile_decimal_total "15.00" "15.00" "10.00"` → `BILLING_DECIMAL_OK`
- `reconcile_decimal_total "10.015" "10.01" "0.00"` → `BILLING_DECIMAL_MISMATCH`
- `reconcile_decimal_total "8.00" "10.00" "10.00"` → `BILLING_MIN_SPEND_MISMATCH`

Full transcript: `IMPLEMENTATION_CHECKLIST/scripts/evidence/stage3_metering_billing_transcript.md`

---

## 10. Stream G Stage 4 — Consolidated Evidence and Closeout

**Stream:** G — Runtime Unblock and Cutover
**Stage:** 4 — Evidence Bundle and Checklist Closeout
**Captured:** 2026-02-27
**Status:** PASS — all scripted validation green; AWS runtime items deferred with owner/blocker/unblock

### 10.1 Stage 1 — Preflight Guardrails Evidence

```
Command  : bash ops/terraform/tests_stage7_preflight_static.sh
Timestamp: 2026-02-27
Verdict  : PASS (22/22 static contract tests)
```

```
Command  : bash ops/terraform/tests_stage7_preflight_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS (16/16 behavioral tests)
```

Covers: AWS credentials preflight (exit 10), DNS delegation preflight (exit 11), S3 release artifact preflight (exit 12), self-owned AMI preflight (exit 13), shared `preflight_fail()` helper, fail-fast ordering, actionable remediation output.

### 10.2 Stage 2 — Runtime Smoke Foundation Evidence

```
Command  : bash ops/terraform/tests_stage7_runtime_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS (26/26 behavioral tests)
```

```
Command  : bash ops/terraform/tests_stage7_runtime_static.sh
Timestamp: 2026-02-27
Verdict  : PASS (48/48 static contract tests)
```

Covers: ACM assertion (exit 20), ALB listener assertion (exit 21), target group assertion (exit 22), health endpoint assertion (exit 23), post-deploy health (exit 24), migration failure + idempotency (exit 25), rollback failure (exit 26), post-rollback health/TG assertions, full successful sequence, FJCLOUD_SCRIPTS_DIR override, --run-rollback/--rollback-sha CLI args.

### 10.3 Stage 3 — Metering, Billing, and Stripe Validation Evidence

#### Metering/Billing Unit Tests

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/metering_billing_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (7/7 tests)
```

Tests: metering capture fail on empty, rollup fail on missing daily, billing pipeline fail on missing summary/invoice, decimal precision mismatch, minimum spend enforcement, monthly pipeline + idempotent replay, structured fail reason codes.

#### Gate Integration Tests

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/gate_metering_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (2/2 tests)
```

Tests: `BACKEND_LIVE_GATE=1` blocks launch on `METERING_USAGE_MISSING` (exit 1), gate passes with valid Stripe + metering fixture data (exit 0, `"result": "pass"`).

#### Stripe Gate Strictness Tests

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/stripe_gate_stage2_test.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

Tests: launch mode fails on missing forwarding, missing key, invalid key format, failed probe. Non-launch mode skips with `STRIPE_NOT_LAUNCH_MODE`.

#### Stripe Flow Tests

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/stripe_flow_stage2_test.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

Tests: success flow emits evidence, idempotency flow enforces single side effect, failure flow emits reason code.

#### Idempotency Verification (Individual Run)

```
Command  : run_monthly_billing_pipeline (first) then run_monthly_billing_pipeline (replay)
Timestamp: 2026-02-27
Verdict  : PASS
Output   : First: {"status":"pass","reason_code":"BILLING_PIPELINE_RUN_OK","evidence":{"signature":"units=300,total=15.00"}}
           Replay: {"status":"pass","reason_code":"BILLING_IDEMPOTENT_REPLAY","evidence":{"signature":"units=300,total=15.00"}}
```

#### Decimal Reconciliation (Individual Runs)

```
Command  : reconcile_decimal_total "15.00" "15.00" "10.00"
Timestamp: 2026-02-27
Verdict  : PASS
Output   : {"status":"pass","reason_code":"BILLING_DECIMAL_OK","evidence":{"actual":"15.00","expected":"15.00","minimum_spend":"10.00"}}
```

```
Command  : reconcile_decimal_total "10.015" "10.01" "0.00"
Timestamp: 2026-02-27
Verdict  : FAIL (expected — precision mismatch detected)
Output   : {"status":"fail","reason_code":"BILLING_DECIMAL_MISMATCH","evidence":{"actual":"10.02","expected":"10.01"}}
```

```
Command  : reconcile_decimal_total "8.00" "10.00" "10.00"
Timestamp: 2026-02-27
Verdict  : FAIL (expected — minimum spend violation)
Output   : {"status":"fail","reason_code":"BILLING_MIN_SPEND_MISMATCH","evidence":{"actual":"8.00","minimum_spend":"10.00"}}
```

### 10.4 Stage 4 — Final Regression Pass

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/metering_billing_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (7/7)
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/gate_metering_stage3_test.sh
Timestamp: 2026-02-27
Verdict  : PASS (2/2)
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/stripe_gate_stage2_test.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/scripts/tests/stripe_flow_stage2_test.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/ops/terraform/tests_stage4_cicd_contract.sh
Timestamp: 2026-02-27
Verdict  : PASS (8/8 CI/CD contract checks)
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/ops/terraform/tests_stage3_runtime_truth_static.sh
Timestamp: 2026-02-27
Verdict  : PASS (13/13 static contract tests)
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/ops/terraform/tests_stage3_runtime_truth_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/ops/terraform/tests_stage3_external_prereqs_unit.sh
Timestamp: 2026-02-27
Verdict  : PASS (5/5 unit tests)
```

```
Command  : bash IMPLEMENTATION_CHECKLIST/ops/terraform/run_stage3_runtime_truth.sh
Timestamp: 2026-02-27
Verdict  : PASS
Output   : {"result":"pass","final_conclusion":"success","issues":[]}
```

All Stream G test suites green. No regressions.

---

## 11. Cutover Requirement Summary

This table is a historical closeout snapshot. For current blocker resolution
status and live updates, refer to `docs/runbooks/staging-evidence.md` as the
canonical status document.

| Requirement                   | Evidence Status              | Reference                                                                        |
| ----------------------------- | ---------------------------- | -------------------------------------------------------------------------------- |
| AWS credentials preflight     | PASS (scripted)              | Section 10.1 — preflight behavioral 16/16                                        |
| DNS delegation preflight      | PASS (scripted)              | Section 10.1 — preflight behavioral 16/16                                        |
| S3 release artifact preflight | PASS (scripted)              | Section 10.1 — preflight behavioral 16/16                                        |
| Self-owned AMI preflight      | PASS (scripted)              | Section 10.1 — preflight behavioral 16/16                                        |
| ACM cert ISSUED               | See canonical current status | `docs/runbooks/staging-evidence.md`                                              |
| ALB HTTPS listener (443)      | See canonical current status | `docs/runbooks/staging-evidence.md`                                              |
| Target group healthy          | See canonical current status | `docs/runbooks/staging-evidence.md`                                              |
| Health endpoint 200           | See canonical current status | `docs/runbooks/staging-evidence.md`                                              |
| Deploy (no downtime)          | DEFERRED                     | Section 7 — **Owner:** Stuart. **Blocker:** DNS + AMI + S3 artifacts.            |
| Migrate (+ idempotent)        | DEFERRED                     | Section 7 — **Owner:** Stuart. **Blocker:** DNS + AMI + S3 artifacts.            |
| Rollback (clean restore)      | DEFERRED                     | Section 7 — **Owner:** Stuart. **Blocker:** DNS + AMI + S3 artifacts.            |
| Metering capture validation   | PASS                         | Section 10.3 — metering_billing_stage3 7/7                                       |
| Rollup correctness            | PASS                         | Section 10.3 — metering_billing_stage3 7/7                                       |
| Billing pipeline validation   | PASS                         | Section 10.3 — metering_billing_stage3 7/7                                       |
| Decimal reconciliation        | PASS                         | Section 10.3 — individual validator runs with JSON                               |
| Billing idempotency           | PASS                         | Section 10.3 — idempotency verification                                          |
| Stripe gate strictness        | PASS                         | Section 10.3 — stripe_gate_stage2                                                |
| Stripe flow evidence          | PASS                         | Section 10.3 — stripe_flow_stage2                                                |
| Bootstrap staging             | DEFERRED                     | Section 7 — **Owner:** Stuart. **Blocker:** AWS credentials.                     |
| Bootstrap prod                | DEFERRED                     | Section 7 — **Owner:** Stuart. **Blocker:** AWS credentials.                     |
| CI/CD workflow contract       | PASS (scripted)              | Section 10.4 — cicd_contract 8/8                                                 |
| CI/CD PR workflow             | DEFERRED                     | **Owner:** Stuart. **Blocker:** Requires real PR run with captured run ID.       |
| CI/CD deploy workflow         | DEFERRED                     | **Owner:** Stuart. **Blocker:** Requires merge-to-main run with captured run ID. |
