//! Live-DB admin audit route helpers shared by auth-admin integration tests.

use std::sync::Arc;

use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use http_body_util::BodyExt;
use sqlx::PgPool;
use uuid::Uuid;

pub async fn connect_shared_public_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set - skipping admin audit integration tests");
        return None;
    };

    let pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");
    if !table_exists(&pool, "customers").await {
        sqlx::migrate!("../migrations")
            .run(&pool)
            .await
            .expect("run migrations");
    }
    ensure_admin_users_contract(&pool).await;

    Some(pool)
}

async fn table_exists(pool: &PgPool, table_name: &str) -> bool {
    sqlx::query_scalar::<_, bool>("SELECT to_regclass($1) IS NOT NULL")
        .bind(format!("public.{table_name}"))
        .fetch_one(pool)
        .await
        .expect("check table existence")
}

async fn ensure_admin_users_contract(pool: &PgPool) {
    if table_exists(pool, "admin_users").await {
        return;
    }

    sqlx::query(
        "CREATE TABLE admin_users (
            id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            identifier          TEXT        NOT NULL UNIQUE,
            credential_prefix   TEXT        NOT NULL,
            credential_sha256   TEXT        NOT NULL UNIQUE,
            created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            revoked_at          TIMESTAMPTZ NULL
        )",
    )
    .execute(pool)
    .await
    .expect("create admin_users operator table for shared live-DB audit tests");

    sqlx::query(
        "CREATE INDEX idx_admin_users_credential_prefix
            ON admin_users(credential_prefix)",
    )
    .execute(pool)
    .await
    .expect("create admin_users credential-prefix index for shared live-DB audit tests");
}

pub fn app_with_live_audit_pool(
    pool: PgPool,
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    tenant_repo: Arc<crate::common::MockTenantRepo>,
    rate_card_repo: Arc<crate::common::MockRateCardRepo>,
    stripe_service: Arc<crate::common::MockStripeService>,
    usage_repo: Arc<crate::common::MockUsageRepo>,
    invoice_repo: Arc<crate::common::MockInvoiceRepo>,
) -> axum::Router {
    let state = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_tenant_repo(tenant_repo)
        .with_rate_card_repo(rate_card_repo)
        .with_stripe_service(stripe_service)
        .with_usage_repo(usage_repo)
        .with_invoice_repo(invoice_repo)
        .with_pool(pool)
        .build();
    api::router::build_router(state)
}

pub fn impersonation_app(
    pool: PgPool,
    customer_repo: Arc<crate::common::MockCustomerRepo>,
) -> axum::Router {
    app_with_live_audit_pool(
        pool,
        customer_repo,
        crate::common::mock_tenant_repo(),
        crate::common::mock_rate_card_repo(),
        crate::common::mock_stripe_service(),
        crate::common::mock_usage_repo(),
        crate::common::mock_invoice_repo(),
    )
}

pub async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, serde_json::Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body =
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body)
}

pub async fn audit_row_count(pool: &PgPool, action: &str, target: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(action)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("count audit rows")
}

pub async fn audit_row_count_for_target(pool: &PgPool, target: Uuid) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE target_tenant_id = $1",
    )
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("count audit rows for target")
}

