mod common;

use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Duration, NaiveDate, Utc};
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
    assert!(json["last_accessed_at"].is_null());
    assert!(
        json.get("subscription_status").is_none(),
        "subscription_status field must be removed from admin tenant response"
    );
    assert_eq!(json["overdue_invoice_count"], 0);
    // No invoice activity yet → green per the post-subscription contract.
    assert_eq!(json["billing_health"], "green");
    // id should be a valid UUID
    Uuid::parse_str(json["id"].as_str().unwrap()).expect("id should be a UUID");
    // created_at and updated_at should be present
    assert!(json["created_at"].is_string());
    assert!(json["updated_at"].is_string());
    // stripe_customer_id must not be in the response
    assert!(json.get("stripe_customer_id").is_none());
}

/// Regression: a freshly created customer has no invoices, and the response
/// must not perform a fallible invoice-repo read after the create has
/// committed. Forcing `list_by_customer` to error must NOT cause the create
/// to fail — the write succeeded and the client must see 201.
#[tokio::test]
async fn create_tenant_succeeds_when_invoice_repo_read_fails() {
    let repo = common::mock_repo();
    let invoice_repo = common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "Acme", "email": "acme@example.com"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::CREATED,
        "create must not fail on post-commit invoice-repo read"
    );
    let json = body_json(resp).await;
    // A never-billed customer with no overdue invoices is green.
    assert_eq!(json["billing_health"], "green");
}

/// Regression: an update mutation that already committed must not surface
/// an error response just because the post-mutation invoice-signal lookup
/// fails. The handler must prefetch signals before mutating so a repo-read
/// failure short-circuits BEFORE any state change.
#[tokio::test]
async fn update_tenant_invoice_repo_failure_short_circuits_before_mutation() {
    let repo = common::mock_repo();
    let customer = repo.seed("Pre Mutation", "pre_mutation@example.com");
    let invoice_repo = common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = common::TestStateBuilder::new()
        .with_customer_repo(repo.clone())
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(
            serde_json::json!({"name": "Should Not Apply"}).to_string(),
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    // The repo failure surfaces as a 5xx, but critically the customer name
    // must NOT have been mutated since the prefetch failed before update.
    assert!(
        resp.status().is_server_error() || resp.status() == StatusCode::INTERNAL_SERVER_ERROR,
        "invoice-repo failure during update prefetch must surface as a server error"
    );
    let stored = repo
        .find_by_email("pre_mutation@example.com")
        .await
        .unwrap();
    assert_eq!(
        stored.expect("customer must remain present").name,
        "Pre Mutation",
        "update must not have applied any mutation when prefetch failed"
    );
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

/// Stage 7 contract:
/// - `deleted` → grey (regardless of other signals)
/// - `overdue_invoice_count > 0` → red
/// - has_ever_been_billed && !recent_paid_invoice_within_60_days → yellow
/// - otherwise → green
#[tokio::test]
async fn list_tenants_returns_billing_health_from_invoice_signals() {
    let repo = common::mock_repo();
    let invoice_repo = common::mock_invoice_repo();

    let green_never_billed = repo.seed("Green Never Billed", "green_never@example.com");
    let green_recent_paid = repo.seed("Green Recent Paid", "green_recent@example.com");
    let yellow_stale_billing = repo.seed("Yellow Stale", "yellow_stale@example.com");
    let red_overdue = repo.seed("Red Overdue", "red_overdue@example.com");
    let grey_deleted = repo.seed_deleted("Grey Deleted", "grey_deleted@example.com");

    let now = Utc::now();
    let seeded_at = now;
    // Green / never billed: no invoices, no overdue.
    repo.seed_billing_health_inputs(green_never_billed.id, Some(seeded_at), 0);
    // Green / recent paid: paid invoice within the 60-day window.
    repo.seed_billing_health_inputs(green_recent_paid.id, Some(seeded_at), 0);
    invoice_repo.seed_paid(
        green_recent_paid.id,
        NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 3, 31).unwrap(),
        now - Duration::days(10),
    );
    // Yellow / stale billing: paid invoice older than 60 days, no recent paid.
    repo.seed_billing_health_inputs(yellow_stale_billing.id, Some(seeded_at), 0);
    invoice_repo.seed_paid(
        yellow_stale_billing.id,
        NaiveDate::from_ymd_opt(2025, 12, 1).unwrap(),
        NaiveDate::from_ymd_opt(2025, 12, 31).unwrap(),
        now - Duration::days(120),
    );
    // Red / overdue: any positive overdue count classifies as red.
    repo.seed_billing_health_inputs(red_overdue.id, Some(seeded_at), 2);

    let app = common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let tenants = json.as_array().expect("response should be an array");

    let find_tenant = |name: &str| -> &serde_json::Value {
        tenants
            .iter()
            .find(|tenant| tenant["name"] == name)
            .unwrap_or_else(|| panic!("tenant '{name}' should be present"))
    };

    assert_eq!(find_tenant("Green Never Billed")["billing_health"], "green");
    assert_eq!(find_tenant("Green Recent Paid")["billing_health"], "green");
    assert_eq!(find_tenant("Yellow Stale")["billing_health"], "yellow");
    assert_eq!(find_tenant("Red Overdue")["billing_health"], "red");
    assert_eq!(find_tenant("Grey Deleted")["billing_health"], "grey");

    let _ = grey_deleted;
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
    let expected_last_accessed_at = Utc::now();
    // Customer with overdue invoices → Red per the post-subscription contract.
    repo.seed_billing_health_inputs(customer.id, Some(expected_last_accessed_at), 3);
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
    let observed_last_accessed_at: DateTime<Utc> = json["last_accessed_at"]
        .as_str()
        .expect("last_accessed_at should be serialized")
        .parse()
        .expect("last_accessed_at should parse as RFC3339");
    assert_eq!(observed_last_accessed_at, expected_last_accessed_at);
    assert!(
        json.get("subscription_status").is_none(),
        "subscription_status field must be removed from admin tenant response"
    );
    assert_eq!(json["overdue_invoice_count"], 3);
    assert_eq!(json["billing_health"], "red");
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

/// Regression: duplicate-email conflicts must retain 409 precedence even when
/// invoice signal lookup is unavailable. The invoice-repo read must not mask
/// the existing customer-repo conflict path with a 5xx.
#[tokio::test]
async fn update_tenant_duplicate_email_stays_409_when_invoice_lookup_fails() {
    let repo = common::mock_repo();
    let _tenant_a = repo.seed("Tenant A", "a@example.com");
    let tenant_b = repo.seed("Tenant B", "b@example.com");
    let invoice_repo = common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

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
    assert_eq!(
        resp.status(),
        StatusCode::CONFLICT,
        "duplicate-email updates must keep 409 precedence over invoice lookup failures"
    );
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
async fn update_tenant_not_found_stays_404_when_invoice_lookup_fails() {
    let repo = common::mock_repo();
    let invoice_repo = common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::json!({"name": "Nope"}).to_string()))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::NOT_FOUND,
        "missing-tenant update must keep 404 precedence over invoice lookup errors"
    );

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
    assert_eq!(arr[1]["billing_health"], "grey");
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
