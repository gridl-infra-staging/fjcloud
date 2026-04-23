use api::provisioner::mock::MockVmProvisioner;
use api::provisioner::{
    CreateVmRequest, UnconfiguredVmProvisioner, VmProvisioner, VmProvisionerError, VmStatus,
};
use uuid::Uuid;

fn test_create_request() -> CreateVmRequest {
    CreateVmRequest {
        region: "us-east-1".to_string(),
        vm_type: "t4g.small".to_string(),
        hostname: "vm-abcd1234.flapjack.foo".to_string(),
        customer_id: Uuid::new_v4(),
        node_id: "node-test-1".to_string(),
        user_data: None,
    }
}

#[tokio::test]
async fn mock_create_vm_returns_instance() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();

    let instance = provisioner.create_vm(&req).await.unwrap();

    assert!(instance.provider_vm_id.starts_with("mock-"));
    assert!(instance.public_ip.is_some());
    assert!(instance.private_ip.is_some());
    assert_eq!(instance.status, VmStatus::Pending);
    assert_eq!(instance.region, "us-east-1");
}

#[tokio::test]
async fn mock_destroy_vm_removes_instance() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();
    let instance = provisioner.create_vm(&req).await.unwrap();
    let vm_id = instance.provider_vm_id.clone();

    provisioner.destroy_vm(&vm_id).await.unwrap();

    let result = provisioner.get_vm_status(&vm_id).await;
    assert!(matches!(result, Err(VmProvisionerError::VmNotFound(_))));
}

#[tokio::test]
async fn mock_stop_start_changes_status() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();
    let instance = provisioner.create_vm(&req).await.unwrap();
    let vm_id = instance.provider_vm_id.clone();

    // Must be running to stop — set to running first
    provisioner.start_vm(&vm_id).await.unwrap(); // Pending -> Running
    let status = provisioner.get_vm_status(&vm_id).await.unwrap();
    assert_eq!(status, VmStatus::Running);

    // Stop
    provisioner.stop_vm(&vm_id).await.unwrap();
    let status = provisioner.get_vm_status(&vm_id).await.unwrap();
    assert_eq!(status, VmStatus::Stopped);

    // Start again
    provisioner.start_vm(&vm_id).await.unwrap();
    let status = provisioner.get_vm_status(&vm_id).await.unwrap();
    assert_eq!(status, VmStatus::Running);
}

#[tokio::test]
async fn mock_get_status_returns_current() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();
    let instance = provisioner.create_vm(&req).await.unwrap();

    let status = provisioner
        .get_vm_status(&instance.provider_vm_id)
        .await
        .unwrap();
    assert_eq!(status, VmStatus::Pending);
}

#[tokio::test]
async fn mock_destroy_nonexistent_is_idempotent() {
    // EC2 TerminateInstances is idempotent: terminating an already-terminated
    // or non-existent instance returns success. The mock must match this.
    let provisioner = MockVmProvisioner::new();

    let result = provisioner.destroy_vm("nonexistent-vm-id").await;
    assert!(
        result.is_ok(),
        "destroying a non-existent VM must succeed (idempotent, matches EC2 TerminateInstances)"
    );
}

#[tokio::test]
async fn mock_failure_injection_works() {
    let provisioner = MockVmProvisioner::new();
    provisioner.set_should_fail(true);

    let req = test_create_request();
    let result = provisioner.create_vm(&req).await;
    assert!(matches!(result, Err(VmProvisionerError::Api(_))));

    // Disable failure
    provisioner.set_should_fail(false);
    let instance = provisioner.create_vm(&req).await.unwrap();
    assert!(instance.provider_vm_id.starts_with("mock-"));
}

#[tokio::test]
async fn mock_stop_pending_returns_invalid_state() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();
    let instance = provisioner.create_vm(&req).await.unwrap();

    // VM is in Pending state — stop should fail
    let result = provisioner.stop_vm(&instance.provider_vm_id).await;
    assert!(
        matches!(result, Err(VmProvisionerError::InvalidState(_))),
        "stopping a Pending VM must return InvalidState"
    );
}

