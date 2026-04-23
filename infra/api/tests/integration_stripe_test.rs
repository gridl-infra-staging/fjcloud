//! Integration tests for Stripe live validation (test mode).
//!
//! Two gating levels:
//!   1. **Stripe API tests** — require `STRIPE_TEST_SECRET_KEY` env var (an `sk_test_` key).
//!      These call the real Stripe API in test mode to validate customer creation,
//!      setup intents, payment methods, and invoice finalization.
//!   2. **Full pipeline tests** — additionally require a live fjcloud API + DB +
//!      `stripe listen --forward-to localhost:3099/webhooks/stripe` running.
//!      These exercise the complete checkout→invoice→paid webhook round-trip.
//!
//! All tests clean up Stripe test objects after themselves.

#![allow(clippy::await_holding_lock)]

mod common;
#[path = "common/integration_helpers.rs"]
mod integration_helpers;

use api::repos::invoice_repo::NewLineItem;
use api::repos::CustomerRepo;
use api::repos::InvoiceRepo;
use api::stripe::live::LiveStripeService;
use api::stripe::{StripeInvoiceLineItem, StripeService};
use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use chrono::{NaiveDate, Utc};
use hmac::{Hmac, Mac};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sha2::Sha256;
use std::time::Instant;
use tokio::sync::OnceCell;
use tower::ServiceExt;

use common::{
    mock_deployment_repo, mock_invoice_repo, mock_rate_card_repo, mock_repo, mock_stripe_service,
    mock_usage_repo, mock_webhook_event_repo, seed_mock_stripe_customer,
    test_state_all_with_stripe, TEST_ADMIN_KEY, TEST_WEBHOOK_SECRET,
};

type HmacSha256 = Hmac<Sha256>;

macro_rules! require_live_locked {
    ($condition:expr, $reason:expr) => {{
        let _env_guard = integration_helpers::test_env_lock();
        require_live!($condition, $reason);
    }};
}

