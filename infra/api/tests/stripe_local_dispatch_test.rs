//! Tests for LocalStripeService — public API tests and wiremock webhook
//! dispatch integration tests. Extracted from stripe/local.rs to keep that
//! file under the 800-line hard limit.
//!
//! State-accessing tests (that need private field access) remain inline in
//! stripe/local.rs.

use std::sync::{Arc, Mutex};

use api::stripe::local::{generate_webhook_signature, LocalStripeService};
use api::stripe::{StripeError, StripeInvoiceLineItem, StripeService};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use wiremock::matchers::{header, header_exists, method};
use wiremock::{Mock, MockServer, Request, ResponseTemplate};

type HmacSha256 = Hmac<Sha256>;

/// Helper: create a LocalStripeService for testing (webhook dispatcher is
/// not spawned — we only test the service logic, not delivery).
fn test_service() -> LocalStripeService {
    let (service, _dispatcher) = LocalStripeService::new(
        "whsec_test".to_string(),
        "http://localhost:3001/webhooks/stripe".to_string(),
    );
    service
}

// ---------------------------------------------------------------------------
// Public API tests (no private state access needed)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn create_customer_returns_local_prefixed_id() {
    let service = test_service();
    let id = service
        .create_customer("Alice", "alice@test.com")
        .await
        .unwrap();
    assert!(id.starts_with("cus_local_"), "got: {id}");
}

#[tokio::test]
async fn create_setup_intent_returns_synthetic_secret() {
    let service = test_service();
    let secret = service.create_setup_intent("cus_123").await.unwrap();
    assert_eq!(secret, "seti_secret_cus_123");
}

#[tokio::test]
async fn list_payment_methods_empty_initially() {
    let service = test_service();
    let cid = service.create_customer("A", "a@test.com").await.unwrap();
    let methods = service.list_payment_methods(&cid).await.unwrap();
    assert!(methods.is_empty());
}

#[tokio::test]
async fn create_and_finalize_invoice_returns_local_ids() {
    let service = test_service();
    let items = vec![StripeInvoiceLineItem {
        description: "Usage".to_string(),
        amount_cents: 1000,
    }];
    let invoice = service
        .create_and_finalize_invoice("cus_test", &items, None, None)
        .await
        .unwrap();
    assert!(invoice.stripe_invoice_id.starts_with("in_local_"));
    assert!(invoice
        .hosted_invoice_url
        .contains(&invoice.stripe_invoice_id));
    assert!(invoice.pdf_url.is_some());
}

#[tokio::test]
async fn construct_webhook_event_verifies_signature() {
    let service = test_service();
    let payload = r#"{"id":"evt_1","type":"invoice.paid","data":{"object":{}}}"#;
    let timestamp = chrono::Utc::now().timestamp();
    let sig = generate_webhook_signature(payload, "whsec_test", timestamp);
    let event = service
        .construct_webhook_event(payload, &sig, "whsec_test")
        .unwrap();
    assert_eq!(event.id, "evt_1");
    assert_eq!(event.event_type, "invoice.paid");
}

#[tokio::test]
async fn construct_webhook_event_rejects_bad_signature() {
    let service = test_service();
    let payload = r#"{"id":"evt_1","type":"test","data":{}}"#;
    let ts = chrono::Utc::now().timestamp();
    let bad_sig = format!("t={ts},v1=invalid_hex_garbage");
    let result = service.construct_webhook_event(payload, &bad_sig, "whsec_test");
    assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
}

// ---------------------------------------------------------------------------
// Webhook dispatch integration tests (wiremock)
// ---------------------------------------------------------------------------

/// Helper: create a LocalStripeService whose webhook_url points at the
/// given wiremock server, and spawn the dispatcher as a background task.
fn test_service_with_dispatcher(secret: &str, webhook_url: &str) -> LocalStripeService {
    let (service, dispatcher) =
        LocalStripeService::new(secret.to_string(), webhook_url.to_string());
    tokio::spawn(dispatcher.run());
    service
}

