use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::IntoResponse;
use axum::Json;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use tracing::info;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::models::tenant::CustomerTenant;
use crate::models::vm_inventory::VmInventory;
use crate::provisioner::VmStatus;
use crate::repos::advisory_lock::{advisory_lock, auto_provision_lock_key};
use crate::repos::{
    VmDecommissionResult, VmRetirementAssessment, VmRetirementBlocker, VmRetirementConflict,
};
use crate::services::provisioning::{
    is_canonical_shared_vm_hostname_for_domain, SharedVmProvisioningMode, VmTeardownReport,
};
use crate::services::vm_health_rollup::{health_rollup_for_tenants, VmHealth};
use crate::state::AppState;

const WARM_FLOOR_REGION: &str = "us-east-1";
const WARM_FLOOR_PROVIDER: &str = "aws";
const WARM_FLOOR_DESIRED_COUNT: u32 = 1;

#[derive(Debug, Serialize)]
pub struct VmDetailResponse {
    pub vm: VmDetailVm,
    pub tenants: Vec<CustomerTenant>,
}

#[derive(Debug, Serialize)]
pub struct VmDetailVm {
    #[serde(flatten)]
    pub inventory: VmInventory,
    pub provider_vm_id: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct VmListEntry {
    #[serde(flatten)]
    pub inventory: VmInventory,
    pub tenant_count: i64,
    pub index_count: i64,
    pub health: VmHealth,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct VmRetirementBlockersQuery {
    pub expected_hostname: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DecommissionVmRequest {
    pub expected_hostname: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SharedWarmFloorRequest {
    pub region: String,
    pub provider: String,
    pub desired_count: u32,
}

#[derive(Debug, Serialize)]
pub struct VmRetirementResponse {
    pub vm_id: Uuid,
    pub hostname: String,
    pub status: &'static str,
    pub result: &'static str,
    pub blockers: Vec<VmRetirementBlocker>,
    pub blocking_reference_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub teardown: Option<VmTeardownReport>,
}

#[derive(Debug, Serialize)]
pub struct SharedWarmFloorResponse {
    pub before_count: usize,
    pub created_count: usize,
    pub active_count: usize,
    pub created_vms: Vec<VmInventory>,
}

fn normalize_provider_vm_id(provider: &str, provider_vm_id: &str) -> String {
    if let Some((prefix, raw)) = provider_vm_id.split_once(':') {
        if prefix == provider && !raw.is_empty() {
            return raw.to_string();
        }
    }
    provider_vm_id.to_string()
}

fn blocking_reference_count(blockers: &[VmRetirementBlocker]) -> i64 {
    blockers.iter().map(|blocker| blocker.count).sum()
}

fn unique_provider_vm_id(provider_ids: impl IntoIterator<Item = String>) -> Option<String> {
    let provider_ids = provider_ids.into_iter().collect::<BTreeSet<_>>();
    (provider_ids.len() == 1)
        .then(|| provider_ids.into_iter().next())
        .flatten()
}

fn retirement_conflict_error(conflict: VmRetirementConflict) -> ApiError {
    match conflict {
        VmRetirementConflict::UnknownVm { vm_id } => {
            ApiError::NotFound(format!("VM not found: {vm_id}"))
        }
        VmRetirementConflict::HostnameMismatch {
            expected_hostname,
            actual_hostname,
        } => ApiError::Conflict(format!(
            "hostname mismatch: expected {expected_hostname}, found {actual_hostname}"
        )),
        VmRetirementConflict::InvalidStatus { actual_status } => ApiError::Conflict(format!(
            "VM status does not allow retirement: {actual_status}"
        )),
    }
}

fn retirement_blockers_response(
    vm_id: Uuid,
    hostname: String,
    assessment: VmRetirementAssessment,
) -> Result<VmRetirementResponse, ApiError> {
    match assessment {
        VmRetirementAssessment::Eligible => Ok(VmRetirementResponse {
            vm_id,
            hostname,
            status: "active",
            result: "eligible",
            blockers: Vec::new(),
            blocking_reference_count: 0,
            teardown: None,
        }),
        VmRetirementAssessment::Blocked(blockers) => Ok(VmRetirementResponse {
            vm_id,
            hostname,
            status: "active",
            result: "blocked",
            blocking_reference_count: blocking_reference_count(&blockers),
            blockers,
            teardown: None,
        }),
        VmRetirementAssessment::Conflict(conflict) => Err(retirement_conflict_error(conflict)),
    }
}

fn decommission_response(
    vm_id: Uuid,
    hostname: String,
    result: VmDecommissionResult,
    teardown: Option<VmTeardownReport>,
) -> Result<axum::response::Response, ApiError> {
    match result {
        VmDecommissionResult::Decommissioned => Ok(Json(VmRetirementResponse {
            vm_id,
            hostname,
            status: "decommissioned",
            result: "decommissioned",
            blockers: Vec::new(),
            blocking_reference_count: 0,
            teardown,
        })
        .into_response()),
        VmDecommissionResult::AlreadyDecommissioned => Ok(Json(VmRetirementResponse {
            vm_id,
            hostname,
            status: "decommissioned",
            result: "already_decommissioned",
            blockers: Vec::new(),
            blocking_reference_count: 0,
            teardown,
        })
        .into_response()),
        VmDecommissionResult::Blocked(blockers) => {
            let response = VmRetirementResponse {
                vm_id,
                hostname,
                status: "active",
                result: "blocked",
                blocking_reference_count: blocking_reference_count(&blockers),
                blockers,
                teardown: None,
            };
            Ok((StatusCode::CONFLICT, Json(response)).into_response())
        }
        VmDecommissionResult::Conflict(conflict) => Err(retirement_conflict_error(conflict)),
    }
}

fn validate_shared_warm_floor_request(
    request: &SharedWarmFloorRequest,
    state: &AppState,
) -> Result<(), ApiError> {
    if request.provider != WARM_FLOOR_PROVIDER {
        return Err(ApiError::BadRequest(format!(
            "shared VM warm floor supports only provider {WARM_FLOOR_PROVIDER}"
        )));
    }
    if request.region != WARM_FLOOR_REGION {
        return Err(ApiError::BadRequest(format!(
            "shared VM warm floor supports only region {WARM_FLOOR_REGION}"
        )));
    }
    if request.desired_count != WARM_FLOOR_DESIRED_COUNT {
        return Err(ApiError::BadRequest(format!(
            "shared VM warm floor desired_count must be {WARM_FLOOR_DESIRED_COUNT}"
        )));
    }
    if state
        .region_config
        .get_available_region(&request.region)
        .is_none()
    {
        return Err(ApiError::BadRequest(format!(
            "region {} is not configured for shared VM warm floor",
            request.region
        )));
    }
    if state.region_config.provider_for_region(&request.region) != Some(request.provider.as_str()) {
        return Err(ApiError::BadRequest(format!(
            "region {} is not configured for provider {}",
            request.region, request.provider
        )));
    }
    Ok(())
}

async fn active_shared_warm_floor_vms(
    state: &AppState,
    region: &str,
    provider: &str,
) -> Result<Vec<VmInventory>, ApiError> {
    let vms = state.vm_inventory_repo.list_active(Some(region)).await?;
    let mut provider_verified_vms = Vec::new();
    for vm in vms {
        if vm.provider != provider
            || !is_canonical_shared_vm_hostname_for_domain(
                &vm.hostname,
                &state.provisioning_service.dns_domain,
            )
        {
            continue;
        }

        let provider_match = state
            .vm_provisioner
            .find_running_vm_by_hostname(provider, region, &vm.hostname)
            .await
            .map_err(|e| {
                ApiError::ServiceUnavailable(format!(
                    "failed to verify shared VM provider state: {e}"
                ))
            })?;
        if provider_match
            .as_ref()
            .is_some_and(|instance| instance.status == VmStatus::Running)
        {
            provider_verified_vms.push(vm);
        }
    }

    Ok(provider_verified_vms)
}

/// Resolve the provider VM ID by looking up deployments for tenants on this VM.
///
/// Filters deployments to those matching the VM's provider and flapjack_url,
/// and returns the stored provider VM ID only if exactly one unique value is
/// found. Returns `None` on zero or ambiguous matches.
async fn provider_vm_id_from_tenants(
    state: &AppState,
    vm: &VmInventory,
    tenants: &[CustomerTenant],
) -> Result<Option<String>, ApiError> {
    let mut provider_ids = BTreeSet::new();
    for tenant in tenants {
        if let Some(deployment) = state
            .deployment_repo
            .find_by_id(tenant.deployment_id)
            .await?
        {
            if deployment.vm_provider != vm.provider {
                continue;
            }
            if deployment.flapjack_url.as_deref() != Some(vm.flapjack_url.as_str()) {
                continue;
            }
            if let Some(provider_vm_id) = deployment.provider_vm_id {
                provider_ids.insert(provider_vm_id);
            }
        }
    }
    Ok(unique_provider_vm_id(provider_ids))
}

/// Fallback: resolve provider VM ID from all active deployments in the fleet.
///
/// Returns an ID only when all matching active deployments agree on one unique
/// provider identity. Ambiguous state must fall through to the provider's
/// hostname lookup instead of selecting an arbitrary destructive target.
async fn provider_vm_id_from_fleet(
    state: &AppState,
    vm: &VmInventory,
) -> Result<Option<String>, ApiError> {
    let deployments = state.deployment_repo.list_active().await?;
    let provider_vm_ids = deployments
        .into_iter()
        .filter(|d| {
            d.vm_provider == vm.provider
                && d.flapjack_url.as_deref() == Some(vm.flapjack_url.as_str())
        })
        .filter_map(|d| d.provider_vm_id);
    Ok(unique_provider_vm_id(provider_vm_ids))
}

async fn teardown_retired_vm_resources(
    state: &AppState,
    vm_id: Uuid,
) -> Result<VmTeardownReport, ApiError> {
    let vm = state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound(format!("VM not found: {vm_id}")))?;
    let tenants = state.tenant_repo.list_by_vm(vm.id).await?;
    state
        .provisioning_service
        .teardown_retired_vm_resources(&vm, &tenants)
        .await
        .map_err(|error| {
            ApiError::ServiceUnavailable(format!("failed to resolve retired VM resources: {error}"))
        })
}

/// `GET /admin/vms/{id}` — retrieve VM inventory detail with tenants and provider ID.
///
/// **Auth:** `AdminAuth`.
/// Returns the VM inventory record, all tenants assigned to it, and the
/// resolved `provider_vm_id` (tenant lookup first, fleet fallback second).
pub async fn get_vm_detail(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let vm = state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("VM not found".into()))?;

    let tenants = state.tenant_repo.list_by_vm(vm_id).await?;
    let provider_vm_id = match provider_vm_id_from_tenants(&state, &vm, &tenants).await? {
        Some(id) => Some(id),
        None => provider_vm_id_from_fleet(&state, &vm).await?,
    }
    .map(|id| normalize_provider_vm_id(&vm.provider, &id));

    Ok(Json(VmDetailResponse {
        vm: VmDetailVm {
            inventory: vm,
            provider_vm_id,
        },
        tenants,
    }))
}

pub async fn get_vm_host_metrics(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("VM not found".into()))?;

    Ok(Json(state.vm_host_metrics_repo.latest_for_vm(vm_id).await?))
}

pub async fn get_vm_lifecycle_events(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("VM not found".into()))?;

