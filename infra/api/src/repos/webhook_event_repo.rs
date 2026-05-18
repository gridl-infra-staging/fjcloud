//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/webhook_event_repo.rs.
use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::repos::error::RepoError;

/// Canonical persisted webhook-event row shape shared by repo, route, and tests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, sqlx::FromRow)]
pub struct WebhookEventRow {
    pub stripe_event_id: String,
    pub event_type: String,
    pub payload: serde_json::Value,
    pub processed_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
}

/// Stripe webhook idempotency repository: try-insert records an event and
/// returns whether the current caller won first insert; mark-processed records
/// successful completion for persisted event state.
#[async_trait]
pub trait WebhookEventRepo {
    /// Record a webhook event if needed and return whether this caller won insert.
    ///
    /// Returns:
    /// - `true` when this call inserted a new row for `stripe_event_id`
    /// - `false` when `stripe_event_id` already existed, including unprocessed rows
    async fn try_insert(
        &self,
        stripe_event_id: &str,
        event_type: &str,
        payload: &serde_json::Value,
    ) -> Result<bool, RepoError>;

    /// Mark a webhook event as successfully processed.
    async fn mark_processed(&self, stripe_event_id: &str) -> Result<(), RepoError>;

    /// Resolve the most recent Stripe invoice id observed for a payment-intent id.
    /// Used for webhook payloads (for example `charge.refunded`) that omit
    /// `data.object.invoice` but include `data.object.payment_intent`.
    async fn find_latest_invoice_id_by_payment_intent(
        &self,
        payment_intent_id: &str,
    ) -> Result<Option<String>, RepoError>;

    /// Count stale, unprocessed webhook events older than `older_than`.
    ///
    /// SQL contract:
    /// - include only rows with `processed_at IS NULL`
    /// - include only rows where `created_at < NOW() - older_than`
    /// - return a single aggregate count row (`0` when none match)
    ///
    /// Used by `WebhookLagPublisher` to emit the CloudWatch webhook backlog metric.
    async fn count_stale_unprocessed(
        &self,
        older_than: std::time::Duration,
    ) -> Result<i64, RepoError>;

    /// Remove an unprocessed event row so future retries can re-insert.
    /// Called after a handler failure to prevent permanent stuck events.
    async fn delete_unprocessed(&self, stripe_event_id: &str) -> Result<(), RepoError>;

    /// Resolve one persisted webhook row by exact Stripe event id.
    async fn find_by_stripe_event_id(
        &self,
        stripe_event_id: &str,
    ) -> Result<Option<WebhookEventRow>, RepoError>;
}
