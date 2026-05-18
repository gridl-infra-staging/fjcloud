mod common;

use api::config::Config;
use api::repos::invoice_repo::InvoiceRepo;
use api::repos::CustomerRepo;
use api::startup::init_stripe_service;
use api::stripe::invoice_create_idempotency_key;
use chrono::NaiveDate;
use rust_decimal_macros::dec;
use std::sync::{Mutex, OnceLock};
use uuid::Uuid;

use common::{mock_invoice_repo, mock_repo};

fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: Option<&str>) -> Self {
        let previous = std::env::var(key).ok();
        // SAFETY: The env lock serializes these process-env mutations.
        unsafe {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        Self { key, previous }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        // SAFETY: The env lock serializes these process-env mutations.
        unsafe {
            match &self.previous {
                Some(value) => std::env::set_var(self.key, value),
                None => std::env::remove_var(self.key),
            }
        }
    }
}

fn config_without_live_stripe() -> Config {
    Config {
        database_url: "postgres://localhost/fjcloud".to_string(),
        listen_addr: "0.0.0.0:3001".to_string(),
        s3_listen_addr: "0.0.0.0:3002".to_string(),
        s3_rate_limit_rps: 100,
        jwt_secret: "super-secret-key-for-testing-1234".to_string(),
        admin_key: "admin-bootstrap-key-for-testing".to_string(),
        stripe_secret_key: None,
        stripe_publishable_key: None,
        stripe_webhook_secret: None,
        stripe_success_url: "http://localhost:5173/dashboard".to_string(),
        stripe_cancel_url: "http://localhost:5173/dashboard".to_string(),
        internal_auth_token: None,
        google_oauth_client_id: None,
        google_oauth_client_secret: None,
        github_oauth_client_id: None,
        github_oauth_client_secret: None,
        dunning_emails_disabled: false,
    }
}

// ============================================================================
// CustomerRepo extensions: set_stripe_customer_id
// ============================================================================

#[tokio::test]
async fn set_stripe_customer_id_updates_customer() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");

    let updated = repo
        .set_stripe_customer_id(customer.id, "cus_abc123")
        .await
        .unwrap();
    assert!(updated);

    let found = repo.find_by_id(customer.id).await.unwrap().unwrap();
    assert_eq!(found.stripe_customer_id.as_deref(), Some("cus_abc123"));
}

#[tokio::test]
async fn find_by_stripe_customer_id_returns_customer() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");

    repo.set_stripe_customer_id(customer.id, "cus_abc123")
        .await
        .unwrap();

    let found = repo.find_by_stripe_customer_id("cus_abc123").await.unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, customer.id);
}

#[tokio::test]
async fn find_by_stripe_customer_id_returns_none_when_not_found() {
    let repo = mock_repo();

    let found = repo
        .find_by_stripe_customer_id("cus_does_not_exist")
        .await
        .unwrap();
    assert!(found.is_none());
}

#[tokio::test]
async fn set_stripe_customer_id_nonexistent_returns_false() {
    let repo = mock_repo();
    let result = repo
        .set_stripe_customer_id(uuid::Uuid::new_v4(), "cus_abc123")
        .await
        .unwrap();
    assert!(!result);
}

#[tokio::test]
async fn set_stripe_customer_id_deleted_customer_returns_false() {
    let repo = mock_repo();
    let customer = repo.seed_deleted("Del Co", "del@example.com");

    let result = repo
        .set_stripe_customer_id(customer.id, "cus_abc123")
        .await
        .unwrap();
    assert!(!result);
}

// ============================================================================
// CustomerRepo extensions: suspend / reactivate
// ============================================================================

#[tokio::test]
async fn suspend_sets_status_to_suspended() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");

    let updated = repo.suspend(customer.id).await.unwrap();
    assert!(updated);

    let found = repo.find_by_id(customer.id).await.unwrap().unwrap();
    assert_eq!(found.status, "suspended");
}

#[tokio::test]
async fn suspend_nonexistent_returns_false() {
    let repo = mock_repo();
    let result = repo.suspend(uuid::Uuid::new_v4()).await.unwrap();
    assert!(!result);
}

#[tokio::test]
async fn suspend_already_suspended_returns_false() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");
    repo.suspend(customer.id).await.unwrap();

    // Second suspend should return false — already suspended
    let result = repo.suspend(customer.id).await.unwrap();
    assert!(!result);
}

