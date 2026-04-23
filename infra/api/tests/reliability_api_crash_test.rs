mod common;

use std::sync::Arc;

use api::dns::mock::MockDnsManager;
use api::provisioner::mock::MockVmProvisioner;
use api::repos::DeploymentRepo;
use api::secrets::mock::MockNodeSecretManager;
use api::secrets::{NodeSecretError, NodeSecretManager};
use api::services::provisioning::{ProvisioningError, ProvisioningService, DEFAULT_DNS_DOMAIN};
use async_trait::async_trait;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn build_service(
    customer_repo: Arc<common::MockCustomerRepo>,
    deployment_repo: Arc<common::MockDeploymentRepo>,
    vm_provisioner: Arc<MockVmProvisioner>,
    dns_manager: Arc<MockDnsManager>,
    node_secret_manager: Arc<dyn NodeSecretManager>,
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

type DefaultServiceDeps = (
    Arc<ProvisioningService>,
    Arc<common::MockCustomerRepo>,
    Arc<common::MockDeploymentRepo>,
    Arc<MockVmProvisioner>,
    Arc<MockDnsManager>,
    Arc<MockNodeSecretManager>,
);

fn default_service() -> DefaultServiceDeps {
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
        Arc::clone(&node_secret_manager) as Arc<dyn NodeSecretManager>,
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

// ---------------------------------------------------------------------------
// FailOnDeleteNodeSecretManager — create always succeeds, delete always fails.
// ---------------------------------------------------------------------------

struct FailOnDeleteNodeSecretManager {
    inner: MockNodeSecretManager,
}

impl FailOnDeleteNodeSecretManager {
    fn new() -> Arc<Self> {
        Arc::new(Self {
            inner: MockNodeSecretManager::new(),
        })
    }
}

#[async_trait]
impl NodeSecretManager for FailOnDeleteNodeSecretManager {
    async fn create_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<String, NodeSecretError> {
        self.inner.create_node_api_key(node_id, region).await
    }

    async fn delete_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(), NodeSecretError> {
        Err(NodeSecretError::Api("simulated SSM delete failure".into()))
    }

    async fn get_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<String, NodeSecretError> {
        self.inner.get_node_api_key(node_id, region).await
    }

    async fn rotate_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        self.inner.rotate_node_api_key(node_id, region).await
    }

    async fn commit_rotation(
        &self,
        node_id: &str,
        region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        // This test double intentionally fails delete semantics to validate rollback
        // robustness when secret cleanup fails.
        self.delete_node_api_key(node_id, region).await
    }
}

// ---------------------------------------------------------------------------
// Class 2: API crash during mutating provisioning request
// ---------------------------------------------------------------------------

/// VM creation failure triggers rollback that cleans up the SSM secret.
/// Uses Pattern B: manual deployment_repo.create + direct complete_provisioning.
#[tokio::test]
async fn vm_creation_failure_cleans_up_ssm_secret() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, ssm) = default_service();

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

    // VM creation will fail — triggers rollback path.
    vm_provisioner.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(
        result,
        Err(ProvisioningError::ProvisionerFailed(_))
    ));

    // SSM secret should have been created then deleted during rollback.
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM secret should be cleaned up when VM creation fails"
    );

    // Deployment should be marked failed.
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");
    assert!(
        updated.provider_vm_id.is_none(),
        "failed deployment must not retain provisioning claim marker in provider_vm_id"
    );
}

/// DNS creation failure triggers rollback that cleans up both the VM and SSM secret.
#[tokio::test]
async fn dns_creation_failure_cleans_up_vm_and_ssm() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, dns_manager, ssm) =
        default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-dns",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // DNS will fail — triggers full 3-step rollback (DNS fails → destroy VM → delete SSM).
    dns_manager.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(matches!(result, Err(ProvisioningError::DnsFailed(_))));

    // VM should have been created then destroyed during rollback.
    assert_eq!(
        vm_provisioner.vm_count(),
        0,
        "VM should be destroyed when DNS creation fails"
    );

    // SSM secret should have been created then deleted during rollback.
    assert_eq!(
        ssm.secret_count(),
        0,
        "SSM secret should be cleaned up when DNS creation fails"
    );

    // Deployment should be marked failed.
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(updated.status, "failed");
    assert!(
        updated.provider_vm_id.is_none(),
        "failed deployment must not retain provisioning claim marker in provider_vm_id"
    );
}

