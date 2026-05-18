use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::repos::error::RepoError;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, sqlx::FromRow)]
pub struct DisputeRow {
    pub id: Uuid,
    pub stripe_dispute_id: String,
    pub stripe_charge_id: String,
    pub stripe_payment_intent_id: Option<String>,
    pub invoice_id: Option<Uuid>,
    pub amount_cents: i64,
    pub currency: String,
    pub reason: Option<String>,
    pub status: String,
    pub evidence_due_by: Option<DateTime<Utc>>,
    pub disputed_at: Option<DateTime<Utc>>,
    pub resolved_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DisputeUpsertInput {
    pub stripe_dispute_id: String,
    pub stripe_charge_id: String,
    pub stripe_payment_intent_id: Option<String>,
    pub invoice_id: Option<Uuid>,
    pub amount_cents: i64,
    pub currency: String,
    pub reason: Option<String>,
    pub status: String,
    pub evidence_due_by: Option<DateTime<Utc>>,
    pub disputed_at: Option<DateTime<Utc>>,
    pub resolved_at: Option<DateTime<Utc>>,
}

#[async_trait]
pub trait DisputeRepo {
    async fn upsert(&self, input: &DisputeUpsertInput) -> Result<DisputeRow, RepoError>;

    async fn find_by_stripe_dispute_id(
        &self,
        stripe_dispute_id: &str,
    ) -> Result<Option<DisputeRow>, RepoError>;
}
