use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct CustomerRateOverrideRow {
    pub customer_id: Uuid,
    pub rate_card_id: Uuid,
    pub overrides: serde_json::Value,
    pub created_at: DateTime<Utc>,
}
