mod common;

use api::models::RateCardRow;
use api::repos::CustomerRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{Datelike, NaiveDate};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use serde_json::json;
use tower::ServiceExt;

use api::models::CustomerRateOverrideRow;
use common::{
    create_test_jwt, mock_deployment_repo, mock_invoice_repo, mock_rate_card_repo, mock_repo,
    mock_storage_bucket_repo, mock_stripe_service, mock_usage_repo, test_state_all_with_stripe,
    TestStateBuilder,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn test_rate_card() -> RateCardRow {
    RateCardRow {
        id: uuid::Uuid::new_v4(),
        name: "default".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: json!({}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: chrono::Utc::now(),
    }
}

fn build_app(
    customer_repo: std::sync::Arc<common::MockCustomerRepo>,
    usage_repo: std::sync::Arc<common::MockUsageRepo>,
    rate_card_repo: std::sync::Arc<common::MockRateCardRepo>,
) -> axum::Router {
    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        mock_invoice_repo(),
        mock_stripe_service(),
    );
    api::router::build_router(state)
}

// ===========================================================================
// GET /billing/estimate
// ===========================================================================

#[tokio::test]
async fn estimate_returns_correct_total_for_usage() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    // Seed usage for Feb 2026: hot storage drives estimate subtotal.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 30;
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(
            customer.id,
            date,
            "us-east-1",
            3571,
            357,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app = build_app(customer_repo, usage_repo, rate_card_repo);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    // Verify response structure
    assert_eq!(body["month"], "2026-02");
    assert!(
        body["subtotal_cents"].as_i64().unwrap() > 0,
        "subtotal should be positive"
    );
    assert!(
        body["total_cents"].as_i64().unwrap() > 0,
        "total should be positive"
    );
    assert_eq!(
        body["minimum_applied"], false,
        "usage exceeds minimum so should not be applied"
    );

    // Verify line items are present
    let line_items = body["line_items"].as_array().unwrap();
    assert!(!line_items.is_empty(), "should have line items");

    // All line items should be for us-east-1
    for li in line_items {
        assert_eq!(li["region"], "us-east-1");
        assert!(li["description"].as_str().is_some());
        assert!(li["quantity"].as_str().is_some());
        assert!(li["unit"].as_str().is_some());
        assert!(li["unit_price_cents"].as_str().is_some());
        assert!(li["amount_cents"].is_number());
    }
}

#[tokio::test]
async fn estimate_zero_when_no_usage() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    // No usage seeded

    let app = build_app(customer_repo, usage_repo, rate_card_repo);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    assert_eq!(body["month"], "2026-02");
    assert_eq!(body["subtotal_cents"], 0);
    assert_eq!(body["total_cents"], 500);
    assert_eq!(body["minimum_applied"], true);
    assert_eq!(body["line_items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn estimate_succeeds_without_stripe_customer_or_payment_methods() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let customer_after_seed = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after_seed.stripe_customer_id, None,
        "seeded customer should have no stripe customer id"
    );

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let stripe_service = mock_stripe_service();
    stripe_service.set_should_fail(true);

    // This app state intentionally has no Stripe customer/payment-method setup.
    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_service)
        .build_app();

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["month"], "2026-02");
    assert_eq!(body["subtotal_cents"], 0);
    assert_eq!(body["total_cents"], 500);
    assert_eq!(body["minimum_applied"], true);
    assert_eq!(body["line_items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn estimate_shared_plan_succeeds_without_stripe_customer_or_payment_methods() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme Shared", "acme-shared@example.com");
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let stripe_service = mock_stripe_service();
    stripe_service.set_should_fail(true);

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_service)
        .build_app();

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["month"], "2026-02");
    assert_eq!(body["subtotal_cents"], 0);
    assert_eq!(body["total_cents"], 200);
    assert_eq!(body["minimum_applied"], true);
    assert_eq!(body["line_items"].as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn estimate_shared_plan_uses_shared_minimum() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme Shared", "acme-shared@example.com");
    customer_repo
        .set_billing_plan(customer.id, "shared")
        .await
        .unwrap();

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(customer_repo, usage_repo, rate_card_repo);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["subtotal_cents"], 0);
    assert_eq!(body["total_cents"], 200);
    assert_eq!(body["minimum_applied"], true);
}

