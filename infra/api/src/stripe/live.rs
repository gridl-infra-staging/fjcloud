use async_trait::async_trait;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use stripe::{
    BillingPortalSession, Client, CollectionMethod, CreateBillingPortalSession, CreateCustomer,
    CreateInvoice, CreateInvoiceItem, CreateSetupIntent, Customer, CustomerInvoiceSettings,
    FinalizeInvoiceParams, Invoice, InvoicePendingInvoiceItemsBehavior, ListPaymentMethods,
    PaymentMethod, PaymentMethodTypeFilter, RequestStrategy, SetupIntent, UpdateCustomer,
};

use super::{
    CreatePortalSessionRequest, FinalizedInvoice, PaymentMethodSummary, PortalSessionResponse,
    StripeError, StripeEvent, StripeInvoiceLineItem, StripeService,
};

type HmacSha256 = Hmac<Sha256>;

const WEBHOOK_TOLERANCE_SECS: i64 = 300; // 5 minutes

pub struct LiveStripeService {
    client: Client,
}

impl LiveStripeService {
    pub fn new(secret_key: &str) -> Self {
        Self {
            client: Client::new(secret_key),
        }
    }
}

/// Verify Stripe webhook signature and parse the event.
/// Implements the same algorithm as Stripe's official SDKs:
/// 1. Extract timestamp and signatures from `Stripe-Signature` header
/// 2. Compute expected signature: HMAC-SHA256(secret, "{timestamp}.{payload}")
/// 3. Compare using constant-time comparison
/// 4. Reject if timestamp older than 5 minutes
fn verify_webhook_signature(
    payload: &str,
    signature_header: &str,
    secret: &str,
) -> Result<serde_json::Value, StripeError> {
    let mut timestamp: Option<&str> = None;
    let mut signatures: Vec<&str> = Vec::new();

    for part in signature_header.split(',') {
        let part = part.trim();
        if let Some(ts) = part.strip_prefix("t=") {
            timestamp = Some(ts);
        } else if let Some(sig) = part.strip_prefix("v1=") {
            signatures.push(sig);
        }
    }

    let timestamp =
        timestamp.ok_or_else(|| StripeError::WebhookVerification("missing timestamp".into()))?;

    if signatures.is_empty() {
        return Err(StripeError::WebhookVerification(
            "no v1 signatures found".into(),
        ));
    }

    // Check timestamp tolerance
    let ts: i64 = timestamp
        .parse()
        .map_err(|_| StripeError::WebhookVerification("invalid timestamp".into()))?;
    let now = chrono::Utc::now().timestamp();
    if (now - ts).abs() > WEBHOOK_TOLERANCE_SECS {
        return Err(StripeError::WebhookVerification(
            "timestamp outside tolerance".into(),
        ));
    }

    // Compute expected signature
    let signed_payload = format!("{timestamp}.{payload}");
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|e| StripeError::WebhookVerification(e.to_string()))?;
    mac.update(signed_payload.as_bytes());
    let expected = hex::encode(mac.finalize().into_bytes());

    // Constant-time comparison against any provided v1 signature
    let valid = signatures
        .iter()
        .any(|sig| subtle::ConstantTimeEq::ct_eq(sig.as_bytes(), expected.as_bytes()).into());

    if !valid {
        return Err(StripeError::WebhookVerification(
            "signature mismatch".into(),
        ));
    }

    serde_json::from_str(payload)
        .map_err(|e| StripeError::WebhookVerification(format!("invalid JSON: {e}")))
}

fn build_invoice_create_params(
    customer_id: stripe::CustomerId,
    metadata: Option<&std::collections::HashMap<String, String>>,
) -> CreateInvoice<'static> {
    let mut invoice_params = CreateInvoice::new();
    invoice_params.customer = Some(customer_id);
    invoice_params.collection_method = Some(CollectionMethod::ChargeAutomatically);
    invoice_params.auto_advance = Some(true);
    invoice_params.pending_invoice_items_behavior =
        Some(InvoicePendingInvoiceItemsBehavior::Include);
    if let Some(meta) = metadata {
        invoice_params.metadata = Some(meta.clone());
    }
    invoice_params
}

