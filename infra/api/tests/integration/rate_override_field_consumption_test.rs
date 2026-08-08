use super::billing_regression_test::{
    create_bucket, generate_invoice, generate_invoice_with_shared_inputs, increment_bucket_egress,
    increment_bucket_size, seed_constant_daily_usage, setup_repos, MockRepos,
};
use crate::common::{mock_deployment_repo, mock_repo, test_app_full, TEST_ADMIN_KEY};
use api::invoicing::{GeneratedInvoice, SharedBillingData};
use api::models::cold_snapshot::ColdSnapshot;
use api::models::customer::BillingPlan;
use api::repos::RateCardRepo;
use api::routes::admin::rate_cards::SetRateOverrideRequest;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use billing::types::BYTES_PER_GIB;
use chrono::{TimeZone, Utc};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use serde_json::{json, Value};
use tower::ServiceExt;
use uuid::Uuid;

// Any SetRateOverrideRequest field addition must update this pin in the same commit.
const CANDIDATE_OVERRIDE_KEYS: [&str; 7] = [
    "storage_rate_per_mb_month",
    "cold_storage_rate_per_gb_month",
    "object_storage_rate_per_gb_month",
    "object_storage_egress_rate_per_gb",
    "shared_minimum_spend_cents",
    "region_multipliers",
    "minimum_spend_cents",
];

fn candidate_value(key: &str) -> Value {
    match key {
        "storage_rate_per_mb_month"
        | "cold_storage_rate_per_gb_month"
        | "object_storage_rate_per_gb_month"
        | "object_storage_egress_rate_per_gb" => json!("0.10"),
        "shared_minimum_spend_cents" => json!(1500),
        "region_multipliers" => json!({"eu-central-1": "0.70"}),
        "minimum_spend_cents" => json!(1500),
        other => panic!("missing candidate value for {other}"),
    }
}

async fn persist_customer_override_request(
    mocks: &MockRepos,
    request_json: Value,
) -> (Uuid, api::models::RateCardRow) {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Rate Override Invoice", "rate-override@example.com");
    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mocks.usage_repo.clone(),
        mocks.rate_card_repo.clone(),
    );

    let response = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(request_json.to_string()))
                .expect("rate override request should build"),
        )
        .await
        .expect("rate override request should complete");
    let status = response.status();
    let response_body = response
        .into_body()
        .collect()
        .await
        .expect("rate override response body should collect")
        .to_bytes();
    assert_eq!(
        status,
        StatusCode::OK,
        "rate override request failed: {}",
        String::from_utf8_lossy(&response_body)
    );

    let active_card = mocks
        .rate_card_repo
        .get_active()
        .await
        .expect("get_active should succeed")
        .expect("active card should exist");
    let persisted_override = mocks
        .rate_card_repo
        .get_override(customer.id, active_card.id)
        .await
        .expect("get_override should succeed")
        .expect("request conversion should persist an override");
    assert_eq!(
        persisted_override.overrides, request_json,
        "persisted override must match the accepted request fields"
    );

    active_card
        .with_overrides(&persisted_override.overrides)
        .expect("the persisted request override should apply to the active card");
    (customer.id, active_card)
}

fn assert_invoice_cents(
    invoice: &GeneratedInvoice,
    expected_subtotal_cents: i64,
    expected_total_cents: i64,
    context: &str,
) {
    assert_eq!(
        invoice.subtotal_cents, expected_subtotal_cents,
        "{context}: subtotal_cents mismatch"
    );
    assert_eq!(
        invoice.total_cents, expected_total_cents,
        "{context}: total_cents mismatch"
    );
}

fn completed_cold_snapshot(customer_id: Uuid, gb: i64) -> ColdSnapshot {
    ColdSnapshot {
        id: Uuid::new_v4(),
        customer_id,
        tenant_id: "rate-override-field-consumption".to_string(),
        source_vm_id: Uuid::new_v4(),
        object_key: "snapshots/rate-override-field-consumption.tar.zst".to_string(),
        size_bytes: gb * BYTES_PER_GIB,
        checksum: None,
        status: "completed".to_string(),
        error: None,
        created_at: Utc.with_ymd_and_hms(2026, 2, 1, 0, 0, 0).unwrap(),
        completed_at: Some(Utc.with_ymd_and_hms(2026, 2, 10, 12, 0, 0).unwrap()),
        expires_at: None,
    }
}