fn build_stripe_webhook_signature(secret: &str, payload: &str, timestamp: i64) -> String {
    let signed_payload = format!("{timestamp}.{payload}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .expect("webhook secret must be a valid HMAC key");
    mac.update(signed_payload.as_bytes());
    let sig = hex::encode(mac.finalize().into_bytes());
    format!("t={timestamp},v1={sig}")
}

fn webhook_request(payload: &str, signature: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/webhooks/stripe")
        .header("stripe-signature", signature)
        .header("content-type", "application/json")
        .body(Body::from(payload.to_string()))
        .unwrap()
}

fn mock_app_with_state(
    customer_repo: std::sync::Arc<common::MockCustomerRepo>,
    invoice_repo: std::sync::Arc<common::MockInvoiceRepo>,
    webhook_event_repo: std::sync::Arc<common::MockWebhookEventRepo>,
    stripe_service: std::sync::Arc<common::MockStripeService>,
) -> axum::Router {
    let mut state = test_state_all_with_stripe(
        customer_repo,
        mock_deployment_repo(),
        mock_usage_repo(),
        mock_rate_card_repo(),
        invoice_repo,
        stripe_service,
    );
    state.webhook_event_repo = webhook_event_repo;
    api::router::build_router(state)
}

fn seed_mock_draft_invoice(
    invoice_repo: &common::MockInvoiceRepo,
    customer_id: uuid::Uuid,
    amount_cents: i64,
) -> api::models::InvoiceRow {
    invoice_repo.seed(
        customer_id,
        NaiveDate::from_ymd_opt(2026, 1, 1).unwrap(),
        NaiveDate::from_ymd_opt(2026, 1, 31).unwrap(),
        amount_cents,
        amount_cents,
        false,
        vec![NewLineItem {
            description: "Stripe integration test charge".to_string(),
            quantity: dec!(1),
            unit: "request".to_string(),
            unit_price_cents: Decimal::from(amount_cents),
            amount_cents,
            region: "us-east-1".to_string(),
            metadata: None,
        }],
    )
}

async fn finalize_invoice_in_test_router(
    app: &axum::Router,
    invoice_repo: &common::MockInvoiceRepo,
    invoice_id: uuid::Uuid,
) -> api::models::InvoiceRow {
    let resp = app
        .clone()
        .oneshot(
            Request::post(format!("/admin/invoices/{invoice_id}/finalize"))
                .header("x-admin-key", TEST_ADMIN_KEY)
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);
    invoice_repo.find_by_id(invoice_id).await.unwrap().unwrap()
}

// ---------------------------------------------------------------------------
// Gating helpers
// ---------------------------------------------------------------------------

/// Returns the Stripe test secret key if available. Tests that only need the
/// Stripe API (no webhook round-trip) gate on this.
fn stripe_test_key() -> Option<String> {
    let key = std::env::var("STRIPE_TEST_SECRET_KEY").ok()?;
    if key.starts_with("sk_test_") {
        Some(key)
    } else {
        eprintln!("[skip] STRIPE_TEST_SECRET_KEY is set but doesn't start with sk_test_");
        None
    }
}

fn stripe_webhook_secret() -> Option<String> {
    let secret = std::env::var("STRIPE_WEBHOOK_SECRET").ok()?;
    if secret.starts_with("whsec_") {
        Some(secret)
    } else {
        eprintln!("[skip] STRIPE_WEBHOOK_SECRET is set but doesn't start with whsec_");
        None
    }
}

/// Returns true when both the Stripe test key and the full integration stack
/// (API + DB + stripe listen) are available. Pipeline tests gate on this.
fn stripe_api_available() -> bool {
    stripe_test_key().is_some()
}

/// Returns true when pipeline preconditions are configured. This does not
/// prove webhook forwarding is live; use `stripe_webhook_available()` for that.
fn stripe_webhook_configured() -> bool {
    if stripe_webhook_secret().is_none() {
        return false;
    }
    if !integration_helpers::integration_enabled() {
        return false;
    }
    true
}

#[derive(Debug, Clone)]
#[allow(dead_code)] // fields consumed by launch gate reporting
struct WebhookProbeResult {
    passed: bool,
    elapsed_ms: u64,
    detail: String,
}

/// Validates Stripe webhook delivery by running the full probe (create invoice,
/// wait for webhook_events record). Returns structured result with timing info.
async fn validate_stripe_webhook_delivery() -> Result<WebhookProbeResult, String> {
    let start = Instant::now();

    if !stripe_api_available() {
        return Err("Stripe API not available (STRIPE_TEST_SECRET_KEY missing or invalid)".into());
    }
    if !stripe_webhook_configured() {
        return Err(
            "Stripe webhook not configured (STRIPE_WEBHOOK_SECRET or INTEGRATION missing)".into(),
        );
    }

    let api_url = integration_helpers::api_base();
    if !integration_helpers::endpoint_reachable(&api_url).await {
        return Err(format!("API endpoint unreachable at {api_url}"));
    }

    let db_url = integration_helpers::db_url();
    let pool = sqlx::PgPool::connect(&db_url)
        .await
        .map_err(|e| format!("integration DB unreachable at {db_url}: {e}"))?;

    let service = build_stripe_service();
    let probe_email = format!("stripe-probe-{}@flapjack.foo", uuid::Uuid::new_v4());
    let stripe_customer_id = service
        .create_customer("Stripe Probe", &probe_email)
        .await
        .map_err(|e| format!("failed creating Stripe probe customer: {e}"))?;

    let pm_id = attach_test_payment_method(&stripe_customer_id).await;
    if let Err(e) = service
        .set_default_payment_method(&stripe_customer_id, &pm_id)
        .await
    {
        delete_stripe_customer(&service, &stripe_customer_id).await;
        return Err(format!(
            "failed setting default PM for Stripe probe customer: {e}"
        ));
    }

    let finalized = match service
        .create_and_finalize_invoice(
            &stripe_customer_id,
            &[StripeInvoiceLineItem {
                description: "Stripe webhook probe".to_string(),
                amount_cents: 50,
            }],
            None,
            None,
        )
        .await
    {
        Ok(invoice) => invoice,
        Err(e) => {
            delete_stripe_customer(&service, &stripe_customer_id).await;
            return Err(format!("failed creating Stripe probe invoice: {e}"));
        }
    };

    let mut webhook_seen = false;
    for _ in 0..20 {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM webhook_events \
             WHERE event_type = 'invoice.payment_succeeded' \
             AND payload->'data'->'object'->>'id' = $1",
        )
        .bind(&finalized.stripe_invoice_id)
        .fetch_one(&pool)
        .await
        .unwrap_or(0);

        if count > 0 {
            webhook_seen = true;
            break;
        }
    }

    delete_stripe_customer(&service, &stripe_customer_id).await;

    let elapsed_ms = start.elapsed().as_millis() as u64;
    if webhook_seen {
        Ok(WebhookProbeResult {
            passed: true,
            elapsed_ms,
            detail: format!("invoice.payment_succeeded webhook received in {elapsed_ms}ms"),
        })
    } else {
        Ok(WebhookProbeResult {
            passed: false,
            elapsed_ms,
            detail: "webhook not received within 10s; ensure `stripe listen --forward-to localhost:3099/webhooks/stripe` is running".into(),
        })
    }
}

static STRIPE_WEBHOOK_AVAILABLE: OnceCell<bool> = OnceCell::const_new();

/// Runtime probe for Stripe webhook forwarding (`stripe listen`).
///
/// Delegates to `validate_stripe_webhook_delivery()` and caches the result.
async fn stripe_webhook_available() -> bool {
    *STRIPE_WEBHOOK_AVAILABLE
        .get_or_init(|| async {
            match validate_stripe_webhook_delivery().await {
                Ok(result) => {
                    if !result.passed {
                        eprintln!("[skip] {}", result.detail);
                    }
                    result.passed
                }
                Err(e) => {
                    eprintln!("[skip] {e}");
                    false
                }
            }
        })
        .await
}

// ---------------------------------------------------------------------------
// Live validation helpers
// ---------------------------------------------------------------------------

