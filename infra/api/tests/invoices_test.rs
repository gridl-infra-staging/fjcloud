mod common;

use api::models::RateCardRow;
use api::repos::invoice_repo::NewLineItem;
use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    create_test_jwt, mock_deployment_repo, mock_invoice_repo, mock_rate_card_repo, mock_repo,
    mock_storage_bucket_repo, mock_usage_repo, test_app_all, TestStateBuilder, TEST_ADMIN_KEY,
};

fn sample_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "launch-2026".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: serde_json::json!({}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: Utc::now(),
    }
}

fn sample_line_item(region: &str, amount_cents: i64) -> NewLineItem {
    NewLineItem {
        description: format!("Search requests ({})", region),
        quantity: dec!(100.000000),
        unit: "requests_1k".to_string(),
        unit_price_cents: dec!(50.0000),
        amount_cents,
        region: region.to_string(),
        metadata: None,
    }
}

// ===========================================================================
// Tenant-facing: GET /invoices
// ===========================================================================

#[tokio::test]
async fn list_invoices_200_with_data() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );
    invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        3000,
        3000,
        false,
        vec![sample_line_item("us-east-1", 3000)],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/invoices")
                .header("authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2);
    // Most-recent period_start first (DESC sort)
    assert_eq!(arr[0]["period_start"], "2026-02-01");
    assert_eq!(arr[1]["period_start"], "2026-01-01");
    // Spot-check required fields
    assert!(arr[0].get("id").is_some());
    assert!(arr[0].get("total_cents").is_some());
    assert!(arr[0].get("status").is_some());
}

#[tokio::test]
async fn list_invoices_200_empty() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/invoices")
                .header("authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn list_invoices_401_missing_auth() {
    let app = test_app_all(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(Request::get("/invoices").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Tenant-facing: GET /invoices/:invoice_id
// ===========================================================================

#[tokio::test]
async fn get_invoice_200_with_line_items() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["total_cents"], 5000);
    let items = body["line_items"].as_array().unwrap();
    assert_eq!(items.len(), 1);
    // Decimal fields serialized as strings
    assert!(items[0]["quantity"].is_string());
    assert!(items[0]["unit_price_cents"].is_string());
    assert_eq!(items[0]["region"], "us-east-1");
}

#[tokio::test]
async fn get_invoice_404_not_found() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", Uuid::new_v4()))
                .header("authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn get_invoice_403_other_tenant() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer_a = customer_repo.seed("Acme", "acme@example.com");
    let customer_b = customer_repo.seed("Beta", "beta@example.com");

    let invoice = invoice_repo.seed(
        customer_a.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    // Customer B tries to access Customer A's invoice
    let jwt = create_test_jwt(customer_b.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
async fn get_invoice_401_missing_auth() {
    let app = test_app_all(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", Uuid::new_v4()))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Admin-facing: GET /admin/tenants/:id/invoices
// ===========================================================================

#[tokio::test]
async fn admin_list_invoices_200() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn admin_list_invoices_404_unknown_tenant() {
    let app = test_app_all(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/invoices", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn admin_list_invoices_401_missing_auth() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/invoices", customer.id))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Admin-facing: POST /admin/tenants/:id/invoices
// ===========================================================================

#[tokio::test]
async fn generate_invoice_201_with_line_items() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card);

    // Seed 28 days with constant 200 MB/day hot storage.
    // summarize() => 200 mb_months; at $0.20/MB this is 4000 cents.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 200;
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(
            customer.id,
            date,
            "us-east-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["customer_id"], customer.id.to_string());
    assert_eq!(body["status"], "draft");
    assert_eq!(body["subtotal_cents"].as_i64().unwrap(), 4000);
    assert_eq!(body["total_cents"].as_i64().unwrap(), 4000);
    assert!(!body["minimum_applied"].as_bool().unwrap());
    let items = body["line_items"].as_array().unwrap();
    assert!(!items.is_empty());
    assert!(
        items.iter().any(|item| item["unit"] == "mb_months"),
        "invoice should include hot storage mb_months line item"
    );
    for item in items {
        assert_eq!(item["region"], "us-east-1");
        assert!(item["description"].as_str().is_some());
    }
}

#[tokio::test]
async fn generate_invoice_201_minimum_applied() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card);

    // No usage seeded — minimum should apply

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body["minimum_applied"].as_bool().unwrap());
    assert_eq!(body["total_cents"].as_i64().unwrap(), 500);
    assert_eq!(body["subtotal_cents"].as_i64().unwrap(), 0);
}

#[tokio::test]
async fn generate_invoice_201_shared_plan_uses_shared_minimum() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Shared Acme", "shared-acme@example.com");
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card);

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body["minimum_applied"].as_bool().unwrap());
    assert_eq!(body["total_cents"].as_i64().unwrap(), 200);
    assert_eq!(body["subtotal_cents"].as_i64().unwrap(), 0);
}