    Ok(Json(
        state.vm_lifecycle_event_repo.list_for_vm(vm_id).await?,
    ))
}

// ---------------------------------------------------------------------------
// VM list endpoint
// ---------------------------------------------------------------------------

/// `GET /admin/vms` — list all active VMs from the inventory.
///
/// **Auth:** `AdminAuth`.
/// Returns all vm_inventory records with status != 'decommissioned'.
/// The fleet page shows deployments; this shows the underlying VM infrastructure.
pub async fn list_vms(
    _auth: AdminAuth,
    State(state): State<AppState>,
) -> Result<impl IntoResponse, ApiError> {
    let vms = state.vm_inventory_repo.list_active(None).await?;
    let mut entries = Vec::with_capacity(vms.len());
    for vm in vms {
        let tenants = state.tenant_repo.list_by_vm(vm.id).await?;
        let tenant_count = i64::try_from(
            tenants
                .iter()
                .map(|tenant| tenant.customer_id)
                .collect::<BTreeSet<_>>()
                .len(),
        )
        .map_err(|_| ApiError::Internal("VM tenant count overflowed i64".into()))?;
        let index_count = i64::try_from(tenants.len())
            .map_err(|_| ApiError::Internal("VM index count overflowed i64".into()))?;

        let health = health_rollup_for_tenants(&tenants, state.deployment_repo.as_ref()).await?;

        entries.push(VmListEntry {
            inventory: vm,
            tenant_count,
            index_count,
            health,
        });
    }
    Ok(Json(entries))
}

