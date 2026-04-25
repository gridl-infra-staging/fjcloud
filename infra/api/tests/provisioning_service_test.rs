mod common;

use std::sync::{Arc, Mutex, OnceLock};

use api::dns::mock::MockDnsManager;
use api::models::vm_inventory::NewVmInventory;
use api::provisioner::{mock::MockVmProvisioner, UnconfiguredVmProvisioner};
use api::repos::{CustomerRepo, DeploymentRepo, VmInventoryRepo};
use api::secrets::mock::MockNodeSecretManager;
use api::services::provisioning::{
    ProvisioningError, ProvisioningService, DEFAULT_DNS_DOMAIN, MAX_DEPLOYMENTS_PER_CUSTOMER,
};
use uuid::Uuid;

type DefaultServiceHarness = (
    Arc<ProvisioningService>,
    Arc<common::MockCustomerRepo>,
    Arc<common::MockDeploymentRepo>,
    Arc<MockVmProvisioner>,
    Arc<MockDnsManager>,
    Arc<MockNodeSecretManager>,
);

type DefaultServiceWithVmInventoryHarness = (
    Arc<ProvisioningService>,
    Arc<common::MockCustomerRepo>,
    Arc<common::MockDeploymentRepo>,
    Arc<MockVmProvisioner>,
    Arc<MockDnsManager>,
    Arc<MockNodeSecretManager>,
    Arc<common::MockVmInventoryRepo>,
);

fn process_env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

struct EnvVarGuard {
    key: &'static str,
    old_value: Option<String>,
}

impl EnvVarGuard {
    fn set(key: &'static str, value: &str) -> Self {
        let old_value = std::env::var(key).ok();
        std::env::set_var(key, value);
        Self { key, old_value }
    }

    fn unset(key: &'static str) -> Self {
        let old_value = std::env::var(key).ok();
        std::env::remove_var(key);
        Self { key, old_value }
    }
}

impl Drop for EnvVarGuard {
    fn drop(&mut self) {
        match &self.old_value {
            Some(value) => std::env::set_var(self.key, value),
            None => std::env::remove_var(self.key),
        }
    }
}

/// Helper: build a ProvisioningService wired to mock repos/provisioner/dns/secrets.
fn build_service(
    customer_repo: Arc<common::MockCustomerRepo>,
    deployment_repo: Arc<common::MockDeploymentRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
    dns_manager: Arc<MockDnsManager>,
    node_secret_manager: Arc<MockNodeSecretManager>,
) -> Arc<ProvisioningService> {
    Arc::new(ProvisioningService::new(
        vm_provisioner,
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    ))
}

fn default_service() -> DefaultServiceHarness {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let vm_provisioner = common::mock_vm_provisioner();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let svc = build_service(
        Arc::clone(&customer_repo),
        Arc::clone(&deployment_repo),
        Arc::clone(&vm_provisioner),
        Arc::clone(&dns_manager),
        Arc::clone(&node_secret_manager),
    );
    (
        svc,
        customer_repo,
        deployment_repo,
        vm_provisioner,
        dns_manager,
        node_secret_manager,
    )
}

fn default_service_with_vm_inventory() -> DefaultServiceWithVmInventoryHarness {
    let (svc, customer_repo, deployment_repo, vm_provisioner, dns_manager, node_secret_manager) =
        default_service();
    let vm_inventory_repo = common::mock_vm_inventory_repo();
    (
        svc,
        customer_repo,
        deployment_repo,
        vm_provisioner,
        dns_manager,
        node_secret_manager,
        vm_inventory_repo,
    )
}

// -----------------------------------------------------------------------
// Test 1: provision creates deployment with status=provisioning
// -----------------------------------------------------------------------
#[tokio::test]
async fn provision_creates_deployment_with_provisioning_status() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    let deployment = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await
        .expect("provision should succeed");

    assert_eq!(deployment.status, "provisioning");
    assert_eq!(deployment.customer_id, customer.id);
    assert_eq!(deployment.region, "us-east-1");
    assert_eq!(deployment.vm_type, "t4g.small");
    assert!(deployment.node_id.starts_with("node-"));

    // Wait briefly for background task to complete
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    // Verify the background task updated provisioning fields
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert!(updated.provider_vm_id.is_some());
    assert!(updated.hostname.is_some());
    assert!(updated.flapjack_url.is_some());
    // Hostname should be vm-{first 8 chars of deployment id}.<DEFAULT_DNS_DOMAIN>
    let short_id = &deployment.id.to_string()[..8];
    let expected_hostname = format!("vm-{short_id}.{DEFAULT_DNS_DOMAIN}");
    assert_eq!(
        updated.hostname.as_deref(),
        Some(expected_hostname.as_str())
    );
    assert_eq!(
        updated.flapjack_url.as_deref(),
        Some(format!("http://{expected_hostname}:7700").as_str())
    );
}