#[tokio::test]
async fn reactivate_suspended_customer() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");
    repo.suspend(customer.id).await.unwrap();

    let updated = repo.reactivate(customer.id).await.unwrap();
    assert!(updated);

    let found = repo.find_by_id(customer.id).await.unwrap().unwrap();
    assert_eq!(found.status, "active");
}

#[tokio::test]
async fn reactivate_non_suspended_returns_false() {
    let repo = mock_repo();
    let customer = repo.seed("Test Co", "test@example.com");

    // Active customer — reactivate should return false
    let result = repo.reactivate(customer.id).await.unwrap();
    assert!(!result);
}

#[tokio::test]
async fn reactivate_nonexistent_returns_false() {
    let repo = mock_repo();
    let result = repo.reactivate(uuid::Uuid::new_v4()).await.unwrap();
    assert!(!result);
}

// ============================================================================
// InvoiceRepo extensions: status transitions
// ============================================================================

fn seed_draft_invoice(
    repo: &common::MockInvoiceRepo,
    customer_id: uuid::Uuid,
) -> api::models::InvoiceRow {
    repo.seed(
        customer_id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        5000,
        5000,
        false,
        vec![api::repos::invoice_repo::NewLineItem {
            description: "Search requests".to_string(),
            quantity: dec!(1000),
            unit: "requests".to_string(),
            unit_price_cents: dec!(5),
            amount_cents: 5000,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    )
}

#[tokio::test]
async fn invoice_create_idempotency_key_is_deterministic_for_same_inputs() {
    let customer_id = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();

    let first = invoice_create_idempotency_key(customer_id, start, end);
    let second = invoice_create_idempotency_key(customer_id, start, end);
    assert_eq!(first, second);
    assert!(first.starts_with("fjcloud-invoice-"));
}

#[tokio::test]
async fn invoice_create_idempotency_key_changes_when_period_changes() {
    let customer_id = Uuid::new_v4();
    let start = NaiveDate::from_ymd_opt(2026, 1, 1).unwrap();
    let end = NaiveDate::from_ymd_opt(2026, 1, 31).unwrap();
    let alternate = NaiveDate::from_ymd_opt(2026, 2, 28).unwrap();

    let first = invoice_create_idempotency_key(customer_id, start, end);
    let second = invoice_create_idempotency_key(customer_id, start, alternate);
    assert_ne!(first, second);
}

// -- finalize --

#[tokio::test]
async fn finalize_draft_invoice_succeeds() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    let finalized = repo.finalize(invoice.id).await.unwrap();
    assert_eq!(finalized.status, "finalized");
    assert!(finalized.finalized_at.is_some());
}

#[tokio::test]
async fn finalize_non_draft_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    // Finalize once
    repo.finalize(invoice.id).await.unwrap();

    // Second finalize should fail — already finalized
    let result = repo.finalize(invoice.id).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn finalize_nonexistent_returns_error() {
    let repo = mock_invoice_repo();
    let result = repo.finalize(uuid::Uuid::new_v4()).await;
    assert!(result.is_err());
}

// -- mark_paid --

#[tokio::test]
async fn mark_paid_finalized_invoice_succeeds() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();

    let paid = repo.mark_paid(invoice.id).await.unwrap();
    assert_eq!(paid.status, "paid");
    assert!(paid.paid_at.is_some());
}

#[tokio::test]
async fn mark_paid_draft_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    let result = repo.mark_paid(invoice.id).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn mark_paid_already_paid_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();
    repo.mark_paid(invoice.id).await.unwrap();

    let result = repo.mark_paid(invoice.id).await;
    assert!(result.is_err());
}

// -- mark_failed --

#[tokio::test]
async fn mark_failed_finalized_invoice_succeeds() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();

    let failed = repo.mark_failed(invoice.id).await.unwrap();
    assert_eq!(failed.status, "failed");
}

#[tokio::test]
async fn mark_failed_draft_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    let result = repo.mark_failed(invoice.id).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn mark_failed_paid_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();
    repo.mark_paid(invoice.id).await.unwrap();

    let result = repo.mark_failed(invoice.id).await;
    assert!(result.is_err());
}

// -- mark_refunded --

#[tokio::test]
async fn mark_refunded_paid_invoice_succeeds() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();
    repo.mark_paid(invoice.id).await.unwrap();

    let refunded = repo.mark_refunded(invoice.id).await.unwrap();
    assert_eq!(refunded.status, "refunded");
}

