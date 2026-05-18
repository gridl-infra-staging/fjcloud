//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/stripe/mod.rs.
pub mod live;
pub mod local;

use async_trait::async_trait;
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum StripeError {
    #[error("stripe API error: {0}")]
    Api(String),

    #[error("stripe not configured")]
    NotConfigured,

    #[error("webhook signature verification failed: {0}")]
    WebhookVerification(String),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PaymentMethodSummary {
    pub id: String,
    pub card_brand: String,
    pub last4: String,
    pub exp_month: u32,
    pub exp_year: u32,
    pub is_default: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StripeInvoiceLineItem {
    pub description: String,
    pub amount_cents: i64,
}

#[derive(Debug, Clone)]
pub struct FinalizedInvoice {
    pub stripe_invoice_id: String,
    pub hosted_invoice_url: String,
    pub pdf_url: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StripeLastPaymentError {
    pub code: Option<String>,
    pub decline_code: Option<String>,
    pub message: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PaidInvoice {
    pub id: String,
    pub status: String,
    pub amount_paid_cents: i64,
    pub last_payment_error: Option<StripeLastPaymentError>,
}

/// Normalized charge lookup response consumed by webhook routes so they can
/// avoid direct dependencies on Stripe SDK response object shapes.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StripeChargeLookup {
    pub charge_id: String,
    pub invoice_id: Option<String>,
    pub payment_intent_id: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StripeEvent {
    pub id: String,
    pub event_type: String,
    pub data: serde_json::Value,
}

/// Response from creating a Stripe Checkout Session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckoutSessionResponse {
    pub id: String,
    pub url: String,
}

/// Input for creating a Stripe Billing Portal session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreatePortalSessionRequest {
    pub return_url: String,
}

/// Response from creating a Stripe Billing Portal session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PortalSessionResponse {
    pub url: String,
}

/// Build a deterministic idempotency key for invoice create+finalize requests.
pub fn invoice_create_idempotency_key(
    customer_id: Uuid,
    period_start: NaiveDate,
    period_end: NaiveDate,
) -> String {
    let payload = format!("{customer_id}:{period_start}:{period_end}");
    let digest = Sha256::digest(payload.as_bytes());
    let hash = hex::encode(digest);

    // Bounded length to keep the Stripe header safely small while staying
    // deterministic and collision-resistant for our usage.
    format!("fjcloud-invoice-{}", &hash[..32])
}

/// Build a deterministic idempotency key for shared-plan activation invoice
/// create+finalize requests.
pub fn activation_upgrade_idempotency_key(
    customer_id: Uuid,
    subscription_cycle_anchor_at: DateTime<Utc>,
) -> String {
    let payload = format!(
        "upgrade:{customer_id}:{}",
        subscription_cycle_anchor_at.to_rfc3339()
    );
    let digest = Sha256::digest(payload.as_bytes());
    let hash = hex::encode(digest);
    format!("fjcloud-upgrade-{}", &hash[..32])
}

/// Parsed subscription data from Stripe API.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscriptionData {
    pub id: String,
    pub status: String,
    pub current_period_start: i64,
    pub current_period_end: i64,
    pub cancel_at_period_end: bool,
    pub customer: String,
    pub items: Vec<SubscriptionItem>,
}

/// A line item in a subscription.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubscriptionItem {
    pub id: String,
    pub price_id: String,
}

/// Async trait abstracting Stripe operations: customer creation, payment
/// method management, invoice creation/finalization, and webhook verification.
#[async_trait]
pub trait StripeService: Send + Sync {
    async fn create_customer(&self, name: &str, email: &str) -> Result<String, StripeError>;

    async fn create_setup_intent(&self, stripe_customer_id: &str) -> Result<String, StripeError>;

    async fn create_billing_portal_session(
        &self,
        stripe_customer_id: &str,
        request: &CreatePortalSessionRequest,
    ) -> Result<PortalSessionResponse, StripeError>;

    async fn list_payment_methods(
        &self,
        stripe_customer_id: &str,
    ) -> Result<Vec<PaymentMethodSummary>, StripeError>;

    async fn detach_payment_method(&self, pm_id: &str) -> Result<(), StripeError>;

    async fn set_default_payment_method(
        &self,
        stripe_customer_id: &str,
        pm_id: &str,
    ) -> Result<(), StripeError>;

    async fn create_and_finalize_invoice(
        &self,
        stripe_customer_id: &str,
        line_items: &[StripeInvoiceLineItem],
        metadata: Option<&std::collections::HashMap<String, String>>,
        idempotency_key: Option<&str>,
    ) -> Result<FinalizedInvoice, StripeError>;

    async fn pay_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError>;

    async fn void_invoice(&self, stripe_invoice_id: &str) -> Result<PaidInvoice, StripeError>;

    /// Resolve fallback linkage fields from a charge ID using a normalized
    /// model that isolates webhook routes from Stripe SDK object shapes.
    async fn lookup_charge_fallback_fields(
        &self,
        charge_id: &str,
    ) -> Result<StripeChargeLookup, StripeError>;

    fn construct_webhook_event(
        &self,
        payload: &str,
        signature: &str,
        secret: &str,
    ) -> Result<StripeEvent, StripeError>;
}
