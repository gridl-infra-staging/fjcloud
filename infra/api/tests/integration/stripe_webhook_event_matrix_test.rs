use std::sync::Arc;

use api::models::Customer;
use api::repos::invoice_repo::{InvoiceRepo, NewLineItem};
use api::repos::webhook_event_repo::WebhookEventRow;
use api::repos::CustomerRepo;
use api::repos::DisputeRepo;
use api::services::audit_log::ACTION_STRIPE_DISPUTE_UPDATED;
use api::services::email::{EmailService, MockEmailService, INVOICE_READY_SUBJECT};
use axum::http::StatusCode;
use chrono::{NaiveDate, Utc};
use rust_decimal_macros::dec;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

use crate::common::stripe_webhook_test_support::{
    dispute_closed_payload, dispute_created_payload, dispute_funds_withdrawn_payload,
    mock_stripe_webhook_app, webhook_request,
};
use crate::common::{
    mock_dispute_repo, mock_invoice_repo, mock_repo, mock_stripe_service, mock_webhook_event_repo,
    MockDisputeRepo, MockInvoiceRepo, MockStripeService, MockWebhookEventRepo, TestStateBuilder,
};

fn seed_draft_invoice(
    repo: &crate::common::MockInvoiceRepo,
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

fn seed_draft_invoice_with_amount(
    repo: &crate::common::MockInvoiceRepo,
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
    amount_cents: i64,
) -> api::models::InvoiceRow {
    repo.seed(
        customer_id,
        period_start,
        period_end,
        amount_cents,
        amount_cents,
        false,
        vec![NewLineItem {
            description: "Search requests".to_string(),
            quantity: dec!(1),
            unit: "invoice_total".to_string(),
            unit_price_cents: dec!(0),
            amount_cents,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    )
}

async fn seed_customer_with_stripe(
    repo: &crate::common::MockCustomerRepo,
    email: &str,
) -> Customer {
    let customer = repo.seed("Acme", email);
    repo.set_stripe_customer_id(
        customer.id,
        &format!("cus_test_{}", &customer.id.to_string()[..8]),
    )
    .await
    .unwrap();
    repo.find_by_id(customer.id).await.unwrap().unwrap()
}

fn payment_intent_invoice_event(
    event_id: &str,
    stripe_invoice_id: &str,
    payment_intent_id: &str,
) -> WebhookEventRow {
    WebhookEventRow {
        stripe_event_id: event_id.to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "data": {
                "object": {
                    "id": stripe_invoice_id,
                    "payment_intent": payment_intent_id
                }
            }
        }),
        processed_at: Some(Utc::now()),
        created_at: Utc::now(),
    }
}

async fn set_stripe_fields(
    invoice_repo: &MockInvoiceRepo,
    invoice_id: Uuid,
    stripe_invoice_id: &str,
    payment_intent_id: Option<&str>,
) {
    invoice_repo
        .set_stripe_fields(
            invoice_id,
            stripe_invoice_id,
            &format!("https://stripe.com/inv/{stripe_invoice_id}"),
            payment_intent_id,
        )
        .await
        .unwrap();
}

async fn seed_paid_invoice_with_payment_intent(
    invoice_repo: &MockInvoiceRepo,
    webhook_event_repo: &MockWebhookEventRepo,
    customer_id: Uuid,
    stripe_invoice_id: &str,
    payment_intent_id: &str,
) -> api::models::InvoiceRow {
    let invoice = seed_draft_invoice(invoice_repo, customer_id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();
    set_stripe_fields(
        invoice_repo,
        invoice.id,
        stripe_invoice_id,
        Some(payment_intent_id),
    )
    .await;
    webhook_event_repo.seed_row(payment_intent_invoice_event(
        &format!("evt_seed_{stripe_invoice_id}_lookup"),
        stripe_invoice_id,
        payment_intent_id,
    ));
    invoice
}

struct DisputeWebhookFixture {
    app: axum::Router,
    customer: Customer,
    invoice: api::models::InvoiceRow,
    invoice_repo: Arc<MockInvoiceRepo>,
    dispute_repo: Arc<MockDisputeRepo>,
    stripe_service: Arc<MockStripeService>,
}

impl DisputeWebhookFixture {
    fn stripe_customer_id(&self) -> &str {
        self.customer.stripe_customer_id.as_deref().unwrap()
    }

    async fn invoice_status(&self) -> String {
        self.invoice_repo
            .find_by_id(self.invoice.id)
            .await
            .unwrap()
            .unwrap()
            .status
    }
}

async fn post_webhook(app: axum::Router, payload: &str) -> StatusCode {
    app.oneshot(webhook_request(payload))
        .await
        .unwrap()
        .status()
}

async fn assert_dispute_invoice_status(
    fixture: DisputeWebhookFixture,
    payload: String,
    expected_status: &str,
    message: &str,
) {
    assert_eq!(
        post_webhook(fixture.app.clone(), &payload).await,
        StatusCode::OK
    );
    assert_eq!(fixture.invoice_status().await, expected_status, "{message}");
}

async fn assert_dispute_invoice_link(
    fixture: DisputeWebhookFixture,
    payload: String,
    dispute_id: &str,
) {
    assert_eq!(post_webhook(fixture.app, &payload).await, StatusCode::OK);
    let dispute = fixture
        .dispute_repo
        .find_by_stripe_dispute_id(dispute_id)
        .await
        .unwrap()
        .expect("dispute row should be persisted");
    assert_eq!(dispute.invoice_id, Some(fixture.invoice.id));
}

fn dispute_app(
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    invoice_repo: Arc<MockInvoiceRepo>,
    dispute_repo: Arc<MockDisputeRepo>,
    webhook_event_repo: Arc<MockWebhookEventRepo>,
    stripe_service: Arc<MockStripeService>,
) -> axum::Router {
    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(invoice_repo)
        .with_dispute_repo(dispute_repo)
        .with_webhook_event_repo(webhook_event_repo)
        .with_stripe_service(stripe_service)
        .build();
    api::router::build_router(state)
}

async fn dispute_webhook_fixture(
    email: &str,
    stripe_invoice_id: &str,
    payment_intent_id: &str,
) -> DisputeWebhookFixture {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let dispute_repo = mock_dispute_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, email).await;
    let invoice = seed_paid_invoice_with_payment_intent(
        &invoice_repo,
        &webhook_event_repo,
        customer.id,
        stripe_invoice_id,
        payment_intent_id,
    )
    .await;
    let app = dispute_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&dispute_repo),
        webhook_event_repo,
        Arc::clone(&stripe_service),
    );

    DisputeWebhookFixture {
        app,
        customer,
        invoice,
        invoice_repo,
        dispute_repo,
        stripe_service,
    }
}

