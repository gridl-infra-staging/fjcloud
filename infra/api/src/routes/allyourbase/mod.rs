//! AYB (AllYourBase) instance management routes.
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AuthenticatedTenant;
use crate::errors::ApiError;
use crate::models::ayb_tenant::{AybTenant, AybTenantStatus, NewAybTenant};
use crate::models::PlanTier;
use crate::services::ayb_admin::{AybAdminClient, AybAdminError, CreateTenantRequest};
use crate::state::AppState;

// ---------------------------------------------------------------------------
// Response DTOs — built from local AybTenant rows, not live AYB fetches
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, utoipa::ToSchema)]
pub struct InstanceResponse {
    pub id: Uuid,
    pub ayb_slug: String,
    pub ayb_cluster_id: String,
    pub ayb_url: String,
    pub status: String,
    pub plan: String,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

impl From<AybTenant> for InstanceResponse {
    fn from(t: AybTenant) -> Self {
        Self {
            id: t.id,
            ayb_slug: t.ayb_slug,
            ayb_cluster_id: t.ayb_cluster_id,
            ayb_url: t.ayb_url,
            status: t.status,
            plan: t.plan,
            created_at: t.created_at,
            updated_at: t.updated_at,
        }
    }
}

// ---------------------------------------------------------------------------
// Request DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateAybInstanceRequest {
    pub name: String,
    pub slug: String,
    pub plan: PlanTier,
}

const EXISTING_INSTANCE_CONFLICT_ERROR: &str =
    "A database instance already exists for this account.";

/// Validated and normalized create-instance input. Single source of truth for
/// request normalization in this stage — both upstream and local writes use
/// these values.
struct ValidatedCreateInput {
    name: String,
    slug: String,
    plan: PlanTier,
}

/// Normalize and validate the raw request body. Trims `name`, rejects empty
/// `name` or `slug`, and enforces the slug rule: lowercase alphanumeric and
/// hyphens, start/end alphanumeric, length 3-63.
fn validate_create_request(
    req: CreateAybInstanceRequest,
) -> Result<ValidatedCreateInput, ApiError> {
    let name = req.name.trim().to_string();
    if name.is_empty() {
        return Err(ApiError::BadRequest("name must not be empty".into()));
    }

    let slug = &req.slug;
    if slug.len() < 3 || slug.len() > 63 {
        return Err(ApiError::BadRequest(
            "slug must be between 3 and 63 characters".into(),
        ));
    }
    let slug_bytes = slug.as_bytes();
    // Start and end must be lowercase alphanumeric.
    if !slug_bytes[0].is_ascii_lowercase() && !slug_bytes[0].is_ascii_digit() {
        return Err(ApiError::BadRequest(
            "slug must start with a lowercase letter or digit".into(),
        ));
    }
    let last = slug_bytes[slug_bytes.len() - 1];
    if !last.is_ascii_lowercase() && !last.is_ascii_digit() {
        return Err(ApiError::BadRequest(
            "slug must end with a lowercase letter or digit".into(),
        ));
    }
    // Interior chars must be lowercase alphanumeric or hyphen.
    for &b in slug_bytes {
        if !b.is_ascii_lowercase() && !b.is_ascii_digit() && b != b'-' {
            return Err(ApiError::BadRequest(
                "slug may only contain lowercase letters, digits, and hyphens".into(),
            ));
        }
    }

    Ok(ValidatedCreateInput {
        name,
        slug: req.slug,
        plan: req.plan,
    })
}

fn ensure_create_slot_available(active_instance_count: usize) -> Result<(), ApiError> {
    if active_instance_count == 0 {
        return Ok(());
    }

    Err(ApiError::Conflict(EXISTING_INSTANCE_CONFLICT_ERROR.into()))
}

// ---------------------------------------------------------------------------
// POST /allyourbase/instances
// ---------------------------------------------------------------------------

/// `POST /allyourbase/instances` — provision a new AYB database instance.
///
/// **Auth:** JWT (`AuthenticatedTenant`).
/// Validates slug format (lowercase alphanumeric + hyphens, 3-63 chars),
/// enforces a single-instance-per-customer limit, then creates the tenant
/// upstream in AYB. The local `ayb_tenants` row is persisted after the
/// upstream call succeeds; if local persistence fails, the upstream tenant
/// is deleted (best-effort) to avoid orphans.
pub async fn create_instance(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Json(body): Json<CreateAybInstanceRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let input = validate_create_request(body)?;
    let active_instance_count = state
        .ayb_tenant_repo
        .find_active_by_customer(tenant.customer_id)
        .await?
        .len();
    ensure_create_slot_available(active_instance_count)?;

    let client = state
        .ayb_admin_client
        .as_ref()
        .ok_or_else(|| ApiError::ServiceNotConfigured("allyourbase".into()))?;

    let upstream_req = CreateTenantRequest {
        name: input.name.clone(),
        slug: input.slug.clone(),
        plan_tier: input.plan,
        owner_user_id: Some(tenant.customer_id.to_string()),
        region: None,
        org_metadata: None,
        idempotency_key: None,
    };

    let response = client.create_tenant(upstream_req).await?;

    let new_tenant = NewAybTenant {
        customer_id: tenant.customer_id,
        ayb_tenant_id: response.tenant_id.clone(),
        ayb_slug: response.slug,
        ayb_cluster_id: client.cluster_id().to_string(),
        ayb_url: client.base_url().to_string(),
        status: AybTenantStatus::Provisioning,
        plan: input.plan,
    };

    let saved = match state.ayb_tenant_repo.create(new_tenant).await {
        Ok(row) => row,
        Err(repo_err) => {
            // Best-effort cleanup: delete upstream tenant so we don't leave an
            // orphan that only exists in AYB but not in our local database.
            if let Err(cleanup_err) = client.delete_tenant(&response.tenant_id).await {
                tracing::error!(
                    tenant_id = %response.tenant_id,
                    "failed to clean up upstream AYB tenant after local persist failure: {cleanup_err}"
                );
            }
            return Err(repo_err.into());
        }
    };

    Ok((StatusCode::CREATED, Json(InstanceResponse::from(saved))))
}

