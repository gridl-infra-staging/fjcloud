//! Live-DB admin audit route helpers shared by auth-admin integration tests.

use std::sync::Arc;

use axum::body::{Body, Bytes};
use axum::http::{Method, Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::Value;
use sqlx::PgPool;
use uuid::Uuid;

use api::repos::{PgCustomerRepo, PgRateCardRepo};

use crate::common::support::pg_schema_harness::{self, DbHarness};

pub async fn connect_isolated_and_migrate(schema_prefix: &str) -> DbHarness {
    pg_schema_harness::connect_and_migrate_required(schema_prefix).await
}

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

pub fn app_with_pg_customer_repo(pool: PgPool) -> axum::Router {
    let mut state = crate::common::TestStateBuilder::new()
        .with_pool(pool.clone())
        .build();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool));
    api::router::build_router(state)
}

pub fn app_with_pg_customer_and_rate_card_repos(pool: PgPool) -> axum::Router {
    let mut state = crate::common::TestStateBuilder::new()
        .with_pool(pool.clone())
        .build();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    state.rate_card_repo = Arc::new(PgRateCardRepo::new(pool));
    api::router::build_router(state)
}

pub async fn response_json(resp: axum::http::Response<Body>) -> (StatusCode, serde_json::Value) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body =
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body)
}

pub async fn response_status_json_and_bytes(
    resp: axum::http::Response<Body>,
) -> (StatusCode, serde_json::Value, Bytes) {
    let status = resp.status();
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    let body =
        serde_json::from_slice::<serde_json::Value>(&bytes).unwrap_or(serde_json::Value::Null);
    (status, body, bytes)
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

pub async fn audit_row_count_for_action_and_nullable_target(
    pool: &PgPool,
    action: &str,
    target: Option<Uuid>,
) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT COUNT(*)::BIGINT FROM audit_log \
         WHERE action = $1 AND target_tenant_id IS NOT DISTINCT FROM $2",
    )
    .bind(action)
    .bind(target)
    .fetch_one(pool)
    .await
    .expect("count audit rows for nullable target")
}

#[derive(Debug, sqlx::FromRow)]
pub struct AuditRecord {
    pub actor_id: Uuid,
    pub action: String,
    pub target_tenant_id: Option<Uuid>,
    pub metadata: Value,
}

pub async fn audit_rows_for_action_and_nullable_target(
    pool: &PgPool,
    action: &str,
    target: Option<Uuid>,
) -> Vec<AuditRecord> {
    sqlx::query_as::<_, AuditRecord>(
        "SELECT actor_id, action, target_tenant_id, metadata \
         FROM audit_log \
         WHERE action = $1 AND target_tenant_id IS NOT DISTINCT FROM $2 \
         ORDER BY created_at, id",
    )
    .bind(action)
    .bind(target)
    .fetch_all(pool)
    .await
    .expect("fetch audit rows for nullable target")
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

pub async fn customer_status(pool: &PgPool, customer_id: Uuid) -> Option<String> {
    sqlx::query_scalar::<_, String>("SELECT status FROM customers WHERE id = $1")
        .bind(customer_id)
        .fetch_optional(pool)
        .await
        .expect("read customer status")
}

pub async fn create_active_customer(pool: &PgPool, label: &str) -> Uuid {
    let customer_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customers (id, name, email, status) \
         VALUES ($1, $2, $3, 'active')",
    )
    .bind(customer_id)
    .bind(label)
    .bind(format!(
        "{}-{}@audit-transactional.test",
        label.to_ascii_lowercase().replace(' ', "-"),
        Uuid::new_v4()
    ))
    .execute(pool)
    .await
    .expect("insert active customer");
    customer_id
}

pub async fn create_soft_deleted_customer(pool: &PgPool, label: &str) -> Uuid {
    let customer_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, deleted_at) \
         VALUES ($1, $2, $3, 'deleted', NOW())",
    )
    .bind(customer_id)
    .bind(label)
    .bind(format!(
        "{}-{}@audit-transactional.test",
        label.to_ascii_lowercase().replace(' ', "-"),
        Uuid::new_v4()
    ))
    .execute(pool)
    .await
    .expect("insert soft-deleted customer");
    customer_id
}