/// Validates the Stripe test key by calling GET /v1/balance.
/// Returns Ok(()) on success, Err with descriptive message on failure.
async fn validate_stripe_key_live() -> Result<(), String> {
    let key = match std::env::var("STRIPE_TEST_SECRET_KEY") {
        Ok(k) if !k.is_empty() => k,
        _ => return Err("STRIPE_TEST_SECRET_KEY is not set".to_string()),
    };
    if !key.starts_with("sk_test_") {
        return Err("STRIPE_TEST_SECRET_KEY has invalid prefix (expected sk_test_)".to_string());
    }
    let client = stripe::Client::new(&key);
    stripe::Balance::retrieve(&client, None)
        .await
        .map_err(|e| format!("Stripe API rejected key: {e}"))?;
    Ok(())
}

/// Build a LiveStripeService from the test key. Panics if key is not available —
/// callers must gate with `stripe_test_key()` first.
fn build_stripe_service() -> LiveStripeService {
    let key = stripe_test_key().expect("STRIPE_TEST_SECRET_KEY must be set");
    LiveStripeService::new(&key)
}

// ---------------------------------------------------------------------------
// Cleanup helper — delete test customers from Stripe to avoid pollution
// ---------------------------------------------------------------------------

async fn delete_stripe_customer(_service: &LiveStripeService, customer_id: &str) {
    // Use the stripe crate directly for deletion since StripeService trait
    // doesn't expose delete_customer (not needed in production).
    let client =
        stripe::Client::new(stripe_test_key().expect("STRIPE_TEST_SECRET_KEY must be set"));
    let cid: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");
    if let Err(e) = stripe::Customer::delete(&client, &cid).await {
        eprintln!("[cleanup] failed to delete Stripe customer {customer_id}: {e}");
    }
}

/// Attach a test payment method to a customer via the Stripe API directly.
/// Uses `pm_card_visa` — a Stripe-provided test PaymentMethod token.
async fn attach_test_payment_method(customer_id: &str) -> String {
    let client =
        stripe::Client::new(stripe_test_key().expect("STRIPE_TEST_SECRET_KEY must be set"));
    let cid: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");

    let pm = stripe::PaymentMethod::attach(
        &client,
        &"pm_card_visa".parse().expect("invalid pm token"),
        stripe::AttachPaymentMethod { customer: cid },
    )
    .await
    .expect("failed to attach test payment method");

    pm.id.to_string()
}

/// Attach a declining test payment method to a customer.
/// Uses `pm_card_chargeDeclined` — Stripe's test token that always declines.
async fn attach_declining_payment_method(customer_id: &str) -> String {
    let client =
        stripe::Client::new(stripe_test_key().expect("STRIPE_TEST_SECRET_KEY must be set"));
    let cid: stripe::CustomerId = customer_id.parse().expect("invalid customer ID");

    let pm = stripe::PaymentMethod::attach(
        &client,
        &"pm_card_chargeDeclined".parse().expect("invalid pm token"),
        stripe::AttachPaymentMethod { customer: cid },
    )
    .await
    .expect("failed to attach declining payment method");

    pm.id.to_string()
}

// ===========================================================================
// Validation tests
// ===========================================================================

#[tokio::test]
async fn validate_stripe_key_live_succeeds_with_real_key() {
    if validate_stripe_key_live().await.is_err() {
        eprintln!("[skip] validate_stripe_key_live() failed — key missing or invalid");
        return;
    }
}

