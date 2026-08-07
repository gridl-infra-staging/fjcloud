use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use std::str::FromStr;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::models::{BillingPlan, Customer, InvoiceRow};
use crate::repos::usage_repo::UsageSummary;
use crate::repos::{
    AdminCustomerListQuery, AdminCustomerStatus, CustomerHardDeleteAuditPolicy,
    CustomerHardDeleteKind, CustomerHardDeleteOutcome,
};
use crate::routes::invoices::InvoiceListItem;
use crate::services::audit_log::{
    list_audit_log_for_target_tenant, write_audit_log, AuditEntry, AuditLogRow,
    ACTION_CUSTOMER_REACTIVATED, ACTION_CUSTOMER_SUSPENDED, ACTION_STRIPE_SYNC,
    ACTION_TENANT_CREATED, ACTION_TENANT_DELETED, ACTION_TENANT_UPDATED,
};
use crate::services::billing_health::{self, BillingHealth, BillingHealthSignals, InvoiceSignals};
use crate::state::AppState;
use crate::validation::{validate_email, validate_length, MAX_NAME_LEN};

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateTenantRequest {
    pub name: String,
    pub email: String,
}

#[derive(Debug, Deserialize)]
pub struct UpdateTenantRequest {
    pub name: Option<String>,
    pub email: Option<String>,
    pub billing_plan: Option<String>,
}

const ADMIN_TENANT_LIST_MAX_LIMIT: i64 = 100;

#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
pub struct AdminTenantListQuery {
    pub limit: Option<i64>,
    pub offset: Option<i64>,
    #[schema(value_type = Option<AdminCustomerStatus>)]
    pub status: Option<String>,
}

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct TenantResponse {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub status: String,
    pub billing_plan: String,
    pub index_count: i64,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub overdue_invoice_count: i64,
    pub billing_health: BillingHealth,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Serialize)]
pub struct CustomerSnapshotResponse {
    pub usage_summary: UsageSummary,
    pub open_invoices: Vec<InvoiceListItem>,
    pub recent_audit: Vec<AuditLogRow>,
}

/// Pure synchronous builder: combine a `Customer` with already-known invoice
/// signals into a `TenantResponse`. Cannot fail. SSOT for tenant
/// serialization across all admin tenant handlers.
fn tenant_response_from_signals(
    customer: Customer,
    invoice_signals: InvoiceSignals,
    index_count: i64,
) -> TenantResponse {
    let signals = BillingHealthSignals {
        overdue_invoice_count: customer.overdue_invoice_count,
        has_ever_been_billed: invoice_signals.has_ever_been_billed,
        recent_paid_invoice_within_60_days: invoice_signals.recent_paid_invoice_within_60_days,
    };

    let billing_plan = customer.billing_plan_enum().to_string();
    let billing_health = billing_health::derive(&customer.status, &signals);

    TenantResponse {
        id: customer.id,
        name: customer.name,
        email: customer.email,
        status: customer.status,
        billing_plan,
        index_count,
        last_accessed_at: customer.last_accessed_at,
        overdue_invoice_count: customer.overdue_invoice_count,
        billing_health,
        created_at: customer.created_at,
        updated_at: customer.updated_at,
    }
}

/// Fetch invoice-derived billing-health signals for a customer.
///
/// Deleted customers short-circuit to `InvoiceSignals::default()` because
/// `derive` always classifies them as `Grey` regardless of invoice state, so
/// the DB read would be wasted work.
///
/// Write handlers must call this BEFORE mutating the customer so a
/// repo-read failure cannot turn a successful write into an error response.
async fn fetch_invoice_signals(
    state: &AppState,
    customer_id: Uuid,
    customer_status: &str,
) -> Result<InvoiceSignals, ApiError> {
    if billing_health::skips_invoice_signals(customer_status) {
        return Ok(InvoiceSignals::default());
    }
    let signals = billing_health::invoice_signals_for_customer(
        state.invoice_repo.as_ref(),
        customer_id,
        Utc::now(),
    )
    .await?;
    Ok(signals)
}

