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
use crate::repos::RepoError;
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

    // 1b. Idempotent fast-path: if the tenant already exists, short-circuit
    //     before allocating any new infrastructure. This guards against
    //     leaking fresh deployments, SSM admin keys, or vm_inventory rows
    //     on rerun — failure modes that the linear path would otherwise
    //     introduce on a (customer_id, tenant_id) collision.
    if let Some(existing) = state.tenant_repo.find_raw(customer_id, &req.name).await? {
        let expected_identity = crate::routes::indexes::catalog_identity_from_tenant(&existing);
        state
            .index_lifecycle_lease
            .guarded_mutation(customer_id, &req.name, Some(&expected_identity), || async {
                Ok::<_, RepoError>(())
            })
            .await?;
        return resolve_existing_seed_index(
            &state,
            customer_id,
            &req.name,
            req.flapjack_url.as_deref(),
        )
        .await;
    }
    state
        .index_lifecycle_lease
        .guarded_mutation(customer_id, &req.name, None, || async {
            Ok::<_, RepoError>(())
        })
        .await?;

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

    let intent = match state
        .index_lifecycle_lease
        .guarded_mutation(customer_id, &req.name, None, || async {
            state
                .tenant_repo
                .create_lifecycle_intent(customer_id, &req.name, deployment.id, "provisioning")
                .await
        })
        .await
    {
        Ok(tenant) => tenant,
        Err(RepoError::Conflict(_)) => {
            return resolve_existing_seed_index(
                &state,
                customer_id,
                &req.name,
                req.flapjack_url.as_deref(),
            )
            .await;
        }
        Err(other) => return Err(other.into()),
    };
    let expected_identity = crate::routes::indexes::catalog_identity_from_tenant(&intent);

    let seeded_vm = match prepare_seed_remote_target(&state, &req, &deployment).await {
        Ok(seeded_vm) => seeded_vm,
        Err(error) => {
            rollback_seed_intent(&state, &intent, &expected_identity).await;
            return Err(error);
        }
    };

    let tenant = match publish_seed_intent(&state, &intent, &expected_identity, &seeded_vm).await {
        Ok(tenant) => tenant,
        Err(error) => {
            rollback_seed_intent(&state, &intent, &expected_identity).await;
            return Err(error);
        }
    };
    state
        .discovery_service
        .invalidate(customer_id, &tenant.tenant_id);
    let endpoint = if let Some(vm) = seeded_vm {
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

async fn prepare_seed_remote_target(
    state: &AppState,
    req: &SeedIndexRequest,
    deployment: &crate::models::Deployment,
) -> Result<Option<crate::models::vm_inventory::VmInventory>, ApiError> {
    if req.flapjack_url.is_some() {
        ensure_seed_deployment_has_admin_key(state, &deployment.node_id, &deployment.region)
            .await?;
    }

    if let Some(ref flapjack_url) = req.flapjack_url {
        find_or_create_vm(state, &req.region, &deployment.vm_provider, flapjack_url)
            .await
            .map(Some)
    } else {
        Ok(None)
    }
}

async fn publish_seed_intent(
    state: &AppState,
    intent: &crate::models::tenant::CustomerTenant,
    expected_identity: &crate::repos::CatalogLifecycleTargetIdentity,
    seeded_vm: &Option<crate::models::vm_inventory::VmInventory>,
) -> Result<crate::models::tenant::CustomerTenant, ApiError> {
    let published = state
        .index_lifecycle_lease
        .guarded_mutation(
            intent.customer_id,
            &intent.tenant_id,
            Some(expected_identity),
            || async {
                state
                    .tenant_repo
                    .publish_lifecycle_placement(
                        intent.customer_id,
                        &intent.tenant_id,
                        expected_identity,
                        seeded_vm.as_ref().map(|vm| vm.id),
                    )
                    .await
            },
        )
        .await?;
    Ok(published)
}

async fn rollback_seed_intent(
    state: &AppState,
    intent: &crate::models::tenant::CustomerTenant,
    expected_identity: &crate::repos::CatalogLifecycleTargetIdentity,
) {
    if let Err(error) = state
        .index_lifecycle_lease
        .guarded_mutation(
            intent.customer_id,
            &intent.tenant_id,
            Some(expected_identity),
            || async {
                state
                    .tenant_repo
                    .delete(intent.customer_id, &intent.tenant_id)
                    .await?;
                Ok::<_, RepoError>(())
            },
        )
        .await
    {
        tracing::warn!(
            customer_id = %intent.customer_id,
            tenant_id = %intent.tenant_id,
            error = %error,
            "failed to roll back admin seed lifecycle intent"
        );
    }
}

/// Idempotency seam: when an index already exists for `(customer_id, name)`,
/// resolve its current flapjack endpoint and return a `200 OK` response so
/// reruns of the synthetic seeder can recover the existing endpoint without
/// having to delete-and-recreate. Falls back to a `None` endpoint when the
/// live VM lookup fails (e.g. tenant exists but no `vm_id` linkage yet).
async fn resolve_existing_seed_index(
    state: &AppState,
    customer_id: Uuid,
    name: &str,
    requested_flapjack_url: Option<&str>,
) -> Result<(StatusCode, Json<SeedIndexResponse>), ApiError> {
    // `find_raw` reads only the customer_tenants row and avoids the
    // deployments-join requirement that `find_by_name` imposes — that
    // matters for both the live PG path (faster, no implicit join) and the
    // unit-test mock, whose join surface is intentionally narrower.
    let tenant = state
        .tenant_repo
        .find_raw(customer_id, name)
        .await?
        .ok_or_else(|| {
            ApiError::Internal(format!(
                "tenant_repo.create reported conflict but find_raw('{name}') returned None"
            ))
        })?;
    let expected_identity = crate::routes::indexes::catalog_identity_from_tenant(&tenant);
    let deployment = state
        .deployment_repo
        .find_by_id(tenant.deployment_id)
        .await?
        .ok_or_else(|| {
            ApiError::Internal(format!(
                "tenant '{name}' references missing deployment {}",
                tenant.deployment_id
            ))
        })?;
    let endpoint = if let Some(flapjack_url) = requested_flapjack_url {
        let vm = find_or_create_vm(
            state,
            &deployment.region,
            &deployment.vm_provider,
            flapjack_url,
        )
        .await?;
        state
            .index_lifecycle_lease
            .guarded_mutation(
                customer_id,
                &tenant.tenant_id,
                Some(&expected_identity),
                || async {
                    state
                        .tenant_repo
                        .publish_lifecycle_placement(
                            customer_id,
                            &tenant.tenant_id,
                            &expected_identity,
                            Some(vm.id),
                        )
                        .await
                },
            )
            .await?;
        state
            .discovery_service
            .invalidate(customer_id, &tenant.tenant_id);
        Some(vm.flapjack_url)
    } else {
        match crate::routes::indexes::resolve_flapjack_target(
            state,
            customer_id,
            name,
            tenant.deployment_id,
        )
        .await
        {
            Ok(Some(target)) => Some(target.flapjack_url),
            Ok(None) | Err(_) => None,
        }
    };
    Ok((
        StatusCode::OK,
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
            capacity: seed_vm_capacity(),
        })
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    ensure_seed_vm_has_admin_key(state, &vm).await?;
    ensure_seed_vm_has_fresh_load(state, &vm).await?;

    Ok(vm)
}

fn seed_vm_capacity() -> serde_json::Value {
    serde_json::Value::from(ResourceVector {
        cpu_weight: 4.0,
        mem_rss_bytes: 8_000_000_000,
        disk_bytes: 100_000_000_000,
        query_rps: 500.0,
        indexing_rps: 200.0,
    })
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
