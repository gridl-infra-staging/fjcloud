mod common;

use api::models::{Customer, PlanTier, SubscriptionStatus};
use api::repos::subscription_repo::NewSubscription;
use api::repos::{CustomerRepo, SubscriptionRepo};
use api::stripe::{SubscriptionData, SubscriptionItem};
use axum::http::StatusCode;
use chrono::NaiveDate;
use serde_json::json;
use tower::ServiceExt;

use common::stripe_webhook_test_support::{mock_stripe_webhook_app, webhook_request};
use common::{mock_repo, mock_subscription_repo, mock_webhook_event_repo, MockCustomerRepo};

async fn seed_customer_with_stripe(repo: &MockCustomerRepo, email: &str) -> Customer {
    let customer = repo.seed("Test Customer", email);
    repo.set_stripe_customer_id(customer.id, &format!("cus_{}", email.replace('@', "_")))
        .await
        .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

fn date_to_unix(date: NaiveDate) -> i64 {
    date.and_hms_opt(0, 0, 0).unwrap().and_utc().timestamp()
}

#[tokio::test]
async fn checkout_session_completed_creates_subscription_from_stripe_data_without_metadata() {
    let customer_repo = mock_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = common::mock_stripe_service();

    let customer = seed_customer_with_stripe(&customer_repo, "test@example.com").await;
    let stripe_customer_id = customer.stripe_customer_id.clone().unwrap();

    let expected_start = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();
    let expected_end = NaiveDate::from_ymd_opt(2026, 3, 1).unwrap();
    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_starter_123".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(expected_start),
        current_period_end: date_to_unix(expected_end),
        cancel_at_period_end: false,
        customer: stripe_customer_id.clone(),
        items: vec![SubscriptionItem {
            id: "si_1".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo.clone(),
        common::mock_invoice_repo(),
        subscription_repo.clone(),
        webhook_event_repo,
        stripe_service,
    );

    let webhook_payload = json!({
        "id": "evt_checkout_complete_123",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_test_abc123",
                "customer": stripe_customer_id,
                "subscription": "sub_starter_123"
            }
        }
    })
    .to_string();

    let response = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let sub = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .expect("subscription should be created");
    assert_eq!(sub.status, "active");
    assert_eq!(sub.plan_tier, "starter");
    assert_eq!(sub.stripe_price_id, "price_starter_test");
    assert_eq!(sub.current_period_start, expected_start);
    assert_eq!(sub.current_period_end, expected_end);
}

#[tokio::test]
async fn checkout_session_completed_replay_is_idempotent() {
    let customer_repo = mock_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = common::mock_stripe_service();

    let customer = seed_customer_with_stripe(&customer_repo, "idempotent@example.com").await;
    let stripe_customer_id = customer.stripe_customer_id.clone().unwrap();

    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_starter_replay".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(NaiveDate::from_ymd_opt(2026, 2, 1).unwrap()),
        current_period_end: date_to_unix(NaiveDate::from_ymd_opt(2026, 3, 1).unwrap()),
        cancel_at_period_end: false,
        customer: stripe_customer_id.clone(),
        items: vec![SubscriptionItem {
            id: "si_replay".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        common::mock_invoice_repo(),
        subscription_repo.clone(),
        webhook_event_repo,
        stripe_service,
    );

    let webhook_payload = json!({
        "id": "evt_checkout_dup_456",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_test_dup",
                "customer": stripe_customer_id,
                "subscription": "sub_starter_replay"
            }
        }
    })
    .to_string();

    let response1 = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();
    let response2 = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();

    assert_eq!(response1.status(), StatusCode::OK);
    assert_eq!(response2.status(), StatusCode::OK);
    assert_eq!(
        subscription_repo.count(),
        1,
        "replayed event must not duplicate subscriptions"
    );
}

