use std::sync::Arc;

use api::repos::invoice_repo::InvoiceRepo;
use api::repos::CustomerRepo;
use api::services::alerting::{AlertService, AlertSeverity, MockAlertService};
use api::services::email::{
    EmailService, MockEmailService, DUNNING_RECOVERED_AFTER_FAILURE_SUBJECT,
    DUNNING_RETRIES_EXHAUSTED_SUBJECT, DUNNING_RETRY_SCHEDULED_SUBJECT, INVOICE_READY_SUBJECT,
};
use axum::http::StatusCode;
use tower::ServiceExt;

use crate::common::stripe_webhook_test_support::{
    seed_draft_invoice, test_app_with_alert_and_email_services, webhook_request,
};
use crate::common::{mock_invoice_repo, mock_repo};

fn test_app_with_services(
    customer_repo: Arc<crate::common::MockCustomerRepo>,
    invoice_repo: Arc<crate::common::MockInvoiceRepo>,
    alert_service: Arc<dyn AlertService>,
    email_service: Arc<dyn EmailService>,
    dunning_emails_disabled: bool,
) -> axum::Router {
    test_app_with_alert_and_email_services(
        customer_repo,
        invoice_repo,
        alert_service,
        email_service,
        dunning_emails_disabled,
    )
}

#[tokio::test]
async fn payment_failed_with_retries_sends_retry_scheduled_dunning_email() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_retry_dunning",
            "https://stripe.com/inv/retry_dunning",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_services(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_retry_dunning","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_retry_dunning","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sent = email_service.sent_emails();
    assert_eq!(sent.len(), 1, "expected exactly one dunning email");
    assert_eq!(sent[0].to, "acme@example.com");
    assert_eq!(sent[0].subject, DUNNING_RETRY_SCHEDULED_SUBJECT);
    assert!(sent[0].html_body.contains("2024-02-19 00:00:00 UTC"));
    assert!(sent[0].text_body.contains("2024-02-19 00:00:00 UTC"));
    assert!(sent[0]
        .html_body
        .contains("https://stripe.com/inv/retry_dunning"));
    assert!(sent[0]
        .text_body
        .contains("https://stripe.com/inv/retry_dunning"));
}

#[tokio::test]
async fn payment_failed_exhausted_retries_sends_exhausted_dunning_email() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_exhausted_dunning",
            "https://stripe.com/inv/exhausted_dunning",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_exhausted_dunning","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_exhausted_dunning","next_payment_attempt":null,"attempt_count":4}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sent = email_service.sent_emails();
    assert_eq!(sent.len(), 1, "expected exactly one dunning email");
    assert_eq!(sent[0].to, "acme@example.com");
    assert_eq!(sent[0].subject, DUNNING_RETRIES_EXHAUSTED_SUBJECT);
    assert!(sent[0].html_body.contains("attempt 4"));
    assert!(sent[0].text_body.contains("attempt 4"));
    assert!(sent[0]
        .html_body
        .contains("https://stripe.com/inv/exhausted_dunning"));
    assert!(sent[0]
        .text_body
        .contains("https://stripe.com/inv/exhausted_dunning"));
}

#[tokio::test]
async fn payment_failed_without_next_payment_attempt_does_not_suspend_customer_or_fail_invoice() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_missing_next_attempt",
            "https://stripe.com/inv/missing_next_attempt",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_missing_next_attempt","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_missing_next_attempt","attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let invoice_after = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(
        invoice_after.status, "finalized",
        "missing next_payment_attempt must not be treated as retries exhausted (billing_run_no_created_invoices regression)"
    );

    let customer_after = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        customer_after.status, "active",
        "missing next_payment_attempt must not suspend the customer"
    );
    assert!(
        email_service.sent_emails().is_empty(),
        "missing next_payment_attempt must not send dunning emails"
    );

    let alerts = alert_service.recorded_alerts();
    assert_eq!(
        alerts.len(),
        1,
        "missing next_payment_attempt should still emit a warning alert for operator visibility"
    );
    assert_eq!(alerts[0].severity, AlertSeverity::Warning);
}

#[tokio::test]
async fn payment_succeeded_after_failed_invoice_sends_recovery_dunning_email() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_recovery_dunning",
            "https://stripe.com/inv/recovery_dunning",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_recovery_dunning","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_recovery_dunning"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sent = email_service.sent_emails();
    assert_eq!(sent.len(), 1, "expected exactly one dunning email");
    assert_eq!(sent[0].to, "acme@example.com");
    assert_eq!(sent[0].subject, DUNNING_RECOVERED_AFTER_FAILURE_SUBJECT);
    assert!(sent[0]
        .html_body
        .contains("https://stripe.com/inv/recovery_dunning"));
    assert!(sent[0]
        .text_body
        .contains("https://stripe.com/inv/recovery_dunning"));
}

#[tokio::test]
async fn payment_succeeded_skips_recovery_email_when_reactivate_errors() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_recovery_dunning_reactivate_error",
            "https://stripe.com/inv/recovery_dunning_reactivate_error",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();
    *customer_repo.should_fail_reactivate.lock().unwrap() = true;

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_recovery_dunning_reactivate_error","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_recovery_dunning_reactivate_error"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        email_service.sent_emails().is_empty(),
        "reactivate errors must suppress recovery dunning email"
    );
}

#[tokio::test]
async fn payment_succeeded_skips_recovery_email_when_reactivate_returns_false() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_recovery_dunning_reactivate_false",
            "https://stripe.com/inv/recovery_dunning_reactivate_false",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_recovery_dunning_reactivate_false","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_recovery_dunning_reactivate_false"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert!(
        email_service.sent_emails().is_empty(),
        "reactivate=false must suppress recovery dunning email"
    );
}