#[tokio::test]
async fn mark_refunded_finalized_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);
    repo.finalize(invoice.id).await.unwrap();

    let result = repo.mark_refunded(invoice.id).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn mark_refunded_draft_rejects() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    let result = repo.mark_refunded(invoice.id).await;
    assert!(result.is_err());
}

// ============================================================================
// InvoiceRepo extensions: Stripe fields
// ============================================================================

#[tokio::test]
async fn set_stripe_fields_stores_both_values() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    repo.set_stripe_fields(
        invoice.id,
        "in_stripe_123",
        "https://invoice.stripe.com/i/abc",
        None,
    )
    .await
    .unwrap();

    let found = repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(found.stripe_invoice_id.as_deref(), Some("in_stripe_123"));
    assert_eq!(
        found.hosted_invoice_url.as_deref(),
        Some("https://invoice.stripe.com/i/abc")
    );
}

#[tokio::test]
async fn set_stripe_fields_nonexistent_returns_error() {
    let repo = mock_invoice_repo();
    let result = repo
        .set_stripe_fields(uuid::Uuid::new_v4(), "in_123", "https://stripe.com", None)
        .await;
    assert!(result.is_err());
}

// ============================================================================
// InvoiceRepo extensions: find_by_stripe_invoice_id
// ============================================================================

#[tokio::test]
async fn find_by_stripe_invoice_id_returns_invoice() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    repo.set_stripe_fields(invoice.id, "in_lookup_test", "https://stripe.com/inv", None)
        .await
        .unwrap();

    let found = repo
        .find_by_stripe_invoice_id("in_lookup_test")
        .await
        .unwrap();
    assert!(found.is_some());
    assert_eq!(found.unwrap().id, invoice.id);
}

#[tokio::test]
async fn find_by_stripe_invoice_id_returns_none_when_not_found() {
    let repo = mock_invoice_repo();
    let found = repo
        .find_by_stripe_invoice_id("in_nonexistent")
        .await
        .unwrap();
    assert!(found.is_none());
}

// ============================================================================
// Full lifecycle tests
// ============================================================================

#[tokio::test]
async fn full_lifecycle_draft_finalized_paid() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    assert_eq!(invoice.status, "draft");
    assert!(invoice.finalized_at.is_none());
    assert!(invoice.paid_at.is_none());

    let finalized = repo.finalize(invoice.id).await.unwrap();
    assert_eq!(finalized.status, "finalized");
    assert!(finalized.finalized_at.is_some());

    let paid = repo.mark_paid(invoice.id).await.unwrap();
    assert_eq!(paid.status, "paid");
    assert!(paid.paid_at.is_some());
}

#[tokio::test]
async fn full_lifecycle_draft_finalized_failed() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    repo.finalize(invoice.id).await.unwrap();
    let failed = repo.mark_failed(invoice.id).await.unwrap();
    assert_eq!(failed.status, "failed");
}

#[tokio::test]
async fn full_lifecycle_paid_refunded() {
    let repo = mock_invoice_repo();
    let cid = uuid::Uuid::new_v4();
    let invoice = seed_draft_invoice(&repo, cid);

    repo.finalize(invoice.id).await.unwrap();
    repo.mark_paid(invoice.id).await.unwrap();

    let refunded = repo.mark_refunded(invoice.id).await.unwrap();
    assert_eq!(refunded.status, "refunded");
}

// ============================================================================
// MockStripeService behavior tests
// ============================================================================

use api::startup::unconfigured_stripe::UnconfiguredStripeService;
use api::stripe::StripeChargeLookup;
use api::stripe::StripeError;
use api::stripe::StripeService;

#[tokio::test]
async fn mock_stripe_create_customer_returns_id() {
    let svc = common::mock_stripe_service();
    let id = svc
        .create_customer("Test Co", "test@example.com")
        .await
        .unwrap();
    assert!(id.starts_with("cus_mock_"));

    let customers = svc.customers.lock().unwrap();
    assert_eq!(customers.len(), 1);
    assert_eq!(customers[0].1, "Test Co");
    assert_eq!(customers[0].2, "test@example.com");
}

#[tokio::test]
async fn mock_stripe_create_customer_fails_when_set() {
    let svc = common::mock_stripe_service();
    svc.set_should_fail(true);
    let result = svc.create_customer("Test Co", "test@example.com").await;
    assert!(result.is_err());
}

#[tokio::test]
async fn mock_stripe_create_setup_intent_returns_secret() {
    let svc = common::mock_stripe_service();
    let secret = svc.create_setup_intent("cus_123").await.unwrap();
    assert!(secret.contains("cus_123"));
}

