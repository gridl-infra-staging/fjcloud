use api::repos::{CustomerRepo, TenantRepo};
use api::services::audit_log::ACTION_CUSTOMER_SUSPENDED;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Duration, NaiveDate, Utc};
use http_body_util::BodyExt;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_audit_test_support::{
    app_with_pg_customer_repo, audit_row_count_for_action_and_nullable_target,
    audit_rows_for_action_and_nullable_target, connect_isolated_and_migrate,
    create_active_customer, customer_status, install_scoped_audit_failure_trigger,
    register_operator, response_json,
};

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn tenant_id_name_status_rows(json: &serde_json::Value) -> Vec<(String, String, String)> {
    json.as_array()
        .expect("tenant response should be an array")
        .iter()
        .map(|tenant| {
            (
                tenant["id"].as_str().unwrap().to_string(),
                tenant["name"].as_str().unwrap().to_string(),
                tenant["status"].as_str().unwrap().to_string(),
            )
        })
        .collect()
}

fn assert_customer_identity_and_non_lifecycle_fields_unchanged(
    before: &api::models::Customer,
    after: &api::models::Customer,
) {
    assert_eq!(after.id, before.id);
    assert_eq!(after.name, before.name);
    assert_eq!(after.email, before.email);
    assert_eq!(after.billing_plan, before.billing_plan);
    assert_eq!(after.created_at, before.created_at);
}

// ===========================================================================
// POST /admin/tenants — create
// ===========================================================================

#[tokio::test]
async fn create_tenant_returns_201() {
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Pre Mutation", "pre_mutation@example.com");
    let invoice_repo = crate::common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(repo.clone())
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    repo.seed("Existing Tenant", "dupe@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("POST")
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

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
    let repo = crate::common::mock_repo();
    repo.seed("Tenant A", "a@example.com");
    repo.seed("Tenant B", "b@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();

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

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo.clone())
        .build_app();

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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

    let invoice_batch_ids = invoice_repo
        .latest_payment_summaries_by_customers_ids()
        .expect("the listing should issue one non-empty invoice batch");
    assert_eq!(
        invoice_batch_ids,
        vec![
            green_never_billed.id,
            green_recent_paid.id,
            yellow_stale_billing.id,
            red_overdue.id,
        ],
        "invoice batching must include every active customer and exclude deleted customers"
    );
    assert!(!invoice_batch_ids.contains(&grey_deleted.id));
}

#[tokio::test]
async fn list_tenants_returns_index_count() {
    let customer_repo = crate::common::mock_repo();
    let tenant_repo = crate::common::mock_tenant_repo();

    let customer_a = customer_repo.seed("Catalog A", "catalog-a@example.com");
    let customer_b = customer_repo.seed("Catalog B", "catalog-b@example.com");

    let active_deployment_a = Uuid::new_v4();
    let other_active_deployment_a = Uuid::new_v4();
    let terminated_deployment_a = Uuid::new_v4();
    let active_deployment_b = Uuid::new_v4();

    tenant_repo.seed_deployment(
        active_deployment_a,
        "us-east-1",
        Some("https://a1.flapjack.test"),
        "running",
        "running",
    );
    tenant_repo.seed_deployment(
        other_active_deployment_a,
        "us-west-2",
        Some("https://a2.flapjack.test"),
        "running",
        "running",
    );
    tenant_repo.seed_deployment(
        terminated_deployment_a,
        "us-east-2",
        Some("https://dead.flapjack.test"),
        "terminated",
        "terminated",
    );
    tenant_repo.seed_deployment(
        active_deployment_b,
        "eu-west-1",
        Some("https://b1.flapjack.test"),
        "running",
        "running",
    );

    tenant_repo
        .create(customer_a.id, "alpha", active_deployment_a)
        .await
        .unwrap();
    tenant_repo
        .create(customer_a.id, "bravo", active_deployment_a)
        .await
        .unwrap();
    tenant_repo
        .create(customer_a.id, "charlie", other_active_deployment_a)
        .await
        .unwrap();
    tenant_repo
        .create(customer_a.id, "terminated", terminated_deployment_a)
        .await
        .unwrap();
    tenant_repo
        .create(customer_b.id, "delta", active_deployment_b)
        .await
        .unwrap();

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_tenant_repo(tenant_repo)
        .build_app();

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let tenants = json.as_array().expect("response should be an array");

    let find_tenant = |id: Uuid| -> &serde_json::Value {
        tenants
            .iter()
            .find(|tenant| tenant["id"] == id.to_string())
            .unwrap_or_else(|| panic!("tenant '{id}' should be present"))
    };

    assert_eq!(find_tenant(customer_a.id)["index_count"], 3);
    assert_eq!(
        find_tenant(customer_b.id)["index_count"],
        1,
        "index_count must remain tenant-isolated"
    );
}

#[tokio::test]
async fn list_tenants_issues_at_most_three_repo_calls_for_twenty_five_customers() {
    let customer_repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();
    let tenant_repo = crate::common::mock_tenant_repo();

    for i in 0..25 {
        customer_repo.seed(
            &format!("Scale Customer {i:02}"),
            &format!("scale-{i:02}@example.com"),
        );
    }

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo.clone())
        .with_invoice_repo(invoice_repo.clone())
        .with_tenant_repo(tenant_repo.clone())
        .build_app();

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    assert_eq!(
        customer_repo.list_call_count(),
        1,
        "admin tenant listing must list customers exactly once"
    );
    let expected = 3;
    let actual = crate::common::admin_tenant_list_repo_call_total(
        &customer_repo,
        &invoice_repo,
        &tenant_repo,
    );
    assert!(
        actual <= expected,
        "admin tenant listing issued {actual} repo calls for 25 customers; \
         batched design allows at most {expected} (1 customer list + \
         1 batched invoice-signal fetch + 1 batched index-count fetch)"
    );
}