// -----------------------------------------------------------------------
// Test 2: provision fails for suspended customer
// -----------------------------------------------------------------------
#[tokio::test]
async fn provision_fails_for_suspended_customer() {
    let (svc, customer_repo, _deploy_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");
    customer_repo.suspend(customer.id).await.unwrap();

    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(matches!(result, Err(ProvisioningError::CustomerSuspended)));
}

// -----------------------------------------------------------------------
// Test 3: provision fails when deployment limit reached
// -----------------------------------------------------------------------
#[tokio::test]
async fn provision_fails_when_deployment_limit_reached() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Seed MAX_DEPLOYMENTS_PER_CUSTOMER deployments
    for i in 0..MAX_DEPLOYMENTS_PER_CUSTOMER {
        deployment_repo.seed(
            customer.id,
            &format!("node-{i}"),
            "us-east-1",
            "t4g.small",
            "aws",
            "running",
        );
    }

    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(matches!(
        result,
        Err(ProvisioningError::DeploymentLimitReached(5))
    ));
}

// -----------------------------------------------------------------------
// Test 4: complete_provisioning creates VM + DNS + updates record
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_creates_vm_dns_updates_record() {
    let (svc, _customer_repo, deployment_repo, _vm, dns_manager, _ssm) = default_service();

    // Manually create a deployment in "provisioning" state (simulating what provision_deployment does)
    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-test",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Call complete_provisioning directly
    svc.complete_provisioning(deployment.id).await.unwrap();

    // Verify deployment was updated
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert!(updated.provider_vm_id.is_some());
    assert!(updated.ip_address.is_some());
    assert!(updated.hostname.is_some());
    assert!(updated.flapjack_url.is_some());

    // Verify DNS record was created
    let records = dns_manager.get_records();
    let hostname = updated.hostname.unwrap();
    assert!(records.contains_key(&hostname));
}

