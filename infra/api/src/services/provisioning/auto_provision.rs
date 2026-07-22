use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::provisioner::cloud_init::{self, CloudInitParams, SecretDelivery};
use crate::provisioner::CreateVmRequest;
use crate::repos::VmInventoryRepo;
use crate::services::health_monitor::{await_engine_health, EngineHealthWaitStatus};
use reqwest::Url;
use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};
use tracing::{error, info};
use uuid::Uuid;

use super::{ProvisioningError, ProvisioningService, ENGINE_HEALTH_FAILURE_REASON};

const DEFAULT_SHARED_VM_TYPE_AWS: &str = "t4g.small";
const DEFAULT_SHARED_VM_TYPE_HETZNER: &str = "cpx31";
const DEFAULT_SHARED_VM_TYPE_GCP: &str = "e2-standard-2";
const DEFAULT_SHARED_VM_TYPE_OCI: &str = "VM.Standard.A1.Flex";
const DEFAULT_SHARED_VM_TYPE_FALLBACK: &str = "shared";
const SHARED_VM_HOSTNAME_PREFIX: &str = "vm-shared-";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SharedVmProvisioningMode {
    AllowLocalDevBypass,
    RequireManagedVm,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VmTeardownPolicy {
    HaltTeardown,
    ContinueBestEffort,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VmTeardownOutcome {
    Removed,
    Failed { message: String },
    Indeterminate { message: String },
    NotApplicable,
    Skipped { reason: String },
}

impl VmTeardownOutcome {
    fn status(&self) -> &'static str {
        match self {
            Self::Removed => "removed",
            Self::Failed { .. } => "failed",
            Self::Indeterminate { .. } => "indeterminate",
            Self::NotApplicable => "not_applicable",
            Self::Skipped { .. } => "skipped",
        }
    }

    fn clean(&self) -> bool {
        matches!(self, Self::Removed | Self::NotApplicable)
    }
}

impl Serialize for VmTeardownOutcome {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let field_count = match self {
            Self::Failed { .. } | Self::Indeterminate { .. } | Self::Skipped { .. } => 3,
            Self::Removed | Self::NotApplicable => 2,
        };
        let mut map = serializer.serialize_map(Some(field_count))?;
        map.serialize_entry("status", self.status())?;
        map.serialize_entry("clean", &self.clean())?;
        match self {
            Self::Failed { message } | Self::Indeterminate { message } => {
                map.serialize_entry("message", message)?;
            }
            Self::Skipped { reason } => {
                map.serialize_entry("reason", reason)?;
            }
            Self::Removed | Self::NotApplicable => {}
        }
        map.end()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct VmTeardownReport {
    pub instance: VmTeardownOutcome,
    pub dns_record: VmTeardownOutcome,
    pub node_api_key: VmTeardownOutcome,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VmInstanceTeardownTarget {
    ProviderVmId(Option<String>),
    Indeterminate { message: String },
}

impl VmInstanceTeardownTarget {
    pub fn provider_vm_id(provider_vm_id: Option<&str>) -> Self {
        Self::ProviderVmId(provider_vm_id.map(str::to_string))
    }
}

const INSTANCE_TEARDOWN_FAILED_REASON: &str = "instance_teardown_failed";

struct SharedVmDraft {
    hostname: String,
    flapjack_url: String,
    node_id: String,
}

struct SharedVmRegistration<'a> {
    draft: &'a SharedVmDraft,
    provider_vm_id: &'a str,
    region: &'a str,
    provider: &'a str,
}

impl ProvisioningService {
    pub async fn auto_provision_shared_vm(
        &self,
        vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
        region: &str,
        provider: &str,
        mode: SharedVmProvisioningMode,
    ) -> Result<VmInventory, ProvisioningError> {
        ensure_supported_vm_provider(provider)?;

        if mode == SharedVmProvisioningMode::AllowLocalDevBypass {
            if let Some(vm) = try_local_dev_provision(vm_inventory_repo, region, provider).await? {
                return Ok(vm);
            }
        }

        let draft = self.build_shared_vm_draft();

        let api_key = self
            .node_secret_manager
            .create_node_api_key(&draft.node_id, region)
            .await
            .map_err(|e| ProvisioningError::SecretFailed(e.to_string()))?;

        let vm_request = build_shared_vm_request(&draft, provider, region, &api_key);

        let vm_instance = match self.vm_provisioner.create_vm(&vm_request).await {
            Ok(vm) => vm,
            Err(e) => {
                self.teardown_vm_resources(
                    None,
                    VmInstanceTeardownTarget::provider_vm_id(None),
                    &draft.node_id,
                    region,
                    VmTeardownPolicy::ContinueBestEffort,
                )
                .await;
                return Err(ProvisioningError::ProvisionerFailed(e.to_string()));
            }
        };

        let ip = match vm_instance.public_ip.as_deref() {
            Some(ip) => ip,
            None => {
                self.teardown_vm_resources(
                    None,
                    VmInstanceTeardownTarget::provider_vm_id(Some(&vm_instance.provider_vm_id)),
                    &draft.node_id,
                    region,
                    VmTeardownPolicy::ContinueBestEffort,
                )
                .await;
                return Err(ProvisioningError::ProvisionerFailed(
                    "VM created without public IP".into(),
                ));
            }
        };

        if let Err(e) = self.dns_manager.create_record(&draft.hostname, ip).await {
            self.teardown_vm_resources(
                Some(&draft.hostname),
                VmInstanceTeardownTarget::provider_vm_id(Some(&vm_instance.provider_vm_id)),
                &draft.node_id,
                region,
                VmTeardownPolicy::ContinueBestEffort,
            )
            .await;
            return Err(ProvisioningError::DnsFailed(e.to_string()));
        }

        let registration = SharedVmRegistration {
            draft: &draft,
            provider_vm_id: &vm_instance.provider_vm_id,
            region,
            provider,
        };
        let vm_row = self
            .register_shared_vm_inventory(vm_inventory_repo, &registration)
            .await?;

        if self.shared_vm_health_deadline_exhausted(&draft).await {
            self.cleanup_unhealthy_shared_vm_registration(
                vm_inventory_repo,
                &vm_row,
                &registration,
            )
            .await;
            return Err(ProvisioningError::ProvisionerFailed(
                ENGINE_HEALTH_FAILURE_REASON.into(),
            ));
        }

        info!(
            region = %region,
            provider = %provider,
            hostname = %draft.hostname,
            vm_id = %vm_row.id,
            "auto-provisioned shared VM for capacity fallback"
        );

        Ok(vm_row)
    }

    async fn register_shared_vm_inventory(
        &self,
        vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
        registration: &SharedVmRegistration<'_>,
    ) -> Result<VmInventory, ProvisioningError> {
        match vm_inventory_repo
            .create(NewVmInventory {
                region: registration.region.to_string(),
                provider: registration.provider.to_string(),
                hostname: registration.draft.hostname.clone(),
                flapjack_url: registration.draft.flapjack_url.clone(),
                capacity: default_shared_vm_capacity(),
            })
            .await
        {
            Ok(vm) => Ok(vm),
            Err(e) => {
                self.teardown_vm_resources(
                    Some(&registration.draft.hostname),
                    VmInstanceTeardownTarget::provider_vm_id(Some(registration.provider_vm_id)),
                    &registration.draft.node_id,
                    registration.region,
                    VmTeardownPolicy::ContinueBestEffort,
                )
                .await;
                Err(ProvisioningError::RepoError(e.to_string()))
            }
        }
    }

    async fn shared_vm_health_deadline_exhausted(&self, draft: &SharedVmDraft) -> bool {
        matches!(
            await_engine_health(
                self.engine_health_client.clone(),
                Some(draft.flapjack_url.clone()),
                self.engine_health_wait_policy,
            )
            .await,
            EngineHealthWaitStatus::DeadlineExhausted
        )
    }

    async fn cleanup_unhealthy_shared_vm_registration(
        &self,
        vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
        vm_row: &VmInventory,
        registration: &SharedVmRegistration<'_>,
    ) {
        if let Err(e) = vm_inventory_repo
            .set_status(vm_row.id, "decommissioned")
            .await
        {
            error!(
                "rollback: failed to decommission unhealthy shared VM inventory {}: {e}",
                vm_row.id
            );
        }
        self.teardown_vm_resources(
            Some(&registration.draft.hostname),
            VmInstanceTeardownTarget::provider_vm_id(Some(registration.provider_vm_id)),
            &registration.draft.node_id,
            registration.region,
            VmTeardownPolicy::ContinueBestEffort,
        )
        .await;
    }

    fn build_shared_vm_draft(&self) -> SharedVmDraft {
        let shared_vm_id = Uuid::new_v4();
        let short_id = &shared_vm_id.to_string()[..8];
        let hostname = format!("{SHARED_VM_HOSTNAME_PREFIX}{short_id}.{}", self.dns_domain);

        SharedVmDraft {
            // Shared flapjack VMs expose the engine directly on port 7700.
            flapjack_url: format!("http://{hostname}:7700"),
            node_id: hostname.clone(),
            hostname,
        }
    }

    /// Canonical owner for external VM teardown. Callers still own their DB row
    /// transitions; this seam owns only provider instance, DNS, and node-key cleanup.
    pub async fn teardown_vm_resources(
        &self,
        hostname: Option<&str>,
        instance_target: VmInstanceTeardownTarget,
        node_id: &str,
        region: &str,
        policy: VmTeardownPolicy,
    ) -> VmTeardownReport {
        // Destroy the instance first so a failed retirement path does not remove
        // DNS/key evidence for a VM that may still be serving traffic.
        let instance = self.teardown_vm_instance(instance_target).await;
        if policy == VmTeardownPolicy::HaltTeardown
            && matches!(
                instance,
                VmTeardownOutcome::Failed { .. } | VmTeardownOutcome::Indeterminate { .. }
            )
        {
            return VmTeardownReport {
                instance,
                dns_record: skipped_after_instance_failure(),
                node_api_key: skipped_after_instance_failure(),
            };
        }

        VmTeardownReport {
            instance,
            dns_record: self.teardown_vm_dns_record(hostname).await,
            node_api_key: self.teardown_vm_node_api_key(node_id, region).await,
        }
    }

    async fn teardown_vm_instance(
        &self,
        instance_target: VmInstanceTeardownTarget,
    ) -> VmTeardownOutcome {
        let provider_vm_id = match instance_target {
            VmInstanceTeardownTarget::ProviderVmId(Some(provider_vm_id)) => provider_vm_id,
            VmInstanceTeardownTarget::ProviderVmId(None) => {
                return VmTeardownOutcome::NotApplicable;
            }
            VmInstanceTeardownTarget::Indeterminate { message } => {
                return VmTeardownOutcome::Indeterminate { message };
            }
        };

        match self.vm_provisioner.destroy_vm(&provider_vm_id).await {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(e) => {
                error!("teardown: failed to destroy VM {provider_vm_id}: {e}");
                VmTeardownOutcome::Failed {
                    message: e.to_string(),
                }
            }
        }
    }

    async fn teardown_vm_dns_record(&self, hostname: Option<&str>) -> VmTeardownOutcome {
        let Some(hostname) = hostname else {
            return VmTeardownOutcome::NotApplicable;
        };

        match self.dns_manager.delete_record(hostname).await {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(e) => {
                error!("teardown: failed to delete DNS record for {hostname}: {e}");
                VmTeardownOutcome::Failed {
                    message: e.to_string(),
                }
            }
        }
    }

    async fn teardown_vm_node_api_key(&self, node_id: &str, region: &str) -> VmTeardownOutcome {
        match self
            .node_secret_manager
            .delete_node_api_key(node_id, region)
            .await
        {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(e) => {
                error!("teardown: failed to delete node API keys for {node_id}: {e}");
                VmTeardownOutcome::Failed {
                    message: e.to_string(),
                }
            }
        }
    }
}

fn skipped_after_instance_failure() -> VmTeardownOutcome {
    VmTeardownOutcome::Skipped {
        reason: INSTANCE_TEARDOWN_FAILED_REASON.to_string(),
    }
}

pub(crate) fn is_canonical_shared_vm_hostname_for_domain(hostname: &str, dns_domain: &str) -> bool {
    let dns_domain = dns_domain.trim().trim_end_matches('.');
    if dns_domain.is_empty() {
        return false;
    }

    let Some(shared_name) = hostname.strip_prefix(SHARED_VM_HOSTNAME_PREFIX) else {
        return false;
    };
    let Some(short_id) = shared_name.strip_suffix(&format!(".{dns_domain}")) else {
        return false;
    };

    !short_id.is_empty() && !short_id.contains('.')
}

async fn try_local_dev_provision(
    vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
    region: &str,
    provider: &str,
) -> Result<Option<VmInventory>, ProvisioningError> {
    let local_flapjack_url_raw = match std::env::var("LOCAL_DEV_FLAPJACK_URL") {
        Ok(val) => val,
        Err(_) => return Ok(None),
    };

    let Some(local_flapjack_url) = resolve_local_dev_flapjack_url(region, &local_flapjack_url_raw)
        .map_err(ProvisioningError::ProvisionerFailed)?
    else {
        return Ok(None);
    };

    let hostname = local_dev_hostname(region);
    if let Some(existing_vm) = find_vm_by_hostname(vm_inventory_repo, &hostname).await? {
        info!(
            region = %region,
            requested_provider = %provider,
            provider = %existing_vm.provider,
            hostname = %existing_vm.hostname,
            vm_id = %existing_vm.id,
            "reused existing local development shared VM"
        );
        return Ok(Some(existing_vm));
    }

    let local_vm = match vm_inventory_repo
        .create(NewVmInventory {
            region: region.to_string(),
            provider: "local".to_string(),
            hostname: hostname.clone(),
            flapjack_url: local_flapjack_url.clone(),
            capacity: default_shared_vm_capacity(),
        })
        .await
    {
        Ok(vm) => vm,
        Err(create_error) => find_vm_by_hostname(vm_inventory_repo, &hostname)
            .await?
            .ok_or_else(|| ProvisioningError::RepoError(create_error.to_string()))?,
    };

    info!(
        region = %region,
        requested_provider = %provider,
        provider = %"local",
        hostname = %local_vm.hostname,
        vm_id = %local_vm.id,
        "auto-provisioned shared VM using local development bypass"
    );
    Ok(Some(local_vm))
}

fn local_dev_hostname(region: &str) -> String {
    format!("local-dev-{region}")
}

async fn find_vm_by_hostname(
    vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
    hostname: &str,
) -> Result<Option<VmInventory>, ProvisioningError> {
    vm_inventory_repo
        .find_by_hostname(hostname)
        .await
        .map_err(|e| ProvisioningError::RepoError(e.to_string()))
}

/// Resolve the URL used by the local shared-VM bypass.
///
/// Region-specific `FLAPJACK_REGIONS` entries are treated as explicit local
/// topology configuration and therefore return validation errors when malformed.
/// The fallback `LOCAL_DEV_FLAPJACK_URL` is best-effort: blank or non-loopback
/// values simply disable the bypass so the normal provisioner path reports the
/// real configuration state.
fn resolve_local_dev_flapjack_url(
    region: &str,
    fallback_raw_url: &str,
) -> Result<Option<String>, String> {
    if std::env::var("FLAPJACK_SINGLE_INSTANCE").ok().as_deref() != Some("1") {
        if let Some(region_specific_url) = resolve_region_flapjack_url_from_env(
            region,
            std::env::var("FLAPJACK_REGIONS").ok().as_deref(),
        )? {
            return Ok(Some(region_specific_url));
        }
    }

    // Invalid or blank fallback URLs should disable only the local-dev bypass.
    // That keeps the real provisioner path responsible for configuration
    // failures instead of letting a stray developer env var shadow production.
    Ok(normalize_local_dev_flapjack_url(fallback_raw_url))
}

fn resolve_region_flapjack_url_from_env(
    region: &str,
    flapjack_regions_raw: Option<&str>,
) -> Result<Option<String>, String> {
    let Some(flapjack_regions_raw) = flapjack_regions_raw else {
        return Ok(None);
    };
    for region_port in flapjack_regions_raw.split_whitespace() {
        let Some((candidate_region, candidate_port)) = region_port.split_once(':') else {
            continue;
        };
        if candidate_region == region {
            let port = parse_flapjack_region_port(candidate_port).ok_or_else(|| {
                format!(
                    "FLAPJACK_REGIONS entry for {region} must use a numeric TCP port between 1 and 65535"
                )
            })?;
            return Ok(Some(format!("http://127.0.0.1:{port}")));
        }
    }

    Ok(None)
}

fn parse_flapjack_region_port(candidate_port: &str) -> Option<u16> {
    let trimmed = candidate_port.trim();
    if trimmed.is_empty() || !trimmed.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }

    trimmed.parse::<u16>().ok().filter(|port| *port > 0)
}

/// Validates and normalizes a `LOCAL_DEV_FLAPJACK_URL` value. Accepts only
/// `http`/`https` URLs pointing to a loopback address, with no embedded
/// credentials. Strips trailing slashes but preserves query and fragment.
pub(crate) fn normalize_local_dev_flapjack_url(raw_url: &str) -> Option<String> {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return None;
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
        return None;
    }

    let parsed = Url::parse(normalized_base).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return None;
    }
    if !parsed.username().is_empty() || parsed.password().is_some() {
        return None;
    }

    let host = parsed.host_str()?;
    if !is_local_dev_host(host) {
        return None;
    }

    Some(format!("{normalized_base}{suffix}"))
}

