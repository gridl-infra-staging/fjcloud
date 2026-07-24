use async_trait::async_trait;
use sqlx::PgPool;

use crate::repos::dispute_repo::{DisputeRepo, DisputeRow, DisputeUpsertInput};
use crate::repos::error::RepoError;

pub struct PgDisputeRepo {
    pool: PgPool,
}

impl PgDisputeRepo {
    pub fn new(pool: PgPool) -> Self {
        Self { pool }
    }
}

#[async_trait]
impl DisputeRepo for PgDisputeRepo {
    async fn upsert(&self, input: &DisputeUpsertInput) -> Result<DisputeRow, RepoError> {
        sqlx::query_as::<_, DisputeRow>(
            "INSERT INTO disputes (
                stripe_dispute_id,
                stripe_charge_id,
                stripe_payment_intent_id,
                invoice_id,
                amount_cents,
                currency,
                reason,
                status,
                evidence_due_by,
                disputed_at,
                resolved_at
            ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
            ON CONFLICT (stripe_dispute_id) DO UPDATE SET
                stripe_charge_id = EXCLUDED.stripe_charge_id,
                stripe_payment_intent_id = EXCLUDED.stripe_payment_intent_id,
                invoice_id = COALESCE(EXCLUDED.invoice_id, disputes.invoice_id),
                amount_cents = EXCLUDED.amount_cents,
                currency = EXCLUDED.currency,
                reason = EXCLUDED.reason,
                status = EXCLUDED.status,
                evidence_due_by = EXCLUDED.evidence_due_by,
                disputed_at = EXCLUDED.disputed_at,
                resolved_at = EXCLUDED.resolved_at,
                updated_at = NOW()
            RETURNING
                id,
                stripe_dispute_id,
                stripe_charge_id,
                stripe_payment_intent_id,
                invoice_id,
                amount_cents,
                currency,
                reason,
                status,
                evidence_due_by,
                disputed_at,
                resolved_at,
                created_at,
                updated_at",
        )
        .bind(&input.stripe_dispute_id)
        .bind(&input.stripe_charge_id)
        .bind(&input.stripe_payment_intent_id)
        .bind(input.invoice_id)
        .bind(input.amount_cents)
        .bind(&input.currency)
        .bind(&input.reason)
        .bind(&input.status)
        .bind(input.evidence_due_by)
        .bind(input.disputed_at)
        .bind(input.resolved_at)
        .fetch_one(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }

    async fn find_by_stripe_dispute_id(
        &self,
        stripe_dispute_id: &str,
    ) -> Result<Option<DisputeRow>, RepoError> {
        sqlx::query_as::<_, DisputeRow>(
            "SELECT
                id,
                stripe_dispute_id,
                stripe_charge_id,
                stripe_payment_intent_id,
                invoice_id,
                amount_cents,
                currency,
                reason,
                status,
                evidence_due_by,
                disputed_at,
                resolved_at,
                created_at,
                updated_at
             FROM disputes
             WHERE stripe_dispute_id = $1",
        )
        .bind(stripe_dispute_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(|e| RepoError::Other(e.to_string()))
    }
}
