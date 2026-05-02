//! Stub `StripeService` returning `NotConfigured` for every operation.
//!
//! Extracted from `startup.rs` so that file stays within the 800-line
//! limit enforced by `scripts/check-sizes.sh` in the staging CI pipeline.
//! Used when `STRIPE_SECRET_KEY` is not set; the rest of the API can
//! still bootstrap (free-tier signups, admin tooling, etc.) and any
//! Stripe-gated handler returns the `NotConfigured` variant cleanly.

use crate::stripe::StripeError;

/// A no-op `StripeService` that returns `NotConfigured` for all operations.
pub struct UnconfiguredStripeService;

#[async_trait::async_trait]
impl crate::stripe::StripeService for UnconfiguredStripeService {
    async fn create_customer(&self, _: &str, _: &str) -> Result<String, StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn create_setup_intent(&self, _: &str) -> Result<String, StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn create_billing_portal_session(
        &self,
        _: &str,
        _: &crate::stripe::CreatePortalSessionRequest,
    ) -> Result<crate::stripe::PortalSessionResponse, StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn list_payment_methods(
        &self,
        _: &str,
    ) -> Result<Vec<crate::stripe::PaymentMethodSummary>, StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn detach_payment_method(&self, _: &str) -> Result<(), StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn set_default_payment_method(&self, _: &str, _: &str) -> Result<(), StripeError> {
        Err(StripeError::NotConfigured)
    }
    async fn create_and_finalize_invoice(
        &self,
        _: &str,
        _: &[crate::stripe::StripeInvoiceLineItem],
        _: Option<&std::collections::HashMap<String, String>>,
        _: Option<&str>,
    ) -> Result<crate::stripe::FinalizedInvoice, StripeError> {
        Err(StripeError::NotConfigured)
    }
    fn construct_webhook_event(
        &self,
        _: &str,
        _: &str,
        _: &str,
    ) -> Result<crate::stripe::StripeEvent, StripeError> {
        Err(StripeError::NotConfigured)
    }
}
