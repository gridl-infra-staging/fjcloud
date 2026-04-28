mod common;

use std::sync::{
    atomic::{AtomicUsize, Ordering},
    Arc,
};

use api::models::RateCardRow;
use api::repos::invoice_repo::NewLineItem;
use api::repos::{CustomerRepo, InvoiceRepo};
use api::services::email::{EmailError, EmailService, MockEmailService};
use async_trait::async_trait;
use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{NaiveDate, Utc};
use http_body_util::BodyExt;
use rust_decimal_macros::dec;
use serde_json::json;
use tower::ServiceExt;
use uuid::Uuid;

use common::{
    mock_deployment_repo, mock_invoice_repo, mock_rate_card_repo, mock_repo, mock_stripe_service,
    mock_usage_repo, test_state_all_with_stripe, TEST_ADMIN_KEY,
};

async fn body_json(resp: axum::response::Response) -> serde_json::Value {
    let bytes = resp.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&bytes).unwrap()
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

fn test_rate_card() -> RateCardRow {
    RateCardRow {
        id: Uuid::new_v4(),
        name: "default".to_string(),
        effective_from: Utc::now(),
        effective_until: None,
        storage_rate_per_mb_month: dec!(0.20),
        region_multipliers: json!({}),
        minimum_spend_cents: 500,
        shared_minimum_spend_cents: 200,
        cold_storage_rate_per_gb_month: dec!(0.02),
        object_storage_rate_per_gb_month: dec!(0.024),
        object_storage_egress_rate_per_gb: dec!(0.01),
        created_at: Utc::now(),
    }
}

fn build_app_with_email(
    customer_repo: Arc<common::MockCustomerRepo>,
    usage_repo: Arc<common::MockUsageRepo>,
    rate_card_repo: Arc<common::MockRateCardRepo>,
    invoice_repo: Arc<common::MockInvoiceRepo>,
    stripe_service: Arc<common::MockStripeService>,
    email_service: Arc<dyn EmailService>,
) -> axum::Router {
    let mut state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        usage_repo,
        rate_card_repo,
        invoice_repo,
        stripe_service,
    );
    state.email_service = email_service;
    api::router::build_router(state)
}

struct FailingInvoiceEmailService {
    invoice_ready_attempts: Arc<AtomicUsize>,
}

impl FailingInvoiceEmailService {
    fn new() -> Self {
        Self {
            invoice_ready_attempts: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn attempts(&self) -> usize {
        self.invoice_ready_attempts.load(Ordering::SeqCst)
    }
}

#[async_trait]
impl EmailService for FailingInvoiceEmailService {
    async fn send_verification_email(
        &self,
        _to: &str,
        _verify_token: &str,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_password_reset_email(
        &self,
        _to: &str,
        _reset_token: &str,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_invoice_ready_email(
        &self,
        _to: &str,
        _invoice_id: &str,
        _invoice_url: &str,
        _pdf_url: Option<&str>,
    ) -> Result<(), EmailError> {
        self.invoice_ready_attempts.fetch_add(1, Ordering::SeqCst);
        Err(EmailError::DeliveryFailed(
            "forced invoice email failure".to_string(),
        ))
    }

    async fn send_quota_warning_email(
        &self,
        _to: &str,
        _metric: &str,
        _percent_used: f64,
        _current_usage: u64,
        _limit: u64,
    ) -> Result<(), EmailError> {
        Ok(())
    }

    async fn send_broadcast_email(
        &self,
        _to: &str,
        _subject: &str,
        _html_body: Option<&str>,
        _text_body: Option<&str>,
    ) -> Result<(), EmailError> {
        Ok(())
    }
}

#[tokio::test]
async fn finalize_invoice_sends_email() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_service = mock_stripe_service();
    let email_service = Arc::new(MockEmailService::new());

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    let app = build_app_with_email(
        customer_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo,
        stripe_service,
        email_service.clone() as Arc<dyn EmailService>,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["status"], "finalized");

    let sent_emails = email_service.sent_emails();
    assert_eq!(sent_emails.len(), 1);
    assert_eq!(sent_emails[0].to, customer.email);
    assert!(
        sent_emails[0].body.contains(&invoice.id.to_string()),
        "invoice ID should be present in email body"
    );
    assert!(
        sent_emails[0]
            .body
            .contains("https://invoice.stripe.com/mock"),
        "hosted invoice URL should be present in email body"
    );
    assert!(
        sent_emails[0]
            .body
            .contains("https://invoice.stripe.com/mock/pdf"),
        "PDF invoice URL should be present in email body"
    );
}

#[tokio::test]
async fn finalize_invoice_email_failure_does_not_block() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_service = mock_stripe_service();
    let email_service = Arc::new(FailingInvoiceEmailService::new());

    let customer = seed_stripe_customer(&customer_repo, "Acme", "acme@example.com").await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);

    let app = build_app_with_email(
        customer_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_service,
        email_service.clone() as Arc<dyn EmailService>,
    );

    let resp = app
        .oneshot(
            Request::post(format!("/admin/invoices/{}/finalize", invoice.id))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        email_service.attempts(),
        1,
        "invoice email should be attempted even when delivery fails"
    );

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "finalized");
}

#[tokio::test]
async fn batch_billing_sends_emails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let usage_repo = mock_usage_repo();
    let rate_card_repo = mock_rate_card_repo();
    let stripe_service = mock_stripe_service();
    let email_service = Arc::new(MockEmailService::new());

    rate_card_repo.seed_active_card(test_rate_card());

    let customer_a = seed_stripe_customer(&customer_repo, "Alpha", "alpha@example.com").await;
    let customer_b = seed_stripe_customer(&customer_repo, "Beta", "beta@example.com").await;

    usage_repo.seed(
        customer_a.id,
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
        "us-east-1",
        10_000,
        100,
        0,
        0,
    );
    usage_repo.seed(
        customer_b.id,
        NaiveDate::from_ymd_opt(2026, 1, 20).unwrap(),
        "us-east-1",
        20_000,
        200,
        0,
        0,
    );

    let app = build_app_with_email(
        customer_repo,
        usage_repo,
        rate_card_repo,
        invoice_repo.clone(),
        stripe_service,
        email_service.clone() as Arc<dyn EmailService>,
    );

    let resp = app
        .oneshot(
            Request::post("/admin/billing/run")
                .header("x-admin-key", TEST_ADMIN_KEY)
                .header("content-type", "application/json")
                .body(Body::from(r#"{"month":"2026-01"}"#))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    let body = body_json(resp).await;
    assert_eq!(body["invoices_created"], 2);

    let sent_emails = email_service.sent_emails();
    assert_eq!(sent_emails.len(), 2);

    let invoice_a = invoice_repo
        .list_by_customer(customer_a.id)
        .await
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    let invoice_b = invoice_repo
        .list_by_customer(customer_b.id)
        .await
        .unwrap()
        .into_iter()
        .next()
        .unwrap();

    let email_a = sent_emails
        .iter()
        .find(|email| email.to == customer_a.email)
        .unwrap();
    let email_b = sent_emails
        .iter()
        .find(|email| email.to == customer_b.email)
        .unwrap();

    for (email, invoice_id) in [
        (email_a, invoice_a.id.to_string()),
        (email_b, invoice_b.id.to_string()),
    ] {
        assert!(
            email.body.contains(&invoice_id),
            "invoice ID should be present in invoice-ready email"
        );
        assert!(
            email.body.contains("https://invoice.stripe.com/mock"),
            "hosted invoice URL should be present in invoice-ready email"
        );
    }
}
