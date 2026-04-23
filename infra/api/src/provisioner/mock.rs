//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/mock.rs.
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use uuid::Uuid;

use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

pub struct MockVmProvisioner {
    vms: Mutex<HashMap<String, VmInstance>>,
    last_create_request: Mutex<Option<CreateVmRequest>>,
    pub should_fail: Arc<AtomicBool>,
    pub omit_public_ip: Arc<AtomicBool>,
}

impl MockVmProvisioner {
    pub fn new() -> Self {
        Self {
            vms: Mutex::new(HashMap::new()),
            last_create_request: Mutex::new(None),
            should_fail: Arc::new(AtomicBool::new(false)),
            omit_public_ip: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Returns the last `CreateVmRequest` passed to `create_vm`, if any.
    pub fn last_create_request(&self) -> Option<CreateVmRequest> {
        self.last_create_request.lock().unwrap().clone()
    }

    pub fn set_should_fail(&self, fail: bool) {
        self.should_fail.store(fail, Ordering::SeqCst);
    }

    /// Returns the number of VMs currently tracked (for test assertions).
    pub fn vm_count(&self) -> usize {
        self.vms.lock().unwrap().len()
    }

    /// Seed the mock with a VM in a specific state (for test setup).
    pub fn seed_vm(&self, provider_vm_id: &str, status: VmStatus, region: &str) {
        let instance = VmInstance {
            provider_vm_id: provider_vm_id.to_string(),
            public_ip: Some("203.0.113.1".to_string()),
            private_ip: Some("10.0.0.1".to_string()),
            status,
            region: region.to_string(),
        };
        self.vms
            .lock()
            .unwrap()
            .insert(provider_vm_id.to_string(), instance);
    }

    fn check_failure(&self) -> Result<(), VmProvisionerError> {
        if self.should_fail.load(Ordering::SeqCst) {
            Err(VmProvisionerError::Api("injected failure".into()))
        } else {
            Ok(())
        }
    }
}

impl Default for MockVmProvisioner {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl VmProvisioner for MockVmProvisioner {
    /// Generates a `mock-{uuid}` VM, stores it in the in-memory map, and records the request for later assertion. Respects `should_fail` (returns injected error) and `omit_public_ip` (leaves `public_ip` as `None`).
    async fn create_vm(&self, config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        self.check_failure()?;

        *self.last_create_request.lock().unwrap() = Some(config.clone());

        let provider_vm_id = format!("mock-{}", Uuid::new_v4());
        let public_ip = if self.omit_public_ip.load(Ordering::SeqCst) {
            None
        } else {
            Some("203.0.113.1".to_string())
        };
        let instance = VmInstance {
            provider_vm_id: provider_vm_id.clone(),
            public_ip,
            private_ip: Some("10.0.0.1".to_string()),
            status: VmStatus::Pending,
            region: config.region.clone(),
        };

        let mut vms = self.vms.lock().unwrap();
        vms.insert(provider_vm_id, instance.clone());
        Ok(instance)
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.check_failure()?;

        // Idempotent: matches real EC2 TerminateInstances behavior where destroying
        // an already-terminated (or non-existent) instance is a no-op.
        self.vms.lock().unwrap().remove(provider_vm_id);
        Ok(())
    }

    /// Transitions a tracked VM from `Running` to `Stopped`. Returns `VmNotFound` if the ID is absent and `InvalidState` if the VM is not `Running`.
    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.check_failure()?;

        let mut vms = self.vms.lock().unwrap();
        let vm = vms
            .get_mut(provider_vm_id)
            .ok_or_else(|| VmProvisionerError::VmNotFound(provider_vm_id.to_string()))?;

        match vm.status {
            VmStatus::Running => {
                vm.status = VmStatus::Stopped;
                Ok(())
            }
            _ => Err(VmProvisionerError::InvalidState(format!(
                "cannot stop VM in {:?} state",
                vm.status
            ))),
        }
    }

    /// Transitions a tracked VM from `Stopped` or `Pending` to `Running`. Returns `VmNotFound` if the ID is absent and `InvalidState` for other states.
    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        self.check_failure()?;

        let mut vms = self.vms.lock().unwrap();
        let vm = vms
            .get_mut(provider_vm_id)
            .ok_or_else(|| VmProvisionerError::VmNotFound(provider_vm_id.to_string()))?;

        match vm.status {
            VmStatus::Stopped | VmStatus::Pending => {
                vm.status = VmStatus::Running;
                Ok(())
            }
            _ => Err(VmProvisionerError::InvalidState(format!(
                "cannot start VM in {:?} state",
                vm.status
            ))),
        }
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        self.check_failure()?;

        let vms = self.vms.lock().unwrap();
        let vm = vms
            .get(provider_vm_id)
            .ok_or_else(|| VmProvisionerError::VmNotFound(provider_vm_id.to_string()))?;

        Ok(vm.status.clone())
    }
}
