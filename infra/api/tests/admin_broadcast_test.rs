mod common;

use std::collections::HashMap;
use std::sync::Arc;

use api::repos::PgCustomerRepo;
use api::services::email::EmailService;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, TimeZone, Utc};
use http_body_util::BodyExt;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

#[derive(Debug, sqlx::FromRow)]
struct EmailLogRow {
    recipient_email: String,
    delivery_status: String,
    error_message: Option<String>,
}

struct DbHarness {
    pool: PgPool,
    schema: String,
}

/// Connect to the integration test DB and apply migrations.
/// Returns None when DATABASE_URL is not set so the ignored tests can be
/// invoked locally without hard-failing by default.
async fn connect_and_migrate() -> Option<DbHarness> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping admin broadcast integration tests");
        return None;
    };

    let admin_pool = PgPool::connect(&url)
        .await
        .expect("connect to integration test DB");

    let schema = format!("it_admin_broadcast_{}", Uuid::new_v4().simple());
    sqlx::query(&format!("CREATE SCHEMA {schema}"))
        .execute(&admin_pool)
        .await
        .expect("create isolated schema for admin broadcast test");

    let pool = PgPoolOptions::new()
        .max_connections(1)
        .connect(&url)
        .await
        .expect("connect to integration test DB");
    sqlx::query(&format!("SET search_path TO {schema}"))
        .execute(&pool)
        .await
        .expect("set test schema search_path");

    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");

    Some(DbHarness { pool, schema })
}

fn unique_email(prefix: &str) -> String {
    format!("{prefix}-{}@broadcast-stage3.test", Uuid::new_v4())
}

fn unique_subject(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::new_v4())
}

async fn seed_customer(pool: &PgPool, name: &str, email: &str, created_at: DateTime<Utc>) {
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

async fn cleanup_schema(pool: &PgPool, schema: &str) {
    sqlx::query("SET search_path TO public")
        .execute(pool)
        .await
        .ok();

    sqlx::query(&format!("DROP SCHEMA IF EXISTS {schema} CASCADE"))
        .execute(pool)
        .await
        .ok();
}

async fn email_log_row_count(pool: &PgPool, subject: &str) -> i64 {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*)::BIGINT FROM email_log WHERE subject = $1")
        .bind(subject)
        .fetch_one(pool)
        .await
        .expect("count email_log rows")
}

async fn email_log_rows(pool: &PgPool, subject: &str) -> Vec<EmailLogRow> {
    sqlx::query_as::<_, EmailLogRow>(
        "SELECT recipient_email, delivery_status, error_message \
         FROM email_log WHERE subject = $1 ORDER BY recipient_email ASC",
    )
    .bind(subject)
    .fetch_all(pool)
    .await
    .expect("list email_log rows")
}

async fn response_json(response: axum::response::Response) -> serde_json::Value {
    let body = response
        .into_body()
        .collect()
        .await
        .expect("collect response body")
        .to_bytes();
    serde_json::from_slice(&body).expect("response body must be valid JSON")
}

fn build_broadcast_request(subject: &str, dry_run: bool) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/admin/broadcast")
        .header("content-type", "application/json")
        .header("x-admin-key", common::TEST_ADMIN_KEY)
        .body(Body::from(
            serde_json::json!({
                "subject": subject,
                "html_body": "<p>Stage 3 broadcast contract test</p>",
                "dry_run": dry_run,
            })
            .to_string(),
        ))
        .expect("build admin broadcast request")
}

