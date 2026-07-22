use super::*;
use crate::services::flapjack_proxy::ProxyError;
use crate::services::provisioning::SharedVmProvisioningMode;
use reqwest::Url;
use std::time::Duration;
use tokio::time::sleep;

const NEW_SHARED_VM_CREATE_RETRY_ATTEMPTS: usize = 20;
const NEW_SHARED_VM_CREATE_RETRY_INTERVAL: Duration = Duration::from_secs(3);

// An existing active shared VM is already booted, so a transient proxy
// unreachable/timeout is a brief blip (proxy GC pause, momentary network fault)
// rather than a cold-boot warmup window. Still, post-deploy prod canaries on
// 2026-05-25 showed the blip can outlast the original 3x500ms budget, so keep a
// fast interval but extend the attempt window to avoid premature 503s.
const EXISTING_SHARED_VM_CREATE_RETRY_ATTEMPTS: usize = 10;
const EXISTING_SHARED_VM_CREATE_RETRY_INTERVAL: Duration = Duration::from_millis(500);

pub(crate) struct SelectedSharedVm {
    vm: crate::models::vm_inventory::VmInventory,
    just_provisioned: bool,
}

impl SelectedSharedVm {
    pub(crate) fn vm_id(&self) -> Uuid {
        self.vm.id
    }

    pub(crate) fn flapjack_url(&self) -> &str {
        &self.vm.flapjack_url
    }
}

struct SharedVmCreatePlan {
    intent: crate::models::tenant::CustomerTenant,
    target: ResolvedFlapjackTarget,
    vm: crate::models::vm_inventory::VmInventory,
    just_provisioned: bool,
    created_deployment_id: Option<Uuid>,
}

