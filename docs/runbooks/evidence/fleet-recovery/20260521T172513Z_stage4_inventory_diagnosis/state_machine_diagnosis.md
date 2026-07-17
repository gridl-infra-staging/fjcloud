# Stage 2 State Machine Diagnosis (2026-05-21)

## Purpose and Input Contract
This document diagnoses why deployments remain in `status='provisioning'` using only the frozen Stage 1 bundle at `docs/runbooks/evidence/fleet-recovery/20260521T172513Z_stage4_inventory_diagnosis/`.

Canonical Stage 1 artifacts confirmed present:
- `reconciliation_summary.json`
- `inventory_rows.json`
- `deployment_rows.json`
- `ec2_instances.json`
- `vm_inventory_status_counts.csv`
- `customer_deployments_status_counts.csv`
- `provisioning_age_distribution.csv`
- `provisioning_rows_detailed.csv`
- `provisioning_by_customer_cohort.csv`
- `billing_accuracy_impact.csv`
- `01_stage1_findings_summary.md`

Non-canonical background directory: `docs/runbooks/evidence/fleet-recovery/20260521T171423Z_stage4_inventory_diagnosis/` is explicitly incomplete (for example, `reconciliation_summary.json` there is empty) and is not used as a source of truth.

## Stage 1 Evidence Snapshot (Frozen Data)
- Provisioning pressure is sustained: `customer_deployments_status_counts.csv` shows `provisioning=131`, `running=88`, `terminated=4`.
- Aging shows most provisioning rows are not fresh: `provisioning_age_distribution.csv` reports `1h_to_6h=27`, `6h_to_24h=70`, `gte_24h=29`.
- Every provisioning row in this bundle is linked to inventory and none carry lock markers: `billing_accuracy_impact.csv` shows `provisioning_rows=131`, `provisioning_lock_rows=0`, `provisioning_rows_linked_to_inventory=131`, `provisioning_rows_missing_inventory_link=0`, `provisioning_rows_with_aws_provider_id=0`.
- Reconciliation model is consistent with shared-hostname matching (`reconciliation_summary.json`): `deployment_linkage_mismatches=0`, `stuck_shared_provisioning_rows=0`, and all `deployment_evaluations` classify as `matched_inventory_hostname` via `inventory_hostname`.

## Dedicated Provisioning State Machine (Owner Trace)
### 1) Where `provisioning` is created
- `ProvisioningService::provision_deployment` creates the deployment row through `deployment_repo.create(...)` and immediately returns the row while background work continues: `infra/api/src/services/provisioning.rs:112-171`.
- The repository owner for this write seam is `DeploymentRepo::create`: `infra/api/src/repos/deployment_repo.rs:22-30`.
- `PgDeploymentRepo::create` inserts into `customer_deployments` and returns the row: `infra/api/src/repos/pg_deployment_repo.rs:59-87`.

### 2) Claim and side-effect handoff
- Background handoff is `tokio::spawn` to `complete_provisioning(deployment_id)`: `infra/api/src/services/provisioning.rs:161-168`.
- `complete_provisioning` first calls `load_and_claim_deployment`: `infra/api/src/services/provisioning.rs:175-204`.
- Claim guard logic (`status == provisioning`, then atomic claim) is in `load_and_claim_deployment`: `infra/api/src/services/provisioning.rs:209-244`.
- Claim persistence owner is `DeploymentRepo::claim_provisioning`: `infra/api/src/repos/deployment_repo.rs:53-58`; concrete SQL owner is `PgDeploymentRepo::claim_provisioning`, which writes `provider_vm_id='provisioning-lock:<id>'` only if `status='provisioning'` and `provider_vm_id IS NULL`: `infra/api/src/repos/pg_deployment_repo.rs:164-183`.

### 3) Failure ownership (`provisioning -> failed`)
- Failure marking helper uses `deployment_repo.mark_failed_provisioning`: `infra/api/src/services/provisioning.rs:88-108`.
- `complete_provisioning` calls this helper on VM/secret provisioning errors: `infra/api/src/services/provisioning.rs:182-187`.
- `persist_dns_and_deployment` calls it on DNS failure and DB update failure paths: `infra/api/src/services/provisioning.rs:341-345` and `infra/api/src/services/provisioning.rs:368-380`.
- Repository owner is `DeploymentRepo::mark_failed_provisioning`: `infra/api/src/repos/deployment_repo.rs:60-64`; concrete SQL owner is `PgDeploymentRepo::mark_failed_provisioning`, which sets `status='failed'` and clears transient fields only when current status is still `provisioning`: `infra/api/src/repos/pg_deployment_repo.rs:185-205`.

