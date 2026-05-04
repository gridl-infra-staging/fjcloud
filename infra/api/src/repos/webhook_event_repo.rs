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

    /// Resolve the most recent Stripe invoice id observed for a payment-intent id.
    /// Used for webhook payloads (for example `charge.refunded`) that omit
    /// `data.object.invoice` but include `data.object.payment_intent`.
    async fn find_latest_invoice_id_by_payment_intent(
        &self,
        payment_intent_id: &str,
    ) -> Result<Option<String>, RepoError>;

    /// Resolve one persisted webhook row by exact Stripe event id.
    async fn find_by_stripe_event_id(
        &self,
        stripe_event_id: &str,
    ) -> Result<Option<WebhookEventRow>, RepoError>;
}
