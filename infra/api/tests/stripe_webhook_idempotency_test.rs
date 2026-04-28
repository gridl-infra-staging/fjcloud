mod common;

use std::sync::Arc;

use api::models::{SubscriptionRow, SubscriptionStatus};
use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::{CustomerRepo, SubscriptionRepo};
use api::stripe::local::generate_webhook_signature;
use axum::http::StatusCode;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
use tower::ServiceExt;
use uuid::Uuid;

use common::stripe_webhook_test_support::{
    local_stripe_webhook_app, webhook_request_with_signature,
};
use common::{
    mock_invoice_repo, mock_repo, mock_subscription_repo, mock_webhook_event_repo,
    TEST_WEBHOOK_SECRET,
};

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

async fn seed_stripe_customer(
    repo: &common::MockCustomerRepo,
    name: &str,
    email: &str,
) -> api::models::Customer {
    let customer = repo.seed(name, email);
    repo.set_stripe_customer_id(
        customer.id,
        &format!("cus_test_{}", &customer.id.to_string()[..8]),
    )
    .await
    .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

#[allow(clippy::too_many_arguments)]
fn seed_subscription_row(
    repo: &common::MockSubscriptionRepo,
    customer_id: Uuid,
    stripe_subscription_id: &str,
    status: SubscriptionStatus,
    plan_tier: &str,
    price_id: &str,
    cancel_at_period_end: bool,
    period_start: NaiveDate,
    period_end: NaiveDate,
) -> SubscriptionRow {
    let row = SubscriptionRow {
        id: Uuid::new_v4(),
        customer_id,
        stripe_subscription_id: stripe_subscription_id.to_string(),
        stripe_price_id: price_id.to_string(),
        plan_tier: plan_tier.to_string(),
        status: status.as_str().to_string(),
        current_period_start: period_start,
        current_period_end: period_end,
        cancel_at_period_end,
        created_at: chrono::Utc::now(),
        updated_at: chrono::Utc::now(),
    };
    repo.seed(row.clone());
    row
}

#[tokio::test]
async fn charge_refunded_replay_transitions_paid_invoice_once_and_keeps_processed_event() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_charge_refund_replay",
            "https://stripe.com/inv/refund-replay",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = local_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
    );

    let payload = r#"{"id":"evt_charge_refund_replay","type":"charge.refunded","data":{"object":{"id":"ch_refund","invoice":"in_charge_refund_replay"}}}"#;

    let first_signature = generate_webhook_signature(payload, TEST_WEBHOOK_SECRET, 1_704_067_205);
    let first = app
        .clone()
        .oneshot(webhook_request_with_signature(payload, &first_signature))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let first_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(first_invoice.status, "refunded");

    let second_signature = generate_webhook_signature(payload, TEST_WEBHOOK_SECRET, 1_704_067_206);
    let second = app
        .oneshot(webhook_request_with_signature(payload, &second_signature))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);

    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_charge_refund_replay"),
        Some(true),
        "replayed event should stay recorded as processed"
    );

    let second_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(second_invoice.status, "refunded");
}

#[tokio::test]
async fn unsupported_event_records_once_and_does_not_mutate_domain_state() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_unsupported_event",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
    );

    let invoice_before = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    let subscription_before = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .expect("seeded subscription should exist");
    let customer_before = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    let app = local_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
    );

    let payload = serde_json::json!({
        "id": "evt_unsupported_acceptance",
        "type": "customer.updated",
        "data": { "object": { "id": "cus_ignore" } }
    })
    .to_string();

    let signature = generate_webhook_signature(&payload, TEST_WEBHOOK_SECRET, 1_704_067_202);
    let response = app
        .oneshot(webhook_request_with_signature(&payload, &signature))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_unsupported_acceptance"),
        Some(true),
    );

    let invoice_after = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    let subscription_after = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .expect("seeded subscription should remain");
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(invoice_after.status, invoice_before.status);
    assert_eq!(invoice_after.paid_at, invoice_before.paid_at);
    assert_eq!(invoice_after.finalized_at, invoice_before.finalized_at);
    assert_eq!(subscription_after.status, subscription_before.status);
    assert_eq!(subscription_after.plan_tier, subscription_before.plan_tier);
    assert_eq!(
        subscription_after.cancel_at_period_end,
        subscription_before.cancel_at_period_end
    );
    assert_eq!(customer_after.status, customer_before.status);
    assert_eq!(customer_after.billing_plan, customer_before.billing_plan);
    assert_eq!(
        customer_after.stripe_customer_id,
        customer_before.stripe_customer_id
    );
}

#[tokio::test]
async fn unsupported_event_replay_deduplicates_and_keeps_domain_state_unchanged() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_replay_unsupported",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
    );

    let invoice_before = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    let subscription_before = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .expect("seeded subscription should exist");
    let customer_before = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    let app = local_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
    );

    let payload = serde_json::json!({
        "id": "evt_unsupported_replay",
        "type": "customer.updated",
        "data": { "object": { "id": "cus_ignore_replay" } }
    })
    .to_string();

    let first_signature = generate_webhook_signature(&payload, TEST_WEBHOOK_SECRET, 1_704_067_203);
    let first = app
        .clone()
        .oneshot(webhook_request_with_signature(&payload, &first_signature))
        .await
        .unwrap();
    assert_eq!(first.status(), StatusCode::OK);

    let second_signature = generate_webhook_signature(&payload, TEST_WEBHOOK_SECRET, 1_704_067_204);
    let second = app
        .oneshot(webhook_request_with_signature(&payload, &second_signature))
        .await
        .unwrap();
    assert_eq!(second.status(), StatusCode::OK);

    assert_eq!(webhook_event_repo.event_count(), 1);
    assert_eq!(
        webhook_event_repo.processed_state("evt_unsupported_replay"),
        Some(true),
    );

    let invoice_after = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    let subscription_after = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .expect("seeded subscription should remain");
    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(invoice_after.status, invoice_before.status);
    assert_eq!(invoice_after.paid_at, invoice_before.paid_at);
    assert_eq!(invoice_after.finalized_at, invoice_before.finalized_at);
    assert_eq!(subscription_after.status, subscription_before.status);
    assert_eq!(subscription_after.plan_tier, subscription_before.plan_tier);
    assert_eq!(
        subscription_after.cancel_at_period_end,
        subscription_before.cancel_at_period_end
    );
    assert_eq!(customer_after.status, customer_before.status);
    assert_eq!(customer_after.billing_plan, customer_before.billing_plan);
    assert_eq!(
        customer_after.stripe_customer_id,
        customer_before.stripe_customer_id
    );
}
