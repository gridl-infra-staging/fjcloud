mod common;

use std::sync::Arc;

use api::models::{Customer, SubscriptionRow, SubscriptionStatus};
use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::{CustomerRepo, SubscriptionRepo};
use api::stripe::{SubscriptionData, SubscriptionItem};
use axum::http::StatusCode;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
use tower::ServiceExt;
use uuid::Uuid;

use common::stripe_webhook_test_support::{mock_stripe_webhook_app, webhook_request};
use common::{
    mock_invoice_repo, mock_repo, mock_stripe_service, mock_subscription_repo,
    mock_webhook_event_repo,
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

fn ymd_utc_timestamp(year: i32, month: u32, day: u32) -> i64 {
    NaiveDate::from_ymd_opt(year, month, day)
        .expect("valid date")
        .and_hms_opt(0, 0, 0)
        .expect("valid midnight")
        .and_utc()
        .timestamp()
}

fn date_to_unix(date: NaiveDate) -> i64 {
    date.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp()
}

#[tokio::test]
async fn invoice_payment_succeeded_marks_invoice_paid_without_unrelated_mutation() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
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

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_matrix_no_change",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
    );

    let before_subscription = subscription_repo
        .find_by_stripe_id("sub_matrix_no_change")
        .await
        .unwrap()
        .expect("subscription should exist");
    let before_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_payment_succeeded","type":"invoice.payment_succeeded","data":{"object":{"id":"in_matrix_payment_succeeded"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    let updated_subscription = subscription_repo
        .find_by_stripe_id("sub_matrix_no_change")
        .await
        .unwrap()
        .expect("subscription should still exist");
    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();

    assert_eq!(updated_invoice.status, "paid");
    assert_eq!(updated_subscription.status, before_subscription.status);
    assert_eq!(
        updated_subscription.plan_tier,
        before_subscription.plan_tier
    );
    assert_eq!(
        updated_subscription.cancel_at_period_end,
        before_subscription.cancel_at_period_end
    );
    assert_eq!(updated_customer.status, before_customer.status);
    assert_eq!(updated_customer.billing_plan, before_customer.billing_plan);
}

#[tokio::test]
async fn invoice_payment_action_required_transitions_active_subscription_to_past_due() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "action-required@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_action_required",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_matrix_action_required",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 3, 31).unwrap(),
    );

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = format!(
        r#"{{"id":"evt_matrix_action_required","type":"invoice.payment_action_required","data":{{"object":{{"id":"in_matrix_action_required","customer":"{}"}}}}}}"#,
        customer.stripe_customer_id.as_deref().unwrap()
    );
    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = subscription_repo
        .find_by_stripe_id("sub_matrix_action_required")
        .await
        .unwrap()
        .expect("subscription should exist");
    assert_eq!(updated.status, "past_due");
}

#[tokio::test]
async fn invoice_payment_failed_exhausted_transitions_past_due_subscription_to_canceled() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
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

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_matrix_payment_failed",
        SubscriptionStatus::PastDue,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 3, 31).unwrap(),
    );

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_payment_failed","type":"invoice.payment_failed","data":{"object":{"id":"in_matrix_payment_failed","next_payment_attempt":null}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = subscription_repo
        .find_by_stripe_id("sub_matrix_payment_failed")
        .await
        .unwrap()
        .expect("subscription should exist");
    assert_eq!(updated.status, "canceled");
}

#[tokio::test]
async fn customer_subscription_created_creates_subscription_row() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "sub-created@example.com").await;

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = serde_json::json!({
        "id": "evt_matrix_sub_created",
        "type": "customer.subscription.created",
        "data": {
            "object": {
                "id": "sub_matrix_created",
                "customer": customer.stripe_customer_id.as_ref().unwrap(),
                "status": "active",
                "current_period_start": ymd_utc_timestamp(2026, 1, 1),
                "current_period_end": ymd_utc_timestamp(2026, 1, 31),
                "cancel_at_period_end": false,
                "items": {
                    "data": [
                        {
                            "price": {
                                "id": "price_starter_test"
                            }
                        }
                    ]
                }
            }
        }
    })
    .to_string();

    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let created = subscription_repo
        .find_by_stripe_id("sub_matrix_created")
        .await
        .unwrap()
        .expect("subscription should be created");
    assert_eq!(created.customer_id, customer.id);
    assert_eq!(created.status, "active");
    assert_eq!(created.plan_tier, "starter");
    assert!(!created.cancel_at_period_end);
}

