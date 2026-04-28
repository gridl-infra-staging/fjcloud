use axum::extract::{Path, State};
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
use crate::routes::invoices::InvoiceListItem;
use crate::services::audit_log::{
    list_audit_log_for_target_tenant, write_audit_log, AuditLogRow, ACTION_CUSTOMER_REACTIVATED,
    ACTION_CUSTOMER_SUSPENDED, ACTION_QUOTAS_UPDATED, ACTION_STRIPE_SYNC, ACTION_TENANT_CREATED,
    ACTION_TENANT_DELETED, ACTION_TENANT_UPDATED, ADMIN_SENTINEL_ACTOR_ID,
};
use crate::services::billing_health::{self, BillingHealth};
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

#[derive(Debug, Serialize)]
pub struct TenantResponse {
    pub id: Uuid,
    pub name: String,
    pub email: String,
    pub status: String,
    pub billing_plan: String,
    pub last_accessed_at: Option<DateTime<Utc>>,
    pub subscription_status: Option<String>,
    pub overdue_invoice_count: i64,
    pub billing_health: BillingHealth,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Deserialize)]
pub struct UpdateTenantQuotasRequest {
    pub max_query_rps: Option<u32>,
    pub max_write_rps: Option<u32>,
    pub max_storage_bytes: Option<u64>,
    pub max_indexes: Option<u32>,
}

#[derive(Debug, Serialize)]
pub struct QuotaValues {
    pub max_query_rps: u32,
    pub max_write_rps: u32,
    pub max_storage_bytes: u64,
    pub max_indexes: u32,
}

#[derive(Debug, Serialize)]
pub struct TenantIndexQuota {
    pub index_name: String,
    pub effective: QuotaValues,
    #[serde(rename = "override")]
    pub override_quota: Value,
}

#[derive(Debug, Serialize)]
pub struct TenantQuotasResponse {
    pub defaults: QuotaValues,
    pub indexes: Vec<TenantIndexQuota>,
}

#[derive(Debug, Serialize)]
pub struct CustomerSnapshotResponse {
    pub usage_summary: UsageSummary,
    pub open_invoices: Vec<InvoiceListItem>,
    pub recent_audit: Vec<AuditLogRow>,
}

impl From<Customer> for TenantResponse {
    fn from(c: Customer) -> Self {
        let billing_plan = c.billing_plan_enum().to_string();
        let billing_health = billing_health::derive(
            &c.status,
            c.subscription_status.as_deref(),
            c.overdue_invoice_count,
        );
        Self {
            id: c.id,
            name: c.name,
            email: c.email,
            status: c.status,
            billing_plan,
            last_accessed_at: c.last_accessed_at,
            subscription_status: c.subscription_status,
            overdue_invoice_count: c.overdue_invoice_count,
            billing_health,
            created_at: c.created_at,
            updated_at: c.updated_at,
        }
    }
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

fn quota_values(
    max_query_rps: u32,
    max_write_rps: u32,
    max_storage_bytes: u64,
    max_indexes: u32,
) -> QuotaValues {
    QuotaValues {
        max_query_rps,
        max_write_rps,
        max_storage_bytes,
        max_indexes,
    }
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
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(req): Json<CreateTenantRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let name = validated_tenant_name(&req.name)?;
    let email = normalized_tenant_email(&req.email)?;

    let customer = state.customer_repo.create(name, &email).await?;

    if let Err(err) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
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

    Ok((StatusCode::CREATED, Json(TenantResponse::from(customer))))
}

pub async fn list_tenants(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let customers = state.customer_repo.list().await?;
    let tenants: Vec<TenantResponse> = customers.into_iter().map(TenantResponse::from).collect();
    Ok(Json(tenants))
}

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
    Ok(Json(TenantResponse::from(customer)))
}

/// `PUT /admin/tenants/{id}` — partial update of tenant fields.
///
/// **Auth:** `AdminAuth`.
/// Accepts optional `name`, `email`, and `billing_plan`. At least one field
/// must be provided. Validates `billing_plan` via `BillingPlan::from_str`;
/// name/email updates and billing plan changes are applied independently.
pub async fn update_tenant(
    _auth: AdminAuth,
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

    let mut customer = if name.is_some() || email.is_some() {
        state
            .customer_repo
            .update(id, name.as_deref(), email.as_deref())
            .await?
            .ok_or_else(|| ApiError::NotFound("tenant not found".into()))?
    } else {
        state
            .customer_repo
            .find_by_id(id)
            .await?
            .filter(|c| c.status != "deleted")
            .ok_or_else(|| ApiError::NotFound("tenant not found".into()))?
    };

    if let Some(ref plan_str) = canonical_billing_plan {
        state.customer_repo.set_billing_plan(id, plan_str).await?;
        customer.billing_plan = plan_str.clone();
    }

    if let Err(err) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
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

    Ok(Json(TenantResponse::from(customer)))
}