fn validated_tenant_name(name: &str) -> Result<&str, ApiError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(ApiError::BadRequest("name must not be empty".into()));
    }

    validate_length("name", trimmed, MAX_NAME_LEN)?;
    Ok(trimmed)
}

fn normalized_tenant_email(email: &str) -> Result<String, ApiError> {
    let normalized = email.trim().to_lowercase();
    validate_email(&normalized)?;
    Ok(normalized)
}

fn message_response(message: &str) -> Json<Value> {
    Json(json!({ "message": message }))
}

fn update_tenant_changed_fields(req: &UpdateTenantRequest) -> Vec<&'static str> {
    let mut changed = Vec::with_capacity(3);
    if req.name.is_some() {
        changed.push("name");
    }
    if req.email.is_some() {
        changed.push("email");
    }
    if req.billing_plan.is_some() {
        changed.push("billing_plan");
    }
    changed
}

/// Open invoices are every lifecycle state except closed settlement states.
fn is_open_invoice_status(status: &str) -> bool {
    !matches!(status, "paid" | "refunded")
}

fn open_invoices_for_snapshot(invoices: &[InvoiceRow]) -> Vec<InvoiceListItem> {
    invoices
        .iter()
        .filter(|invoice| is_open_invoice_status(&invoice.status))
        .map(InvoiceListItem::from)
        .collect()
}

fn parse_tenant_list_query(
    query: AdminTenantListQuery,
) -> Result<AdminCustomerListQuery, ApiError> {
    let limit = match query.limit {
        None => None,
        Some(value) if (1..=ADMIN_TENANT_LIST_MAX_LIMIT).contains(&value) => Some(value),
        Some(_) => {
            return Err(ApiError::BadRequest(format!(
                "limit must be between 1 and {ADMIN_TENANT_LIST_MAX_LIMIT}"
            )));
        }
    };
    let offset = match query.offset {
        None => None,
        Some(value) if value >= 0 => Some(value),
        Some(_) => {
            return Err(ApiError::BadRequest(
                "offset must be a non-negative integer".into(),
            ));
        }
    };
    let status = query
        .status
        .as_deref()
        .map(|value| {
            AdminCustomerStatus::from_str(value).map_err(|_| {
                ApiError::BadRequest(format!(
                    "invalid status '{}'; expected one of: {}",
                    value,
                    AdminCustomerStatus::VALUES.join(", ")
                ))
            })
        })
        .transpose()?;

    Ok(AdminCustomerListQuery {
        status,
        limit,
        offset,
    })
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `POST /admin/tenants` — create a new tenant (customer).
///
/// **Auth:** `AdminAuth`.
/// Validates `name` (trimmed, non-empty, max `MAX_NAME_LEN`) and `email`
/// (trimmed, lowercased, format-validated). Creates the customer record and
/// returns 201 with the tenant response.
pub async fn create_tenant(
    auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<CreateTenantRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let name = validated_tenant_name(&req.name)?;
    let email = normalized_tenant_email(&req.email)?;

    let customer = state.customer_repo.create(name, &email).await?;

    if let Err(err) = write_audit_log(
        &state.pool,
        auth.operator_id,
        ACTION_TENANT_CREATED,
        Some(customer.id),
        json!({
            "tenant_id": customer.id,
            "name": &customer.name,
            "email": &customer.email
        }),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %customer.id,
            "failed to write tenant_created audit_log row"
        );
    }

    // A freshly created customer has no invoices yet, so default signals are
    // accurate here AND avoid adding a fallible repo read after the
    // create has already committed.
    let response = tenant_response_from_signals(customer, InvoiceSignals::default(), 0);
    Ok((StatusCode::CREATED, Json(response)))
}