pub(super) fn ensure_supported_vm_provider(vm_provider: &str) -> Result<(), ProvisioningError> {
    match vm_provider {
        "aws" | "hetzner" | "gcp" | "oci" | "bare_metal" => Ok(()),
        _ => Err(ProvisioningError::ProvisionerFailed(format!(
            "unsupported VM provider '{vm_provider}'"
        ))),
    }
}

fn is_local_dev_host(host: &str) -> bool {
    if host == "localhost" {
        return true;
    }

    match host.parse::<std::net::IpAddr>() {
        Ok(ip) => ip.is_loopback(),
        Err(_) => false,
    }
}

/// Creates a [`CreateVmRequest`] for a shared VM with provider-appropriate
/// user-data and the default VM type for the given provider.
fn build_shared_vm_request(
    draft: &SharedVmDraft,
    provider: &str,
    region: &str,
    api_key: &str,
) -> CreateVmRequest {
    let user_data = build_user_data(
        provider,
        &Uuid::nil().to_string(),
        &draft.node_id,
        region,
        api_key,
    );

    CreateVmRequest {
        region: region.to_string(),
        vm_type: default_shared_vm_type(provider).to_string(),
        hostname: draft.hostname.clone(),
        customer_id: Uuid::nil(),
        node_id: draft.node_id.clone(),
        user_data: Some(user_data),
    }
}