#[tokio::test]
async fn mock_stripe_list_payment_methods() {
    let svc = common::mock_stripe_service();
    svc.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_1".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });

    let methods = svc.list_payment_methods("cus_123").await.unwrap();
    assert_eq!(methods.len(), 1);
    assert_eq!(methods[0].last4, "4242");
}

#[tokio::test]
async fn mock_stripe_detach_payment_method() {
    let svc = common::mock_stripe_service();
    svc.seed_payment_method(api::stripe::PaymentMethodSummary {
        id: "pm_1".to_string(),
        card_brand: "visa".to_string(),
        last4: "4242".to_string(),
        exp_month: 12,
        exp_year: 2027,
        is_default: false,
    });

    svc.detach_payment_method("pm_1").await.unwrap();
    let methods = svc.list_payment_methods("cus_123").await.unwrap();
    assert!(methods.is_empty());
}

#[tokio::test]
async fn mock_stripe_set_default_payment_method() {
    let svc = common::mock_stripe_service();
    svc.set_default_payment_method("cus_123", "pm_1")
        .await
        .unwrap();

    let default = svc.default_pm.lock().unwrap().clone();
    assert_eq!(default, Some("pm_1".to_string()));
}

#[tokio::test]
async fn mock_stripe_create_and_finalize_invoice() {
    let svc = common::mock_stripe_service();
    let line_items = vec![api::stripe::StripeInvoiceLineItem {
        description: "Test charge".to_string(),
        amount_cents: 5000,
    }];

    let result = svc
        .create_and_finalize_invoice("cus_123", &line_items, None, Some("idempotency-key-1"))
        .await
        .unwrap();
    assert!(result.stripe_invoice_id.starts_with("in_mock_"));
    assert!(result.hosted_invoice_url.contains("stripe.com"));
}

#[tokio::test]
async fn mock_stripe_create_and_finalize_invoice_records_idempotency_key() {
    let svc = common::mock_stripe_service();
    let line_items = vec![api::stripe::StripeInvoiceLineItem {
        description: "Test charge".to_string(),
        amount_cents: 5000,
    }];

    svc.create_and_finalize_invoice("cus_123", &line_items, None, Some("idempotent-key-42"))
        .await
        .unwrap();

    let calls = svc.create_and_finalize_calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "cus_123");
    assert_eq!(calls[0].1, Some("idempotent-key-42".to_string()));
}

#[tokio::test]
async fn mock_stripe_pay_invoice_uses_default_result_and_records_call() {
    let svc = common::mock_stripe_service();
    svc.set_pay_invoice_result_default(api::stripe::PaidInvoice {
        id: "ignored_by_setter".to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(api::stripe::StripeLastPaymentError {
            code: Some("card_declined".to_string()),
            decline_code: Some("insufficient_funds".to_string()),
            message: Some("Declined".to_string()),
        }),
    });

    let result = svc.pay_invoice("in_mock_target").await.unwrap();
    assert_eq!(result.id, "in_mock_target");
    assert_eq!(result.status, "open");
    assert_eq!(result.amount_paid_cents, 0);
    assert_eq!(
        result.last_payment_error,
        Some(api::stripe::StripeLastPaymentError {
            code: Some("card_declined".to_string()),
            decline_code: Some("insufficient_funds".to_string()),
            message: Some("Declined".to_string()),
        })
    );

    let calls = svc.pay_invoice_calls.lock().unwrap();
    assert_eq!(calls.as_slice(), ["in_mock_target"]);
}

#[tokio::test]
async fn mock_stripe_void_invoice_records_call() {
    let svc = common::mock_stripe_service();

    let result = svc.void_invoice("in_mock_void").await.unwrap();
    assert_eq!(result.id, "in_mock_void");
    assert_eq!(result.status, "void");
    assert_eq!(result.amount_paid_cents, 0);
    assert!(result.last_payment_error.is_none());

    let calls = svc.void_invoice_calls.lock().unwrap();
    assert_eq!(calls.as_slice(), ["in_mock_void"]);
}

#[tokio::test]
async fn mock_stripe_construct_webhook_event_parses_payload() {
    let svc = common::mock_stripe_service();
    let payload = r#"{"id":"evt_123","type":"invoice.payment_succeeded","data":{"object":{}}}"#;

    let event = svc
        .construct_webhook_event(payload, "sig", "secret")
        .unwrap();
    assert_eq!(event.id, "evt_123");
    assert_eq!(event.event_type, "invoice.payment_succeeded");
}

