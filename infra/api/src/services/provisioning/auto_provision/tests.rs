#![allow(clippy::await_holding_lock)]

use super::*;
use crate::vm_providers::VALID_VM_PROVIDERS;

const MANAGED_SHARED_VM_PROVIDERS: &[&str] = &["aws"];
const DISABLED_MANAGED_SHARED_VM_PROVIDERS: &[&str] = &["hetzner", "gcp", "oci", "bare_metal"];

fn assert_caddy_runtime_present(script: &str, hostname: &str) {
    assert!(script.contains(&format!("CADDY_SERVED_HOSTNAME='{hostname}'")));
    assert!(script.contains("cat > /etc/caddy/Caddyfile <<CADDYEOF"));
    assert!(script.contains("$served_hostname {"));
    assert!(script.contains("reverse_proxy 127.0.0.1:7700"));
    assert!(script.contains("systemctl enable --now caddy"));
    assert!(script.contains("systemctl reload-or-restart caddy"));
}

fn expect_disabled_managed_provider(provider: &str) {
    let draft = SharedVmDraft {
        hostname: "vm-shared-disabled.example.com".to_string(),
        flapjack_url: "http://vm-shared-disabled.example.com:7700".to_string(),
        node_id: "node-disabled".to_string(),
    };
    let error = build_shared_vm_request(&draft, provider, "region", "fj_live_secret")
        .expect_err("non-AWS managed shared VM provisioning must stay disabled");
    assert!(
        matches!(error, ProvisioningError::ProvisionerFailed(ref message) if message.contains("embed live credentials in user-data")),
        "{provider}: expected credential-exposure guardrail, got {error}"
    );
}

fn assert_core_flapjack_and_metering_script(script: &str) {
    assert!(script.contains("cat > /etc/flapjack/env <<ENVEOF"));
    assert!(script.contains("cat > /etc/fjcloud/metering-env <<ENVEOF"));
    assert!(script.contains("FLAPJACK_API_KEY=$API_KEY"));
    assert!(script.contains("FLAPJACK_ADMIN_KEY=$API_KEY"));
    assert!(script.contains("FLAPJACK_BIND_ADDR=0.0.0.0:7700"));
    assert!(script.contains("FLAPJACK_URL=http://$NODE_ID:7700"));
    assert!(script.contains("systemctl enable --now flapjack fj-metering-agent"));
}

