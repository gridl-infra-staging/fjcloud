#![allow(clippy::await_holding_lock)]

use super::*;

#[test]
fn build_user_data_aws_uses_ssm() {
    let _env_guard = EnvVarGuard::set("ENVIRONMENT", Some("staging"));
    let script = build_user_data("aws", "cust-123", "node-abc", "us-east-1", "fj_live_key");

    assert!(script.contains("CUSTOMER_ID='cust-123'"));
    assert!(script.contains("NODE_ID='node-abc'"));
    assert!(script.contains("REGION='us-east-1'"));
    assert!(script.contains("ENVIRONMENT='staging'"));
    assert!(
        script.contains("aws ssm get-parameter"),
        "AWS user-data must fetch secrets from SSM at boot"
    );
    assert!(
        script.contains("/fjcloud/$ENVIRONMENT/database_url"),
        "AWS user-data must fetch the env-scoped database URL"
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

    async fn create(&self, new_vm: NewVmInventory) -> Result<VmInventory, crate::repos::RepoError> {
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

    async fn set_status(&self, _id: Uuid, _status: &str) -> Result<(), crate::repos::RepoError> {
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
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
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
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
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
    let _local_guard = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", Some("http://127.0.0.1:6333"));
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