#[test]
fn rate_override_field_consumption_request_surface_rejects_dead_minimum_spend_knob() {
    let empty_request = serde_json::from_value::<SetRateOverrideRequest>(json!({}))
        .expect("an empty rate override request should deserialize");
    let SetRateOverrideRequest {
        storage_rate_per_mb_month: _,
        cold_storage_rate_per_gb_month: _,
        object_storage_rate_per_gb_month: _,
        object_storage_egress_rate_per_gb: _,
        shared_minimum_spend_cents: _,
        region_multipliers: _,
    } = empty_request;

    assert_eq!(
        CANDIDATE_OVERRIDE_KEYS.len(),
        7,
        "candidate denominator must stay pinned to seven fields"
    );

    for key in CANDIDATE_OVERRIDE_KEYS {
        let result = serde_json::from_value::<SetRateOverrideRequest>(json!({
            (key): candidate_value(key),
        }));

        if key == "minimum_spend_cents" {
            assert!(
                result.is_err(),
                "minimum_spend_cents must not be accepted by SetRateOverrideRequest"
            );
        } else {
            assert!(
                result.is_ok(),
                "{key} must be accepted by SetRateOverrideRequest: {result:?}"
            );
        }
    }
}

#[tokio::test]
async fn rate_override_field_consumption_storage_rate_per_mb_month_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    seed_constant_daily_usage(
        &baseline_mocks.usage_repo,
        baseline_customer,
        1000,
        "us-east-1",
    );

    let baseline_invoice =
        generate_invoice(&baseline_mocks, baseline_customer, BillingPlan::Free).await;
    // 1000 MB-months * $0.05/MB-month * 100 = 5000 cents.
    assert_invoice_cents(&baseline_invoice, 5000, 5000, "baseline hot storage");

    let override_mocks = setup_repos();
    let (override_customer, _) = persist_customer_override_request(
        &override_mocks,
        json!({"storage_rate_per_mb_month": "0.10"}),
    )
    .await;
    seed_constant_daily_usage(
        &override_mocks.usage_repo,
        override_customer,
        1000,
        "us-east-1",
    );

    let override_invoice =
        generate_invoice(&override_mocks, override_customer, BillingPlan::Free).await;
    // 1000 MB-months * $0.10/MB-month * 100 = 10000 cents.
    assert_invoice_cents(&override_invoice, 10000, 10000, "override hot storage");
}

#[tokio::test]
async fn rate_override_field_consumption_cold_storage_rate_per_gb_month_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    let baseline_card = baseline_mocks
        .rate_card_repo
        .get_active()
        .await
        .expect("get_active should succeed")
        .expect("active card should exist");
    let baseline_snapshot = completed_cold_snapshot(baseline_customer, 1000);
    let baseline_shared = SharedBillingData {
        base_card: &baseline_card,
        cold_snapshots: &[baseline_snapshot],
        storage_buckets: &[],
    };

    let baseline_invoice = generate_invoice_with_shared_inputs(
        &baseline_mocks,
        &baseline_shared,
        baseline_customer,
        dec!(0),
    )
    .await;
    // 1000 GB-months * $0.02/GB-month * 100 = 2000 cents.
    assert_invoice_cents(&baseline_invoice, 2000, 2000, "baseline cold storage");

    let override_mocks = setup_repos();
    let (override_customer, override_card) = persist_customer_override_request(
        &override_mocks,
        json!({"cold_storage_rate_per_gb_month": "0.03"}),
    )
    .await;
    let override_snapshot = completed_cold_snapshot(override_customer, 1000);
    let override_shared = SharedBillingData {
        base_card: &override_card,
        cold_snapshots: &[override_snapshot],
        storage_buckets: &[],
    };

    let override_invoice = generate_invoice_with_shared_inputs(
        &override_mocks,
        &override_shared,
        override_customer,
        dec!(0),
    )
    .await;
    // 1000 GB-months * $0.03/GB-month * 100 = 3000 cents.
    assert_invoice_cents(&override_invoice, 3000, 3000, "override cold storage");
}

#[tokio::test]
async fn rate_override_field_consumption_object_storage_rate_per_gb_month_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    let baseline_bucket = create_bucket(
        &baseline_mocks,
        baseline_customer,
        "baseline-object-storage",
        "garage-baseline-object-storage",
    )
    .await;
    increment_bucket_size(&baseline_mocks, baseline_bucket, 1000 * BYTES_PER_GIB).await;

    let baseline_invoice =
        generate_invoice(&baseline_mocks, baseline_customer, BillingPlan::Free).await;
    // 1000 GB-months * $0.024/GB-month * 100 = 2400 cents.
    assert_invoice_cents(&baseline_invoice, 2400, 2400, "baseline object storage");

    let override_mocks = setup_repos();
    let (override_customer, _) = persist_customer_override_request(
        &override_mocks,
        json!({"object_storage_rate_per_gb_month": "0.048"}),
    )
    .await;
    let override_bucket = create_bucket(
        &override_mocks,
        override_customer,
        "override-object-storage",
        "garage-override-object-storage",
    )
    .await;
    increment_bucket_size(&override_mocks, override_bucket, 1000 * BYTES_PER_GIB).await;

    let override_invoice =
        generate_invoice(&override_mocks, override_customer, BillingPlan::Free).await;
    // 1000 GB-months * $0.048/GB-month * 100 = 4800 cents.
    assert_invoice_cents(&override_invoice, 4800, 4800, "override object storage");
}

