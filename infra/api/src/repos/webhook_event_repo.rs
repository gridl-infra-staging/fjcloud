//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/webhook_event_repo.rs.
use async_trait::async_trait;

use crate::repos::error::RepoError;

/// Stripe webhook idempotency repository: try-insert records an event and
/// returns whether it should be processed; mark-processed prevents
/// redelivery on subsequent webhook retries.
#[async_trait]
pub trait WebhookEventRepo {
    /// Record a webhook event if needed and return whether it should be processed.
    ///
    /// Returns:
    /// - `true` for a new event, or an event previously recorded but not marked processed
    /// - `false` for an event already marked processed
    async fn try_insert(
        &self,
        stripe_event_id: &str,
        event_type: &str,
        payload: &serde_json::Value,
    ) -> Result<bool, RepoError>;

    /// Mark a webhook event as successfully processed.
    async fn mark_processed(&self, stripe_event_id: &str) -> Result<(), RepoError>;
}