pub async fn get_retirement_blockers(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
    Query(query): Query<VmRetirementBlockersQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let assessment = state
        .vm_inventory_repo
        .retirement_blockers(vm_id, &query.expected_hostname)
        .await?;
    Ok(Json(retirement_blockers_response(
        vm_id,
        query.expected_hostname,
        assessment,
    )?))
}

pub async fn decommission_vm(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
    Json(request): Json<DecommissionVmRequest>,
) -> Result<axum::response::Response, ApiError> {
    let result = state
        .vm_inventory_repo
        .decommission_if_unreferenced(vm_id, &request.expected_hostname)
        .await?;
    let teardown = match &result {
        VmDecommissionResult::Decommissioned | VmDecommissionResult::AlreadyDecommissioned => {
            Some(teardown_retired_vm_resources(&state, vm_id).await?)
        }
        VmDecommissionResult::Blocked(_) | VmDecommissionResult::Conflict(_) => None,
    };
    decommission_response(vm_id, request.expected_hostname, result, teardown)
}

pub async fn warm_floor_shared_vm(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Json(request): Json<SharedWarmFloorRequest>,
) -> Result<impl IntoResponse, ApiError> {
    validate_shared_warm_floor_request(&request, &state)?;

    let lock_key = auto_provision_lock_key(&state.pool, &request.region)
        .await
        .map_err(|e| ApiError::ServiceUnavailable(format!("failed to compute lock key: {e}")))?;
    let _provisioning_lock = advisory_lock(&state.pool, lock_key).await.map_err(|e| {
        ApiError::ServiceUnavailable(format!("failed to acquire advisory lock: {e}"))
    })?;

    let before_vms =
        active_shared_warm_floor_vms(&state, &request.region, &request.provider).await?;
    let mut created_vms = Vec::new();
    if before_vms.is_empty() {
        let created_vm = state
            .provisioning_service
            .auto_provision_shared_vm(
                state.vm_inventory_repo.as_ref(),
                &request.region,
                &request.provider,
                SharedVmProvisioningMode::RequireManagedVm,
            )
            .await
            .map_err(|e| {
                ApiError::ServiceUnavailable(format!("failed to auto-provision shared VM: {e}"))
            })?;
        created_vms.push(created_vm);
    }

    let active_vms =
        active_shared_warm_floor_vms(&state, &request.region, &request.provider).await?;
    Ok(Json(SharedWarmFloorResponse {
        before_count: before_vms.len(),
        created_count: created_vms.len(),
        active_count: active_vms.len(),
        created_vms,
    }))
}