async fn dispute_created_charge_lookup_fixture(
    email: &str,
    stripe_invoice_id: &str,
    payment_intent_id: &str,
) -> DisputeWebhookFixture {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let dispute_repo = mock_dispute_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, email).await;
    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    set_stripe_fields(
        &invoice_repo,
        invoice.id,
        stripe_invoice_id,
        Some(payment_intent_id),
    )
    .await;
    let app = dispute_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&dispute_repo),
        webhook_event_repo,
        Arc::clone(&stripe_service),
    );

    DisputeWebhookFixture {
        app,
        customer,
        invoice,
        invoice_repo,
        dispute_repo,
        stripe_service,
    }
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
async fn invoice_email_dispatch_includes_invoice_id() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let email_service = Arc::new(MockEmailService::new());
    let customer = seed_customer_with_stripe(&customer_repo, "paid-email@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    let hosted_invoice_url = "https://stripe.com/inv/paid-email";
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_matrix_payment_succeeded_email",
            hosted_invoice_url,
            None,
        )
        .await
        .unwrap();

    let state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(Arc::clone(&invoice_repo))
        .with_webhook_event_repo(Arc::clone(&webhook_event_repo))
        .with_stripe_service(stripe_service)
        .with_email_service(email_service.clone() as Arc<dyn EmailService>)
        .build();
    let app = api::router::build_router(state);

    let payload = r#"{"id":"evt_matrix_payment_succeeded_email","type":"invoice.payment_succeeded","data":{"object":{"id":"in_matrix_payment_succeeded_email"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    let sent_emails = email_service.sent_emails();
    assert_eq!(
        sent_emails.len(),
        1,
        "paid invoice webhook should dispatch one invoice-ready email"
    );
    assert_eq!(sent_emails[0].to, customer.email);
    assert_eq!(sent_emails[0].subject, INVOICE_READY_SUBJECT);
    assert!(
        sent_emails[0].html_body.contains(&invoice.id.to_string()),
        "invoice ID should be present in rendered HTML body"
    );
    assert!(
        sent_emails[0].html_body.contains(hosted_invoice_url),
        "hosted invoice URL should be present in rendered HTML body"
    );
    assert!(
        sent_emails[0].text_body.contains(&invoice.id.to_string()),
        "invoice ID should be present in rendered text body"
    );
    assert!(
        sent_emails[0].text_body.contains(hosted_invoice_url),
        "hosted invoice URL should be present in rendered text body"
    );
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

