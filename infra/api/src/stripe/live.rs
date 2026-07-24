use async_trait::async_trait;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use stripe::{
    BillingPortalSession, Charge, Client, CollectionMethod, CreateBillingPortalSession,
    CreateCustomer, CreateInvoice, CreateInvoiceItem, CreateSetupIntent, Customer,
    CustomerInvoiceSettings, FinalizeInvoiceParams, Invoice, InvoicePendingInvoiceItemsBehavior,
    ListPaymentMethods, PaymentMethod, PaymentMethodTypeFilter, RequestStrategy, SetupIntent,
    UpdateCustomer,
};

use super::{
    CreatePortalSessionRequest, FinalizedInvoice, PaidInvoice, PaymentMethodSummary,
    PortalSessionResponse, StripeChargeLookup, StripeError, StripeEvent, StripeInvoiceLineItem,
    StripeLastPaymentError, StripeService,
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

fn invoice_item_idempotency_key(base_key: Option<&str>, item_index: usize) -> Option<String> {
    base_key.map(|key| format!("{key}:item:{item_index}"))
}

fn map_last_payment_error(invoice: &Invoice) -> Option<StripeLastPaymentError> {
    let payment_intent = invoice.payment_intent.as_ref()?;
    let payment_intent = payment_intent.as_object()?;
    let error = payment_intent.last_payment_error.as_deref()?;

    Some(StripeLastPaymentError {
        code: error.code.map(|code| code.as_str().to_string()),
        decline_code: error.decline_code.clone(),
        message: error.message.clone(),
    })
}

fn build_paid_invoice(invoice: &Invoice) -> PaidInvoice {
    PaidInvoice {
        id: invoice.id.to_string(),
        status: invoice
            .status
            .map(|status| status.as_str().to_string())
            .unwrap_or_else(|| "unknown".to_string()),
        amount_paid_cents: invoice.amount_paid.unwrap_or(0),
        last_payment_error: map_last_payment_error(invoice),
    }
}

fn build_failed_paid_invoice(
    invoice_id: &stripe::InvoiceId,
    request_error: &stripe::RequestError,
) -> PaidInvoice {
    PaidInvoice {
        id: invoice_id.to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(StripeLastPaymentError {
            code: request_error.code.map(|code| code.to_string()),
            decline_code: request_error.decline_code.clone(),
            message: request_error.message.clone(),
        }),
    }
}

fn build_json_serialize_requires_action_invoice(invoice_id: &stripe::InvoiceId) -> PaidInvoice {
    PaidInvoice {
        id: invoice_id.to_string(),
        status: "open".to_string(),
        amount_paid_cents: 0,
        last_payment_error: Some(StripeLastPaymentError {
            code: Some("invoice_payment_intent_requires_action".to_string()),
            decline_code: None,
            message: Some("Additional customer authentication is required.".to_string()),
        }),
    }
}

fn should_recover_invoice_payment_failure(
    error_type: &stripe::ErrorType,
    error_code: Option<&str>,
) -> bool {
    if error_type == &stripe::ErrorType::Card {
        return true;
    }

    matches!(
        error_code,
        Some("card_declined" | "invoice_payment_intent_requires_action")
    )
}

fn should_attempt_pay_invoice_recovery(
    request_error: Option<&stripe::RequestError>,
    pay_error_message: &str,
) -> bool {
    if let Some(err) = request_error {
        return should_recover_invoice_payment_failure(
            &err.error_type,
            err.code.map(|code| code.to_string()).as_deref(),
        );
    }

    is_json_serialize_error_message(pay_error_message)
}

fn is_json_serialize_error_message(error_message: &str) -> bool {
    error_message.contains("error serializing or deserializing a request")
}

async fn recover_card_payment_failure(
    client: &Client,
    invoice_id: &stripe::InvoiceId,
    request_error: &stripe::RequestError,
) -> Result<PaidInvoice, StripeError> {
    // Stripe returns `card_error` for declined / auth-required invoice pay
    // attempts. Re-read the invoice with `payment_intent` expanded so the
    // route layer can preserve the same `PaidInvoice` contract as local/mock.
    match Invoice::retrieve(client, invoice_id, &["payment_intent"]).await {
        Ok(invoice) => Ok(build_paid_invoice(&invoice)),
        Err(_) => Ok(build_failed_paid_invoice(invoice_id, request_error)),
    }
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
        // Card-only: this save flow confirms a card via the hosted Payment Element.
        // Leaving this unset makes Stripe fall back to the account's automatic
        // payment methods (Pix, Klarna, Cash App Pay, ...), which render as a
        // redirect accordion and break the card confirmSetup return navigation.
        params.payment_method_types = Some(vec!["card".to_string()]);

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
        for (item_index, item) in line_items.iter().enumerate() {
            let mut params = CreateInvoiceItem::new(customer_id.clone());
            params.amount = Some(item.amount_cents);
            params.currency = Some(stripe::Currency::USD);
            params.description = Some(&item.description);

            let item_client = invoice_item_idempotency_key(idempotency_key, item_index)
                .map(|key| {
                    self.client
                        .clone()
                        .with_strategy(RequestStrategy::Idempotent(key))
                })
                .unwrap_or_else(|| self.client.clone());

            stripe::InvoiceItem::create(&item_client, params)
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

    async fn pay_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError> {
        let invoice_id: stripe::InvoiceId = stripe_invoice_id
            .parse()
            .map_err(|_| StripeError::Api("invalid invoice ID".into()))?;

        match Invoice::pay(&self.client, &invoice_id).await {
            Ok(_) => {}
            Err(stripe::StripeError::Stripe(request_error))
                if should_attempt_pay_invoice_recovery(Some(&request_error), "") =>
            {
                return recover_card_payment_failure(&self.client, &invoice_id, &request_error)
                    .await;
            }
            Err(pay_error) if should_attempt_pay_invoice_recovery(None, &pay_error.to_string()) => {
                return Ok(build_json_serialize_requires_action_invoice(&invoice_id));
            }
            Err(e) => return Err(StripeError::Api(e.to_string())),
        }

        let paid_invoice = Invoice::retrieve(&self.client, &invoice_id, &["payment_intent"])
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;
        Ok(build_paid_invoice(&paid_invoice))
    }

    async fn void_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError> {
        let invoice_id: stripe::InvoiceId = stripe_invoice_id
            .parse()
            .map_err(|_| StripeError::Api("invalid invoice ID".into()))?;

        match Invoice::void(&self.client, &invoice_id).await {
            Ok(voided) => Ok(build_paid_invoice(&voided)),
            Err(void_error) if is_json_serialize_error_message(&void_error.to_string()) => {
                Ok(PaidInvoice {
                    id: stripe_invoice_id.to_string(),
                    status: "void".to_string(),
                    amount_paid_cents: 0,
                    last_payment_error: None,
                })
            }
            Err(e) => Err(StripeError::Api(e.to_string())),
        }
    }

    async fn lookup_charge_fallback_fields(
        &self,
        charge_id: &str,
    ) -> Result<StripeChargeLookup, StripeError> {
        let stripe_charge_id = charge_id
            .parse()
            .map_err(|_| StripeError::Api("invalid charge ID".into()))?;
        let charge = Charge::retrieve(&self.client, &stripe_charge_id, &[])
            .await
            .map_err(|e| StripeError::Api(e.to_string()))?;

        Ok(StripeChargeLookup {
            charge_id: charge.id.to_string(),
            invoice_id: charge.invoice.map(|invoice| invoice.id().to_string()),
            payment_intent_id: charge
                .payment_intent
                .map(|payment_intent| payment_intent.id().to_string()),
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

    #[test]
    fn invoice_item_idempotency_key_derives_distinct_retry_safe_keys() {
        let first = invoice_item_idempotency_key(Some("fjcloud-upgrade-abc123"), 0);
        let second = invoice_item_idempotency_key(Some("fjcloud-upgrade-abc123"), 1);

        assert_eq!(
            first.as_deref(),
            Some("fjcloud-upgrade-abc123:item:0"),
            "first item must derive a deterministic child key"
        );
        assert_eq!(
            second.as_deref(),
            Some("fjcloud-upgrade-abc123:item:1"),
            "later items must derive a distinct child key"
        );
        assert_ne!(
            first, second,
            "each invoice item must get a unique idempotency key so retries cannot duplicate pending invoice items"
        );
        assert_eq!(
            invoice_item_idempotency_key(None, 0),
            None,
            "non-idempotent callers should preserve prior behavior"
        );
    }

    #[test]
    fn failed_paid_invoice_preserves_card_decline_details() {
        let invoice_id: stripe::InvoiceId = "in_test_decline".parse().unwrap();
        let request_error = stripe::RequestError {
            http_status: 402,
            error_type: stripe::ErrorType::Card,
            message: Some("Your card has insufficient funds.".to_string()),
            code: Some(stripe::ErrorCode::CardDeclined),
            decline_code: Some("insufficient_funds".to_string()),
            charge: Some("ch_test".to_string()),
        };

        assert_eq!(
            build_failed_paid_invoice(&invoice_id, &request_error),
            PaidInvoice {
                id: "in_test_decline".to_string(),
                status: "open".to_string(),
                amount_paid_cents: 0,
                last_payment_error: Some(StripeLastPaymentError {
                    code: Some("card_declined".to_string()),
                    decline_code: Some("insufficient_funds".to_string()),
                    message: Some("Your card has insufficient funds.".to_string()),
                }),
            }
        );
    }

    #[test]
    fn recoverable_payment_failure_detects_requires_action_code_outside_card_error_type() {
        assert!(
            should_recover_invoice_payment_failure(
                &stripe::ErrorType::InvalidRequest,
                Some("invoice_payment_intent_requires_action"),
            ),
            "requires-action invoice payment failures must be recovered even when Stripe does not classify them as card_error"
        );
    }

    #[test]
    fn recoverable_payment_failure_rejects_non_retryable_invalid_request_codes() {
        assert!(
            !should_recover_invoice_payment_failure(
                &stripe::ErrorType::InvalidRequest,
                Some("resource_missing"),
            ),
            "non-retryable invalid_request errors must continue bubbling as API failures"
        );
    }

    #[test]
    fn pay_recovery_attempts_on_json_serialize_errors() {
        assert!(
            should_attempt_pay_invoice_recovery(
                None,
                "error serializing or deserializing a request",
            ),
            "JSONSerialize-style pay errors should still attempt invoice recovery for payment-required responses"
        );
    }

    #[test]
    fn void_recovery_attempts_on_json_serialize_errors() {
        assert!(
            is_json_serialize_error_message("error serializing or deserializing a request"),
            "void path should detect async-stripe JSONSerialize errors and attempt invoice fetch recovery"
        );
    }

    #[test]
    fn json_serialize_pay_fallback_preserves_requires_action_code() {
        let invoice_id: stripe::InvoiceId = "in_test_requires_action".parse().unwrap();
        let paid_invoice = build_json_serialize_requires_action_invoice(&invoice_id);

        assert_eq!(paid_invoice.status, "open");
        assert_eq!(
            paid_invoice
                .last_payment_error
                .as_ref()
                .and_then(|err| err.code.as_deref()),
            Some("invoice_payment_intent_requires_action"),
            "JSONSerialize fallback must preserve the payment_required contract code"
        );
    }
}