#[tokio::test]
async fn checkout_session_completed_updates_existing_subscription_period_and_plan_from_stripe() {
    let customer_repo = mock_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = common::mock_stripe_service();

    let customer = seed_customer_with_stripe(&customer_repo, "update@example.com").await;
    let stripe_customer_id = customer.stripe_customer_id.clone().unwrap();

    let old_status: SubscriptionStatus = "past_due".parse().unwrap();
    let old_start = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let old_end = NaiveDate::from_ymd_opt(2026, 2, 1).unwrap();

    subscription_repo
        .create(NewSubscription {
            customer_id: customer.id,
            stripe_subscription_id: "sub_existing_789".to_string(),
            stripe_price_id: "price_pro_test".to_string(),
            plan_tier: PlanTier::Pro,
            status: old_status,
            current_period_start: old_start,
            current_period_end: old_end,
            cancel_at_period_end: false,
        })
        .await
        .unwrap();

    let new_start = NaiveDate::from_ymd_opt(2026, 4, 1).unwrap();
    let new_end = NaiveDate::from_ymd_opt(2026, 5, 1).unwrap();
    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_existing_789".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(new_start),
        current_period_end: date_to_unix(new_end),
        cancel_at_period_end: false,
        customer: stripe_customer_id.clone(),
        items: vec![SubscriptionItem {
            id: "si_update".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        common::mock_invoice_repo(),
        subscription_repo.clone(),
        webhook_event_repo,
        stripe_service,
    );

    let webhook_payload = json!({
        "id": "evt_checkout_update",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_test_update",
                "customer": stripe_customer_id,
                "subscription": "sub_existing_789",
                "metadata": {
                    "customer_id": customer.id.to_string(),
                    "plan_tier": "starter"
                }
            }
        }
    })
    .to_string();

    let response = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let sub = subscription_repo
        .find_by_stripe_id("sub_existing_789")
        .await
        .unwrap()
        .expect("subscription should still exist");
    assert_eq!(sub.status, "active");
    assert_eq!(sub.plan_tier, "starter");
    assert_eq!(sub.stripe_price_id, "price_starter_test");
    assert_eq!(sub.current_period_start, new_start);
    assert_eq!(sub.current_period_end, new_end);
}

#[tokio::test]
async fn checkout_session_completed_missing_subscription_is_ignored_gracefully() {
    let customer_repo = mock_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = common::mock_stripe_service();

    let app = mock_stripe_webhook_app(
        customer_repo,
        common::mock_invoice_repo(),
        subscription_repo.clone(),
        webhook_event_repo,
        stripe_service,
    );

    let webhook_payload = json!({
        "id": "evt_checkout_missing_sub",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_missing_sub"
            }
        }
    })
    .to_string();

    let response = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(subscription_repo.count(), 0);
}

#[tokio::test]
async fn checkout_session_completed_for_unknown_stripe_customer_is_ignored() {
    let customer_repo = mock_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = common::mock_stripe_service();

    stripe_service.seed_subscription(SubscriptionData {
        id: "sub_unknown_customer".to_string(),
        status: "active".to_string(),
        current_period_start: date_to_unix(NaiveDate::from_ymd_opt(2026, 6, 1).unwrap()),
        current_period_end: date_to_unix(NaiveDate::from_ymd_opt(2026, 7, 1).unwrap()),
        cancel_at_period_end: false,
        customer: "cus_unknown_123".to_string(),
        items: vec![SubscriptionItem {
            id: "si_unknown_customer".to_string(),
            price_id: "price_starter_test".to_string(),
        }],
    });

    let app = mock_stripe_webhook_app(
        customer_repo,
        common::mock_invoice_repo(),
        subscription_repo.clone(),
        webhook_event_repo,
        stripe_service,
    );

    let webhook_payload = json!({
        "id": "evt_checkout_unknown_customer",
        "type": "checkout.session.completed",
        "data": {
            "object": {
                "id": "cs_unknown_customer",
                "subscription": "sub_unknown_customer"
            }
        }
    })
    .to_string();

    let response = app
        .clone()
        .oneshot(webhook_request(&webhook_payload))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(subscription_repo.count(), 0);
}
