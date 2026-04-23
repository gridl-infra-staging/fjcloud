mod common;

use api::models::{CustomerRateOverrideRow, RateCardRow};
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::Utc;
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    mock_deployment_repo, mock_rate_card_repo, mock_repo, mock_usage_repo, test_app_full,
    TEST_ADMIN_KEY,
};

fn sample_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "launch-2026".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.200000),
        region_multipliers: serde_json::json!({"eu-west-1": "1.3"}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.020000),
        object_storage_rate_per_gb_month: dec!(0.024000),
        object_storage_egress_rate_per_gb: dec!(0.010000),
        created_at: Utc::now(),
    }
}

// ---------------------------------------------------------------------------
// GET /admin/tenants/:id/rate-card
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_rate_card_200_base_card_no_override() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card.clone());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["id"], card.id.to_string());
    assert_eq!(body["name"], "launch-2026");
    assert_eq!(body["storage_rate_per_mb_month"], "0.200000");
    assert_eq!(body["cold_storage_rate_per_gb_month"], "0.020000");
    assert_eq!(body["object_storage_rate_per_gb_month"], "0.024000");
    assert_eq!(body["object_storage_egress_rate_per_gb"], "0.010000");
    assert_eq!(body["minimum_spend_cents"], 500);
    assert_eq!(body["shared_minimum_spend_cents"], 200);
    assert_eq!(body["has_override"], false);
    assert_eq!(body["override_fields"], serde_json::json!({}));

    // region_multipliers should come through
    let multipliers = body["region_multipliers"].as_object().unwrap();
    assert!(multipliers.contains_key("eu-west-1"));
}

#[tokio::test]
async fn get_rate_card_200_with_override() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card.clone());

    // Seed an override for this customer
    let override_json = serde_json::json!({
        "storage_rate_per_mb_month": "0.300000",
        "shared_minimum_spend_cents": 240
    });
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer.id,
        rate_card_id: card.id,
        overrides: override_json,
        created_at: Utc::now(),
    });

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["has_override"], true);
    // The overridden field should reflect the new value
    assert_eq!(body["storage_rate_per_mb_month"], "0.300000");
    assert_eq!(body["shared_minimum_spend_cents"], 240);
    // Non-overridden fields keep base values
    assert_eq!(body["cold_storage_rate_per_gb_month"], "0.020000");
    // override_fields should contain the override
    assert!(body["override_fields"]["storage_rate_per_mb_month"].is_string());
    assert_eq!(body["override_fields"]["shared_minimum_spend_cents"], 240);
}

#[tokio::test]
async fn get_rate_card_404_unknown_tenant() {
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/rate-card", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn get_rate_card_404_no_active_rate_card() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // No rate card seeded
    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// PUT /admin/tenants/:id/rate-card
// ---------------------------------------------------------------------------

#[tokio::test]
async fn set_rate_override_200_creates_new() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.30"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["has_override"], true);
    assert_eq!(body["storage_rate_per_mb_month"], "0.30");
    // Base values preserved
    assert_eq!(body["cold_storage_rate_per_gb_month"], "0.020000");
}

#[tokio::test]
async fn set_rate_override_200_updates_existing() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    let card = sample_rate_card();
    rate_card_repo.seed_active_card(card.clone());

    // Seed existing override
    rate_card_repo.seed_override(CustomerRateOverrideRow {
        customer_id: customer.id,
        rate_card_id: card.id,
        overrides: serde_json::json!({"storage_rate_per_mb_month": "0.25"}),
        created_at: Utc::now(),
    });

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.05"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["has_override"], true);
    // The upsert replaces the override entirely with the new storage override payload.
    assert_eq!(body["storage_rate_per_mb_month"], "0.05");
    // Non-overridden fields stay at base values.
    assert_eq!(body["minimum_spend_cents"], 500);
}

#[tokio::test]
async fn set_rate_override_200_supports_cold_and_minimum_fields() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "cold_storage_rate_per_gb_month": "0.015000",
                        "minimum_spend_cents": 150,
                        "shared_minimum_spend_cents": 120
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["cold_storage_rate_per_gb_month"], "0.015000");
    assert_eq!(body["minimum_spend_cents"], 150);
    assert_eq!(body["shared_minimum_spend_cents"], 120);
    assert_eq!(
        body["override_fields"]["cold_storage_rate_per_gb_month"],
        "0.015000"
    );
    assert_eq!(body["override_fields"]["minimum_spend_cents"], 150);
    assert_eq!(body["override_fields"]["shared_minimum_spend_cents"], 120);
}

#[tokio::test]
async fn set_rate_override_200_supports_shared_minimum_field_only() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "shared_minimum_spend_cents": 120
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["minimum_spend_cents"], 500);
    assert_eq!(body["shared_minimum_spend_cents"], 120);
    assert_eq!(body["override_fields"]["shared_minimum_spend_cents"], 120);
}

#[tokio::test]
async fn set_rate_override_400_empty_body() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["error"], "no fields to update");
}

#[tokio::test]
async fn set_rate_override_400_invalid_decimal() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "not-a-number"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn set_rate_override_404_unknown_tenant() {
    let rate_card_repo = mock_rate_card_repo();
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        mock_repo(),
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", Uuid::new_v4()))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.30"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn set_rate_override_401_missing_auth() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.30"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::UNAUTHORIZED);
}

// ---------------------------------------------------------------------------
// MT-08: GET /admin/tenants/:id/rate-card 404 for deleted tenant
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_rate_card_404_deleted_tenant() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::get(format!("/admin/tenants/{}/rate-card", deleted.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// PUT /admin/tenants/:id/rate-card 404 when no active rate card exists
// ---------------------------------------------------------------------------

#[tokio::test]
async fn set_rate_override_404_no_active_rate_card() {
    let customer_repo = mock_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");

    // No rate card seeded
    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.30"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// MT-09: PUT /admin/tenants/:id/rate-card 404 for deleted tenant
// ---------------------------------------------------------------------------

#[tokio::test]
async fn set_rate_override_404_deleted_tenant() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let deleted = customer_repo.seed_deleted("Gone Corp", "gone@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", deleted.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "storage_rate_per_mb_month": "0.30"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NOT_FOUND);
}

// ---------------------------------------------------------------------------
// Object storage rate card fields
// ---------------------------------------------------------------------------

#[tokio::test]
async fn set_rate_override_200_supports_object_storage_fields() {
    let customer_repo = mock_repo();
    let rate_card_repo = mock_rate_card_repo();
    let customer = customer_repo.seed("Acme", "acme@example.com");
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = test_app_full(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        rate_card_repo,
    );

    let resp = app
        .oneshot(
            Request::put(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::to_string(&serde_json::json!({
                        "object_storage_rate_per_gb_month": "0.050000",
                        "object_storage_egress_rate_per_gb": "0.020000"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body: serde_json::Value =
        serde_json::from_slice(&resp.into_body().collect().await.unwrap().to_bytes()).unwrap();

    assert_eq!(body["object_storage_rate_per_gb_month"], "0.050000");
    assert_eq!(body["object_storage_egress_rate_per_gb"], "0.020000");
    assert_eq!(
        body["override_fields"]["object_storage_rate_per_gb_month"],
        "0.050000"
    );
    assert_eq!(
        body["override_fields"]["object_storage_egress_rate_per_gb"],
        "0.020000"
    );
    // Other fields unchanged
    assert_eq!(body["storage_rate_per_mb_month"], "0.200000");
    assert_eq!(body["cold_storage_rate_per_gb_month"], "0.020000");
}