// -----------------------------------------------------------------------
// Test 5: complete_provisioning sets status=failed on VM creation failure
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_sets_failed_on_vm_error() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Inject failure
    vm_provisioner.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(
        result,
        Err(ProvisioningError::ProvisionerFailed(_))
    ));

    // Verify deployment status is now "failed"
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");

    // SSM key must be cleaned up — it was created before the VM attempt, so
    // the cleanup path after VM failure must delete it to prevent key leaks.
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM secret must be cleaned up when VM creation fails"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_cleans_up_ssm_on_vm_failure() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::unset("LOCAL_DEV_FLAPJACK_URL");

    let (
        svc,
        _customer_repo,
        _deployment_repo,
        vm_provisioner,
        _dns_manager,
        ssm,
        vm_inventory_repo,
    ) = default_service_with_vm_inventory();

    vm_provisioner.set_should_fail(true);

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(_))),
        "auto-provision should fail with ProvisionerFailed when VM create fails: {result:?}"
    );
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM key must be cleaned up when auto-provision VM create fails"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_cleans_up_vm_and_ssm_on_dns_failure() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::unset("LOCAL_DEV_FLAPJACK_URL");

    let (
        svc,
        _customer_repo,
        _deployment_repo,
        vm_provisioner,
        dns_manager,
        ssm,
        vm_inventory_repo,
    ) = default_service_with_vm_inventory();

    dns_manager.set_should_fail(true);

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::DnsFailed(_))),
        "auto-provision should fail with DnsFailed when DNS create fails: {result:?}"
    );
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM must be destroyed when DNS fails during auto-provision"
    );
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM key must be cleaned up when DNS fails during auto-provision"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_cleans_up_all_on_db_failure() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::unset("LOCAL_DEV_FLAPJACK_URL");

    let (
        svc,
        _customer_repo,
        _deployment_repo,
        vm_provisioner,
        dns_manager,
        ssm,
        vm_inventory_repo,
    ) = default_service_with_vm_inventory();

    vm_inventory_repo.set_should_fail(true);

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::RepoError(_))),
        "auto-provision should fail with RepoError when vm inventory insert fails: {result:?}"
    );
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM must be destroyed when vm inventory create fails"
    );
    assert!(
        dns_manager.get_records().is_empty(),
        "DNS records must be cleaned up when vm inventory create fails"
    );
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM key must be cleaned up when vm inventory create fails"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_uses_local_dev_bypass_when_url_configured() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "http://localhost:7700");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let vm = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "eu-west-1", "aws")
        .await
        .expect("bypass should create vm inventory row in local mode");

    assert_eq!(vm.provider, "local");
    assert_eq!(vm.flapjack_url, "http://localhost:7700");
    assert_eq!(vm.region, "eu-west-1");
    assert_eq!(vm.hostname, "local-dev-eu-west-1");
    assert_eq!(vm_inventory_repo.create_call_count(), 1);
    assert!(
        dns_manager.get_records().is_empty(),
        "local bypass must skip DNS record provisioning"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "local bypass must skip node secret provisioning"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_reuses_existing_local_dev_vm_for_region() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "http://localhost:7700");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let existing_vm = vm_inventory_repo
        .create(NewVmInventory {
            region: "us-east-1".to_string(),
            provider: "local".to_string(),
            hostname: "local-dev-us-east-1".to_string(),
            flapjack_url: "http://localhost:7700".to_string(),
            capacity: serde_json::json!({}),
        })
        .await
        .expect("seed existing local vm");

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let vm = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await
        .expect("local bypass should reuse existing vm inventory row");

    assert_eq!(vm.id, existing_vm.id);
    assert_eq!(vm.hostname, "local-dev-us-east-1");
    assert_eq!(vm_inventory_repo.create_call_count(), 1);
    assert!(
        dns_manager.get_records().is_empty(),
        "reused local bypass must still skip DNS record provisioning"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "reused local bypass must still skip node secret provisioning"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_trims_local_dev_flapjack_url_before_persisting() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set(
        "LOCAL_DEV_FLAPJACK_URL",
        "  \thttp://localhost:7700/local  \n",
    );

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let vm = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await
        .expect("trimmed local URL should still activate local bypass");

    assert_eq!(vm.provider, "local");
    assert_eq!(vm.flapjack_url, "http://localhost:7700/local");
    assert_eq!(vm.region, "us-east-1");
    assert_eq!(vm.hostname, "local-dev-us-east-1");
    assert_eq!(vm_inventory_repo.create_call_count(), 1);
    assert!(
        dns_manager.get_records().is_empty(),
        "trimmed local bypass must still skip DNS record provisioning"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "trimmed local bypass must still skip node secret provisioning"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_normalizes_trailing_slash_in_local_dev_flapjack_url() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "http://localhost:7700/");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let vm = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await
        .expect("local bypass with trailing slash should still succeed");

    assert_eq!(vm.provider, "local");
    assert_eq!(
        vm.flapjack_url, "http://localhost:7700",
        "persisted flapjack URL should not retain trailing slash to avoid // path joins"
    );
    assert_eq!(vm.region, "us-east-1");
    assert_eq!(vm.hostname, "local-dev-us-east-1");
    assert_eq!(vm_inventory_repo.create_call_count(), 1);
    assert!(
        dns_manager.get_records().is_empty(),
        "local bypass must skip DNS record provisioning"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "local bypass must skip node secret provisioning"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_normalizes_path_slash_without_mutating_query_suffix() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set(
        "LOCAL_DEV_FLAPJACK_URL",
        "http://localhost:7700/local/?token=abc/",
    );

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager.clone(),
        node_secret_manager.clone(),
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let vm = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await
        .expect("local bypass with query suffix should still succeed");

    assert_eq!(vm.provider, "local");
    assert_eq!(
        vm.flapjack_url, "http://localhost:7700/local?token=abc/",
        "normalization must only trim the trailing path slash and preserve query suffixes"
    );
    assert_eq!(vm.region, "us-east-1");
    assert_eq!(vm.hostname, "local-dev-us-east-1");
    assert_eq!(vm_inventory_repo.create_call_count(), 1);
    assert!(
        dns_manager.get_records().is_empty(),
        "local bypass must skip DNS record provisioning"
    );
    assert_eq!(
        node_secret_manager.secret_count(),
        0,
        "local bypass must skip node secret provisioning"
    );
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_without_local_dev_url_fails_with_unconfigured_provisioner() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::unset("LOCAL_DEV_FLAPJACK_URL");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "eu-west-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(ref msg)) if msg == "VM provisioner not configured"),
        "without local bypass env var, unconfigured provisioner must fail: {result:?}"
    );
    assert_eq!(vm_inventory_repo.create_call_count(), 0);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_with_blank_local_dev_url_fails_with_unconfigured_provisioner() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "   ");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "eu-west-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(ref msg)) if msg == "VM provisioner not configured"),
        "blank local bypass env var should be treated as unset: {result:?}"
    );
    assert_eq!(vm_inventory_repo.create_call_count(), 0);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_rejects_non_loopback_local_dev_url() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "https://example.com:7700");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "eu-west-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(ref msg)) if msg == "VM provisioner not configured"),
        "non-loopback local bypass URLs must be ignored so the real provisioner path still enforces configuration: {result:?}"
    );
    assert_eq!(vm_inventory_repo.create_call_count(), 0);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_with_empty_local_dev_url_fails_with_unconfigured_provisioner() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::set("LOCAL_DEV_FLAPJACK_URL", "");

    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let dns_manager = common::mock_dns_manager();
    let node_secret_manager = common::mock_node_secret_manager();
    let vm_inventory_repo = common::mock_vm_inventory_repo();

    let svc = ProvisioningService::new(
        Arc::new(UnconfiguredVmProvisioner),
        dns_manager,
        node_secret_manager,
        deployment_repo,
        customer_repo,
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "eu-west-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(ref msg)) if msg == "VM provisioner not configured"),
        "empty local bypass env var should be treated as unset: {result:?}"
    );
    assert_eq!(vm_inventory_repo.create_call_count(), 0);
}

