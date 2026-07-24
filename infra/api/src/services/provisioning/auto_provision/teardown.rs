use std::collections::BTreeSet;

use serde::ser::SerializeMap;
use serde::{Serialize, Serializer};
use tracing::error;

use crate::models::{CustomerTenant, VmInventory};

use super::super::{ProvisioningError, ProvisioningService};

const INSTANCE_TEARDOWN_FAILED_REASON: &str = "instance_teardown_failed";

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum VmTeardownPolicy {
    HaltTeardown,
    ContinueBestEffort,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VmTeardownOutcome {
    Removed,
    Failed { message: String },
    Indeterminate { message: String },
    NotApplicable,
    Skipped { reason: String },
}

impl VmTeardownOutcome {
    fn status(&self) -> &'static str {
        match self {
            Self::Removed => "removed",
            Self::Failed { .. } => "failed",
            Self::Indeterminate { .. } => "indeterminate",
            Self::NotApplicable => "not_applicable",
            Self::Skipped { .. } => "skipped",
        }
    }

    fn clean(&self) -> bool {
        matches!(self, Self::Removed | Self::NotApplicable)
    }
}

impl Serialize for VmTeardownOutcome {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        let field_count = match self {
            Self::Failed { .. } | Self::Indeterminate { .. } | Self::Skipped { .. } => 3,
            Self::Removed | Self::NotApplicable => 2,
        };
        let mut map = serializer.serialize_map(Some(field_count))?;
        map.serialize_entry("status", self.status())?;
        map.serialize_entry("clean", &self.clean())?;
        match self {
            Self::Failed { message } | Self::Indeterminate { message } => {
                map.serialize_entry("message", message)?;
            }
            Self::Skipped { reason } => {
                map.serialize_entry("reason", reason)?;
            }
            Self::Removed | Self::NotApplicable => {}
        }
        map.end()
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct VmTeardownReport {
    pub instance: VmTeardownOutcome,
    pub dns_record: VmTeardownOutcome,
    pub node_api_key: VmTeardownOutcome,
}

impl VmTeardownReport {
    pub fn is_clean(&self) -> bool {
        self.instance.clean() && self.dns_record.clean() && self.node_api_key.clean()
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum VmInstanceTeardownTarget {
    ProviderVmId(Option<String>),
    Indeterminate { message: String },
}

impl VmInstanceTeardownTarget {
    pub fn provider_vm_id(provider_vm_id: Option<&str>) -> Self {
        Self::ProviderVmId(provider_vm_id.map(str::to_string))
    }
}

impl ProvisioningService {
    /// Remove provider, DNS, and node-key resources in the requested failure policy.
    pub async fn teardown_vm_resources(
        &self,
        hostname: Option<&str>,
        instance_target: VmInstanceTeardownTarget,
        node_id: &str,
        region: &str,
        policy: VmTeardownPolicy,
    ) -> VmTeardownReport {
        let instance = self.teardown_vm_instance(instance_target).await;
        if policy == VmTeardownPolicy::HaltTeardown
            && matches!(
                instance,
                VmTeardownOutcome::Failed { .. } | VmTeardownOutcome::Indeterminate { .. }
            )
        {
            return VmTeardownReport {
                instance,
                dns_record: skipped_after_instance_failure(),
                node_api_key: skipped_after_instance_failure(),
            };
        }

        VmTeardownReport {
            instance,
            dns_record: self.teardown_vm_dns_record(hostname).await,
            node_api_key: self.teardown_vm_node_api_key(node_id, region).await,
        }
    }

    /// Resolve and remove external resources for an identity-checked,
    /// decommissioned inventory row.
    pub async fn teardown_retired_vm_resources(
        &self,
        vm: &VmInventory,
        known_tenants: &[CustomerTenant],
    ) -> Result<VmTeardownReport, ProvisioningError> {
        let instance_target = self.retirement_instance_target(vm, known_tenants).await?;
        Ok(self
            .teardown_vm_resources(
                Some(&vm.hostname),
                instance_target,
                vm.node_secret_id(),
                &vm.region,
                VmTeardownPolicy::HaltTeardown,
            )
            .await)
    }

    async fn retirement_instance_target(
        &self,
        vm: &VmInventory,
        known_tenants: &[CustomerTenant],
    ) -> Result<VmInstanceTeardownTarget, ProvisioningError> {
        if let Some(provider_vm_id) = self.provider_vm_id_from_tenants(vm, known_tenants).await? {
            return Ok(VmInstanceTeardownTarget::ProviderVmId(Some(provider_vm_id)));
        }
        if let Some(provider_vm_id) = self.provider_vm_id_from_fleet(vm).await? {
            return Ok(VmInstanceTeardownTarget::ProviderVmId(Some(provider_vm_id)));
        }

        match self
            .vm_provisioner
            .find_managed_vm_by_hostname(&vm.provider, &vm.region, &vm.hostname)
            .await
        {
            Ok(Some(instance)) => Ok(VmInstanceTeardownTarget::ProviderVmId(Some(
                instance.provider_vm_id,
            ))),
            Ok(None) => Ok(VmInstanceTeardownTarget::ProviderVmId(None)),
            Err(error) => Ok(VmInstanceTeardownTarget::Indeterminate {
                message: error.to_string(),
            }),
        }
    }

    async fn provider_vm_id_from_tenants(
        &self,
        vm: &VmInventory,
        tenants: &[CustomerTenant],
    ) -> Result<Option<String>, ProvisioningError> {
        let mut provider_ids = BTreeSet::new();
        for tenant in tenants {
            if let Some(deployment) = self
                .deployment_repo
                .find_by_id(tenant.deployment_id)
                .await
                .map_err(|error| ProvisioningError::RepoError(error.to_string()))?
            {
                if deployment.vm_provider == vm.provider
                    && deployment.flapjack_url.as_deref() == Some(vm.flapjack_url.as_str())
                {
                    if let Some(provider_vm_id) = deployment.provider_vm_id {
                        provider_ids.insert(provider_vm_id);
                    }
                }
            }
        }
        Ok(unique_provider_vm_id(provider_ids))
    }

    async fn provider_vm_id_from_fleet(
        &self,
        vm: &VmInventory,
    ) -> Result<Option<String>, ProvisioningError> {
        let deployments = self
            .deployment_repo
            .list_active()
            .await
            .map_err(|error| ProvisioningError::RepoError(error.to_string()))?;
        Ok(unique_provider_vm_id(
            deployments
                .into_iter()
                .filter(|deployment| {
                    deployment.vm_provider == vm.provider
                        && deployment.flapjack_url.as_deref() == Some(vm.flapjack_url.as_str())
                })
                .filter_map(|deployment| deployment.provider_vm_id),
        ))
    }

    async fn teardown_vm_instance(
        &self,
        instance_target: VmInstanceTeardownTarget,
    ) -> VmTeardownOutcome {
        let provider_vm_id = match instance_target {
            VmInstanceTeardownTarget::ProviderVmId(Some(provider_vm_id)) => provider_vm_id,
            VmInstanceTeardownTarget::ProviderVmId(None) => {
                return VmTeardownOutcome::NotApplicable;
            }
            VmInstanceTeardownTarget::Indeterminate { message } => {
                return VmTeardownOutcome::Indeterminate { message };
            }
        };

        match self.vm_provisioner.destroy_vm(&provider_vm_id).await {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(error) => {
                error!("teardown: failed to destroy VM {provider_vm_id}: {error}");
                VmTeardownOutcome::Failed {
                    message: error.to_string(),
                }
            }
        }
    }

    async fn teardown_vm_dns_record(&self, hostname: Option<&str>) -> VmTeardownOutcome {
        let Some(hostname) = hostname else {
            return VmTeardownOutcome::NotApplicable;
        };

        match self.dns_manager.delete_record(hostname).await {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(error) => {
                error!("teardown: failed to delete DNS record for {hostname}: {error}");
                VmTeardownOutcome::Failed {
                    message: error.to_string(),
                }
            }
        }
    }

    async fn teardown_vm_node_api_key(&self, node_id: &str, region: &str) -> VmTeardownOutcome {
        match self
            .node_secret_manager
            .delete_node_api_key(node_id, region)
            .await
        {
            Ok(()) => VmTeardownOutcome::Removed,
            Err(error) => {
                error!("teardown: failed to delete node API keys for {node_id}: {error}");
                VmTeardownOutcome::Failed {
                    message: error.to_string(),
                }
            }
        }
    }
}

fn unique_provider_vm_id(provider_ids: impl IntoIterator<Item = String>) -> Option<String> {
    let provider_ids = provider_ids.into_iter().collect::<BTreeSet<_>>();
    (provider_ids.len() == 1)
        .then(|| provider_ids.into_iter().next())
        .flatten()
}

fn skipped_after_instance_failure() -> VmTeardownOutcome {
    VmTeardownOutcome::Skipped {
        reason: INSTANCE_TEARDOWN_FAILED_REASON.to_string(),
    }
}
