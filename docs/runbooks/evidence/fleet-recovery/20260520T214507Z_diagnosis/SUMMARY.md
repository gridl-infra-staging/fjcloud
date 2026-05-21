# Stage 2 Diagnosis Summary (2026-05-20)

## Primary classification
Combined issue: **shared-placement bookkeeping defect + unhealthy shared VM processes + inventory drift**.

- Bookkeeping defect is present in the owner seam and is currently active.
- A large subset of shared VMs are reachable at EC2 level but not healthy at flapjack level.
- Inventory contains rows with no non-terminated EC2 match.

## Evidence that the customer path is still failing now
- Reproduction on current prod baseline: [`31_run_a_red.txt`](./31_run_a_red.txt) shows `run-a` failing at `create_index` with HTTP 503 after retries.
- Live fleet/deployment view: [`10_admin_fleet.json`](./10_admin_fleet.json) and [`24_customer_deployments_by_status.csv`](./24_customer_deployments_by_status.csv) show 70 non-terminated deployments, with 41 stuck in `provisioning`.

## Shared-placement owner path analysis
Code path traced per checklist:
- `create_index_on_shared_vm` → `select_shared_vm_for_new_index` → `create_shared_deployment` in [`infra/api/src/routes/indexes/shared_vm.rs`](../../../../../infra/api/src/routes/indexes/shared_vm.rs).
- In `create_shared_deployment`, `DeploymentRepo::create(...)` inserts `status=provisioning`, then `update_provisioning(...)` writes VM linkage fields but does not set `status=running`.
- `PgDeploymentRepo::update_provisioning` updates `provider_vm_id`, `ip_address`, `hostname`, `flapjack_url` only (no status transition): [`infra/api/src/repos/pg_deployment_repo.rs`](../../../../../infra/api/src/repos/pg_deployment_repo.rs).

Live proof:
- [`32_bookkeeping_hypothesis.sql.txt`](./32_bookkeeping_hypothesis.sql.txt): `provisioning_total=41`, `provider_vm_id_matches_vm_inventory_id=41`, `provider_vm_id_aws_style=0`.
- [`27_provider_inventory_reconciliation.json`](./27_provider_inventory_reconciliation.json): provisioning rows map to VM inventory UUIDs, and EC2 linkage resolves by hostname fallback, not provider VM ID contract.

Conclusion: the bookkeeping hypothesis is **proven**.

## Provider-ID contract reconciliation (to avoid false mismatches)
- Contract reference: provider-qualified IDs (`provider:id`) in [`infra/api/src/provisioner/multi.rs`](../../../../../infra/api/src/provisioner/multi.rs).
- Normalization reference: strip provider prefix only when matching provider in [`infra/api/src/routes/admin/vms.rs`](../../../../../infra/api/src/routes/admin/vms.rs).
- Applied in reconciliation artifact: [`27_provider_inventory_reconciliation.json`](./27_provider_inventory_reconciliation.json).

## Fleet health findings (healthy + unhealthy host probe)
Selection source:
- [`29_vm_probe_targets.json`](./29_vm_probe_targets.json)
  - healthy host: `vm-shared-f2b9c8a6.flapjack.foo` (`http_code=200`)
  - unhealthy host: `vm-shared-1f4d5f46.flapjack.foo` (`http_code=000`)

Captured host evidence:
- Healthy probe: [`30_host_probe_healthy_invocation.json`](./30_host_probe_healthy_invocation.json)
  - `flapjack.service` active/running
  - probe command marked Failed because `metering-agent.service` is missing on host
- Unhealthy probe: [`30_host_probe_unhealthy_invocation.json`](./30_host_probe_unhealthy_invocation.json)
  - `flapjack.service` in auto-restart loop (`status=203/EXEC`)

## Reconciled counts vs prior roadmap claim
Derived artifact: [`28_reconciliation_counts.md`](./28_reconciliation_counts.md)

Fresh counts:
- dead-but-running deployments: **37**
- inventory rows without non-terminated EC2 match: **14**
- stuck provisioning deployments: **41**

These differ from the earlier note (`41`, `~10`, `32`) and confirm drift has worsened since that snapshot.

