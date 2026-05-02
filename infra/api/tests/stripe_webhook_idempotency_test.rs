mod common;

use std::sync::Arc;

use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::CustomerRepo;
use axum::http::StatusCode;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
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