#[test]
fn build_user_data_aws_uses_ssm() {
    let _env_guard = EnvVarGuard::set("ENVIRONMENT", Some("staging"));
    let script = build_user_data(
        "aws",
        "cust-123",
        "node-abc",
        "us-east-1",
        "fj_live_key",
        "vm-abc.example.com",
    );

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

/// Verifies that managed Hetzner shared VM provisioning is rejected
/// before user-data generation can embed live credentials.
#[test]
fn build_user_data_hetzner_is_rejected() {
    expect_disabled_managed_provider("hetzner");
}

/// Verifies that managed GCP shared VM provisioning is rejected before
/// user-data generation can embed live credentials.
#[test]
fn build_user_data_gcp_is_rejected() {
    expect_disabled_managed_provider("gcp");
}

/// Verifies that managed OCI shared VM provisioning is rejected before
/// user-data generation can embed live credentials.
#[test]
fn build_user_data_oci_is_rejected() {
    expect_disabled_managed_provider("oci");
}

/// Verifies that managed bare-metal shared VM provisioning is rejected
/// before user-data generation can embed live credentials.
#[test]
fn build_user_data_bare_metal_is_rejected() {
    expect_disabled_managed_provider("bare_metal");
}

#[test]
fn build_user_data_starts_systemd_services() {
    for provider in MANAGED_SHARED_VM_PROVIDERS {
        let script = build_user_data(provider, "c", "n", "r", "k", "vm-test.example.com");
        assert!(
            script.contains("systemctl enable --now flapjack fj-metering-agent"),
            "{provider}: must atomically enable and start flapjack services"
        );
        assert!(
            script.contains("fj-metering-agent"),
            "{provider}: must manage metering agent service"
        );
    }
}

#[test]
fn build_user_data_sets_secure_permissions() {
    for provider in MANAGED_SHARED_VM_PROVIDERS {
        let script = build_user_data(provider, "c", "n", "r", "k", "vm-test.example.com");
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
    for provider in MANAGED_SHARED_VM_PROVIDERS {
        let script = build_user_data(provider, "c", "n", "r", "k", "vm-test.example.com");
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
    for provider in MANAGED_SHARED_VM_PROVIDERS {
        let script = build_user_data(provider, "c", "n", "r", "k", "vm-test.example.com");
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
fn build_user_data_limits_caddy_runtime_to_aws() {
    assert_eq!(
        VALID_VM_PROVIDERS,
        &["aws", "hetzner", "gcp", "oci", "bare_metal"]
    );

    for provider in MANAGED_SHARED_VM_PROVIDERS {
        let script = build_user_data(
            provider,
            "cust-canonical",
            "node-canonical",
            "us-east-1",
            "fj_live_secret",
            "vm-canonical.example.com",
        );

        assert!(
            script.contains("aws ssm get-parameter"),
            "AWS user-data must keep SSM secret delivery"
        );
        assert!(
            !script.contains("fj_live_secret"),
            "AWS user-data must not embed the API key"
        );
        assert_core_flapjack_and_metering_script(&script);
        assert_caddy_runtime_present(&script, "vm-canonical.example.com");
    }

    for provider in DISABLED_MANAGED_SHARED_VM_PROVIDERS {
        expect_disabled_managed_provider(provider);
    }
}

#[test]
fn build_shared_vm_request_passes_request_hostname_to_user_data() {
    let draft = SharedVmDraft {
        hostname: "vm-shared-canonical.example.com".to_string(),
        flapjack_url: "http://vm-shared-canonical.example.com:7700".to_string(),
        node_id: "node-shared-canonical".to_string(),
    };

    let request = build_shared_vm_request(&draft, "aws", "us-east-1", "fj_live_secret")
        .expect("aws managed shared VM request should build");
    let script = request
        .user_data
        .expect("shared VM request should include user-data");

    assert_eq!(request.hostname, "vm-shared-canonical.example.com");
    assert!(script.contains("NODE_ID='node-shared-canonical'"));
    assert!(script.contains("CADDY_SERVED_HOSTNAME='vm-shared-canonical.example.com'"));
    assert!(script.contains("$served_hostname {"));
    assert!(script.contains("FLAPJACK_URL=http://$NODE_ID:7700"));
    assert!(!script.contains("fj_live_secret"));
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
fn shared_vm_draft_routes_durable_urls_through_transport_policy() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();
    let canonical_hostname = "vm-shared-canonical.flapjack.foo";

    let tls_off_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("false"));
    let draft = shared_vm_draft(
        "aws",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: canonical_hostname.to_string(),
            node_id: canonical_hostname.to_string(),
        }),
    )
    .expect("canonical durable draft should succeed");
    assert_eq!(draft.hostname, canonical_hostname);
    assert_eq!(
        draft.flapjack_url,
        "http://vm-shared-canonical.flapjack.foo:7700"
    );
    assert_eq!(draft.node_id, canonical_hostname);
    drop(tls_off_guard);

    let tls_on_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("true"));
    let draft = shared_vm_draft(
        "aws",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: canonical_hostname.to_string(),
            node_id: canonical_hostname.to_string(),
        }),
    )
    .expect("canonical durable draft should succeed");
    assert_eq!(draft.hostname, canonical_hostname);
    assert_eq!(
        draft.flapjack_url,
        "https://vm-shared-canonical.flapjack.foo"
    );
    assert_eq!(draft.node_id, canonical_hostname);

    let draft = shared_vm_draft(
        "hetzner",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: canonical_hostname.to_string(),
            node_id: canonical_hostname.to_string(),
        }),
    )
    .expect("canonical durable draft should succeed");
    assert_eq!(draft.hostname, canonical_hostname);
    assert_eq!(
        draft.flapjack_url,
        "http://vm-shared-canonical.flapjack.foo:7700"
    );
    assert_eq!(draft.node_id, canonical_hostname);
    drop(tls_on_guard);
}

#[test]
fn shared_vm_draft_builds_fresh_cleartext_identity() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();
    let _tls_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", None);

    let draft = shared_vm_draft("aws", "flapjack.foo", None).expect("fresh draft should succeed");

    assert_eq!(draft.flapjack_url, engine_base_url("aws", &draft.hostname));
    assert!(draft.flapjack_url.starts_with("http://vm-shared-"));
    assert!(draft.flapjack_url.ends_with(":7700"));
    assert_eq!(draft.node_id, draft.hostname);
}

#[test]
fn shared_vm_draft_rejects_non_canonical_durable_identity() {
    let error = shared_vm_draft(
        "aws",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: "evil.example.com".to_string(),
            node_id: "evil.example.com".to_string(),
        }),
    )
    .expect_err("non-canonical durable hostnames must be rejected");
    assert!(matches!(error, ProvisioningError::InvalidState(message)
        if message == "durable shared VM hostname 'evil.example.com' is not canonical for DNS domain 'flapjack.foo'"));

    let error = shared_vm_draft(
        "aws",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: "vm-shared-abcd1234.flapjack.foo".to_string(),
            node_id: "node-x".to_string(),
        }),
    )
    .expect_err("durable node_id must stay aligned with the canonical hostname");
    assert!(matches!(error, ProvisioningError::InvalidState(message)
        if message == "durable shared VM node_id 'node-x' must match hostname 'vm-shared-abcd1234.flapjack.foo'"));
}

