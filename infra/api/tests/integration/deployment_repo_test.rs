use chrono::Utc;
use std::sync::Arc;
use uuid::Uuid;

use api::models::Deployment;
use api::repos::{DeploymentRepo, PgDeploymentRepo};

fn setup() -> Arc<crate::common::MockDeploymentRepo> {
    crate::common::mock_deployment_repo()
}

#[test]
fn pg_deployment_bulk_lookup_is_single_any_query() {
    let source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_deployment_repo.rs"),
    )
    .expect("read pg_deployment_repo source");
    let body = crate::common::source_assertions::function_body(&source, "find_by_ids")
        .expect("PgDeploymentRepo must implement find_by_ids");

    assert!(
        body.contains("ANY($1)"),
        "PgDeploymentRepo::find_by_ids must use a single PostgreSQL ANY($1) lookup"
    );
    assert_eq!(
        body.matches("sqlx::query_as::<_, Deployment>").count(),
        1,
        "PgDeploymentRepo::find_by_ids must construct exactly one Deployment query"
    );
    assert!(
        !body.contains("find_by_id"),
        "PgDeploymentRepo::find_by_ids must not fan out through find_by_id"
    );
}

#[tokio::test]
async fn pg_deployment_bulk_lookup_matches_any_status_find_semantics() {
    let Some(db) =
        crate::common::support::pg_schema_harness::connect_and_migrate("deployment_bulk_lookup")
            .await
    else {
        return;
    };
    let repo = PgDeploymentRepo::new(db.pool.clone());
    let customer_id = Uuid::new_v4();
    let running_id = Uuid::new_v4();
    let terminated_id = Uuid::new_v4();
    let no_url_id = Uuid::new_v4();
    let missing_id = Uuid::new_v4();

    crate::common::support::pg_schema_harness::insert_active_customer(&db.pool, customer_id, 1)
        .await;
    insert_deployment_row(
        &db.pool,
        running_id,
        customer_id,
        "deployment-bulk-running",
        "running",
        Some("http://deployment-bulk-running:7700"),
        "healthy",
    )
    .await;
    insert_deployment_row(
        &db.pool,
        terminated_id,
        customer_id,
        "deployment-bulk-terminated",
        "terminated",
        Some("http://deployment-bulk-terminated:7700"),
        "unhealthy",
    )
    .await;
    insert_deployment_row(
        &db.pool,
        no_url_id,
        customer_id,
        "deployment-bulk-no-url",
        "running",
        None,
        "unknown",
    )
    .await;

    let ids = [running_id, terminated_id, no_url_id, missing_id];
    let bulk = repo.find_by_ids(&ids).await.unwrap();
    let mut per_id = Vec::new();
    for id in ids {
        if let Some(deployment) = repo.find_by_id(id).await.unwrap() {
            per_id.push(deployment);
        }
    }

    assert_eq!(
        deployment_rows_by_stable_values(bulk),
        deployment_rows_by_stable_values(per_id)
    );
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
    assert_eq!(updated.status, "running");
    assert_eq!(updated.failure_reason, None);
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

#[tokio::test]
async fn ordinary_failed_provisioning_has_null_failure_reason_engine_health() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo
        .create(
            cid,
            "node-ordinary-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    let marked = repo.mark_failed_provisioning(dep.id, None).await.unwrap();
    let updated = repo.find_by_id(dep.id).await.unwrap().unwrap();

    assert!(
        marked,
        "ordinary provisioning failure must transition while still provisioning"
    );
    assert_eq!(updated.status, "failed");
    assert_eq!(
        updated.failure_reason, None,
        "ordinary provisioning failures must leave failure_reason NULL"
    );
    assert!(updated.provider_vm_id.is_none());
    assert!(updated.ip_address.is_none());
    assert!(updated.hostname.is_none());
    assert!(updated.flapjack_url.is_none());
}

#[tokio::test]
async fn mark_failed_provisioning_stores_engine_health_reason_and_preserves_guard() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed_provisioned(
        cid,
        "node-engine-health-fail",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
        Some("https://vm-engine-health.flapjack.foo"),
    );

    let marked = repo
        .mark_failed_provisioning(dep.id, Some("engine_health_check_failed"))
        .await
        .unwrap();
    let updated = repo.find_by_id(dep.id).await.unwrap().unwrap();
    let rejected = repo
        .mark_failed_provisioning(dep.id, Some("later_reason_must_not_overwrite"))
        .await
        .unwrap();
    let after_rejected = repo.find_by_id(dep.id).await.unwrap().unwrap();

    assert!(
        marked,
        "engine-health provisioning failure must transition while still provisioning"
    );
    assert_eq!(updated.status, "failed");
    assert_eq!(
        updated.failure_reason.as_deref(),
        Some("engine_health_check_failed")
    );
    assert!(updated.provider_vm_id.is_none());
    assert!(updated.ip_address.is_none());
    assert!(updated.hostname.is_none());
    assert!(updated.flapjack_url.is_none());
    assert!(
        !rejected,
        "second mark_failed_provisioning call must be rejected after leaving provisioning"
    );
    assert_eq!(
        after_rejected.failure_reason.as_deref(),
        Some("engine_health_check_failed"),
        "rejected transition must not overwrite the first failure_reason"
    );
}

