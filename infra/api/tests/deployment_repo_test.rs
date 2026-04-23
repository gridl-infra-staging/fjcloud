mod common;

use chrono::Utc;
use std::sync::Arc;
use uuid::Uuid;

use api::repos::DeploymentRepo;

fn setup() -> Arc<common::MockDeploymentRepo> {
    common::mock_deployment_repo()
}

// ===========================================================================
// list_active: returns non-terminated deployments with flapjack_url set
// ===========================================================================

#[tokio::test]
async fn list_active_returns_running_with_flapjack_url() {
    let repo = setup();
    let cid = Uuid::new_v4();

    // Running deployment WITH flapjack_url — should be included
    repo.seed_provisioned(
        cid,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-abcd1234.flapjack.foo"),
    );
    // Running deployment WITHOUT flapjack_url — should be excluded (still provisioning)
    repo.seed(cid, "node-2", "us-east-1", "t4g.small", "aws", "running");
    // Terminated deployment WITH flapjack_url — should be excluded
    repo.seed_provisioned(
        cid,
        "node-3",
        "eu-west-1",
        "t4g.small",
        "aws",
        "terminated",
        Some("https://vm-dead1234.flapjack.foo"),
    );

    let active = repo.list_active().await.unwrap();
    assert_eq!(active.len(), 1);
    assert_eq!(active[0].node_id, "node-1");
}

#[tokio::test]
async fn list_active_excludes_provisioning_without_url() {
    let repo = setup();
    let cid = Uuid::new_v4();

    // Provisioning deployment without flapjack_url — not ready for health checks
    repo.seed(
        cid,
        "node-new",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let active = repo.list_active().await.unwrap();
    assert!(
        active.is_empty(),
        "provisioning VMs without flapjack_url should not appear in list_active"
    );
}

// ===========================================================================
// update_health: sets health_status and last_health_check_at
// ===========================================================================

#[tokio::test]
async fn update_health_sets_fields() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed_provisioned(
        cid,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-abcd1234.flapjack.foo"),
    );

    let now = Utc::now();
    repo.update_health(dep.id, "healthy", now).await.unwrap();

    let updated = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(updated.health_status, "healthy");
    assert!(updated.last_health_check_at.is_some());
}

// ===========================================================================
// update_provisioning: batch-updates provider_vm_id, ip_address, hostname, flapjack_url
// ===========================================================================

#[tokio::test]
async fn update_provisioning_sets_all_fields() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed(
        cid,
        "node-prov",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let result = repo
        .update_provisioning(
            dep.id,
            "i-0abc123def",
            "203.0.113.42",
            "vm-abcd1234.flapjack.foo",
            "https://vm-abcd1234.flapjack.foo",
        )
        .await
        .unwrap();

    let updated = result.expect("update_provisioning should return the updated deployment");
    assert_eq!(updated.provider_vm_id.as_deref(), Some("i-0abc123def"));
    assert_eq!(updated.ip_address.as_deref(), Some("203.0.113.42"));
    assert_eq!(
        updated.hostname.as_deref(),
        Some("vm-abcd1234.flapjack.foo")
    );
    assert_eq!(
        updated.flapjack_url.as_deref(),
        Some("https://vm-abcd1234.flapjack.foo")
    );
}

#[tokio::test]
async fn update_provisioning_nonexistent_returns_none() {
    let repo = setup();

    let result = repo
        .update_provisioning(
            Uuid::new_v4(),
            "i-0abc",
            "1.2.3.4",
            "vm-xxxx.flapjack.foo",
            "https://vm-xxxx.flapjack.foo",
        )
        .await
        .unwrap();

    assert!(result.is_none());
}

// ===========================================================================
// new columns round-trip through create/find
// ===========================================================================

#[tokio::test]
async fn new_columns_default_correctly_on_create_find() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let created = repo.seed(
        cid,
        "node-rt",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let found = repo.find_by_id(created.id).await.unwrap().unwrap();

    assert!(
        found.provider_vm_id.is_none(),
        "provider_vm_id should default to None"
    );
    assert!(found.hostname.is_none(), "hostname should default to None");
    assert!(
        found.flapjack_url.is_none(),
        "flapjack_url should default to None"
    );
    assert!(
        found.last_health_check_at.is_none(),
        "last_health_check_at should default to None"
    );
    assert_eq!(
        found.health_status, "unknown",
        "health_status should default to 'unknown'"
    );
}

// ===========================================================================
// update_health on nonexistent deployment returns error
// ===========================================================================

#[tokio::test]
async fn update_health_nonexistent_returns_error() {
    let repo = setup();

    let result = repo
        .update_health(Uuid::new_v4(), "healthy", Utc::now())
        .await;
    assert!(
        result.is_err(),
        "update_health on nonexistent deployment should return error"
    );
}

// ===========================================================================
// terminated deployments have terminated_at set (data integrity)
// ===========================================================================

