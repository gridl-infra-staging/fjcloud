use crate::models::vm_inventory::{NewVmInventory, VmInventory};
use crate::provisioner::cloud_init::{self, CloudInitParams, SecretDelivery};
use crate::provisioner::CreateVmRequest;
use crate::repos::VmInventoryRepo;
use reqwest::Url;
use tracing::info;
use uuid::Uuid;

use super::{ProvisioningError, ProvisioningService};

const DEFAULT_SHARED_VM_TYPE_AWS: &str = "t4g.small";
const DEFAULT_SHARED_VM_TYPE_HETZNER: &str = "cpx31";
const DEFAULT_SHARED_VM_TYPE_GCP: &str = "e2-standard-2";
const DEFAULT_SHARED_VM_TYPE_OCI: &str = "VM.Standard.A1.Flex";
const DEFAULT_SHARED_VM_TYPE_FALLBACK: &str = "shared";

struct SharedVmDraft {
    hostname: String,
    flapjack_url: String,
    node_id: String,
}

impl ProvisioningService {
    pub async fn auto_provision_shared_vm(
        &self,
        vm_inventory_repo: &(dyn VmInventoryRepo + Send + Sync),
        region: &str,
        provider: &str,
    ) -> Result<VmInventory, ProvisioningError> {
        if let Some(vm) = try_local_dev_provision(vm_inventory_repo, region, provider).await? {
            return Ok(vm);
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
                self.cleanup_shared_vm_secret(&draft.node_id, region).await;
                return Err(ProvisioningError::ProvisionerFailed(e.to_string()));
            }
        };

        let ip = match vm_instance.public_ip.as_deref() {
            Some(ip) => ip,
            None => {
                self.cleanup_shared_vm_instance(
                    &vm_instance.provider_vm_id,
                    &draft.node_id,
                    region,
                )
                .await;
                return Err(ProvisioningError::ProvisionerFailed(
                    "VM created without public IP".into(),
                ));
            }
        };

        if let Err(e) = self.dns_manager.create_record(&draft.hostname, ip).await {
            self.cleanup_shared_vm_instance(&vm_instance.provider_vm_id, &draft.node_id, region)
                .await;
            return Err(ProvisioningError::DnsFailed(e.to_string()));
        }

        let vm_row = match vm_inventory_repo
            .create(NewVmInventory {
                region: region.to_string(),
                provider: provider.to_string(),
                hostname: draft.hostname.clone(),
                flapjack_url: draft.flapjack_url.clone(),
                capacity: default_shared_vm_capacity(),
            })
            .await
        {
            Ok(vm) => vm,
            Err(e) => {
                self.cleanup_failed_shared_vm_registration(
                    &draft.hostname,
                    &vm_instance.provider_vm_id,
                    &draft.node_id,
                    region,
                )
                .await;
                return Err(ProvisioningError::RepoError(e.to_string()));
            }
        };

        info!(
            region = %region,
            provider = %provider,
            hostname = %draft.hostname,
            vm_id = %vm_row.id,
            "auto-provisioned shared VM for capacity fallback"
        );

        Ok(vm_row)
    }

    fn build_shared_vm_draft(&self) -> SharedVmDraft {
        let shared_vm_id = Uuid::new_v4();
        let short_id = &shared_vm_id.to_string()[..8];
        let hostname = format!("vm-shared-{short_id}.{}", self.dns_domain);

        SharedVmDraft {
            // Shared flapjack VMs expose the engine directly on port 7700.
            flapjack_url: format!("http://{hostname}:7700"),
            node_id: hostname.clone(),
            hostname,
        }
    }

    async fn cleanup_shared_vm_secret(&self, node_id: &str, region: &str) {
        let _ = self
            .node_secret_manager
            .delete_node_api_key(node_id, region)
            .await;
    }

    async fn cleanup_shared_vm_instance(&self, provider_vm_id: &str, node_id: &str, region: &str) {
        let _ = self.vm_provisioner.destroy_vm(provider_vm_id).await;
        self.cleanup_shared_vm_secret(node_id, region).await;
    }

    async fn cleanup_failed_shared_vm_registration(
        &self,
        hostname: &str,
        provider_vm_id: &str,
        node_id: &str,
        region: &str,
    ) {
        let _ = self.dns_manager.delete_record(hostname).await;
        self.cleanup_shared_vm_instance(provider_vm_id, node_id, region)
            .await;
    }
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
fn normalize_local_dev_flapjack_url(raw_url: &str) -> Option<String> {
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
        // All non-AWS providers use direct secret delivery via cloud-init
        _ => {
            let db_url = std::env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://localhost/fjcloud".to_string());
            SecretDelivery::Direct {
                db_url,
                api_key: api_key.to_string(),
            }
        }
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
mod tests;