// ---------------------------------------------------------------------------
// Local-mode VM kill endpoint
// ---------------------------------------------------------------------------

/// Response from the kill endpoint — confirms which VM was killed and on what port.
#[derive(Debug, Serialize)]
pub struct KillVmResponse {
    pub vm_id: Uuid,
    pub region: String,
    pub port: u16,
    pub status: String,
}

/// `POST /admin/vms/{id}/kill` — kill the local Flapjack process for a VM.
///
/// **Auth:** `AdminAuth`.
/// **Local-mode only:** parses the VM's `flapjack_url`, finds the process
/// listening on that port via `lsof`, and sends SIGTERM. Returns 400 if the
/// URL is not a localhost address (safety guard against killing remote VMs).
///
/// After killing, the health monitor will detect the VM as unhealthy within
/// ~3 check cycles, and the region failover monitor will promote replicas if
/// the entire region goes down.
pub async fn kill_vm(
    _auth: AdminAuth,
    State(state): State<AppState>,
    Path(vm_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let vm = state
        .vm_inventory_repo
        .get(vm_id)
        .await?
        .ok_or_else(|| ApiError::NotFound("VM not found".into()))?;

    // Safety guard: only allow killing local Flapjack processes.
    // Remote/production URLs must never be killed via this endpoint.
    if !is_localhost_url(&vm.flapjack_url) {
        return Err(ApiError::BadRequest(
            "kill is only available for local VMs (localhost URLs)".into(),
        ));
    }

    let port = parse_port_from_url(&vm.flapjack_url)
        .ok_or_else(|| ApiError::BadRequest("cannot parse port from flapjack_url".into()))?;

    // Find and kill the Flapjack process listening on this port.
    kill_process_on_port(port)
        .map_err(|e| ApiError::Internal(format!("failed to kill process on port {port}: {e}")))?;

    info!(
        vm_id = %vm_id,
        region = %vm.region,
        port = port,
        "killed local Flapjack process for HA demo"
    );

    Ok(Json(KillVmResponse {
        vm_id,
        region: vm.region,
        port,
        status: "killed".to_string(),
    }))
}

// ---------------------------------------------------------------------------
// Helper functions for local process management
// ---------------------------------------------------------------------------

/// Returns true if the URL's host is a loopback address (127.0.0.1, localhost,
/// or [::1]). Used as a safety guard to prevent accidentally killing remote
/// processes. Uses exact host matching — NOT prefix matching — to prevent
/// bypasses like "http://127.0.0.199" or "http://localhost.evil.com".
pub(crate) fn is_localhost_url(url: &str) -> bool {
    let Some(authority) = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))
    else {
        return false;
    };
    // Strip path and query: "127.0.0.1:7700/health?foo" -> "127.0.0.1:7700"
    let host_port = authority.split('/').next().unwrap_or("");
    // Extract just the host part (strip port if present).
    // Handle IPv6 bracket notation: "[::1]:7700" -> "[::1]"
    let host = if host_port.starts_with('[') {
        // IPv6: everything up to and including ']'
        host_port.split(']').next().map(|s| format!("{s}]"))
    } else {
        // IPv4 or hostname: everything before the last ':'
        // But "127.0.0.1:7700" → host="127.0.0.1", "localhost" → host="localhost"
        Some(
            host_port
                .rsplit_once(':')
                .map(|(h, _)| h)
                .unwrap_or(host_port)
                .to_string(),
        )
    };
    matches!(
        host.as_deref(),
        Some("127.0.0.1") | Some("localhost") | Some("[::1]")
    )
}