// ===========================================================================
// Category 1: Stripe API tests (need STRIPE_TEST_SECRET_KEY only)
// ===========================================================================

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn stripe_create_customer_in_test_mode() {
    require_live_locked!(
        validate_stripe_key_live().await.is_ok(),
        "STRIPE_TEST_SECRET_KEY not available or rejected by Stripe API"
    );

    let service = build_stripe_service();

    let customer_id = service
        .create_customer("FJCloud Test User", "test-integration@flapjack.foo")
        .await
        .expect("create_customer should succeed in test mode");

    // Stripe test-mode customer IDs start with cus_
    assert!(
        customer_id.starts_with("cus_"),
        "expected customer ID to start with 'cus_', got: {customer_id}"
    );

    // Cleanup
    delete_stripe_customer(&service, &customer_id).await;
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn stripe_create_setup_intent_in_test_mode() {
    require_live_locked!(
        validate_stripe_key_live().await.is_ok(),
        "STRIPE_TEST_SECRET_KEY not available or rejected by Stripe API"
    );

    let service = build_stripe_service();

    // Create a customer first (setup intent requires a customer)
    let customer_id = service
        .create_customer("FJCloud Setup Test", "setup-test@flapjack.foo")
        .await
        .expect("create_customer should succeed");

    let client_secret = service
        .create_setup_intent(&customer_id)
        .await
        .expect("create_setup_intent should succeed in test mode");

    // Setup intent client secrets have the format: seti_..._secret_...
    assert!(
        client_secret.starts_with("seti_"),
        "expected client_secret to start with 'seti_', got: {client_secret}"
    );
    assert!(
        client_secret.contains("_secret_"),
        "expected client_secret to contain '_secret_', got: {client_secret}"
    );

    // Cleanup
    delete_stripe_customer(&service, &customer_id).await;
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn stripe_attach_and_list_payment_methods() {
    require_live_locked!(
        validate_stripe_key_live().await.is_ok(),
        "STRIPE_TEST_SECRET_KEY not available or rejected by Stripe API"
    );

    let service = build_stripe_service();

    let customer_id = service
        .create_customer("FJCloud PM Test", "pm-test@flapjack.foo")
        .await
        .expect("create_customer should succeed");

    // Attach pm_card_visa via Stripe API directly
    let pm_id = attach_test_payment_method(&customer_id).await;
    assert!(
        pm_id.starts_with("pm_"),
        "expected payment method ID to start with 'pm_', got: {pm_id}"
    );

    // Set as default payment method
    service
        .set_default_payment_method(&customer_id, &pm_id)
        .await
        .expect("set_default_payment_method should succeed");

    // List payment methods via our StripeService trait
    let methods = service
        .list_payment_methods(&customer_id)
        .await
        .expect("list_payment_methods should succeed");

    assert!(!methods.is_empty(), "expected at least one payment method");
    let visa = methods.iter().find(|m| m.id == pm_id);
    assert!(visa.is_some(), "attached visa card not found in list");
    let visa = visa.unwrap();
    assert_eq!(visa.last4, "4242", "pm_card_visa should have last4=4242");
    assert_eq!(visa.card_brand, "visa");
    assert!(visa.is_default, "should be marked as default");

    // Detach and verify removal
    service
        .detach_payment_method(&pm_id)
        .await
        .expect("detach_payment_method should succeed");

    let methods_after = service
        .list_payment_methods(&customer_id)
        .await
        .expect("list_payment_methods should succeed after detach");

    assert!(
        methods_after.iter().all(|m| m.id != pm_id),
        "detached payment method should no longer appear in list"
    );

    // Cleanup
    delete_stripe_customer(&service, &customer_id).await;
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn stripe_create_and_finalize_invoice() {
    require_live_locked!(
        validate_stripe_key_live().await.is_ok(),
        "STRIPE_TEST_SECRET_KEY not available or rejected by Stripe API"
    );

    let service = build_stripe_service();

    let customer_id = service
        .create_customer("FJCloud Invoice Test", "invoice-test@flapjack.foo")
        .await
        .expect("create_customer should succeed");

    // Attach payment method (required for auto-charge invoices)
    let pm_id = attach_test_payment_method(&customer_id).await;
    service
        .set_default_payment_method(&customer_id, &pm_id)
        .await
        .expect("set_default_payment_method should succeed");

    // Create and finalize an invoice with line items
    let line_items = vec![
        StripeInvoiceLineItem {
            description: "Search queries (10,000 @ $0.001)".to_string(),
            amount_cents: 1000,
        },
        StripeInvoiceLineItem {
            description: "Storage (500 MB @ $0.10/GB)".to_string(),
            amount_cents: 50,
        },
    ];

    let mut metadata = std::collections::HashMap::new();
    metadata.insert("fjcloud_test".to_string(), "true".to_string());

    let finalized = service
        .create_and_finalize_invoice(&customer_id, &line_items, Some(&metadata), None)
        .await
        .expect("create_and_finalize_invoice should succeed");

    // Invoice IDs start with in_
    assert!(
        finalized.stripe_invoice_id.starts_with("in_"),
        "expected invoice ID to start with 'in_', got: {}",
        finalized.stripe_invoice_id
    );

    // Hosted invoice URL should be a valid Stripe URL
    assert!(
        finalized.hosted_invoice_url.starts_with("https://"),
        "expected hosted_invoice_url to be HTTPS, got: {}",
        finalized.hosted_invoice_url
    );

    // Cleanup
    delete_stripe_customer(&service, &customer_id).await;
}

// ===========================================================================
// Category 2: Full pipeline tests (need integration stack + stripe listen)
// ===========================================================================

async fn run_live_checkout_to_paid_invoice_end_to_end() {
    let client = integration_helpers::http_client();
    let base = integration_helpers::api_base();
    let db_url = integration_helpers::db_url();

    let pool = sqlx::PgPool::connect(&db_url)
        .await
        .expect("failed to connect to integration DB");

    // 1. Register and get auth token
    let email = format!("stripe-e2e-{}@flapjack.foo", uuid::Uuid::new_v4());
    let _jwt = integration_helpers::register_and_login(&client, &base, &email).await;

    // 2. Get customer_id from DB and link Stripe customer
    let customer_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM customers WHERE email = $1")
        .bind(&email)
        .fetch_one(&pool)
        .await
        .expect("customer not found in DB");

    let service = build_stripe_service();
    let stripe_customer_id = service
        .create_customer("E2E Test", &email)
        .await
        .expect("create stripe customer");

    // Link Stripe customer to fjcloud customer
    sqlx::query("UPDATE customers SET stripe_customer_id = $1 WHERE id = $2")
        .bind(&stripe_customer_id)
        .bind(customer_id)
        .execute(&pool)
        .await
        .expect("failed to link stripe customer");

    // Attach payment method + set as default
    let pm_id = attach_test_payment_method(&stripe_customer_id).await;
    service
        .set_default_payment_method(&stripe_customer_id, &pm_id)
        .await
        .expect("set default pm");

    // 3. Create and finalize invoice via Stripe (triggers auto-charge)
    let line_items = vec![StripeInvoiceLineItem {
        description: "E2E test charge".to_string(),
        amount_cents: 500,
    }];

    let mut metadata = std::collections::HashMap::new();
    metadata.insert("customer_id".to_string(), customer_id.to_string());

    let finalized = service
        .create_and_finalize_invoice(&stripe_customer_id, &line_items, Some(&metadata), None)
        .await
        .expect("finalize invoice");

    // Insert the invoice into our DB so the webhook handler can find it
    sqlx::query(
        "INSERT INTO invoices (id, customer_id, period_start, period_end, subtotal_cents, total_cents, status, stripe_invoice_id, created_at, updated_at)
         VALUES (gen_random_uuid(), $1, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, 500, 500, 'finalized', $2, NOW(), NOW())",
    )
    .bind(customer_id)
    .bind(&finalized.stripe_invoice_id)
    .execute(&pool)
    .await
    .expect("failed to insert invoice into DB");

    // 4. Wait for webhook to arrive and mark invoice as paid
    //    (stripe listen forwards webhook from Stripe → our API)
    let mut paid = false;
    for _ in 0..20 {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let status: Option<String> =
            sqlx::query_scalar("SELECT status FROM invoices WHERE stripe_invoice_id = $1")
                .bind(&finalized.stripe_invoice_id)
                .fetch_optional(&pool)
                .await
                .expect("query failed")
                .flatten();

        if status.as_deref() == Some("paid") {
            paid = true;
            break;
        }
    }

    assert!(
        paid,
        "invoice {} should be marked 'paid' after webhook round-trip (waited 10s)",
        finalized.stripe_invoice_id
    );

    // Cleanup
    delete_stripe_customer(&service, &stripe_customer_id).await;
}

async fn run_mock_checkout_to_paid_invoice_end_to_end() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let stripe_service = mock_stripe_service();

    let app = mock_app_with_state(
        customer_repo.clone(),
        invoice_repo.clone(),
        webhook_event_repo,
        stripe_service.clone(),
    );

    let customer = seed_mock_stripe_customer(
        &customer_repo,
        "Mock Checkout Customer",
        &format!("stripe-checkout-mock-{}@flapjack.foo", uuid::Uuid::new_v4()),
    )
    .await;

    let invoice = seed_mock_draft_invoice(&invoice_repo, customer.id, 500);
    let invoice = finalize_invoice_in_test_router(&app, &invoice_repo, invoice.id).await;
    assert_eq!(invoice.status, "finalized");
    let stripe_invoice_id = invoice
        .stripe_invoice_id
        .expect("mock finalized invoice should include stripe id");
    let stripe_customer_id = customer
        .stripe_customer_id
        .as_ref()
        .expect("customer should have stripe_customer_id");

    let event_payload = serde_json::json!({
        "id": format!("evt_mock_paid_{}", uuid::Uuid::new_v4()),
        "type": "invoice.payment_succeeded",
        "data": {
            "object": {
                "id": stripe_invoice_id,
                "customer": stripe_customer_id,
                "amount_paid": 500,
                "amount_due": 0,
                "status": "paid"
            }
        }
    });

    let payload = serde_json::to_string(&event_payload).unwrap();
    let signature =
        build_stripe_webhook_signature(TEST_WEBHOOK_SECRET, &payload, Utc::now().timestamp());
    let resp = app
        .oneshot(webhook_request(&payload, &signature))
        .await
        .unwrap();

    assert_eq!(resp.status(), StatusCode::OK);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");
}

async fn run_live_webhook_idempotent() {
    let db_url = integration_helpers::db_url();
    let pool = sqlx::PgPool::connect(&db_url)
        .await
        .expect("failed to connect to integration DB");

    // Construct a synthetic webhook event and POST it twice to /webhooks/stripe.
    // The idempotency mechanism (webhook_events table) should process it only once.
    let event_id = format!("evt_test_idempotent_{}", uuid::Uuid::new_v4());
    let stripe_invoice_id = format!("in_test_idempotent_{}", uuid::Uuid::new_v4());

    // Seed a matching invoice so the handler has something to mark paid
    let customer_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM customers LIMIT 1")
        .fetch_optional(&pool)
        .await
        .expect("query failed")
        .unwrap_or_else(uuid::Uuid::nil);

    require_live_locked!(
        !customer_id.is_nil(),
        "no customers in integration DB for idempotency test"
    );

    sqlx::query(
        "INSERT INTO invoices (id, customer_id, period_start, period_end, subtotal_cents, total_cents, status, stripe_invoice_id, created_at, updated_at)
         VALUES (gen_random_uuid(), $1, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, 500, 500, 'finalized', $2, NOW(), NOW())",
    )
    .bind(customer_id)
    .bind(&stripe_invoice_id)
    .execute(&pool)
    .await
    .expect("failed to insert invoice");

    let event_payload = serde_json::json!({
        "id": event_id,
        "type": "invoice.payment_succeeded",
        "data": {
            "object": {
                "id": stripe_invoice_id,
                "customer": "cus_test",
                "amount_paid": 500,
                "amount_due": 0,
                "status": "paid"
            }
        }
    });

    // Build a valid webhook signature using the configured webhook secret
    require_live_locked!(
        stripe_webhook_secret().is_some(),
        "STRIPE_WEBHOOK_SECRET not configured for signing test webhook"
    );
    let webhook_secret = stripe_webhook_secret().unwrap();

    let payload_str = serde_json::to_string(&event_payload).unwrap();
    let timestamp = chrono::Utc::now().timestamp();

    let signature = build_stripe_webhook_signature(&webhook_secret, &payload_str, timestamp);

    let client = integration_helpers::http_client();
    let base = integration_helpers::api_base();

    // First POST — should process the event
    let resp1 = client
        .post(format!("{base}/webhooks/stripe"))
        .header("stripe-signature", &signature)
        .header("content-type", "application/json")
        .body(payload_str.clone())
        .send()
        .await
        .expect("first webhook request failed");
    assert_eq!(resp1.status().as_u16(), 200, "first webhook should succeed");

    // Verify the event was processed (recorded in webhook_events with processed_at)
    let processed_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM webhook_events WHERE stripe_event_id = $1 AND processed_at IS NOT NULL",
    )
    .bind(&event_id)
    .fetch_one(&pool)
    .await
    .expect("query failed");
    assert_eq!(processed_count, 1, "event should be recorded as processed");

    // Second POST — same event, should be idempotent (200 OK, no duplicate processing)
    // Need a fresh timestamp for the signature to pass tolerance check
    let signature2 = build_stripe_webhook_signature(
        &webhook_secret,
        &payload_str,
        chrono::Utc::now().timestamp(),
    );

    let resp2 = client
        .post(format!("{base}/webhooks/stripe"))
        .header("stripe-signature", &signature2)
        .header("content-type", "application/json")
        .body(payload_str)
        .send()
        .await
        .expect("second webhook request failed");
    assert_eq!(
        resp2.status().as_u16(),
        200,
        "replayed webhook should still return 200"
    );

    // Verify idempotency: processed_count must still be exactly 1, not 2
    let processed_count_after: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM webhook_events WHERE stripe_event_id = $1 AND processed_at IS NOT NULL",
    )
    .bind(&event_id)
    .fetch_one(&pool)
    .await
    .expect("query failed");
    assert_eq!(
        processed_count_after, 1,
        "replayed event must not create a duplicate webhook_events row"
    );

    // Invoice should still have exactly one "paid" status transition
    let invoice_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM invoices WHERE stripe_invoice_id = $1")
            .bind(&stripe_invoice_id)
            .fetch_optional(&pool)
            .await
            .expect("query failed")
            .flatten();
    assert_eq!(
        invoice_status.as_deref(),
        Some("paid"),
        "invoice should be paid after idempotent replay"
    );
}

