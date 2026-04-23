//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/repos/invoice_repo.rs.
use async_trait::async_trait;
use chrono::NaiveDate;
use rust_decimal::Decimal;
use uuid::Uuid;

use crate::models::{InvoiceLineItemRow, InvoiceRow};
use crate::repos::error::RepoError;

pub struct NewInvoice {
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub subtotal_cents: i64,
    pub total_cents: i64,
    pub minimum_applied: bool,
}

pub struct NewLineItem {
    pub description: String,
    pub quantity: Decimal,
    pub unit: String,
    pub unit_price_cents: Decimal,
    pub amount_cents: i64,
    pub region: String,
    pub metadata: Option<serde_json::Value>,
}

/// Invoice lifecycle repository: atomic creation with line items, status
/// transitions (draft → finalized → paid/failed/refunded), and Stripe
/// invoice linking (ID, hosted URL, PDF URL).
#[async_trait]
pub trait InvoiceRepo {
    /// Creates an invoice and its line items atomically. Returns both the invoice row
    /// and the persisted line item rows so callers never need a second DB round-trip.
    async fn create_with_line_items(
        &self,
        invoice: NewInvoice,
        line_items: Vec<NewLineItem>,
    ) -> Result<(InvoiceRow, Vec<InvoiceLineItemRow>), RepoError>;

    async fn list_by_customer(&self, customer_id: Uuid) -> Result<Vec<InvoiceRow>, RepoError>;

    async fn find_by_id(&self, id: Uuid) -> Result<Option<InvoiceRow>, RepoError>;

    async fn get_line_items(&self, invoice_id: Uuid) -> Result<Vec<InvoiceLineItemRow>, RepoError>;

    // Invoice lifecycle transitions
    async fn finalize(&self, id: Uuid) -> Result<InvoiceRow, RepoError>;
    async fn mark_paid(&self, id: Uuid) -> Result<InvoiceRow, RepoError>;
    async fn mark_failed(&self, id: Uuid) -> Result<InvoiceRow, RepoError>;
    async fn mark_refunded(&self, id: Uuid) -> Result<InvoiceRow, RepoError>;

    // Stripe fields
    async fn set_stripe_fields(
        &self,
        id: Uuid,
        stripe_invoice_id: &str,
        hosted_invoice_url: &str,
        pdf_url: Option<&str>,
    ) -> Result<(), RepoError>;

    async fn find_by_stripe_invoice_id(
        &self,
        stripe_invoice_id: &str,
    ) -> Result<Option<InvoiceRow>, RepoError>;
}