#[tokio::test]
async fn charge_refunded_payment_intent_fallback_marks_invoice_refunded() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "refund-pi@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_fallback_test",
            "https://stripe.com/inv/refund-pi",
            None,
        )
        .await
        .unwrap();
    webhook_event_repo.seed_row(payment_intent_invoice_event(
        "evt_seed_refund_pi_lookup",
        "in_fallback_test",
        "pi_fallback_test",
    ));

    let app = mock_stripe_webhook_app(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = r#"{"id":"evt_matrix_charge_refund_pi","type":"charge.refunded","data":{"object":{"payment_intent":"pi_fallback_test"}}}"#;
    let response = app.oneshot(webhook_request(payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 2);
    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "refunded");
}

#[tokio::test]
async fn charge_refunded_customer_amount_fallback_picks_matching_amount_invoice() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "refund-amount@example.com").await;

    let matching_invoice = seed_draft_invoice_with_amount(
        &invoice_repo,
        customer.id,
        NaiveDate::from_ymd_opt(2026, 2, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 2, 28).unwrap(),
        7500,
    );
    let newer_wrong_amount_invoice = seed_draft_invoice_with_amount(
        &invoice_repo,
        customer.id,
        NaiveDate::from_ymd_opt(2026, 3, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 3, 31).unwrap(),
        5000,
    );
    invoice_repo
        .set_stripe_fields(
            matching_invoice.id,
            "in_refund_matching_amount",
            "https://stripe.com/inv/refund-matching-amount",
            None,
        )
        .await
        .unwrap();
    invoice_repo
        .set_stripe_fields(
            newer_wrong_amount_invoice.id,
            "in_refund_newer_wrong_amount",
            "https://stripe.com/inv/refund-newer-wrong-amount",
            None,
        )
        .await
        .unwrap();
    invoice_repo.finalize(matching_invoice.id).await.unwrap();
    invoice_repo.mark_paid(matching_invoice.id).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    invoice_repo
        .finalize(newer_wrong_amount_invoice.id)
        .await
        .unwrap();
    invoice_repo
        .mark_paid(newer_wrong_amount_invoice.id)
        .await
        .unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = format!(
        r#"{{"id":"evt_matrix_charge_refund_amount","type":"charge.refunded","data":{{"object":{{"customer":"{}","amount_refunded":7500}}}}}}"#,
        customer.stripe_customer_id.as_deref().unwrap()
    );
    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
    let updated_matching = invoice_repo
        .find_by_id(matching_invoice.id)
        .await
        .unwrap()
        .unwrap();
    let updated_wrong_amount = invoice_repo
        .find_by_id(newer_wrong_amount_invoice.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_matching.status, "refunded");
    assert_eq!(updated_wrong_amount.status, "paid");
}