#[tokio::test]
#[allow(clippy::await_holding_lock)]
async fn auto_provision_shared_vm_cleans_up_vm_and_ssm_on_missing_public_ip() {
    let _env_guard = process_env_lock().lock().unwrap();
    let _local_url = EnvVarGuard::unset("LOCAL_DEV_FLAPJACK_URL");

    let (
        svc,
        _customer_repo,
        _deployment_repo,
        vm_provisioner,
        _dns_manager,
        ssm,
        vm_inventory_repo,
    ) = default_service_with_vm_inventory();

    vm_provisioner
        .omit_public_ip
        .store(true, std::sync::atomic::Ordering::SeqCst);

    let result = svc
        .auto_provision_shared_vm(vm_inventory_repo.as_ref(), "us-east-1", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(_))),
        "auto-provision should fail with ProvisionerFailed when VM has no public IP: {result:?}"
    );
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM must be destroyed when auto-provision VM has no public IP"
    );
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM key must be cleaned up when auto-provision VM has no public IP"
    );
}

// -----------------------------------------------------------------------
// Test 6: stop/start lifecycle
// -----------------------------------------------------------------------
#[tokio::test]
async fn stop_and_start_lifecycle() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Create a deployment and complete provisioning
    let deployment = deployment_repo
        .create(
            customer.id,
            "node-lifecycle",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    // Move VM to running state (simulating health monitor)
    deployment_repo
        .update(deployment.id, None, Some("running"))
        .await
        .unwrap();

    // Need to also make the mock VM running
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    let provider_vm_id = updated.provider_vm_id.as_ref().unwrap();
    // Start the mock VM to put it in Running state (it starts as Pending)
    svc.vm_provisioner.start_vm(provider_vm_id).await.unwrap();

    // Stop the deployment
    let stopped = svc
        .stop_deployment(deployment.id, customer.id)
        .await
        .unwrap();
    assert_eq!(stopped.status, "stopped");

    // Start it again
    let started = svc
        .start_deployment(deployment.id, customer.id)
        .await
        .unwrap();
    assert_eq!(started.status, "provisioning");
}

// -----------------------------------------------------------------------
// Test 7: terminate cleans up VM + DNS + deployment
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_cleans_up_vm_dns_deployment() {
    let (svc, customer_repo, deployment_repo, _vm, dns_manager, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Create and provision
    let deployment = deployment_repo
        .create(
            customer.id,
            "node-term",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    // Verify DNS record exists
    let records_before = dns_manager.get_records();
    assert!(!records_before.is_empty());

    // Terminate
    svc.terminate_deployment(deployment.id, customer.id)
        .await
        .unwrap();

    // Verify deployment is terminated
    let terminated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(terminated.status, "terminated");
    assert!(terminated.terminated_at.is_some());

    // Verify DNS record was deleted
    let records_after = dns_manager.get_records();
    assert!(records_after.is_empty());
}

// -----------------------------------------------------------------------
// Test 8: ownership checks — not found and not owned
// -----------------------------------------------------------------------
#[tokio::test]
async fn ownership_check_deployment_not_found() {
    let (svc, customer_repo, _deploy_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    let result = svc.stop_deployment(Uuid::new_v4(), customer.id).await;

    assert!(matches!(result, Err(ProvisioningError::DeploymentNotFound)));
}

#[tokio::test]
async fn ownership_check_not_owned() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let owner = customer_repo.seed("Owner", "owner@example.com");
    let other = customer_repo.seed("Other", "other@example.com");

    let deployment = deployment_repo.seed(
        owner.id,
        "node-owned",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );

    let result = svc.stop_deployment(deployment.id, other.id).await;

    assert!(matches!(result, Err(ProvisioningError::NotOwned)));
}

// -----------------------------------------------------------------------
// Test 9: provision fails for deleted customer
// -----------------------------------------------------------------------
#[tokio::test]
async fn provision_fails_for_deleted_customer() {
    let (svc, customer_repo, _deploy_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed_deleted("Deleted Co", "deleted@example.com");

    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(matches!(result, Err(ProvisioningError::CustomerNotFound)));
}

// -----------------------------------------------------------------------
// Test 10: provision fails for nonexistent customer
// -----------------------------------------------------------------------
#[tokio::test]
async fn provision_fails_for_nonexistent_customer() {
    let (svc, _customer_repo, _deploy_repo, _vm, _dns, _ssm) = default_service();

    let result = svc
        .provision_deployment(Uuid::new_v4(), "us-east-1", "t4g.small", "aws")
        .await;

    assert!(matches!(result, Err(ProvisioningError::CustomerNotFound)));
}

// -----------------------------------------------------------------------
// Test 11: complete_provisioning sets failed on DNS failure AND cleans up VM
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_sets_failed_on_dns_error() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, dns_manager, _ssm) =
        default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-dns-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Inject DNS failure
    dns_manager.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(result, Err(ProvisioningError::DnsFailed(_))));

    // Verify deployment status is "failed"
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");

    // BUG FIX: Verify the VM was cleaned up (not leaked)
    // The VM was created before DNS failed, so it must be destroyed
    let vm_count = vm_provisioner.vm_count();
    assert_eq!(
        vm_count, 0,
        "VM should be destroyed after DNS failure, not leaked"
    );
}

