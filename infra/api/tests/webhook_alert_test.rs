mod common;

use std::sync::Arc;

use api::repos::invoice_repo::InvoiceRepo;
use api::repos::CustomerRepo;
use api::services::alerting::{
    Alert, AlertError, AlertRecord, AlertService, AlertSeverity, MockAlertService,
};
use api::services::email::{EmailService, MockEmailService};
use async_trait::async_trait;
use axum::http::StatusCode;
use std::sync::Mutex;
use tower::ServiceExt;

use common::{
    mock_invoice_repo, mock_repo,
    stripe_webhook_test_support::{
        dispute_closed_payload, dispute_created_payload, dispute_funds_reinstated_payload,
        dispute_funds_withdrawn_payload, seed_draft_invoice,
        test_app_with_alert_and_email_services, webhook_request,
    },
};

fn test_app_with_alert_service(
    customer_repo: Arc<common::MockCustomerRepo>,
    invoice_repo: Arc<common::MockInvoiceRepo>,
    alert_service: Arc<dyn AlertService>,
) -> axum::Router {
    test_app_with_alert_and_email_services(
        customer_repo,
        invoice_repo,
        alert_service,
        Arc::new(MockEmailService::new()) as Arc<dyn EmailService>,
        false,
    )
}

struct FailingAlertService {
    attempted_severities: Mutex<Vec<AlertSeverity>>,
}

impl FailingAlertService {
    fn new() -> Self {
        Self {
            attempted_severities: Mutex::new(Vec::new()),
        }
    }

    fn attempted_severities(&self) -> Vec<AlertSeverity> {
        self.attempted_severities.lock().unwrap().clone()
    }
}

#[async_trait]
impl AlertService for FailingAlertService {
    async fn send_alert(&self, alert: Alert) -> Result<(), AlertError> {
        self.attempted_severities
            .lock()
            .unwrap()
            .push(alert.severity);
        Err(AlertError::SendFailed(
            "synthetic alert send failure".to_string(),
        ))
    }

    async fn get_recent_alerts(&self, _limit: i64) -> Result<Vec<AlertRecord>, AlertError> {
        Ok(Vec::new())
    }
}

#[tokio::test]
async fn payment_failed_with_retries_sends_warning_alert() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_retry_alert",
            "https://stripe.com/inv/retry",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        customer_repo,
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_retry_alert","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_retry_alert","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let updated = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated.status, "finalized");

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1, "expected exactly one warning alert");
    let alert = &alerts[0];
    assert_eq!(alert.severity, AlertSeverity::Warning);
    assert!(alert.title.to_lowercase().contains("payment failed"));

    let metadata = alert.metadata.as_object().unwrap();
    let customer_id = customer.id.to_string();
    let invoice_id = invoice.id.to_string();
    let amount_cents = invoice.total_cents.to_string();
    assert_eq!(metadata["customer_id"].as_str(), Some(customer_id.as_str()));
    assert_eq!(metadata["invoice_id"].as_str(), Some(invoice_id.as_str()));
    assert_eq!(
        metadata["amount_cents"].as_str(),
        Some(amount_cents.as_str())
    );
    assert_eq!(
        metadata["next_payment_attempt"].as_str(),
        Some("1708300800")
    );
    assert_eq!(metadata["attempt_count"].as_str(), Some("2"));
}

#[tokio::test]
async fn payment_failed_with_retries_keeps_invoice_finalized_and_customer_active() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_retry_subscription_active",
            "https://stripe.com/inv/retry_subscription_active",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_retry_keeps_active","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_retry_subscription_active","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "finalized");
    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");
}

#[tokio::test]
async fn payment_action_required_sends_warning_alert_without_suspending_customer() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_action_required")
        .await
        .unwrap();

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_action_required",
            "https://stripe.com/inv/required",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_action_required","type":"invoice.payment_action_required","data":{"object":{"id":"in_action_required","customer":"cus_action_required"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    let alert = &alerts[0];
    assert_eq!(alert.severity, AlertSeverity::Warning);
    assert!(alert
        .title
        .to_lowercase()
        .contains("payment action required"));
    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "finalized");
    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");
}

