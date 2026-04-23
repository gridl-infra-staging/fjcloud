mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

// ===========================================================================
// POST /admin/tenants/:id/deployments with provision=true
// ===========================================================================

#[tokio::test]
async fn admin_create_with_provision_true_triggers_provisioner() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme Corp", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme Corp", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
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

    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri("/admin/fleet")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
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

    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri("/admin/fleet")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let app = common::test_app_with_repos(common::mock_repo(), common::mock_deployment_repo());

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
    let app = common::test_app_with_repos(common::mock_repo(), common::mock_deployment_repo());
    let fake_id = uuid::Uuid::new_v4();

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{fake_id}/health-check"))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
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

    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{}/health-check", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
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

    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/deployments/{}/health-check", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
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
