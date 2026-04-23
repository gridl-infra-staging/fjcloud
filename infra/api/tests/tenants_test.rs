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
// POST /admin/tenants — create
// ===========================================================================

#[tokio::test]
async fn create_tenant_returns_201() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "Acme Corp", "email": "admin@acme.com"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CREATED);

    let json = body_json(resp).await;
    assert_eq!(json["name"], "Acme Corp");
    assert_eq!(json["email"], "admin@acme.com");
    assert_eq!(json["status"], "active");
    // id should be a valid UUID
    Uuid::parse_str(json["id"].as_str().unwrap()).expect("id should be a UUID");
    // created_at and updated_at should be present
    assert!(json["created_at"].is_string());
    assert!(json["updated_at"].is_string());
    // stripe_customer_id must not be in the response
    assert!(json.get("stripe_customer_id").is_none());
}

#[tokio::test]
async fn create_tenant_duplicate_email_returns_409() {
    let repo = common::mock_repo();
    repo.seed("Existing Tenant", "dupe@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "New Tenant", "email": "dupe@example.com"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "email already exists");
}

#[tokio::test]
async fn create_tenant_missing_auth_returns_401() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "Acme", "email": "a@b.com"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// GET /admin/tenants — list
// ===========================================================================

#[tokio::test]
async fn list_tenants_returns_200_with_data() {
    let repo = common::mock_repo();
    repo.seed("Tenant A", "a@example.com");
    repo.seed("Tenant B", "b@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
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
async fn list_tenants_empty_returns_200_with_empty_array() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert!(arr.is_empty());
}

// ===========================================================================
// GET /admin/tenants/:id — get
// ===========================================================================

#[tokio::test]
async fn get_tenant_returns_200() {
    let repo = common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["id"], customer.id.to_string());
    assert_eq!(json["name"], "Acme");
    assert_eq!(json["email"], "acme@example.com");
}

#[tokio::test]
async fn get_tenant_not_found_returns_404() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "tenant not found");
}

// ===========================================================================
// PUT /admin/tenants/:id — update
// ===========================================================================

#[tokio::test]
async fn update_tenant_returns_200() {
    let repo = common::mock_repo();
    let customer = repo.seed("Old Name", "old@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "New Name"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["name"], "New Name");
    assert_eq!(json["email"], "old@example.com"); // unchanged
}

#[tokio::test]
async fn update_tenant_with_only_unknown_fields_returns_400() {
    let repo = common::mock_repo();
    let customer = repo.seed("Mode Co", "mode@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"nonexistent_field": "value"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "no fields to update");
}

#[tokio::test]
async fn update_tenant_duplicate_email_returns_409() {
    let repo = common::mock_repo();
    let _tenant_a = repo.seed("Tenant A", "a@example.com");
    let tenant_b = repo.seed("Tenant B", "b@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", tenant_b.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"email": "a@example.com"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn update_tenant_not_found_returns_404() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::json!({"name": "Nope"}).to_string()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "tenant not found");
}

#[tokio::test]
async fn update_tenant_empty_body_returns_400() {
    let repo = common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "no fields to update");
}

// ===========================================================================
// GET /admin/tenants — list: deleted tenants remain visible for status filters
// ===========================================================================

#[tokio::test]
async fn list_tenants_includes_deleted() {
    let repo = common::mock_repo();
    repo.seed("Active Corp", "active@example.com");
    repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(
        arr.len(),
        2,
        "deleted tenant should remain available for admin filtering"
    );
    assert_eq!(arr[0]["name"], "Active Corp");
    assert_eq!(arr[1]["name"], "Gone Corp");
    assert_eq!(arr[1]["status"], "deleted");
}

// ===========================================================================
// GET /admin/tenants/:id — deleted tenant: admin can still view for audit
// ===========================================================================

#[tokio::test]
async fn get_tenant_returns_200_for_deleted_tenant() {
    // Intentional: admin can always look up a deleted tenant by ID for audit purposes.
    // Operational endpoints (usage, invoices, deployments, rate-card) all return 404 for
    // deleted tenants. Only this GET-by-ID endpoint exposes the record (with status="deleted").
    let repo = common::mock_repo();
    let deleted = repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", deleted.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["id"], deleted.id.to_string());
    assert_eq!(json["status"], "deleted");
}

// ===========================================================================
// PUT /admin/tenants/:id — deleted tenant must return 404
// ===========================================================================

#[tokio::test]
async fn update_tenant_deleted_returns_404() {
    let repo = common::mock_repo();
    let deleted = repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", deleted.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "New Name"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// DELETE /admin/tenants/:id — soft-delete
// ===========================================================================

#[tokio::test]
async fn delete_tenant_returns_204() {
    let repo = common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
async fn delete_tenant_not_found_returns_404() {
    let repo = common::mock_repo();
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_tenant_already_deleted_returns_404() {
    let repo = common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = common::test_app_with_repo(repo.clone());

    // First delete — 204
    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    // Second delete — 404
    let app2 = common::test_app_with_repo(repo);
    let req2 = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp2 = app2.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// PUT /admin/tenants/:id — billing_plan update
// ===========================================================================

#[tokio::test]
async fn update_tenant_billing_plan_returns_200() {
    let repo = common::mock_repo();
    let customer = repo.seed("Plan Corp", "plan@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"billing_plan": "shared"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["billing_plan"], "shared");
}

#[tokio::test]
async fn update_tenant_invalid_billing_plan_returns_400() {
    let repo = common::mock_repo();
    let customer = repo.seed("Bad Plan Corp", "badplan@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"billing_plan": "nonexistent_plan"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn update_tenant_billing_plan_with_name_returns_200() {
    let repo = common::mock_repo();
    let customer = repo.seed("Combo Corp", "combo@example.com");
    let app = common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "Updated Corp", "billing_plan": "shared"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    assert_eq!(json["name"], "Updated Corp");
    assert_eq!(json["billing_plan"], "shared");
}