#[tokio::test]
async fn list_tenants_response_body_is_unchanged_for_seeded_fixture() {
    let customer_repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();
    let tenant_repo = crate::common::mock_tenant_repo();

    let now = Utc::now();
    let never_billed_last_accessed = now - Duration::minutes(40);
    let paid_last_accessed = now - Duration::minutes(30);
    let overdue_last_accessed = now - Duration::minutes(20);

    let never_billed = customer_repo.seed_billing_health_inputs(
        customer_repo
            .seed("Never Billed", "never-billed@example.com")
            .id,
        Some(never_billed_last_accessed),
        0,
    );
    let recent_paid = customer_repo.seed_billing_health_inputs(
        customer_repo
            .seed("Recent Paid", "recent-paid@example.com")
            .id,
        Some(paid_last_accessed),
        0,
    );
    invoice_repo.seed_paid(
        recent_paid.id,
        NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 5, 31).unwrap(),
        now - Duration::days(10),
    );
    let overdue = customer_repo.seed_billing_health_inputs(
        customer_repo.seed("Overdue", "overdue@example.com").id,
        Some(overdue_last_accessed),
        2,
    );
    let deleted = customer_repo.seed_deleted("Deleted Tenant", "deleted@example.com");
    let indexed = customer_repo.seed("Indexed Tenant", "indexed@example.com");

    let deleted_deployment = Uuid::new_v4();
    tenant_repo.seed_deployment(
        deleted_deployment,
        "us-east-1",
        Some("https://deleted.flapjack.test"),
        "running",
        "running",
    );
    tenant_repo
        .create(deleted.id, "retained", deleted_deployment)
        .await
        .unwrap();

    let indexed_deployment = Uuid::new_v4();
    tenant_repo.seed_deployment(
        indexed_deployment,
        "us-east-1",
        Some("https://indexed.flapjack.test"),
        "running",
        "running",
    );
    tenant_repo
        .create(indexed.id, "primary", indexed_deployment)
        .await
        .unwrap();

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_tenant_repo(tenant_repo)
        .build_app();

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let expected = serde_json::json!([
        {
            "id": never_billed.id,
            "name": never_billed.name,
            "email": never_billed.email,
            "status": never_billed.status,
            "billing_plan": never_billed.billing_plan,
            "index_count": 0,
            "last_accessed_at": never_billed.last_accessed_at,
            "overdue_invoice_count": 0,
            "billing_health": "green",
            "created_at": never_billed.created_at,
            "updated_at": never_billed.updated_at,
        },
        {
            "id": recent_paid.id,
            "name": recent_paid.name,
            "email": recent_paid.email,
            "status": recent_paid.status,
            "billing_plan": recent_paid.billing_plan,
            "index_count": 0,
            "last_accessed_at": recent_paid.last_accessed_at,
            "overdue_invoice_count": 0,
            "billing_health": "green",
            "created_at": recent_paid.created_at,
            "updated_at": recent_paid.updated_at,
        },
        {
            "id": overdue.id,
            "name": overdue.name,
            "email": overdue.email,
            "status": overdue.status,
            "billing_plan": overdue.billing_plan,
            "index_count": 0,
            "last_accessed_at": overdue.last_accessed_at,
            "overdue_invoice_count": 2,
            "billing_health": "red",
            "created_at": overdue.created_at,
            "updated_at": overdue.updated_at,
        },
        {
            "id": deleted.id,
            "name": deleted.name,
            "email": deleted.email,
            "status": deleted.status,
            "billing_plan": deleted.billing_plan,
            "index_count": 1,
            "last_accessed_at": deleted.last_accessed_at,
            "overdue_invoice_count": deleted.overdue_invoice_count,
            "billing_health": "grey",
            "created_at": deleted.created_at,
            "updated_at": deleted.updated_at,
        },
        {
            "id": indexed.id,
            "name": indexed.name,
            "email": indexed.email,
            "status": indexed.status,
            "billing_plan": indexed.billing_plan,
            "index_count": 1,
            "last_accessed_at": indexed.last_accessed_at,
            "overdue_invoice_count": indexed.overdue_invoice_count,
            "billing_health": "green",
            "created_at": indexed.created_at,
            "updated_at": indexed.updated_at,
        }
    ]);

    assert_eq!(json, expected);

    let tenants = json.as_array().expect("response should be an array");
    let observed_ids = tenants
        .iter()
        .map(|tenant| tenant["id"].as_str().unwrap())
        .collect::<Vec<_>>();
    let expected_ids = [
        never_billed.id.to_string(),
        recent_paid.id.to_string(),
        overdue.id.to_string(),
        deleted.id.to_string(),
        indexed.id.to_string(),
    ];
    assert_eq!(
        observed_ids,
        expected_ids.iter().map(String::as_str).collect::<Vec<_>>()
    );

    let expected_keys = [
        "billing_health",
        "billing_plan",
        "created_at",
        "email",
        "id",
        "index_count",
        "last_accessed_at",
        "name",
        "overdue_invoice_count",
        "status",
        "updated_at",
    ];
    for tenant in tenants {
        let object = tenant.as_object().expect("tenant should be an object");
        let keys = object.keys().map(String::as_str).collect::<Vec<_>>();
        assert_eq!(keys, expected_keys);
    }
}

