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
            flapjack_url: format!("https://{hostname}"),
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
        secrets,
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::await_holding_lock)]

    use super::*;

    #[test]
    fn build_user_data_aws_uses_ssm() {
        let script = build_user_data("aws", "cust-123", "node-abc", "us-east-1", "fj_live_key");

        assert!(script.contains("CUSTOMER_ID='cust-123'"));
        assert!(script.contains("NODE_ID='node-abc'"));
        assert!(script.contains("REGION='us-east-1'"));
        assert!(
            script.contains("aws ssm get-parameter"),
            "AWS user-data must fetch secrets from SSM at boot"
        );
        assert!(
            !script.contains("fj_live_key"),
            "AWS user-data must NOT embed API key — SSM delivers it at boot"
        );
    }

    /// Verifies that Hetzner user-data embeds the API key directly via
    /// cloud-init and does not reference AWS SSM.
    #[test]
    fn build_user_data_hetzner_uses_direct_secrets() {
        let script = build_user_data(
            "hetzner",
            "cust-456",
            "node-xyz",
            "eu-central-1",
            "fj_live_htz",
        );

        assert!(script.contains("CUSTOMER_ID='cust-456'"));
        assert!(script.contains("NODE_ID='node-xyz'"));
        assert!(script.contains("REGION='eu-central-1'"));
        assert!(
            !script.contains("aws ssm"),
            "Hetzner user-data must NOT reference AWS SSM"
        );
        assert!(
            script.contains("fj_live_htz"),
            "Hetzner user-data must embed the API key directly"
        );
    }

    /// Verifies that GCP user-data embeds the API key directly and does
    /// not reference AWS SSM.
    #[test]
    fn build_user_data_gcp_uses_direct_secrets() {
        let script = build_user_data(
            "gcp",
            "cust-789",
            "node-gcp",
            "us-central1-a",
            "fj_live_gcp",
        );

        assert!(script.contains("CUSTOMER_ID='cust-789'"));
        assert!(script.contains("NODE_ID='node-gcp'"));
        assert!(script.contains("REGION='us-central1-a'"));
        assert!(
            !script.contains("aws ssm"),
            "GCP user-data must NOT reference AWS SSM"
        );
        assert!(
            script.contains("fj_live_gcp"),
            "GCP user-data must embed the API key directly"
        );
    }

    /// Verifies that OCI user-data embeds the API key directly and does
    /// not reference AWS SSM.
    #[test]
    fn build_user_data_oci_uses_direct_secrets() {
        let script = build_user_data(
            "oci",
            "cust-oci",
            "node-oci",
            "Uocm:US-ASHBURN-AD-1",
            "fj_live_oci",
        );

        assert!(script.contains("CUSTOMER_ID='cust-oci'"));
        assert!(script.contains("NODE_ID='node-oci'"));
        assert!(script.contains("REGION='Uocm:US-ASHBURN-AD-1'"));
        assert!(
            !script.contains("aws ssm"),
            "OCI user-data must NOT reference AWS SSM"
        );
        assert!(
            script.contains("fj_live_oci"),
            "OCI user-data must embed the API key directly"
        );
    }

    /// Verifies that bare-metal user-data embeds the API key directly and
    /// does not reference AWS SSM.
    #[test]
    fn build_user_data_bare_metal_uses_direct_secrets() {
        let script = build_user_data(
            "bare_metal",
            "cust-bm",
            "node-bm",
            "eu-central-bm",
            "fj_live_bm",
        );

        assert!(script.contains("CUSTOMER_ID='cust-bm'"));
        assert!(script.contains("NODE_ID='node-bm'"));
        assert!(script.contains("REGION='eu-central-bm'"));
        assert!(
            !script.contains("aws ssm"),
            "bare_metal user-data must NOT reference AWS SSM"
        );
        assert!(
            script.contains("fj_live_bm"),
            "bare_metal user-data must embed the API key directly"
        );
    }

    #[test]
    fn build_user_data_starts_systemd_services() {
        for provider in &["aws", "hetzner", "gcp", "oci", "bare_metal"] {
            let script = build_user_data(provider, "c", "n", "r", "k");
            assert!(
                script.contains("systemctl start flapjack"),
                "{provider}: must start flapjack service"
            );
            assert!(
                script.contains("fj-metering-agent"),
                "{provider}: must manage metering agent service"
            );
        }
    }

    #[test]
    fn build_user_data_sets_secure_permissions() {
        for provider in &["aws", "hetzner", "gcp", "oci", "bare_metal"] {
            let script = build_user_data(provider, "c", "n", "r", "k");
            assert!(
                script.contains("chmod 600"),
                "{provider}: env files must have restricted permissions"
            );
            assert!(
                script.contains("chown flapjack:flapjack"),
                "{provider}: env files must be owned by flapjack user"
            );
        }
    }

    #[test]
    fn build_user_data_includes_logging() {
        for provider in &["aws", "hetzner", "gcp", "oci", "bare_metal"] {
            let script = build_user_data(provider, "c", "n", "r", "k");
            assert!(
                script.contains("logger -t"),
                "{provider}: user-data must log to syslog"
            );
        }
    }

    /// Confirms that all providers set the correct metering env var names
    /// (`DATABASE_URL`, `FLAPJACK_URL`, etc.) without a `METERING_` prefix.
    #[test]
    fn build_user_data_metering_env_uses_correct_var_names() {
        for provider in &["aws", "hetzner", "gcp", "oci", "bare_metal"] {
            let script = build_user_data(provider, "c", "n", "r", "k");
            assert!(
                script.contains("DATABASE_URL="),
                "{provider}: must set DATABASE_URL"
            );
            assert!(
                script.contains("FLAPJACK_URL="),
                "{provider}: must set FLAPJACK_URL"
            );
            assert!(
                script.contains("FLAPJACK_API_KEY="),
                "{provider}: must set FLAPJACK_API_KEY"
            );
            assert!(
                script.contains("CUSTOMER_ID="),
                "{provider}: must set CUSTOMER_ID"
            );
            assert!(script.contains("NODE_ID="), "{provider}: must set NODE_ID");
            assert!(
                !script.contains("METERING_"),
                "{provider}: must not use METERING_ prefix"
            );
        }
    }

    #[test]
    fn default_shared_vm_type_maps_known_providers() {
        assert_eq!(default_shared_vm_type("aws"), "t4g.small");
        assert_eq!(default_shared_vm_type("hetzner"), "cpx31");
        assert_eq!(default_shared_vm_type("gcp"), "e2-standard-2");
        assert_eq!(default_shared_vm_type("oci"), "VM.Standard.A1.Flex");
        assert_eq!(default_shared_vm_type("other"), "shared");
    }

    #[test]
    fn build_user_data_capacity_has_required_fields() {
        let capacity = default_shared_vm_capacity();
        assert_eq!(capacity["cpu_weight"], 4.0);
        assert_eq!(capacity["query_rps"], 500.0);
    }

    // -- try_local_dev_provision tests ----------------------------------------

    use std::sync::Mutex;

    /// Serializes tests that mutate local-dev topology env vars (process-global).
    static LOCAL_DEV_ENV_LOCK: Mutex<()> = Mutex::new(());

    /// RAII guard that sets an env var for the test and restores the previous
    /// value on drop. Same pattern used in provisioning.rs tests.
    struct EnvVarGuard {
        key: &'static str,
        previous: Option<String>,
    }

    impl EnvVarGuard {
        fn set(key: &'static str, value: Option<&str>) -> Self {
            let previous = std::env::var(key).ok();
            match value {
                Some(v) => unsafe { std::env::set_var(key, v) },
                None => unsafe { std::env::remove_var(key) },
            }
            Self { key, previous }
        }
    }

    impl Drop for EnvVarGuard {
        fn drop(&mut self) {
            match &self.previous {
                Some(val) => unsafe { std::env::set_var(self.key, val) },
                None => unsafe { std::env::remove_var(self.key) },
            }
        }
    }

    fn clear_local_dev_topology_env() -> (EnvVarGuard, EnvVarGuard) {
        (
            EnvVarGuard::set("FLAPJACK_REGIONS", None),
            EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None),
        )
    }

    /// Minimal in-memory VmInventoryRepo mock for unit tests.
    struct InMemoryVmRepo {
        vms: Mutex<Vec<VmInventory>>,
    }

    impl InMemoryVmRepo {
        fn new() -> Self {
            Self {
                vms: Mutex::new(Vec::new()),
            }
        }

        fn with_vm(vm: VmInventory) -> Self {
            Self {
                vms: Mutex::new(vec![vm]),
            }
        }

        fn make_vm(hostname: &str, region: &str) -> VmInventory {
            VmInventory {
                id: Uuid::new_v4(),
                region: region.to_string(),
                provider: "local".to_string(),
                hostname: hostname.to_string(),
                flapjack_url: "http://127.0.0.1:6333".to_string(),
                capacity: serde_json::json!({}),
                current_load: serde_json::json!({}),
                load_scraped_at: None,
                status: "active".to_string(),
                created_at: chrono::Utc::now(),
                updated_at: chrono::Utc::now(),
            }
        }
    }

    #[async_trait::async_trait]
    impl VmInventoryRepo for InMemoryVmRepo {
        async fn list_active(
            &self,
            _region: Option<&str>,
        ) -> Result<Vec<VmInventory>, crate::repos::RepoError> {
            Ok(self.vms.lock().unwrap().clone())
        }

        async fn get(&self, id: Uuid) -> Result<Option<VmInventory>, crate::repos::RepoError> {
            Ok(self
                .vms
                .lock()
                .unwrap()
                .iter()
                .find(|v| v.id == id)
                .cloned())
        }

        async fn create(
            &self,
            new_vm: NewVmInventory,
        ) -> Result<VmInventory, crate::repos::RepoError> {
            let vm = VmInventory {
                id: Uuid::new_v4(),
                region: new_vm.region,
                provider: new_vm.provider,
                hostname: new_vm.hostname,
                flapjack_url: new_vm.flapjack_url,
                capacity: new_vm.capacity,
                current_load: serde_json::json!({}),
                load_scraped_at: None,
                status: "active".to_string(),
                created_at: chrono::Utc::now(),
                updated_at: chrono::Utc::now(),
            };
            self.vms.lock().unwrap().push(vm.clone());
            Ok(vm)
        }

        async fn update_load(
            &self,
            _id: Uuid,
            _load: serde_json::Value,
        ) -> Result<(), crate::repos::RepoError> {
            Ok(())
        }

        async fn set_status(
            &self,
            _id: Uuid,
            _status: &str,
        ) -> Result<(), crate::repos::RepoError> {
            Ok(())
        }

        async fn find_by_hostname(
            &self,
            hostname: &str,
        ) -> Result<Option<VmInventory>, crate::repos::RepoError> {
            Ok(self
                .vms
                .lock()
                .unwrap()
                .iter()
                .find(|v| v.hostname == hostname)
                .cloned())
        }
    }

    #[tokio::test]
    async fn try_local_dev_provision_reuses_existing_vm() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
        let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
        let existing = InMemoryVmRepo::make_vm("local-dev-us-east-1", "us-east-1");
        let expected_id = existing.id;
        let repo = InMemoryVmRepo::with_vm(existing);

        let result = try_local_dev_provision(&repo, "us-east-1", "aws")
            .await
            .expect("should succeed");

        let vm = result.expect("should return Some(vm)");
        assert_eq!(vm.id, expected_id, "should reuse the existing VM");
        assert_eq!(vm.hostname, "local-dev-us-east-1");
    }

    #[tokio::test]
    async fn try_local_dev_provision_creates_new_vm() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
        let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
        let repo = InMemoryVmRepo::new();

        let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
            .await
            .expect("should succeed");

        let vm = result.expect("should return Some(vm)");
        assert_eq!(vm.hostname, "local-dev-eu-west-1");
        assert_eq!(vm.provider, "local");
        assert_eq!(vm.flapjack_url, "http://127.0.0.1:6333");
        // Verify the VM was persisted in the repo
        assert_eq!(repo.vms.lock().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn try_local_dev_provision_prefers_region_specific_url_from_flapjack_regions() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None);
        let _local_guard =
            EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
        let _regions_guard = EnvVarGuard::set(
            "FLAPJACK_REGIONS",
            Some("us-east-1:7700 eu-west-1:7701 eu-central-1:7702"),
        );
        let repo = InMemoryVmRepo::new();

        let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
            .await
            .expect("should succeed");

        let vm = result.expect("should return Some(vm)");
        assert_eq!(vm.hostname, "local-dev-eu-west-1");
        assert_eq!(
            vm.flapjack_url, "http://127.0.0.1:7701",
            "should use the target region port instead of the shared LOCAL_DEV_FLAPJACK_URL"
        );
    }

    #[tokio::test]
    async fn try_local_dev_provision_ignores_region_specific_urls_when_single_instance_is_forced() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let _local_guard =
            EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
        let _regions_guard = EnvVarGuard::set(
            "FLAPJACK_REGIONS",
            Some("us-east-1:7700 eu-west-1:7701 eu-central-1:7702"),
        );
        let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", Some("1"));
        let repo = InMemoryVmRepo::new();

        let result = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
            .await
            .expect("should succeed");

        let vm = result.expect("should return Some(vm)");
        assert_eq!(vm.hostname, "local-dev-eu-west-1");
        assert_eq!(
            vm.flapjack_url, "http://127.0.0.1:6333",
            "single-instance mode should keep using LOCAL_DEV_FLAPJACK_URL"
        );
    }

    #[tokio::test]
    async fn try_local_dev_provision_returns_none_without_env_var() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
        let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", None);
        let repo = InMemoryVmRepo::new();

        let result = try_local_dev_provision(&repo, "us-east-1", "aws")
            .await
            .expect("should succeed");

        assert!(result.is_none(), "should return None when env var is unset");
    }

    #[tokio::test]
    async fn try_local_dev_provision_ignores_invalid_local_dev_url() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let (_regions_guard, _single_instance_guard) = clear_local_dev_topology_env();
        let _guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("https://example.com"));
        let repo = InMemoryVmRepo::new();

        let result = try_local_dev_provision(&repo, "us-east-1", "aws")
            .await
            .expect("invalid fallback URL should leave the real provisioner path in charge");

        assert!(
            result.is_none(),
            "invalid fallback URL must not activate the local-dev bypass"
        );
    }

    #[tokio::test]
    async fn try_local_dev_provision_errors_on_invalid_region_specific_port() {
        let _lock = LOCAL_DEV_ENV_LOCK.lock().unwrap();
        let _local_guard =
            EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
        let _regions_guard = EnvVarGuard::set(
            "FLAPJACK_REGIONS",
            Some("us-east-1:7700 eu-west-1:7701@evil.test"),
        );
        let _single_instance_guard = EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None);
        let repo = InMemoryVmRepo::new();

        let err = try_local_dev_provision(&repo, "eu-west-1", "hetzner")
            .await
            .expect_err("should reject non-numeric FLAPJACK_REGIONS ports");

        assert!(
            err.to_string().contains("FLAPJACK_REGIONS"),
            "error should explain the invalid region-specific flapjack contract"
        );
    }
}
