pub mod aws;
pub mod cloud_init;
pub(crate) mod env_config;
pub mod gcp;
pub mod hetzner;
pub mod mock;
pub mod multi;
pub mod oci;
pub mod region_map;
pub mod ssh;

use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;
use uuid::Uuid;

#[derive(Debug, thiserror::Error)]
pub enum VmProvisionerError {
    #[error("VM provisioner API error: {0}")]
    Api(String),

    #[error("VM provisioner not configured")]
    NotConfigured,

    #[error("VM not found: {0}")]
    VmNotFound(String),

    #[error("invalid VM state: {0}")]
    InvalidState(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VmStatus {
    Pending,
    Running,
    Stopped,
    Terminated,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct CreateVmRequest {
    pub region: String,
    pub vm_type: String,
    pub hostname: String,
    pub customer_id: Uuid,
    pub node_id: String,
    pub user_data: Option<String>,
}

#[derive(Debug, Clone)]
pub struct VmInstance {
    pub provider_vm_id: String,
    pub public_ip: Option<String>,
    pub private_ip: Option<String>,
    pub status: VmStatus,
    pub region: String,
}

#[async_trait]
pub trait VmProvisioner: Send + Sync {
    async fn create_vm(&self, config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError>;
    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError>;
    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError>;
    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError>;
    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError>;
}

/// Returns `VmProvisionerError::NotConfigured` for all methods.
/// Used in dev mode when `AWS_AMI_ID` is not set.
pub struct UnconfiguredVmProvisioner;

#[async_trait]
impl VmProvisioner for UnconfiguredVmProvisioner {
    async fn create_vm(&self, _config: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        Err(VmProvisionerError::NotConfigured)
    }
    async fn destroy_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Err(VmProvisionerError::NotConfigured)
    }
    async fn stop_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Err(VmProvisionerError::NotConfigured)
    }
    async fn start_vm(&self, _provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        Err(VmProvisionerError::NotConfigured)
    }
    async fn get_vm_status(&self, _provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        Err(VmProvisionerError::NotConfigured)
    }
}

/// Build a VM provisioner from configured provider implementations.
///
/// Returns:
/// - `UnconfiguredVmProvisioner` when no providers are configured.
/// - `MultiProviderProvisioner` when one or more providers are configured.
pub fn build_vm_provisioner(
    providers: HashMap<String, Arc<dyn VmProvisioner>>,
    region_config: region_map::RegionConfig,
) -> Arc<dyn VmProvisioner> {
    if providers.is_empty() {
        Arc::new(UnconfiguredVmProvisioner)
    } else {
        let region_config = effective_region_config(region_config, &providers);
        Arc::new(multi::MultiProviderProvisioner::new(
            providers,
            region_config,
        ))
    }
}

/// Compute the runtime-effective region config by removing regions whose
/// provider implementation is not configured in this process.
///
/// When no providers are configured (dev/test mode), the full region config is
/// kept so that region validation succeeds and the provisioning flow can reach
/// its graceful "no VM provider" path rather than failing at input validation.
pub fn effective_region_config(
    region_config: region_map::RegionConfig,
    providers: &HashMap<String, Arc<dyn VmProvisioner>>,
) -> region_map::RegionConfig {
    if providers.is_empty() {
        return region_config;
    }
    let provider_names = providers.keys().cloned().collect();
    region_config.filter_to_providers(&provider_names)
}
