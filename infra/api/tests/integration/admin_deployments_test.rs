use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::json;
use std::sync::Arc;
use tokio::time::{sleep, timeout, Duration};
use tower::ServiceExt;
use uuid::Uuid;

use api::repos::{DeploymentRepo, PgDeploymentRepo};
use api::router::build_router;

use crate::common::support::pg_schema_harness::{connect_and_migrate, pool_in_schema};
use crate::common::vm_inventory_reference_guard_fixtures::insert_customer;
use crate::common::{TestStateBuilder, TEST_ADMIN_KEY};

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn admin_deployment_pg_test_app(pool: sqlx::PgPool) -> axum::Router {
    let mut state = TestStateBuilder::new().with_pool(pool.clone()).build();
    state.deployment_repo = Arc::new(PgDeploymentRepo::new(pool));
    build_router(state)
}

async fn post_fail_provisioning(
    app: axum::Router,
    deployment_id: Uuid,
    body: serde_json::Value,
    admin_key: Option<&str>,
) -> axum::response::Response {
    post_fail_provisioning_raw(app, deployment_id, body.to_string(), admin_key).await
}

async fn post_fail_provisioning_raw(
    app: axum::Router,
    deployment_id: Uuid,
    body: String,
    admin_key: Option<&str>,
) -> axum::response::Response {
    let mut builder = Request::builder()
        .method("POST")
        .uri(format!(
            "/admin/deployments/{deployment_id}/fail-provisioning"
        ))
        .header("content-type", "application/json");
    if let Some(admin_key) = admin_key {
        builder = builder.header("x-admin-key", admin_key);
    }
    app.oneshot(builder.body(Body::from(body)).unwrap())
        .await
        .unwrap()
}

#[tokio::test]
async fn fail_provisioning_requires_admin_and_exact_fixed_body() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let customer = customer_repo.seed("Acme Corp", "acme-fail@example.com");
    let deployment = deployment_repo.seed(
        customer.id,
        "node-fail-provisioning",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let success = post_fail_provisioning(
        crate::common::test_app_with_repos(customer_repo.clone(), deployment_repo.clone()),
        deployment.id,
        json!({"reason":"retired_dead_ami_fleet"}),
        Some(TEST_ADMIN_KEY),
    )
    .await;
    assert_eq!(success.status(), StatusCode::OK);
    assert_eq!(
        body_json(success).await,
        json!({
            "id": deployment.id,
            "status": "failed",
            "failure_reason": "retired_dead_ami_fleet"
        })
    );

    let invalid_cases = [
        (
            None,
            json!({"reason":"retired_dead_ami_fleet"}).to_string(),
            StatusCode::UNAUTHORIZED,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({}).to_string(),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"reason":"engine_health_check_failed"}).to_string(),
            StatusCode::BAD_REQUEST,
        ),
        (
            Some(TEST_ADMIN_KEY),
            json!({"reason":"retired_dead_ami_fleet","extra":true}).to_string(),
            StatusCode::UNPROCESSABLE_ENTITY,
        ),
        (
            Some(TEST_ADMIN_KEY),
            "{".to_string(),
            StatusCode::BAD_REQUEST,
        ),
    ];

    for (admin_key, body, expected_status) in invalid_cases {
        let response = post_fail_provisioning_raw(
            crate::common::test_app_with_repos(
                crate::common::mock_repo(),
                crate::common::mock_deployment_repo(),
            ),
            Uuid::new_v4(),
            body,
            admin_key,
        )
        .await;
        assert_eq!(response.status(), expected_status);
    }
}

