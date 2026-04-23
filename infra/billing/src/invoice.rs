use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// One line on an invoice, corresponding to a single billing dimension.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LineItem {
    pub description: String,
    /// The quantity in the given `unit`.
    /// For requests: number of 1K batches (e.g. 100.0 = 100,000 requests).
    /// For storage: GB-months.
    /// For VMs: hours.
    pub quantity: Decimal,
    /// Unit label: "requests_1k" | "write_ops_1k" | "gb_months" | "vm_hours"
    pub unit: String,
    /// Price per unit in cents.
    pub unit_price_cents: Decimal,
    /// Total for this line item, in cents, rounded to nearest cent.
    pub amount_cents: i64,
    pub region: String,
}

/// The result of running the pricing engine against a MonthlyUsageSummary.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct InvoiceCalculation {
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub line_items: Vec<LineItem>,
    /// Raw sum of usage-derived line item amounts.
    pub subtotal_cents: i64,
    /// Always false in the billing crate; minimum enforcement happens in the API layer.
    pub minimum_applied: bool,
    /// Mirrors `subtotal_cents` in the billing crate; the API layer may clamp later.
    pub total_cents: i64,
}