#[async_trait]
impl StripeService for LiveStripeService {
    async fn create_customer(&self, name: &str, email: &str) -> Result<String, StripeError> {
        let mut params = CreateCustomer::new();
        params.name = Some(name);
        params.email = Some(email);

        let customer = Customer::create(&self.client, params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(customer.id.to_string())
    }

    /// Parses the Stripe customer ID and creates a [`SetupIntent`], returning
    /// its `client_secret` for frontend confirmation.
    async fn create_setup_intent(&self, stripe_customer_id: &str) -> Result<String, StripeError> {
        let customer_id = stripe_customer_id
            .parse()
            .map_err(|_| StripeError::Api("invalid customer ID".into()))?;

        let mut params = CreateSetupIntent::new();
        params.customer = Some(customer_id);

        let intent = SetupIntent::create(&self.client, params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        intent
            .client_secret
            .ok_or_else(|| StripeError::Api("setup intent missing client_secret".into()))
    }

    async fn create_billing_portal_session(
        &self,
        stripe_customer_id: &str,
        request: &CreatePortalSessionRequest,
    ) -> Result<PortalSessionResponse, StripeError> {
        let customer_id = stripe_customer_id
            .parse()
            .map_err(|_| StripeError::Api("invalid customer ID".into()))?;

        let mut params = CreateBillingPortalSession::new(customer_id);
        params.return_url = Some(request.return_url.as_str());

        let session = BillingPortalSession::create(&self.client, params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(PortalSessionResponse { url: session.url })
    }

    /// Lists Card-type payment methods for the customer, fetching the customer
    /// record to identify which method is the default for invoices.
    async fn list_payment_methods(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Vec<PaymentMethodSummary>, StripeError> {
        let customer_id: stripe::CustomerId = stripe_customer_id
            .parse()
            .map_err(|_| StripeError::Api("invalid customer ID".into()))?;

        // Fetch customer to determine default payment method
        let customer = Customer::retrieve(&self.client, &customer_id, &[])
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        let default_pm_id = customer
            .invoice_settings
            .and_then(|s| s.default_payment_method)
            .map(|pm| pm.id().to_string());

        let mut params = ListPaymentMethods::new();
        params.customer = Some(customer_id);
        params.type_ = Some(PaymentMethodTypeFilter::Card);

        let methods = PaymentMethod::list(&self.client, &params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(methods
            .data
            .into_iter()
            .filter_map(|pm| {
                let card = pm.card?;
                let pm_id = pm.id.to_string();
                Some(PaymentMethodSummary {
                    is_default: default_pm_id.as_deref() == Some(&pm_id),
                    id: pm_id,
                    card_brand: card.brand.clone(),
                    last4: card.last4.clone(),
                    exp_month: card.exp_month as u32,
                    exp_year: card.exp_year as u32,
                })
            })
            .collect())
    }

    async fn detach_payment_method(&self, pm_id: &str) -> Result<(), StripeError> {
        let id = pm_id
            .parse()
            .map_err(|_| StripeError::Api("invalid payment method ID".into()))?;

        PaymentMethod::detach(&self.client, &id)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(())
    }

    /// Updates the customer.s `invoice_settings.default_payment_method` to the
    /// given payment method ID.
    async fn set_default_payment_method(
        &self,
        stripe_customer_id: &str,
        pm_id: &str,
    ) -> Result<(), StripeError> {
        let customer_id = stripe_customer_id
            .parse()
            .map_err(|_| StripeError::Api("invalid customer ID".into()))?;

        let mut params = UpdateCustomer::new();
        params.invoice_settings = Some(CustomerInvoiceSettings {
            default_payment_method: Some(pm_id.to_string()),
            ..Default::default()
        });

        Customer::update(&self.client, &customer_id, params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(())
    }

    /// Creates invoice line items, builds the invoice with an optional idempotency
    /// key and metadata, finalizes it, and returns the hosted URL and PDF link.
    async fn create_and_finalize_invoice(
        &self,
        stripe_customer_id: &str,
        line_items: &[StripeInvoiceLineItem],
        metadata: Option<&std::collections::HashMap<String, String>>,
        idempotency_key: Option<&str>,
    ) -> Result<FinalizedInvoice, StripeError> {
        let customer_id: stripe::CustomerId = stripe_customer_id
            .parse()
            .map_err(|_| StripeError::Api("invalid customer ID".into()))?;

        // Create InvoiceItems for each line item
        for item in line_items {
            let mut params = CreateInvoiceItem::new(customer_id.clone());
            params.amount = Some(item.amount_cents);
            params.currency = Some(stripe::Currency::USD);
            params.description = Some(&item.description);

            stripe::InvoiceItem::create(&self.client, params)
                .await
                .map_err(|e| StripeError::Api(e.to_string()))?;
        }

        // Create invoice from pending line items added above.
        let invoice_params = build_invoice_create_params(customer_id, metadata);

        let client = idempotency_key
            .map(|key| {
                self.client
                    .clone()
                    .with_strategy(RequestStrategy::Idempotent(key.to_string()))
            })
            .unwrap_or_else(|| self.client.clone());

        let invoice = Invoice::create(&client, invoice_params)
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        let invoice_id = invoice.id.clone();

        // Finalize the invoice
        let finalized =
            Invoice::finalize(&self.client, &invoice_id, FinalizeInvoiceParams::default())
                .await
                .map_err(|e| StripeError::Api(e.to_string()))?;

        let stripe_invoice_id = finalized.id.to_string();
        let hosted_invoice_url = finalized
            .hosted_invoice_url
            .ok_or_else(|| StripeError::Api("finalized invoice missing hosted URL".into()))?;
        let pdf_url = finalized.invoice_pdf;

        Ok(FinalizedInvoice {
            stripe_invoice_id,
            hosted_invoice_url,
            pdf_url,
        })
    }

    /// Verifies the Stripe webhook HMAC-SHA256 signature, then extracts the
    /// event `id`, `type`, and `data` from the parsed JSON payload.
    fn construct_webhook_event(
        &self,
        payload: &str,
        signature: &str,
        secret: &str,
    ) -> Result<StripeEvent, StripeError> {
        let parsed = verify_webhook_signature(payload, signature, secret)?;

        let id = parsed["id"]
            .as_str()
            .ok_or_else(|| StripeError::WebhookVerification("missing event id".into()))?
            .to_string();
        let event_type = parsed["type"]
            .as_str()
            .ok_or_else(|| StripeError::WebhookVerification("missing event type".into()))?
            .to_string();
        let data = parsed["data"].clone();

        Ok(StripeEvent {
            id,
            event_type,
            data,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_signature(payload: &str, secret: &str, timestamp: i64) -> String {
        let signed_payload = format!("{timestamp}.{payload}");
        let mut mac = HmacSha256::new_from_slice(secret.as_bytes()).unwrap();
        mac.update(signed_payload.as_bytes());
        let sig = hex::encode(mac.finalize().into_bytes());
        format!("t={timestamp},v1={sig}")
    }

    #[test]
    fn valid_webhook_signature_accepted() {
        let secret = "whsec_test_secret";
        let payload = r#"{"id":"evt_123","type":"invoice.payment_succeeded","data":{"object":{}}}"#;
        let ts = chrono::Utc::now().timestamp();
        let sig = make_signature(payload, secret, ts);

        let result = verify_webhook_signature(payload, &sig, secret);
        assert!(result.is_ok());
    }

    #[test]
    fn invalid_signature_rejected() {
        let secret = "whsec_test_secret";
        let payload = r#"{"id":"evt_123","type":"test","data":{}}"#;
        let ts = chrono::Utc::now().timestamp();
        let sig = format!("t={ts},v1=invalid_hex_signature");

        let result = verify_webhook_signature(payload, &sig, secret);
        assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
    }

    #[test]
    fn expired_timestamp_rejected() {
        let secret = "whsec_test_secret";
        let payload = r#"{"id":"evt_123","type":"test","data":{}}"#;
        let ts = chrono::Utc::now().timestamp() - 600; // 10 min ago
        let sig = make_signature(payload, secret, ts);

        let result = verify_webhook_signature(payload, &sig, secret);
        assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
    }

    #[test]
    fn missing_timestamp_rejected() {
        let result = verify_webhook_signature("{}", "v1=abc123", "secret");
        assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
    }

    #[test]
    fn missing_v1_signature_rejected() {
        let ts = chrono::Utc::now().timestamp();
        let result = verify_webhook_signature("{}", &format!("t={ts}"), "secret");
        assert!(matches!(result, Err(StripeError::WebhookVerification(_))));
    }

    #[test]
    fn invoice_create_params_include_pending_invoice_items() {
        let customer_id: stripe::CustomerId = "cus_test".parse().unwrap();
        let params = build_invoice_create_params(customer_id, None);
        assert_eq!(
            params.pending_invoice_items_behavior,
            Some(InvoicePendingInvoiceItemsBehavior::Include),
            "invoice creation must include pending invoice items so billed line items are charged"
        );
    }
}