#[tokio::test]
async fn generate_invoice_201_unknown_plan_defaults_to_free_minimum() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Unknown Acme", "unknown-acme@example.com");
    customer_repo
        .set_billing_plan(customer.id, "enterprise")
        .await
        .unwrap();

    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card);

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(body["minimum_applied"].as_bool().unwrap());
    assert_eq!(body["total_cents"].as_i64().unwrap(), 500);
    assert_eq!(body["subtotal_cents"].as_i64().unwrap(), 0);
}

#[tokio::test]
async fn generate_invoice_409_duplicate_period() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card);

    // Seed existing invoice for same period
    invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        500,
        500,
        true,
        vec![],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn generate_invoice_400_invalid_month() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "bad"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn generate_invoice_404_unknown_tenant() {
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_all(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn generate_invoice_404_no_rate_card() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // No rate card seeded
    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn generate_invoice_401_missing_auth() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// MT-02: Tenant invoice list isolation — tenant B cannot see tenant A's invoices
// ===========================================================================

#[tokio::test]
async fn list_invoices_200_tenant_isolation() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let tenant_a = customer_repo.seed("Tenant A", "a@example.com");
    let tenant_b = customer_repo.seed("Tenant B", "b@example.com");

    // Seed invoices only for tenant A
    invoice_repo.seed(
        tenant_a.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    // Tenant B fetches their own invoice list — must be empty
    let jwt = create_test_jwt(tenant_b.id);
    let resp = app
        .oneshot(
            Request::get("/invoices")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(
        body.as_array().unwrap().len(),
        0,
        "tenant B must not see tenant A's invoices"
    );
}

// ===========================================================================
// MT-10: generate_invoice 404 for deleted tenant
// ===========================================================================

#[tokio::test]
async fn generate_invoice_404_deleted_tenant() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", deleted.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// MT-13: admin list invoices 404 for deleted tenant
// ===========================================================================

#[tokio::test]
async fn admin_list_invoices_404_deleted_tenant() {
    let customer_repo = mock_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/invoices", deleted.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// Suspended customer — 403 on invoice detail
// ===========================================================================

#[tokio::test]
async fn get_invoice_detail_403_suspended_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ===========================================================================
// MT-06: generate_invoice uses customer rate override to compute totals
// ===========================================================================

#[tokio::test]
async fn generate_invoice_201_rate_override_applied() {
    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let card = sample_rate_card(); // storage_rate_per_mb_month = 0.20, minimum = 500
    rate_card_repo.seed_active_card(card.clone());

    // Override: lower the hot storage rate for this customer.
    use api::models::CustomerRateOverrideRow;
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer.id,
        rate_card_id: card.id,
        overrides: serde_json::json!({"storage_rate_per_mb_month": "0.10"}),
        created_at: chrono::Utc::now(),
    });

    // Seed 28 days with constant 300 MB/day hot storage.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 300;
    for day in 1u32..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(
            customer.id,
            date,
            "us-east-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    // Base rate: 300 mb_months × $0.20 = 6000 cents
    // Override rate: 300 mb_months × $0.10 = 3000 cents
    let total = body["total_cents"].as_i64().unwrap();
    assert_eq!(
        total, 3000,
        "override should set hot storage total to 3000 cents"
    );
    assert!(!body["minimum_applied"].as_bool().unwrap());
    assert!(!body["line_items"].as_array().unwrap().is_empty());
}

// ===========================================================================
// Invoice detail includes Stripe/lifecycle fields
// ===========================================================================

#[tokio::test]
async fn get_invoice_detail_includes_stripe_fields_null_for_draft() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["status"], "draft");
    assert!(body["stripe_invoice_id"].is_null());
    assert!(body["hosted_invoice_url"].is_null());
    assert!(body["finalized_at"].is_null());
    assert!(body["paid_at"].is_null());
}

#[tokio::test]
async fn get_invoice_detail_includes_stripe_fields_after_finalize() {
    use api::repos::invoice_repo::InvoiceRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    // Simulate finalization + Stripe fields being set
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_abc",
            "https://invoice.stripe.com/i/test",
            None,
        )
        .await
        .unwrap();

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["status"], "finalized");
    assert_eq!(body["stripe_invoice_id"], "in_stripe_abc");
    assert_eq!(
        body["hosted_invoice_url"],
        "https://invoice.stripe.com/i/test"
    );
    assert!(
        body["finalized_at"].is_string(),
        "finalized_at should be a timestamp string"
    );
    assert!(
        body["paid_at"].is_null(),
        "paid_at should be null before payment"
    );
}

