//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/routes/admin/deployments.rs.
use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::models::Deployment;
use crate::state::AppState;
use crate::vm_providers::VALID_VM_PROVIDERS;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const VALID_STATUSES: &[&str] = &["provisioning", "running", "stopped", "failed"];

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct CreateDeploymentRequest {
    pub node_id: String,
    pub region: String,
    pub vm_type: String,
    pub vm_provider: String,
    pub ip_address: Option<String>,
    #[serde(default)]
    pub provision: bool,
}

#[derive(Debug, Deserialize)]
pub struct UpdateDeploymentRequest {
    pub ip_address: Option<String>,
    pub status: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct ListDeploymentsQuery {
    pub include_terminated: Option<bool>,
}

/// Admin-facing deployment DTO exposing all deployment fields including
/// provisioning state, provider VM linkage, and health check results.
#[derive(Debug, Serialize)]
pub struct DeploymentResponse {
    pub id: Uuid,
    pub customer_id: Uuid,
    pub node_id: String,
    pub region: String,
    pub vm_type: String,
    pub vm_provider: String,
    pub ip_address: Option<String>,
    pub status: String,
    pub created_at: DateTime<Utc>,
    pub terminated_at: Option<DateTime<Utc>>,
    pub provider_vm_id: Option<String>,
    pub hostname: Option<String>,
    pub flapjack_url: Option<String>,
    pub health_status: String,
    pub last_health_check_at: Option<DateTime<Utc>>,
}

impl From<Deployment> for DeploymentResponse {
    /// 1:1 field mapping from the `Deployment` model.
    fn from(d: Deployment) -> Self {
        Self {
            id: d.id,
            customer_id: d.customer_id,
            node_id: d.node_id,
            region: d.region,
            vm_type: d.vm_type,
            vm_provider: d.vm_provider,
            ip_address: d.ip_address,
            status: d.status,
            created_at: d.created_at,
            terminated_at: d.terminated_at,
            provider_vm_id: d.provider_vm_id,
            hostname: d.hostname,
            flapjack_url: d.flapjack_url,
            health_status: d.health_status,
            last_health_check_at: d.last_health_check_at,
        }
    }
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// `POST /admin/tenants/{id}/deployments` — create a deployment for a customer.
///
/// **Auth:** `AdminAuth`.
/// Validates `vm_provider` against `VALID_VM_PROVIDERS`. When `provision` is
/// true, delegates to the provisioning service for async VM creation + DNS;
/// otherwise creates a direct DB record for manual provisioning. Returns 201.
pub async fn create_deployment(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(req): Json<CreateDeploymentRequest>,
) -> Result<impl IntoResponse, ApiError> {
    // Verify customer exists and is active.
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    // Validate vm_provider
    if !VALID_VM_PROVIDERS.contains(&req.vm_provider.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "invalid vm_provider: must be one of {:?}",
            VALID_VM_PROVIDERS
        )));
    }

    if req.provision {
        // Delegate to provisioning service (async VM creation + DNS)
        let deployment = state
            .provisioning_service
            .provision_deployment(customer_id, &req.region, &req.vm_type, &req.vm_provider)
            .await?;

        Ok((
            StatusCode::CREATED,
            Json(DeploymentResponse::from(deployment)),
        ))
    } else {
        // Direct DB record creation (manual provisioning)
        let deployment = state
            .deployment_repo
            .create(
                customer_id,
                &req.node_id,
                &req.region,
                &req.vm_type,
                &req.vm_provider,
                req.ip_address.as_deref(),
            )
            .await?;

        Ok((
            StatusCode::CREATED,
            Json(DeploymentResponse::from(deployment)),
        ))
    }
}

/// `GET /admin/tenants/{id}/deployments` — list deployments for a customer.
///
/// **Auth:** `AdminAuth`.
/// Optional `include_terminated` query param (default false) controls whether
/// terminated deployments are included in the response.
pub async fn list_deployments(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Query(query): Query<ListDeploymentsQuery>,
) -> Result<impl IntoResponse, ApiError> {
    // Verify customer exists and is active.
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;

    let include_terminated = query.include_terminated.unwrap_or(false);
    let deployments = state
        .deployment_repo
        .list_by_customer(customer_id, include_terminated)
        .await?;

    let responses: Vec<DeploymentResponse> = deployments
        .into_iter()
        .map(DeploymentResponse::from)
        .collect();

    Ok(Json(responses))
}

/// `PUT /admin/deployments/{id}` — update deployment ip_address or status.
///
/// **Auth:** `AdminAuth`.
/// At least one field required. Validates `status` against `VALID_STATUSES`
/// (provisioning, running, stopped, failed).
pub async fn update_deployment(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
    Json(req): Json<UpdateDeploymentRequest>,
) -> Result<impl IntoResponse, ApiError> {
    if req.ip_address.is_none() && req.status.is_none() {
        return Err(ApiError::BadRequest("no fields to update".into()));
    }

    // Validate status if provided
    if let Some(ref status) = req.status {
        if !VALID_STATUSES.contains(&status.as_str()) {
            return Err(ApiError::BadRequest(format!(
                "invalid status: must be one of {:?}",
                VALID_STATUSES
            )));
        }
    }

    let deployment = state
        .deployment_repo
        .update(id, req.ip_address.as_deref(), req.status.as_deref())
        .await?
        .ok_or_else(|| ApiError::NotFound("deployment not found".into()))?;

    Ok(Json(DeploymentResponse::from(deployment)))
}

pub async fn terminate_deployment(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let terminated = state.deployment_repo.terminate(id).await?;
    if terminated {
        Ok(StatusCode::NO_CONTENT)
    } else {
        Err(ApiError::NotFound("deployment not found".into()))
    }
}

pub async fn list_fleet(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let deployments = state.deployment_repo.list_active().await?;
    let responses: Vec<DeploymentResponse> = deployments
        .into_iter()
        .map(DeploymentResponse::from)
        .collect();
    Ok(Json(responses))
}

#[derive(Debug, Serialize)]
pub struct HealthCheckResponse {
    pub id: Uuid,
    pub health_status: String,
    pub last_health_check_at: DateTime<Utc>,
}

/// `POST /admin/deployments/{id}/health-check` — probe a deployment's health.
///
/// **Auth:** `AdminAuth`.
/// Requires the deployment to have a `flapjack_url`. Sends an HTTP GET to
/// `/health` with a 5-second timeout. Updates the deployment's `health_status`
/// ("healthy"/"unhealthy") and `last_health_check_at` timestamp.
pub async fn health_check_deployment(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let deployment = state
        .deployment_repo
        .find_by_id(id)
        .await?
        .ok_or_else(|| ApiError::NotFound("deployment not found".into()))?;

    let flapjack_url = deployment.flapjack_url.as_deref().ok_or_else(|| {
        ApiError::BadRequest("deployment has no flapjack_url (still provisioning)".into())
    })?;

    let health_url = format!("{flapjack_url}/health");
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| ApiError::Internal(format!("failed to build HTTP client: {e}")))?;

    let now = Utc::now();
    let health_status = match client.get(&health_url).send().await {
        Ok(resp) if resp.status().is_success() => "healthy",
        _ => "unhealthy",
    };

    state
        .deployment_repo
        .update_health(id, health_status, now)
        .await?;

    Ok(Json(HealthCheckResponse {
        id,
        health_status: health_status.to_string(),
        last_health_check_at: now,
    }))
}
