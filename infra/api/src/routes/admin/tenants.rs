//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar23_pm_2_admin_ui_enhancements/fjcloud_dev/infra/api/src/routes/admin/tenants.rs.
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
use crate::models::{BillingPlan, Customer};
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

impl From<Customer> for TenantResponse {
    fn from(c: Customer) -> Self {
        let billing_plan = c.billing_plan_enum().to_string();
        Self {
            id: c.id,
            name: c.name,
            email: c.email,
            status: c.status,
            billing_plan,
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

    Ok(Json(TenantResponse::from(customer)))
}

pub async fn delete_tenant(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let deleted = state.customer_repo.soft_delete(id).await?;
    if deleted {
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

    Ok(message_response("customer suspended"))
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