pub async fn seed_api_key_for_customer(pool: &PgPool, customer_id: Uuid) -> Uuid {
    let api_key_id = Uuid::new_v4();
    sqlx::query(
        "INSERT INTO api_keys (id, customer_id, name, key_prefix, key_hash, scopes) \
         VALUES ($1, $2, 'audit transactional key', $3, $4, ARRAY['read']::text[])",
    )
    .bind(api_key_id)
    .bind(customer_id)
    .bind(format!("atk_{}", Uuid::new_v4().simple()))
    .bind(format!("hash_{}", Uuid::new_v4().simple()))
    .execute(pool)
    .await
    .expect("insert dependent api_key");
    api_key_id
}

pub async fn row_count_for_customer_id(pool: &PgPool, table: &str, customer_id: Uuid) -> i64 {
    assert!(
        table
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
        "table name must be a simple identifier"
    );
    sqlx::query_scalar::<_, i64>(&format!(
        "SELECT COUNT(*)::BIGINT FROM {table} WHERE customer_id = $1"
    ))
    .bind(customer_id)
    .fetch_one(pool)
    .await
    .expect("count rows for customer_id")
}

pub async fn insert_prior_target_audit_row(pool: &PgPool, actor_id: Uuid, target: Uuid) {
    sqlx::query(
        "INSERT INTO audit_log (actor_id, action, target_tenant_id, metadata) \
         VALUES ($1, 'prior_target_bound_event', $2, '{\"prior\": true}'::jsonb)",
    )
    .bind(actor_id)
    .bind(target)
    .execute(pool)
    .await
    .expect("insert prior target-bound audit row");
}