#[tokio::test]
async fn payment_failed_exhausted_retries_sends_critical_alert() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_exhausted_alert",
            "https://stripe.com/inv/exhausted",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_fail_alert","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_exhausted_alert","next_payment_attempt":null}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "failed");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "suspended");

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1, "expected exactly one critical alert");
    let alert = &alerts[0];
    assert_eq!(alert.severity, AlertSeverity::Critical);
    assert!(alert.title.to_lowercase().contains("payment"));

    let metadata = alert.metadata.as_object().unwrap();
    let customer_id = customer.id.to_string();
    let invoice_id = invoice.id.to_string();
    let amount_cents = invoice.total_cents.to_string();
    assert_eq!(metadata["customer_id"].as_str(), Some(customer_id.as_str()));
    assert_eq!(metadata["invoice_id"].as_str(), Some(invoice_id.as_str()));
    assert_eq!(
        metadata["amount_cents"].as_str(),
        Some(amount_cents.as_str())
    );
    assert_eq!(
        metadata["customer_email"].as_str(),
        Some("acme@example.com")
    );
}

#[tokio::test]
async fn payment_succeeded_after_failed_invoice_sends_recovery_info_alert() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_recovery_alert",
            "https://stripe.com/inv/recovery",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_recovery_alert","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_recovery_alert"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1, "expected exactly one recovery info alert");
    let alert = &alerts[0];
    assert_eq!(alert.severity, AlertSeverity::Info);
    assert!(alert.title.to_lowercase().contains("recovered"));

    let metadata = alert.metadata.as_object().unwrap();
    let customer_id = customer.id.to_string();
    let invoice_id = invoice.id.to_string();
    let amount_cents = invoice.total_cents.to_string();
    assert_eq!(metadata["customer_id"].as_str(), Some(customer_id.as_str()));
    assert_eq!(metadata["invoice_id"].as_str(), Some(invoice_id.as_str()));
    assert_eq!(
        metadata["amount_cents"].as_str(),
        Some(amount_cents.as_str())
    );
}

#[tokio::test]
async fn payment_succeeded_without_prior_failure_does_not_send_recovery_alert() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_normal_success",
            "https://stripe.com/inv/normal_success",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_normal_success","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_normal_success"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    assert_eq!(
        alert_service.alert_count(),
        0,
        "payment success for non-failed invoice should not send recovery alert"
    );
}

#[tokio::test]
async fn payment_succeeded_replay_is_idempotent() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_replay_success",
            "https://stripe.com/inv/replay_success",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_replay_success","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_replay_success"}}}"#;
    let resp1 = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    let resp2 = app.clone().oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp1.status(), StatusCode::OK);
    assert_eq!(resp2.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");

    assert_eq!(
        alert_service.alert_count(),
        1,
        "replayed payment_succeeded event should not duplicate recovery alert"
    );
}

/// Verifies the webhook returns 200 and the recovery alert is still sent even
/// when `reactivate()` returns an error.  If reactivate errors were propagated
/// via `?`, the event would not be marked processed — but on retry the invoice
/// is already "paid" so the was_failed branch is never entered and reactivate
/// would never be retried, leaving the customer permanently suspended.
#[tokio::test]
async fn payment_recovery_succeeds_even_when_reactivate_fails() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let customer = customer_repo.seed("FailCo", "fail@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_reactivate_fail",
            "https://stripe.com/inv/reactivate_fail",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();

    // Inject failure into reactivate
    *customer_repo.should_fail_reactivate.lock().unwrap() = true;

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_reactivate_fail","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_reactivate_fail"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();

    // Webhook must return 200 even when reactivate fails
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "webhook must not propagate reactivation errors"
    );

    // Invoice should still be marked paid (this happens before reactivate)
    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    // Recovery alert should still be sent (best-effort, after reactivate)
    let alerts = alert_service.recorded_alerts();
    assert_eq!(
        alerts.len(),
        1,
        "recovery alert should still be sent even when reactivate fails"
    );
    assert_eq!(alerts[0].severity, AlertSeverity::Info);
}