/// Extracts the port number from a URL like "http://127.0.0.1:7701".
/// Returns None if the URL has no explicit port or the port is not a valid u16.
/// Handles IPv6 bracket notation: "http://[::1]:7700" → Some(7700).
pub(crate) fn parse_port_from_url(url: &str) -> Option<u16> {
    let authority = url
        .strip_prefix("http://")
        .or_else(|| url.strip_prefix("https://"))?;
    // Strip path: "127.0.0.1:7700/health" -> "127.0.0.1:7700"
    let host_port = authority.split('/').next()?;
    // For IPv6 "[::1]:7700", split on "]:" to get port after bracket
    if host_port.starts_with('[') {
        let after_bracket = host_port.split("]:").nth(1)?;
        return after_bracket.parse().ok();
    }
    // For IPv4/hostname, the port is after the LAST ':'
    let (_host, port_str) = host_port.rsplit_once(':')?;
    port_str.parse().ok()
}

/// Finds all processes listening on the given TCP port and sends SIGTERM.
/// Uses `lsof` to find PIDs — works on macOS and Linux.
///
/// Treats "process already dead" as success (race between lsof and kill is
/// expected if the process exits naturally between the two calls).
fn kill_process_on_port(port: u16) -> Result<(), String> {
    let output = std::process::Command::new("lsof")
        .args(["-t", "-i", &format!(":{port}"), "-sTCP:LISTEN"])
        .output()
        .map_err(|e| format!("lsof command failed: {e}"))?;

    if !output.status.success() || output.stdout.is_empty() {
        return Err(format!("no process found listening on port {port}"));
    }

    let pid_str = String::from_utf8_lossy(&output.stdout);
    // lsof may return multiple PIDs (one per line, e.g. forked workers).
    // Kill ALL of them so the port is fully released.
    let mut killed_any = false;
    for line in pid_str.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let pid: i32 = trimmed
            .parse()
            .map_err(|e| format!("invalid PID '{trimmed}' from lsof: {e}"))?;

        let kill_result = std::process::Command::new("kill")
            .arg(pid.to_string())
            .output()
            .map_err(|e| format!("kill command failed for PID {pid}: {e}"))?;

        if kill_result.status.success() {
            killed_any = true;
        } else {
            // "No such process" means the process already exited between lsof
            // and kill — this is the desired state, so treat it as success.
            let stderr = String::from_utf8_lossy(&kill_result.stderr);
            if stderr.contains("No such process") {
                killed_any = true;
            } else {
                return Err(format!("kill returned non-zero for PID {pid}: {stderr}"));
            }
        }
    }

    if killed_any {
        Ok(())
    } else {
        Err(format!("no valid PIDs found for port {port}"))
    }
}