### 4) Persisted provisioning metadata
- After VM and DNS success, dedicated path writes provider/id/url metadata through `deployment_repo.update_provisioning(...)`: `infra/api/src/services/provisioning.rs:348-352`.
- Repository seam is `DeploymentRepo::update_provisioning`: `infra/api/src/repos/deployment_repo.rs:66-74`; SQL owner is `PgDeploymentRepo::update_provisioning`: `infra/api/src/repos/pg_deployment_repo.rs:209-234`.

### 5) Only dedicated `provisioning -> running` transition owner
- The only explicit status promotion from `provisioning` to `running` is in health monitoring, not provisioning service completion: `HealthMonitor::handle_healthy_result` calls `deployment_repo.update(..., Some("running"))` when deployment.status is `provisioning`: `infra/api/src/services/health_monitor.rs:251-267`.
- `handle_unhealthy_result` ignores non-`running` deployments (`if deployment.status != "running" { return; }`), so unhealthy checks do not fail provisioning rows: `infra/api/src/services/health_monitor.rs:283-291`.

## Shared Placement State Machine (Separate Owner)
### 1) Capacity selection and optional shared-VM provisioning
- `select_shared_vm_for_new_index` first tries active inventory placement, then may call `ProvisioningService::auto_provision_shared_vm(...)` only when needed: `infra/api/src/routes/indexes/shared_vm.rs:160-237`.

### 2) Deployment attachment on shared VM
- `create_shared_deployment` creates a row then immediately calls `deployment_repo.update_provisioning(...)` with existing shared VM identifiers (`vm.id`, hostname, flapjack_url), without running dedicated `complete_provisioning`: `infra/api/src/routes/indexes/shared_vm.rs:293-337`.
- This means shared placement bypasses dedicated claim/VM/DNS side-effect sequence and directly persists attachment metadata.

## Canonical Identity Join Model for Ambiguous VM Links
When inventory/deployment rows do not map 1:1, the existing canonical join clues come from admin VM linkage helpers:
- `provider_vm_id_from_tenants(...)`: filters by `vm_provider` and matching `flapjack_url`, then normalizes provider-prefixed IDs (`provider:id` -> `id`): `infra/api/src/routes/admin/vms.rs:42-75`.
- `provider_vm_id_from_fleet(...)`: fallback scans active deployments with same `vm_provider` and `flapjack_url`, then normalizes: `infra/api/src/routes/admin/vms.rs:77-96`.
- These functions establish the current system contract: `vm_provider`, normalized `provider_vm_id`, and shared `flapjack_url` are the authoritative join clues.

## Diagnosis: Why Rows Stay `provisioning`
### Dedicated-path stall points (code-supported)
1. Dedicated rows can remain `provisioning` indefinitely if health checks never report healthy, because status promotion to `running` is owned by `HealthMonitor::handle_healthy_result`, not by `complete_provisioning` itself (`infra/api/src/services/provisioning.rs:175-204`, `infra/api/src/services/health_monitor.rs:251-267`).
2. Unhealthy checks alone cannot move dedicated provisioning rows to `failed` (`infra/api/src/services/health_monitor.rs:283-291`), so rows can persist in `provisioning` unless a provisioning-service error path triggers `mark_failed_provisioning`.
3. Any non-failing but non-healthy endpoint state is a logical limbo between `update_provisioning` metadata persistence and first healthy transition.

### Shared-placement stall points (evidence-supported)
1. Shared path writes provisioning metadata immediately via `update_provisioning` after attachment to an existing shared VM (`infra/api/src/routes/indexes/shared_vm.rs:316-325`), so many rows can accumulate on a single shared VM identity before/without running transition logic.
2. Stage 1 data matches that pattern: provisioning rows are heavily concentrated on shared host identities (for example repeated `provider_vm_id`/hostname pairs in `provisioning_rows_detailed.csv`; top count `84f62708-e895-4fd9-a4c6-21f01d811b36` appears 40 times in the frozen CSV export).
3. Reconciliation shows linkage is internally consistent (`deployment_linkage_mismatches=0`) even while provisioning counts are high, indicating the issue is lifecycle advancement, not identity mismatch (`reconciliation_summary.json`, `billing_accuracy_impact.csv`).

## Open Questions
- Are these long-lived `provisioning` rows all expected shared-index warmup behavior, or should shared-created deployments be promoted to `running` on successful index-create completion in `shared_vm.rs`?
- Should shared-placement rows use a separate explicit status (or terminal condition) to avoid overloading dedicated provisioning semantics?
- Should health-monitor logic include a bounded timeout/escalation path for provisioning rows that persist beyond a threshold without ever becoming healthy?