#[tokio::test]
async fn estimate_unknown_plan_defaults_to_free_minimum() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme Unknown", "acme-unknown@example.com");
    customer_repo
        .set_billing_plan(customer.id, "enterprise")
        .await
        .unwrap();

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(customer_repo, usage_repo, rate_card_repo);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["subtotal_cents"], 0);
    assert_eq!(body["total_cents"], 500);
    assert_eq!(body["minimum_applied"], true);
}

#[tokio::test]
async fn estimate_applies_rate_card_minimums() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card()); // minimum_spend_cents = 500

    // Seed tiny usage — subtotal will be well under $5.00 minimum
    usage_repo.seed(
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        "us-east-1",
        100, // 100 search requests = 0.1 units at $0.50/1K = $0.05
        50,  // 50 writes = 0.05 units at $0.10/1K = $0.005
        0,
        0,
    );

    let app = build_app(customer_repo, usage_repo, rate_card_repo);

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    assert!(
        body["subtotal_cents"].as_i64().unwrap() < 500,
        "subtotal should be below minimum"
    );
    assert_eq!(
        body["total_cents"], 500,
        "total should be bumped to minimum_spend_cents"
    );
    assert_eq!(body["minimum_applied"], true);
}

#[tokio::test]
async fn estimate_401_without_auth() {
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(mock_repo(), mock_usage_repo(), rate_card_repo);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ===========================================================================
// Suspended customer — 403
// ===========================================================================

#[tokio::test]
async fn estimate_403_suspended_customer() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(customer_repo, mock_usage_repo(), rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::FORBIDDEN);
}

// ===========================================================================
// Rate override affects estimate
// ===========================================================================

#[tokio::test]
async fn estimate_with_rate_override_applies_custom_rates() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let card = test_rate_card();
    let card_id = card.id;
    rate_card_repo.seed_active_card(card);

    // Customer has a rate override for hot storage.
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer.id,
        rate_card_id: card_id,
        overrides: json!({ "storage_rate_per_mb_month": "0.25" }),
        created_at: chrono::Utc::now(),
    });

    // Seed usage: 10 MB-month hot storage.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 10;
    for day in 1..=28 {
        usage_repo.seed(
            customer.id,
            NaiveDate::from_ymd_opt(2026, 2, day).unwrap(),
            "us-east-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app = build_app(
        customer_repo.clone(),
        usage_repo.clone(),
        rate_card_repo.clone(),
    );
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    // 10 MB-month at $0.25/MB = 250 cents (subtotal)
    // Unified minimum is 500 cents, so total should be bumped.
    let subtotal = body["subtotal_cents"].as_i64().unwrap();
    assert_eq!(subtotal, 250, "10 MB-month at $0.25/MB = 250 cents");
    assert_eq!(body["total_cents"], 500);
    assert_eq!(body["minimum_applied"], true);

    // Verify line item uses override rate
    let items = body["line_items"].as_array().unwrap();
    let hot_storage_item = items.iter().find(|li| {
        li["description"]
            .as_str()
            .unwrap_or("")
            .to_lowercase()
            .contains("hot storage")
    });
    assert!(
        hot_storage_item.is_some(),
        "should have a hot storage line item"
    );
    let hot_storage_item = hot_storage_item.unwrap();
    assert_eq!(hot_storage_item["amount_cents"], 250);
}

// ===========================================================================
// Cross-tenant isolation — customer A cannot see customer B's override
// ===========================================================================

