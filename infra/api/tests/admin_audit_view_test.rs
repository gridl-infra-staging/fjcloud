//! Stage 1 admin audit coverage for high-trust admin mutations.
//!
//! These are ignored live-DB regressions. They drive admin HTTP handlers with
//! mock repos/services while using a real Postgres pool for `audit_log` writes,
//! so we can assert the route-level audit behavior end-to-end.

mod common;

use std::sync::Arc;

use api::models::RateCardRow;
use api::repos::{CustomerRepo, InvoiceRepo, TenantRepo};
use api::services::audit_log::{
    ACTION_CUSTOMER_REACTIVATED, ACTION_CUSTOMER_SUSPENDED, ACTION_IMPERSONATION_TOKEN_CREATED,
    ACTION_QUOTAS_UPDATED, ACTION_RATE_CARD_OVERRIDE, ACTION_STRIPE_SYNC, ACTION_TENANT_CREATED,
    ACTION_TENANT_DELETED, ACTION_TENANT_UPDATED,
};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use chrono::Utc;
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

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

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping admin audit view integration tests");
        return None;
    };

    let pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");

    Some(pool)
}

fn app_with_live_audit_pool(
    pool: PgPool,
    customer_repo: Arc<common::MockCustomerRepo>,
    tenant_repo: Arc<common::MockTenantRepo>,
    rate_card_repo: Arc<common::MockRateCardRepo>,
    stripe_service: Arc<common::MockStripeService>,
    usage_repo: Arc<common::MockUsageRepo>,
    invoice_repo: Arc<common::MockInvoiceRepo>,
) -> axum::Router {
    let mut state = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_tenant_repo(tenant_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_service)
        .with_usage_repo(usage_repo)
        .with_invoice_repo(invoice_repo)
        .build();

    state.pool = pool;
    api::router::build_router(state)
}

async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, serde_json::Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body =
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body)
}

async fn audit_row_count(pool: &PgPool, action: &str, target: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(action)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("count audit rows")
}

async fn audit_row_count_for_target(pool: &PgPool, target: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE target_tenant_id = $1",
    )
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("count audit rows for target")
}

async fn latest_metadata(pool: &PgPool, action: &str, target: Uuid) -> serde_json::Value {
    sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT metadata FROM audit_log \
         WHERE action = $1 AND target_tenant_id = $2 \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(action)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("fetch latest audit metadata")
}

async fn cleanup_target(pool: &PgPool, target: Uuid) {
    sqlx::query("DELETE FROM audit_log WHERE target_tenant_id = $1")
        .bind(target)
        .execute(pool)
        .await
        .ok();
}

async fn seed_audit_row_with_created_at(
    pool: &PgPool,
    target: Uuid,
    action: &str,
    metadata: serde_json::Value,
    created_at_rfc3339: &str,
) {
    sqlx::query(
        "INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata, created_at) \
         VALUES ($1, $2, $3, $4, $5::timestamptz)",
    )
    .bind(Uuid::nil())
    .bind(action)
    .bind(target)
    .bind(metadata)
    .bind(created_at_rfc3339)
    .execute(pool)
    .await
    .expect("seed audit row");
}

