//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/models/invoice.rs.
use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Invoice record with billing period, amounts (subtotal, tax, total),
/// currency, status, `minimum_applied` flag, and Stripe references
/// (`stripe_invoice_id`, hosted URL, PDF).
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct InvoiceRow {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub subtotal_cents: i64,
    pub tax_cents: i64,
    pub total_cents: i64,
    pub currency: String,
    pub status: String,
    pub minimum_applied: bool,
    pub stripe_invoice_id: Option<String>,
    pub hosted_invoice_url: Option<String>,
    pub pdf_url: Option<String>,
    pub created_at: DateTime<Utc>,
    pub finalized_at: Option<DateTime<Utc>>,
    pub paid_at: Option<DateTime<Utc>>,
}