pub async fn install_scoped_audit_failure_trigger(
    pool: &PgPool,
    action: &str,
    actor_id: Uuid,
    target: Option<Uuid>,
) {
    assert!(
        action
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_'),
        "audit action must be a simple identifier"
    );
    let suffix = Uuid::new_v4().simple().to_string();
    let function_name = format!("fail_audit_insert_{suffix}");
    let trigger_name = format!("trg_fail_audit_insert_{suffix}");
    let target_predicate = match target {
        Some(target) => format!("NEW.target_tenant_id = '{target}'::uuid"),
        None => "NEW.target_tenant_id IS NULL".to_string(),
    };
    let function_sql = format!(
        "CREATE FUNCTION {function_name}() RETURNS trigger AS $$ \
         BEGIN \
             IF NEW.action = '{action}' \
                AND NEW.actor_id = '{actor_id}'::uuid \
                AND {target_predicate} THEN \
                 RAISE EXCEPTION 'scoped audit insert failure for transactional test'; \
             END IF; \
             RETURN NEW; \
         END; \
         $$ LANGUAGE plpgsql;"
    );
    sqlx::query(&function_sql)
        .execute(pool)
        .await
        .expect("install scoped audit failure function");

    let trigger_sql = format!(
        "CREATE TRIGGER {trigger_name} \
         BEFORE INSERT ON audit_log \
         FOR EACH ROW EXECUTE FUNCTION {function_name}();"
    );
    sqlx::query(&trigger_sql)
        .execute(pool)
        .await
        .expect("install scoped audit failure trigger");
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

pub fn admin_token_request_with_session(
    session_id: &str,
    customer_id: Uuid,
    expires_in_secs: Option<u64>,
    purpose: Option<&str>,
) -> Request<Body> {
    let mut request = admin_token_request_with_key("", customer_id, expires_in_secs, purpose);
    request.headers_mut().remove("x-admin-key");
    request.headers_mut().insert(
        "x-admin-session",
        session_id.parse().expect("valid session header"),
    );
    request
}

pub fn admin_token_request_with_key_and_session(
    admin_key: &str,
    session_id: &str,
    customer_id: Uuid,
) -> Request<Body> {
    let mut request = admin_token_request_with_key(admin_key, customer_id, Some(30), None);
    request.headers_mut().insert(
        "x-admin-session",
        session_id.parse().expect("valid session header"),
    );
    request
}

pub fn admin_session_login_request_with_key(
    admin_key: &str,
    max_age_seconds: Option<u64>,
) -> Request<Body> {
    let mut payload = serde_json::Map::new();
    if let Some(max_age_seconds) = max_age_seconds {
        payload.insert("max_age_seconds".into(), serde_json::json!(max_age_seconds));
    }

    Request::builder()
        .method(Method::POST)
        .uri("/admin/sessions")
        .header("x-admin-key", admin_key)
        .header("content-type", "application/json")
        .body(Body::from(serde_json::Value::Object(payload).to_string()))
        .expect("build admin session login request")
}

pub async fn latest_admin_session_record_id_for_operator(pool: &PgPool, operator_id: Uuid) -> Uuid {
    sqlx::query_scalar::<_, Uuid>(
        "SELECT id FROM admin_sessions \
         WHERE admin_user_id = $1 \
         ORDER BY created_at DESC LIMIT 1",
    )
    .bind(operator_id)
    .fetch_one(pool)
    .await
    .expect("read newest durable admin session record for operator")
}

pub async fn backdate_admin_session_last_activity(
    pool: &PgPool,
    session_record_id: Uuid,
    age_seconds: i64,
) {
    let updated = sqlx::query(
        "UPDATE admin_sessions \
         SET last_activity_at = NOW() - make_interval(secs => $2::double precision) \
         WHERE id = $1",
    )
    .bind(session_record_id)
    .bind(age_seconds)
    .execute(pool)
    .await
    .expect("backdate durable admin session activity")
    .rows_affected();
    assert_eq!(
        updated, 1,
        "activity setup must update exactly one durable session record"
    );
}

pub async fn expire_admin_session(pool: &PgPool, session_record_id: Uuid) {
    let updated = sqlx::query(
        "UPDATE admin_sessions SET expires_at = NOW() - INTERVAL '1 second' WHERE id = $1",
    )
    .bind(session_record_id)
    .execute(pool)
    .await
    .expect("expire durable admin session")
    .rows_affected();
    assert_eq!(
        updated, 1,
        "expiry setup must update exactly one durable session record"
    );
}

pub async fn admin_session_absolute_lifetime_seconds(
    pool: &PgPool,
    session_record_id: Uuid,
) -> i64 {
    sqlx::query_scalar::<_, i64>(
        "SELECT EXTRACT(EPOCH FROM (expires_at - created_at))::BIGINT \
         FROM admin_sessions WHERE id = $1",
    )
    .bind(session_record_id)
    .fetch_one(pool)
    .await
    .expect("read durable admin session absolute lifetime")
}

pub async fn admin_session_secret_sha256(pool: &PgPool, session_record_id: Uuid) -> String {
    sqlx::query_scalar("SELECT secret_sha256 FROM admin_sessions WHERE id = $1")
        .bind(session_record_id)
        .fetch_one(pool)
        .await
        .expect("read durable admin session secret hash")
}

pub async fn set_admin_session_secret_sha256(
    pool: &PgPool,
    session_record_id: Uuid,
    secret_sha256: &str,
) {
    let updated = sqlx::query("UPDATE admin_sessions SET secret_sha256 = $2 WHERE id = $1")
        .bind(session_record_id)
        .bind(secret_sha256)
        .execute(pool)
        .await
        .expect("replace durable admin session secret hash")
        .rows_affected();
    assert_eq!(updated, 1, "hash setup must update exactly one session");
}

pub async fn admin_session_last_activity(
    pool: &PgPool,
    session_record_id: Uuid,
) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar("SELECT last_activity_at FROM admin_sessions WHERE id = $1")
        .bind(session_record_id)
        .fetch_one(pool)
        .await
        .expect("read durable admin session activity")
}

/// Non-destructive `GET /admin/sessions/current` probe. `session_id: None`
/// omits the credential header entirely so the absent-session arm is covered.
pub fn admin_session_current_request(session_id: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder()
        .method(Method::GET)
        .uri("/admin/sessions/current");
    if let Some(session_id) = session_id {
        builder = builder.header("x-admin-session", session_id);
    }
    builder
        .body(Body::empty())
        .expect("build current admin session validation request")
}

pub fn admin_session_current_request_with_key(admin_key: &str) -> Request<Body> {
    Request::builder()
        .method(Method::GET)
        .uri("/admin/sessions/current")
        .header("x-admin-key", admin_key)
        .body(Body::empty())
        .expect("build current admin session validation request with admin key")
}

pub fn admin_session_revoke_current_request(session_id: &str) -> Request<Body> {
    Request::builder()
        .method(Method::DELETE)
        .uri("/admin/sessions/current")
        .header("x-admin-session", session_id)
        .body(Body::empty())
        .expect("build current admin session revocation request")
}

pub fn admin_session_revoke_all_request(session_id: &str) -> Request<Body> {
    Request::builder()
        .method(Method::DELETE)
        .uri("/admin/sessions")
        .header("x-admin-session", session_id)
        .body(Body::empty())
        .expect("build all admin session revocation request")
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