#[tokio::test]
async fn list_tenants_limit_and_offset_return_exact_created_desc_id_desc_page() {
    let customer_repo = crate::common::mock_repo();
    let base = Utc::now();
    let older = customer_repo.seed_with_status_and_created_at(
        "Page Older",
        "page-older@example.com",
        "active",
        base - Duration::minutes(30),
    );
    let tie_a = customer_repo.seed_with_status_and_created_at(
        "Page Tie A",
        "page-tie-a@example.com",
        "suspended",
        base - Duration::minutes(10),
    );
    let tie_b = customer_repo.seed_with_status_and_created_at(
        "Page Tie B",
        "page-tie-b@example.com",
        "active",
        tie_a.created_at,
    );
    let newest = customer_repo.seed_with_status_and_created_at(
        "Page Newest",
        "page-newest@example.com",
        "deleted",
        base,
    );
    let oldest = customer_repo.seed_with_status_and_created_at(
        "Page Oldest",
        "page-oldest@example.com",
        "active",
        base - Duration::minutes(60),
    );

    let mut expected_customers = vec![older, tie_a, tie_b, newest, oldest];
    expected_customers.sort_by(|left, right| {
        right
            .created_at
            .cmp(&left.created_at)
            .then_with(|| right.id.cmp(&left.id))
    });
    let expected_first_page = expected_customers[0..2]
        .iter()
        .map(|customer| {
            (
                customer.id.to_string(),
                customer.name.clone(),
                customer.status.clone(),
            )
        })
        .collect::<Vec<_>>();
    let expected_second_page = expected_customers[2..4]
        .iter()
        .map(|customer| {
            (
                customer.id.to_string(),
                customer.name.clone(),
                customer.status.clone(),
            )
        })
        .collect::<Vec<_>>();

    let app = crate::common::test_app_with_repo(customer_repo);

    let first_page = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/admin/tenants?limit=2")
                .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(first_page.status(), StatusCode::OK);
    assert_eq!(
        tenant_id_name_status_rows(&body_json(first_page).await),
        expected_first_page
    );

    let second_page = app
        .oneshot(
            Request::builder()
                .uri("/admin/tenants?limit=2&offset=2")
                .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(second_page.status(), StatusCode::OK);
    assert_eq!(
        tenant_id_name_status_rows(&body_json(second_page).await),
        expected_second_page
    );
}

#[tokio::test]
async fn list_tenants_status_filter_returns_exact_rows_for_each_status() {
    let customer_repo = crate::common::mock_repo();
    let base = Utc::now();
    let active = customer_repo.seed_with_status_and_created_at(
        "Filter Active",
        "filter-active@example.com",
        "active",
        base,
    );
    let suspended = customer_repo.seed_with_status_and_created_at(
        "Filter Suspended",
        "filter-suspended@example.com",
        "suspended",
        base - Duration::minutes(1),
    );
    let deleted = customer_repo.seed_with_status_and_created_at(
        "Filter Deleted",
        "filter-deleted@example.com",
        "deleted",
        base - Duration::minutes(2),
    );

    let app = crate::common::test_app_with_repo(customer_repo);

    for (status, customer) in [
        ("active", active),
        ("suspended", suspended),
        ("deleted", deleted),
    ] {
        let resp = app
            .clone()
            .oneshot(
                Request::builder()
                    .uri(format!("/admin/tenants?status={status}"))
                    .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
        assert_eq!(
            tenant_id_name_status_rows(&body_json(resp).await),
            vec![(
                customer.id.to_string(),
                customer.name.clone(),
                customer.status.clone()
            )],
            "status={status} must return only matching tenants"
        );
    }
}

#[tokio::test]
async fn list_tenants_rejects_limit_over_max() {
    let repo = crate::common::mock_repo();
    repo.seed("Tenant A", "limit-overflow@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/admin/tenants?limit=101")
                .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp).await;
    assert_eq!(json["error"], "limit must be between 1 and 100");
}

#[tokio::test]
async fn list_tenants_rejects_unknown_status() {
    let repo = crate::common::mock_repo();
    repo.seed("Tenant A", "unknown-status@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let resp = app
        .oneshot(
            Request::builder()
                .uri("/admin/tenants?status=archived")
                .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let json = body_json(resp).await;
    assert_eq!(
        json["error"],
        "invalid status 'archived'; expected one of: active, suspended, deleted"
    );
}

#[tokio::test]
async fn list_tenants_empty_returns_200_with_empty_array() {
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let expected_last_accessed_at = Utc::now();
    // Customer with overdue invoices → Red per the post-subscription contract.
    repo.seed_billing_health_inputs(customer.id, Some(expected_last_accessed_at), 3);
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Old Name", "old@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Mode Co", "mode@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let _tenant_a = repo.seed("Tenant A", "a@example.com");
    let tenant_b = repo.seed("Tenant B", "b@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", tenant_b.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let _tenant_a = repo.seed("Tenant A", "a@example.com");
    let tenant_b = repo.seed("Tenant B", "b@example.com");
    let invoice_repo = crate::common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", tenant_b.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let invoice_repo = crate::common::mock_invoice_repo();
    invoice_repo.force_list_by_customer_failure();
    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(repo)
        .with_invoice_repo(invoice_repo)
        .build_app();

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from("{}"))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);

    let json = body_json(resp).await;
    assert_eq!(json["error"], "no fields to update");
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn suspend_customer_audit_transactional_failure_returns_500_and_keeps_customer_active() {
    let db = connect_isolated_and_migrate("tenant_suspend_audit_transactional_failure").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "tenant-suspend-transactional-failure-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Suspend Audit Transactional Failure").await;
    install_scoped_audit_failure_trigger(
        &db.pool,
        ACTION_CUSTOMER_SUSPENDED,
        operator_id,
        Some(customer_id),
    )
    .await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/customers/{customer_id}/suspend"))
                .header("x-admin-key", admin_credential)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    // Capture the response AND every post-request PostgreSQL observation
    // before asserting, then compare them together in one aggregate
    // assertion. Asserting the status first would short-circuit on today's
    // buggy 200 and hide the committed state; the aggregate form makes the
    // RED failure report that the suspension actually committed after the
    // scoped audit INSERT failed, not merely that the status was unexpected.
    let observed_customer_status = customer_status(&db.pool, customer_id).await;
    let observed_audit_rows = audit_row_count_for_action_and_nullable_target(
        &db.pool,
        ACTION_CUSTOMER_SUSPENDED,
        Some(customer_id),
    )
    .await;

    assert_eq!(
        (
            status,
            body.clone(),
            observed_customer_status.as_deref(),
            observed_audit_rows,
        ),
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            serde_json::json!({"error": "internal server error"}),
            Some("active"),
            0,
        ),
        "audit INSERT failure must roll back suspension; \
         observed status={status}, body={body}, \
         customer_status={observed_customer_status:?}, audit_rows={observed_audit_rows}"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn suspend_customer_audit_transactional_success_commits_status_and_attributed_audit_row() {
    let db = connect_isolated_and_migrate("tenant_suspend_audit_transactional_success").await;
    let (operator_id, admin_credential) = register_operator(
        &db.pool,
        &format!(
            "tenant-suspend-transactional-success-{}@example.com",
            Uuid::new_v4()
        ),
    )
    .await;
    let customer_id = create_active_customer(&db.pool, "Suspend Audit Transactional Success").await;
    let app = app_with_pg_customer_repo(db.pool.clone());

    let resp = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri(format!("/admin/customers/{customer_id}/suspend"))
                .header("x-admin-key", admin_credential)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let (status, body) = response_json(resp).await;

    assert_eq!(status, StatusCode::OK);
    assert_eq!(body, serde_json::json!({"message": "customer suspended"}));
    assert_eq!(
        customer_status(&db.pool, customer_id).await.as_deref(),
        Some("suspended")
    );
    let rows = audit_rows_for_action_and_nullable_target(
        &db.pool,
        ACTION_CUSTOMER_SUSPENDED,
        Some(customer_id),
    )
    .await;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].actor_id, operator_id);
    assert_eq!(rows[0].target_tenant_id, Some(customer_id));
}

// ===========================================================================
// GET /admin/tenants — list: deleted tenants remain visible for status filters
// ===========================================================================

#[tokio::test]
async fn list_tenants_includes_deleted() {
    let repo = crate::common::mock_repo();
    repo.seed("Active Corp", "active@example.com");
    repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri("/admin/tenants")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let deleted = repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .uri(format!("/admin/tenants/{}", deleted.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let deleted = repo.seed_deleted("Gone Corp", "gone@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", deleted.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = crate::common::test_app_with_repo(repo.clone());

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);

    let retained_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed")
        .expect("soft-deleted tenant row should be retained");
    assert_eq!(retained_customer.status, "deleted");
    assert_eq!(
        retained_customer.lifecycle_generation,
        customer.lifecycle_generation + 1,
        "admin delete should advance lifecycle generation exactly once"
    );
    let deleted_at = retained_customer
        .deleted_at
        .expect("admin delete should stamp deleted_at");
    assert_eq!(
        retained_customer.updated_at, deleted_at,
        "admin delete should stamp updated_at with deleted_at"
    );
    assert_customer_identity_and_non_lifecycle_fields_unchanged(&customer, &retained_customer);
}

#[tokio::test]
async fn delete_tenant_not_found_returns_404() {
    let repo = crate::common::mock_repo();
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", Uuid::new_v4()))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_tenant_returns_404_when_soft_delete_reports_missing() {
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    repo.fail_next_soft_delete();
    let app = crate::common::test_app_with_repo(repo.clone());

    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NOT_FOUND);

    let retained_customer = repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed")
        .expect("active tenant row should remain after soft_delete reports false");
    assert_eq!(retained_customer.status, "active");
    assert_eq!(
        retained_customer.lifecycle_generation,
        customer.lifecycle_generation
    );
    assert_eq!(retained_customer.deleted_at, customer.deleted_at);
    assert_eq!(retained_customer.updated_at, customer.updated_at);
    assert_customer_identity_and_non_lifecycle_fields_unchanged(&customer, &retained_customer);
}

#[tokio::test]
async fn delete_tenant_already_deleted_returns_404() {
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Acme", "acme@example.com");
    let app = crate::common::test_app_with_repo(repo.clone());

    // First delete — 204
    let req = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    let retained_after_first_delete = repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed after first delete")
        .expect("soft-deleted tenant row should be retained");
    assert_eq!(
        retained_after_first_delete.lifecycle_generation,
        customer.lifecycle_generation + 1
    );

    // Second delete — 404
    let app2 = crate::common::test_app_with_repo(repo.clone());
    let req2 = Request::builder()
        .method("DELETE")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp2 = app2.oneshot(req2).await.unwrap();
    assert_eq!(resp2.status(), StatusCode::NOT_FOUND);

    let retained_after_repeat = repo
        .find_by_id(customer.id)
        .await
        .expect("mock repo lookup should succeed after repeat delete")
        .expect("repeat delete should retain the deleted tenant row");
    assert_eq!(retained_after_repeat.status, "deleted");
    assert_eq!(
        retained_after_repeat.lifecycle_generation,
        retained_after_first_delete.lifecycle_generation,
        "repeat admin delete must not advance lifecycle generation"
    );
    assert_eq!(
        retained_after_repeat.deleted_at,
        retained_after_first_delete.deleted_at
    );
    assert_eq!(
        retained_after_repeat.updated_at,
        retained_after_first_delete.updated_at
    );
    assert_customer_identity_and_non_lifecycle_fields_unchanged(
        &retained_after_first_delete,
        &retained_after_repeat,
    );
}

// ===========================================================================
// PUT /admin/tenants/:id — billing_plan update
// ===========================================================================

#[tokio::test]
async fn update_tenant_billing_plan_returns_200() {
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Plan Corp", "plan@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Bad Plan Corp", "badplan@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
    let repo = crate::common::mock_repo();
    let customer = repo.seed("Combo Corp", "combo@example.com");
    let app = crate::common::test_app_with_repo(repo);

    let req = Request::builder()
        .method("PUT")
        .uri(format!("/admin/tenants/{}", customer.id))
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
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