#[tokio::test]
async fn payment_failed_warning_alert_failure_is_swallowed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(FailingAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_warning_alert_fail",
            "https://stripe.com/inv/warning_alert_fail",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_warning_alert_fail","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_warning_alert_fail","next_payment_attempt":1708300800,"attempt_count":2}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "webhook must not fail when warning alert delivery fails"
    );

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "finalized");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");

    assert_eq!(
        alert_service.attempted_severities(),
        vec![AlertSeverity::Warning]
    );
}

#[tokio::test]
async fn payment_succeeded_recovery_alert_failure_is_swallowed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(FailingAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_recovery_alert_fail",
            "https://stripe.com/inv/recovery_alert_fail",
            None,
        )
        .await
        .unwrap();
    invoice_repo.mark_failed(invoice.id).await.unwrap();
    customer_repo.suspend(customer.id).await.unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_recovery_alert_fail","type":"invoice.payment_succeeded","data":{"object":{"id":"in_stripe_recovery_alert_fail"}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "webhook must not fail when recovery alert delivery fails"
    );

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "active");

    assert_eq!(
        alert_service.attempted_severities(),
        vec![AlertSeverity::Info]
    );
}

#[tokio::test]
async fn payment_failed_critical_alert_failure_is_swallowed() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(FailingAlertService::new());
    let customer = customer_repo.seed("Acme", "acme@example.com");

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_stripe_critical_alert_fail",
            "https://stripe.com/inv/critical_alert_fail",
            None,
        )
        .await
        .unwrap();

    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_critical_alert_fail","type":"invoice.payment_failed","data":{"object":{"id":"in_stripe_critical_alert_fail","next_payment_attempt":null}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(
        resp.status(),
        StatusCode::OK,
        "webhook must not fail when critical alert delivery fails"
    );

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "failed");

    let updated_customer = customer_repo
        .find_by_id(customer.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated_customer.status, "suspended");

    assert_eq!(
        alert_service.attempted_severities(),
        vec![AlertSeverity::Critical]
    );
}

#[tokio::test]
async fn payment_failed_for_unknown_invoice_is_ignored() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());

    let app = test_app_with_alert_service(
        customer_repo,
        invoice_repo,
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    let payload = r#"{"id":"evt_unknown_invoice_failed","type":"invoice.payment_failed","data":{"object":{"id":"in_missing","next_payment_attempt":1708300800,"attempt_count":1}}}"#;
    let resp = app.oneshot(webhook_request(payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);
    assert_eq!(
        alert_service.alert_count(),
        0,
        "unknown invoice payment_failed should be ignored without side effects"
    );
}

#[tokio::test]
async fn deprecated_subscription_events_do_not_emit_alerts() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());

    let app = test_app_with_alert_service(
        customer_repo,
        invoice_repo,
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );

    for (event_id, event_type) in [
        ("evt_no_alert_sub_created", "customer.subscription.created"),
        ("evt_no_alert_sub_updated", "customer.subscription.updated"),
        ("evt_no_alert_sub_deleted", "customer.subscription.deleted"),
        (
            "evt_no_alert_checkout_completed",
            "checkout.session.completed",
        ),
    ] {
        let payload = format!(
            r#"{{"id":"{event_id}","type":"{event_type}","data":{{"object":{{"id":"legacy_noop"}}}}}}"#
        );
        let resp = app
            .clone()
            .oneshot(webhook_request(&payload))
            .await
            .unwrap();
        assert_eq!(resp.status(), StatusCode::OK);
    }

    assert_eq!(alert_service.alert_count(), 0);
}

