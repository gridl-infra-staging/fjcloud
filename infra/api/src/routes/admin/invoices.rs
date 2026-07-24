use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::invoicing::stripe_sync::{
    send_invoice_ready_email_best_effort, send_to_stripe_and_finalize,
};
use crate::invoicing::GeneratedInvoice;
use crate::repos::error::RepoError;
use crate::repos::invoice_repo::{AdminInvoiceSummaryRow, NewInvoice};
use crate::routes::invoices::{build_detail_response, InvoiceListItem};
use crate::routes::usage::parse_month;
use crate::state::AppState;

#[derive(Debug, Deserialize)]
pub struct GenerateInvoiceRequest {
    pub month: String,
}

pub async fn list_tenant_invoices(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let invoices = state.invoice_repo.list_by_customer(customer_id).await?;

    let items: Vec<InvoiceListItem> = invoices.iter().map(InvoiceListItem::from).collect();
    Ok(Json(items))
}

/// `GET /admin/invoices/{id}` — read stored invoice details for operator drill-in.
pub async fn get_admin_invoice_detail(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(invoice_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let invoice = state
        .invoice_repo
        .find_by_id(invoice_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("invoice not found".into()))?;
    let line_items = state.invoice_repo.get_line_items(invoice_id).await?;
    Ok(Json(build_detail_response(&invoice, line_items)))
}

pub async fn generate_invoice(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(req): Json<GenerateInvoiceRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let (start, end) = parse_month(&req.month)?;

    let customer = require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let repos = crate::invoicing::BillingRepos::from_state(&state);
    let generated = crate::invoicing::compute_invoice_for_customer(
        &repos,
        customer_id,
        start,
        end,
        customer.billing_plan_for_billing(),
        customer.object_storage_egress_carryforward_cents,
    )
    .await?;

    let (invoice, line_items) = state
        .invoice_repo
        .create_with_line_items(
            build_new_invoice(customer_id, &generated),
            generated.line_items,
        )
        .await?;

    let response = build_detail_response(&invoice, line_items);
    Ok((StatusCode::CREATED, Json(response)))
}

/// `POST /admin/invoices/{id}/finalize` — finalize a draft invoice to Stripe.
///
/// **Auth:** `AdminAuth`.
/// Requires the invoice to be in `draft` status, the customer to be active, and
/// a `stripe_customer_id` to be linked. Pushes the invoice to Stripe, advances
/// egress watermarks from the draft snapshot, persists carry-forward, marks
/// the invoice as finalized, and sends an invoice-ready email (best-effort).
/// On Stripe or finalization failure, attempts to roll back egress mutations;
/// if rollback itself fails, returns a combined error describing the partial state.
pub async fn finalize_invoice(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(invoice_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let invoice = state
        .invoice_repo
        .find_by_id(invoice_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("invoice not found".into()))?;

    if invoice.status != "draft" {
        return Err(ApiError::BadRequest(
            "invoice is not in draft status".into(),
        ));
    }

    let customer =
        require_active_customer(state.customer_repo.as_ref(), invoice.customer_id).await?;

    let stripe_customer_id = customer
        .stripe_customer_id
        .as_deref()
        .ok_or_else(|| ApiError::BadRequest("customer has no stripe account linked".into()))?;

    let final_invoice = send_to_stripe_and_finalize(&state, invoice_id, stripe_customer_id).await?;
    send_invoice_ready_email_best_effort(
        &state,
        &customer.email,
        invoice_id,
        final_invoice.hosted_invoice_url.as_deref(),
        final_invoice.pdf_url.as_deref(),
        "admin_invoice_finalize",
    )
    .await;

    let response_line_items = state.invoice_repo.get_line_items(invoice_id).await?;
    let response = build_detail_response(&final_invoice, response_line_items);
    Ok(Json(response))
}

// ---------------------------------------------------------------------------
// POST /admin/billing/run — batch invoice generation + finalization
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct BatchBillingRequest {
    pub month: String,
}

#[derive(Debug, Serialize)]
pub struct BatchBillingResult {
    pub customer_id: Uuid,
    pub status: String,
    pub invoice_id: Option<Uuid>,
    pub reason: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct BatchBillingResponse {
    pub month: String,
    pub invoices_created: usize,
    pub invoices_skipped: usize,
    pub results: Vec<BatchBillingResult>,
}

#[derive(Debug, Serialize)]
pub struct BillingStatusTotal {
    pub total_cents: i64,
    pub count: usize,
}

#[derive(Debug, Serialize)]
pub struct BillingMonthBucket {
    pub month: String,
    pub paid_total_cents: i64,
}

#[derive(Debug, Serialize)]
pub struct AdminBillingInvoiceRow {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub customer_name: String,
    pub customer_email: String,
    pub period_start: chrono::NaiveDate,
    pub period_end: chrono::NaiveDate,
    pub subtotal_cents: i64,
    pub tax_cents: i64,
    pub total_cents: i64,
    pub currency: String,
    pub status: String,
    pub minimum_applied: bool,
    pub stripe_invoice_id: Option<String>,
    pub hosted_invoice_url: Option<String>,
    pub pdf_url: Option<String>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub finalized_at: Option<chrono::DateTime<chrono::Utc>>,
    pub paid_at: Option<chrono::DateTime<chrono::Utc>>,
}

#[derive(Debug, Serialize)]
pub struct AdminBillingSummaryResponse {
    pub status_totals: BTreeMap<String, BillingStatusTotal>,
    pub pending_total_cents: i64,
    pub pending_count: usize,
    pub total_count: usize,
    pub by_month: Vec<BillingMonthBucket>,
    pub mrr_proxy_cents: i64,
    pub invoices: Vec<AdminBillingInvoiceRow>,
}

const ADMIN_BILLING_STATUSES: [&str; 5] = ["paid", "draft", "finalized", "failed", "refunded"];

fn empty_status_totals() -> BTreeMap<String, BillingStatusTotal> {
    ADMIN_BILLING_STATUSES
        .iter()
        .map(|status| {
            (
                (*status).to_string(),
                BillingStatusTotal {
                    total_cents: 0,
                    count: 0,
                },
            )
        })
        .collect()
}

fn checked_revenue_sum(current: i64, addition: i64) -> Result<i64, ApiError> {
    current
        .checked_add(addition)
        .ok_or_else(|| ApiError::Internal("admin billing summary cents overflow".into()))
}

pub fn checked_revenue_product(amount_cents: i64, count: i64) -> Result<i64, ApiError> {
    amount_cents
        .checked_mul(count)
        .ok_or_else(|| ApiError::Internal("admin billing summary MRR overflow".into()))
}

fn add_status_total(
    totals: &mut BTreeMap<String, BillingStatusTotal>,
    status: &str,
    amount_cents: i64,
) -> Result<(), ApiError> {
    let total = totals
        .get_mut(status)
        .ok_or_else(|| ApiError::Internal(format!("unknown persisted invoice status: {status}")))?;
    total.total_cents = checked_revenue_sum(total.total_cents, amount_cents)?;
    total.count += 1;
    Ok(())
}

fn invoice_summary_response_row(row: &AdminInvoiceSummaryRow) -> AdminBillingInvoiceRow {
    AdminBillingInvoiceRow {
        id: row.id,
        customer_id: row.customer_id,
        customer_name: row.customer_name.clone(),
        customer_email: row.customer_email.clone(),
        period_start: row.period_start,
        period_end: row.period_end,
        subtotal_cents: row.subtotal_cents,
        tax_cents: row.tax_cents,
        total_cents: row.total_cents,
        currency: row.currency.clone(),
        status: row.status.clone(),
        minimum_applied: row.minimum_applied,
        stripe_invoice_id: row.stripe_invoice_id.clone(),
        hosted_invoice_url: row.hosted_invoice_url.clone(),
        pdf_url: row.pdf_url.clone(),
        created_at: row.created_at,
        finalized_at: row.finalized_at,
        paid_at: row.paid_at,
    }
}

pub fn summarize_billing_rows(
    rows: &[AdminInvoiceSummaryRow],
) -> Result<AdminBillingSummaryResponse, ApiError> {
    let mut status_totals = empty_status_totals();
    let mut pending_total_cents = 0;
    let mut pending_count = 0;
    let mut month_totals: BTreeMap<String, i64> = BTreeMap::new();

    for row in rows {
        add_status_total(&mut status_totals, &row.status, row.total_cents)?;

        if row.status == "draft" || row.status == "finalized" {
            pending_total_cents = checked_revenue_sum(pending_total_cents, row.total_cents)?;
            pending_count += 1;
        }

        if row.status == "paid" {
            let month = row.period_start.format("%Y-%m").to_string();
            let total = month_totals.entry(month).or_insert(0);
            *total = checked_revenue_sum(*total, row.total_cents)?;
        }
    }

    let by_month = month_totals
        .into_iter()
        .map(|(month, paid_total_cents)| BillingMonthBucket {
            month,
            paid_total_cents,
        })
        .collect();

    Ok(AdminBillingSummaryResponse {
        status_totals,
        pending_total_cents,
        pending_count,
        total_count: rows.len(),
        by_month,
        mrr_proxy_cents: 0,
        invoices: rows.iter().map(invoice_summary_response_row).collect(),
    })
}

pub async fn billing_summary(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let rows = state.invoice_repo.revenue_summary().await?;
    let mut response = summarize_billing_rows(&rows)?;
    let customers = state.customer_repo.list().await?;
    let rate_card = state
        .rate_card_repo
        .get_active()
        .await?
        .ok_or_else(|| ApiError::NotFound("no active rate card".into()))?;

    let active_shared_count = customers
        .iter()
        .filter(|customer| {
            customer.status == "active"
                && customer.billing_plan_for_billing() == crate::models::BillingPlan::Shared
        })
        .count();
    let active_shared_count = i64::try_from(active_shared_count)
        .map_err(|_| ApiError::Internal("active shared customer count overflow".into()))?;
    // Recurring floor is enforced in infra/api/src/invoicing.rs and infra/api/src/invoicing/line_items.rs.
    response.mrr_proxy_cents =
        checked_revenue_product(rate_card.shared_minimum_spend_cents, active_shared_count)?;

    Ok(Json(response))
}

fn build_new_invoice(customer_id: Uuid, generated: &GeneratedInvoice) -> NewInvoice {
    NewInvoice {
        customer_id,
        period_start: generated.period_start,
        period_end: generated.period_end,
        subtotal_cents: generated.subtotal_cents,
        total_cents: generated.total_cents,
        minimum_applied: generated.minimum_applied,
    }
}

fn batch_result(
    customer_id: Uuid,
    status: &str,
    invoice_id: Option<Uuid>,
    reason: Option<String>,
) -> BatchBillingResult {
    BatchBillingResult {
        customer_id,
        status: status.to_string(),
        invoice_id,
        reason,
    }
}

pub async fn run_batch_billing(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<BatchBillingRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let (start, end) = parse_month(&req.month)?;

    let base_card = state
        .rate_card_repo
        .get_active()
        .await?
        .ok_or_else(|| ApiError::NotFound("no active rate card".into()))?;
    let cold_snapshots = state
        .cold_snapshot_repo
        .list_completed_for_billing(start, end)
        .await?;
    let storage_buckets = state.storage_bucket_repo.list_all().await?;

    let repos = crate::invoicing::BillingRepos::from_state(&state);
    let shared = crate::invoicing::SharedBillingData {
        base_card: &base_card,
        cold_snapshots: &cold_snapshots,
        storage_buckets: &storage_buckets,
    };

    let customers = state.customer_repo.list().await?;

    let mut results = Vec::new();
    let mut created = 0usize;
    let mut skipped = 0usize;

    for customer in customers {
        if customer.status != "active" {
            skipped += 1;
            results.push(batch_result(
                customer.id,
                "skipped",
                None,
                Some(format!("customer_{}", customer.status)),
            ));
            continue;
        }

        if customer.billing_plan_for_billing() == crate::models::BillingPlan::Free {
            skipped += 1;
            results.push(batch_result(
                customer.id,
                "skipped",
                None,
                Some("free_plan".to_string()),
            ));
            continue;
        }

        let stripe_customer_id = match &customer.stripe_customer_id {
            Some(id) => id.clone(),
            None => {
                skipped += 1;
                results.push(batch_result(
                    customer.id,
                    "skipped",
                    None,
                    Some("no_stripe_account".to_string()),
                ));
                continue;
            }
        };

        let generated = crate::invoicing::compute_invoice_for_customer_with_shared_inputs(
            &repos,
            &shared,
            customer.id,
            start,
            end,
            customer.billing_plan_for_billing(),
            customer.object_storage_egress_carryforward_cents,
        )
        .await?;

        let invoice = match state
            .invoice_repo
            .create_with_line_items(
                build_new_invoice(customer.id, &generated),
                generated.line_items,
            )
            .await
        {
            Ok((inv, _items)) => inv,
            Err(RepoError::Conflict(_)) => {
                skipped += 1;
                results.push(batch_result(
                    customer.id,
                    "skipped",
                    None,
                    Some("already_invoiced".to_string()),
                ));
                continue;
            }
            Err(e) => return Err(e.into()),
        };

        match send_to_stripe_and_finalize(&state, invoice.id, &stripe_customer_id).await {
            Ok(final_invoice) => {
                send_invoice_ready_email_best_effort(
                    &state,
                    &customer.email,
                    invoice.id,
                    final_invoice.hosted_invoice_url.as_deref(),
                    final_invoice.pdf_url.as_deref(),
                    "admin_billing_run",
                )
                .await;

                created += 1;
                results.push(batch_result(customer.id, "created", Some(invoice.id), None));
            }
            Err(e) => {
                // Invoice remains as draft in DB — admin can retry manually
                tracing::error!(
                    "batch billing: stripe finalization failed for customer {}: {:?}",
                    customer.id,
                    e
                );
                skipped += 1;
                results.push(batch_result(
                    customer.id,
                    "failed",
                    Some(invoice.id),
                    Some(format!("stripe_error: {:?}", e)),
                ));
            }
        }
    }

    Ok(Json(BatchBillingResponse {
        month: req.month,
        invoices_created: created,
        invoices_skipped: skipped,
        results,
    }))
}
