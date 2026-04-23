//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/stripe/mod.rs.
pub mod live;
pub mod local;

use async_trait::async_trait;
use chrono::NaiveDate;
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

/// Async trait abstracting all Stripe operations: customer creation, payment
/// method management, invoice creation/finalization, webhook verification,
/// checkout sessions, and subscription lifecycle (retrieve, cancel, update).
#[async_trait]
pub trait StripeService: Send + Sync {
    async fn create_customer(&self, name: &str, email: &str) -> Result<String, StripeError>;

    async fn create_setup_intent(&self, stripe_customer_id: &str) -> Result<String, StripeError>;

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

    fn construct_webhook_event(
        &self,
        payload: &str,
        signature: &str,
        secret: &str,
    ) -> Result<StripeEvent, StripeError>;

    // ---------------------------------------------------------------------------
    // Subscription and Checkout Session methods
    // ---------------------------------------------------------------------------

    /// Creates a Stripe Checkout Session for subscription checkout.
    async fn create_checkout_session(
        &self,
        stripe_customer_id: &str,
        price_id: &str,
        success_url: &str,
        cancel_url: &str,
        metadata: Option<&std::collections::HashMap<String, String>>,
    ) -> Result<CheckoutSessionResponse, StripeError>;

    /// Retrieves a subscription by its Stripe ID.
    async fn retrieve_subscription(
        &self,
        subscription_id: &str,
    ) -> Result<SubscriptionData, StripeError>;

    /// Cancels a subscription (optionally at period end).
    async fn cancel_subscription(
        &self,
        subscription_id: &str,
        cancel_at_period_end: bool,
    ) -> Result<SubscriptionData, StripeError>;

    /// Updates a subscription's price (for plan changes).
    async fn update_subscription_price(
        &self,
        subscription_id: &str,
        new_price_id: &str,
        proration_behavior: &str,
    ) -> Result<SubscriptionData, StripeError>;
}