#[tokio::test]
async fn dispute_created_emits_single_alert_with_invoice_metadata_when_resolved() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let webhook_event_repo = common::mock_webhook_event_repo();
    let stripe_service = common::mock_stripe_service();
    let customer = customer_repo.seed("Acme", "dispute-created-alert@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_dispute_created_alert")
        .await
        .unwrap();

    let invoice = seed_draft_invoice(&invoice_repo, customer.id);
    invoice_repo.finalize(invoice.id).await.unwrap();
    invoice_repo.mark_paid(invoice.id).await.unwrap();
    invoice_repo
        .set_stripe_fields(
            invoice.id,
            "in_dispute_created_alert",
            "https://stripe.com/inv/dispute-created",
            Some("pi_dispute_created_alert"),
        )
        .await
        .unwrap();

    webhook_event_repo.seed_row(api::repos::webhook_event_repo::WebhookEventRow {
        stripe_event_id: "evt_seed_dispute_created_alert_lookup".to_string(),
        event_type: "invoice.payment_succeeded".to_string(),
        payload: serde_json::json!({
            "data": {"object": {"id": "in_dispute_created_alert", "payment_intent": "pi_dispute_created_alert"}}
        }),
        processed_at: Some(chrono::Utc::now()),
        created_at: chrono::Utc::now(),
    });

    let state = common::TestStateBuilder::new()
        .with_customer_repo(customer_repo)
        .with_invoice_repo(Arc::clone(&invoice_repo))
        .with_webhook_event_repo(webhook_event_repo)
        .with_stripe_service(stripe_service)
        .with_alert_service(Arc::clone(&alert_service))
        .build();
    let app = api::router::build_router(state);

    let payload = dispute_created_payload(
        "evt_dispute_created_alert",
        "dp_dispute_created_alert",
        "ch_dispute_created_alert",
        Some("pi_dispute_created_alert"),
        "cus_dispute_created_alert",
        5000,
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    let metadata = alerts[0].metadata.as_object().unwrap();
    assert_eq!(
        metadata["stripe_dispute_id"].as_str(),
        Some("dp_dispute_created_alert")
    );
    assert_eq!(
        metadata["customer_id"].as_str(),
        Some(customer.id.to_string().as_str())
    );
    assert_eq!(
        metadata["invoice_id"].as_str(),
        Some(invoice.id.to_string().as_str())
    );
}

#[tokio::test]
async fn dispute_funds_withdrawn_unresolved_mapping_emits_single_alert_with_lookup_metadata() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );
    let customer = customer_repo.seed("Acme", "dispute-unresolved-alert@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_dispute_unresolved")
        .await
        .unwrap();

    let payload = dispute_funds_withdrawn_payload(
        "evt_dispute_unresolved_alert",
        "dp_dispute_unresolved_alert",
        "ch_dispute_unresolved_alert",
        Some("pi_dispute_unresolved"),
        "cus_dispute_unresolved",
        5000,
    );
    let resp = app.oneshot(webhook_request(&payload)).await.unwrap();
    assert_eq!(resp.status(), StatusCode::OK);

    let alerts = alert_service.recorded_alerts();
    assert_eq!(alerts.len(), 1);
    let metadata = alerts[0].metadata.as_object().unwrap();
    assert_eq!(
        metadata["invoice_resolution_source"].as_str(),
        Some("unresolved")
    );
    assert!(metadata.get("invoice_id").is_none());
}

#[tokio::test]
async fn dispute_funds_reinstated_and_closed_do_not_emit_alerts() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let alert_service = Arc::new(MockAlertService::new());
    let app = test_app_with_alert_service(
        Arc::clone(&customer_repo),
        Arc::clone(&invoice_repo),
        Arc::clone(&alert_service) as Arc<dyn AlertService>,
    );
    let customer = customer_repo.seed("Acme", "dispute-quiet-alert@example.com");
    customer_repo
        .set_stripe_customer_id(customer.id, "cus_dispute_quiet")
        .await
        .unwrap();

    let reinstated = dispute_funds_reinstated_payload(
        "evt_dispute_reinstated_quiet",
        "dp_dispute_quiet",
        "ch_dispute_quiet",
        Some("pi_dispute_quiet"),
        "cus_dispute_quiet",
        5000,
    );
    let closed = dispute_closed_payload(
        "evt_dispute_closed_quiet",
        "dp_dispute_quiet",
        "ch_dispute_quiet",
        Some("pi_dispute_quiet"),
        "cus_dispute_quiet",
        5000,
        "won",
    );

    let first = app
        .clone()
        .oneshot(webhook_request(&reinstated))
        .await
        .unwrap();
    let second = app.clone().oneshot(webhook_request(&closed)).await.unwrap();
    assert_eq!(first.status(), StatusCode::OK);
    assert_eq!(second.status(), StatusCode::OK);
    assert_eq!(alert_service.alert_count(), 0);
}