pub async fn delete_tenant(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let deleted = state.customer_repo.soft_delete(id).await?;
    if deleted {
        if let Err(err) = write_audit_log(
            &state.pool,
            ADMIN_SENTINEL_ACTOR_ID,
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
    _auth: AdminAuth,
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
        ADMIN_SENTINEL_ACTOR_ID,
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
    _auth: AdminAuth,
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
        ADMIN_SENTINEL_ACTOR_ID,
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
    _auth: AdminAuth,
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

    state.customer_repo.suspend(customer_id).await?;

    if let Err(err) = write_audit_log(
        &state.pool,
        ADMIN_SENTINEL_ACTOR_ID,
        ACTION_CUSTOMER_SUSPENDED,
        Some(customer_id),
        json!({}),
    )
    .await
    {
        tracing::error!(
            error = %err,
            customer_id = %customer_id,
            "failed to write customer_suspended audit_log row"
        );
    }

    Ok(message_response("customer suspended"))
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

pub async fn get_quotas(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let response = quotas_response(&state, customer_id).await?;
    Ok(Json(response))
}

/// `PUT /admin/tenants/{id}/quotas` — update quotas for all tenant indexes.
///
/// **Auth:** `AdminAuth`.
/// Applies the partial quota update to every index (tenant) owned by the
/// customer, then invalidates the in-memory quota cache for each. Returns
/// the full quotas response (defaults + per-index effective values).
pub async fn update_quotas(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(req): Json<UpdateTenantQuotasRequest>,
) -> Result<impl IntoResponse, ApiError> {
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let update_payload = quota_update_payload(&req)?;
    let mut quota_keys = update_payload
        .as_object()
        .map(|map| map.keys().cloned().collect::<Vec<_>>())
        .unwrap_or_default();
    quota_keys.sort();

    let tenants = state.tenant_repo.list_raw_by_customer(customer_id).await?;
    for tenant in &tenants {
        state
            .tenant_repo
            .set_resource_quota(customer_id, &tenant.tenant_id, update_payload.clone())
            .await?;
        state
            .tenant_quota_service
            .invalidate_quota(customer_id, &tenant.tenant_id);
    }

    if !tenants.is_empty() {
        if let Err(err) = write_audit_log(
            &state.pool,
            ADMIN_SENTINEL_ACTOR_ID,
            ACTION_QUOTAS_UPDATED,
            Some(customer_id),
            json!({ "quota_keys": quota_keys }),
        )
        .await
        {
            tracing::error!(
                error = %err,
                customer_id = %customer_id,
                "failed to write quotas_updated audit_log row"
            );
        }
    }

    let response = quotas_response(&state, customer_id).await?;
    Ok(Json(response))
}

/// Validate quota fields and build a partial JSON update object.
///
/// At least one field must be provided; all provided values must be > 0.
/// Returns a `serde_json::Value::Object` containing only the fields to update.
fn quota_update_payload(req: &UpdateTenantQuotasRequest) -> Result<Value, ApiError> {
    if req.max_query_rps.is_none()
        && req.max_write_rps.is_none()
        && req.max_storage_bytes.is_none()
        && req.max_indexes.is_none()
    {
        return Err(ApiError::BadRequest("no fields to update".into()));
    }

    if req.max_query_rps.is_some_and(|v| v == 0) {
        return Err(ApiError::BadRequest(
            "max_query_rps must be greater than 0".into(),
        ));
    }
    if req.max_write_rps.is_some_and(|v| v == 0) {
        return Err(ApiError::BadRequest(
            "max_write_rps must be greater than 0".into(),
        ));
    }
    if req.max_storage_bytes.is_some_and(|v| v == 0) {
        return Err(ApiError::BadRequest(
            "max_storage_bytes must be greater than 0".into(),
        ));
    }
    if req.max_indexes.is_some_and(|v| v == 0) {
        return Err(ApiError::BadRequest(
            "max_indexes must be greater than 0".into(),
        ));
    }

    let mut map = serde_json::Map::new();
    if let Some(v) = req.max_query_rps {
        map.insert("max_query_rps".into(), json!(v));
    }
    if let Some(v) = req.max_write_rps {
        map.insert("max_write_rps".into(), json!(v));
    }
    if let Some(v) = req.max_storage_bytes {
        map.insert("max_storage_bytes".into(), json!(v));
    }
    if let Some(v) = req.max_indexes {
        map.insert("max_indexes".into(), json!(v));
    }
    Ok(Value::Object(map))
}

/// Build the full quotas response: system defaults plus per-index effective values.
///
/// Lists all tenant (index) records for the customer, resolves each index's
/// effective quota by merging overrides with defaults, and returns them sorted
/// by `index_name`.
async fn quotas_response(
    state: &AppState,
    customer_id: Uuid,
) -> Result<TenantQuotasResponse, ApiError> {
    let defaults = state.tenant_quota_service.defaults().clone();
    let tenants = state.tenant_repo.list_raw_by_customer(customer_id).await?;

    let mut indexes = tenants
        .into_iter()
        .map(|tenant| {
            let effective = state
                .tenant_quota_service
                .resolve_quota(&tenant.resource_quota);
            TenantIndexQuota {
                index_name: tenant.tenant_id,
                effective: quota_values(
                    effective.max_query_rps,
                    effective.max_write_rps,
                    effective.max_storage_bytes,
                    effective.max_indexes,
                ),
                override_quota: tenant.resource_quota,
            }
        })
        .collect::<Vec<_>>();

    indexes.sort_by(|a, b| a.index_name.cmp(&b.index_name));

    Ok(TenantQuotasResponse {
        defaults: quota_values(
            defaults.max_query_rps,
            defaults.max_write_rps,
            defaults.max_storage_bytes,
            defaults.max_indexes,
        ),
        indexes,
    })
}