#[tokio::test]
async fn estimate_cross_tenant_isolation() {
    let customer_repo = mock_repo();
    let customer_a = customer_repo.seed("Acme", "acme@example.com");
    let customer_b = customer_repo.seed("Beta", "beta@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let card = test_rate_card();
    let card_id = card.id;
    rate_card_repo.seed_active_card(card);

    // Customer B has a rate override: search rate halved
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer_b.id,
        rate_card_id: card_id,
        overrides: json!({ "storage_rate_per_mb_month": "0.25" }),
        created_at: chrono::Utc::now(),
    });

    // Seed identical hot-storage usage for both customers.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 10;
    for cust_id in [customer_a.id, customer_b.id] {
        for day in 1..=28 {
            usage_repo.seed(
                cust_id,
                NaiveDate::from_ymd_opt(2026, 2, day).unwrap(),
                "us-east-1",
                0,
                0,
                hot_storage_bytes_per_day,
                0,
            );
        }
    }

    // Customer A should use base rate ($0.20/MB → 200 cents subtotal)
    let state_a = test_state_all_with_stripe(
        customer_repo.clone(),
        mock_deployment_repo(),
        usage_repo.clone(),
        rate_card_repo.clone(),
        mock_invoice_repo(),
        mock_stripe_service(),
    );
    let app_a = api::router::build_router(state_a);
    let jwt_a = create_test_jwt(customer_a.id);

    let resp_a = app_a
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt_a}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp_a.status(), StatusCode::OK);
    let body_a = body_json(resp_a).await;
    let subtotal_a = body_a["subtotal_cents"].as_i64().unwrap();
    assert_eq!(
        subtotal_a, 200,
        "customer A: 10 MB-month at base $0.20/MB = 200 cents"
    );

    // Customer B should use override rate ($0.25/MB → 250 cents subtotal)
    let state_b = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        mock_invoice_repo(),
        mock_stripe_service(),
    );
    let app_b = api::router::build_router(state_b);
    let jwt_b = create_test_jwt(customer_b.id);

    let resp_b = app_b
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt_b}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp_b.status(), StatusCode::OK);
    let body_b = body_json(resp_b).await;
    let subtotal_b = body_b["subtotal_cents"].as_i64().unwrap();
    assert_eq!(
        subtotal_b, 250,
        "customer B: 10 MB-month at override $0.25/MB = 250 cents"
    );
}

// ===========================================================================
// Default month — no month param defaults to current month
// ===========================================================================

#[tokio::test]
async fn estimate_defaults_to_current_month() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(customer_repo, mock_usage_repo(), rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    // Should default to current month in YYYY-MM format
    let month = body["month"].as_str().unwrap();
    let now = chrono::Utc::now();
    let expected = format!("{:04}-{:02}", now.year(), now.month());
    assert_eq!(month, expected, "should default to current month");
}

// ===========================================================================
// Invalid month format — 400
// ===========================================================================

#[tokio::test]
async fn estimate_400_invalid_month_format() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let app = build_app(customer_repo, mock_usage_repo(), rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=bad-format")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

// ===========================================================================
// No active rate card — 404
// ===========================================================================

// ===========================================================================
// Multi-region estimate — per-region line items
// ===========================================================================

#[tokio::test]
async fn estimate_multi_region_produces_per_region_line_items() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    // Seed storage usage in two different regions.
    let hot_storage_us_east = billing::types::BYTES_PER_MB * 20;
    let hot_storage_eu_west = billing::types::BYTES_PER_MB * 20;
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "us-east-1", 0, 0, hot_storage_us_east, 0);
        usage_repo.seed(customer.id, date, "eu-west-1", 0, 0, hot_storage_eu_west, 0);
    }

    let app = build_app(customer_repo, usage_repo, rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    let line_items = body["line_items"].as_array().unwrap();
    assert!(
        line_items.len() >= 2,
        "should have line items for both regions"
    );

    // Collect regions from line items
    let regions: Vec<&str> = line_items
        .iter()
        .filter_map(|li| li["region"].as_str())
        .collect();
    assert!(
        regions.contains(&"us-east-1"),
        "missing us-east-1 line items"
    );
    assert!(
        regions.contains(&"eu-west-1"),
        "missing eu-west-1 line items"
    );

    // Both regions contribute to subtotal
    assert!(body["subtotal_cents"].as_i64().unwrap() > 0);
    assert_eq!(body["minimum_applied"], false, "usage exceeds minimum");
}