fn default_shared_vm_type(provider: &str) -> &'static str {
    match provider {
        "aws" => DEFAULT_SHARED_VM_TYPE_AWS,
        "hetzner" => DEFAULT_SHARED_VM_TYPE_HETZNER,
        "gcp" => DEFAULT_SHARED_VM_TYPE_GCP,
        "oci" => DEFAULT_SHARED_VM_TYPE_OCI,
        _ => DEFAULT_SHARED_VM_TYPE_FALLBACK,
    }
}

fn default_shared_vm_capacity() -> serde_json::Value {
    serde_json::json!({
        "cpu_weight": 4.0,
        "mem_rss_bytes": 8_589_934_592_u64,
        "disk_bytes": 107_374_182_400_u64,
        "query_rps": 500.0,
        "indexing_rps": 200.0
    })
}

/// Build provider-appropriate cloud-init user-data.
///
/// - **AWS:** fetches secrets from SSM Parameter Store at boot (no secrets in user-data).
/// - **Hetzner:** receives secrets directly via cloud-init (Hetzner API is HTTPS;
///   on-disk user-data is stored at 0600 root by cloud-init).
pub(crate) fn build_user_data(
    vm_provider: &str,
    customer_id: &str,
    node_id: &str,
    region: &str,
    api_key: &str,
) -> String {
    let environment = std::env::var("ENVIRONMENT").unwrap_or_else(|_| "unknown".to_string());
    let secrets = match vm_provider {
        "aws" => SecretDelivery::AwsSsm {
            region: region.to_string(),
        },
        // Supported non-AWS providers use direct secret delivery via cloud-init.
        // (bare_metal is a real SSH-pool provider — vm_providers::BARE_METAL_VM_PROVIDER,
        // registered in startup.rs; it was dropped from this allowlist by 0623f9f9cf.)
        "hetzner" | "gcp" | "oci" | "bare_metal" => {
            let db_url = std::env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://localhost/fjcloud".to_string());
            SecretDelivery::Direct {
                db_url,
                api_key: api_key.to_string(),
            }
        }
        _ => unreachable!("unsupported providers are rejected before user-data generation"),
    };

    cloud_init::generate_cloud_init(&CloudInitParams {
        customer_id: customer_id.to_string(),
        node_id: node_id.to_string(),
        region: region.to_string(),
        environment,
        secrets,
    })
}

#[cfg(test)]
mod security_tests {
    use super::*;

    #[test]
    fn unsupported_provider_is_rejected_before_secret_delivery() {
        let error = ensure_supported_vm_provider("custom-provider")
            .expect_err("unsupported provider must be rejected");

        match error {
            ProvisioningError::ProvisionerFailed(message) => {
                assert!(message.contains("unsupported VM provider 'custom-provider'"));
            }
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn supported_providers_are_accepted() {
        for provider in ["aws", "hetzner", "gcp", "oci"] {
            ensure_supported_vm_provider(provider)
                .unwrap_or_else(|error| panic!("supported provider {provider} failed: {error}"));
            let user_data = build_user_data(provider, "cust", "node", "iad", "secret");
            assert!(
                !user_data.is_empty(),
                "supported provider {provider} must produce user-data"
            );
        }
    }
}

#[cfg(test)]
mod tests;