/// Parse the Stripe-Signature header into (timestamp, v1_hex).
fn parse_stripe_signature(header_val: &str) -> (String, String) {
    let mut ts = String::new();
    let mut v1 = String::new();
    for part in header_val.split(',') {
        let part = part.trim();
        if let Some(t) = part.strip_prefix("t=") {
            ts = t.to_string();
        } else if let Some(s) = part.strip_prefix("v1=") {
            v1 = s.to_string();
        }
    }
    (ts, v1)
}

type CapturedRequest = (String, String, String);

async fn mount_capturing_mock(server: &MockServer) -> Arc<Mutex<Vec<CapturedRequest>>> {
    let captured = Arc::new(Mutex::new(Vec::<CapturedRequest>::new()));
    let clone = Arc::clone(&captured);
    Mock::given(method("POST"))
        .respond_with(move |req: &Request| {
            let sig = req
                .headers
                .get("Stripe-Signature")
                .map(|v| v.to_str().unwrap().to_string())
                .unwrap_or_default();
            let body = String::from_utf8(req.body.clone()).unwrap();
            let ct = req
                .headers
                .get("Content-Type")
                .map(|v| v.to_str().unwrap().to_string())
                .unwrap_or_default();
            clone.lock().unwrap().push((sig, body, ct));
            ResponseTemplate::new(200)
        })
        .mount(server)
        .await;
    captured
}

async fn mount_body_capturing_mock(server: &MockServer) -> Arc<Mutex<Vec<serde_json::Value>>> {
    let received = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
    let clone = Arc::clone(&received);
    Mock::given(method("POST"))
        .respond_with(move |req: &Request| {
            let body: serde_json::Value = serde_json::from_slice(&req.body).unwrap();
            clone.lock().unwrap().push(body);
            ResponseTemplate::new(200)
        })
        .mount(server)
        .await;
    received
}