#[tokio::test]
async fn payment_succeeded_without_prior_failure_does_not_send_recovery_dunning_email() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let email_service = Arc::new(MockEmailService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_normal_success_no_dunning",
            "https://stripe.com/inv/normal_success_no_dunning",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_normal_success_no_dunning","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_normal_success_no_dunning"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let sent = email_service.sent_emails();
    assert_eq!(
        sent.len(),
        1,
        "non-failed payment success should send only the invoice-ready email"
    );
    assert_eq!(sent[0].subject, INVOICE_READY_SUBJECT);
    assert_ne!(sent[0].subject, DUNNING_RECOVERED_AFTER_FAILURE_SUBJECT);
    assert!(sent[0].html_body.contains(&invoice.id.to_string()));
    assert!(sent[0]
        .html_body
        .contains("https://stripe.com/inv/normal_success_no_dunning"));
    assert!(sent[0].text_body.contains(&invoice.id.to_string()));
    assert!(sent[0]
        .text_body
        .contains("https://stripe.com/inv/normal_success_no_dunning"));
}

#[tokio::test]
async fn dunning_emails_disabled_suppresses_delivery_but_keeps_alerting_and_state_transitions() {
    let customer_repo_enabled = mock_repo();
    let invoice_repo_enabled = mock_invoice_repo();
    let alert_service_enabled = Arc::new(MockAlertService::new());
    let email_service_enabled = Arc::new(MockEmailService::new());
    let customer_enabled = customer_repo_enabled.seed("Acme", "acme@example.com");

    let enabled_invoice = seed_draft_invoice(&invoice_repo_enabled, customer_enabled.id);
    invoice_repo_enabled
        .finalize(enabled_invoice.id)
        .await
        .unwrap();
    invoice_repo_enabled
        .set_stripe_fields(
            enabled_invoice.id,
            "in_stripe_enabled_dunning",
            "https://stripe.com/inv/enabled_dunning",
            None,
        )
        .await
        .unwrap();

    let enabled_app = test_app_with_services(
        Arc::clone(&customer_repo_enabled),
        Arc::clone(&invoice_repo_enabled),
        Arc::clone(&alert_service_enabled) as Arc<dyn AlertService>,
        Arc::clone(&email_service_enabled) as Arc<dyn EmailService>,
        false,
    );

    let enabled_payload = r#"{"id":"evt_enabled_dunning","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_enabled_dunning","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let enabled_resp = enabled_app
        .oneshot(webhook_request(enabled_payload))
        .await
        .unwrap();
    assert_eq!(enabled_resp.status(), StatusCode::OK);
    assert_eq!(
        email_service_enabled.sent_emails().len(),
        1,
        "enabled dunning path should send email"
    );

    let customer_repo_disabled = mock_repo();
    let invoice_repo_disabled = mock_invoice_repo();
    let alert_service_disabled = Arc::new(MockAlertService::new());
    let email_service_disabled = Arc::new(MockEmailService::new());
    let customer_disabled = customer_repo_disabled.seed("Acme", "acme@example.com");

    let disabled_invoice = seed_draft_invoice(&invoice_repo_disabled, customer_disabled.id);
    invoice_repo_disabled
        .finalize(disabled_invoice.id)
        .await
        .unwrap();
    invoice_repo_disabled
        .set_stripe_fields(
            disabled_invoice.id,
            "in_stripe_disabled_dunning",
            "https://stripe.com/inv/disabled_dunning",
            None,
        )
        .await
        .unwrap();

    let disabled_app = test_app_with_services(
        Arc::clone(&customer_repo_disabled),
        Arc::clone(&invoice_repo_disabled),
        Arc::clone(&alert_service_disabled) as Arc<dyn AlertService>,
        Arc::clone(&email_service_disabled) as Arc<dyn EmailService>,
        true,
    );

    let disabled_payload = r#"{"id":"evt_disabled_dunning","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_disabled_dunning","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let disabled_resp = disabled_app
        .oneshot(webhook_request(disabled_payload))
        .await
        .unwrap();
    assert_eq!(disabled_resp.status(), StatusCode::OK);
    assert_eq!(
        email_service_disabled.sent_emails().len(),
        0,
        "disabled dunning path should suppress email delivery"
    );

    let disabled_invoice_after = invoice_repo_disabled
        .find_by_id(disabled_invoice.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        disabled_invoice_after.status, "finalized",
        "retry-scheduled path should keep invoice finalized even when email delivery is disabled"
    );
    let disabled_customer_after = customer_repo_disabled
        .find_by_id(customer_disabled.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        disabled_customer_after.status, "active",
        "retry-scheduled path should keep customer active even when email delivery is disabled"
    );

    let disabled_alerts = alert_service_disabled.recorded_alerts();
    assert_eq!(
        disabled_alerts.len(),
        1,
        "dunning email disable flag must not suppress webhook alerts"
    );
    assert_eq!(disabled_alerts[0].severity, AlertSeverity::Warning);
}

#[tokio::test]
async fn dunning_email_delivery_failure_is_swallowed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let (email_service, delegate) = crate::common::FailableEmailService::with_mock_delegate();
    email_service.fail_recipient("acme@example.com", "synthetic dunning failure");
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_dunning_failure",
            "https://stripe.com/inv/dunning_failure",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_services(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
        Arc::clone(&email_service) as Arc<dyn EmailService>,
        false,
    );

    let payload = r#"{"id":"evt_dunning_failure","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_dunning_failure","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(email_service.attempt_count(), 1);
    assert_eq!(
        email_service.attempted_recipients(),
        vec!["acme@example.com".to_string()]
    );
    assert!(
        delegate.sent_emails().is_empty(),
        "failed dunning send should not reach delegate transport"
    );
}