#[tokio::test]
async fn terminated_deployment_has_terminated_at_set() {
    let repo = setup();
    let cid = Uuid::new_v4();

    // seed_provisioned with status "terminated" must set terminated_at
    let dep = repo.seed_provisioned(
        cid,
        "node-dead",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
        Some("https://vm-dead.flapjack.foo"),
    );
    assert!(
        dep.terminated_at.is_some(),
        "terminated deployment must have terminated_at set"
    );

    // seed() with status "terminated" must also set terminated_at
    let dep2 = repo.seed(
        cid,
        "node-dead2",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
    );
    assert!(
        dep2.terminated_at.is_some(),
        "terminated deployment must have terminated_at set"
    );

    // Running deployment must NOT have terminated_at
    let dep3 = repo.seed(cid, "node-live", "us-east-1", "t4g.small", "aws", "running");
    assert!(
        dep3.terminated_at.is_none(),
        "running deployment must not have terminated_at"
    );
}

// ===========================================================================
// list_active excludes failed deployments (even if flapjack_url is set)
// ===========================================================================

#[tokio::test]
async fn list_active_includes_failed_with_flapjack_url() {
    let repo = setup();
    let cid = Uuid::new_v4();

    // A failed deployment might have a partial flapjack_url if provisioning failed after DNS setup.
    // list_active only excludes "terminated" — failed deployments with a URL are included
    // so the health monitor can detect if they come back up.
    repo.seed_provisioned(
        cid,
        "node-fail",
        "us-east-1",
        "t4g.small",
        "aws",
        "failed",
        Some("https://vm-fail.flapjack.foo"),
    );

    let active = repo.list_active().await.unwrap();
    assert_eq!(
        active.len(),
        1,
        "failed deployments with flapjack_url should be in list_active"
    );
    assert_eq!(active[0].status, "failed");
}

// ===========================================================================
// update_health transitions: unknown → healthy → unhealthy round-trip
// ===========================================================================

#[tokio::test]
async fn update_health_transitions_round_trip() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed_provisioned(
        cid,
        "node-health-rt",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-hlth.flapjack.foo"),
    );

    // Default is "unknown"
    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.health_status, "unknown");

    // Transition to "healthy"
    let t1 = Utc::now();
    repo.update_health(dep.id, "healthy", t1).await.unwrap();
    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.health_status, "healthy");
    assert!(found.last_health_check_at.is_some());

    // Transition to "unhealthy"
    let t2 = Utc::now();
    repo.update_health(dep.id, "unhealthy", t2).await.unwrap();
    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.health_status, "unhealthy");

    // Recover back to "healthy"
    let t3 = Utc::now();
    repo.update_health(dep.id, "healthy", t3).await.unwrap();
    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.health_status, "healthy");
}

// ===========================================================================
// list_by_customer respects include_terminated flag
// ===========================================================================

#[tokio::test]
async fn list_by_customer_excludes_terminated_by_default() {
    let repo = setup();
    let cid = Uuid::new_v4();

    repo.seed(
        cid,
        "node-active",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    repo.seed(
        cid,
        "node-term",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
    );

    let non_terminated = repo.list_by_customer(cid, false).await.unwrap();
    assert_eq!(non_terminated.len(), 1);
    assert_eq!(non_terminated[0].node_id, "node-active");

    let all = repo.list_by_customer(cid, true).await.unwrap();
    assert_eq!(all.len(), 2);
}

// ===========================================================================
// list_active includes stopped deployments with flapjack_url
// ===========================================================================

#[tokio::test]
async fn list_active_includes_stopped_with_flapjack_url() {
    let repo = setup();
    let cid = Uuid::new_v4();

    // Stopped deployment WITH flapjack_url — should be included (still valid for health checks)
    repo.seed_provisioned(
        cid,
        "node-stopped",
        "us-east-1",
        "t4g.small",
        "aws",
        "stopped",
        Some("https://vm-stop1234.flapjack.foo"),
    );

    let active = repo.list_active().await.unwrap();
    assert_eq!(
        active.len(),
        1,
        "stopped deployments with flapjack_url should be in list_active"
    );
    assert_eq!(active[0].node_id, "node-stopped");
}

// ===========================================================================
// terminate via repo sets terminated_at and status
// ===========================================================================

#[tokio::test]
async fn terminate_sets_status_and_terminated_at() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed(
        cid,
        "node-to-term",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );

    assert!(dep.terminated_at.is_none());

    let result = repo.terminate(dep.id).await.unwrap();
    assert!(result, "terminate should return true for active deployment");

    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.status, "terminated");
    assert!(found.terminated_at.is_some());
}

#[tokio::test]
async fn terminate_already_terminated_returns_false() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed(
        cid,
        "node-already",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
    );

    let result = repo.terminate(dep.id).await.unwrap();
    assert!(
        !result,
        "terminate on already-terminated should return false"
    );
}

#[tokio::test]
async fn terminate_nonexistent_returns_false() {
    let repo = setup();

    let result = repo.terminate(Uuid::new_v4()).await.unwrap();
    assert!(!result, "terminate on nonexistent should return false");
}