/// Calling complete_provisioning on a non-provisioning deployment returns InvalidState.
/// This validates the idempotency guard that prevents duplicate VM creation on retry.
#[tokio::test]
async fn complete_provisioning_rejects_non_provisioning_deployment() {
    let (svc, _customer_repo, deployment_repo, _vm, _dns, _ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-idem",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    // Simulate a deployment that already completed provisioning (status = "active").
    deployment_repo
        .update(deployment.id, None, Some("active"))
        .await
        .unwrap();

    // complete_provisioning should reject because status is "active", not "provisioning".
    let result = svc.complete_provisioning(deployment.id).await;
    assert!(
        matches!(result, Err(ProvisioningError::InvalidState(_))),
        "complete_provisioning should reject non-provisioning deployment"
    );
}

/// When SSM delete fails during rollback (create succeeded, then VM fails,
/// then SSM cleanup fails), the deployment should still be marked failed.
/// Rollback errors are best-effort — logged but never leave deployment stuck.
#[tokio::test]
async fn ssm_failure_during_rollback_still_marks_deployment_failed() {
    let customer_repo = common::mock_repo();
    let deployment_repo = common::mock_deployment_repo();
    let vm_provisioner = common::mock_vm_provisioner();
    let dns_manager = common::mock_dns_manager();
    let fail_delete_ssm = FailOnDeleteNodeSecretManager::new();

    let svc = build_service(
        Arc::clone(&customer_repo),
        Arc::clone(&deployment_repo),
        Arc::clone(&vm_provisioner),
        Arc::clone(&dns_manager),
        fail_delete_ssm,
    );

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

    // VM creation fails → triggers rollback → SSM delete also fails.
    vm_provisioner.set_should_fail(true);

    let result = svc.complete_provisioning(deployment.id).await;
    assert!(result.is_err());

    // Deployment should still be marked "failed" even though SSM cleanup errored.
    let updated = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        updated.status, "failed",
        "deployment must be marked failed even when SSM rollback itself fails"
    );
    assert!(
        updated.provider_vm_id.is_none(),
        "failed deployment must not retain provisioning claim marker in provider_vm_id"
    );
}

// ---------------------------------------------------------------------------
// Class 3: Concurrent mutating provisioning requests
// ---------------------------------------------------------------------------

/// Two concurrent complete_provisioning calls on the same deployment exercise
/// the read-then-act race window. Exactly one caller should atomically claim
/// the deployment and succeed; the loser should fail fast with InvalidState
/// before creating VM/DNS/secret side effects.
#[tokio::test]
async fn concurrent_complete_provisioning_single_winner_no_duplicate_side_effects() {
    let (svc, _customer_repo, deployment_repo, vm_provisioner, _dns, ssm) = default_service();

    let customer_id = Uuid::new_v4();
    let deployment = deployment_repo
        .create(
            customer_id,
            "node-race",
            "us-east-1",
            "t4g.small",
            "aws",
            None,
        )
        .await
        .unwrap();

    let dep_id = deployment.id;

    // Spawn two concurrent complete_provisioning calls on the SAME deployment.
    let task1 = tokio::spawn({
        let svc = Arc::clone(&svc);
        async move { svc.complete_provisioning(dep_id).await }
    });
    let task2 = tokio::spawn({
        let svc = Arc::clone(&svc);
        async move { svc.complete_provisioning(dep_id).await }
    });

    let (r1, r2) = tokio::join!(task1, task2);
    let result1 = r1.expect("task1 should not panic");
    let result2 = r2.expect("task2 should not panic");

    // Exactly one caller must succeed.
    let successes = [&result1, &result2].iter().filter(|r| r.is_ok()).count();
    assert_eq!(successes, 1, "exactly one concurrent call should succeed");

    // Losing caller should fail fast with InvalidState.
    let invalid_state_failures = [&result1, &result2]
        .iter()
        .filter(|r| matches!(r, Err(ProvisioningError::InvalidState(_))))
        .count();
    assert_eq!(
        invalid_state_failures, 1,
        "one concurrent call should fail with InvalidState"
    );

    // Deployment must have provisioning fields filled in (not half-provisioned).
    let final_dep = deployment_repo
        .find_by_id(deployment.id)
        .await
        .unwrap()
        .unwrap();
    assert!(
        final_dep.hostname.is_some(),
        "hostname must be set after provisioning"
    );
    assert!(
        final_dep.flapjack_url.is_some(),
        "flapjack_url must be set after provisioning"
    );

    // Infrastructure accounting: exactly one VM and one SSM key should exist.
    assert_eq!(
        vm_provisioner.vm_count(),
        1,
        "exactly one VM should be created"
    );
    assert_eq!(
        ssm.secret_count(),
        1,
        "exactly one SSM key should be created"
    );
}