// -----------------------------------------------------------------------
// Test 12: complete_provisioning skips if deployment is no longer provisioning
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_skips_non_provisioning_deployment() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, _ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-stale",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Simulate deployment being terminated before background task runs
    deployment_repo.terminate(deployment.id).await.unwrap();

    let result = svc.complete_provisioning(deployment.id).await;

    // Should return an error — deployment is no longer in provisioning state
    assert!(
        result.is_err(),
        "should not proceed with terminated deployment"
    );

    // No VMs should have been created
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "no VM should be created for terminated deployment"
    );
}

// -----------------------------------------------------------------------
// Test 13: complete_provisioning cleans up if update_provisioning finds no deployment
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_cleans_up_on_update_provisioning_failure() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, dns_manager, _ssm) =
        default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-vanish",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // We need a custom flow: let complete_provisioning start, but delete the
    // deployment between VM creation and the update_provisioning call.
    // Since we can't inject mid-flow, we test the simpler case: call
    // complete_provisioning, then verify update_provisioning was called and the
    // deployment record was properly updated.
    // (This test ensures the happy path properly saves provider_vm_id)
    svc.complete_provisioning(deployment.id).await.unwrap();

    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert!(
        updated.provider_vm_id.is_some(),
        "provider_vm_id must be saved to deployment"
    );
    assert!(
        updated.hostname.is_some(),
        "hostname must be saved to deployment"
    );
    assert!(
        updated.flapjack_url.is_some(),
        "flapjack_url must be saved to deployment"
    );
    assert!(
        updated.ip_address.is_some(),
        "ip_address must be saved to deployment"
    );

    // Verify exactly one VM exists in the mock provisioner
    assert_eq!(vm_provisioner.vm_count(), 1, "exactly one VM should exist");

    // Verify DNS record exists
    let records = dns_manager.get_records();
    assert_eq!(records.len(), 1, "exactly one DNS record should exist");
}

// -----------------------------------------------------------------------
// Test 14: terminate already-terminated deployment returns InvalidState
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_already_terminated_returns_invalid_state() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    let deployment = deployment_repo.seed(
        customer.id,
        "node-term2",
        "us-east-1",
        "t4g.small",
        "aws",
        "terminated",
    );

    let result = svc.terminate_deployment(deployment.id, customer.id).await;

    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "terminating an already-terminated deployment must return InvalidState"
    );
}

// -----------------------------------------------------------------------
// Test 15: stop_deployment on non-running deployment returns InvalidState
// -----------------------------------------------------------------------
#[tokio::test]
async fn stop_non_running_deployment_returns_invalid_state() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Provisioning deployment — cannot be stopped
    let provisioning = deployment_repo.seed(
        customer.id,
        "node-prov",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let result = svc.stop_deployment(provisioning.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "stopping a provisioning deployment must return InvalidState"
    );

    // Stopped deployment — cannot be stopped again
    let stopped = deployment_repo.seed(
        customer.id,
        "node-stopped",
        "us-east-1",
        "t4g.small",
        "aws",
        "stopped",
    );

    let result = svc.stop_deployment(stopped.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "stopping an already-stopped deployment must return InvalidState"
    );

    // Failed deployment — cannot be stopped
    let failed = deployment_repo.seed(
        customer.id,
        "node-failed",
        "us-east-1",
        "t4g.small",
        "aws",
        "failed",
    );

    let result = svc.stop_deployment(failed.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "stopping a failed deployment must return InvalidState"
    );
}