#[tokio::test]
async fn get_invoice_detail_includes_paid_at_after_payment() {
    use api::repos::invoice_repo::InvoiceRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    // Simulate full lifecycle: draft → finalized → paid
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["status"], "paid");
    assert!(body["finalized_at"].is_string());
    assert!(
        body["paid_at"].is_string(),
        "paid_at should be set after payment"
    );
}

// ===========================================================================
// Admin generate invoice includes object-storage line items
// ===========================================================================

#[tokio::test]
async fn generate_invoice_201_with_object_storage_line_items() {
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let invoice_repo = mock_invoice_repo();
    let storage_bucket_repo = mock_storage_bucket_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    rate_card_repo.seed_active_card(sample_rate_card());

    // Create storage bucket: 20 GB stored, 8 GB egress, 3 GB watermark
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "data-bucket".to_string(),
            },
            "garage-data-bucket",
        )
        .await
        .unwrap();
    let one_gb = billing::types::BYTES_PER_GIB;
    storage_bucket_repo
        .increment_size(bucket.id, one_gb * 20, 500)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 8)
        .await
        .unwrap();
    storage_bucket_repo
        .update_egress_watermark(bucket.id, one_gb * 3)
        .await
        .unwrap();

    // Seed some hot usage too
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "us-east-1", 3571, 0, 0, 0);
    }

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_invoice_repo(invoice_repo)
        .with_storage_bucket_repo(storage_bucket_repo)
        .build_app();

    let resp = app
        .oneshot(
            Request::post(format!("/admin/tenants/{}/invoices", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month": "2026-02"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::CREATED);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    let items = body["line_items"].as_array().unwrap();

    // 20 GB at $0.024/GB = 48 cents
    let obj_li = items
        .iter()
        .find(|li| li["unit"].as_str().unwrap_or("") == "object_storage_gb_months");
    assert!(
        obj_li.is_some(),
        "admin invoice should include object_storage_gb_months line item"
    );
    assert_eq!(obj_li.unwrap()["amount_cents"], 48);

    // 5 GB unbilled egress (8 - 3 watermark) at $0.01/GB = 5 cents
    let egress_li = items
        .iter()
        .find(|li| li["unit"].as_str().unwrap_or("") == "object_storage_egress_gb");
    assert!(
        egress_li.is_some(),
        "admin invoice should include object_storage_egress_gb line item"
    );
    assert_eq!(egress_li.unwrap()["amount_cents"], 5);
}

#[tokio::test]
async fn get_invoice_detail_includes_pdf_url_after_finalize() {
    use api::repos::invoice_repo::InvoiceRepo;

    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 3, 31).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_pdf_test",
            "https://invoice.stripe.com/i/hosted",
            Some("https://invoice.stripe.com/i/pdf"),
        )
        .await
        .unwrap();

    // Verify round-trip through find_by_id
    let found = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(
        found.pdf_url.as_deref(),
        Some("https://invoice.stripe.com/i/pdf")
    );

    // Verify API response includes pdf_url
    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert_eq!(body["stripe_invoice_id"], "in_stripe_pdf_test");
    assert_eq!(
        body["hosted_invoice_url"],
        "https://invoice.stripe.com/i/hosted"
    );
    assert_eq!(body["pdf_url"], "https://invoice.stripe.com/i/pdf");
}

#[tokio::test]
async fn get_invoice_detail_pdf_url_null_when_not_set() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = invoice_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 4, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 4, 30).unwrap(),
        5000,
        5000,
        false,
        vec![sample_line_item("us-east-1", 5000)],
    );

    let app = test_app_all(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
    );

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get(format!("/invoices/{}", invoice.id))
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();
    assert!(
        body["pdf_url"].is_null(),
        "pdf_url should be null for draft invoices"
    );
}
