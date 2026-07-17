#![allow(dead_code)]

use std::sync::Arc;

use api::repos::PgCustomerRepo;
use api::services::email::EmailService;
use axum::body::Body;
use axum::http::Request;
use chrono::{DateTime, Utc};
use http_body_util::BodyExt;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use uuid::Uuid;

use crate::common::support::pg_schema_harness::{self, DbHarness};

#[derive(Debug, sqlx::FromRow)]
pub struct EmailLogRow {
    pub recipient_email: String,
    pub delivery_status: String,
    pub error_message: Option<String>,
}

pub async fn connect_and_migrate() -> Option<DbHarness> {
    pg_schema_harness::connect_and_migrate("it_admin_broadcast").await
}

pub async fn cleanup_schema(pool: &PgPool, schema: &str) {
    pg_schema_harness::cleanup_schema(pool, schema).await;
}

pub async fn seed_customer(pool: &PgPool, name: &str, email: &str, created_at: DateTime<Utc>) {
    sqlx::query(
        "INSERT INTO customers (id, name, email, status, created_at, updated_at) \
         VALUES ($1, $2, $3, 'active', $4, $4)",
    )
    .bind(Uuid::new_v4())
    .bind(name)
    .bind(email)
    .bind(created_at)
    .execute(pool)
    .await
    .expect("seed customer");
}

pub async fn email_log_row_count(pool: &PgPool, subject: &str) -> i64 {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*)::BIGINT FROM email_log WHERE subject = $1")
        .bind(subject)
        .fetch_one(pool)
        .await
        .expect("count email_log rows")
}

pub async fn email_log_rows(pool: &PgPool, subject: &str) -> Vec<EmailLogRow> {
    sqlx::query_as::<_, EmailLogRow>(
        "SELECT recipient_email, delivery_status, error_message \
         FROM email_log WHERE subject = $1 ORDER BY recipient_email ASC",
    )
    .bind(subject)
    .fetch_all(pool)
    .await
    .expect("list email_log rows")
}

pub async fn response_json(response: axum::response::Response) -> serde_json::Value {
    let body = response
        .into_body()
        .collect()
        .await
        .expect("collect response body")
        .to_bytes();
    serde_json::from_slice(&body).expect("response body must be valid JSON")
}

pub fn assert_response_keys(response_body: &serde_json::Value, expected_keys: &[&str]) {
    let object = response_body
        .as_object()
        .expect("response body must be a JSON object");
    let mut actual_keys: Vec<&str> = object.keys().map(String::as_str).collect();
    actual_keys.sort_unstable();
    let mut expected_keys = expected_keys.to_vec();
    expected_keys.sort_unstable();
    assert_eq!(
        actual_keys, expected_keys,
        "admin broadcast response schema changed"
    );
}

pub fn build_broadcast_request(subject: &str, dry_run: bool) -> Request<Body> {
    build_broadcast_request_with_bodies(
        subject,
        Some("<p>Stage 3 broadcast contract test</p>"),
        None,
        dry_run,
    )
}

pub fn build_broadcast_request_with_bodies(
    subject: &str,
    html_body: Option<&str>,
    text_body: Option<&str>,
    dry_run: bool,
) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/admin/broadcast")
        .header("content-type", "application/json")
        .header("x-admin-key", crate::common::TEST_ADMIN_KEY)
        .body(Body::from(
            serde_json::json!({
                "subject": subject,
                "html_body": html_body,
                "text_body": text_body,
                "dry_run": dry_run,
            })
            .to_string(),
        ))
        .expect("build admin broadcast request")
}

pub fn build_db_backed_broadcast_app(
    pool: &PgPool,
    email_service: Arc<dyn EmailService>,
) -> axum::Router {
    let mut state = crate::common::test_state();
    state.pool = pool.clone();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    state.email_service = email_service;
    api::router::build_router(state)
}

pub fn build_mock_broadcast_app(
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    email_service: Arc<dyn EmailService>,
) -> axum::Router {
    let mut state = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_email_service(email_service)
        .build();
    state.pool = PgPoolOptions::new()
        .max_connections(1)
        .acquire_timeout(std::time::Duration::from_millis(1))
        .connect_lazy("postgres://test:test@127.0.0.1:1/test")
        .expect("connect_lazy should never fail");
    api::router::build_router(state)
}