#[test]
fn durable_shared_vm_recovery_rehydrates_existing_row_url() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();
    let _tls_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("true"));
    let stale_vm = InMemoryVmRepo::make_vm("vm-shared-canonical.flapjack.foo", "us-east-1")
        .with_provider("aws", "http://vm-shared-canonical.flapjack.foo:7700");
    let draft = shared_vm_draft(
        "aws",
        "flapjack.foo",
        Some(DurableSharedVmDraft {
            hostname: "vm-shared-canonical.flapjack.foo".to_string(),
            node_id: "vm-shared-canonical.flapjack.foo".to_string(),
        }),
    )
    .expect("canonical durable draft should succeed");

    let vm = rehydrate_existing_shared_vm(stale_vm, &draft, "aws")
        .expect("matching stored and requested providers should rehydrate");

    assert_eq!(vm.hostname, "vm-shared-canonical.flapjack.foo");
    assert_eq!(vm.provider, "aws");
    assert_eq!(vm.flapjack_url, "https://vm-shared-canonical.flapjack.foo");

    let mismatched_vm = InMemoryVmRepo::make_vm("vm-shared-canonical.flapjack.foo", "us-east-1")
        .with_provider("hetzner", "http://vm-shared-canonical.flapjack.foo:7700");
    let error = rehydrate_existing_shared_vm(mismatched_vm, &draft, "aws")
        .expect_err("provider mismatch must fail before returning an inconsistent row");
    assert!(matches!(error, ProvisioningError::InvalidState(message)
        if message == "existing shared VM provider 'hetzner' does not match requested provider 'aws'"));
}

#[test]
fn canonical_shared_vm_hostname_for_domain_rejects_other_environment_subdomains() {
    assert!(is_canonical_shared_vm_hostname_for_domain(
        "vm-shared-abcd1234.flapjack.foo",
        "flapjack.foo"
    ));
    assert!(is_canonical_shared_vm_hostname_for_domain(
        "vm-shared-abcd1234.staging.flapjack.foo",
        "staging.flapjack.foo"
    ));
    assert!(!is_canonical_shared_vm_hostname_for_domain(
        "vm-shared-abcd1234.staging.flapjack.foo",
        "flapjack.foo"
    ));
    assert!(!is_canonical_shared_vm_hostname_for_domain(
        "manual-abcd1234.flapjack.foo",
        "flapjack.foo"
    ));
    assert!(!is_canonical_shared_vm_hostname_for_domain(
        "vm-shared-abcd1234.flapjack.foo",
        ""
    ));
}

#[test]
fn build_user_data_capacity_has_required_fields() {
    let capacity = default_shared_vm_capacity();
    assert_eq!(capacity["cpu_weight"], 4.0);
    assert_eq!(capacity["query_rps"], 500.0);
}

#[test]
fn engine_base_url_defaults_to_cleartext_when_tls_switch_unset_for_aws() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();
    let _tls_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", None);

    assert_eq!(
        engine_base_url("aws", "vm-x.example.com"),
        "http://vm-x.example.com:7700"
    );
}

#[test]
fn engine_base_url_requires_switch_and_caddy_runtime_for_https() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();

    let false_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("false"));
    assert_eq!(
        engine_base_url("aws", "vm-x.example.com"),
        "http://vm-x.example.com:7700"
    );
    drop(false_guard);

    let true_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("true"));
    let url = engine_base_url("aws", "vm-x.example.com");
    assert_eq!(url, "https://vm-x.example.com");
    assert!(!url.contains(":7700"));
    assert!(!url.contains(":443"));
    assert_eq!(
        engine_base_url("hetzner", "vm-x.example.com"),
        "http://vm-x.example.com:7700"
    );
    drop(true_guard);
}

#[test]
fn engine_base_url_fails_safe_to_cleartext_for_unsupported_provider() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();
    let _tls_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("true"));

    for provider in ["gcp", "oci", "bare_metal", "totally-bogus"] {
        assert_eq!(
            engine_base_url(provider, "vm-x.example.com"),
            "http://vm-x.example.com:7700",
            "{provider} must not select HTTPS"
        );
    }
}

#[test]
fn engine_data_plane_tls_enabled_fails_closed_for_invalid_or_blank_values() {
    let _lock = super::super::ENGINE_TLS_ENV_LOCK.lock().unwrap();

    let unset_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", None);
    assert!(!engine_data_plane_tls_enabled());
    drop(unset_guard);

    let true_guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some("true"));
    assert!(engine_data_plane_tls_enabled());
    drop(true_guard);

    for (raw, expected) in [
        ("false", false),
        ("1", false),
        ("yes", false),
        ("  ", false),
    ] {
        let guard = EnvVarGuard::set("FJCLOUD_ENGINE_DATA_PLANE_TLS_ENABLED", Some(raw));
        assert_eq!(
            engine_data_plane_tls_enabled(),
            expected,
            "{raw:?} should parse to {expected}"
        );
        drop(guard);
    }
}

