
use std::sync::Arc;

use api::repos::webhook_event_repo::WebhookEventRepo;
use api::state::AppState;
use api::stripe::local::LocalStripeService;
use axum::body::Body;
use axum::http::Request;

use super::{
    mock_deployment_repo, mock_rate_card_repo, mock_usage_repo, test_state_all_with_stripe,
    MockCustomerRepo, MockInvoiceRepo, MockStripeService, MockSubscriptionRepo,
    MockWebhookEventRepo, TEST_WEBHOOK_SECRET,
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

fn build_webhook_test_app(
    mut state: AppState,
    subscription_repo: Arc<MockSubscriptionRepo>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
) -> axum::Router {
    state.subscription_repo = subscription_repo;
    state.webhook_event_repo = webhook_event_repo as Arc<dyn WebhookEventRepo + Send + Sync>;

    api::router::build_router(state)
}

pub fn local_stripe_webhook_app(
    customer_repo: Arc<MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    subscription_repo: Arc<MockSubscriptionRepo>,
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
    build_webhook_test_app(state, subscription_repo, webhook_event_repo)
}

/// Build a webhook app using the mock Stripe service so tests can seed Stripe
/// subscription lookup data (for `checkout.session.completed` and fallback
/// `customer.subscription.updated` paths).
pub fn mock_stripe_webhook_app(
    customer_repo: Arc<MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    subscription_repo: Arc<MockSubscriptionRepo>,
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
    build_webhook_test_app(state, subscription_repo, webhook_event_repo)
}
