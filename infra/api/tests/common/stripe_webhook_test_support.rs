use std::sync::Arc;

use api::repos::invoice_repo::NewLineItem;
use api::repos::webhook_event_repo::WebhookEventRepo;
use api::services::alerting::AlertService;
use api::services::email::EmailService;
use api::state::AppState;
use api::stripe::local::LocalStripeService;
use axum::body::Body;
use axum::http::Request;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
use uuid::Uuid;

use super::{
    mock_deployment_repo, mock_rate_card_repo, mock_usage_repo, test_state_all_with_stripe,
    MockCustomerRepo, MockInvoiceRepo, MockStripeService, MockWebhookEventRepo,
    TEST_WEBHOOK_SECRET,
};

pub fn webhook_request(body: &str) -> Request<Body> {
    webhook_request_with_signature(body, "mock-sig")
}

pub fn webhook_request_with_signature(body: &str, signature: &str) -> Request<Body> {
    Request::post("/webhooks/stripe")
        .header("content-type", "application/json")
        .header("stripe-signature", signature)
        .body(Body::from(body.to_string()))
        .unwrap()
}

/// Seed the canonical webhook-invoice fixture shared by dunning and alert tests.
pub fn seed_draft_invoice(repo: &MockInvoiceRepo, customer_id: Uuid) -> api::models::InvoiceRow {
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

/// Build a webhook app with caller-controlled alert/email services and dunning toggle.
pub fn test_app_with_alert_and_email_services(
    customer_repo: Arc<MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    alert_service: Arc<dyn AlertService>,
    email_service: Arc<dyn EmailService>,
    dunning_emails_disabled: bool,
) -> axum::Router {
    let mut state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
        super::mock_stripe_service(),
    );
    state.alert_service = alert_service;
    state.email_service = email_service;
    state.dunning_emails_disabled = dunning_emails_disabled;
    api::router::build_router(state)
}

fn build_webhook_test_app(
    mut state: AppState,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
) -> axum::Router {
    state.webhook_event_repo = webhook_event_repo as Arc<dyn WebhookEventRepo + Send + Sync>;

    api::router::build_router(state)
}

pub fn local_stripe_webhook_app(
    customer_repo: Arc<MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
) -> axum::Router {
    let mut state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
        super::mock_stripe_service(),
    );
    let (local_stripe_service, _webhook_dispatcher) = LocalStripeService::new(
        TEST_WEBHOOK_SECRET.to_string(),
        "http://127.0.0.1:65535/webhooks/stripe".to_string(),
    );
    state.stripe_service = Arc::new(local_stripe_service);
    build_webhook_test_app(state, webhook_event_repo)
}

/// Build a webhook app using the mock Stripe service so tests can seed Stripe
/// subscription lookup data (for `checkout.session.completed` and fallback
/// `customer.subscription.updated` paths).
pub fn mock_stripe_webhook_app(
    customer_repo: Arc<MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
    stripe_service: Arc<MockStripeService>,
) -> axum::Router {
    let state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
        stripe_service,
    );
    build_webhook_test_app(state, webhook_event_repo)
}
