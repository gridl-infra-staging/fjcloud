use std::collections::HashMap;
use std::sync::Arc;

use api::services::email::{EmailService, MockEmailService};
use axum::http::StatusCode;
use chrono::{TimeZone, Utc};
use tokio::time::{Duration, Instant};
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::admin_broadcast_test_support::{
    assert_response_keys, build_broadcast_request, build_broadcast_request_with_bodies,
    build_db_backed_broadcast_app, build_mock_broadcast_app, cleanup_schema, connect_and_migrate,
    email_log_row_count, email_log_rows, response_json, seed_customer, EmailLogRow,
};

const MEASURED_STAGING_RECIPIENT_DENOMINATOR: usize = 55;
const CAPACITY_KAT_RECIPIENT_COUNT: usize = MEASURED_STAGING_RECIPIENT_DENOMINATOR;
const CAPACITY_KAT_PER_SEND_DELAY_MS: u64 = 20;
const CAPACITY_KAT_MAX_ELAPSED_MS: u64 = 500;

fn unique_email(prefix: &str) -> String {
    format!("{prefix}-{}@broadcast-stage3.test", Uuid::new_v4())
}

fn unique_subject(prefix: &str) -> String {
    format!("{prefix}-{}", Uuid::new_v4())
}

#[tokio::test]
async fn live_broadcast_capacity_guardrail_requires_bounded_concurrency() {
    let customer_repo = crate::common::mock_repo();
    let subject = "capacity-guardrail";
    for index in 0..CAPACITY_KAT_RECIPIENT_COUNT {
        customer_repo.seed(
            &format!("Capacity Recipient {index}"),
            &format!("capacity-recipient-{index}@broadcast-stage1.test"),
        );
    }

    let (failable_email_service, delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
    failable_email_service.set_broadcast_delay_ms(CAPACITY_KAT_PER_SEND_DELAY_MS);

    let app = build_mock_broadcast_app(
        customer_repo,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let started_at = Instant::now();
    let response = app
        .oneshot(build_broadcast_request_with_bodies(
            subject,
            Some("<p>capacity guardrail</p>"),
            Some("capacity guardrail"),
            false,
        ))
        .await
        .expect("broadcast request should complete");
    let elapsed = started_at.elapsed();
    assert_eq!(response.status(), StatusCode::OK);
    let response_body = response_json(response).await;

    assert_response_keys(
        &response_body,
        &[
            "attempted_count",
            "failure_count",
            "mode",
            "subject",
            "success_count",
            "suppressed_count",
        ],
    );
    assert_eq!(
        failable_email_service.attempt_count(),
        CAPACITY_KAT_RECIPIENT_COUNT,
        "capacity KAT must attempt exactly one send per measured recipient"
    );
    assert_eq!(
        delegate.sent_emails().len(),
        CAPACITY_KAT_RECIPIENT_COUNT,
        "capacity KAT delegate should observe one send per measured recipient"
    );
    assert_eq!(
        response_body.get("attempted_count"),
        Some(&serde_json::json!(CAPACITY_KAT_RECIPIENT_COUNT))
    );
    assert!(
        elapsed < Duration::from_millis(CAPACITY_KAT_MAX_ELAPSED_MS),
        "broadcast to {CAPACITY_KAT_RECIPIENT_COUNT} measured staging recipients with {CAPACITY_KAT_PER_SEND_DELAY_MS}ms/send took {elapsed:?}; this exceeds the bounded-concurrency guardrail of {CAPACITY_KAT_MAX_ELAPSED_MS}ms"
    );
}

#[tokio::test]
async fn live_broadcast_html_only_request_keeps_empty_text_part() {
    let customer_repo = crate::common::mock_repo();
    customer_repo.seed("Alice", "alice@example.com");
    customer_repo.seed("Bob", "bob@example.com");

    let delegate = Arc::new(MockEmailService::new());
    let failable_email_service = Arc::new(crate::common::FailableEmailService::new(
        delegate.clone() as Arc<dyn EmailService>,
    ));

    let app = crate::common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_email_service(failable_email_service as Arc<dyn EmailService>)
        .build_app();

    let response = app
        .oneshot(build_broadcast_request_with_bodies(
            "html-only-contract",
            Some("<p>HTML only path</p>"),
            None,
            false,
        ))
        .await
        .expect("broadcast request should complete");
    assert_eq!(response.status(), StatusCode::OK);

    let sent_emails = delegate.sent_emails();
    assert_eq!(sent_emails.len(), 2);
    for email in sent_emails {
        assert_eq!(email.subject, "html-only-contract");
        assert_eq!(email.html_body, "<p>HTML only path</p>");
        assert_eq!(email.text_body, "");
    }
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

    let (failable_email_service, _delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
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
    assert_response_keys(&response_body, &["mode", "recipient_count", "subject"]);
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

    let (failable_email_service, _delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
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
    assert_response_keys(
        &response_body,
        &[
            "attempted_count",
            "failure_count",
            "mode",
            "subject",
            "success_count",
            "suppressed_count",
        ],
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
async fn live_broadcast_invalid_request_returns_400_without_success_body_or_invalid_log() {
    let db = connect_and_migrate()
        .await
        .expect("DATABASE_URL must be set for the non-ignored invalid-request broadcast KAT");
    let pool = db.pool.clone();

    let valid_email = unique_email("live-invalid-0");
    let invalid_email = unique_email("live-invalid-1");
    let maybe_in_flight_email = unique_email("live-invalid-2");
    let subject = unique_subject("live-invalid-request");

    let base = Utc
        .with_ymd_and_hms(2026, 4, 1, 0, 0, 0)
        .single()
        .expect("valid timestamp");

    seed_customer(
        &pool,
        "Valid Before Invalid",
        &valid_email,
        base + chrono::Duration::seconds(2),
    )
    .await;
    seed_customer(
        &pool,
        "Invalid Second",
        &invalid_email,
        base + chrono::Duration::seconds(1),
    )
    .await;
    seed_customer(&pool, "Maybe In Flight", &maybe_in_flight_email, base).await;

    let (failable_email_service, _delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
    failable_email_service.set_broadcast_delay_ms(10);
    failable_email_service
        .invalidate_broadcast_recipient(&invalid_email, "forced invalid broadcast request");

    let app = build_db_backed_broadcast_app(
        &pool,
        failable_email_service.clone() as Arc<dyn EmailService>,
    );

    let response = app
        .oneshot(build_broadcast_request(&subject, false))
        .await
        .expect("broadcast request should complete");
    let status = response.status();
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let response_body = response_json(response).await;

    let attempts = failable_email_service.attempted_recipients();
    let invalid_observed_attempt_count = failable_email_service
        .invalid_request_observed_attempt_count()
        .expect("invalid request should be observed by the email double");
    let rows = email_log_rows(&pool, &subject).await;
    let raw_row_count = rows.len();
    let rows_by_recipient: HashMap<String, EmailLogRow> = rows
        .into_iter()
        .map(|row| (row.recipient_email.clone(), row))
        .collect();

    cleanup_schema(&pool, &db.schema).await;

    assert_eq!(
        attempts.len(),
        invalid_observed_attempt_count,
        "broadcast must not schedule new recipient work after InvalidRequest is observed"
    );
    assert!(
        attempts.contains(&invalid_email),
        "invalid recipient must be attempted so InvalidRequest can be observed"
    );
    assert_eq!(
        raw_row_count,
        rows_by_recipient.len(),
        "invalid-request abort path must not duplicate email_log rows"
    );
    assert!(
        rows_by_recipient
            .keys()
            .all(|recipient| attempts.contains(recipient)),
        "email_log rows must only exist for recipients whose send work was scheduled"
    );
    assert!(
        !rows_by_recipient.contains_key(&invalid_email),
        "invalid recipient must not produce an email_log row"
    );
    assert!(
        rows_by_recipient
            .get(&valid_email)
            .is_some_and(|row| row.delivery_status == "success"),
        "the non-invalid recipient completed before InvalidRequest should retain its success row"
    );
    assert!(
        response_body.get("mode").is_none()
            && response_body.get("attempted_count").is_none()
            && response_body.get("success_count").is_none()
            && response_body.get("suppressed_count").is_none()
            && response_body.get("failure_count").is_none(),
        "InvalidRequest response must not use the live-send success body"
    );
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

    let (failable_email_service, _delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
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

    let mut attempted_recipients = attempts.clone();
    attempted_recipients.sort();
    let mut expected_recipients = vec![
        failing_email.clone(),
        success_email_a.clone(),
        success_email_b.clone(),
    ];
    expected_recipients.sort();

    assert_eq!(
        attempted_recipients, expected_recipients,
        "broadcast must attempt every recipient after a delivery failure without relying on concurrent attempt order"
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
    assert_response_keys(
        &response_body,
        &[
            "attempted_count",
            "failure_count",
            "mode",
            "subject",
            "success_count",
            "suppressed_count",
        ],
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

    let (failable_email_service, _delegate) =
        crate::common::FailableEmailService::with_mock_delegate();
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
    let raw_row_count = rows.len();
    let rows_by_recipient: HashMap<String, EmailLogRow> = rows
        .into_iter()
        .map(|row| (row.recipient_email.clone(), row))
        .collect();

    cleanup_schema(&pool, &db.schema).await;

    let mut attempted_recipients = attempts.clone();
    attempted_recipients.sort();
    let mut expected_recipients = vec![
        suppressed_email.clone(),
        success_email.clone(),
        failed_email.clone(),
    ];
    expected_recipients.sort();

    assert_eq!(
        attempted_recipients, expected_recipients,
        "broadcast must attempt every recipient after suppressed recipients without relying on concurrent attempt order"
    );
    assert_eq!(
        raw_row_count,
        attempts.len(),
        "email_log must persist exactly one raw row per attempted recipient"
    );
    assert_eq!(
        rows_by_recipient.len(),
        attempts.len(),
        "email_log must persist exactly one row per attempted recipient"
    );

    assert_response_keys(
        &response_body,
        &[
            "attempted_count",
            "failure_count",
            "mode",
            "subject",
            "success_count",
            "suppressed_count",
        ],
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