// ===========================================================================
// Storage usage — produces storage line item
// ===========================================================================

#[tokio::test]
async fn estimate_with_storage_produces_storage_line_item() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    // Seed 28 days of 1 GiB storage plus some metered requests.
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(
            customer.id,
            date,
            "us-east-1",
            3571, // searches to exceed minimum
            0,
            billing::types::BYTES_PER_GIB, // 1 GB per day
            0,
        );
    }

    let app = build_app(customer_repo, usage_repo, rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    let line_items = body["line_items"].as_array().unwrap();

    // Should have a storage line item
    let storage_item = line_items
        .iter()
        .find(|li| li["unit"].as_str().unwrap_or("") == "mb_months");
    assert!(
        storage_item.is_some(),
        "should have a storage (mb_months) line item"
    );
    let storage_item = storage_item.unwrap();

    assert!(
        storage_item["description"]
            .as_str()
            .unwrap()
            .to_lowercase()
            .contains("storage"),
        "storage line item description should mention 'storage'"
    );
    assert!(
        storage_item["amount_cents"].as_i64().unwrap() > 0,
        "storage line item should have positive amount"
    );

    // Only storage dimensions are billable in the stage-2 contract.
}

// ===========================================================================
// No active rate card — 404
// ===========================================================================

#[tokio::test]
async fn estimate_404_when_no_active_rate_card() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // No rate card seeded
    let rate_card_repo = mock_rate_card_repo();

    let app = build_app(customer_repo, mock_usage_repo(), rate_card_repo);
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// Object storage — estimate includes object-storage line items
// ===========================================================================

#[tokio::test]
async fn estimate_includes_object_storage_line_items() {
    use api::models::storage::NewStorageBucket;
    use api::repos::StorageBucketRepo;

    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card());

    let storage_bucket_repo = mock_storage_bucket_repo();
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "my-bucket".to_string(),
            },
            "garage-my-bucket",
        )
        .await
        .unwrap();
    // 10 GB stored, 5 GB egress with 2 GB already billed
    let one_gb = billing::types::BYTES_PER_GIB;
    storage_bucket_repo
        .increment_size(bucket.id, one_gb * 10, 100)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, one_gb * 5)
        .await
        .unwrap();
    storage_bucket_repo
        .update_egress_watermark(bucket.id, one_gb * 2)
        .await
        .unwrap();

    // Seed some search usage to exceed minimum
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "us-east-1", 3571, 0, 0, 0);
    }

    let app = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_usage_repo(usage_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_storage_bucket_repo(storage_bucket_repo.clone())
        .build_app();

    let jwt = create_test_jwt(customer.id);
    let resp = app
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    let line_items = body["line_items"].as_array().unwrap();

    // Object storage GB-months: 10 GB at $0.024/GB = 24 cents
    let obj_storage = line_items
        .iter()
        .find(|li| li["unit"].as_str().unwrap_or("") == "object_storage_gb_months");
    assert!(
        obj_storage.is_some(),
        "estimate should include object_storage_gb_months line item"
    );
    assert_eq!(obj_storage.unwrap()["amount_cents"], 24);

    // Object storage egress: 3 GB unbilled (5 - 2 watermark) at $0.01/GB = 3 cents
    let egress = line_items
        .iter()
        .find(|li| li["unit"].as_str().unwrap_or("") == "object_storage_egress_gb");
    assert!(
        egress.is_some(),
        "estimate should include object_storage_egress_gb line item"
    );
    assert_eq!(egress.unwrap()["amount_cents"], 3);

    // Estimate must NOT advance watermark (read-only)
    let bucket_after = storage_bucket_repo.get(bucket.id).await.unwrap().unwrap();
    assert_eq!(
        bucket_after.egress_watermark_bytes,
        one_gb * 2,
        "estimate must not advance egress watermark"
    );
}