fn build_db_backed_broadcast_app(
    pool: &PgPool,
    email_service: Arc<dyn EmailService>,
) -> axum::Router {
    let mut state = common::test_state();
    state.pool = pool.clone();
    state.customer_repo = Arc::new(PgCustomerRepo::new(pool.clone()));
    state.email_service = email_service;
    api::router::build_router(state)
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn dry_run_broadcast_writes_no_email_log_rows() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

    let email_a = unique_email("dry-run-a");
    let email_b = unique_email("dry-run-b");
    let subject = unique_subject("dry-run");

    seed_customer(&pool, "Dry Run A", &email_a, Utc::now()).await;
    seed_customer(&pool, "Dry Run B", &email_b, Utc::now()).await;

    let (failable_email_service, _delegate) = common::FailableEmailService::with_mock_delegate();
    let app = build_db_backed_broadcast_app(
        &pool,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let response = app
        .oneshot(build_broadcast_request(&subject, true))
        .await
        .expect("broadcast request should complete");
    let status = response.status();
    assert_eq!(status, StatusCode::OK);
    let response_body = response_json(response).await;

    let attempt_count = failable_email_service.attempt_count();
    let log_count = email_log_row_count(&pool, &subject).await;

    cleanup_schema(&pool, &db.schema).await;

    assert_eq!(
        attempt_count, 0,
        "dry-run broadcast must not call email delivery"
    );
    assert_eq!(
        log_count, 0,
        "dry-run broadcast must not persist email_log rows"
    );
    assert_eq!(
        response_body.get("mode"),
        Some(&serde_json::json!("dry_run"))
    );
    assert_eq!(
        response_body.get("subject"),
        Some(&serde_json::json!(subject))
    );
    assert_eq!(
        response_body.get("recipient_count"),
        Some(&serde_json::json!(2))
    );
    assert!(
        response_body.get("success_count").is_none()
            && response_body.get("suppressed_count").is_none()
            && response_body.get("failure_count").is_none(),
        "dry-run response schema must stay distinct from live-send schema"
    );
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn live_broadcast_logs_one_success_row_per_recipient() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

    let email_a = unique_email("live-success-a");
    let email_b = unique_email("live-success-b");
    let email_c = unique_email("live-success-c");
    let subject = unique_subject("live-success");

    let base = Utc
        .with_ymd_and_hms(2026, 1, 1, 0, 0, 0)
        .single()
        .expect("valid timestamp");

    seed_customer(&pool, "Live Success A", &email_a, base).await;
    seed_customer(
        &pool,
        "Live Success B",
        &email_b,
        base + chrono::Duration::seconds(1),
    )
    .await;
    seed_customer(
        &pool,
        "Live Success C",
        &email_c,
        base + chrono::Duration::seconds(2),
    )
    .await;

    let seeded_recipients = vec![email_a, email_b, email_c];

    let (failable_email_service, _delegate) = common::FailableEmailService::with_mock_delegate();
    let app = build_db_backed_broadcast_app(
        &pool,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let response = app
        .oneshot(build_broadcast_request(&subject, false))
        .await
        .expect("broadcast request should complete");
    let status = response.status();
    assert_eq!(status, StatusCode::OK);
    let response_body = response_json(response).await;

    let attempt_count = failable_email_service.attempt_count();
    let rows = email_log_rows(&pool, &subject).await;
    let mut logged_recipients: Vec<String> =
        rows.iter().map(|row| row.recipient_email.clone()).collect();
    logged_recipients.sort();

    let mut expected_recipients = seeded_recipients.clone();
    expected_recipients.sort();

    cleanup_schema(&pool, &db.schema).await;

    assert_eq!(
        attempt_count,
        expected_recipients.len(),
        "live broadcast must attempt one send per recipient"
    );
    assert_eq!(
        rows.len(),
        expected_recipients.len(),
        "live broadcast must persist one email_log row per recipient"
    );
    assert_eq!(
        logged_recipients, expected_recipients,
        "email_log rows must map 1:1 to attempted recipients"
    );
    assert_eq!(
        response_body.get("mode"),
        Some(&serde_json::json!("live_send"))
    );
    assert_eq!(
        response_body.get("subject"),
        Some(&serde_json::json!(subject))
    );
    assert_eq!(
        response_body.get("attempted_count"),
        Some(&serde_json::json!(expected_recipients.len()))
    );
    assert_eq!(
        response_body.get("success_count"),
        Some(&serde_json::json!(expected_recipients.len()))
    );
    assert_eq!(
        response_body.get("suppressed_count"),
        Some(&serde_json::json!(0))
    );
    assert_eq!(
        response_body.get("failure_count"),
        Some(&serde_json::json!(0))
    );
    assert!(
        response_body.get("recipient_count").is_none(),
        "live-send response schema must stay distinct from dry-run schema"
    );

    for row in rows {
        assert_eq!(
            row.delivery_status, "success",
            "successful sends must be persisted as success rows"
        );
        assert!(
            row.error_message.is_none(),
            "success rows must not store an error_message"
        );
    }
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn live_broadcast_partial_failure_logs_failed_rows_and_continues() {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

    let failing_email = unique_email("live-fail-0");
    let success_email_a = unique_email("live-fail-1");
    let success_email_b = unique_email("live-fail-2");
    let subject = unique_subject("live-partial-failure");

    let base = Utc
        .with_ymd_and_hms(2026, 2, 1, 0, 0, 0)
        .single()
        .expect("valid timestamp");

    // PgCustomerRepo::list orders by created_at DESC; make the failing recipient
    // newest so the test can prove the loop continues to later rows.
    seed_customer(
        &pool,
        "Failure First",
        &failing_email,
        base + chrono::Duration::seconds(2),
    )
    .await;
    seed_customer(
        &pool,
        "Success Second",
        &success_email_a,
        base + chrono::Duration::seconds(1),
    )
    .await;
    seed_customer(&pool, "Success Third", &success_email_b, base).await;

    let (failable_email_service, _delegate) = common::FailableEmailService::with_mock_delegate();
    failable_email_service.fail_recipient(&failing_email, "forced partial failure");

    let app = build_db_backed_broadcast_app(
        &pool,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let response = app
        .oneshot(build_broadcast_request(&subject, false))
        .await
        .expect("broadcast request should complete");
    let status = response.status();
    assert_eq!(status, StatusCode::OK);
    let response_body = response_json(response).await;

    let attempts = failable_email_service.attempted_recipients();
    let rows = email_log_rows(&pool, &subject).await;
    let raw_row_count = rows.len();
    let mut row_counts_by_recipient: HashMap<String, usize> = HashMap::new();
    for row in &rows {
        *row_counts_by_recipient
            .entry(row.recipient_email.clone())
            .or_insert(0) += 1;
    }
    let rows_by_recipient: HashMap<String, EmailLogRow> = rows
        .into_iter()
        .map(|row| (row.recipient_email.clone(), row))
        .collect();

    cleanup_schema(&pool, &db.schema).await;

    assert_eq!(
        attempts,
        vec![
            failing_email.clone(),
            success_email_a.clone(),
            success_email_b.clone(),
        ],
        "broadcast loop must continue to later recipients after a delivery failure"
    );
    assert_eq!(
        raw_row_count,
        attempts.len(),
        "email_log must persist one outcome row for each attempted recipient"
    );
    assert_eq!(
        row_counts_by_recipient.get(&failing_email).copied(),
        Some(1),
        "failing recipient must produce exactly one persisted outcome row"
    );
    for success_email in [&success_email_a, &success_email_b] {
        assert_eq!(
            row_counts_by_recipient.get(success_email).copied(),
            Some(1),
            "successful recipient must produce exactly one persisted outcome row"
        );
    }
    assert_eq!(
        row_counts_by_recipient.values().sum::<usize>(),
        attempts.len(),
        "email_log multiplicity accounting must match attempted recipient count"
    );
    assert_eq!(
        rows_by_recipient.len(),
        attempts.len(),
        "email_log rows must include each attempted recipient exactly once"
    );
    assert_eq!(
        response_body.get("mode"),
        Some(&serde_json::json!("live_send"))
    );
    assert_eq!(
        response_body.get("subject"),
        Some(&serde_json::json!(subject))
    );
    assert_eq!(
        response_body.get("attempted_count"),
        Some(&serde_json::json!(attempts.len()))
    );
    assert_eq!(
        response_body.get("success_count"),
        Some(&serde_json::json!(2))
    );
    assert_eq!(
        response_body.get("suppressed_count"),
        Some(&serde_json::json!(0))
    );
    assert_eq!(
        response_body.get("failure_count"),
        Some(&serde_json::json!(1))
    );
    assert!(
        response_body.get("recipient_count").is_none(),
        "live-send response schema must stay distinct from dry-run schema"
    );

    let failed_row = rows_by_recipient
        .get(&failing_email)
        .expect("failed recipient row should exist");
    assert_eq!(failed_row.delivery_status, "failed");
    assert_eq!(
        failed_row.error_message.as_deref(),
        Some("forced partial failure"),
        "failed rows must keep the delivery error"
    );

    for success_email in [&success_email_a, &success_email_b] {
        let row = rows_by_recipient
            .get(success_email)
            .expect("successful recipient row should exist");
        assert_eq!(
            row.delivery_status, "success",
            "non-failing recipients must be logged as success"
        );
        assert!(
            row.error_message.is_none(),
            "success rows must not include an error message"
        );
    }
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn live_broadcast_suppressed_recipient_logs_suppressed_and_keeps_failure_count_for_real_failures(
) {
    let Some(db) = connect_and_migrate().await else {
        return;
    };
    let pool = db.pool.clone();

    let suppressed_email = unique_email("live-suppressed-0");
    let success_email = unique_email("live-suppressed-1");
    let failed_email = unique_email("live-suppressed-2");
    let subject = unique_subject("live-suppressed-mixed");

    let base = Utc
        .with_ymd_and_hms(2026, 3, 1, 0, 0, 0)
        .single()
        .expect("valid timestamp");

    // Keep predictable send order via PgCustomerRepo::list created_at DESC.
    seed_customer(
        &pool,
        "Suppressed First",
        &suppressed_email,
        base + chrono::Duration::seconds(2),
    )
    .await;
    seed_customer(
        &pool,
        "Success Second",
        &success_email,
        base + chrono::Duration::seconds(1),
    )
    .await;
    seed_customer(&pool, "Failed Third", &failed_email, base).await;

    let (failable_email_service, _delegate) = common::FailableEmailService::with_mock_delegate();
    failable_email_service.suppress_recipient(&suppressed_email);
    failable_email_service.fail_recipient(&failed_email, "forced delivery failure");

    let app = build_db_backed_broadcast_app(
        &pool,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let response = app
        .oneshot(build_broadcast_request(&subject, false))
        .await
        .expect("broadcast request should complete");
    let status = response.status();
    assert_eq!(status, StatusCode::OK);
    let response_body = response_json(response).await;

    let attempts = failable_email_service.attempted_recipients();
    let rows = email_log_rows(&pool, &subject).await;
    let rows_by_recipient: HashMap<String, EmailLogRow> = rows
        .into_iter()
        .map(|row| (row.recipient_email.clone(), row))
        .collect();

    cleanup_schema(&pool, &db.schema).await;

    assert_eq!(
        attempts,
        vec![
            suppressed_email.clone(),
            success_email.clone(),
            failed_email.clone(),
        ],
        "broadcast loop must keep iterating after suppressed recipients"
    );
    assert_eq!(
        rows_by_recipient.len(),
        attempts.len(),
        "email_log must persist exactly one row per attempted recipient"
    );

    assert_eq!(
        response_body.get("attempted_count"),
        Some(&serde_json::json!(attempts.len()))
    );
    assert_eq!(
        response_body.get("success_count"),
        Some(&serde_json::json!(1)),
        "only true deliveries count as success"
    );
    assert_eq!(
        response_body.get("suppressed_count"),
        Some(&serde_json::json!(1)),
        "suppressed recipients must be reported separately"
    );
    assert_eq!(
        response_body.get("failure_count"),
        Some(&serde_json::json!(1)),
        "failure_count must only represent real delivery failures"
    );

    let suppressed_row = rows_by_recipient
        .get(&suppressed_email)
        .expect("suppressed recipient row should exist");
    assert_eq!(suppressed_row.delivery_status, "suppressed");
    assert!(
        suppressed_row.error_message.is_none(),
        "suppressed rows should not carry delivery error text"
    );

    let success_row = rows_by_recipient
        .get(&success_email)
        .expect("success recipient row should exist");
    assert_eq!(success_row.delivery_status, "success");
    assert!(
        success_row.error_message.is_none(),
        "success rows should not include error_message"
    );

    let failed_row = rows_by_recipient
        .get(&failed_email)
        .expect("failed recipient row should exist");
    assert_eq!(failed_row.delivery_status, "failed");
    assert_eq!(
        failed_row.error_message.as_deref(),
        Some("forced delivery failure")
    );
}
