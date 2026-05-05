use async_trait::async_trait;
use sqlx::PgPool;

use crate::repos::error::RepoError;
use crate::repos::webhook_event_repo::{WebhookEventRepo, WebhookEventRow};

pub struct PgWebhookEventRepo {
    pool: PgPool,
}

impl PgWebhookEventRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl WebhookEventRepo for PgWebhookEventRepo {
    /// Attempts to insert a webhook event once using the unique `stripe_event_id`.
    /// Returns `true` only for the caller that inserted the row.
    async fn try_insert(
        &self,
        stripe_event_id: &str,
        event_type: &str,
        payload: &serde_json::Value,
    ) -> Result<bool, RepoError> {
        let inserted = sqlx::query_scalar::<_, bool>(
            "WITH inserted AS ( \
               INSERT INTO webhook_events (stripe_event_id, event_type, payload) \
               VALUES ($1, $2, $3) \
               ON CONFLICT (stripe_event_id) DO NOTHING \
               RETURNING 1 \
             ) \
             SELECT EXISTS(SELECT 1 FROM inserted)",
        )
        .bind(stripe_event_id)
        .bind(event_type)
        .bind(payload)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(inserted)
    }

    async fn mark_processed(&self, stripe_event_id: &str) -> Result<(), RepoError> {
        sqlx::query(
            "UPDATE webhook_events \
             SET processed_at = NOW() \
             WHERE stripe_event_id = $1",
        )
        .bind(stripe_event_id)
        .execute(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;

        Ok(())
    }

    /// Look up the latest stripe invoice id for a given payment_intent id by
    /// scanning prior `invoice.payment_succeeded`/`invoice.paid` webhook events.
    ///
    /// Returns `Ok(None)` when no matching event has been seen — including the
    /// production-realistic case where a `charge.refunded` arrives for a charge
    /// whose payment_intent was never associated with one of our customer
    /// invoices (synthetic Stripe-side invoices, ad-hoc charges, etc).
    ///
    /// Implementation note: must use `fetch_optional` rather than `fetch_one`.
    /// `fetch_one` errors with `RowNotFound` when the query returns zero rows,
    /// which would surface as a 500 to Stripe and block webhook acknowledgement.
    /// This was caught 2026-05-03 by the Phase G live invoice probe — the
    /// charge.refunded handler called this fn for a payment_intent we'd never
    /// processed, returning 500 → Stripe stuck in retry. Mock repo returned
    /// None gracefully so unit tests passed; only the real Postgres path
    /// surfaced the bug.
    async fn find_latest_invoice_id_by_payment_intent(
        &self,
        payment_intent_id: &str,
    ) -> Result<Option<String>, RepoError> {
        // The DB column is JSONB extracted to text; the `Option<String>` row type
        // accommodates a NULL extracted value. `fetch_optional` then wraps the
        // whole thing in another Option for "zero rows", so we flatten.
        let row: Option<Option<String>> = sqlx::query_scalar::<_, Option<String>>(
            "SELECT payload->'data'->'object'->>'id' \
             FROM webhook_events \
             WHERE event_type IN ('invoice.payment_succeeded', 'invoice.paid') \
               AND payload->'data'->'object'->>'payment_intent' = $1 \
             ORDER BY created_at DESC \
             LIMIT 1",
        )
        .bind(payment_intent_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))?;
        Ok(row.flatten())
    }

    async fn find_by_stripe_event_id(
        &self,
        stripe_event_id: &str,
    ) -> Result<Option<WebhookEventRow>, RepoError> {
        sqlx::query_as::<_, WebhookEventRow>(
            "SELECT stripe_event_id, event_type, payload, processed_at, created_at \
             FROM webhook_events \
             WHERE stripe_event_id = $1",
        )
        .bind(stripe_event_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }
}