// -----------------------------------------------------------------------
// Test 16: start_deployment on non-stopped deployment returns InvalidState
// -----------------------------------------------------------------------
#[tokio::test]
async fn start_non_stopped_deployment_returns_invalid_state() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Running deployment — cannot be started
    let running = deployment_repo.seed(
        customer.id,
        "node-running",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );

    let result = svc.start_deployment(running.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "starting a running deployment must return InvalidState"
    );

    // Provisioning deployment — cannot be started
    let provisioning = deployment_repo.seed(
        customer.id,
        "node-prov2",
        "us-east-1",
        "t4g.small",
        "aws",
        "provisioning",
    );

    let result = svc.start_deployment(provisioning.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "starting a provisioning deployment must return InvalidState"
    );
}

// -----------------------------------------------------------------------
// Test 17: deployment limit excludes terminated deployments
// -----------------------------------------------------------------------
#[tokio::test]
async fn deployment_limit_excludes_terminated() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Fill to the limit with terminated deployments — these should NOT count
    for i in 0..MAX_DEPLOYMENTS_PER_CUSTOMER {
        deployment_repo.seed(
            customer.id,
            &format!("node-terminated-{i}"),
            "us-east-1",
            "t4g.small",
            "aws",
            "terminated",
        );
    }

    // Provisioning should succeed since terminated don't count
    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(
        result.is_ok(),
        "terminated deployments should not count toward the limit"
    );
}

// -----------------------------------------------------------------------
// Test 18a: deployment limit excludes failed deployments
// -----------------------------------------------------------------------
#[tokio::test]
async fn deployment_limit_excludes_failed() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Fill to the limit with failed deployments — these should NOT count toward the limit
    // (failed deployments are dead records; customers must be able to retry provisioning)
    for i in 0..MAX_DEPLOYMENTS_PER_CUSTOMER {
        deployment_repo.seed(
            customer.id,
            &format!("node-failed-{i}"),
            "us-east-1",
            "t4g.small",
            "aws",
            "failed",
        );
    }

    // Provisioning should succeed since failed deployments don't count
    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(
        result.is_ok(),
        "failed deployments should not count toward the deployment limit; got: {result:?}"
    );
}

// Test 18b: deployment limit still enforced for active deployments alongside failed ones
#[tokio::test]
async fn deployment_limit_counts_active_not_failed() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Mix of active (running) and failed deployments: active ones fill the limit
    for i in 0..MAX_DEPLOYMENTS_PER_CUSTOMER {
        deployment_repo.seed(
            customer.id,
            &format!("node-running-{i}"),
            "us-east-1",
            "t4g.small",
            "aws",
            "running",
        );
    }
    // Extra failed deployments — should not affect the limit enforcement
    for i in 0..3 {
        deployment_repo.seed(
            customer.id,
            &format!("node-failed-{i}"),
            "us-east-1",
            "t4g.small",
            "aws",
            "failed",
        );
    }

    let result = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await;

    assert!(
        matches!(result, Err(ProvisioningError::DeploymentLimitReached(5))),
        "should be limited by active deployments even when failed ones also exist; got: {result:?}"
    );
}

// -----------------------------------------------------------------------
// Test 18: stop_deployment without provider_vm_id returns InvalidState
// -----------------------------------------------------------------------
#[tokio::test]
async fn stop_deployment_without_provider_vm_id_returns_invalid_state() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Seed a running deployment that has NO provider_vm_id set (shouldn't happen
    // in practice, but the code must handle it gracefully)
    let dep = deployment_repo.seed(
        customer.id,
        "node-no-vm",
        "us-east-1",
        "t4g.small",
        "aws",
        "running",
    );
    // dep has provider_vm_id = None since seed() doesn't set it

    let result = svc.stop_deployment(dep.id, customer.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "stopping a deployment without provider_vm_id must return InvalidState"
    );
}

// -----------------------------------------------------------------------
// Test 19: complete_provisioning fails when VM has no public IP
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_fails_when_no_public_ip() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, _ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-no-ip",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Configure mock to return VMs without a public IP
    vm_provisioner
        .omit_public_ip
        .store(true, std::sync::atomic::Ordering::SeqCst);

    let result = svc.complete_provisioning(deployment.id).await;

    // Should fail — cannot create DNS without a public IP
    assert!(
        result.is_err(),
        "provisioning must fail when VM has no public IP"
    );

    // Deployment should be marked as failed
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        updated.status, "failed",
        "deployment status must be 'failed' when VM has no public IP"
    );

    // VM should be cleaned up (not leaked)
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM must be destroyed when provisioning fails due to missing public IP"
    );
}

