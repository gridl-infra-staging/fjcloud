use super::*;

pub(super) async fn create_index_on_shared_vm(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    region: &str,
) -> Result<Response, ApiError> {
    let vm = select_shared_vm_for_new_index(state, region, &ResourceVector::zero()).await?;
    ensure_shared_vm_has_admin_key(state, &vm).await?;
    let (deployment_id, target) =
        create_shared_deployment(state, customer_id, index_name, region, &vm).await?;

    // Use the tenant-scoped flapjack UID already computed in the target so
    // same-name indexes from different customers are isolated on the shared VM.
    state
        .flapjack_proxy
        .create_index(
            &target.flapjack_url,
            &target.node_id,
            region,
            &target.flapjack_uid,
        )
        .await?;

    let tenant = state
        .tenant_repo
        .create(customer_id, index_name, deployment_id)
        .await?;
    if let Some(existing_override) =
        super::resolve_customer_quota_override(state, customer_id).await?
    {
        // Admin quota updates are stored on existing tenant rows, so copy the
        // effective customer override onto the newly created row to keep
        // future quota reads consistent.
        state
            .tenant_repo
            .set_resource_quota(customer_id, index_name, existing_override)
            .await?;
    }
    state
        .tenant_repo
        .set_vm_id(customer_id, index_name, vm.id)
        .await?;

    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!(IndexResponse {
            name: tenant.tenant_id,
            region: region.to_string(),
            endpoint: Some(vm.flapjack_url),
            entries: 0,
            data_size_bytes: 0,
            status: "healthy".to_string(),
            tier: "active".to_string(),
            last_accessed_at: None,
            cold_since: None,
            created_at: tenant.created_at.to_rfc3339(),
        })),
    )
        .into_response())
}

/// Ensure the shared VM has an admin API key, creating one if missing.
async fn ensure_shared_vm_has_admin_key(
    state: &AppState,
    vm: &crate::models::vm_inventory::VmInventory,
) -> Result<(), ApiError> {
    let secret_id = super::shared_vm_secret_id(vm);
    match state
        .provisioning_service
        .node_secret_manager
        .get_node_api_key(secret_id, &vm.region)
        .await
    {
        Ok(_) => Ok(()),
        Err(error) if super::is_missing_node_secret_error(&error) => state
            .provisioning_service
            .node_secret_manager
            .create_node_api_key(secret_id, &vm.region)
            .await
            .map(|_| ())
            .map_err(|e| {
                ApiError::Internal(format!(
                    "failed to create admin key for shared VM placement: {e}"
                ))
            }),
        Err(error) => Err(ApiError::Internal(format!(
            "failed to verify admin key for shared VM placement: {error}"
        ))),
    }
}

fn build_shared_vm_loads(
    candidate_vms: &[crate::models::vm_inventory::VmInventory],
) -> Vec<VmWithLoad> {
    candidate_vms
        .iter()
        .map(|vm| VmWithLoad {
            vm_id: vm.id,
            capacity: ResourceVector::from(vm.capacity.clone()),
            current_load: ResourceVector::from(vm.current_load.clone()),
            status: vm.status.clone(),
            load_scraped_at: vm.load_scraped_at,
        })
        .collect::<Vec<_>>()
}

fn select_placed_vm(
    new_index_resources: &ResourceVector,
    candidate_vms: &[crate::models::vm_inventory::VmInventory],
) -> Option<crate::models::vm_inventory::VmInventory> {
    place_index(new_index_resources, &build_shared_vm_loads(candidate_vms))
        .and_then(|placed_vm_id| candidate_vms.iter().find(|v| v.id == placed_vm_id).cloned())
}

/// Select the best shared VM in a region for placing a new index, auto-provisioning
/// a new VM if no existing VM has capacity.
async fn select_shared_vm_for_new_index(
    state: &AppState,
    region: &str,
    new_index_resources: &ResourceVector,
) -> Result<crate::models::vm_inventory::VmInventory, ApiError> {
    let baseline_vms = state
        .vm_inventory_repo
        .list_active(Some(region))
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    if let Some(vm) = select_placed_vm(new_index_resources, &baseline_vms) {
        return Ok(vm);
    }

    let lock_key = auto_provision_lock_key(&state.pool, region)
        .await
        .map_err(|e| ApiError::ServiceUnavailable(format!("failed to compute lock key: {e}")))?;
    let _provisioning_lock = advisory_lock(&state.pool, lock_key).await.map_err(|e| {
        ApiError::ServiceUnavailable(format!("failed to acquire advisory lock: {e}"))
    })?;

    let locked_vms = state
        .vm_inventory_repo
        .list_active(Some(region))
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    if let Some(vm) = select_placed_vm(new_index_resources, &locked_vms) {
        return Ok(vm);
    }

    let newly_visible_vm = locked_vms
        .iter()
        .filter(|candidate| {
            !baseline_vms
                .iter()
                .any(|original| original.id == candidate.id)
        })
        .max_by_key(|vm| vm.created_at)
        .cloned();

    if let Some(vm) = newly_visible_vm {
        return Ok(vm);
    }

    let provider = state
        .region_config
        .provider_for_region(region)
        .or_else(|| locked_vms.first().map(|v| v.provider.as_str()))
        .or_else(|| baseline_vms.first().map(|v| v.provider.as_str()))
        .ok_or_else(|| ApiError::Internal("no provider mapping found for auto-provision".into()))?;

    state
        .provisioning_service
        .auto_provision_shared_vm(state.vm_inventory_repo.as_ref(), region, provider)
        .await
        .map_err(|e| {
            ApiError::ServiceUnavailable(format!("failed to auto-provision shared VM: {e}"))
        })
}

/// Create a deployment row and return the resolved flapjack target for a
/// shared-VM index.
///
/// Generates a random `node_id` (unused for auth — shared-VM traffic uses
/// the VM-level secret), writes the deployment, then immediately marks it
/// as provisioned with the VM's hostname and flapjack URL.
async fn create_shared_deployment(
    state: &AppState,
    customer_id: Uuid,
    index_name: &str,
    region: &str,
    vm: &crate::models::vm_inventory::VmInventory,
) -> Result<(Uuid, ResolvedFlapjackTarget), ApiError> {
    // Shared-placement traffic authenticates with the shared VM secret, so a
    // per-deployment node API key would be unused secret sprawl.
    let node_id = format!("node-{}", Uuid::new_v4());

    let deployment = state
        .deployment_repo
        .create(customer_id, &node_id, region, "shared", &vm.provider, None)
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    state
        .deployment_repo
        .update_provisioning(
            deployment.id,
            &vm.id.to_string(),
            "0.0.0.0",
            &vm.hostname,
            &vm.flapjack_url,
        )
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;

    Ok((
        deployment.id,
        ResolvedFlapjackTarget {
            flapjack_url: vm.flapjack_url.clone(),
            node_id: super::shared_vm_secret_id(vm).to_string(),
            region: region.to_string(),
            flapjack_uid: super::flapjack_index_uid(customer_id, index_name),
        },
    ))
}
