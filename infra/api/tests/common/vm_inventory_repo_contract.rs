use api::repos::{
    PgVmInventoryRepo, VmDecommissionResult, VmInventoryRepo, VmRetirementAssessment,
    VmRetirementBlocker, VmRetirementConflict,
};
use sqlx::PgPool;
use uuid::Uuid;

use super::vm_inventory_reference_guard_fixtures::{
    insert_all_live_vm_references, insert_customer, insert_deployment, insert_tenant, insert_vm,
    EXPECTED_VM_REFERENCE_COLUMNS,
};

pub async fn assert_exact_live_reference_blockers(pool: &PgPool) {
    let vm_id = insert_vm(pool, "repo-blocked-vm", "active").await;
    let other_vm_id = insert_vm(pool, "repo-blocker-peer", "active").await;
    insert_all_live_vm_references(pool, vm_id, other_vm_id, "repo_blockers").await;
    let repo = PgVmInventoryRepo::new(pool.clone());

    let actual = repo
        .retirement_blockers(vm_id, "repo-blocked-vm")
        .await
        .expect("inspect repository retirement blockers");

    assert_eq!(
        actual,
        VmRetirementAssessment::Blocked(expected_live_reference_blockers())
    );
}

pub async fn assert_structured_identity_and_status_conflicts(pool: &PgPool) {
    let repo = PgVmInventoryRepo::new(pool.clone());
    let unknown_vm_id = Uuid::new_v4();
    let draining_vm_id = insert_vm(pool, "repo-draining-vm", "draining").await;

    assert_eq!(
        repo.retirement_blockers(unknown_vm_id, "unknown-vm")
            .await
            .expect("inspect unknown vm"),
        VmRetirementAssessment::Conflict(VmRetirementConflict::UnknownVm {
            vm_id: unknown_vm_id
        })
    );
    assert_eq!(
        repo.retirement_blockers(draining_vm_id, "wrong-hostname")
            .await
            .expect("inspect hostname mismatch"),
        VmRetirementAssessment::Conflict(VmRetirementConflict::HostnameMismatch {
            expected_hostname: "wrong-hostname".to_string(),
            actual_hostname: "repo-draining-vm".to_string(),
        })
    );
    assert_eq!(
        repo.retirement_blockers(draining_vm_id, "repo-draining-vm")
            .await
            .expect("inspect non-active vm"),
        VmRetirementAssessment::Conflict(VmRetirementConflict::InvalidStatus {
            actual_status: "draining".to_string()
        })
    );
}

pub async fn assert_decommissions_once_and_repeats_idempotently(pool: &PgPool) {
    let vm_id = insert_vm(pool, "repo-retired-vm", "active").await;
    let repo = PgVmInventoryRepo::new(pool.clone());

    assert_eq!(
        repo.decommission_if_unreferenced(vm_id, "repo-retired-vm")
            .await
            .expect("decommission eligible vm"),
        VmDecommissionResult::Decommissioned
    );
    assert_inventory_status(pool, vm_id, "decommissioned").await;
    assert_eq!(
        repo.decommission_if_unreferenced(vm_id, "repo-retired-vm")
            .await
            .expect("repeat decommission"),
        VmDecommissionResult::AlreadyDecommissioned
    );
    assert_eq!(
        repo.decommission_if_unreferenced(vm_id, "wrong-hostname")
            .await
            .expect("reject repeat with mismatched identity"),
        VmDecommissionResult::Conflict(VmRetirementConflict::HostnameMismatch {
            expected_hostname: "wrong-hostname".to_string(),
            actual_hostname: "repo-retired-vm".to_string(),
        })
    );
}

pub async fn assert_rejects_blocked_unknown_and_non_active_retirement(pool: &PgPool) {
    let blocked_vm_id = insert_vm(pool, "repo-blocked-retirement", "active").await;
    let draining_vm_id = insert_vm(pool, "repo-non-active", "draining").await;
    let customer_id = insert_customer(pool, "repo_rejection").await;
    let deployment_id = insert_deployment(pool, customer_id, "repo-rejection-node").await;
    insert_tenant(
        pool,
        customer_id,
        deployment_id,
        "repo_rejection_tenant",
        blocked_vm_id,
    )
    .await
    .expect("insert blocking tenant");
    let repo = PgVmInventoryRepo::new(pool.clone());
    let unknown_vm_id = Uuid::new_v4();

    assert_eq!(
        repo.decommission_if_unreferenced(blocked_vm_id, "repo-blocked-retirement")
            .await
            .expect("reject blocked retirement"),
        VmDecommissionResult::Blocked(vec![VmRetirementBlocker {
            owner: "customer_tenants".to_string(),
            reference_column: "vm_id".to_string(),
            count: 1,
        }])
    );
    assert_inventory_status(pool, blocked_vm_id, "active").await;
    assert_eq!(
        repo.decommission_if_unreferenced(unknown_vm_id, "unknown-vm")
            .await
            .expect("reject unknown vm"),
        VmDecommissionResult::Conflict(VmRetirementConflict::UnknownVm {
            vm_id: unknown_vm_id
        })
    );
    assert_eq!(
        repo.decommission_if_unreferenced(draining_vm_id, "repo-non-active")
            .await
            .expect("reject non-active vm"),
        VmDecommissionResult::Conflict(VmRetirementConflict::InvalidStatus {
            actual_status: "draining".to_string()
        })
    );
}

fn expected_live_reference_blockers() -> Vec<VmRetirementBlocker> {
    let mut blockers = EXPECTED_VM_REFERENCE_COLUMNS
        .iter()
        .map(|(owner, reference_column)| VmRetirementBlocker {
            owner: (*owner).to_string(),
            reference_column: (*reference_column).to_string(),
            count: 1,
        })
        .collect::<Vec<_>>();
    blockers.sort_by(|left, right| {
        (&left.owner, &left.reference_column).cmp(&(&right.owner, &right.reference_column))
    });
    blockers
}

async fn assert_inventory_status(pool: &PgPool, vm_id: Uuid, expected_status: &str) {
    let actual_status: String = sqlx::query_scalar("SELECT status FROM vm_inventory WHERE id = $1")
        .bind(vm_id)
        .fetch_one(pool)
        .await
        .expect("query inventory status");
    assert_eq!(actual_status, expected_status);
}
