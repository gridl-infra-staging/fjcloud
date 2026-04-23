//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar22_pm_2_utoipa_openapi_docs/fjcloud_dev/infra/api/src/routes/invoices.rs.
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, NaiveDate, Utc};
use serde::Serialize;
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::{InvoiceLineItemRow, InvoiceRow};
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Response DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct InvoiceListItem {
    pub id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub subtotal_cents: i64,
    pub total_cents: i64,
    pub status: String,
    pub minimum_applied: bool,
    pub created_at: DateTime<Utc>,
}

impl From<&InvoiceRow> for InvoiceListItem {
    fn from(row: &InvoiceRow) -> Self {
        Self {
            id: row.id,
            period_start: row.period_start,
            period_end: row.period_end,
            subtotal_cents: row.subtotal_cents,
            total_cents: row.total_cents,
            status: row.status.clone(),
            minimum_applied: row.minimum_applied,
            created_at: row.created_at,
        }
    }
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct LineItemResponse {
    pub id: Uuid,
    pub description: String,
    pub quantity: String,
    pub unit: String,
    pub unit_price_cents: String,
    pub amount_cents: i64,
    pub region: String,
}

impl From<&InvoiceLineItemRow> for LineItemResponse {
    fn from(row: &InvoiceLineItemRow) -> Self {
        Self {
            id: row.id,
            description: row.description.clone(),
            quantity: row.quantity.to_string(),
            unit: row.unit.clone(),
            unit_price_cents: row.unit_price_cents.to_string(),
            amount_cents: row.amount_cents,
            region: row.region.clone(),
        }
    }
}

/// Full invoice detail returned by `GET /invoices/{invoice_id}`, including
/// Stripe links (hosted URL, PDF), line items, and finalization/payment
/// timestamps. Fields like `stripe_invoice_id` and `hosted_invoice_url` are
/// `None` until the invoice is finalized and synced with Stripe.
#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct InvoiceDetailResponse {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub period_start: NaiveDate,
    pub period_end: NaiveDate,
    pub subtotal_cents: i64,
    pub total_cents: i64,
    pub tax_cents: i64,
    pub currency: String,
    pub status: String,
    pub minimum_applied: bool,
    pub stripe_invoice_id: Option<String>,
    pub hosted_invoice_url: Option<String>,
    pub pdf_url: Option<String>,
    pub line_items: Vec<LineItemResponse>,
    pub created_at: DateTime<Utc>,
    pub finalized_at: Option<DateTime<Utc>>,
    pub paid_at: Option<DateTime<Utc>>,
}

/// Assemble an [`InvoiceDetailResponse`] from an invoice row and its line items.
///
/// Pure mapping helper shared by the tenant-facing `get_invoice` handler and
/// the admin invoice endpoints.
pub fn build_detail_response(
    invoice: &InvoiceRow,
    line_items: Vec<InvoiceLineItemRow>,
) -> InvoiceDetailResponse {
    InvoiceDetailResponse {
        id: invoice.id,
        customer_id: invoice.customer_id,
        period_start: invoice.period_start,
        period_end: invoice.period_end,
        subtotal_cents: invoice.subtotal_cents,
        total_cents: invoice.total_cents,
        tax_cents: invoice.tax_cents,
        currency: invoice.currency.clone(),
        status: invoice.status.clone(),
        minimum_applied: invoice.minimum_applied,
        stripe_invoice_id: invoice.stripe_invoice_id.clone(),
        hosted_invoice_url: invoice.hosted_invoice_url.clone(),
        pdf_url: invoice.pdf_url.clone(),
        line_items: line_items.iter().map(LineItemResponse::from).collect(),
        created_at: invoice.created_at,
        finalized_at: invoice.finalized_at,
        paid_at: invoice.paid_at,
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET /invoices — list all invoices for the authenticated tenant.
#[utoipa::path(
    get,
    path = "/invoices",
    tag = "Invoices",
    responses(
        (status = 200, description = "List of invoices", body = Vec<InvoiceListItem>),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn list_invoices(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let invoices = state
        .invoice_repo
        .list_by_customer(tenant.customer_id)
        .await?;

    let items: Vec<InvoiceListItem> = invoices.iter().map(InvoiceListItem::from).collect();
    Ok(Json(items))
}

/// GET /invoices/:invoice_id — get invoice details with line items.
#[utoipa::path(
    get,
    path = "/invoices/{invoice_id}",
    tag = "Invoices",
    params(("invoice_id" = Uuid, Path, description = "Invoice identifier")),
    responses(
        (status = 200, description = "Invoice detail with line items", body = InvoiceDetailResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 403, description = "Access denied", body = crate::errors::ErrorResponse),
        (status = 404, description = "Invoice not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_invoice(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(invoice_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let invoice = state
        .invoice_repo
        .find_by_id(invoice_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("invoice not found".into()))?;

    if invoice.customer_id != tenant.customer_id {
        return Err(ApiError::Forbidden("access denied".into()));
    }

    let line_items = state.invoice_repo.get_line_items(invoice_id).await?;
    let response = build_detail_response(&invoice, line_items);
    Ok((StatusCode::OK, Json(response)))
}