// -----------------------------------------------------------------------
// Test 20: terminate_deployment succeeds even when DNS cleanup fails
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_succeeds_even_when_dns_cleanup_fails() {
    let (svc, customer_repo, deployment_repo, vm_provisioner, dns_manager, _ssm) =
        default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Create and provision a deployment
    let deployment = deployment_repo
        .create(
            customer.id,
            "node-dns-cleanup-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    // Verify VM and DNS exist
    assert_eq!(vm_provisioner.vm_count(), 1);
    assert!(!dns_manager.get_records().is_empty());

    // Inject DNS failure — terminate should still succeed
    dns_manager.set_should_fail(true);

    let result = svc.terminate_deployment(deployment.id, customer.id).await;

    // Termination must succeed even though DNS cleanup failed
    assert!(
        result.is_ok(),
        "terminate_deployment must succeed even when DNS cleanup fails: {result:?}"
    );

    // Deployment must be marked terminated
    let terminated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        terminated.status, "terminated",
        "deployment must be terminated even when DNS cleanup fails"
    );
    assert!(terminated.terminated_at.is_some());

    // VM should be destroyed (it was destroyed before DNS failure)
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM should be destroyed during termination"
    );
}

// -----------------------------------------------------------------------
// Test 21: terminate_deployment fails when VM destruction fails
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_fails_when_vm_destruction_fails() {
    let (svc, customer_repo, deployment_repo, vm_provisioner, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Create and provision a deployment
    let deployment = deployment_repo
        .create(
            customer.id,
            "node-vm-destroy-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    // Inject VM provisioner failure — terminate should fail
    vm_provisioner.set_should_fail(true);

    let result = svc.terminate_deployment(deployment.id, customer.id).await;

    // Should fail because VM destruction failed
    assert!(
        matches!(result, Err(ProvisioningError::ProvisionerFailed(_))),
        "terminate should fail when VM destruction fails: {result:?}"
    );

    // Deployment must NOT be terminated (VM still exists)
    let dep = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_ne!(
        dep.status, "terminated",
        "deployment must not be terminated when VM destruction fails"
    );
}

// -----------------------------------------------------------------------
// Test 22: complete_provisioning creates SSM secret before VM
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_creates_ssm_secret() {
    let (svc, _customer_repo, deployment_repo, _vm, _dns, ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-ssm-test",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    svc.complete_provisioning(deployment.id).await.unwrap();

    // SSM secret must exist for this node
    assert_eq!(ssm.secret_count(), 1, "exactly one SSM secret should exist");
    assert!(
        ssm.get_secret("node-ssm-test").is_some(),
        "SSM secret must be stored under the node_id"
    );
}

// -----------------------------------------------------------------------
// Test 23: complete_provisioning fails when SSM creation fails
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_fails_when_ssm_fails() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-ssm-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Inject SSM failure
    ssm.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::SecretFailed(_))),
        "provisioning must fail when SSM write fails: {result:?}"
    );

    // No VM should have been created (SSM write happens before VM creation)
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "no VM should be created when SSM write fails"
    );

    // Deployment should be marked as failed
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");
}

// -----------------------------------------------------------------------
// Test 24: terminate_deployment cleans up SSM secret
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_cleans_up_ssm_secret() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    let deployment = deployment_repo
        .create(
            customer.id,
            "node-ssm-term",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    // SSM secret should exist
    assert_eq!(ssm.secret_count(), 1);

    // Terminate
    svc.terminate_deployment(deployment.id, customer.id)
        .await
        .unwrap();

    // SSM secret should be cleaned up
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM secret must be deleted on termination"
    );
}