#[utoipa::path(
    get,
    path = "/admin/tenants",
    params(
        ("limit" = Option<i64>, Query, description = "Maximum tenants to return. Must be between 1 and 100."),
        ("offset" = Option<i64>, Query, description = "Number of tenants to skip. Must be non-negative."),
        ("status" = Option<AdminCustomerStatus>, Query, description = "Optional customer status filter.")
    ),
    responses(
        (status = 200, description = "Admin tenant list", body = [TenantResponse]),
        (status = 400, description = "Invalid pagination or status filter", body = crate::errors::ErrorResponse),
        (status = 401, description = "Missing or invalid admin credential", body = crate::errors::ErrorResponse)
    ),
    security(("bearer_jwt" = []))
)]
pub async fn list_tenants(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Query(query): Query<AdminTenantListQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let customers = state
        .customer_repo
        .list_admin(parse_tenant_list_query(query)?)
        .await?;

    // Batched fan-out avoidance: the staging customers table is ~10,574 rows,
    // so the old per-row loop (`1 + 2N` reads) issued ~21k queries. Instead we
    // issue exactly three reads regardless of N — one customer list plus one
    // batched invoice-signal fetch plus one batched index-count fetch — and
    // join the results back in memory below.
    let all_customer_ids: Vec<Uuid> = customers.iter().map(|customer| customer.id).collect();
    // Customers whose billing health ignores invoice history stay on default
    // signals and are excluded from the invoice batch.
    let non_deleted_customer_ids: Vec<Uuid> = customers
        .iter()
        .filter(|customer| !billing_health::skips_invoice_signals(&customer.status))
        .map(|customer| customer.id)
        .collect();

    let signals_by_customer = billing_health::invoice_signals_for_customers(
        state.invoice_repo.as_ref(),
        &non_deleted_customer_ids,
        Utc::now(),
    )
    .await?;
    let index_counts = state
        .tenant_repo
        .count_by_customers(&all_customer_ids)
        .await?;

    let tenants: Vec<TenantResponse> = customers
        .into_iter()
        .map(|customer| {
            let signals = signals_by_customer
                .get(&customer.id)
                .copied()
                .unwrap_or_default();
            let index_count = index_counts.get(&customer.id).copied().unwrap_or(0);
            tenant_response_from_signals(customer, signals, index_count)
        })
        .collect();
    Ok(Json(tenants))
}

/// `GET /admin/tenants/{id}` — single-tenant detail.
///
/// This endpoint intentionally stays on the single-row calls to
/// `fetch_invoice_signals` and `count_by_customer`, rather than the batched
/// readers used by `list_tenants`. It resolves exactly one customer, so the
/// batched `= ANY($1)` forms (whose payoff is amortizing one query across the
/// ~10,574-row listing) would add slice-wrapping overhead with no fan-out to
/// avoid.
pub async fn get_tenant(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(id)
        .await?
        .ok_or_else(|| ApiError::NotFound("tenant not found".into()))?;
    let signals = fetch_invoice_signals(&state, customer.id, &customer.status).await?;
    let index_count = state.tenant_repo.count_by_customer(customer.id).await?;
    Ok(Json(tenant_response_from_signals(
        customer,
        signals,
        index_count,
    )))
}