#[tokio::test]
async fn fail_provisioning_maps_absent_and_non_provisioning_rows() {
    let absent = post_fail_provisioning(
        crate::common::test_app_with_repos(
            crate::common::mock_repo(),
            crate::common::mock_deployment_repo(),
        ),
        Uuid::new_v4(),
        json!({"reason":"retired_dead_ami_fleet"}),
        Some(TEST_ADMIN_KEY),
    )
    .await;
    assert_eq!(absent.status(), StatusCode::NOT_FOUND);

    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let customer = customer_repo.seed("Acme Corp", "acme-running@example.com");
    let deployment = deployment_repo.seed_provisioned(
        customer.id,
        "node-running-fail-reject",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-running.flapjack.foo"),
    );

    let conflict = post_fail_provisioning(
        crate::common::test_app_with_repos(customer_repo, deployment_repo.clone()),
        deployment.id,
        json!({"reason":"retired_dead_ami_fleet"}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(conflict.status(), StatusCode::CONFLICT);
    let after = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(after.status, "running");
    assert_eq!(after.failure_reason, None);
    assert_eq!(after.provider_vm_id, deployment.provider_vm_id);
}

#[tokio::test]
async fn fail_provisioning_postgres_clears_transient_fields() {
    let Some(db) = connect_and_migrate("admin_deployment_fail_provisioning").await else {
        return;
    };
    let customer_id = insert_customer(&db.pool, "admin_deployment_fail").await;
    let repo = PgDeploymentRepo::new(db.pool.clone());
    let deployment = repo
        .create(
            customer_id,
            "node-pg-fail-provisioning",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    sqlx::query(
        "UPDATE customer_deployments
         SET provider_vm_id = 'provisioning-lock:test',
             ip_address = '203.0.113.55',
             hostname = 'vm-pg-fail.flapjack.foo',
             flapjack_url = 'https://vm-pg-fail.flapjack.foo'
         WHERE id = $1",
    )
    .bind(deployment.id)
    .execute(&db.pool)
    .await
    .unwrap();

    let response = post_fail_provisioning(
        admin_deployment_pg_test_app(db.pool.clone()),
        deployment.id,
        json!({"reason":"retired_dead_ami_fleet"}),
        Some(TEST_ADMIN_KEY),
    )
    .await;

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        body_json(response).await,
        json!({
            "id": deployment.id,
            "status": "failed",
            "failure_reason": "retired_dead_ami_fleet"
        })
    );
    let updated = repo.find_by_id(deployment.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    assert_eq!(
        updated.failure_reason.as_deref(),
        Some("retired_dead_ami_fleet")
    );
    assert_eq!(updated.provider_vm_id, None);
    assert_eq!(updated.ip_address, None);
    assert_eq!(updated.hostname, None);
    assert_eq!(updated.flapjack_url, None);
}

#[tokio::test]
async fn fail_provisioning_postgres_race_reports_conflict_without_mutation() {
    let Some(db) = connect_and_migrate("admin_deployment_fail_race").await else {
        return;
    };
    let customer_id = insert_customer(&db.pool, "admin_deployment_fail_race").await;
    let repo = PgDeploymentRepo::new(db.pool.clone());
    let deployment = repo
        .create(
            customer_id,
            "node-pg-fail-race",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    let worker_pool = pool_in_schema(&db.schema, 1).await;
    let route_pool = pool_in_schema(&db.schema, 1).await;
    let mut transition = worker_pool.begin().await.unwrap();
    sqlx::query("UPDATE customer_deployments SET status = 'running' WHERE id = $1")
        .bind(deployment.id)
        .execute(&mut *transition)
        .await
        .unwrap();

    let route_task = tokio::spawn(post_fail_provisioning(
        admin_deployment_pg_test_app(route_pool),
        deployment.id,
        json!({"reason":"retired_dead_ami_fleet"}),
        Some(TEST_ADMIN_KEY),
    ));
    sleep(Duration::from_millis(50)).await;
    transition.commit().await.unwrap();

    let response = timeout(Duration::from_secs(2), route_task)
        .await
        .expect("fail-provisioning route must not deadlock")
        .expect("route task joins");
    assert_eq!(response.status(), StatusCode::CONFLICT);
    let after = repo.find_by_id(deployment.id).await.unwrap().unwrap();
    assert_eq!(after.status, "running");
    assert_eq!(after.failure_reason, None);
}

// ===========================================================================
// POST /admin/tenants/:id/deployments with provision=true
// ===========================================================================

#[tokio::test]
async fn admin_create_with_provision_true_triggers_provisioner() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme Corp", "acme@example.com");
    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-prov-1",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws",
                "provision": true
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    assert_eq!(json["status"], "provisioning");
    // When provision=true, the provisioning_service auto-generates the node_id
    // so the manually-specified "node-prov-1" should be ignored.
    let returned_node_id = json["node_id"].as_str().unwrap();
    assert_ne!(
        returned_node_id, "node-prov-1",
        "provision=true should auto-generate node_id, not use the one from request body"
    );
    assert!(
        returned_node_id.starts_with("node-"),
        "auto-generated node_id should start with 'node-'"
    );
}

// ===========================================================================
// POST /admin/tenants/:id/deployments without provision flag (default behavior)
// ===========================================================================

#[tokio::test]
async fn admin_create_without_provision_flag_works_as_before() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme Corp", "acme@example.com");
    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-manual-1",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws",
                "ip_address": "10.0.1.5"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    // Without provision flag, the manually-specified node_id is preserved
    assert_eq!(json["node_id"], "node-manual-1");
    assert_eq!(json["ip_address"], "10.0.1.5");
    assert_eq!(json["status"], "provisioning");
}

// ===========================================================================
// GET /admin/fleet — returns all active deployments
// ===========================================================================

#[tokio::test]
async fn fleet_endpoint_returns_all_active_deployments() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant_a = customer_repo.seed("Acme", "acme@example.com");
    let tenant_b = customer_repo.seed("Beta", "beta@example.com");

    // Two active deployments with flapjack_url set (different customers)
    deployment_repo.seed_provisioned(
        tenant_a.id,
        "node-a1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-aaaa1111.flapjack.foo"),
    );
    deployment_repo.seed_provisioned(
        tenant_b.id,
        "node-b1",
        "eu-west-1",
        "t4g.medium",
        "aws",
        "running",
        Some("https://vm-bbbb2222.flapjack.foo"),
    );

    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri("/admin/fleet")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2, "both active deployments should be listed");
}

