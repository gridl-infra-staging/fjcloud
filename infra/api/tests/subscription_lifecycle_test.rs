mod common;

use api::models::{Customer, SubscriptionRow};
use api::repos::{CustomerRepo, SubscriptionRepo};
use api::stripe::{SubscriptionData, SubscriptionItem};
use axum::body::Body;
use axum::http::{Method, Request, StatusCode};
use chrono::{NaiveDate, Utc};
use http_body_util::BodyExt;
use serde_json::json;
use std::{collections::HashMap, sync::Arc};
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    create_test_jwt, mock_repo, mock_stripe_service, mock_subscription_repo, MockCustomerRepo,
    MockStripeService, MockSubscriptionRepo, TestStateBuilder,
};

type CheckoutSessionCall = (
    String,
    String,
    String,
    String,
    Option<HashMap<String, String>>,
);

fn test_app_with_subscription(
    customer_repo: Arc<MockCustomerRepo>,
    subscription_repo: Arc<MockSubscriptionRepo>,
    stripe_service: Arc<MockStripeService>,
) -> axum::Router {
    TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_subscription_repo(subscription_repo)
        .with_stripe_service(stripe_service)
        .build_app()
}

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
}

async fn seed_customer_with_stripe(repo: &MockCustomerRepo) -> Customer {
    let customer = repo.seed("Test Customer", "test@example.com");
    repo.set_stripe_customer_id(customer.id, "cus_test_123")
        .await
        .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

fn checkout_session_request(jwt: &str, plan_tier: &str) -> Request<Body> {
    Request::builder()
        .method(Method::POST)
        .uri("/billing/checkout-session")
        .header("Authorization", format!("Bearer {}", jwt))
        .header("Content-Type", "application/json")
        .body(Body::from(json!({ "plan_tier": plan_tier }).to_string()))
        .unwrap()
}

fn assert_checkout_metadata(
    metadata: &Option<HashMap<String, String>>,
    customer_id: Uuid,
    plan_tier: &str,
) {
    let expected_customer_id = customer_id.to_string();
    let metadata = metadata.as_ref().expect("metadata should be present");
    assert_eq!(
        metadata.get("customer_id").map(String::as_str),
        Some(expected_customer_id.as_str())
    );
    assert_eq!(
        metadata.get("plan_tier").map(String::as_str),
        Some(plan_tier)
    );
}

fn seed_active_subscription(
    repo: &MockSubscriptionRepo,
    stripe_service: &MockStripeService,
    customer_id: Uuid,
    plan_tier: &str,
    stripe_price_id: &str,
) -> SubscriptionRow {
    let sub = SubscriptionRow {
        id: Uuid::new_v4(),
        customer_id,
        stripe_subscription_id: "sub_test_123".to_string(),
        stripe_price_id: stripe_price_id.to_string(),
        plan_tier: plan_tier.to_string(),
        status: "active".to_string(),
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        cancel_at_period_end: false,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    };
    repo.seed(sub.clone());

    stripe_service.seed_subscription(SubscriptionData {
        id: sub.stripe_subscription_id.clone(),
        status: sub.status.clone(),
        current_period_start: sub
            .current_period_start
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_utc()
            .timestamp(),
        current_period_end: sub
            .current_period_end
            .and_hms_opt(0, 0, 0)
            .unwrap()
            .and_utc()
            .timestamp(),
        cancel_at_period_end: sub.cancel_at_period_end,
        customer: "cus_test_123".to_string(),
        items: vec![SubscriptionItem {
            id: "si_test_123".to_string(),
            price_id: stripe_price_id.to_string(),
        }],
    });

    sub
}

// ===========================================================================
// POST /billing/checkout-session
// ===========================================================================

#[tokio::test]
async fn create_checkout_session_returns_url() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service.clone());

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(checkout_session_request(&jwt, "starter"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;
    assert!(body.get("checkout_url").is_some());

    let checkout_calls = stripe_service.checkout_session_calls.lock().unwrap();
    assert_eq!(checkout_calls.len(), 1);
    let call: &CheckoutSessionCall = &checkout_calls[0];
    let (_customer_id, price_id, success_url, cancel_url, metadata) = call;
    assert_eq!(price_id, "price_starter_test");
    assert_eq!(
        success_url,
        "http://localhost:5173/dashboard?subscription=success"
    );
    assert_eq!(
        cancel_url,
        "http://localhost:5173/dashboard?subscription=cancelled"
    );
    assert_checkout_metadata(metadata, customer.id, "starter");
}

#[tokio::test]
async fn create_checkout_session_passes_metadata_to_stripe() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service.clone());

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(checkout_session_request(&jwt, "starter"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let checkout_calls = stripe_service.checkout_session_calls.lock().unwrap();
    assert_eq!(checkout_calls.len(), 1);
    let call: &CheckoutSessionCall = &checkout_calls[0];
    let (_customer_id, _price_id, _success_url, _cancel_url, metadata) = call;
    assert_checkout_metadata(metadata, customer.id, "starter");
}

#[tokio::test]
async fn create_checkout_session_rejects_free_tier() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/checkout-session")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "free"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn create_checkout_session_requires_auth() {
    let customer_repo = mock_repo();
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/checkout-session")
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "starter"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn create_checkout_session_returns_409_for_already_subscribed_customer() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter_test",
    );

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(checkout_session_request(&jwt, "starter"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::CONFLICT);
}

