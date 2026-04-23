use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::invoicing::stripe_sync::{
    send_invoice_ready_email_best_effort, send_to_stripe_and_finalize,
};
use crate::invoicing::GeneratedInvoice;
use crate::repos::error::RepoError;
use crate::repos::invoice_repo::NewInvoice;
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
        customer.billing_plan_enum(),
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
        // Only bill active customers — skip suspended (payment issues)
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
            customer.billing_plan_enum(),
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