#[tokio::test]
async fn mock_start_running_returns_invalid_state() {
    let provisioner = MockVmProvisioner::new();
    let req = test_create_request();
    let instance = provisioner.create_vm(&req).await.unwrap();
    let vm_id = instance.provider_vm_id.clone();

    // Pending -> Running
    provisioner.start_vm(&vm_id).await.unwrap();
    assert_eq!(
        provisioner.get_vm_status(&vm_id).await.unwrap(),
        VmStatus::Running
    );

    // Starting an already Running VM should fail
    let result = provisioner.start_vm(&vm_id).await;
    assert!(
        matches!(result, Err(VmProvisionerError::InvalidState(_))),
        "starting an already Running VM must return InvalidState"
    );
}

#[tokio::test]
async fn unconfigured_create_vm_returns_not_configured() {
    let provisioner = UnconfiguredVmProvisioner;
    let req = test_create_request();

    let result = provisioner.create_vm(&req).await;
    assert!(matches!(result, Err(VmProvisionerError::NotConfigured)));
}

#[tokio::test]
async fn unconfigured_destroy_vm_returns_not_configured() {
    let provisioner = UnconfiguredVmProvisioner;

    let result = provisioner.destroy_vm("any-id").await;
    assert!(matches!(result, Err(VmProvisionerError::NotConfigured)));
}

#[tokio::test]
async fn unconfigured_get_vm_status_returns_not_configured() {
    let provisioner = UnconfiguredVmProvisioner;

    let result = provisioner.get_vm_status("any-id").await;
    assert!(matches!(result, Err(VmProvisionerError::NotConfigured)));
}

#[tokio::test]
async fn unconfigured_stop_vm_returns_not_configured() {
    let provisioner = UnconfiguredVmProvisioner;

    let result = provisioner.stop_vm("any-id").await;
    assert!(matches!(result, Err(VmProvisionerError::NotConfigured)));
}

#[tokio::test]
async fn unconfigured_start_vm_returns_not_configured() {
    let provisioner = UnconfiguredVmProvisioner;

    let result = provisioner.start_vm("any-id").await;
    assert!(matches!(result, Err(VmProvisionerError::NotConfigured)));
}

#[tokio::test]
async fn mock_stop_nonexistent_returns_vm_not_found() {
    let provisioner = MockVmProvisioner::new();

    let result = provisioner.stop_vm("nonexistent-id").await;
    assert!(
        matches!(result, Err(VmProvisionerError::VmNotFound(_))),
        "stopping a nonexistent VM must return VmNotFound"
    );
}

#[tokio::test]
async fn mock_start_nonexistent_returns_vm_not_found() {
    let provisioner = MockVmProvisioner::new();

    let result = provisioner.start_vm("nonexistent-id").await;
    assert!(
        matches!(result, Err(VmProvisionerError::VmNotFound(_))),
        "starting a nonexistent VM must return VmNotFound"
    );
}

#[tokio::test]
async fn mock_get_status_nonexistent_returns_vm_not_found() {
    let provisioner = MockVmProvisioner::new();

    let result = provisioner.get_vm_status("nonexistent-id").await;
    assert!(
        matches!(result, Err(VmProvisionerError::VmNotFound(_))),
        "get_vm_status on nonexistent VM must return VmNotFound"
    );
}

#[tokio::test]
async fn mock_vm_count_reflects_creates_and_destroys() {
    let provisioner = MockVmProvisioner::new();
    assert_eq!(provisioner.vm_count(), 0);

    let req = test_create_request();
    let vm1 = provisioner.create_vm(&req).await.unwrap();
    assert_eq!(provisioner.vm_count(), 1);

    let req2 = CreateVmRequest {
        node_id: "node-test-2".to_string(),
        ..test_create_request()
    };
    let vm2 = provisioner.create_vm(&req2).await.unwrap();
    assert_eq!(provisioner.vm_count(), 2);

    provisioner.destroy_vm(&vm1.provider_vm_id).await.unwrap();
    assert_eq!(provisioner.vm_count(), 1);

    provisioner.destroy_vm(&vm2.provider_vm_id).await.unwrap();
    assert_eq!(provisioner.vm_count(), 0);
}