#[tokio::test]
async fn rate_override_field_consumption_object_storage_egress_rate_per_gb_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    let baseline_bucket = create_bucket(
        &baseline_mocks,
        baseline_customer,
        "baseline-object-egress",
        "garage-baseline-object-egress",
    )
    .await;
    increment_bucket_egress(&baseline_mocks, baseline_bucket, 1000 * BYTES_PER_GIB).await;

    let baseline_invoice =
        generate_invoice(&baseline_mocks, baseline_customer, BillingPlan::Free).await;
    // 1000 GB egress * $0.01/GB * 100 = 1000 cents.
    assert_invoice_cents(&baseline_invoice, 1000, 1000, "baseline object egress");

    let override_mocks = setup_repos();
    let (override_customer, _) = persist_customer_override_request(
        &override_mocks,
        json!({"object_storage_egress_rate_per_gb": "0.02"}),
    )
    .await;
    let override_bucket = create_bucket(
        &override_mocks,
        override_customer,
        "override-object-egress",
        "garage-override-object-egress",
    )
    .await;
    increment_bucket_egress(&override_mocks, override_bucket, 1000 * BYTES_PER_GIB).await;

    let override_invoice =
        generate_invoice(&override_mocks, override_customer, BillingPlan::Free).await;
    // 1000 GB egress * $0.02/GB * 100 = 2000 cents.
    assert_invoice_cents(&override_invoice, 2000, 2000, "override object egress");
}

#[tokio::test]
async fn rate_override_field_consumption_region_multipliers_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    seed_constant_daily_usage(
        &baseline_mocks.usage_repo,
        baseline_customer,
        1000,
        "eu-central-1",
    );

    let baseline_invoice =
        generate_invoice(&baseline_mocks, baseline_customer, BillingPlan::Free).await;
    // 1000 MB-months * $0.05/MB-month * 1.00 * 100 = 5000 cents.
    assert_invoice_cents(&baseline_invoice, 5000, 5000, "baseline region multiplier");

    let override_mocks = setup_repos();
    let (override_customer, _) = persist_customer_override_request(
        &override_mocks,
        json!({"region_multipliers": {"eu-central-1": "0.70"}}),
    )
    .await;
    seed_constant_daily_usage(
        &override_mocks.usage_repo,
        override_customer,
        1000,
        "eu-central-1",
    );

    let override_invoice =
        generate_invoice(&override_mocks, override_customer, BillingPlan::Free).await;
    // 1000 MB-months * $0.05/MB-month * 0.70 * 100 = 3500 cents.
    assert_invoice_cents(&override_invoice, 3500, 3500, "override region multiplier");
}

#[tokio::test]
async fn rate_override_field_consumption_shared_minimum_spend_cents_reaches_invoice_total() {
    let baseline_mocks = setup_repos();
    let baseline_customer = Uuid::new_v4();
    seed_constant_daily_usage(
        &baseline_mocks.usage_repo,
        baseline_customer,
        50,
        "us-east-1",
    );

    let baseline_invoice =
        generate_invoice(&baseline_mocks, baseline_customer, BillingPlan::Shared).await;
    // 50 MB-months * $0.05/MB-month * 100 = 250 cents, clamped to 1500 cents.
    assert_invoice_cents(&baseline_invoice, 250, 1500, "baseline shared minimum");

    let override_mocks = setup_repos();
    let (override_customer, _) = persist_customer_override_request(
        &override_mocks,
        json!({"shared_minimum_spend_cents": 2500}),
    )
    .await;
    seed_constant_daily_usage(
        &override_mocks.usage_repo,
        override_customer,
        50,
        "us-east-1",
    );

    let override_invoice =
        generate_invoice(&override_mocks, override_customer, BillingPlan::Shared).await;
    // 50 MB-months * $0.05/MB-month * 100 = 250 cents, clamped to 2500 cents.
    assert_invoice_cents(&override_invoice, 250, 2500, "override shared minimum");
}
