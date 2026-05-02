mod common;

use std::sync::Arc;

use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use axum::body::Body;
use axum::http::{Request, StatusCode};
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
async fn missing_signature_header_returns_bad_request() {
    let app = mock_stripe_webhook_app(
        mock_repo(),
        mock_invoice_repo(),
        mock_webhook_event_repo(),
        mock_stripe_service(),
    );

    let req = Request::post("/webhooks/stripe")
        .header("content-type", "application/json")
        .body(Body::from(
            r#"{"id":"evt_missing_sig","type":"invoice.payment_succeeded","data":{"object":{"id":"in_missing_sig"}}}"#,
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn mock_stripe_service_accepts_any_signature_value() {
    let app = mock_stripe_webhook_app(
        mock_repo(),
        mock_invoice_repo(),
        mock_webhook_event_repo(),
        mock_stripe_service(),
    );

    let req = Request::post("/webhooks/stripe")
        .header("content-type", "application/json")
        .header("stripe-signature", "invalid")
        .body(Body::from(
            r#"{"id":"evt_bad_sig","type":"invoice.payment_succeeded","data":{"object":{"id":"in_bad_sig"}}}"#,
        ))
        .unwrap();

    let resp = app.oneshot(req).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
}

#[tokio::test]
async fn valid_signature_processes_event() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "signature@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_signature_valid",
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

    let payload = r#"{"id":"evt_signature_valid","type":"invoice.payment_succeeded","data":{"object":{"id":"in_signature_valid"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "paid");
}

#[tokio::test]
async fn valid_signature_accepts_deprecated_subscription_event() {
    let webhook_event_repo = mock_webhook_event_repo();
    let app = mock_stripe_webhook_app(
        mock_repo(),
        mock_invoice_repo(),
        Arc::clone(&webhook_event_repo),
        mock_stripe_service(),
    );

    let payload = r#"{"id":"evt_signature_sub_deprecated","type":"customer.subscription.deleted","data":{"object":{"id":"sub_signature"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
}