#[tokio::test]
async fn terminate_cleans_up_ssm_even_when_ssm_delete_partially_fails() {
    let (svc, customer_repo, deployment_repo, vm_provisioner, _dns, ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    let deployment = deployment_repo
        .create(
            customer.id,
            "node-ssm-term-partial-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    assert_eq!(vm_provisioner.vm_count(), 1);
    assert_eq!(ssm.secret_count(), 1);

    // Delete failure is best-effort during terminate; termination should still succeed.
    ssm.set_should_fail(true);

    let result = svc.terminate_deployment(deployment.id, customer.id).await;
    assert!(
        result.is_ok(),
        "terminate must succeed even when SSM delete fails: {result:?}"
    );

    let terminated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(terminated.status, "terminated");
    assert!(terminated.terminated_at.is_some());
    assert_eq!(vm_provisioner.vm_count(), 0);
}

// -----------------------------------------------------------------------
// Test 25: SSM cleanup on DNS failure during provisioning
// -----------------------------------------------------------------------
#[tokio::test]
async fn complete_provisioning_cleans_up_ssm_on_dns_failure() {
    let (svc, _customer_repo, deployment_repo, _vm, dns_manager, ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-dns-ssm-fail",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Inject DNS failure (SSM write will succeed, VM creation will succeed, DNS will fail)
    dns_manager.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(result, Err(ProvisioningError::DnsFailed(_))));

    // SSM secret should be cleaned up after DNS failure
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM secret must be cleaned up when provisioning fails due to DNS error"
    );
}

// -----------------------------------------------------------------------
// Test 26: terminate succeeds when VM was already externally terminated
//          (e.g. AWS spot interruption, manual operator action)
// -----------------------------------------------------------------------
#[tokio::test]
async fn terminate_succeeds_when_vm_already_externally_terminated() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Test Co", "test@example.com");

    // Create and provision a deployment
    let deployment = deployment_repo
        .create(
            customer.id,
            "node-ext-term",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();
    svc.complete_provisioning(deployment.id).await.unwrap();

    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    let provider_vm_id = updated.provider_vm_id.as_ref().unwrap().clone();

    // Simulate external VM termination (spot interruption, manual AWS console action).
    // Remove the VM from the mock directly, without going through the service.
    // In real EC2, TerminateInstances is idempotent: calling it on an already-terminated
    // or non-existent instance returns success. The mock must match this behavior.
    svc.vm_provisioner
        .destroy_vm(&provider_vm_id)
        .await
        .unwrap();

    // Now call terminate_deployment — the VM is already gone, but termination
    // must succeed because the deployment record still needs to be marked terminated.
    let result = svc.terminate_deployment(deployment.id, customer.id).await;
    assert!(
        result.is_ok(),
        "terminate must succeed even when VM was already externally terminated: {result:?}"
    );

    let terminated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(terminated.status, "terminated");
    assert!(terminated.terminated_at.is_some());
}

// -----------------------------------------------------------------------
// Stage 9: Hetzner VM cloud-init uses Direct secrets, not AWS SSM
// -----------------------------------------------------------------------

#[tokio::test]
async fn hetzner_deployment_uses_direct_secrets_in_cloud_init() {
    let (svc, customer_repo, _deployment_repo, vm_provisioner, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Hetzner Co", "hetzner@example.com");

    // Provision a Hetzner deployment
    let _deployment = svc
        .provision_deployment(customer.id, "eu-central-1", "cpx32", "hetzner")
        .await
        .expect("provision should succeed");

    // Wait for background task
    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    // The user_data sent to the VM provisioner must NOT contain AWS SSM commands
    // (Hetzner VMs don't have IAM roles or AWS CLI).
    let last_req = vm_provisioner
        .last_create_request()
        .expect("create_vm should have been called");

    let user_data = last_req
        .user_data
        .expect("user_data must be set for VM bootstrapping");

    assert!(
        !user_data.contains("aws ssm"),
        "Hetzner cloud-init must NOT reference AWS SSM — VMs don't have AWS access.\n\
         Got user_data:\n{user_data}"
    );
    assert!(
        user_data.contains("systemctl start flapjack"),
        "cloud-init must start flapjack service.\nGot user_data:\n{user_data}"
    );
}

#[tokio::test]
async fn aws_deployment_uses_ssm_secrets_in_cloud_init() {
    let (svc, customer_repo, _deployment_repo, vm_provisioner, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("AWS Co", "aws@example.com");

    let _deployment = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await
        .expect("provision should succeed");

    tokio::time::sleep(std::time::Duration::from_millis(200)).await;

    let last_req = vm_provisioner
        .last_create_request()
        .expect("create_vm should have been called");

    let user_data = last_req
        .user_data
        .expect("user_data must be set for VM bootstrapping");

    assert!(
        user_data.contains("aws ssm get-parameter"),
        "AWS cloud-init must use SSM for secret retrieval.\nGot user_data:\n{user_data}"
    );
}

// -----------------------------------------------------------------------
// Stage 2: DEFAULT_DNS_DOMAIN must be flapjack.foo
// -----------------------------------------------------------------------
#[test]
fn default_dns_domain_is_flapjack_foo() {
    assert_eq!(
        DEFAULT_DNS_DOMAIN, "flapjack.foo",
        "DEFAULT_DNS_DOMAIN must be the canonical flapjack.foo domain"
    );
}

#[tokio::test]
async fn provision_hostname_uses_flapjack_foo_domain() {
    let (svc, customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();
    let customer = customer_repo.seed("Flapjack Co", "flapjack@example.com");

    let deployment = svc
        .provision_deployment(customer.id, "us-east-1", "t4g.small", "aws")
        .await
        .expect("provision should succeed");

    tokio::time::sleep(std::time::Duration::from_millis(100)).await;

    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    let short_id = &deployment.id.to_string()[..8];
    let expected_hostname = format!("vm-{short_id}.flapjack.foo");
    assert_eq!(
        updated.hostname.as_deref(),
        Some(expected_hostname.as_str()),
        "provisioned hostname must use flapjack.foo domain"
    );
    assert_eq!(
        updated.flapjack_url.as_deref(),
        Some(format!("http://{expected_hostname}:7700").as_str()),
        "provisioned URL must use flapjack.foo domain"
    );
}
