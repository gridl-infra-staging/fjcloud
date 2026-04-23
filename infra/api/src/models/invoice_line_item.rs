use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct InvoiceLineItemRow {
    pub id: Uuid,
    pub invoice_id: Uuid,
    pub description: String,
    pub quantity: Decimal,
    pub unit: String,
    pub unit_price_cents: Decimal,
    pub amount_cents: i64,
    pub region: String,
    pub metadata: Option<serde_json::Value>,
}