// ===========================================================================
// GET /admin/fleet — excludes terminated deployments
// ===========================================================================

#[tokio::test]
async fn fleet_endpoint_excludes_terminated() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");

    deployment_repo.seed_provisioned(
        tenant.id,
        "node-active",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-aaaa1111.flapjack.foo"),
    );
    deployment_repo.seed_provisioned(
        tenant.id,
        "node-terminated",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
        Some("https://vm-bbbb2222.flapjack.foo"),
    );
    // Provisioning deployment without flapjack_url — also excluded from list_active
    deployment_repo.seed(
        tenant.id,
        "node-provisioning",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri("/admin/fleet")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(
        arr.len(),
        1,
        "only the active deployment with flapjack_url should be listed"
    );
    assert_eq!(arr[0]["node_id"], "node-active");
}

// ===========================================================================
// GET /admin/fleet — requires admin auth
// ===========================================================================

#[tokio::test]
async fn fleet_endpoint_requires_admin_auth() {
    let app = crate::common::test_app_with_repos(
        crate::common::mock_repo(),
        crate::common::mock_deployment_repo(),
    );

    // No admin key header
    let req = Request::builder()
        .uri("/admin/fleet")
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// POST /admin/deployments/:id/health-check — nonexistent deployment returns 404
// ===========================================================================

#[tokio::test]
async fn health_check_nonexistent_deployment_returns_404() {
    let app = crate::common::test_app_with_repos(
        crate::common::mock_repo(),
        crate::common::mock_deployment_repo(),
    );
    let fake_id = uuid::Uuid::new_v4();

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{fake_id}/health-check"))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// POST /admin/deployments/:id/health-check — no flapjack_url returns 400
// ===========================================================================

#[tokio::test]
async fn health_check_deployment_without_flapjack_url_returns_400() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");

    // Deployment still provisioning — no flapjack_url set
    let dep = deployment_repo.seed(
        tenant.id,
        "node-no-url",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{}/health-check", dep.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert!(
        json["error"].as_str().unwrap().contains("flapjack_url"),
        "error message should mention flapjack_url"
    );
}

// ===========================================================================
// POST /admin/deployments/:id/health-check — triggers manual health check
// ===========================================================================

#[tokio::test]
async fn health_check_endpoint_updates_status() {
    let customer_repo = crate::common::mock_repo();
    let deployment_repo = crate::common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");

    // Create a deployment with a flapjack_url pointing to a non-existent host
    // (will be unreachable, so health_status should be set to "unhealthy")
    let dep = deployment_repo.seed_provisioned(
        tenant.id,
        "node-hc",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("http://127.0.0.1:19999"),
    );

    let app = crate::common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{}/health-check", dep.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    // The deployment health check was attempted; since the target is unreachable,
    // status should be "unhealthy"
    assert_eq!(json["health_status"], "unhealthy");
    assert!(json["last_health_check_at"].is_string());
}