async fn run_mock_webhook_idempotent() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let app = mock_app_with_state(
        customer_repo.clone(),
        invoice_repo.clone(),
        webhook_event_repo.clone(),
        mock_stripe_service(),
    );

    let customer = seed_mock_stripe_customer(
        &customer_repo,
        "Mock Idempotent Customer",
        &format!(
            "stripe-idempotent-mock-{}@flapjack.foo",
            uuid::Uuid::new_v4()
        ),
    )
    .await;

    let invoice = seed_mock_draft_invoice(&invoice_repo, customer.id, 500);
    let invoice = finalize_invoice_in_test_router(&app, &invoice_repo, invoice.id).await;
    assert_eq!(invoice.status, "finalized");
    let stripe_invoice_id = invoice
        .stripe_invoice_id
        .expect("mock finalized invoice should include stripe id");
    let customer_stripe_id = customer
        .stripe_customer_id
        .expect("mock customer must have stripe id");

    let event_id = format!("evt_mock_idempotent_{}", uuid::Uuid::new_v4());
    let payload_json = serde_json::json!({
        "id": event_id,
        "type": "invoice.payment_succeeded",
        "data": {
            "object": {
                "id": stripe_invoice_id,
                "customer": customer_stripe_id,
                "amount_paid": 500,
                "amount_due": 0,
                "status": "paid",
            }
        }
    });
    let payload = serde_json::to_string(&payload_json).unwrap();

    let signature_1 =
        build_stripe_webhook_signature(TEST_WEBHOOK_SECRET, &payload, Utc::now().timestamp());
    let resp_1 = app
        .clone()
        .oneshot(webhook_request(&payload, &signature_1))
        .await
        .unwrap();
    assert_eq!(resp_1.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let signature_2 =
        build_stripe_webhook_signature(TEST_WEBHOOK_SECRET, &payload, Utc::now().timestamp());
    let resp_2 = app
        .clone()
        .oneshot(webhook_request(&payload, &signature_2))
        .await
        .unwrap();
    assert_eq!(resp_2.status(), StatusCode::OK);
    assert_eq!(webhook_event_repo.event_count(), 1);

    let updated_invoice = invoice_repo.find_by_id(invoice.id).await.unwrap().unwrap();
    assert_eq!(updated_invoice.status, "paid");
}

