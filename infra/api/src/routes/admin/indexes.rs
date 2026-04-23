//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/mar19_1_frontend_test_suite/fjcloud_dev/infra/api/src/routes/admin/indexes.rs.
use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use reqwest::Url;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::helpers::require_active_customer;
use crate::models::resource_vector::ResourceVector;
use crate::models::vm_inventory::NewVmInventory;
use crate::state::AppState;
use crate::vm_providers::{AWS_VM_PROVIDER, BARE_METAL_VM_PROVIDER};

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize)]
pub struct SeedIndexRequest {
    pub name: String,
    pub region: String,
    pub flapjack_url: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct SeedIndexResponse {
    pub name: String,
    pub region: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<String>,
}

/// Validate a flapjack URL for seed index creation.
///
/// Requires http/https scheme, a host, and no embedded credentials, query
/// params, fragments, or non-root path. Rejects anything beyond
/// `scheme://host[:port]/`.
fn validate_seed_flapjack_url(flapjack_url: &str) -> Result<(), ApiError> {
    let parsed = Url::parse(flapjack_url)
        .map_err(|_| ApiError::BadRequest("flapjack_url must be a valid absolute URL".into()))?;

    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(ApiError::BadRequest(
            "flapjack_url must use http or https".into(),
        ));
    }

    if parsed.host_str().is_none() {
        return Err(ApiError::BadRequest(
            "flapjack_url must include a host".into(),
        ));
    }

    if !parsed.username().is_empty() || parsed.password().is_some() {
        return Err(ApiError::BadRequest(
            "flapjack_url must not include embedded credentials".into(),
        ));
    }

    if parsed.query().is_some() || parsed.fragment().is_some() {
        return Err(ApiError::BadRequest(
            "flapjack_url must not include query params or fragments".into(),
        ));
    }

