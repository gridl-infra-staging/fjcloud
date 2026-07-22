use std::sync::{Arc, Mutex};

use api::dns::{DnsError, DnsManager};
use api::provisioner::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};
use api::secrets::{mock::MockNodeSecretManager, NodeSecretError, NodeSecretManager};
use api::services::provisioning::{
    ProvisioningService, VmInstanceTeardownTarget, VmTeardownOutcome, VmTeardownPolicy,
    DEFAULT_DNS_DOMAIN,
};

#[derive(Clone, Default)]
struct TeardownEvents {
    events: Arc<Mutex<Vec<String>>>,
}

impl TeardownEvents {
    fn push(&self, event: impl Into<String>) {
        self.events.lock().unwrap().push(event.into());
    }

    fn snapshot(&self) -> Vec<String> {
        self.events.lock().unwrap().clone()
    }
}

struct RecordingVmProvisioner {
    events: TeardownEvents,
    fail_destroy: bool,
}

struct RecordingDnsManager {
    events: TeardownEvents,
}

struct RecordingNodeSecretManager {
    events: TeardownEvents,
}

#[async_trait::async_trait]
impl VmProvisioner for RecordingVmProvisioner {
    async fn create_vm(&self, _config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        unreachable!("teardown tests must not create VMs")
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.events.push(format!("destroy_vm:{provider_vm_id}"));
        if self.fail_destroy {
            Err(VmProvisionerError::Api("destroy failed".into()))
        } else {
            Ok(())
        }
    }

    async fn stop_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        unreachable!("teardown tests must not stop VMs")
    }

    async fn start_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        unreachable!("teardown tests must not start VMs")
    }

    async fn get_vm_status(&self, _provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        unreachable!("teardown tests must not query VM status")
    }
}

#[async_trait::async_trait]
impl DnsManager for RecordingDnsManager {
    async fn create_record(&self, _hostname: &str, _ip: &str) -> Result<(), DnsError> {
        unreachable!("teardown tests must not create DNS records")
    }

    async fn delete_record(&self, hostname: &str) -> Result<(), DnsError> {
        self.events.push(format!("delete_record:{hostname}"));
        Ok(())
    }
}

#[async_trait::async_trait]
impl NodeSecretManager for RecordingNodeSecretManager {
    async fn create_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        unreachable!("teardown tests must not create node keys")
    }

    async fn delete_node_api_key(
        &self,
        node_id: &str,
        region: &str,
    ) -> Result<(), NodeSecretError> {
        self.events
            .push(format!("delete_node_api_key:{node_id}:{region}"));
        Ok(())
    }

    async fn get_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<String, NodeSecretError> {
        unreachable!("teardown tests must not read node keys")
    }

    async fn rotate_node_api_key(
        &self,
        _node_id: &str,
        _region: &str,
    ) -> Result<(String, String), NodeSecretError> {
        unreachable!("teardown tests must not rotate node keys")
    }

    async fn commit_rotation(
        &self,
        _node_id: &str,
        _region: &str,
        _old_key: &str,
    ) -> Result<(), NodeSecretError> {
        unreachable!("teardown tests must not commit node key rotations")
    }
}

fn recording_service(fail_destroy: bool) -> (Arc<ProvisioningService>, TeardownEvents) {
    let events = TeardownEvents::default();
    let service = Arc::new(ProvisioningService::new(
        Arc::new(RecordingVmProvisioner {
            events: events.clone(),
            fail_destroy,
        }),
        Arc::new(RecordingDnsManager {
            events: events.clone(),
        }),
        Arc::new(RecordingNodeSecretManager {
            events: events.clone(),
        }),
        crate::common::mock_deployment_repo(),
        crate::common::mock_repo(),
        DEFAULT_DNS_DOMAIN.to_string(),
    ));

    (service, events)
}

#[tokio::test]
async fn teardown_vm_resources_deletes_instance_first_and_reports_removed_resources() {
    let (service, events) = recording_service(false);

    let report = service
        .teardown_vm_resources(
            Some("vm-shared-a.flapjack.foo"),
            VmInstanceTeardownTarget::provider_vm_id(Some("provider-vm-1")),
            "node-a",
            "us-east-1",
            VmTeardownPolicy::ContinueBestEffort,
        )
        .await;

    assert_eq!(
        events.snapshot(),
        vec![
            "destroy_vm:provider-vm-1",
            "delete_record:vm-shared-a.flapjack.foo",
            "delete_node_api_key:node-a:us-east-1",
        ]
    );
    assert_eq!(report.instance, VmTeardownOutcome::Removed);
    assert_eq!(report.dns_record, VmTeardownOutcome::Removed);
    assert_eq!(report.node_api_key, VmTeardownOutcome::Removed);
}

