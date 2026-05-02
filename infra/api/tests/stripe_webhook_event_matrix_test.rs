mod common;

use std::sync::Arc;

use api::models::Customer;
use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::CustomerRepo;
use axum::http::StatusCode;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
use tower::ServiceExt;
use uuid::Uuid;

use common::stripe_webhook_test_support::{mock_stripe_webhook_app, webhook_request};
use common::{mock_invoice_repo, mock_repo, mock_stripe_service, mock_webhook_event_repo};

fn seed_draft_invoice(
    repo: &common::MockInvoiceRepo,
    customer_id: Uuid,
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

async fn seed_customer_with_stripe(repo: &common::MockCustomerRepo, email: &str) -> Customer {
    let customer = repo.seed("Acme", email);
    repo.set_stripe_customer_id(
        customer.id,
        &format!("cus_test_{}", &customer.id.to_string()[..8]),
    )
    .await
    .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

#[tokio::test]
async fn invoice_payment_succeeded_marks_invoice_paid() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "pay-success@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_payment_succeeded",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_payment_succeeded","type":"invoice.payment_succeeded","data":{"object":{"id":"in_matrix_payment_succeeded"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");
}

#[tokio::test]
async fn invoice_payment_failed_exhausted_marks_failed_and_suspends_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "payment-failed@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_payment_failed",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_payment_failed","type":"invoice.payment_failed","data":{"object":{"id":"in_matrix_payment_failed","next_payment_attempt":null}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "failed");
    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "suspended");
}

#[tokio::test]
async fn deprecated_subscription_events_are_noops_with_zero_state_mutations() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "sub-noop@example.com").await;
    let customer_before = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    let invoice_before = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    for (event_id, event_type) in [
        ("evt_matrix_sub_created", "customer.subscription.created"),
        ("evt_matrix_sub_updated", "customer.subscription.updated"),
        ("evt_matrix_sub_deleted", "customer.subscription.deleted"),
        (
            "evt_matrix_checkout_completed",
            "checkout.session.completed",
        ),
    ] {
        let payload = format!(
            r#"{{"id":"{event_id}","type":"{event_type}","data":{{"object":{{"id":"sub_matrix","customer":"{}"}}}}}}"#,
            customer.stripe_customer_id.as_deref().unwrap()
        );
        let response = app
            .clone()
            .oneshot(webhook_request(&payload))
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::OK);
    }

    assert_eq!(webhook_event_repo.event_count(), 4);
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    let invoice_after = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(customer_after.status, customer_before.status);
    assert_eq!(customer_after.billing_plan, customer_before.billing_plan);
    assert_eq!(invoice_after.status, invoice_before.status);
    assert_eq!(invoice_after.total_cents, invoice_before.total_cents);
}

#[tokio::test]
async fn charge_refunded_marks_paid_invoice_refunded() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "refund@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_refund",
            "https://stripe.com/inv/refund",
            Some("pi_matrix_refund"),
        )
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_charge_refund","type":"charge.refunded","data":{"object":{"invoice":"in_matrix_refund"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "refunded");
}