fn admin_token_request(
    customer_id: Uuid,
    expires_in_secs: Option<u64>,
    purpose: Option<&str>,
) -> Request<Body> {
    let mut payload = serde_json::Map::new();
    payload.insert("customer_id".into(), serde_json::json!(customer_id));
    if let Some(expires_in_secs) = expires_in_secs {
        payload.insert("expires_in_secs".into(), serde_json::json!(expires_in_secs));
    }
    if let Some(purpose) = purpose {
        payload.insert("purpose".into(), serde_json::json!(purpose));
    }

    Request::builder()
        .method(Method::POST)
        .uri("/admin/tokens")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::Value::Object(payload).to_string()))
        .expect("build admin token request")
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tenants_writes_tenant_created_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let app = app_with_live_audit_pool(
        pool.clone(),
        common::mock_repo(),
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/admin/tenants")
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "Audit Create",
                        "email": "audit-create@example.com"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::CREATED);

    let tenant_id = Uuid::parse_str(body["id"].as_str().expect("id string")).expect("uuid id");

    assert_eq!(
        audit_row_count(&pool, ACTION_TENANT_CREATED, tenant_id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_TENANT_CREATED, tenant_id).await;
    assert_eq!(metadata["tenant_id"], tenant_id.to_string());
    assert_eq!(metadata["name"], "Audit Create");
    assert_eq!(metadata["email"], "audit-create@example.com");

    cleanup_target(&pool, tenant_id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn put_admin_tenants_id_writes_tenant_updated_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Before", "before@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::PUT)
                .uri(format!("/admin/tenants/{}", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "name": "After",
                        "email": "after@example.com",
                        "billing_plan": "shared"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        audit_row_count(&pool, ACTION_TENANT_UPDATED, customer.id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_TENANT_UPDATED, customer.id).await;
    assert_eq!(
        metadata["changed"],
        serde_json::json!(["name", "email", "billing_plan"])
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn delete_admin_tenants_id_writes_tenant_deleted_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Delete Me", "delete-me@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/admin/tenants/{}", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::NO_CONTENT);
    assert_eq!(
        audit_row_count(&pool, ACTION_TENANT_DELETED, customer.id).await,
        1
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_customers_sync_stripe_writes_stripe_sync_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Stripe User", "stripe-user@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("/admin/customers/{}/sync-stripe", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    let stripe_customer_id = body["stripe_customer_id"]
        .as_str()
        .expect("stripe customer id")
        .to_string();

    assert_eq!(
        audit_row_count(&pool, ACTION_STRIPE_SYNC, customer.id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_STRIPE_SYNC, customer.id).await;
    assert_eq!(metadata["stripe_customer_id"], stripe_customer_id);

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_customers_suspend_writes_customer_suspended_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Suspend User", "suspend-user@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("/admin/customers/{}/suspend", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        audit_row_count(&pool, ACTION_CUSTOMER_SUSPENDED, customer.id).await,
        1
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_customers_reactivate_writes_customer_reactivated_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Reactivate User", "reactivate-user@example.com");
    customer_repo
        .suspend(customer.id)
        .await
        .expect("suspend seeded customer");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(format!("/admin/customers/{}/reactivate", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        audit_row_count(&pool, ACTION_CUSTOMER_REACTIVATED, customer.id).await,
        1
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn put_admin_tenants_rate_card_writes_rate_card_override_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Rate User", "rate-user@example.com");
    let rate_card_repo = common::mock_rate_card_repo();
    rate_card_repo.seed_active_card(sample_rate_card());

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        rate_card_repo,
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::PUT)
                .uri(format!("/admin/tenants/{}/rate-card", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "storage_rate_per_mb_month": "0.30",
                        "shared_minimum_spend_cents": 240
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        audit_row_count(&pool, ACTION_RATE_CARD_OVERRIDE, customer.id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_RATE_CARD_OVERRIDE, customer.id).await;
    assert_eq!(
        metadata["override_field_keys"],
        serde_json::json!(["shared_minimum_spend_cents", "storage_rate_per_mb_month"])
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn put_admin_tenants_quotas_writes_quotas_updated_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Quota User", "quota-user@example.com");
    let tenant_repo = common::mock_tenant_repo();

    tenant_repo
        .create(customer.id, "alpha-index", Uuid::new_v4())
        .await
        .expect("seed tenant alpha");
    tenant_repo
        .create(customer.id, "beta-index", Uuid::new_v4())
        .await
        .expect("seed tenant beta");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        tenant_repo,
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::PUT)
                .uri(format!("/admin/tenants/{}/quotas", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "max_query_rps": 21,
                        "max_storage_bytes": 12345
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);

    assert_eq!(
        audit_row_count(&pool, ACTION_QUOTAS_UPDATED, customer.id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_QUOTAS_UPDATED, customer.id).await;
    assert_eq!(
        metadata["quota_keys"],
        serde_json::json!(["max_query_rps", "max_storage_bytes"])
    );

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn put_admin_tenants_quotas_skips_audit_when_customer_has_no_tenant_rows() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("No Tenant Rows", "no-tenant-rows@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::PUT)
                .uri(format!("/admin/tenants/{}/quotas", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "max_query_rps": 42
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, _body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 0);

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_with_impersonation_purpose_writes_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Impersonation Target", "impersonation@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(admin_token_request(
            customer.id,
            Some(30),
            Some("impersonation"),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert!(body["token"].as_str().is_some());
    assert!(body["expires_at"].as_str().is_some());
    assert_eq!(
        audit_row_count(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await,
        1
    );

    let metadata = latest_metadata(&pool, ACTION_IMPERSONATION_TOKEN_CREATED, customer.id).await;
    assert_eq!(metadata["duration_secs"], 60);

    cleanup_target(&pool, customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_with_invalid_purpose_returns_bad_request_without_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Invalid Purpose", "invalid-purpose@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(admin_token_request(
            customer.id,
            Some(120),
            Some("impersonatoin"),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(
        body["error"],
        "invalid purpose 'impersonatoin'; expected one of: admin, impersonation"
    );
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 0);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_for_missing_customer_returns_not_found_without_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let missing_customer_id = Uuid::new_v4();

    let app = app_with_live_audit_pool(
        pool.clone(),
        common::mock_repo(),
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(admin_token_request(
            missing_customer_id,
            Some(120),
            Some("impersonation"),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    assert_eq!(body["error"], "customer not found");
    assert_eq!(
        audit_row_count_for_target(&pool, missing_customer_id).await,
        0
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn post_admin_tokens_for_suspended_customer_returns_forbidden_without_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Suspended Target", "suspended-target@example.com");
    customer_repo
        .suspend(customer.id)
        .await
        .expect("suspend seeded customer");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(admin_token_request(
            customer.id,
            Some(120),
            Some("impersonation"),
        ))
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::FORBIDDEN);
    assert_eq!(body["error"], "customer is suspended");
    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 0);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn get_admin_tenants_id_is_negative_control_without_audit_row() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let customer = customer_repo.seed("Read Only", "read-only@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(format!("/admin/tenants/{}", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["id"], customer.id.to_string());

    assert_eq!(audit_row_count_for_target(&pool, customer.id).await, 0);
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn get_admin_customers_id_audit_returns_requested_customer_rows_newest_first() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let target_customer = customer_repo.seed("Audit Target", "audit-target@example.com");
    let other_customer = customer_repo.seed("Audit Other", "audit-other@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        common::mock_usage_repo(),
        common::mock_invoice_repo(),
    );

    seed_audit_row_with_created_at(
        &pool,
        target_customer.id,
        ACTION_CUSTOMER_SUSPENDED,
        serde_json::json!({ "order": "oldest-target" }),
        "2026-01-01T00:00:00Z",
    )
    .await;
    seed_audit_row_with_created_at(
        &pool,
        other_customer.id,
        ACTION_CUSTOMER_SUSPENDED,
        serde_json::json!({ "order": "other-customer" }),
        "2026-01-02T00:00:00Z",
    )
    .await;
    seed_audit_row_with_created_at(
        &pool,
        target_customer.id,
        ACTION_CUSTOMER_REACTIVATED,
        serde_json::json!({ "order": "middle-target" }),
        "2026-01-03T00:00:00Z",
    )
    .await;
    seed_audit_row_with_created_at(
        &pool,
        target_customer.id,
        ACTION_STRIPE_SYNC,
        serde_json::json!({ "order": "newest-target" }),
        "2026-01-04T00:00:00Z",
    )
    .await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(format!("/admin/customers/{}/audit", target_customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    let rows = body.as_array().expect("audit rows array");
    assert_eq!(rows.len(), 3);
    assert!(rows
        .iter()
        .all(|row| row["target_tenant_id"] == target_customer.id.to_string()));
    assert_eq!(rows[0]["action"], ACTION_STRIPE_SYNC);
    assert_eq!(rows[0]["metadata"]["order"], "newest-target");
    assert_eq!(rows[1]["action"], ACTION_CUSTOMER_REACTIVATED);
    assert_eq!(rows[1]["metadata"]["order"], "middle-target");
    assert_eq!(rows[2]["action"], ACTION_CUSTOMER_SUSPENDED);
    assert_eq!(rows[2]["metadata"]["order"], "oldest-target");

    cleanup_target(&pool, target_customer.id).await;
    cleanup_target(&pool, other_customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn get_admin_customers_id_snapshot_returns_seeded_customer_snapshot() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let usage_repo = common::mock_usage_repo();
    let invoice_repo = common::mock_invoice_repo();
    let target_customer = customer_repo.seed("Snapshot Target", "snapshot-target@example.com");
    let other_customer = customer_repo.seed("Snapshot Other", "snapshot-other@example.com");
    let today = Utc::now().date_naive();

    usage_repo.seed(
        target_customer.id,
        today - chrono::Duration::days(1),
        "us-east-1",
        40,
        5,
        billing::types::BYTES_PER_GIB * 2,
        900,
    );
    usage_repo.seed(
        target_customer.id,
        today,
        "us-west-2",
        60,
        7,
        billing::types::BYTES_PER_GIB,
        1100,
    );
    usage_repo.seed(
        other_customer.id,
        today,
        "us-east-1",
        999,
        999,
        billing::types::BYTES_PER_GIB,
        9999,
    );

    let draft_invoice = invoice_repo.seed(
        target_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 1, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 1, 31).expect("valid date"),
        100,
        100,
        false,
        vec![],
    );
    let finalized_invoice = invoice_repo.seed(
        target_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 2, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 2, 28).expect("valid date"),
        200,
        200,
        false,
        vec![],
    );
    invoice_repo
        .finalize(finalized_invoice.id)
        .await
        .expect("finalize seeded invoice");

    let failed_invoice = invoice_repo.seed(
        target_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 3, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 3, 31).expect("valid date"),
        300,
        300,
        false,
        vec![],
    );
    invoice_repo
        .finalize(failed_invoice.id)
        .await
        .expect("finalize seeded invoice before mark_failed");
    invoice_repo
        .mark_failed(failed_invoice.id)
        .await
        .expect("mark seeded invoice failed");

    let paid_invoice = invoice_repo.seed(
        target_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 4, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 4, 30).expect("valid date"),
        400,
        400,
        false,
        vec![],
    );
    invoice_repo
        .finalize(paid_invoice.id)
        .await
        .expect("finalize seeded invoice before mark_paid");
    invoice_repo
        .mark_paid(paid_invoice.id)
        .await
        .expect("mark seeded invoice paid");

    let refunded_invoice = invoice_repo.seed(
        target_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 5, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 5, 31).expect("valid date"),
        500,
        500,
        false,
        vec![],
    );
    invoice_repo
        .finalize(refunded_invoice.id)
        .await
        .expect("finalize seeded invoice before mark_refunded");
    invoice_repo
        .mark_paid(refunded_invoice.id)
        .await
        .expect("mark seeded invoice paid before mark_refunded");
    invoice_repo
        .mark_refunded(refunded_invoice.id)
        .await
        .expect("mark seeded invoice refunded");

    invoice_repo.seed(
        other_customer.id,
        chrono::NaiveDate::from_ymd_opt(2026, 6, 1).expect("valid date"),
        chrono::NaiveDate::from_ymd_opt(2026, 6, 30).expect("valid date"),
        600,
        600,
        false,
        vec![],
    );

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        usage_repo,
        invoice_repo,
    );

    seed_audit_row_with_created_at(
        &pool,
        target_customer.id,
        ACTION_CUSTOMER_SUSPENDED,
        serde_json::json!({ "order": "oldest-target" }),
        "2026-01-01T00:00:00Z",
    )
    .await;
    seed_audit_row_with_created_at(
        &pool,
        other_customer.id,
        ACTION_CUSTOMER_SUSPENDED,
        serde_json::json!({ "order": "other-customer" }),
        "2026-01-02T00:00:00Z",
    )
    .await;
    seed_audit_row_with_created_at(
        &pool,
        target_customer.id,
        ACTION_STRIPE_SYNC,
        serde_json::json!({ "order": "newest-target" }),
        "2026-01-03T00:00:00Z",
    )
    .await;

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(format!("/admin/customers/{}/snapshot", target_customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["usage_summary"],
        serde_json::json!({
            "total_search_requests": 100,
            "total_write_operations": 12,
            "avg_storage_gb": 1.5,
            "avg_document_count": 1000
        })
    );

    let open_invoices = body["open_invoices"]
        .as_array()
        .expect("open invoices array");
    assert_eq!(open_invoices.len(), 3);
    assert_eq!(open_invoices[0]["status"], "failed");
    assert_eq!(open_invoices[1]["status"], "finalized");
    assert_eq!(open_invoices[2]["status"], "draft");
    assert!(open_invoices
        .iter()
        .all(|row| row["status"] != "paid" && row["status"] != "refunded"));
    assert_eq!(open_invoices[0]["id"], failed_invoice.id.to_string());
    assert_eq!(open_invoices[1]["id"], finalized_invoice.id.to_string());
    assert_eq!(open_invoices[2]["id"], draft_invoice.id.to_string());

    let audit_rows = body["recent_audit"].as_array().expect("recent_audit array");
    assert_eq!(audit_rows.len(), 2);
    assert_eq!(audit_rows[0]["action"], ACTION_STRIPE_SYNC);
    assert_eq!(audit_rows[0]["metadata"]["order"], "newest-target");
    assert_eq!(audit_rows[1]["action"], ACTION_CUSTOMER_SUSPENDED);
    assert_eq!(audit_rows[1]["metadata"]["order"], "oldest-target");

    assert!(body.get("recent_alerts").is_none());

    cleanup_target(&pool, target_customer.id).await;
    cleanup_target(&pool, other_customer.id).await;
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn get_admin_customers_id_snapshot_returns_empty_snapshot_for_customer_without_data() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };

    let customer_repo = common::mock_repo();
    let usage_repo = common::mock_usage_repo();
    let invoice_repo = common::mock_invoice_repo();
    let customer = customer_repo.seed("Snapshot Empty", "snapshot-empty@example.com");

    let app = app_with_live_audit_pool(
        pool.clone(),
        customer_repo,
        common::mock_tenant_repo(),
        common::mock_rate_card_repo(),
        common::mock_stripe_service(),
        usage_repo,
        invoice_repo,
    );

    let resp = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri(format!("/admin/customers/{}/snapshot", customer.id))
                .header("x-admin-key", common::TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    let (status, body) = response_json(resp).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        body["usage_summary"],
        serde_json::json!({
            "total_search_requests": 0,
            "total_write_operations": 0,
            "avg_storage_gb": 0.0,
            "avg_document_count": 0
        })
    );
    assert_eq!(body["open_invoices"], serde_json::json!([]));
    assert_eq!(body["recent_audit"], serde_json::json!([]));
    assert!(body.get("recent_alerts").is_none());

    cleanup_target(&pool, customer.id).await;
}
