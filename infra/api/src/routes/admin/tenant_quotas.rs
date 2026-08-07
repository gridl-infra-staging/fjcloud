use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::services::audit_log::{write_audit_log, ACTION_QUOTAS_UPDATED};
use crate::state::AppState;

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
    auth: AdminAuth,
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
            auth.operator_id,
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