    if parsed.path() != "/" {
        return Err(ApiError::BadRequest(
            "flapjack_url must contain only scheme, host, and optional port".into(),
        ));
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// POST /admin/tenants/:id/indexes
///
/// Directly creates a tenant (index) record for the given customer, bypassing
/// the normal Flapjack provisioning flow.  Used for E2E test data seeding.
///
/// If no running deployment exists in the requested region for this customer,
/// a placeholder deployment record is created and transitioned to "running".
///
/// When `flapjack_url` is provided, a VM record is found or created in
/// `vm_inventory`, the tenant's `vm_id` is set, and any synthetic deployment
/// created for the seed receives a node admin key so
/// `resolve_flapjack_target` returns a routable, authenticated endpoint for
/// search proxying.
pub async fn seed_index(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(customer_id): Path<Uuid>,
    Json(req): Json<SeedIndexRequest>,
) -> Result<impl IntoResponse, ApiError> {
    // 1. Verify customer exists and is active.
    require_active_customer(state.customer_repo.as_ref(), customer_id).await?;
    if let Some(flapjack_url) = req.flapjack_url.as_deref() {
        validate_seed_flapjack_url(flapjack_url)?;
    }

    // 2. Find or create a running deployment in the requested region.
    let deployments = state
        .deployment_repo
        .list_by_customer(customer_id, false)
        .await?;

    let (deployment, _created_placeholder_deployment) = if let Some(d) = deployments
        .into_iter()
        .find(|d| d.region == req.region && d.status == "running")
    {
        (d, false)
    } else {
        let node_id = format!("e2e-node-{}", Uuid::new_v4());
        let deployment_provider = if req.flapjack_url.is_some() {
            BARE_METAL_VM_PROVIDER
        } else {
            AWS_VM_PROVIDER
        };
        let created = state
            .deployment_repo
            .create(
                customer_id,
                &node_id,
                &req.region,
                "t4g.small",
                deployment_provider,
                None,
            )
            .await?;
        let deployment = state
            .deployment_repo
            .update(created.id, None, Some("running"))
            .await?
            .ok_or_else(|| {
                ApiError::Internal("failed to transition deployment to running".into())
            })?;
        (deployment, true)
    };

    if req.flapjack_url.is_some() {
        ensure_seed_deployment_has_admin_key(&state, &deployment.node_id, &deployment.region)
            .await?;
    }

    // 3. Resolve shared-VM prerequisites before creating the tenant so a
    // failed seed does not leave behind an index row with no vm_id linkage.
    let seeded_vm = if let Some(ref flapjack_url) = req.flapjack_url {
        Some(find_or_create_vm(&state, &req.region, &deployment.vm_provider, flapjack_url).await?)
    } else {
        None
    };

    // 4. Create the tenant (index) record directly.
    let tenant = state
        .tenant_repo
        .create(customer_id, &req.name, deployment.id)
        .await?;

    // 5. If flapjack_url provided, link the tenant to the prepared VM.
    let endpoint = if let Some(vm) = seeded_vm {
        if let Err(error) = state
            .tenant_repo
            .set_vm_id(customer_id, &tenant.tenant_id, vm.id)
            .await
        {
            if let Err(cleanup_error) = state
                .tenant_repo
                .delete(customer_id, &tenant.tenant_id)
                .await
            {
                tracing::warn!(
                    customer_id = %customer_id,
                    tenant_id = %tenant.tenant_id,
                    vm_id = %vm.id,
                    error = %cleanup_error,
                    "failed to roll back seeded tenant after vm_id link failure"
                );
            }
            return Err(error.into());
        }

        Some(vm.flapjack_url)
    } else {
        None
    };

    Ok((
        StatusCode::CREATED,
        Json(SeedIndexResponse {
            name: tenant.tenant_id,
            region: deployment.region,
            status: "healthy".to_string(),
            endpoint,
        }),
    ))
}

/// Ensure the seeded deployment's node has an API key in the secret manager.
///
/// Checks for an existing key; if missing (detected via
/// `is_missing_node_secret_error`), creates one. Used during seed index
/// creation so `resolve_flapjack_target` can authenticate to the node.
async fn ensure_seed_deployment_has_admin_key(
    state: &AppState,
    node_id: &str,
    region: &str,
) -> Result<(), ApiError> {
    match state
        .provisioning_service
        .node_secret_manager
        .get_node_api_key(node_id, region)
        .await
    {
        Ok(_) => Ok(()),
        Err(error) if crate::routes::indexes::is_missing_node_secret_error(&error) => state
            .provisioning_service
            .node_secret_manager
            .create_node_api_key(node_id, region)
            .await
            .map(|_| ())
            .map_err(|e| {
                ApiError::Internal(format!(
                    "failed to create admin key for seeded deployment: {e}"
                ))
            }),
        Err(error) => Err(ApiError::Internal(format!(
            "failed to verify admin key for seeded deployment: {error}"
        ))),
    }
}

/// Find an active VM with the given `flapjack_url` and provider in the region, or create one.
async fn find_or_create_vm(
    state: &AppState,
    region: &str,
    provider: &str,
    flapjack_url: &str,
) -> Result<crate::models::vm_inventory::VmInventory, ApiError> {
    let existing_vms = state
        .vm_inventory_repo
        .list_active(Some(region))
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    if let Some(vm) = existing_vms
        .into_iter()
        .find(|vm| vm.flapjack_url == flapjack_url && vm.provider == provider)
    {
        ensure_seed_vm_has_admin_key(state, &vm).await?;
        ensure_seed_vm_has_fresh_load(state, &vm).await?;
        return Ok(vm);
    }

    let vm = state
        .vm_inventory_repo
        .create(NewVmInventory {
            region: region.to_string(),
            provider: provider.to_string(),
            hostname: format!("e2e-seed-{}", &Uuid::new_v4().to_string()[..8]),
            flapjack_url: flapjack_url.to_string(),
            capacity: serde_json::json!({"cpu_cores": 8, "memory_gb": 32, "disk_gb": 500}),
        })
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    ensure_seed_vm_has_admin_key(state, &vm).await?;
    ensure_seed_vm_has_fresh_load(state, &vm).await?;

    Ok(vm)
}

/// Ensure the seeded VM has an API key in the secret manager.
///
/// Same pattern as `ensure_seed_deployment_has_admin_key` but uses the VM's
/// `node_secret_id()` as the key identifier.
async fn ensure_seed_vm_has_admin_key(
    state: &AppState,
    vm: &crate::models::vm_inventory::VmInventory,
) -> Result<(), ApiError> {
    let secret_id = vm.node_secret_id();
    match state
        .provisioning_service
        .node_secret_manager
        .get_node_api_key(secret_id, &vm.region)
        .await
    {
        Ok(_) => Ok(()),
        Err(error) if crate::routes::indexes::is_missing_node_secret_error(&error) => state
            .provisioning_service
            .node_secret_manager
            .create_node_api_key(secret_id, &vm.region)
            .await
            .map(|_| ())
            .map_err(|e| {
                ApiError::Internal(format!("failed to create admin key for seeded VM: {e}"))
            }),
        Err(error) => Err(ApiError::Internal(format!(
            "failed to verify admin key for seeded VM: {error}"
        ))),
    }
}

/// Bootstrap zero load for a newly created VM that has never been scraped.
///
/// Only acts when `load_scraped_at` is `None` and `current_load` is the zero
/// vector. Writes a zero-load snapshot so the VM appears in scheduling queries
/// that filter on load freshness.
async fn ensure_seed_vm_has_fresh_load(
    state: &AppState,
    vm: &crate::models::vm_inventory::VmInventory,
) -> Result<(), ApiError> {
    let existing_load = ResourceVector::from(vm.current_load.clone());
    let needs_bootstrap_load =
        vm.load_scraped_at.is_none() && existing_load == ResourceVector::zero();

    if needs_bootstrap_load {
        state
            .vm_inventory_repo
            .update_load(vm.id, serde_json::Value::from(ResourceVector::zero()))
            .await
            .map_err(|e| ApiError::Internal(e.to_string()))?;
    }

    Ok(())
}