#[tokio::test]
async fn charge_refunded_customer_amount_fallback_ties_pick_most_recent_paid() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "refund-tie@example.com").await;

    let earlier_invoice = seed_draft_invoice_with_amount(
        &invoice_repo,
        customer.id,
        NaiveDate::from_ymd_opt(2026, 4, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 4, 30).unwrap(),
        7500,
    );
    let later_invoice = seed_draft_invoice_with_amount(
        &invoice_repo,
        customer.id,
        NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 5, 31).unwrap(),
        7500,
    );
    invoice_repo
        .set_stripe_fields(
            earlier_invoice.id,
            "in_refund_tie_earlier",
            "https://stripe.com/inv/refund-tie-earlier",
            None,
        )
        .await
        .unwrap();
    invoice_repo
        .set_stripe_fields(
            later_invoice.id,
            "in_refund_tie_later",
            "https://stripe.com/inv/refund-tie-later",
            None,
        )
        .await
        .unwrap();
    invoice_repo.finalize(earlier_invoice.id).await.unwrap();
    invoice_repo.mark_paid(earlier_invoice.id).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(5)).await;
    invoice_repo.finalize(later_invoice.id).await.unwrap();
    invoice_repo.mark_paid(later_invoice.id).await.unwrap();

    let app = mock_stripe_webhook_app(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&webhook_event_repo),
        stripe_service,
    );

    let payload = format!(
        r#"{{"id":"evt_matrix_charge_refund_tie","type":"charge.refunded","data":{{"object":{{"customer":"{}","amount_refunded":7500}}}}}}"#,
        customer.stripe_customer_id.as_deref().unwrap()
    );
    let response = app.oneshot(webhook_request(&payload)).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);
    let updated_earlier = invoice_repo
        .find_by_id(earlier_invoice.id)
        .await
        .unwrap()
        .unwrap();
    let updated_later = invoice_repo
        .find_by_id(later_invoice.id)
        .await
        .unwrap()
        .unwrap();
    // Pins the current tie-break for amount-ambiguous refunds.
    assert_eq!(updated_later.status, "refunded");
    assert_eq!(updated_earlier.status, "paid");
}

#[tokio::test]
async fn dispute_closed_with_won_status_does_not_refund_paid_invoice() {
    let fixture = dispute_webhook_fixture(
        "dispute-closed-won@example.com",
        "in_dispute_closed_won",
        "pi_dispute_closed_won",
    )
    .await;

    let payload = dispute_closed_payload(
        "evt_dispute_closed_won",
        "dp_dispute_closed_won",
        "ch_dispute_closed_won",
        Some("pi_dispute_closed_won"),
        fixture.stripe_customer_id(),
        5000,
        "won",
    );
    assert_dispute_invoice_status(
        fixture,
        payload,
        "paid",
        "won disputes must not transition paid invoices to refunded",
    )
    .await;
}

#[tokio::test]
async fn dispute_funds_withdrawn_marks_paid_invoice_refunded() {
    let fixture = dispute_webhook_fixture(
        "dispute-funds-withdrawn@example.com",
        "in_dispute_funds_withdrawn",
        "pi_dispute_funds_withdrawn",
    )
    .await;

    let payload = dispute_funds_withdrawn_payload(
        "evt_dispute_funds_withdrawn",
        "dp_dispute_funds_withdrawn",
        "ch_dispute_funds_withdrawn",
        Some("pi_dispute_funds_withdrawn"),
        fixture.stripe_customer_id(),
        5000,
    );
    assert_dispute_invoice_status(
        fixture,
        payload,
        "refunded",
        "funds_withdrawn disputes must transition the paid invoice to refunded",
    )
    .await;
}

#[tokio::test]
async fn dispute_closed_with_lost_status_marks_paid_invoice_refunded() {
    let fixture = dispute_webhook_fixture(
        "dispute-closed-lost@example.com",
        "in_dispute_closed_lost",
        "pi_dispute_closed_lost",
    )
    .await;

    let payload = dispute_closed_payload(
        "evt_dispute_closed_lost",
        "dp_dispute_closed_lost",
        "ch_dispute_closed_lost",
        Some("pi_dispute_closed_lost"),
        fixture.stripe_customer_id(),
        5000,
        "lost",
    );
    assert_dispute_invoice_status(
        fixture,
        payload,
        "refunded",
        "lost disputes must transition the paid invoice to refunded",
    )
    .await;
}

#[tokio::test]
async fn dispute_created_prefers_webhook_event_invoice_mapping_for_upsert_link() {
    let fixture = dispute_webhook_fixture(
        "dispute-prefer-webhook@example.com",
        "in_dispute_preferred_webhook",
        "pi_dispute_preferred",
    )
    .await;
    fixture
        .stripe_service
        .seed_charge_lookup(api::stripe::StripeChargeLookup {
            charge_id: "ch_dispute_preferred".to_string(),
            invoice_id: Some("in_fallback_should_not_win".to_string()),
            payment_intent_id: Some("pi_dispute_preferred".to_string()),
        });

    let payload = dispute_created_payload(
        "evt_dispute_created_prefer_webhook",
        "dp_prefer_webhook",
        "ch_dispute_preferred",
        Some("pi_dispute_preferred"),
        fixture.stripe_customer_id(),
        5000,
    );
    assert_dispute_invoice_link(fixture, payload, "dp_prefer_webhook").await;
}