#[tokio::test]
async fn mock_stripe_fails_when_should_fail_set() {
    let svc = common::mock_stripe_service();
    svc.set_should_fail(true);

    assert!(svc.create_setup_intent("cus_123").await.is_err());
    assert!(svc.list_payment_methods("cus_123").await.is_err());
    assert!(svc.detach_payment_method("pm_1").await.is_err());
    assert!(svc
        .set_default_payment_method("cus_123", "pm_1")
        .await
        .is_err());
    assert!(svc
        .create_and_finalize_invoice("cus_123", &[], None, None)
        .await
        .is_err());
    assert!(svc.pay_invoice("in_123").await.is_err());
    assert!(svc.void_invoice("in_123").await.is_err());
    assert!(svc.construct_webhook_event("{}", "sig", "secret").is_err());
}

#[tokio::test]
async fn mock_stripe_lookup_charge_fallback_returns_seeded_fields() {
    let svc = common::mock_stripe_service();
    svc.seed_charge_lookup(StripeChargeLookup {
        charge_id: "ch_test_123".to_string(),
        invoice_id: Some("in_test_123".to_string()),
        payment_intent_id: Some("pi_test_123".to_string()),
    });

    let lookup = svc
        .lookup_charge_fallback_fields("ch_test_123")
        .await
        .unwrap();
    assert_eq!(lookup.charge_id, "ch_test_123");
    assert_eq!(lookup.invoice_id.as_deref(), Some("in_test_123"));
    assert_eq!(lookup.payment_intent_id.as_deref(), Some("pi_test_123"));
}

#[tokio::test]
async fn mock_stripe_lookup_charge_fallback_propagates_api_error() {
    let svc = common::mock_stripe_service();
    svc.set_charge_lookup_error("charge lookup failed");

    let result = svc.lookup_charge_fallback_fields("ch_test_missing").await;
    assert!(matches!(
        result,
        Err(StripeError::Api(message)) if message == "charge lookup failed"
    ));
}

#[tokio::test]
async fn unconfigured_stripe_lookup_charge_fallback_returns_not_configured() {
    let svc = UnconfiguredStripeService;
    let result = svc.lookup_charge_fallback_fields("ch_test").await;
    assert!(matches!(result, Err(StripeError::NotConfigured)));
}

#[tokio::test]
async fn init_stripe_service_local_mode_requires_explicit_webhook_secret() {
    let _guard = env_lock().lock().expect("env lock poisoned");
    let _local_mode = EnvVarGuard::set("STRIPE_LOCAL_MODE", Some("1"));
    let _webhook_secret = EnvVarGuard::set("STRIPE_WEBHOOK_SECRET", None);
    let _webhook_url = EnvVarGuard::set("STRIPE_WEBHOOK_URL", None);

    let svc = init_stripe_service(&config_without_live_stripe());
    let result = svc.create_customer("Test Co", "test@example.com").await;
    assert!(matches!(result, Err(StripeError::NotConfigured)));
}

#[tokio::test]
async fn init_stripe_service_local_mode_uses_local_mock_when_webhook_secret_is_present() {
    let _guard = env_lock().lock().expect("env lock poisoned");
    let _local_mode = EnvVarGuard::set("STRIPE_LOCAL_MODE", Some("1"));
    let _webhook_secret = EnvVarGuard::set("STRIPE_WEBHOOK_SECRET", Some("whsec_test_local_mode"));
    let _webhook_url = EnvVarGuard::set("STRIPE_WEBHOOK_URL", None);

    let svc = init_stripe_service(&config_without_live_stripe());
    let result = svc.create_customer("Test Co", "test@example.com").await;
    assert!(matches!(result, Ok(customer_id) if customer_id.starts_with("cus_local_")));
}

#[tokio::test]
async fn mock_stripe_lookup_charge_fallback_honors_not_configured_seam() {
    let svc = common::mock_stripe_service();
    svc.set_not_configured(true);
    svc.seed_charge_lookup(StripeChargeLookup {
        charge_id: "ch_test_unconfigured".to_string(),
        invoice_id: Some("in_test".to_string()),
        payment_intent_id: Some("pi_test".to_string()),
    });

    let result = svc
        .lookup_charge_fallback_fields("ch_test_unconfigured")
        .await;
    assert!(matches!(result, Err(StripeError::NotConfigured)));
}
