//! Admin VM inventory endpoints: list, detail, and local-mode process kill.
//!
//! The kill endpoint is local-dev-only: it sends SIGTERM to the Flapjack process
//! bound to a VM's port. This lets the admin UI demonstrate HA failover by
//! killing a node and watching the health monitor + region failover react.
use axum::extract::{Path, State};
use axum::response::IntoResponse;
use axum::Json;
use serde::Serialize;
use std::collections::BTreeSet;
use tracing::info;
use uuid::Uuid;

use crate::auth::AdminAuth;
use crate::errors::ApiError;
use crate::models::tenant::CustomerTenant;
use crate::models::vm_inventory::VmInventory;
use crate::state::AppState;

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

fn normalize_provider_vm_id(provider: &str, provider_vm_id: &str) -> String {
    if let Some((prefix, raw)) = provider_vm_id.split_once(':') {
        if prefix == provider && !raw.is_empty() {
            return raw.to_string();
        }
    }
    provider_vm_id.to_string()
}

/// Resolve the provider VM ID by looking up deployments for tenants on this VM.
///
/// Filters deployments to those matching the VM's provider and flapjack_url,
/// normalizes provider VM IDs, and returns the ID only if exactly one unique
/// value is found. Returns `None` on zero or ambiguous matches.
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
                provider_ids.insert(normalize_provider_vm_id(&vm.provider, &provider_vm_id));
            }
        }
    }
    if provider_ids.len() == 1 {
        Ok(provider_ids.into_iter().next())
    } else {
        Ok(None)
    }
}

/// Fallback: resolve provider VM ID from all active deployments in the fleet.
///
/// Searches for the first active deployment matching the VM's provider and
/// flapjack_url. Used when tenant-based lookup yields no result.
async fn provider_vm_id_from_fleet(
    state: &AppState,
    vm: &VmInventory,
) -> Result<Option<String>, ApiError> {
    let deployments = state.deployment_repo.list_active().await?;
    let provider_vm_id = deployments
        .into_iter()
        .find(|d| {
            d.vm_provider == vm.provider
                && d.flapjack_url.as_deref() == Some(vm.flapjack_url.as_str())
                && d.provider_vm_id.is_some()
        })
        .and_then(|d| d.provider_vm_id)
        .map(|id| normalize_provider_vm_id(&vm.provider, &id));
    Ok(provider_vm_id)
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
    };

    Ok(Json(VmDetailResponse {
        vm: VmDetailVm {
            inventory: vm,
            provider_vm_id,
        },
        tenants,
    }))
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
    Ok(Json(vms))
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