#[tokio::test]
async fn dispute_created_falls_back_to_charge_lookup_when_event_repo_has_no_invoice_mapping() {
    let fixture = dispute_created_charge_lookup_fixture(
        "dispute-fallback-charge@example.com",
        "in_dispute_fallback_charge",
        "pi_dispute_fallback",
    )
    .await;
    fixture
        .stripe_service
        .seed_charge_lookup(api::stripe::StripeChargeLookup {
            charge_id: "ch_dispute_fallback".to_string(),
            invoice_id: Some("in_dispute_fallback_charge".to_string()),
            payment_intent_id: Some("pi_dispute_fallback".to_string()),
        });

    let payload = dispute_created_payload(
        "evt_dispute_created_fallback_charge",
        "dp_fallback_charge",
        "ch_dispute_fallback",
        Some("pi_dispute_fallback"),
        fixture.stripe_customer_id(),
        5000,
    );
    assert_dispute_invoice_link(fixture, payload, "dp_fallback_charge").await;
}

async fn connect_and_migrate() -> Option<PgPool> {
    let Ok(url) = std::env::var("DATABASE_URL") else {
        println!("SKIP: DATABASE_URL not set — skipping dispute audit integration test");
        return None;
    };
    let normalized_url = url.to_ascii_lowercase();
    let uses_local_host = ["localhost", "127.0.0.1", "::1", "host=/var/run/postgresql"]
        .iter()
        .any(|needle| normalized_url.contains(needle));
    let targets_test_database = ["/test", "_test", "-test", "test?", "test&", "test#"]
        .iter()
        .any(|needle| normalized_url.contains(needle));

    // This ignored test runs migrations and cleanup SQL, so refuse anything that
    // does not obviously target a local disposable database.
    if !uses_local_host || !targets_test_database {
        println!(
            "SKIP: DATABASE_URL must target a local test database for dispute audit integration test"
        );
        return None;
    }
    let pool = PgPool::connect(&url).await.expect("connect integration db");
    sqlx::migrate!("../migrations")
        .run(&pool)
        .await
        .expect("run migrations");
    Some(pool)
}

#[tokio::test]
#[ignore = "requires DATABASE_URL"]
async fn dispute_events_append_audit_log_rows_with_real_pool() {
    let Some(pool) = connect_and_migrate().await else {
        return;
    };
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let dispute_repo = mock_dispute_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();
    let customer = seed_customer_with_stripe(&customer_repo, "dispute-audit@example.com").await;

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_dispute_audit",
            "https://stripe.com/inv/dispute-audit",
            Some("pi_dispute_audit"),
        )
        .await
        .unwrap();
    webhook_event_repo.seed_row(WebhookEventRow {
        stripe_event_id: "evt_seed_dispute_audit_lookup".to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "data": {
                "object": {
                    "id": "in_dispute_audit",
                    "payment_intent": "pi_dispute_audit"
                }
            }
        }),
        processed_at: Some(Utc::now()),
        created_at: Utc::now(),
    });

    let mut state = TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(Arc::clone(&invoice_repo))
        .with_dispute_repo(dispute_repo)
        .with_webhook_event_repo(Arc::clone(&webhook_event_repo))
        .with_stripe_service(stripe_service)
        .build();
    state.pool = pool.clone();
    let app = api::router::build_router(state);

    let payload = dispute_funds_withdrawn_payload(
        "evt_dispute_funds_withdrawn_audit",
        "dp_dispute_audit",
        "ch_dispute_audit",
        Some("pi_dispute_audit"),
        customer.stripe_customer_id.as_deref().unwrap(),
        5000,
    );
    let response = app.oneshot(webhook_request(&payload)).await.unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let audit_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*)::BIGINT FROM audit_log WHERE action = $1 AND target_tenant_id = $2",
    )
    .bind(ACTION_STRIPE_DISPUTE_UPDATED)
    .bind(customer.id)
    .fetch_one(&pool)
    .await
    .expect("count audit rows");
    assert_eq!(audit_rows, 1, "expected one durable dispute audit row");

    let _ = sqlx::query("DELETE FROM audit_log WHERE action = $1 AND target_tenant_id = $2")
        .bind(ACTION_STRIPE_DISPUTE_UPDATED)
        .bind(customer.id)
        .execute(&pool)
        .await;
}