#[tokio::test]
async fn mark_failed_provisioning_accepts_engine_health_failure_reason_contract() {
    let repo_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/deployment_repo.rs"),
    )
    .expect("read deployment_repo source");
    let pg_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_deployment_repo.rs"),
    )
    .expect("read pg_deployment_repo source");
    let repo_signature_start = repo_source
        .find("mark_failed_provisioning")
        .expect("DeploymentRepo must keep mark_failed_provisioning as the canonical failure owner");
    let repo_signature_end = repo_source[repo_signature_start..]
        .find(';')
        .expect("DeploymentRepo mark_failed_provisioning signature must be a trait declaration")
        + repo_signature_start;
    let repo_signature = &repo_source[repo_signature_start..repo_signature_end];
    let pg_body =
        crate::common::source_assertions::function_body(&pg_source, "mark_failed_provisioning")
            .expect("PgDeploymentRepo must implement mark_failed_provisioning");

    assert!(
        repo_signature.contains("failure_reason") && repo_signature.contains("Option<&str>"),
        "DeploymentRepo failure path must accept a failure_reason without adding a parallel helper"
    );
    assert!(
        pg_body.contains("failure_reason = $2"),
        "PgDeploymentRepo must persist failure_reason in the canonical failed-provisioning update"
    );
    assert!(
        pg_body.contains(".bind(failure_reason)"),
        "PgDeploymentRepo must bind failure_reason as the second parameter"
    );
}

#[tokio::test]
async fn update_clears_failure_reason_when_status_leaves_failed() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed_with_failure_reason(
        cid,
        "node-failed-recovery",
        "us-east-1",
        "t4g.small",
        "aws",
        "failed",
        "engine_health_check_failed",
    );
    let pg_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_deployment_repo.rs"),
    )
    .expect("read pg_deployment_repo source");
    let pg_body = crate::common::source_assertions::function_body(&pg_source, "update")
        .expect("PgDeploymentRepo must implement update");

    let updated = repo
        .update(dep.id, None, Some("running"))
        .await
        .unwrap()
        .expect("update should return the recovered deployment");

    assert_eq!(updated.status, "running");
    assert_eq!(
        updated.failure_reason, None,
        "recovering a deployment must clear stale failed-provisioning failure_reason"
    );
    assert!(
        pg_body.contains("WHEN $3 IS NOT NULL AND $3 != 'failed' THEN NULL"),
        "PgDeploymentRepo::update must clear failure_reason when status leaves failed"
    );
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
async fn terminate_clears_failure_reason_when_status_leaves_failed() {
    let repo = setup();
    let cid = Uuid::new_v4();
    let dep = repo.seed_with_failure_reason(
        cid,
        "node-failed-terminate",
        "us-east-1",
        "t4g.small",
        "aws",
        "failed",
        "engine_health_check_failed",
    );
    let pg_source = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/repos/pg_deployment_repo.rs"),
    )
    .expect("read pg_deployment_repo source");
    let pg_body = crate::common::source_assertions::function_body(&pg_source, "terminate")
        .expect("PgDeploymentRepo must implement terminate");

    let result = repo.terminate(dep.id).await.unwrap();

    assert!(
        result,
        "terminate should return true for failed non-terminated deployment"
    );
    let found = repo.find_by_id(dep.id).await.unwrap().unwrap();
    assert_eq!(found.status, "terminated");
    assert!(found.terminated_at.is_some());
    assert_eq!(
        found.failure_reason, None,
        "terminating a failed deployment must clear stale failed-provisioning failure_reason"
    );
    assert!(
        pg_body.contains("failure_reason = NULL"),
        "PgDeploymentRepo::terminate must clear failure_reason when status leaves failed"
    );
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

async fn insert_deployment_row(
    pool: &sqlx::PgPool,
    id: Uuid,
    customer_id: Uuid,
    node_id: &str,
    status: &str,
    flapjack_url: Option<&str>,
    health_status: &str,
) {
    sqlx::query(
        "INSERT INTO customer_deployments \
         (id, customer_id, node_id, region, vm_type, vm_provider, status, flapjack_url, \
          health_status, terminated_at) \
         VALUES ($1, $2, $3, 'us-east-1', 'shared', 'aws', $4, $5, $6, \
                 CASE WHEN $4 = 'terminated' THEN NOW() ELSE NULL END)",
    )
    .bind(id)
    .bind(customer_id)
    .bind(node_id)
    .bind(status)
    .bind(flapjack_url)
    .bind(health_status)
    .execute(pool)
    .await
    .expect("insert deployment row");
}

fn deployment_rows_by_stable_values(
    mut deployments: Vec<Deployment>,
) -> Vec<(Uuid, String, String, Option<String>, String)> {
    let mut rows = deployments
        .drain(..)
        .map(|deployment| {
            (
                deployment.id,
                deployment.node_id,
                deployment.status,
                deployment.flapjack_url,
                deployment.health_status,
            )
        })
        .collect::<Vec<_>>();
    rows.sort();
    rows
}