/// `PUT /admin/tenants/{id}` — partial update of tenant fields.
///
/// **Auth:** `AdminAuth`.
/// Accepts optional `name`, `email`, and `billing_plan`. At least one field
/// must be provided. Validates `billing_plan` via `BillingPlan::from_str`;
/// name/email updates and billing plan changes are applied independently.
pub async fn update_tenant(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateTenantRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let changed = update_tenant_changed_fields(&req);

    if req.name.is_none() && req.email.is_none() && req.billing_plan.is_none() {
        return Err(ApiError::BadRequest("no fields to update".into()));
    }

    let canonical_billing_plan = req
        .billing_plan
        .as_deref()
        .map(|plan_str| {
            BillingPlan::from_str(plan_str)
                .map(|plan| plan.to_string())
                .map_err(|_| {
                    ApiError::BadRequest(format!(
                        "invalid billing_plan '{}'; expected one of: free, shared",
                        plan_str
                    ))
                })
        })
        .transpose()?;

    let name = match req.name {
        Some(name) => Some(validated_tenant_name(&name)?.to_string()),
        None => None,
    };

    let email = match req.email {
        Some(email) => Some(normalized_tenant_email(&email)?),
        None => None,
    };

    let existing_customer = state
        .customer_repo
        .find_by_id(id)
        .await?
        .filter(|customer| customer.status != "deleted")
        .ok_or_else(|| ApiError::NotFound("tenant not found".into()))?;

    if let Some(new_email) = email.as_deref() {
        let conflicting_customer = state.customer_repo.find_by_email(new_email).await?;
        if conflicting_customer
            .as_ref()
            .is_some_and(|customer| customer.id != existing_customer.id)
        {
            return Err(ApiError::Conflict("email already exists".into()));
        }
    }

    // Resolve invoice signals only after proving the tenant exists and is
    // not deleted so update keeps the historical 404 precedence for missing/
    // deleted tenants. The lookup still runs before mutation to prevent
    // post-write failures from turning a committed update into an error.
    let invoice_signals =
        fetch_invoice_signals(&state, existing_customer.id, &existing_customer.status).await?;
    let index_count = state
        .tenant_repo
        .count_by_customer(existing_customer.id)
        .await?;

    let mut customer = if name.is_some() || email.is_some() {
        state
            .customer_repo
            .update(id, name.as_deref(), email.as_deref())
            .await?
            .ok_or_else(|| ApiError::NotFound("tenant not found".into()))?
    } else {
        existing_customer
    };

    if let Some(ref plan_str) = canonical_billing_plan {
        state.customer_repo.set_billing_plan(id, plan_str).await?;
        customer.billing_plan = plan_str.clone();
    }

    if let Err(err) = write_audit_log(
        &state.pool,
        auth.operator_id,
        ACTION_TENANT_UPDATED,
        Some(id),
        json!({ "changed": changed }),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %id,
            "failed to write tenant_updated audit_log row"
        );
    }

    Ok(Json(tenant_response_from_signals(
        customer,
        invoice_signals,
        index_count,
    )))
}

pub async fn delete_tenant(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let deleted = state.customer_repo.soft_delete(id).await?;
    if deleted {
        if let Err(err) = write_audit_log(
            &state.pool,
            auth.operator_id,
            ACTION_TENANT_DELETED,
            Some(id),
            json!({}),
        )
        .await
        {
            tracing::error!(
                error = %err,
                customer_id = %id,
                "failed to write tenant_deleted audit_log row"
            );
        }

        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound("tenant not found".into()))
    }
}

// POST /admin/customers/:id/sync-stripe
/// `POST /admin/customers/{id}/sync-stripe` — link customer to Stripe.
///
/// **Auth:** `AdminAuth`.
/// If the customer already has a `stripe_customer_id`, returns the existing
/// link. Otherwise creates a new Stripe customer and persists the ID.
pub async fn sync_stripe(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    if customer.stripe_customer_id.is_some() {
        return Ok(Json(json!({
            "message": "customer already linked to stripe",
            "stripe_customer_id": customer.stripe_customer_id
        })));
    }

    let stripe_id = state
        .stripe_service
        .create_customer(&customer.name, &customer.email)
        .await
        .map_err(|e| ApiError::Internal(format!("stripe error: {e}")))?;

    state
        .customer_repo
        .set_stripe_customer_id(customer_id, &stripe_id)
        .await?;

    if let Err(err) = write_audit_log(
        &state.pool,
        auth.operator_id,
        ACTION_STRIPE_SYNC,
        Some(customer_id),
        json!({ "stripe_customer_id": &stripe_id }),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %customer_id,
            "failed to write stripe_sync audit_log row"
        );
    }

    Ok(Json(json!({
        "message": "stripe customer created and linked",
        "stripe_customer_id": stripe_id
    })))
}

// POST /admin/customers/:id/reactivate
/// `POST /admin/customers/{id}/reactivate` — reactivate a suspended customer.
///
/// **Auth:** `AdminAuth`.
/// Requires the customer to be in `suspended` status; returns 400 otherwise.
pub async fn reactivate_customer(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    if customer.status != "suspended" {
        return Err(ApiError::BadRequest("customer is not suspended".into()));
    }

    state.customer_repo.reactivate(customer_id).await?;

    if let Err(err) = write_audit_log(
        &state.pool,
        auth.operator_id,
        ACTION_CUSTOMER_REACTIVATED,
        Some(customer_id),
        json!({}),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %customer_id,
            "failed to write customer_reactivated audit_log row"
        );
    }

    Ok(message_response("customer reactivated"))
}

