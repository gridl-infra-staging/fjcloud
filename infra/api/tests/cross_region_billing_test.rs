/// Stage 9 §4 — Cross-region usage aggregation tests.
///
/// Three checklist tests:
/// 1. usage_aggregation_separates_regions — AWS + Hetzner usage aggregated separately
/// 2. billing_applies_region_multiplier_for_hetzner — eu-central-1 billed at 0.70× rate
/// 3. admin_fleet_shows_provider_column — fleet endpoint returns vm_provider field
mod common;

use api::models::storage::NewStorageBucket;
use api::models::RateCardRow;
use api::repos::StorageBucketRepo;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::NaiveDate;
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use serde_json::json;
use tower::ServiceExt;

use common::{
    create_test_jwt, mock_deployment_repo, mock_invoice_repo, mock_rate_card_repo, mock_repo,
    mock_storage_bucket_repo, mock_stripe_service, mock_usage_repo, test_state_all_with_stripe,
    TestStateBuilder, TEST_ADMIN_KEY,
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn test_rate_card_with_hetzner_multipliers() -> RateCardRow {
    RateCardRow {
        id: uuid::Uuid::new_v4(),
        name: "launch-2026".to_string(),
        effective_from: chrono::Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: json!({
            "eu-central-1": "0.70",
            "eu-north-1": "0.75",
            "us-east-2": "0.80",
            "us-west-1": "0.80"
        }),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: chrono::Utc::now(),
    }
}

// ===========================================================================
// §4 Test 1: usage_aggregation_separates_regions
// ===========================================================================

#[tokio::test]
async fn usage_aggregation_separates_regions() {
    // Customer has indexes in both AWS (us-east-1) and Hetzner (eu-central-1).
    // Usage for each region must be aggregated separately in the /usage response.
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("MultiCloud Corp", "mc@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card_with_hetzner_multipliers());

    // Seed usage: us-east-1 (AWS) — 5000 searches/day for 28 days
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "us-east-1", 5000, 200, 0, 0);
    }

    // Seed usage: eu-central-1 (Hetzner) — 3000 searches/day for 28 days
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "eu-central-1", 3000, 100, 0, 0);
    }

    let app = api::router::build_router(test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        mock_invoice_repo(),
        mock_stripe_service(),
    ));
    let jwt = create_test_jwt(customer.id);

    let resp = app
        .oneshot(
            Request::get("/usage?month=2026-02")
                .header("authorization", format!("Bearer {jwt}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;

    // Both regions must appear in by_region
    let by_region = body["by_region"].as_array().unwrap();
    assert_eq!(by_region.len(), 2, "should have 2 regions: AWS + Hetzner");

    // by_region is sorted alphabetically: eu-central-1 before us-east-1
    let eu = &by_region[0];
    let us = &by_region[1];
    assert_eq!(eu["region"], "eu-central-1");
    assert_eq!(us["region"], "us-east-1");

    // Verify per-region totals are separated correctly
    // us-east-1: 5000 * 28 = 140000 searches
    assert_eq!(us["search_requests"], 140_000);
    assert_eq!(us["write_operations"], 5600); // 200 * 28

    // eu-central-1: 3000 * 28 = 84000 searches
    assert_eq!(eu["search_requests"], 84_000);
    assert_eq!(eu["write_operations"], 2800); // 100 * 28

    // Cross-region totals
    assert_eq!(body["total_search_requests"], 224_000);
    assert_eq!(body["total_write_operations"], 8400);
}

// ===========================================================================
// §4 Test 2: billing_applies_region_multiplier_for_hetzner
// ===========================================================================

#[tokio::test]
async fn billing_applies_region_multiplier_for_hetzner() {
    // Customer has usage in eu-central-1 (Hetzner, 0.70× multiplier).
    // Billing estimate must apply the 0.70× region multiplier to all rates.
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Hetzner Customer", "hetzner@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card_with_hetzner_multipliers());

    // Seed 250 MB average hot storage in eu-central-1 across Feb.
    // With a constant daily storage snapshot, summarize() produces 250 mb_months.
    let hot_storage_bytes_per_day = billing::types::BYTES_PER_MB * 250;
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(
            customer.id,
            date,
            "eu-central-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app = api::router::build_router(test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        mock_invoice_repo(),
        mock_stripe_service(),
    ));
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

    // Without multiplier: 250 mb_months × $0.20 = 5000 cents.
    // With 0.70× multiplier: 250 mb_months × $0.20 × 0.70 = 3500 cents.
    let subtotal = body["subtotal_cents"].as_i64().unwrap();
    assert_eq!(
        subtotal, 3500,
        "eu-central-1 subtotal should reflect 0.70× region multiplier"
    );
    assert!(!body["minimum_applied"].as_bool().unwrap());

    // Verify all line items are for eu-central-1
    let line_items = body["line_items"].as_array().unwrap();
    assert!(!line_items.is_empty());
    for li in line_items {
        assert_eq!(li["region"], "eu-central-1");
    }
    assert!(
        line_items.iter().any(|li| li["unit"] == "mb_months"),
        "expected hot storage mb_months line item"
    );

    // Now compare: same usage in us-east-1 (no multiplier) should be higher
    let customer_repo2 = mock_repo();
    let customer2 = customer_repo2.seed("AWS Customer", "aws@example.com");
    let usage_repo2 = mock_usage_repo();
    let rate_card_repo2 = mock_rate_card_repo();
    rate_card_repo2.seed_active_card(test_rate_card_with_hetzner_multipliers());

    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo2.seed(
            customer2.id,
            date,
            "us-east-1",
            0,
            0,
            hot_storage_bytes_per_day,
            0,
        );
    }

    let app2 = api::router::build_router(test_state_all_with_stripe(
        customer_repo2,
        mock_deployment_repo(),
        usage_repo2,
        rate_card_repo2,
        mock_invoice_repo(),
        mock_stripe_service(),
    ));
    let jwt2 = create_test_jwt(customer2.id);

    let resp2 = app2
        .oneshot(
            Request::get("/billing/estimate?month=2026-02")
                .header("authorization", format!("Bearer {jwt2}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp2.status(), StatusCode::OK);
    let body2 = body_json(resp2).await;
    let subtotal_aws = body2["subtotal_cents"].as_i64().unwrap();

    assert_eq!(
        subtotal_aws, 5000,
        "us-east-1 subtotal should use base (1.0×) multiplier"
    );
    // AWS us-east-1 (1.0× multiplier) should be more expensive than eu-central-1.
    assert!(
        subtotal_aws > subtotal,
        "us-east-1 (no multiplier, {subtotal_aws}) should be more expensive than eu-central-1 (0.70×, {subtotal})"
    );
}

// ===========================================================================
// §4 Test 3: admin_fleet_shows_provider_column
// ===========================================================================

#[tokio::test]
async fn admin_fleet_shows_provider_column() {
    // Fleet endpoint must include vm_provider for each deployment so the admin
    // dashboard can show provider info (AWS vs Hetzner).
    let customer_repo = mock_repo();
    let deployment_repo = mock_deployment_repo();
    let tenant = customer_repo.seed("Multi-Cloud Inc", "mc@example.com");

    // Create deployments across both providers
    deployment_repo.seed_provisioned(
        tenant.id,
        "node-aws-1",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
        Some("https://vm-aws.flapjack.foo"),
    );
    deployment_repo.seed_provisioned(
        tenant.id,
        "node-hetzner-1",
        "eu-central-1",
        "cpx32",
        "hetzner",
        "running",
        Some("https://vm-hetzner.flapjack.foo"),
    );

    let app = common::test_app_with_repos(customer_repo, deployment_repo);

    let req = Request::builder()
        .uri("/admin/fleet")
        .header("x-admin-key", TEST_ADMIN_KEY)
        .body(Body::empty())
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let json = body_json(resp).await;
    let arr = json.as_array().expect("response should be an array");
    assert_eq!(arr.len(), 2, "both deployments should be returned");

    // Every deployment must have a vm_provider field
    for deployment in arr {
        assert!(
            deployment.get("vm_provider").is_some(),
            "each deployment must include vm_provider field"
        );
        let provider = deployment["vm_provider"].as_str().unwrap();
        assert!(
            provider == "aws" || provider == "hetzner",
            "vm_provider should be 'aws' or 'hetzner', got '{provider}'"
        );
    }

    // Find the specific deployments and verify their provider
    let aws_dep = arr
        .iter()
        .find(|d| d["region"] == "us-east-1")
        .expect("AWS deployment should be present");
    assert_eq!(aws_dep["vm_provider"], "aws");

    let hetzner_dep = arr
        .iter()
        .find(|d| d["region"] == "eu-central-1")
        .expect("Hetzner deployment should be present");
    assert_eq!(hetzner_dep["vm_provider"], "hetzner");
}

// ===========================================================================
// §6 Test: object storage billed once with region multiplier in cross-region context
// ===========================================================================

#[tokio::test]
async fn estimate_object_storage_not_duplicated_across_regions() {
    // Customer has hot usage in TWO regions (eu-central-1 + us-east-1) plus
    // object storage. Object storage must appear once, attached to the
    // deterministic region (alphabetically first = eu-central-1), and receive
    // that region's 0.70× multiplier.
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("CrossRegion Corp", "xr@example.com");

    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(test_rate_card_with_hetzner_multipliers());

    let storage_bucket_repo = mock_storage_bucket_repo();
    let bucket = storage_bucket_repo
        .create(
            NewStorageBucket {
                customer_id: customer.id,
                name: "data-bucket".to_string(),
            },
            "grg-data-bucket",
        )
        .await
        .unwrap();
    // 10 GB stored, 10 GB egress, 0 watermark → all egress unbilled
    let ten_gb: i64 = 10 * 1_073_741_824;
    storage_bucket_repo
        .increment_size(bucket.id, ten_gb, 50)
        .await
        .unwrap();
    storage_bucket_repo
        .increment_egress(bucket.id, ten_gb)
        .await
        .unwrap();

    // Seed hot usage in both regions
    for day in 1..=28 {
        let date = NaiveDate::from_ymd_opt(2026, 2, day).unwrap();
        usage_repo.seed(customer.id, date, "eu-central-1", 1000, 0, 0, 0);
        usage_repo.seed(customer.id, date, "us-east-1", 1000, 0, 0, 0);
    }

    let app = api::router::build_router(
        TestStateBuilder::new()
            .with_customer_repo(customer_repo)
            .with_usage_repo(usage_repo)
            .with_rate_card_repo(rate_card_repo)
            .with_storage_bucket_repo(storage_bucket_repo)
            .build(),
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
    let line_items = body["line_items"].as_array().unwrap();

    // Object storage line items must appear exactly once each (not doubled for 2 regions)
    let obj_storage_items: Vec<_> = line_items
        .iter()
        .filter(|li| li["unit"] == "object_storage_gb_months")
        .collect();
    assert_eq!(
        obj_storage_items.len(),
        1,
        "object storage should appear once, got {}",
        obj_storage_items.len()
    );

    let obj_egress_items: Vec<_> = line_items
        .iter()
        .filter(|li| li["unit"] == "object_storage_egress_gb")
        .collect();
    assert_eq!(
        obj_egress_items.len(),
        1,
        "object storage egress should appear once, got {}",
        obj_egress_items.len()
    );

    // Object storage attached to deterministic region eu-central-1 (alphabetically first)
    assert_eq!(obj_storage_items[0]["region"], "eu-central-1");
    assert_eq!(obj_egress_items[0]["region"], "eu-central-1");

    // Object storage pricing: 10 GB × $0.024 × 0.70 × 100 = 16.8 → 17 cents
    assert_eq!(obj_storage_items[0]["amount_cents"], 17);

    // Object egress pricing: 10 GB × $0.01 × 0.70 × 100 = 7.0 → 7 cents
    assert_eq!(obj_egress_items[0]["amount_cents"], 7);
}