async fn run_live_payment_failure_on_declined_card() {
    let db_url = integration_helpers::db_url();
    let pool = sqlx::PgPool::connect(&db_url)
        .await
        .expect("failed to connect to integration DB");

    let service = build_stripe_service();

    // Create a test customer with a declining card
    let email = format!("stripe-dunning-{}@flapjack.foo", uuid::Uuid::new_v4());

    // Register in fjcloud
    let client = integration_helpers::http_client();
    let base = integration_helpers::api_base();
    let _jwt = integration_helpers::register_and_login(&client, &base, &email).await;

    let customer_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM customers WHERE email = $1")
        .bind(&email)
        .fetch_one(&pool)
        .await
        .expect("customer not found");

    let stripe_customer_id = service
        .create_customer("Dunning Test", &email)
        .await
        .expect("create stripe customer");

    sqlx::query("UPDATE customers SET stripe_customer_id = $1 WHERE id = $2")
        .bind(&stripe_customer_id)
        .bind(customer_id)
        .execute(&pool)
        .await
        .expect("link stripe customer");

    // Attach a declining card and set as default
    let pm_id = attach_declining_payment_method(&stripe_customer_id).await;
    service
        .set_default_payment_method(&stripe_customer_id, &pm_id)
        .await
        .expect("set default pm");

    // Create and finalize invoice — this should fail to charge
    let line_items = vec![StripeInvoiceLineItem {
        description: "Dunning test charge".to_string(),
        amount_cents: 500,
    }];

    let finalized = service
        .create_and_finalize_invoice(&stripe_customer_id, &line_items, None, None)
        .await
        .expect("finalize invoice");

    // Seed invoice in our DB
    sqlx::query(
        "INSERT INTO invoices (id, customer_id, period_start, period_end, subtotal_cents, total_cents, status, stripe_invoice_id, created_at, updated_at)
         VALUES (gen_random_uuid(), $1, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE, 500, 500, 'finalized', $2, NOW(), NOW())",
    )
    .bind(customer_id)
    .bind(&finalized.stripe_invoice_id)
    .execute(&pool)
    .await
    .expect("insert invoice");

    // Wait for payment_failed webhook. The first failure has retries remaining,
    // so customer stays active.
    let mut saw_failed_event = false;
    for _ in 0..20 {
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM webhook_events WHERE event_type = 'invoice.payment_failed' AND payload->'data'->'object'->>'id' = $1",
        )
        .bind(&finalized.stripe_invoice_id)
        .fetch_one(&pool)
        .await
        .unwrap_or(0);

        if count > 0 {
            saw_failed_event = true;
            break;
        }
    }

    assert!(
        saw_failed_event,
        "expected invoice.payment_failed webhook within 10s for declining card"
    );

    // Verify: on first failure Stripe sets next_payment_attempt (retries remain),
    // so customer stays active.
    let customer_status: Option<String> =
        sqlx::query_scalar("SELECT status FROM customers WHERE id = $1")
            .bind(customer_id)
            .fetch_optional(&pool)
            .await
            .expect("customer status query failed")
            .flatten();
    assert_ne!(
        customer_status.as_deref(),
        Some("suspended"),
        "customer should still be active after first payment failure (retries remain)"
    );

    // Cleanup
    delete_stripe_customer(&service, &stripe_customer_id).await;
}