// POST /admin/customers/:id/suspend
/// `POST /admin/customers/{id}/suspend` — suspend an active customer.
///
/// **Auth:** `AdminAuth`.
/// Requires the customer to be in `active` status; returns 400 otherwise.
pub async fn suspend_customer(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let customer = state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    if customer.status != "active" {
        return Err(ApiError::BadRequest("customer is not active".into()));
    }

    let audit_entry = AuditEntry {
        actor_id: auth.operator_id,
        action: ACTION_CUSTOMER_SUSPENDED.to_owned(),
        target_tenant_id: Some(customer_id),
        metadata: json!({}),
    };
    state
        .customer_repo
        .suspend(customer_id, audit_entry)
        .await?;

    Ok(message_response("customer suspended"))
}

// POST /admin/customers/:id/hard-erase
/// `POST /admin/customers/{id}/hard-erase` — permanently erase a previously
/// soft-deleted customer and all dependent rows.
///
/// **Auth:** `AdminAuth`.
///
/// **Preconditions:** the customer must already be in `deleted` status —
/// active/suspended customers must be soft-deleted (and any unfinished
/// billing wound down) before hard-erasure is allowed. The repo seam
/// additionally rejects with `409 Conflict` if any non-final invoice rows
/// still reference the customer.
///
/// **Responses:**
/// * `204 No Content` — erasure succeeded; customer PII and dependents were
///   removed while opaque Algolia reconciliation tombstones were retained.
///   A target-free `customer_hard_erase` audit receipt commits in the same
///   transaction; an audit-write failure rolls the erasure back.
/// * `404 Not Found` — no `customers` row matched (already erased).
/// * `400 Bad Request` — customer is not in `deleted` status.
/// * `409 Conflict` — customer still has open invoices.
pub async fn hard_erase_customer(
    auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    match state
        .customer_repo
        .hard_delete(
            customer_id,
            CustomerHardDeleteKind::PrivacyErasure,
            CustomerHardDeleteAuditPolicy::Required {
                operator_id: auth.operator_id,
            },
        )
        .await?
    {
        CustomerHardDeleteOutcome::Erased { .. } => {}
        CustomerHardDeleteOutcome::NotFound => {
            return Err(ApiError::NotFound("customer not found".into()));
        }
        CustomerHardDeleteOutcome::NotSoftDeleted => {
            return Err(ApiError::BadRequest(
                "customer must be soft-deleted before hard-erase".into(),
            ));
        }
    }

    Ok(StatusCode::NO_CONTENT)
}

// GET /admin/customers/:id/audit
/// `GET /admin/customers/{id}/audit` — read audit-log rows for one customer.
///
/// **Auth:** `AdminAuth`.
/// Returns up to the newest 100 rows for the requested customer, newest-first.
pub async fn get_customer_audit(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    let rows: Vec<AuditLogRow> = list_audit_log_for_target_tenant(&state.pool, customer_id)
        .await
        .map_err(|err| ApiError::Internal(format!("failed to read customer audit log: {err}")))?;
    Ok(Json(rows))
}

/// `GET /admin/customers/{id}/snapshot` — recent usage, open invoices, and audit rows.
pub async fn get_customer_snapshot(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .customer_repo
        .find_by_id(customer_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("customer not found".into()))?;

    let usage_summary: UsageSummary = state.usage_repo.summary_for(customer_id, 7).await?;
    let invoices = state.invoice_repo.list_by_customer(customer_id).await?;
    let open_invoices = open_invoices_for_snapshot(&invoices);
    let recent_audit: Vec<AuditLogRow> = list_audit_log_for_target_tenant(&state.pool, customer_id)
        .await
        .map_err(|err| {
            ApiError::Internal(format!(
                "failed to read customer audit log for snapshot: {err}"
            ))
        })?;

    Ok(Json(CustomerSnapshotResponse {
        usage_summary,
        open_invoices,
        recent_audit,
    }))
}
