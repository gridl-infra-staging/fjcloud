#![allow(clippy::await_holding_lock)]

mod common;

use api::models::{SubscriptionRow, SubscriptionStatus};
use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::{CustomerRepo, SubscriptionRepo};
use api::stripe::local::generate_webhook_signature;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::NaiveDate;
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use common::stripe_webhook_test_support::{
    local_stripe_webhook_app, webhook_request_with_signature,
};
use common::{mock_invoice_repo, mock_repo, mock_webhook_event_repo, TEST_WEBHOOK_SECRET};

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

fn seed_subscription_row(
    repo: &common::MockSubscriptionRepo,
    customer_id: Uuid,
    _stripe_customer_id: &str,
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

#[tokio::test]
async fn webhook_missing_signature_header_returns_400_and_shared_error_envelope() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = common::mock_subscription_repo();
    let webhook_repo = mock_webhook_event_repo();

    let app = local_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_repo),
    );

    let resp = app
        .oneshot(
            Request::post("/webhooks/stripe")
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(
        body,
        serde_json::json!({ "error": "missing stripe-signature header" })
    );
}

#[tokio::test]
async fn webhook_invalid_signature_hmac_verification_returns_400_and_non_mutating() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = common::mock_subscription_repo();
    let webhook_repo = mock_webhook_event_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    seed_subscription_row(
        &subscription_repo,
        customer.id,
        customer
            .stripe_customer_id
            .as_deref()
            .expect("seeded customer has stripe id"),
        "sub_signature_reject",
        SubscriptionStatus::PastDue,
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
        Arc::clone(&webhook_repo),
    );

    let payload = serde_json::json!({
        "id": "evt_bad_sig_hmac",
        "type": "customer.updated",
        "data": { "object": {} }
    })
    .to_string();
    let wrong_signature =
        generate_webhook_signature(&payload, "wrong-webhook-secret", 1_704_067_200);

    let resp = app
        .oneshot(webhook_request_with_signature(&payload, &wrong_signature))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(
        body,
        serde_json::json!({ "error": "invalid webhook signature" })
    );
    assert_eq!(
        webhook_repo.event_count(),
        0,
        "invalid signatures must not insert webhook events"
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
async fn webhook_malformed_raw_json_hmac_verification_returns_400_and_non_mutating() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = common::mock_subscription_repo();
    let webhook_repo = mock_webhook_event_repo();
    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    seed_subscription_row(
        &subscription_repo,
        customer.id,
        customer
            .stripe_customer_id
            .as_deref()
            .expect("seeded customer has stripe id"),
        "sub_bad_json_reject",
        SubscriptionStatus::PastDue,
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
        Arc::clone(&webhook_repo),
    );

    let malformed_payload =
        r#"{"id":"evt_bad_json_hmac","type":"customer.updated","data":{"object":{}}"#;
    let signature =
        generate_webhook_signature(malformed_payload, TEST_WEBHOOK_SECRET, 1_704_067_201);

    let resp = app
        .oneshot(webhook_request_with_signature(
            malformed_payload,
            &signature,
        ))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::BAD_REQUEST);
    let body = body_json(resp).await;
    assert_eq!(
        body,
        serde_json::json!({ "error": "invalid webhook signature" })
    );
    assert_eq!(
        webhook_repo.event_count(),
        0,
        "malformed raw JSON must not insert webhook events"
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