fn assert_hmac_signature_valid(sig_header: &str, body: &str, secret: &str) {
    let (ts_str, v1_hex) = parse_stripe_signature(sig_header);
    assert!(!ts_str.is_empty(), "timestamp must be present");
    assert!(!v1_hex.is_empty(), "v1 signature must be present");
    let ts: i64 = ts_str.parse().expect("timestamp should be numeric");
    let signed_payload = format!("{ts}.{body}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
    mac.update(signed_payload.as_bytes());
    let expected_hex = hex::encode(mac.finalize().into_bytes());
    assert_eq!(v1_hex, expected_hex, "HMAC signature must match");
}

#[tokio::test]
async fn dispatcher_posts_with_correct_headers() {
    let mock_server = MockServer::start().await;
    let webhook_url = format!("{}/webhooks/stripe", mock_server.uri());
    Mock::given(method("POST"))
        .and(header("Content-Type", "application/json"))
        .and(header_exists("Stripe-Signature"))
        .respond_with(ResponseTemplate::new(200))
        .expect(1)
        .mount(&mock_server)
        .await;
    let service = test_service_with_dispatcher("whsec_dispatch_test", &webhook_url);
    let items = vec![StripeInvoiceLineItem {
        description: "Test item".to_string(),
        amount_cents: 2500,
    }];
    service
        .create_and_finalize_invoice("cus_dispatch", &items, None, None)
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
}

#[tokio::test]
async fn dispatcher_sends_correct_invoice_payload() {
    let mock_server = MockServer::start().await;
    let webhook_url = format!("{}/webhooks/stripe", mock_server.uri());
    let received = mount_body_capturing_mock(&mock_server).await;
    let service = test_service_with_dispatcher("whsec_payload", &webhook_url);
    let items = vec![
        StripeInvoiceLineItem {
            description: "Storage".into(),
            amount_cents: 1200,
        },
        StripeInvoiceLineItem {
            description: "Compute".into(),
            amount_cents: 800,
        },
    ];
    service
        .create_and_finalize_invoice("cus_payload_test", &items, None, None)
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let bodies = received.lock().unwrap();
    assert_eq!(bodies.len(), 1, "expected exactly one webhook delivery");
    let body = &bodies[0];
    let event_id = body["id"].as_str().unwrap();
    assert!(event_id.starts_with("evt_local_"), "got: {event_id}");
    assert_eq!(body["type"].as_str().unwrap(), "invoice.payment_succeeded");
    let obj = &body["data"]["object"];
    assert_eq!(obj["customer"].as_str().unwrap(), "cus_payload_test");
    assert_eq!(obj["amount_paid"].as_i64().unwrap(), 2000);
    assert_eq!(obj["status"].as_str().unwrap(), "paid");
    assert!(obj["id"].as_str().unwrap().starts_with("in_local_"));
}

#[tokio::test]
async fn dispatcher_signature_is_verifiable() {
    let mock_server = MockServer::start().await;
    let webhook_url = format!("{}/webhooks/stripe", mock_server.uri());
    let secret = "whsec_e2e_sig_test";
    let captured = mount_capturing_mock(&mock_server).await;
    let service = test_service_with_dispatcher(secret, &webhook_url);
    let items = vec![StripeInvoiceLineItem {
        description: "Sig test".into(),
        amount_cents: 100,
    }];
    service
        .create_and_finalize_invoice("cus_sig", &items, None, None)
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let requests = captured.lock().unwrap();
    assert_eq!(requests.len(), 1, "expected one captured request");
    let (sig_header, body_str, content_type) = &requests[0];
    assert_eq!(content_type, "application/json");
    assert_hmac_signature_valid(sig_header, body_str, secret);
    let event = service
        .construct_webhook_event(body_str, sig_header, secret)
        .unwrap();
    assert_eq!(event.event_type, "invoice.payment_succeeded");
    assert!(event.id.starts_with("evt_local_"));
}

#[tokio::test]
async fn dispatcher_retries_on_server_error() {
    let mock_server = MockServer::start().await;
    let webhook_url = format!("{}/webhooks/stripe", mock_server.uri());
    let call_count = Arc::new(std::sync::atomic::AtomicU32::new(0));
    let call_count_clone = Arc::clone(&call_count);
    Mock::given(method("POST"))
        .respond_with(move |_req: &Request| {
            let n = call_count_clone.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if n == 0 {
                ResponseTemplate::new(500)
            } else {
                ResponseTemplate::new(200)
            }
        })
        .mount(&mock_server)
        .await;
    let service = test_service_with_dispatcher("whsec_retry", &webhook_url);
    let items = vec![StripeInvoiceLineItem {
        description: "Retry test".to_string(),
        amount_cents: 42,
    }];
    service
        .create_and_finalize_invoice("cus_retry", &items, None, None)
        .await
        .unwrap();
    // Retry delay is 1s, so wait for first attempt + delay + second attempt.
    tokio::time::sleep(std::time::Duration::from_millis(2500)).await;
    let total_calls = call_count.load(std::sync::atomic::Ordering::SeqCst);
    assert_eq!(total_calls, 2, "expected 2 attempts, got {total_calls}");
}

#[tokio::test]
async fn dispatcher_signature_wrong_secret_fails_verification() {
    let mock_server = MockServer::start().await;
    let webhook_url = format!("{}/webhooks/stripe", mock_server.uri());
    let dispatch_secret = "whsec_correct_secret";
    let captured = mount_capturing_mock(&mock_server).await;
    let service = test_service_with_dispatcher(dispatch_secret, &webhook_url);
    let items = vec![StripeInvoiceLineItem {
        description: "Wrong secret test".into(),
        amount_cents: 1,
    }];
    service
        .create_and_finalize_invoice("cus_wrong", &items, None, None)
        .await
        .unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
    let reqs = captured.lock().unwrap();
    assert_eq!(reqs.len(), 1);
    let (sig_header, body_str, _ct) = &reqs[0];
    // Wrong secret must fail.
    let result = service.construct_webhook_event(body_str, sig_header, "whsec_WRONG_secret");
    assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
    // Correct secret must succeed.
    let event = service
        .construct_webhook_event(body_str, sig_header, dispatch_secret)
        .unwrap();
    assert_eq!(event.event_type, "invoice.payment_succeeded");
}