#[tokio::test]
async fn customer_subscription_created_falls_back_to_stripe_lookup_when_payload_sparse() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer =
        seed_customer_with_stripe(&customer_repo, "sub-created-fallback@example.com").await;
    let stripe_customer_id = customer.stripe_customer_id.clone().unwrap();

    let expected_start = NaiveDate::from_ymd_opt(2026, 7, 1).unwrap();
    let expected_end = NaiveDate::from_ymd_opt(2026, 8, 1).unwrap();
    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_matrix_created_sparse".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(expected_start),
        current_period_end: date_to_unix(expected_end),
        cancel_at_period_end: false,
        customer: stripe_customer_id.clone(),
        items: vec![SubscriptionItem {
            id: "si_matrix_created_sparse".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = serde_json::json!({
        "id": "evt_matrix_sub_created_sparse",
        "type": "customer.subscription.created",
        "data": {
            "object": {
                "id": "sub_matrix_created_sparse",
                "customer": stripe_customer_id
            }
        }
    })
    .to_string();

    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let created = subscription_repo
        .find_by_stripe_id("sub_matrix_created_sparse")
        .await
        .unwrap()
        .expect("subscription should be created from Stripe lookup fallback");
    assert_eq!(created.customer_id, customer.id);
    assert_eq!(created.status, "active");
    assert_eq!(created.plan_tier, "starter");
    assert_eq!(created.current_period_start, expected_start);
    assert_eq!(created.current_period_end, expected_end);
}

#[tokio::test]
async fn customer_subscription_updated_updates_subscription_row() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "sub-updated@example.com").await;

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_matrix_updated",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
    );

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = serde_json::json!({
        "id": "evt_matrix_sub_updated",
        "type": "customer.subscription.updated",
        "data": {
            "object": {
                "id": "sub_matrix_updated",
                "customer": customer.stripe_customer_id.as_ref().unwrap(),
                "status": "past_due",
                "current_period_start": ymd_utc_timestamp(2026, 2, 1),
                "current_period_end": ymd_utc_timestamp(2026, 2, 28),
                "cancel_at_period_end": true,
                "items": {
                    "data": [
                        {
                            "price": {
                                "id": "price_pro_test"
                            }
                        }
                    ]
                }
            }
        }
    })
    .to_string();

    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = subscription_repo
        .find_by_stripe_id("sub_matrix_updated")
        .await
        .unwrap()
        .expect("subscription should remain");
    assert_eq!(updated.status, "past_due");
    assert_eq!(updated.plan_tier, "pro");
    assert!(updated.cancel_at_period_end);
}

#[tokio::test]
async fn customer_subscription_deleted_marks_subscription_canceled() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "sub-deleted@example.com").await;

    seed_subscription_row(
        &subscription_repo,
        customer.id,
        "sub_matrix_deleted",
        SubscriptionStatus::Active,
        "starter",
        "price_starter_test",
        false,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
    );

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = serde_json::json!({
        "id": "evt_matrix_sub_deleted",
        "type": "customer.subscription.deleted",
        "data": {
            "object": {
                "id": "sub_matrix_deleted",
                "customer": customer.stripe_customer_id.as_ref().unwrap(),
                "status": "canceled",
                "current_period_start": ymd_utc_timestamp(2026, 2, 1),
                "current_period_end": ymd_utc_timestamp(2026, 2, 28),
                "cancel_at_period_end": false,
                "items": {
                    "data": [
                        {
                            "price": {
                                "id": "price_starter_test"
                            }
                        }
                    ]
                }
            }
        }
    })
    .to_string();

    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = subscription_repo
        .find_by_stripe_id("sub_matrix_deleted")
        .await
        .unwrap()
        .expect("subscription should persist as canceled");
    assert_eq!(updated.status, "canceled");
}

#[tokio::test]
async fn checkout_session_completed_creates_subscription_from_seeded_stripe_lookup() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "checkout-matrix@example.com").await;
    let stripe_customer_id = customer.stripe_customer_id.clone().unwrap();

    let expected_start = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
    let expected_end = NaiveDate::from_ymd_opt(2026, 6, 1).unwrap();
    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_matrix_checkout".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(expected_start),
        current_period_end: date_to_unix(expected_end),
        cancel_at_period_end: false,
        customer: stripe_customer_id.clone(),
        items: vec![SubscriptionItem {
            id: "si_matrix_checkout".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        invoice_repo,
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = serde_json::json!({
        "id": "evt_matrix_checkout_completed",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_matrix_checkout",
                "customer": stripe_customer_id,
                "subscription": "sub_matrix_checkout"
            }
        }
    })
    .to_string();

    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let created = subscription_repo
        .find_by_stripe_id("sub_matrix_checkout")
        .await
        .unwrap()
        .expect("subscription should be created from Stripe lookup");
    assert_eq!(created.customer_id, customer.id);
    assert_eq!(created.status, "active");
    assert_eq!(created.plan_tier, "starter");
    assert_eq!(created.current_period_start, expected_start);
    assert_eq!(created.current_period_end, expected_end);
}

#[tokio::test]
async fn charge_refunded_marks_paid_invoice_refunded() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "refund@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_charge_refund",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&subscription_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_charge_refunded","type":"charge.refunded","data":{"object":{"id":"ch_123","invoice":"in_matrix_charge_refund"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "refunded");
}

#[tokio::test]
async fn charge_refunded_uses_payment_intent_fallback_when_invoice_missing() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let subscription_repo = mock_subscription_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = customer_repo.seed("Acme", "refund-fallback@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_charge_refund_pi_fallback",
            "https://stripe.com/inv",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        subscription_repo,
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );
    let prior_payload = r#"{"id":"evt_prior_invoice_paid","type":"invoice.payment_succeeded","data":{"object":{"id":"in_matrix_charge_refund_pi_fallback","payment_intent":"pi_matrix_charge_refund_fallback"}}}"#;
    let prior_response = app
        .clone()
        .oneshot(webhook_request(prior_payload))
        .await
        .unwrap();
    assert_eq!(prior_response.status(), StatusCode::OK);

    let payload = r#"{"id":"evt_matrix_charge_refunded_pi_only","type":"charge.refunded","data":{"object":{"id":"ch_123","invoice":null,"payment_intent":"pi_matrix_charge_refund_fallback"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 2);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "refunded");
}