// ---------------------------------------------------------------------------
// Unit tests for helper functions
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unique_provider_vm_id_rejects_ambiguous_destructive_targets() {
        assert_eq!(unique_provider_vm_id(Vec::<String>::new()), None);
        assert_eq!(
            unique_provider_vm_id(vec!["aws:i-one".to_string()]),
            Some("aws:i-one".to_string())
        );
        assert_eq!(
            unique_provider_vm_id(vec!["aws:i-one".to_string(), "aws:i-one".to_string()]),
            Some("aws:i-one".to_string())
        );
        assert_eq!(
            unique_provider_vm_id(vec!["aws:i-one".to_string(), "aws:i-two".to_string()]),
            None
        );
    }

    // -- is_localhost_url: valid loopback addresses --

    #[test]
    fn is_localhost_url_accepts_ipv4_loopback() {
        assert!(is_localhost_url("http://127.0.0.1:7700"));
        assert!(is_localhost_url("http://127.0.0.1:7701/health"));
        assert!(is_localhost_url("https://127.0.0.1:8080"));
    }

    #[test]
    fn is_localhost_url_accepts_localhost_hostname() {
        assert!(is_localhost_url("http://localhost:7700"));
        assert!(is_localhost_url("https://localhost:7700"));
        assert!(is_localhost_url("http://localhost:7700/path?q=1"));
    }

    #[test]
    fn is_localhost_url_accepts_ipv6_loopback() {
        assert!(is_localhost_url("http://[::1]:7700"));
        assert!(is_localhost_url("https://[::1]:8080/health"));
    }

    // -- is_localhost_url: prefix-matching security tests --
    // These MUST be rejected — they are NOT loopback addresses despite
    // sharing a prefix with valid ones.

    #[test]
    fn is_localhost_url_rejects_similar_prefixes() {
        // 127.0.0.199 is NOT the same as 127.0.0.1
        assert!(!is_localhost_url("http://127.0.0.199:7700"));
        // localhost.evil.com is NOT localhost
        assert!(!is_localhost_url("http://localhost.evil.com:7700"));
        // 127.0.0.1.attacker.com is NOT 127.0.0.1
        assert!(!is_localhost_url("http://127.0.0.1.attacker.com:7700"));
    }

    #[test]
    fn is_localhost_url_rejects_remote() {
        assert!(!is_localhost_url("http://10.0.0.5:7700"));
        assert!(!is_localhost_url("https://vm-abc.flapjack.foo:7700"));
        assert!(!is_localhost_url("http://192.168.1.1:7700"));
        assert!(!is_localhost_url(""));
        assert!(!is_localhost_url("not-a-url"));
    }

    // -- parse_port_from_url: valid cases --

    #[test]
    fn parse_port_from_url_extracts_ipv4_port() {
        assert_eq!(parse_port_from_url("http://127.0.0.1:7700"), Some(7700));
        assert_eq!(parse_port_from_url("http://127.0.0.1:7701"), Some(7701));
        assert_eq!(parse_port_from_url("http://localhost:8080"), Some(8080));
        assert_eq!(
            parse_port_from_url("http://127.0.0.1:7700/health"),
            Some(7700)
        );
        assert_eq!(
            parse_port_from_url("https://localhost:443/api/v1"),
            Some(443)
        );
    }

    #[test]
    fn parse_port_from_url_extracts_ipv6_port() {
        assert_eq!(parse_port_from_url("http://[::1]:7700"), Some(7700));
        assert_eq!(parse_port_from_url("https://[::1]:443/health"), Some(443));
    }

    #[test]
    fn parse_port_from_url_handles_boundary_ports() {
        assert_eq!(parse_port_from_url("http://127.0.0.1:1"), Some(1));
        assert_eq!(parse_port_from_url("http://127.0.0.1:65535"), Some(65535));
        // 65536 overflows u16
        assert_eq!(parse_port_from_url("http://127.0.0.1:65536"), None);
    }

    // -- parse_port_from_url: invalid/missing port --

    #[test]
    fn parse_port_from_url_returns_none_for_invalid() {
        assert_eq!(parse_port_from_url("not-a-url"), None);
        assert_eq!(parse_port_from_url(""), None);
        // No port → None (rsplit_once finds no ':' separator)
        assert_eq!(parse_port_from_url("http://localhost"), None);
        // IPv6 without port
        assert_eq!(parse_port_from_url("http://[::1]"), None);
    }
}