## Owner seams and test-contract comparison
Owner seams consulted:
- Shared placement owner: [`infra/api/src/routes/indexes/shared_vm.rs`](../../../../../infra/api/src/routes/indexes/shared_vm.rs)
- Auto-provision path: [`infra/api/src/services/provisioning/auto_provision.rs`](../../../../../infra/api/src/services/provisioning/auto_provision.rs)
- Active inventory reads: [`infra/api/src/repos/pg_vm_inventory_repo.rs`](../../../../../infra/api/src/repos/pg_vm_inventory_repo.rs)
- Deployment contracts: [`infra/api/src/repos/deployment_repo.rs`](../../../../../infra/api/src/repos/deployment_repo.rs), [`infra/api/src/repos/pg_deployment_repo.rs`](../../../../../infra/api/src/repos/pg_deployment_repo.rs)

Explicit owner-contract expectations (source anchored):
- `VmInventoryRepo::list_active` contract is "active-only inventory input to placement", with SQL constrained to `status = 'active'` (optionally `AND region = $1`) in [`infra/api/src/repos/pg_vm_inventory_repo.rs:24`](../../../../../infra/api/src/repos/pg_vm_inventory_repo.rs). Shared placement calls this seam twice (before and after advisory lock) in [`infra/api/src/routes/indexes/shared_vm.rs:167`](../../../../../infra/api/src/routes/indexes/shared_vm.rs) and [`infra/api/src/routes/indexes/shared_vm.rs:184`](../../../../../infra/api/src/routes/indexes/shared_vm.rs), so non-active rows are intentionally excluded from candidate selection.
- `DeploymentRepo::claim_provisioning` contract is an atomic single-writer claim for provisioning side effects; trait docs require first caller `true`, concurrent callers `false` in [`infra/api/src/repos/deployment_repo.rs:53`](../../../../../infra/api/src/repos/deployment_repo.rs), implemented as CAS update (`status='provisioning' AND provider_vm_id IS NULL`) in [`infra/api/src/repos/pg_deployment_repo.rs:167`](../../../../../infra/api/src/repos/pg_deployment_repo.rs).
- `DeploymentRepo::mark_failed_provisioning` contract is rollback cleanup for failed provisioning: set `status='failed'` and clear transient linkage fields (`provider_vm_id`, `ip_address`, `hostname`, `flapjack_url`) while still provisioning, defined in trait docs at [`infra/api/src/repos/deployment_repo.rs:60`](../../../../../infra/api/src/repos/deployment_repo.rs) and implemented in [`infra/api/src/repos/pg_deployment_repo.rs:188`](../../../../../infra/api/src/repos/pg_deployment_repo.rs).
- Persisted deployment linkage contract in shared placement currently bypasses a `running` transition: `create_shared_deployment` inserts via `DeploymentRepo::create` then calls `update_provisioning` with `provider_vm_id=vm_inventory.id` and endpoint fields in [`infra/api/src/routes/indexes/shared_vm.rs:299`](../../../../../infra/api/src/routes/indexes/shared_vm.rs); `PgDeploymentRepo::update_provisioning` writes linkage fields only and does not mutate status in [`infra/api/src/repos/pg_deployment_repo.rs:209`](../../../../../infra/api/src/repos/pg_deployment_repo.rs).

Test contract grounding:
- Shared placement returns immediate 201 and shared endpoint: [`infra/api/tests/indexes_test.rs:4048`](../../../../../infra/api/tests/indexes_test.rs)
- Auto-provision cleanup behavior on failure: [`infra/api/tests/provisioning_service_test.rs:302`](../../../../../infra/api/tests/provisioning_service_test.rs)

Gap: existing tests do not assert a shared deployment status transition out of `provisioning` after `create_shared_deployment` linkage update.

## Stage handoff guidance
Stage 3 (probe commit) should assert:
1. `status=provisioning` rows where `provider_vm_id = vm_inventory.id::text` remain stuck over time (age threshold assertion).
2. `provider_vm_id` for shared-placement rows is not provider-qualified and cannot be used as provider VM identifier without hostname mapping.
3. dead-but-running count and inventory-missing-EC2 count are computed from live probes using the same normalization rules.

Stage 4/5 direction:
- Treat next work as **combined remediation**:
  - inventory/data repair (stuck provisioning + stale inventory rows), and
  - code fix in shared-placement bookkeeping seam (status transition contract), and
  - VM recovery for hosts with flapjack restart/exec failures.

## Open questions
- Why is `metering-agent.service` missing on the sampled healthy host? (Could be AMI/service drift; verify expected unit name in provisioning artifacts.)
- Root cause of flapjack `203/EXEC` on unhealthy host (binary missing/permissions/ExecStart mismatch) needs targeted VM recovery analysis.
- Should shared-placement `provider_vm_id` field represent inventory ID by design, or should schema/field semantics be split to avoid contract confusion with provider VM IDs?
