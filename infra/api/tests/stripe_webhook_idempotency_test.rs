mod common;

use std::sync::Arc;

use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::webhook_event_repo::WebhookEventRow;
use api::repos::CustomerRepo;
use axum::http::StatusCode;
use chrono::{NaiveDate, Utc};
use rust_decimal_macros::dec;
use tokio::time::{timeout, Duration};
use tower::ServiceExt;

use common::stripe_webhook_test_support::{mock_stripe_webhook_app, webhook_request};
use common::{mock_invoice_repo, mock_repo, mock_stripe_service, mock_webhook_event_repo};

fn seed_draft_invoice(
    repo: &common::MockInvoiceRepo,
    customer_id: uuid::Uuid,
) -> api::models::InvoiceRow {
    repo.seed(
        customer_id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        5000,
        5000,
        false,
        vec![NewLineItem {
            description: "Search requests".to_string(),
            quantity: dec!(1000),
            unit: "requests_1k".to_string(),
            unit_price_cents: dec!(5),
            amount_cents: 5000,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    )
}

#[tokio::test]
async fn replayed_invoice_event_is_processed_once() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "idempotent@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_idempotent_success",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_idempotent_success","type":"invoice.payment_succeeded","data":{"object":{"id":"in_idempotent_success"}}}"#;
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let second = app.clone().oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(second.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "paid");
}

#[tokio::test]
async fn seeded_unprocessed_invoice_event_short_circuits_without_handler_side_effects() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "seeded-unprocessed@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_seeded_unprocessed",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    webhook_event_repo.seed_row(WebhookEventRow {
        stripe_event_id: "evt_seeded_unprocessed".to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "id": "evt_seeded_unprocessed",
            "type": "invoice.payment_succeeded",
            "data": {"object": {"id": "in_seeded_unprocessed"}}
        }),
        processed_at: None,
        created_at: Utc::now(),
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_seeded_unprocessed","type":"invoice.payment_succeeded","data":{"object":{"id":"in_seeded_unprocessed"}}}"#;
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let second = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(first.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(second.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_seeded_unprocessed"),
        Some(false),
        "existing unprocessed rows must stay retryable instead of being acknowledged as completed duplicates"
    );
    assert_eq!(
        invoice_repo.mark_paid_call_count(),
        0,
        "seeded unprocessed duplicates must not re-enter handler side effects"
    );

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(
        updated.status, "finalized",
        "seeded unprocessed duplicate should not transition invoice state"
    );
}

#[tokio::test]
async fn retry_after_first_handler_failure_stays_unprocessed_and_not_acknowledged() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "retry-unprocessed@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_retry_unprocessed",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    invoice_repo.fail_next_mark_paid();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_retry_unprocessed","type":"invoice.payment_succeeded","data":{"object":{"id":"in_retry_unprocessed"}}}"#;
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let second = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(first.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(
        second.status(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "retry for an unprocessed event must not be acknowledged as completed"
    );
    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_retry_unprocessed"),
        Some(false),
        "event should remain unprocessed after handler failure"
    );
    assert_eq!(
        invoice_repo.mark_paid_call_count(),
        0,
        "injected failure happens before mark_paid increments call count; retry must not execute handler again"
    );
}

#[tokio::test]
async fn replayed_subscription_event_is_noop_once() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "sub-idempotent@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_idempotent")
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_idempotent_sub","type":"customer.subscription.updated","data":{"object":{"id":"sub_idempotent","customer":"cus_idempotent"}}}"#;
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let second = app.clone().oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(second.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
}

#[tokio::test]
async fn concurrent_duplicate_invoice_event_loser_stays_out_of_handler() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "concurrent-duplicate@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_concurrent_duplicate",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    // Keep the winner in-flight so the duplicate request arrives while the
    // first delivery still owns processing for this event id.
    invoice_repo.pause_next_mark_paid();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_concurrent_duplicate","type":"invoice.payment_succeeded","data":{"object":{"id":"in_concurrent_duplicate"}}}"#;
    let first_handle = tokio::spawn({
        let app = app.clone();
        async move { app.oneshot(webhook_request(payload)).await.unwrap() }
    });

    invoice_repo.wait_for_mark_paid_calls(1).await;

    let second = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(
        second.status(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "concurrent duplicate must not acknowledge success while the winner is still in flight"
    );
    assert_eq!(
        invoice_repo.mark_paid_call_count(),
        1,
        "losing duplicate must not execute handler side effects while winner is in flight"
    );
    assert_eq!(
        webhook_event_repo.processed_state("evt_concurrent_duplicate"),
        Some(false),
        "winner should remain unprocessed while paused in handler"
    );

    invoice_repo.resume_paused_mark_paid().await;

    let first = first_handle.await.unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_concurrent_duplicate"),
        Some(true),
        "winner should eventually mark the event as processed"
    );
}

#[tokio::test]
async fn resume_before_pause_waiter_exists_does_not_deadlock_mark_paid() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "resume-race@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(invoice.id, "in_resume_race", "https://stripe.com/inv", None)
        .await
        .unwrap();

    invoice_repo.pause_next_mark_paid();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_resume_race","type":"invoice.payment_succeeded","data":{"object":{"id":"in_resume_race"}}}"#;
    let first_handle = tokio::spawn({
        let app = app.clone();
        async move { app.oneshot(webhook_request(payload)).await.unwrap() }
    });

    // Intentionally resume before waiting for pause signaling: this used to lose
    // the notify and deadlock the paused mark_paid waiter.
    invoice_repo.resume_paused_mark_paid().await;
    invoice_repo.wait_for_mark_paid_calls(1).await;

    let first = timeout(Duration::from_secs(2), first_handle)
        .await
        .expect("request should not deadlock when resume races ahead")
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
}

#[tokio::test]
async fn resume_waits_for_pause_handshake_internally() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "resume-handshake@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_resume_handshake",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    invoice_repo.pause_next_mark_paid();
    invoice_repo.block_next_pause_waiter_install();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let mut resume_handle = tokio::spawn({
        let invoice_repo = Arc::clone(&invoice_repo);
        async move { invoice_repo.resume_paused_mark_paid().await }
    });
    assert!(
        timeout(Duration::from_millis(50), &mut resume_handle)
            .await
            .is_err(),
        "resume helper must remain pending until mark_paid installs the paused waiter"
    );

    let payload = r#"{"id":"evt_resume_handshake","type":"invoice.payment_succeeded","data":{"object":{"id":"in_resume_handshake"}}}"#;
    let first_handle = tokio::spawn({
        let app = app.clone();
        async move { app.oneshot(webhook_request(payload)).await.unwrap() }
    });

    invoice_repo.wait_for_mark_paid_calls(1).await;
    invoice_repo.wait_for_pause_waiter_install_block().await;
    assert!(
        timeout(Duration::from_millis(50), &mut resume_handle)
            .await
            .is_err(),
        "resume helper must remain pending while mark_paid is blocked before pause-waiter install"
    );

    invoice_repo.release_pause_waiter_install_block();
    timeout(Duration::from_secs(2), &mut resume_handle)
        .await
        .expect("resume helper should finish after paused waiter exists")
        .expect("resume helper task should not panic");

    let first = timeout(Duration::from_secs(2), first_handle)
        .await
        .expect("request should complete after internal pause handshake + resume")
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);
}

#[tokio::test]
async fn replayed_checkout_completed_event_is_noop_once() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_idempotent_checkout","type":"checkout.session.completed","data":{"object":{"id":"cs_idempotent"}}}"#;
    let first = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let second = app.clone().oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(second.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
}