#[tokio::test]
async fn create_checkout_session_allows_checkout_when_subscription_is_canceled() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    subscription_repo.seed(SubscriptionRow {
        id: Uuid::new_v4(),
        customer_id: customer.id,
        stripe_subscription_id: "sub_canceled_123".to_string(),
        stripe_price_id: "price_starter_test".to_string(),
        plan_tier: "starter".to_string(),
        status: "canceled".to_string(),
        current_period_start: NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        current_period_end: NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        cancel_at_period_end: true,
        created_at: Utc::now(),
        updated_at: Utc::now(),
    });

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(checkout_session_request(&jwt, "starter"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
}

// ===========================================================================
// GET /billing/subscription
// ===========================================================================

#[tokio::test]
async fn get_subscription_returns_current_subscription() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/billing/subscription")
                .header("Authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = body_json(response).await;
    assert_eq!(body["plan_tier"], "starter");
    assert_eq!(body["status"], "active");
}

#[tokio::test]
async fn get_subscription_returns_404_if_none() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/billing/subscription")
                .header("Authorization", format!("Bearer {}", jwt))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// POST /billing/subscription/cancel
// ===========================================================================

#[tokio::test]
async fn cancel_subscription_sets_cancel_at_period_end() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(
        customer_repo,
        subscription_repo.clone(),
        stripe_service.clone(),
    );

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/cancel")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(
                    json!({"cancel_at_period_end": true}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    {
        let cancel_calls = stripe_service.cancel_subscription_calls.lock().unwrap();
        assert_eq!(cancel_calls.len(), 1);
        assert_eq!(
            cancel_calls[0],
            ("sub_test_123".to_string(), true),
            "cancel route should call Stripe with cancel_at_period_end=true"
        );
    }

    let subscription = subscription_repo
        .find_by_customer(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert!(subscription.cancel_at_period_end);
}

#[tokio::test]
async fn cancel_subscription_immediate_marks_canceled() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(
        customer_repo,
        subscription_repo.clone(),
        stripe_service.clone(),
    );

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/cancel")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(
                    json!({"cancel_at_period_end": false}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let cancel_calls = stripe_service.cancel_subscription_calls.lock().unwrap();
    assert_eq!(cancel_calls.len(), 1);
    assert_eq!(
        cancel_calls[0],
        ("sub_test_123".to_string(), false),
        "immediate cancel should call Stripe with cancel_at_period_end=false"
    );
}

#[tokio::test]
async fn cancel_subscription_returns_404_if_no_subscription() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/cancel")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(
                    json!({"cancel_at_period_end": true}).to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// POST /billing/subscription/upgrade
// ===========================================================================

#[tokio::test]
async fn upgrade_subscription_updates_plan() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(
        customer_repo,
        subscription_repo.clone(),
        stripe_service.clone(),
    );

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/upgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "pro"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = body_json(response).await;
    assert_eq!(body["plan_tier"], "pro");

    let update_calls = stripe_service.update_subscription_calls.lock().unwrap();
    assert_eq!(update_calls.len(), 1);
    assert_eq!(
        update_calls[0],
        (
            "sub_test_123".to_string(),
            "price_pro_test".to_string(),
            "always_invoice".to_string(),
        ),
        "upgrade should call Stripe with always_invoice proration"
    );
}

#[tokio::test]
async fn upgrade_subscription_rejects_downgrade() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/upgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "free"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn upgrade_subscription_returns_404_if_no_subscription() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/upgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "pro"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

// ===========================================================================
// POST /billing/subscription/downgrade
// ===========================================================================

#[tokio::test]
async fn downgrade_subscription_updates_plan() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "pro",
        "price_pro",
    );

    let app = test_app_with_subscription(
        customer_repo,
        subscription_repo.clone(),
        stripe_service.clone(),
    );

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/downgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "starter"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);

    let body = body_json(response).await;
    assert_eq!(body["plan_tier"], "starter");

    let update_calls = stripe_service.update_subscription_calls.lock().unwrap();
    assert_eq!(update_calls.len(), 1);
    assert_eq!(
        update_calls[0],
        (
            "sub_test_123".to_string(),
            "price_starter_test".to_string(),
            "none".to_string(),
        ),
        "downgrade should call Stripe with none proration"
    );
}

#[tokio::test]
async fn downgrade_subscription_rejects_upgrade() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();
    seed_active_subscription(
        &subscription_repo,
        &stripe_service,
        customer.id,
        "starter",
        "price_starter",
    );

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/downgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "pro"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn downgrade_subscription_returns_404_if_no_subscription() {
    let customer_repo = mock_repo();
    let customer = seed_customer_with_stripe(&customer_repo).await;
    let subscription_repo = mock_subscription_repo();
    let stripe_service = mock_stripe_service();

    let app = test_app_with_subscription(customer_repo, subscription_repo, stripe_service);

    let jwt = create_test_jwt(customer.id);
    let response = app
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/billing/subscription/downgrade")
                .header("Authorization", format!("Bearer {}", jwt))
                .header("Content-Type", "application/json")
                .body(Body::from(json!({"plan_tier": "starter"}).to_string()))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}