// ---------------------------------------------------------------------------
// GET /allyourbase/instances
// ---------------------------------------------------------------------------

/// GET /allyourbase/instances — list active AYB instances for the tenant.
#[utoipa::path(
    get,
    path = "/allyourbase/instances",
    tag = "AllYourBase",
    responses(
        (status = 200, description = "List of AYB instances", body = Vec<InstanceResponse>),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
    )
)]
pub async fn list_instances(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let tenants = state
        .ayb_tenant_repo
        .find_active_by_customer(tenant.customer_id)
        .await?;

    let response: Vec<InstanceResponse> = tenants.into_iter().map(Into::into).collect();
    Ok(Json(response))
}

// ---------------------------------------------------------------------------
// GET /allyourbase/instances/:id
// ---------------------------------------------------------------------------

/// GET /allyourbase/instances/:id — get a specific AYB instance.
#[utoipa::path(
    get,
    path = "/allyourbase/instances/{id}",
    tag = "AllYourBase",
    params(("id" = Uuid, Path, description = "Instance identifier")),
    responses(
        (status = 200, description = "AYB instance details", body = InstanceResponse),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 404, description = "Instance not found", body = crate::errors::ErrorResponse),
    )
)]
pub async fn get_instance(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let row = resolve_customer_instance(&state, tenant.customer_id, id).await?;
    Ok(Json(InstanceResponse::from(row)))
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

async fn resolve_customer_instance(
    state: &AppState,
    customer_id: Uuid,
    id: Uuid,
) -> Result<AybTenant, ApiError> {
    state
        .ayb_tenant_repo
        .find_active_by_customer_and_id(customer_id, id)
        .await?
        .ok_or_else(|| ApiError::NotFound("instance not found".into()))
}

/// Delete an AYB tenant upstream, treating "not found" as success (idempotent).
///
/// Returns `ApiError::ServiceUnavailable` when AYB is unreachable, or
/// `ApiError::Internal` for unexpected failures.
async fn delete_upstream_instance(
    client: &(dyn AybAdminClient + Send + Sync),
    ayb_tenant_id: &str,
) -> Result<(), ApiError> {
    match client.delete_tenant(ayb_tenant_id).await {
        Ok(_) | Err(AybAdminError::NotFound(_)) => Ok(()),
        Err(AybAdminError::ServiceUnavailable) => Err(ApiError::ServiceUnavailable(
            "AYB service unavailable".into(),
        )),
        Err(e) => {
            tracing::error!("AYB delete failed: {e}");
            Err(ApiError::Internal("AYB admin operation failed".into()))
        }
    }
}

// ---------------------------------------------------------------------------
// DELETE /allyourbase/instances/:id
// ---------------------------------------------------------------------------

/// DELETE /allyourbase/instances/:id — delete an AYB instance.
#[utoipa::path(
    delete,
    path = "/allyourbase/instances/{id}",
    tag = "AllYourBase",
    params(("id" = Uuid, Path, description = "Instance identifier")),
    responses(
        (status = 204, description = "Instance deleted"),
        (status = 401, description = "Authentication required", body = crate::errors::ErrorResponse),
        (status = 404, description = "Instance not found", body = crate::errors::ErrorResponse),
        (status = 503, description = "AYB service unavailable", body = crate::errors::ErrorResponse),
    )
)]
pub async fn delete_instance(
    tenant: AuthenticatedTenant,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let row = resolve_customer_instance(&state, tenant.customer_id, id).await?;

    let client = state
        .ayb_admin_client
        .as_ref()
        .ok_or_else(|| ApiError::ServiceNotConfigured("allyourbase".into()))?;

    delete_upstream_instance(client.as_ref(), &row.ayb_tenant_id).await?;

    state
        .ayb_tenant_repo
        .soft_delete_for_customer(tenant.customer_id, id)
        .await?;

    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::{ensure_create_slot_available, ApiError, EXISTING_INSTANCE_CONFLICT_ERROR};

    #[test]
    fn create_slot_is_available_without_existing_instances() {
        assert!(ensure_create_slot_available(0).is_ok());
    }

    #[test]
    fn create_slot_is_rejected_when_an_active_instance_exists() {
        match ensure_create_slot_available(1) {
            Err(ApiError::Conflict(message)) => {
                assert_eq!(message, EXISTING_INSTANCE_CONFLICT_ERROR);
            }
            other => panic!("expected conflict error, got {other:?}"),
        }
    }
}
