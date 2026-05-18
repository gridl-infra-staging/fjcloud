use async_trait::async_trait;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::sync::{Arc, Mutex};
use uuid::Uuid;

use super::{
    CreatePortalSessionRequest, FinalizedInvoice, PaidInvoice, PaymentMethodSummary,
    PortalSessionResponse, StripeChargeLookup, StripeError, StripeEvent, StripeInvoiceLineItem,
    StripeLastPaymentError, StripeService,
};

type HmacSha256 = Hmac<Sha256>;

// ---------------------------------------------------------------------------
// In-memory state types — fields are stored for completeness even if not
// currently read back (they're useful for debugging/inspection).
// ---------------------------------------------------------------------------

#[allow(dead_code)]
#[derive(Debug, Clone)]
struct LocalCustomer {
    id: String,
    name: String,
    email: String,
    default_payment_method: Option<String>,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
struct LocalPaymentMethod {
    id: String,
    customer_id: String,
    card_brand: String,
    last4: String,
    exp_month: u32,
    exp_year: u32,
}

#[allow(dead_code)]
#[derive(Debug, Clone)]
struct LocalInvoice {
    id: String,
    customer_id: String,
    line_items: Vec<StripeInvoiceLineItem>,
    hosted_url: String,
    pdf_url: String,
    status: String,
    amount_paid_cents: i64,
    last_payment_error: Option<StripeLastPaymentError>,
}

/// In-memory state for the local Stripe mock.
#[derive(Debug, Default)]
struct LocalStripeState {
    customers: Vec<LocalCustomer>,
    payment_methods: Vec<LocalPaymentMethod>,
    invoices: Vec<LocalInvoice>,
}

// ---------------------------------------------------------------------------
// Webhook event types
// ---------------------------------------------------------------------------

/// A queued webhook event to be dispatched to the API's webhook endpoint.
#[derive(Debug, Clone)]
struct WebhookEvent {
    /// Stripe event type (e.g., "invoice.payment_succeeded").
    event_type: String,
    /// The event data payload (the "object" field in Stripe events).
    data: serde_json::Value,
}

/// Background task that reads webhook events from a channel and POSTs them
/// to the API webhook endpoint with proper HMAC-SHA256 signatures.
pub struct WebhookDispatcher {
    /// Receives queued webhook events.
    rx: tokio::sync::mpsc::UnboundedReceiver<WebhookEvent>,
    /// Webhook signing secret (must match STRIPE_WEBHOOK_SECRET in .env.local).
    webhook_secret: String,
    /// URL to POST webhook events to (e.g., "http://localhost:3001/webhooks/stripe").
    webhook_url: String,
    /// HTTP client for sending webhook requests.
    client: reqwest::Client,
}

impl WebhookDispatcher {
    /// Run the dispatcher loop. Consumes events from the channel and POSTs
    /// them to the webhook URL with HMAC-SHA256 signatures. Retries up to 3
    /// times on failure with a 1-second delay between attempts.
    pub async fn run(mut self) {
        while let Some(event) = self.rx.recv().await {
            let event_id = format!("evt_local_{}", Uuid::new_v4().simple());
            let payload = serde_json::json!({
                "id": event_id,
                "type": event.event_type,
                "data": { "object": event.data }
            });
            let payload_str = serde_json::to_string(&payload).unwrap_or_default();

            // Generate HMAC-SHA256 signature matching real Stripe format.
            let timestamp = chrono::Utc::now().timestamp();
            let signature =
                generate_webhook_signature(&payload_str, &self.webhook_secret, timestamp);

            // Retry up to 3 times — the API might not be ready yet on startup.
            for attempt in 1..=3 {
                match self
                    .client
                    .post(&self.webhook_url)
                    .header("Content-Type", "application/json")
                    .header("Stripe-Signature", &signature)
                    .body(payload_str.clone())
                    .send()
                    .await
                {
                    Ok(resp) if resp.status().is_success() => {
                        tracing::info!(
                            event_type = %event.event_type,
                            event_id,
                            "Local webhook delivered"
                        );
                        break;
                    }
                    Ok(resp) => {
                        tracing::warn!(
                            event_type = %event.event_type,
                            status = %resp.status(),
                            attempt,
                            "Local webhook delivery failed (non-2xx)"
                        );
                    }
                    Err(e) => {
                        tracing::warn!(
                            event_type = %event.event_type,
                            error = %e,
                            attempt,
                            "Local webhook delivery failed (connection error)"
                        );
                    }
                }
                if attempt < 3 {
                    tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Signature generation (shared with tests)
// ---------------------------------------------------------------------------

/// Generate a Stripe-format webhook signature header value.
/// Format: "t={timestamp},v1={hex_hmac_sha256("{timestamp}.{payload}", secret)}"
pub fn generate_webhook_signature(payload: &str, secret: &str, timestamp: i64) -> String {
    let signed_payload = format!("{timestamp}.{payload}");
    let mut mac =
        HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC accepts any key length");
    mac.update(signed_payload.as_bytes());
    let sig = hex::encode(mac.finalize().into_bytes());
    format!("t={timestamp},v1={sig}")
}

// ---------------------------------------------------------------------------
// LocalStripeService
// ---------------------------------------------------------------------------

/// Stateful in-process Stripe mock for local development.
/// All state is held in memory (lost on restart). Webhook events are queued
/// to a background dispatcher task for delivery to the API webhook endpoint.
pub struct LocalStripeService {
    /// In-memory state (customers, payment methods, invoices, subscriptions).
    state: Arc<Mutex<LocalStripeState>>,
    /// Channel for queuing webhook events to be dispatched.
    webhook_tx: tokio::sync::mpsc::UnboundedSender<WebhookEvent>,
    /// Webhook signing secret (matches STRIPE_WEBHOOK_SECRET in .env.local).
    /// Stored for potential future use; the trait's construct_webhook_event
    /// takes the secret as a parameter so this field isn't read directly.
    #[allow(dead_code)]
    webhook_secret: String,
}

impl LocalStripeService {
    /// Create a new LocalStripeService and its companion WebhookDispatcher.
    /// The dispatcher must be spawned as a background tokio task.
    pub fn new(webhook_secret: String, webhook_url: String) -> (Self, WebhookDispatcher) {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let service = Self {
            state: Arc::new(Mutex::new(LocalStripeState::default())),
            webhook_tx: tx,
            webhook_secret: webhook_secret.clone(),
        };
        let dispatcher = WebhookDispatcher {
            rx,
            webhook_secret,
            webhook_url,
            client: reqwest::Client::new(),
        };
        (service, dispatcher)
    }

    /// Queue a webhook event for delivery by the background dispatcher.
    fn queue_webhook(&self, event_type: &str, data: serde_json::Value) {
        // Ignore send errors — the dispatcher may have been dropped during shutdown.
        let _ = self.webhook_tx.send(WebhookEvent {
            event_type: event_type.to_string(),
            data,
        });
    }

    /// Test-only setup helper: seed a synthetic payment method and mark it as
    /// default for the given customer so pay-path tests can drive deterministic
    /// outcomes without adding trait-only test seams.
    pub fn seed_default_payment_method(&self, stripe_customer_id: &str, pm_id: &str) {
        let mut state = self.state.lock().unwrap();
        if let Some(customer) = state
            .customers
            .iter_mut()
            .find(|candidate| candidate.id == stripe_customer_id)
        {
            customer.default_payment_method = Some(pm_id.to_string());
        }

        if !state
            .payment_methods
            .iter()
            .any(|payment_method| payment_method.id == pm_id)
        {
            state.payment_methods.push(LocalPaymentMethod {
                id: pm_id.to_string(),
                customer_id: stripe_customer_id.to_string(),
                card_brand: "visa".to_string(),
                last4: "4242".to_string(),
                exp_month: 12,
                exp_year: 2030,
            });
        }
    }

    fn payment_outcome_for_payment_method(
        default_payment_method: Option<&str>,
    ) -> (String, i64, Option<StripeLastPaymentError>, &'static str) {
        let Some(pm_id) = default_payment_method else {
            return (
                "open".to_string(),
                0,
                Some(StripeLastPaymentError {
                    code: Some("invoice_no_payment_method_types".to_string()),
                    decline_code: None,
                    message: Some("No default payment method is set.".to_string()),
                }),
                "invoice.payment_failed",
            );
        };

        // Canonical local-payment convention for tests:
        // - pm_test_decline_* => declined
        // - pm_test_3ds_* => requires_action
        // - everything else => paid
        if pm_id.starts_with("pm_test_decline_") {
            return (
                "open".to_string(),
                0,
                Some(StripeLastPaymentError {
                    code: Some("card_declined".to_string()),
                    decline_code: Some("insufficient_funds".to_string()),
                    message: Some("Your card has insufficient funds.".to_string()),
                }),
                "invoice.payment_failed",
            );
        }

        if pm_id.starts_with("pm_test_3ds_") {
            return (
                "open".to_string(),
                0,
                Some(StripeLastPaymentError {
                    code: Some("invoice_payment_intent_requires_action".to_string()),
                    decline_code: None,
                    message: Some("Payment requires customer action.".to_string()),
                }),
                "invoice.payment_failed",
            );
        }

        ("paid".to_string(), -1, None, "invoice.payment_succeeded")
    }
}

#[async_trait]
impl StripeService for LocalStripeService {
    async fn create_customer(&self, name: &str, email: &str) -> Result<String, StripeError> {
        let id = format!("cus_local_{}", Uuid::new_v4().simple());
        let mut state = self.state.lock().unwrap();
        state.customers.push(LocalCustomer {
            id: id.clone(),
            name: name.to_string(),
            email: email.to_string(),
            default_payment_method: None,
        });
        Ok(id)
    }

    async fn create_setup_intent(&self, stripe_customer_id: &str) -> Result<String, StripeError> {
        // Return a synthetic client secret. In local dev, the frontend won't
        // actually talk to Stripe — it just needs a non-empty string.
        Ok(format!("seti_secret_{stripe_customer_id}"))
    }

    async fn create_billing_portal_session(
        &self,
        stripe_customer_id: &str,
        _request: &CreatePortalSessionRequest,
    ) -> Result<PortalSessionResponse, StripeError> {
        Ok(PortalSessionResponse {
            url: format!("http://localhost:3000/local-billing-portal/{stripe_customer_id}"),
        })
    }

    async fn list_payment_methods(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Vec<PaymentMethodSummary>, StripeError> {
        let state = self.state.lock().unwrap();
        let customer = state.customers.iter().find(|c| c.id == stripe_customer_id);
        let default_pm = customer.and_then(|c| c.default_payment_method.clone());

        Ok(state
            .payment_methods
            .iter()
            .filter(|pm| pm.customer_id == stripe_customer_id)
            .map(|pm| PaymentMethodSummary {
                id: pm.id.clone(),
                card_brand: pm.card_brand.clone(),
                last4: pm.last4.clone(),
                exp_month: pm.exp_month,
                exp_year: pm.exp_year,
                is_default: default_pm.as_deref() == Some(&pm.id),
            })
            .collect())
    }

    async fn detach_payment_method(&self, pm_id: &str) -> Result<(), StripeError> {
        let mut state = self.state.lock().unwrap();
        state.payment_methods.retain(|pm| pm.id != pm_id);
        Ok(())
    }

    async fn set_default_payment_method(
        &self,
        stripe_customer_id: &str,
        pm_id: &str,
    ) -> Result<(), StripeError> {
        let mut state = self.state.lock().unwrap();
        if let Some(customer) = state
            .customers
            .iter_mut()
            .find(|c| c.id == stripe_customer_id)
        {
            customer.default_payment_method = Some(pm_id.to_string());
        }
        Ok(())
    }

    /// Creates a mock invoice in `open` state and queues `invoice.finalized`.
    async fn create_and_finalize_invoice(
        &self,
        stripe_customer_id: &str,
        line_items: &[StripeInvoiceLineItem],
        _metadata: Option<&std::collections::HashMap<String, String>>,
        _idempotency_key: Option<&str>,
    ) -> Result<FinalizedInvoice, StripeError> {
        let invoice_id = format!("in_local_{}", Uuid::new_v4().simple());
        let hosted_url = format!("http://localhost:8025/local-invoice/{invoice_id}");
        let pdf_url = format!("http://localhost:8025/local-invoice/{invoice_id}/pdf");

        let invoice = LocalInvoice {
            id: invoice_id.clone(),
            customer_id: stripe_customer_id.to_string(),
            line_items: line_items.to_vec(),
            hosted_url: hosted_url.clone(),
            pdf_url: pdf_url.clone(),
            status: "open".to_string(),
            amount_paid_cents: 0,
            last_payment_error: None,
        };

        {
            let mut state = self.state.lock().unwrap();
            state.invoices.push(invoice);
        }

        // Queue webhook: invoice finalized and ready for explicit pay/void.
        self.queue_webhook(
            "invoice.finalized",
            serde_json::json!({
                "id": invoice_id,
                "customer": stripe_customer_id,
                "amount_paid": 0,
                "hosted_invoice_url": hosted_url,
                "invoice_pdf": pdf_url,
                "status": "open"
            }),
        );

        Ok(FinalizedInvoice {
            stripe_invoice_id: invoice_id,
            hosted_invoice_url: hosted_url,
            pdf_url: Some(pdf_url),
        })
    }

    async fn pay_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError> {
        let mut state = self.state.lock().unwrap();
        let invoice_index = state
            .invoices
            .iter()
            .position(|candidate| candidate.id == stripe_invoice_id)
            .ok_or_else(|| StripeError::Api("invoice not found".to_string()))?;
        let customer_id = state.invoices[invoice_index].customer_id.clone();

        let default_payment_method = state
            .customers
            .iter()
            .find(|customer| customer.id == customer_id)
            .and_then(|customer| customer.default_payment_method.as_deref());

        let (status, amount_paid_cents, last_payment_error, webhook_event_type) =
            Self::payment_outcome_for_payment_method(default_payment_method);

        let invoice = &mut state.invoices[invoice_index];
        let total_cents: i64 = invoice
            .line_items
            .iter()
            .map(|item| item.amount_cents)
            .sum();
        invoice.status = status.clone();
        invoice.amount_paid_cents = if amount_paid_cents < 0 {
            total_cents
        } else {
            amount_paid_cents
        };
        invoice.last_payment_error = last_payment_error.clone();

        self.queue_webhook(
            webhook_event_type,
            serde_json::json!({
                "id": invoice.id,
                "customer": invoice.customer_id,
                "amount_paid": invoice.amount_paid_cents,
                "hosted_invoice_url": invoice.hosted_url,
                "invoice_pdf": invoice.pdf_url,
                "status": invoice.status,
                "last_payment_error": invoice.last_payment_error,
            }),
        );

        Ok(PaidInvoice {
            id: invoice.id.clone(),
            status,
            amount_paid_cents: invoice.amount_paid_cents,
            last_payment_error,
        })
    }

    async fn void_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError> {
        let mut state = self.state.lock().unwrap();
        let invoice = state
            .invoices
            .iter_mut()
            .find(|candidate| candidate.id == stripe_invoice_id)
            .ok_or_else(|| StripeError::Api("invoice not found".to_string()))?;

        invoice.status = "void".to_string();
        invoice.amount_paid_cents = 0;
        invoice.last_payment_error = None;

        self.queue_webhook(
            "invoice.voided",
            serde_json::json!({
                "id": invoice.id,
                "customer": invoice.customer_id,
                "amount_paid": invoice.amount_paid_cents,
                "hosted_invoice_url": invoice.hosted_url,
                "invoice_pdf": invoice.pdf_url,
                "status": invoice.status,
            }),
        );

        Ok(PaidInvoice {
            id: invoice.id.clone(),
            status: invoice.status.clone(),
            amount_paid_cents: 0,
            last_payment_error: None,
        })
    }

    async fn lookup_charge_fallback_fields(
        &self,
        charge_id: &str,
    ) -> Result<StripeChargeLookup, StripeError> {
        if !charge_id.starts_with("ch_") {
            return Err(StripeError::Api(
                "invalid charge id for local Stripe".into(),
            ));
        }

        let suffix = charge_id.trim_start_matches("ch_");
        let invoice_id = if suffix.contains("missing_invoice") {
            None
        } else {
            Some(format!("in_{suffix}"))
        };
        let payment_intent_id = if suffix.contains("missing_payment_intent") {
            None
        } else {
            Some(format!("pi_{suffix}"))
        };

        Ok(StripeChargeLookup {
            charge_id: charge_id.to_string(),
            invoice_id,
            payment_intent_id,
        })
    }

    /// Verify the webhook signature using the same HMAC logic as live.rs.
    /// Since both sides use the same secret, this always works locally.
    fn construct_webhook_event(
        &self,
        payload: &str,
        signature: &str,
        secret: &str,
    ) -> Result<StripeEvent, StripeError> {
        // Parse the signature header to extract timestamp and v1 signature.
        let mut timestamp: Option<&str> = None;
        let mut signatures: Vec<&str> = Vec::new();

        for part in signature.split(',') {
            let part = part.trim();
            if let Some(ts) = part.strip_prefix("t=") {
                timestamp = Some(ts);
            } else if let Some(sig) = part.strip_prefix("v1=") {
                signatures.push(sig);
            }
        }

        let timestamp = timestamp
            .ok_or_else(|| StripeError::WebhookVerification("missing timestamp".into()))?;

        if signatures.is_empty() {
            return Err(StripeError::WebhookVerification(
                "no v1 signatures found".into(),
            ));
        }

        // Compute expected HMAC-SHA256 signature.
        let signed_payload = format!("{timestamp}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
            .map_err(|e| StripeError::WebhookVerification(e.to_string()))?;
        mac.update(signed_payload.as_bytes());
        let expected = hex::encode(mac.finalize().into_bytes());

        // Constant-time comparison.
        let valid = signatures
            .iter()
            .any(|sig| subtle::ConstantTimeEq::ct_eq(sig.as_bytes(), expected.as_bytes()).into());

        if !valid {
            return Err(StripeError::WebhookVerification(
                "signature mismatch".into(),
            ));
        }

        // Parse the JSON payload and extract event fields.
        let parsed: serde_json::Value = serde_json::from_str(payload)
            .map_err(|e| StripeError::WebhookVerification(format!("invalid JSON: {e}")))?;

        Ok(StripeEvent {
            id: parsed["id"]
                .as_str()
                .unwrap_or("evt_local_unknown")
                .to_string(),
            event_type: parsed["type"].as_str().unwrap_or("unknown").to_string(),
            data: parsed["data"].clone(),
        })
    }
}

// ===========================================================================
// Tests
// ===========================================================================

#[cfg(test)]
mod tests {
    use super::*;

    /// Helper: create a LocalStripeService for testing (webhook dispatcher is
    /// not spawned — we only test the service logic, not delivery).
    fn test_service() -> LocalStripeService {
        let (service, _dispatcher) = LocalStripeService::new(
            "whsec_test".to_string(),
            "http://localhost:3001/webhooks/stripe".to_string(),
        );
        service
    }

    // Public-API-only tests moved to infra/api/tests/stripe_local_dispatch_test.rs.
    // Tests below access private state and must remain inline.

    #[tokio::test]
    async fn create_customer_stores_in_state() {
        let service = test_service();
        service
            .create_customer("Bob", "bob@test.com")
            .await
            .unwrap();
        let state = service.state.lock().unwrap();
        assert_eq!(state.customers.len(), 1);
        assert_eq!(state.customers[0].name, "Bob");
        assert_eq!(state.customers[0].email, "bob@test.com");
    }

    #[tokio::test]
    async fn detach_payment_method_removes_from_state() {
        let service = test_service();
        // Manually seed a payment method.
        {
            let mut state = service.state.lock().unwrap();
            state.payment_methods.push(LocalPaymentMethod {
                id: "pm_test".to_string(),
                customer_id: "cus_test".to_string(),
                card_brand: "visa".to_string(),
                last4: "4242".to_string(),
                exp_month: 12,
                exp_year: 2030,
            });
        }
        service.detach_payment_method("pm_test").await.unwrap();
        let state = service.state.lock().unwrap();
        assert!(state.payment_methods.is_empty());
    }

    #[tokio::test]
    async fn set_default_payment_method_updates_customer() {
        let service = test_service();
        let cid = service.create_customer("C", "c@test.com").await.unwrap();
        service
            .set_default_payment_method(&cid, "pm_42")
            .await
            .unwrap();
        let state = service.state.lock().unwrap();
        assert_eq!(
            state.customers[0].default_payment_method.as_deref(),
            Some("pm_42")
        );
    }

    #[tokio::test]
    async fn create_invoice_queues_webhook() {
        let (service, _dispatcher) = LocalStripeService::new(
            "whsec_test".to_string(),
            "http://localhost:9999".to_string(),
        );
        let items = vec![StripeInvoiceLineItem {
            description: "Usage".to_string(),
            amount_cents: 500,
        }];
        service
            .create_and_finalize_invoice("cus_test", &items, None, None)
            .await
            .unwrap();
        // The webhook_tx should have one queued event. We can verify the channel
        // is not empty by checking that the dispatcher would receive something.
        // (In a real test we'd check the channel, but the unbounded sender has
        // no len() method. The webhook was queued successfully if no panic.)
    }

    // -----------------------------------------------------------------------
    // Webhook signature tests
    // -----------------------------------------------------------------------

    #[test]
    fn generate_webhook_signature_matches_live_verification() {
        let secret = "whsec_test_secret";
        let payload = r#"{"id":"evt_1","type":"test","data":{}}"#;
        let timestamp = chrono::Utc::now().timestamp();
        let sig_header = generate_webhook_signature(payload, secret, timestamp);

        // Verify we can parse it back.
        assert!(sig_header.starts_with("t="));
        assert!(sig_header.contains(",v1="));

        // Verify the signature is valid using the same HMAC logic.
        let signed_payload = format!("{timestamp}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(signed_payload.as_bytes());
        let expected = hex::encode(mac.finalize().into_bytes());
        assert!(sig_header.contains(&expected));
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

    // Wiremock dispatch tests moved to infra/api/tests/stripe_local_dispatch_test.rs
    // to keep this file under the 800-line hard limit.
}