#[tokio::test]
async fn teardown_vm_resources_halt_teardown_skips_dns_and_key_after_instance_failure() {
    let (service, events) = recording_service(true);

    let report = service
        .teardown_vm_resources(
            Some("vm-shared-b.flapjack.foo"),
            VmInstanceTeardownTarget::provider_vm_id(Some("provider-vm-2")),
            "node-b",
            "us-east-1",
            VmTeardownPolicy::HaltTeardown,
        )
        .await;

    assert_eq!(events.snapshot(), vec!["destroy_vm:provider-vm-2"]);
    assert!(matches!(
        report.instance,
        VmTeardownOutcome::Failed { ref message } if message.contains("destroy failed")
    ));
    assert!(matches!(
        report.dns_record,
        VmTeardownOutcome::Skipped { ref reason } if reason == "instance_teardown_failed"
    ));
    assert!(matches!(
        report.node_api_key,
        VmTeardownOutcome::Skipped { ref reason } if reason == "instance_teardown_failed"
    ));
}

#[tokio::test]
async fn teardown_vm_resources_continue_best_effort_continues_after_instance_failure() {
    let (service, events) = recording_service(true);

    let report = service
        .teardown_vm_resources(
            Some("vm-shared-c.flapjack.foo"),
            VmInstanceTeardownTarget::provider_vm_id(Some("provider-vm-3")),
            "node-c",
            "us-east-1",
            VmTeardownPolicy::ContinueBestEffort,
        )
        .await;

    assert_eq!(
        events.snapshot(),
        vec![
            "destroy_vm:provider-vm-3",
            "delete_record:vm-shared-c.flapjack.foo",
            "delete_node_api_key:node-c:us-east-1",
        ]
    );
    assert!(matches!(report.instance, VmTeardownOutcome::Failed { .. }));
    assert_eq!(report.dns_record, VmTeardownOutcome::Removed);
    assert_eq!(report.node_api_key, VmTeardownOutcome::Removed);
}

#[tokio::test]
async fn teardown_vm_resources_absent_provider_vm_id_and_hostname_are_not_applicable() {
    let (service, events) = recording_service(false);

    let report = service
        .teardown_vm_resources(
            None,
            VmInstanceTeardownTarget::provider_vm_id(None),
            "node-d",
            "us-east-1",
            VmTeardownPolicy::HaltTeardown,
        )
        .await;

    assert_eq!(
        events.snapshot(),
        vec!["delete_node_api_key:node-d:us-east-1"]
    );
    assert_eq!(report.instance, VmTeardownOutcome::NotApplicable);
    assert_eq!(report.dns_record, VmTeardownOutcome::NotApplicable);
    assert_eq!(report.node_api_key, VmTeardownOutcome::Removed);
}

#[tokio::test]
async fn teardown_vm_resources_deletes_current_and_previous_node_api_keys() {
    let vm_provisioner = api::provisioner::mock::MockVmProvisioner::new();
    let dns_manager = api::dns::mock::MockDnsManager::new();
    let node_secret_manager = Arc::new(MockNodeSecretManager::new());
    node_secret_manager
        .create_node_api_key("node-e", "us-east-1")
        .await
        .unwrap();
    node_secret_manager
        .rotate_node_api_key("node-e", "us-east-1")
        .await
        .unwrap();

    let service = ProvisioningService::new(
        Arc::new(vm_provisioner),
        Arc::new(dns_manager),
        node_secret_manager.clone(),
        crate::common::mock_deployment_repo(),
        crate::common::mock_repo(),
        DEFAULT_DNS_DOMAIN.to_string(),
    );

    let report = service
        .teardown_vm_resources(
            None,
            VmInstanceTeardownTarget::provider_vm_id(None),
            "node-e",
            "us-east-1",
            VmTeardownPolicy::ContinueBestEffort,
        )
        .await;

    assert_eq!(report.node_api_key, VmTeardownOutcome::Removed);
    assert!(
        node_secret_manager.get_secret("node-e").is_none(),
        "current node API key must be deleted"
    );
    assert!(
        node_secret_manager.get_previous_secret("node-e").is_none(),
        "previous node API key must be deleted"
    );
}