pub(super) async fn create_index_on_shared_vm(
    state: &AppState,
    destination: AdmittedIndexDestination,
) -> Result<Response, ApiError> {
    // Writer inventory owner: create planning publishes through state.tenant_repo.create_lifecycle_intent(...).
    let plan = state
        .index_lifecycle_lease
        .guarded_locked_mutation(destination.customer_id, &destination.index_name, || async {
            resolve_or_create_shared_vm_create_plan(state, &destination).await
        })
        .await?;
    let endpoint = plan.vm.flapjack_url.clone();

    // Use the tenant-scoped flapjack UID already computed in the target so
    // same-name indexes from different customers are isolated on the shared VM.
    let remote_result = async {
        ensure_shared_vm_has_admin_key(state, &plan.vm).await?;
        create_shared_vm_index_with_warmup_retry(state, &plan.target, plan.just_provisioned).await
    }
    .await;
    if let Err(error) = remote_result {
        rollback_owned_shared_vm_create_intent(state, &destination, &plan).await;
        return Err(error);
    }

    let expected_identity = super::catalog_identity_from_tenant(&plan.intent);
    let published = state
        .index_lifecycle_lease
        .guarded_mutation(
            destination.customer_id,
            &destination.index_name,
            Some(&expected_identity),
            || async {
                state
                    .tenant_repo
                    .publish_lifecycle_placement(
                        destination.customer_id,
                        &destination.index_name,
                        &expected_identity,
                        Some(plan.vm.id),
                    )
                    .await
            },
        )
        .await;
    let tenant = match published {
        Ok(tenant) => tenant,
        Err(error) => {
            rollback_owned_shared_vm_create_intent(state, &destination, &plan).await;
            return Err(error.into());
        }
    };
    state
        .discovery_service
        .invalidate(destination.customer_id, &destination.index_name);

    if let Some(existing_override) =
        super::resolve_customer_quota_override(state, destination.customer_id).await?
    {
        // Admin quota updates are stored on existing tenant rows, so copy the
        // effective customer override onto the newly created row to keep
        // future quota reads consistent.
        state
            .tenant_repo
            .set_resource_quota(
                destination.customer_id,
                &destination.index_name,
                existing_override,
            )
            .await?;
    }
    Ok((
        StatusCode::CREATED,
        Json(serde_json::json!(IndexResponse {
            name: tenant.tenant_id,
            region: destination.region,
            endpoint: Some(endpoint),
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

async fn resolve_or_create_shared_vm_create_plan(
    state: &AppState,
    destination: &AdmittedIndexDestination,
) -> Result<SharedVmCreatePlan, ApiError> {
    match state
        .tenant_repo
        .find_raw(destination.customer_id, &destination.index_name)
        .await?
    {
        Some(existing) => resume_shared_vm_create_plan(state, destination, existing).await,
        None => create_shared_vm_create_plan(state, destination).await,
    }
}

async fn create_shared_vm_create_plan(
    state: &AppState,
    destination: &AdmittedIndexDestination,
) -> Result<SharedVmCreatePlan, ApiError> {
    let selected_vm = reserve_shared_vm_destination(state, destination).await?;
    let vm = selected_vm.vm;
    let (deployment_id, target) = create_shared_deployment(state, destination, &vm).await?;
    let intent = crate::repos::TenantRepo::create_lifecycle_intent(
        state.tenant_repo.as_ref(),
        destination.customer_id,
        &destination.index_name,
        deployment_id,
        "provisioning",
    )
    .await?;

    Ok(SharedVmCreatePlan {
        intent,
        target,
        vm,
        just_provisioned: selected_vm.just_provisioned,
        created_deployment_id: Some(deployment_id),
    })
}

async fn resume_shared_vm_create_plan(
    state: &AppState,
    destination: &AdmittedIndexDestination,
    intent: crate::models::tenant::CustomerTenant,
) -> Result<SharedVmCreatePlan, ApiError> {
    if !is_compatible_shared_vm_create_intent(&intent) {
        return Err(ApiError::Conflict("destination_changed".into()));
    }
    let deployment = state
        .deployment_repo
        .find_by_id(intent.deployment_id)
        .await?
        .ok_or(ApiError::Conflict("destination_changed".into()))?;
    if deployment.customer_id != destination.customer_id
        || deployment.region != destination.region
        || deployment.vm_type != "shared"
        || deployment.status == "terminated"
    {
        return Err(ApiError::Conflict("destination_changed".into()));
    }
    let vm_id = deployment
        .provider_vm_id
        .as_deref()
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or(ApiError::Conflict("destination_changed".into()))?;
    let vm = state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or(ApiError::Conflict("destination_changed".into()))?;
    if vm.region != destination.region
        || vm.provider != deployment.vm_provider
        || Some(vm.flapjack_url.as_str()) != deployment.flapjack_url.as_deref()
        || vm.status != "active"
    {
        return Err(ApiError::Conflict("destination_changed".into()));
    }

    Ok(SharedVmCreatePlan {
        target: ResolvedFlapjackTarget {
            vm_id,
            flapjack_url: vm.flapjack_url.clone(),
            node_id: super::shared_vm_secret_id(&vm).to_string(),
            region: destination.region.clone(),
            flapjack_uid: destination.flapjack_uid(),
        },
        intent,
        vm,
        just_provisioned: false,
        created_deployment_id: None,
    })
}

fn is_compatible_shared_vm_create_intent(tenant: &crate::models::tenant::CustomerTenant) -> bool {
    tenant.tier == "provisioning"
        && tenant.vm_id.is_none()
        && tenant.cold_snapshot_id.is_none()
        && tenant.service_type == "flapjack"
}

async fn rollback_owned_shared_vm_create_intent(
    state: &AppState,
    destination: &AdmittedIndexDestination,
    plan: &SharedVmCreatePlan,
) {
    let Some(deployment_id) = plan.created_deployment_id else {
        return;
    };
    let expected_identity = super::catalog_identity_from_tenant(&plan.intent);
    match state
        .tenant_repo
        .remove_lifecycle_intent(
            destination.customer_id,
            &destination.index_name,
            &expected_identity,
        )
        .await
    {
        Ok(true) => terminate_unreferenced_created_deployment(state, deployment_id).await,
        Ok(false) => tracing::warn!(
            deployment_id = %deployment_id,
            index_name = %destination.index_name,
            "shared VM create rollback found no lifecycle intent to remove"
        ),
        Err(error) => tracing::warn!(
            error = %error,
            deployment_id = %deployment_id,
            index_name = %destination.index_name,
            "shared VM create rollback failed to remove lifecycle intent"
        ),
    }
}

async fn terminate_unreferenced_created_deployment(state: &AppState, deployment_id: Uuid) {
    match state.tenant_repo.find_by_deployment(deployment_id).await {
        Ok(references) if references.is_empty() => {
            if let Err(error) = state.deployment_repo.terminate(deployment_id).await {
                tracing::warn!(
                    error = %error,
                    deployment_id = %deployment_id,
                    "shared VM create rollback failed to terminate unreferenced deployment"
                );
            }
        }
        Ok(_) => tracing::warn!(
            deployment_id = %deployment_id,
            "shared VM create rollback kept deployment because it is still referenced"
        ),
        Err(error) => tracing::warn!(
            error = %error,
            deployment_id = %deployment_id,
            "shared VM create rollback could not confirm deployment references"
        ),
    }
}

pub(crate) async fn reserve_shared_vm_destination(
    state: &AppState,
    destination: &AdmittedIndexDestination,
) -> Result<SelectedSharedVm, ApiError> {
    select_shared_vm_for_new_index(state, &destination.region, &ResourceVector::zero()).await
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

fn normalized_flapjack_url(raw_url: &str) -> String {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let suffix_start = [trimmed.find('?'), trimmed.find('#')]
        .into_iter()
        .flatten()
        .min();

    let (base, suffix) = match suffix_start {
        Some(index) => trimmed.split_at(index),
        None => (trimmed, ""),
    };

    let normalized_base = base.trim_end_matches('/');
    if normalized_base.is_empty() {
        return String::new();
    }

    let parsed = match Url::parse(normalized_base) {
        Ok(parsed) => parsed,
        Err(_) => return format!("{normalized_base}{suffix}"),
    };

    let Some(host) = parsed.host_str() else {
        return format!("{normalized_base}{suffix}");
    };

    let canonical_host = if host == "localhost" {
        "loopback".to_string()
    } else {
        match host.parse::<std::net::IpAddr>() {
            Ok(ip) if ip.is_loopback() => "loopback".to_string(),
            _ => host.to_ascii_lowercase(),
        }
    };

    let port = parsed
        .port_or_known_default()
        .map(|value| format!(":{value}"))
        .unwrap_or_default();
    format!(
        "{}://{}{port}{}{}",
        parsed.scheme(),
        canonical_host,
        parsed.path(),
        suffix
    )
}

fn current_local_dev_flapjack_url() -> Option<String> {
    std::env::var("LOCAL_DEV_FLAPJACK_URL")
        .ok()
        .and_then(|raw_url| {
            crate::services::provisioning::normalize_local_dev_flapjack_url(&raw_url)
        })
        .map(|normalized_url| normalized_flapjack_url(&normalized_url))
        .filter(|normalized_url| !normalized_url.is_empty())
}

fn restrict_to_current_local_dev_vm(
    candidate_vms: Vec<crate::models::vm_inventory::VmInventory>,
) -> Vec<crate::models::vm_inventory::VmInventory> {
    let Some(current_local_url) = current_local_dev_flapjack_url() else {
        return candidate_vms;
    };

    // Playwright and local-dev runs use workspace-derived Flapjack ports. Old
    // active inventory rows from a previous run can still point at dead loopback
    // ports, so local-dev placement must only consider the current stack URL.
    candidate_vms
        .into_iter()
        .filter(|vm| normalized_flapjack_url(&vm.flapjack_url) == current_local_url)
        .collect()
}

fn select_placed_vm(
    new_index_resources: &ResourceVector,
    candidate_vms: &[crate::models::vm_inventory::VmInventory],
) -> Option<SelectedSharedVm> {
    place_index(new_index_resources, &build_shared_vm_loads(candidate_vms)).and_then(
        |placed_vm_id| {
            candidate_vms
                .iter()
                .find(|v| v.id == placed_vm_id)
                .cloned()
                .map(|vm| SelectedSharedVm {
                    vm,
                    just_provisioned: false,
                })
        },
    )
}

/// For zero-resource index creation requests, placement does not need fresh
/// load telemetry or capacity headroom because creating an empty index does
/// not add measurable runtime load.
///
/// This avoids unnecessary cold auto-provisioning when existing shared VMs are
/// active but temporarily missing/stale `load_scraped_at`.
///
/// Prefers VMs with load telemetry history (confirmed alive by the scraper at
/// some point) over VMs that have never been scraped. Among each group, picks
/// the most recently scraped/created.
fn select_zero_resource_fallback_vm(
    new_index_resources: &ResourceVector,
    candidate_vms: &[crate::models::vm_inventory::VmInventory],
) -> Option<SelectedSharedVm> {
    if *new_index_resources != ResourceVector::zero() {
        return None;
    }

    candidate_vms
        .iter()
        .filter(|vm| vm.status == "active")
        .max_by_key(|vm| {
            (
                vm.load_scraped_at.is_some(),
                vm.load_scraped_at.unwrap_or(vm.created_at),
            )
        })
        .cloned()
        .map(|vm| SelectedSharedVm {
            vm,
            just_provisioned: false,
        })
}

/// Select the best shared VM in a region for placing a new index, auto-provisioning
/// a new VM if no existing VM has capacity.
pub(crate) async fn select_shared_vm_for_new_index(
    state: &AppState,
    region: &str,
    new_index_resources: &ResourceVector,
) -> Result<SelectedSharedVm, ApiError> {
    let baseline_vms = state
        .vm_inventory_repo
        .list_active(Some(region))
        .await
        .map_err(|e| ApiError::Internal(e.to_string()))?;
    let baseline_vms = restrict_to_current_local_dev_vm(baseline_vms);

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
    let locked_vms = restrict_to_current_local_dev_vm(locked_vms);

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
        return Ok(SelectedSharedVm {
            vm,
            just_provisioned: true,
        });
    }

    if let Some(vm) = select_zero_resource_fallback_vm(new_index_resources, &locked_vms) {
        tracing::warn!(
            region,
            "shared VM placement missing fresh load telemetry; reusing active VM for zero-resource create"
        );
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
        .auto_provision_shared_vm(
            state.vm_inventory_repo.as_ref(),
            region,
            provider,
            SharedVmProvisioningMode::AllowLocalDevBypass,
        )
        .await
        .map(|vm| SelectedSharedVm {
            vm,
            just_provisioned: true,
        })
        .map_err(|e| {
            ApiError::ServiceUnavailable(format!("failed to auto-provision shared VM: {e}"))
        })
}

async fn create_shared_vm_index_with_warmup_retry(
    state: &AppState,
    target: &ResolvedFlapjackTarget,
    just_provisioned: bool,
) -> Result<(), ApiError> {
    // Fresh provisions need a long cold-boot warmup window; existing active VMs
    // only need a short fast-retry budget to ride out a transient blip. Both
    // paths retry the same transient proxy errors — only the budget differs.
    let (attempts, retry_interval) = if just_provisioned {
        (
            NEW_SHARED_VM_CREATE_RETRY_ATTEMPTS,
            NEW_SHARED_VM_CREATE_RETRY_INTERVAL,
        )
    } else {
        (
            EXISTING_SHARED_VM_CREATE_RETRY_ATTEMPTS,
            EXISTING_SHARED_VM_CREATE_RETRY_INTERVAL,
        )
    };

    for attempt in 0..attempts {
        match state
            .flapjack_proxy
            .create_index(
                &target.flapjack_url,
                &target.node_id,
                &target.region,
                &target.flapjack_uid,
            )
            .await
        {
            Ok(()) => return Ok(()),
            Err(ProxyError::Unreachable(message)) if attempt + 1 < attempts => {
                tracing::warn!(
                    flapjack_url = %target.flapjack_url,
                    node_id = %target.node_id,
                    attempt = attempt + 1,
                    attempts,
                    just_provisioned,
                    error = %message,
                    "shared VM unreachable during index create; retrying"
                );
                sleep(retry_interval).await;
            }
            Err(ProxyError::Timeout) if attempt + 1 < attempts => {
                tracing::warn!(
                    flapjack_url = %target.flapjack_url,
                    node_id = %target.node_id,
                    attempt = attempt + 1,
                    attempts,
                    just_provisioned,
                    "shared VM timed out during index create; retrying"
                );
                sleep(retry_interval).await;
            }
            Err(error) => return Err(error.into()),
        }
    }

    Err(ApiError::ServiceUnavailable(
        "backend temporarily unavailable".into(),
    ))
}

/// Create a deployment row and return the resolved flapjack target for a
/// shared-VM index.
///
/// Generates a random `node_id` (unused for auth — shared-VM traffic uses
/// the VM-level secret), writes the deployment, then immediately marks it
/// as provisioned with the VM's hostname and flapjack URL.
pub(crate) async fn create_shared_deployment(
    state: &AppState,
    destination: &AdmittedIndexDestination,
    vm: &crate::models::vm_inventory::VmInventory,
) -> Result<(Uuid, ResolvedFlapjackTarget), ApiError> {
    // Shared-placement traffic authenticates with the shared VM secret, so a
    // per-deployment node API key would be unused secret sprawl.
    let node_id = format!("node-{}", Uuid::new_v4());

    let deployment = state
        .deployment_repo
        .create(
            destination.customer_id,
            &node_id,
            &destination.region,
            "shared",
            &vm.provider,
            None,
        )
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
            vm_id: vm.id,
            flapjack_url: vm.flapjack_url.clone(),
            node_id: super::shared_vm_secret_id(vm).to_string(),
            region: destination.region.clone(),
            flapjack_uid: destination.flapjack_uid(),
        },
    ))
}
