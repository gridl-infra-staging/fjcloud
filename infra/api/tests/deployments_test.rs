mod common;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

// ===========================================================================
// POST /admin/tenants/:id/deployments — create
// ===========================================================================

#[tokio::test]
async fn create_deployment_returns_201() {
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
                "node_id": "node-acme-us-1",
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
    Uuid::parse_str(json["id"].as_str().unwrap()).expect("id should be a UUID");
    assert_eq!(json["customer_id"], tenant.id.to_string());
    assert_eq!(json["node_id"], "node-acme-us-1");
    assert_eq!(json["region"], "us-east-1");
    assert_eq!(json["vm_type"], "t4g.small");
    assert_eq!(json["vm_provider"], "aws");
    assert_eq!(json["ip_address"], "10.0.1.5");
    assert_eq!(json["status"], "provisioning");
    assert!(json["created_at"].is_string());
    assert!(json["terminated_at"].is_null());
}

#[tokio::test]
async fn create_deployment_unknown_tenant_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-1",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "customer not found");
}

#[tokio::test]
async fn create_deployment_duplicate_node_id_returns_409() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    deployment_repo.seed(
        tenant.id,
        "node-dup",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-dup",
                "region": "eu-west-1",
                "vm_type": "t4g.medium",
                "vm_provider": "aws"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "node_id already exists");
}

#[tokio::test]
async fn create_deployment_invalid_vm_provider_returns_400() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-1",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "digitalocean"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_deployment_missing_auth_returns_401() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-1",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// GET /admin/tenants/:id/deployments — list
// ===========================================================================

#[tokio::test]
async fn list_deployments_returns_200_excludes_terminated() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    deployment_repo.seed(
        tenant.id,
        "node-active",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    deployment_repo.seed(
        tenant.id,
        "node-term",
        "eu-west-1",
        "t4g.medium",
        "hetzner",
        "terminated",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 1);
    assert_eq!(arr[0]["node_id"], "node-active");
}

#[tokio::test]
async fn list_deployments_include_terminated() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    deployment_repo.seed(
        tenant.id,
        "node-active",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    deployment_repo.seed(
        tenant.id,
        "node-term",
        "eu-west-1",
        "t4g.medium",
        "hetzner",
        "terminated",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!(
            "/admin/tenants/{}/deployments?include_terminated=true",
            tenant.id
        ))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2);
}

#[tokio::test]
async fn list_deployments_empty_returns_200_with_empty_array() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert!(arr.is_empty());
}

#[tokio::test]
async fn list_deployments_unknown_tenant_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}/deployments", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// PUT /admin/deployments/:id — update
// ===========================================================================

#[tokio::test]
async fn update_deployment_returns_200() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"status": "running"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["status"], "running");
    assert_eq!(json["node_id"], "node-1");
}

#[tokio::test]
async fn update_deployment_empty_body_returns_400() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "no fields to update");
}

#[tokio::test]
async fn update_deployment_invalid_status_returns_400() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"status": "exploded"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn update_deployment_not_found_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"status": "running"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// DELETE /admin/deployments/:id — terminate
// ===========================================================================

#[tokio::test]
async fn terminate_deployment_returns_204() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn terminate_deployment_not_found_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/deployments/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn terminate_deployment_already_terminated_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let app = common::test_app_with_repos(customer_repo.clone(), deployment_repo.clone());

    // First terminate — 204
    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Second terminate — 404
    let app2 = common::test_app_with_repos(customer_repo, deployment_repo);
    let req2 = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp2 = app2.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// MT-11: list deployments 404 for deleted tenant
// ===========================================================================

#[tokio::test]
async fn list_deployments_deleted_tenant_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}/deployments", deleted.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// MT-12: create deployment 404 for deleted tenant
// ===========================================================================

#[tokio::test]
async fn create_deployment_deleted_tenant_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", deleted.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-x",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// MT-04: PUT deployment with status="terminated" must return 400 (not allowed via PUT)
// ===========================================================================

#[tokio::test]
async fn update_deployment_cannot_set_status_terminated() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"status": "terminated"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // "terminated" is not in VALID_STATUSES for PUT — must use DELETE instead
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert!(
        json["error"].as_str().unwrap().contains("invalid status"),
        "error message must mention invalid status"
    );
}

// ===========================================================================
// Deployment response includes new Stage 4 provisioning/health fields
// ===========================================================================

#[tokio::test]
async fn create_deployment_response_includes_health_status() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "node_id": "node-new",
                "region": "us-east-1",
                "vm_type": "t4g.small",
                "vm_provider": "aws"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    // New fields from migration 009 must be present in the response
    assert_eq!(
        json["health_status"], "unknown",
        "new deployments default to health_status=unknown"
    );
    assert!(
        json["provider_vm_id"].is_null(),
        "provider_vm_id should be null initially"
    );
    assert!(
        json["hostname"].is_null(),
        "hostname should be null initially"
    );
    assert!(
        json["flapjack_url"].is_null(),
        "flapjack_url should be null initially"
    );
    assert!(
        json["last_health_check_at"].is_null(),
        "last_health_check_at should be null initially"
    );
}

// ===========================================================================
// GET /admin/tenants/:id/deployments — provisioned fields in response
// ===========================================================================

#[tokio::test]
async fn list_deployments_shows_provisioned_fields() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    deployment_repo.seed_provisioned(
        tenant.id,
        "node-prov",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-abcd1234.flapjack.foo"),
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}/deployments", tenant.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().unwrap();
    assert_eq!(arr.len(), 1);

    let dep = &arr[0];
    assert!(
        dep["provider_vm_id"].is_string(),
        "provider_vm_id should be populated"
    );
    assert!(dep["hostname"].is_string(), "hostname should be populated");
    assert_eq!(dep["flapjack_url"], "https://vm-abcd1234.flapjack.foo");
    assert_eq!(dep["health_status"], "unknown");
    assert!(dep["last_health_check_at"].is_null());
}

// ===========================================================================
// PUT /admin/deployments/:id — "failed" is a valid status
// ===========================================================================

#[tokio::test]
async fn update_deployment_status_failed_returns_200() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let tenant = customer_repo.seed("Acme", "acme@example.com");
    let dep = deployment_repo.seed(
        tenant.id,
        "node-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/deployments/{}", dep.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"status": "failed"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "admin should be able to set status=failed"
    );

    let json = body_json(resp).await;
    assert_eq!(json["status"], "failed");
}

// ===========================================================================
// seed_index 404 for deleted tenant (security gap fix)
// ===========================================================================

#[tokio::test]
async fn seed_index_deleted_tenant_returns_404() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .method("POST")
        .uri(format!("/admin/tenants/{}/indexes", deleted.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({
                "name": "test-index",
                "region": "us-east-1"
            })
            .to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}