// -- try_local_dev_provision tests ----------------------------------------

use std::sync::Mutex;

/// Serializes tests that mutate local-dev topology env vars (process-global).
pub(super) static LOCAL_DEV_ENV_LOCK: Mutex<()> = Mutex::new(());

/// RAII guard that sets an env var for the test and restores the previous
/// value on drop. Same pattern used in provisioning.rs tests.
pub(super) struct EnvVarGuard {
    key: &'static str,
    previous: Option<String>,
}

impl EnvVarGuard {
    pub(super) fn set(key: &'static str, value: Option<&str>) -> Self {
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

pub(super) fn clear_local_dev_topology_env() -> (EnvVarGuard, EnvVarGuard) {
    (
        EnvVarGuard::set("FLAPJACK_REGIONS", None),
        EnvVarGuard::set("FLAPJACK_SINGLE_INSTANCE", None),
    )
}

/// Minimal in-memory VmInventoryRepo mock for unit tests.
pub(super) struct InMemoryVmRepo {
    pub(super) vms: Mutex<Vec<VmInventory>>,
}

impl InMemoryVmRepo {
    pub(super) fn new() -> Self {
        Self {
            vms: Mutex::new(Vec::new()),
        }
    }

    pub(super) fn with_vm(vm: VmInventory) -> Self {
        Self {
            vms: Mutex::new(vec![vm]),
        }
    }

    pub(super) fn make_vm(hostname: &str, region: &str) -> VmInventory {
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

trait VmInventoryTestExt {
    fn with_provider(self, provider: &str, flapjack_url: &str) -> Self;
}

impl VmInventoryTestExt for VmInventory {
    fn with_provider(mut self, provider: &str, flapjack_url: &str) -> Self {
        self.provider = provider.to_string();
        self.flapjack_url = flapjack_url.to_string();
        self
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

    async fn list_non_decommissioned(&self) -> Result<Vec<VmInventory>, crate::repos::RepoError> {
        Ok(self
            .vms
            .lock()
            .unwrap()
            .iter()
            .filter(|vm| vm.status != "decommissioned")
            .cloned()
            .collect())
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

    async fn retirement_blockers(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<crate::repos::VmRetirementAssessment, crate::repos::RepoError> {
        let vms = self.vms.lock().unwrap();
        let candidate = vms
            .iter()
            .find(|vm| vm.id == id)
            .map(|vm| (vm.hostname.as_str(), vm.status.as_str()));
        match crate::repos::vm_inventory_repo::validate_vm_retirement_candidate(
            id,
            expected_hostname,
            candidate,
        ) {
            Ok(crate::repos::vm_inventory_repo::VmRetirementCandidateStatus::Active) => {
                Ok(crate::repos::VmRetirementAssessment::Eligible)
            }
            Ok(status) => Ok(crate::repos::VmRetirementAssessment::Conflict(
                crate::repos::VmRetirementConflict::InvalidStatus {
                    actual_status: status.as_str().to_string(),
                },
            )),
            Err(conflict) => Ok(crate::repos::VmRetirementAssessment::Conflict(conflict)),
        }
    }

    async fn decommission_if_unreferenced(
        &self,
        id: Uuid,
        expected_hostname: &str,
    ) -> Result<crate::repos::VmDecommissionResult, crate::repos::RepoError> {
        let mut vms = self.vms.lock().unwrap();
        let vm = vms.iter_mut().find(|vm| vm.id == id);
        let candidate = vm
            .as_ref()
            .map(|vm| (vm.hostname.as_str(), vm.status.as_str()));
        match crate::repos::vm_inventory_repo::validate_vm_retirement_candidate(
            id,
            expected_hostname,
            candidate,
        ) {
            Ok(crate::repos::vm_inventory_repo::VmRetirementCandidateStatus::Active) => {
                let vm = vm.expect("validated active VM exists");
                vm.status = "decommissioned".to_string();
                vm.updated_at = chrono::Utc::now();
                Ok(crate::repos::VmDecommissionResult::Decommissioned)
            }
            Ok(crate::repos::vm_inventory_repo::VmRetirementCandidateStatus::Decommissioned) => {
                Ok(crate::repos::VmDecommissionResult::AlreadyDecommissioned)
            }
            Err(conflict) => Ok(crate::repos::VmDecommissionResult::Conflict(conflict)),
        }
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