pub async fn latest_metadata(pool: &PgPool, action: &str, target: Uuid) -> serde_json::Value {
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

pub async fn cleanup_target(pool: &PgPool, target: Uuid) {
    sqlx::query("DELETE FROM audit_log WHERE target_tenant_id = $1")
        .bind(target)
        .execute(pool)
        .await
        .ok();
}

/// Every `actor_id` written for one `(action, target)` pair. Returned
/// unordered on purpose - attribution assertions compare sets, so two rows
/// landing inside the same `NOW()` tick cannot make the test flaky.
pub async fn actor_ids_for_action_and_target(
    pool: &PgPool,
    action: &str,
    target: Uuid,
) -> Vec<Uuid> {
    sqlx::query_scalar::<_, Uuid>(
        "SELECT actor_id FROM audit_log WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(action)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("read audit actor ids")
}

pub async fn latest_actor_id(pool: &PgPool, action: &str, target: Uuid) -> Uuid {
    sqlx::query_scalar::<_, Uuid>(
        "SELECT actor_id FROM audit_log \
         WHERE action = $1 AND target_tenant_id = $2 \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(action)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("read the newest audit actor id")
}

/// `POST /admin/tokens` signed with an explicit admin credential.
pub fn admin_token_request_with_key(
    admin_key: &str,
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
        .header("x-admin-key", admin_key)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::Value::Object(payload).to_string()))
        .expect("build admin token request")
}

pub fn admin_token_request(
    customer_id: Uuid,
    expires_in_secs: Option<u64>,
    purpose: Option<&str>,
) -> Request<Body> {
    admin_token_request_with_key(
        crate::common::TEST_ADMIN_KEY,
        customer_id,
        expires_in_secs,
        purpose,
    )
}

/// `to_regclass` probe, so an absent `admin_users` is a clean boolean instead
/// of a raw `relation ... does not exist` SQL panic.
pub async fn admin_users_table_exists(pool: &PgPool) -> bool {
    sqlx::query_scalar::<_, Option<String>>("SELECT to_regclass('admin_users')::text")
        .fetch_one(pool)
        .await
        .expect("probe for the admin_users operator table")
        .is_some()
}

pub async fn require_admin_users_contract(pool: &PgPool) {
    assert!(
        admin_users_table_exists(pool).await,
        "operator-identity contract unmet: there is no `admin_users` table, so \
         persisted admin credentials cannot resolve to individual operators. \
         This assertion is the Stage 1 red pin for FJ-R-AUTHZ-01."
    );
}

pub fn credential_sha256_hex(credential: &str) -> String {
    use sha2::{Digest, Sha256};

    let mut hasher = Sha256::new();
    hasher.update(credential.as_bytes());
    hex::encode(hasher.finalize())
}

pub async fn register_operator(pool: &PgPool, identifier: &str) -> (Uuid, String) {
    let credential = format!("fjop_{}", Uuid::new_v4().simple());
    let operator_id = register_operator_with_credential(pool, identifier, &credential).await;
    (operator_id, credential)
}

pub async fn register_operator_with_credential(
    pool: &PgPool,
    identifier: &str,
    credential: &str,
) -> Uuid {
    assert!(
        credential.len() >= api::auth::admin::ADMIN_CREDENTIAL_PREFIX_LENGTH,
        "test operator credentials must satisfy the admin-credential prefix floor"
    );
    let operator_id = Uuid::new_v4();
    let credential_prefix = &credential[..api::auth::admin::ADMIN_CREDENTIAL_PREFIX_LENGTH];

    sqlx::query(
        "INSERT INTO admin_users \
             (id, identifier, credential_prefix, credential_sha256, created_at, revoked_at) \
         VALUES ($1, $2, $3, $4, NOW(), NULL)",
    )
    .bind(operator_id)
    .bind(identifier)
    .bind(credential_prefix)
    .bind(credential_sha256_hex(credential))
    .execute(pool)
    .await
    .expect("register a test operator in admin_users");

    operator_id
}

pub async fn revoke_operator(pool: &PgPool, operator_id: Uuid) {
    let revoked = sqlx::query("UPDATE admin_users SET revoked_at = NOW() WHERE id = $1")
        .bind(operator_id)
        .execute(pool)
        .await
        .expect("revoke a test operator")
        .rows_affected();
    assert_eq!(
        revoked, 1,
        "revocation must update exactly the target operator"
    );
}

pub async fn admin_users_row_count(pool: &PgPool) -> i64 {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*)::BIGINT FROM admin_users")
        .fetch_one(pool)
        .await
        .expect("count admin_users rows")
}

pub async fn sole_admin_user_id(pool: &PgPool) -> Uuid {
    sqlx::query_scalar::<_, Uuid>("SELECT id FROM admin_users")
        .fetch_one(pool)
        .await
        .expect("read the single admin_users row")
}

pub async fn sole_admin_user_identifier(pool: &PgPool) -> String {
    sqlx::query_scalar::<_, String>("SELECT identifier FROM admin_users")
        .fetch_one(pool)
        .await
        .expect("read the single admin_users identifier")
}

pub async fn credential_is_registered(pool: &PgPool, credential: &str) -> bool {
    sqlx::query_scalar::<_, bool>(
        "SELECT EXISTS(SELECT 1 FROM admin_users WHERE credential_sha256 = $1)",
    )
    .bind(credential_sha256_hex(credential))
    .fetch_one(pool)
    .await
    .expect("check whether a credential is registered")
}