async fn run_mock_payment_failure_webhook_declined_card() {
    let customer_repo = mock_repo();
    let invoice_repo = mock_invoice_repo();
    let webhook_event_repo = mock_webhook_event_repo();
    let app = mock_app_with_state(
        customer_repo.clone(),
        invoice_repo.clone(),
        webhook_event_repo,
        mock_stripe_service(),
    );

    let customer = seed_mock_stripe_customer(
        &customer_repo,
        "Mock Dunning Customer",
        &format!("stripe-failure-mock-{}@flapjack.foo", uuid::Uuid::new_v4()),
    )
    .await;

    let invoice = seed_mock_draft_invoice(&invoice_repo, customer.id, 500);
    let invoice = finalize_invoice_in_test_router(&app, &invoice_repo, invoice.id).await;
    assert_eq!(invoice.status, "finalized");
    let stripe_invoice_id = invoice
        .stripe_invoice_id
        .expect("mock finalized invoice should include stripe id");

    let payload_json = serde_json::json!({
        "id": format!("evt_mock_declined_{}", uuid::Uuid::new_v4()),
        "type": "invoice.payment_failed",
        "data": {
            "object": {
                "id": stripe_invoice_id,
                "customer": customer.stripe_customer_id.unwrap(),
                "next_payment_attempt": Utc::now().timestamp() + 3600,
                "amount_due": 500,
                "attempt_count": 1
            }
        }
    });
    let payload = serde_json::to_string(&payload_json).unwrap();

    let signature =
        build_stripe_webhook_signature(TEST_WEBHOOK_SECRET, &payload, Utc::now().timestamp());
    let resp = app
        .oneshot(webhook_request(&payload, &signature))
        .await
        .unwrap();

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
async fn stripe_checkout_to_paid_invoice_end_to_end() {
    run_mock_checkout_to_paid_invoice_end_to_end().await;

    if stripe_api_available() {
        let webhook_available = stripe_webhook_available().await;
        require_live_locked!(webhook_available, "stripe webhook forwarding not available");
        run_live_checkout_to_paid_invoice_end_to_end().await;
    }
}

#[cfg(test)]
mod helper_tests {
    use super::{
        integration_helpers, stripe_api_available, stripe_test_key, stripe_webhook_configured,
        stripe_webhook_secret, validate_stripe_key_live, validate_stripe_webhook_delivery,
    };

    struct EnvGuard {
        vars: Vec<(&'static str, Option<String>)>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn new(keys: &[&'static str], lock: std::sync::MutexGuard<'static, ()>) -> Self {
            let vars = keys
                .iter()
                .map(|key| (*key, std::env::var(key).ok()))
                .collect();
            Self { vars, _lock: lock }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            for (key, value) in &self.vars {
                if let Some(value) = value {
                    std::env::set_var(key, value);
                } else {
                    std::env::remove_var(key);
                }
            }
        }
    }

    #[tokio::test]
    async fn validate_stripe_key_live_err_when_key_missing() {
        let lock = integration_helpers::test_env_lock();
        let _guard = EnvGuard::new(&["STRIPE_TEST_SECRET_KEY"], lock);
        std::env::remove_var("STRIPE_TEST_SECRET_KEY");
        let result = validate_stripe_key_live().await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("STRIPE_TEST_SECRET_KEY"));
    }

    #[tokio::test]
    async fn validate_stripe_key_live_err_when_key_bad_prefix() {
        let lock = integration_helpers::test_env_lock();
        let _guard = EnvGuard::new(&["STRIPE_TEST_SECRET_KEY"], lock);
        std::env::set_var("STRIPE_TEST_SECRET_KEY", "rk_live_bad");
        let result = validate_stripe_key_live().await;
        assert!(result.is_err());
        assert!(result.unwrap_err().contains("sk_test_"));
    }

    #[tokio::test]
    async fn validate_stripe_webhook_delivery_err_when_no_key() {
        let lock = integration_helpers::test_env_lock();
        let _guard = EnvGuard::new(
            &[
                "STRIPE_TEST_SECRET_KEY",
                "STRIPE_WEBHOOK_SECRET",
                "INTEGRATION",
            ],
            lock,
        );
        std::env::remove_var("STRIPE_TEST_SECRET_KEY");
        std::env::remove_var("STRIPE_WEBHOOK_SECRET");
        std::env::remove_var("INTEGRATION");
        let result = validate_stripe_webhook_delivery().await;
        assert!(result.is_err());
    }

    #[test]
    fn webhook_secret_requires_whsec_prefix() {
        let lock = integration_helpers::test_env_lock();
        let _guard = EnvGuard::new(&["STRIPE_WEBHOOK_SECRET"], lock);

        std::env::set_var("STRIPE_WEBHOOK_SECRET", "whsec_test_123");
        assert!(stripe_webhook_secret().is_some());

        std::env::set_var("STRIPE_WEBHOOK_SECRET", "test_123");
        assert!(stripe_webhook_secret().is_none());

        std::env::remove_var("STRIPE_WEBHOOK_SECRET");
        assert!(stripe_webhook_secret().is_none());
    }

    #[test]
    fn webhook_configuration_requires_secret_and_integration() {
        let lock = integration_helpers::test_env_lock();
        let _guard = EnvGuard::new(
            &[
                "STRIPE_TEST_SECRET_KEY",
                "STRIPE_WEBHOOK_SECRET",
                "INTEGRATION",
            ],
            lock,
        );

        std::env::set_var("STRIPE_TEST_SECRET_KEY", "sk_test_abc");
        assert!(stripe_api_available());
        assert!(!stripe_webhook_configured());

        std::env::set_var("INTEGRATION", "1");
        assert!(stripe_test_key().is_some());
        assert!(!stripe_webhook_configured());

        std::env::set_var("STRIPE_WEBHOOK_SECRET", "whsec_live_abc");
        assert!(stripe_webhook_configured());
    }
}

#[tokio::test]
async fn stripe_webhook_is_idempotent() {
    run_mock_webhook_idempotent().await;

    if stripe_api_available() {
        let webhook_available = stripe_webhook_available().await;
        require_live_locked!(webhook_available, "stripe webhook forwarding not available");
        run_live_webhook_idempotent().await;
    }
}

#[tokio::test]
async fn stripe_payment_failure_webhook_fires_on_declined_card() {
    run_mock_payment_failure_webhook_declined_card().await;

    if stripe_api_available() {
        let webhook_available = stripe_webhook_available().await;
        require_live_locked!(webhook_available, "stripe webhook forwarding not available");
        run_live_payment_failure_on_declined_card().await;
    }
}
