//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/multi.rs.
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;

use super::region_map::RegionConfig;
use super::{CreateVmRequest, VmInstance, VmProvisioner, VmProvisionerError, VmStatus};

/// Routes provisioning calls to the correct provider based on region config.
///
/// For `create_vm`, resolves provider from the request's region.
/// For `destroy_vm`/`stop_vm`/`start_vm`/`get_vm_status`, the caller must
/// encode the provider in the `provider_vm_id` as `"{provider}:{id}"`.
/// The `ProvisioningService` stores this composite ID in `vm_inventory`.
pub struct MultiProviderProvisioner {
    providers: HashMap<String, Arc<dyn VmProvisioner>>,
    region_config: RegionConfig,
}

impl MultiProviderProvisioner {
    pub fn new(
        providers: HashMap<String, Arc<dyn VmProvisioner>>,
        region_config: RegionConfig,
    ) -> Self {
        Self {
            providers,
            region_config,
        }
    }

    /// Encode a provider-qualified VM ID: `"{provider}:{provider_vm_id}"`.
    pub fn encode_vm_id(provider: &str, provider_vm_id: &str) -> String {
        format!("{provider}:{provider_vm_id}")
    }

    /// Decode a provider-qualified VM ID into `(provider, provider_vm_id)`.
    fn decode_vm_id(composite_id: &str) -> Result<(&str, &str), VmProvisionerError> {
        composite_id.split_once(':').ok_or_else(|| {
            VmProvisionerError::Api(format!(
                "invalid composite VM ID (expected 'provider:id'): {composite_id}"
            ))
        })
    }

    fn get_provider(&self, name: &str) -> Result<&Arc<dyn VmProvisioner>, VmProvisionerError> {
        self.providers
            .get(name)
            .ok_or_else(|| VmProvisionerError::Api(format!("provider '{name}' not configured")))
    }

    pub fn region_config(&self) -> &RegionConfig {
        &self.region_config
    }
}

#[async_trait]
impl VmProvisioner for MultiProviderProvisioner {
    /// Resolves the provider for the requested region, delegates to the provider-specific `create_vm`, then encodes the provider name into a composite VM ID (`provider:id`) so future operations can route back to the correct provider.
    async fn create_vm(&self, req: &CreateVmRequest) -> Result<VmInstance, VmProvisionerError> {
        let region = self
            .region_config
            .get_region(&req.region)
            .ok_or_else(|| VmProvisionerError::Api(format!("unknown region: {}", req.region)))?;

        let provider_name = region.provider.as_str();
        let provider = self.get_provider(provider_name)?;

        let mut provider_req = req.clone();
        provider_req.region = region.provider_location.clone();

        let mut instance = provider.create_vm(&provider_req).await?;
        instance.region = req.region.clone();

        // Encode provider into the VM ID so destroy/stop/start can route correctly
        instance.provider_vm_id = Self::encode_vm_id(provider_name, &instance.provider_vm_id);

        Ok(instance)
    }

    async fn destroy_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (provider_name, raw_id) = Self::decode_vm_id(provider_vm_id)?;
        let provider = self.get_provider(provider_name)?;
        provider.destroy_vm(raw_id).await
    }

    async fn stop_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (provider_name, raw_id) = Self::decode_vm_id(provider_vm_id)?;
        let provider = self.get_provider(provider_name)?;
        provider.stop_vm(raw_id).await
    }

    async fn start_vm(&self, provider_vm_id: &str) -> Result<(), VmProvisionerError> {
        let (provider_name, raw_id) = Self::decode_vm_id(provider_vm_id)?;
        let provider = self.get_provider(provider_name)?;
        provider.start_vm(raw_id).await
    }

    async fn get_vm_status(&self, provider_vm_id: &str) -> Result<VmStatus, VmProvisionerError> {
        let (provider_name, raw_id) = Self::decode_vm_id(provider_vm_id)?;
        let provider = self.get_provider(provider_name)?;
        provider.get_vm_status(raw_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_vm_id_format() {
        let encoded = MultiProviderProvisioner::encode_vm_id("aws", "i-abc123");
        assert_eq!(encoded, "aws:i-abc123");
    }

    #[test]
    fn decode_vm_id_valid() {
        let (provider, id) = MultiProviderProvisioner::decode_vm_id("aws:i-abc123").unwrap();
        assert_eq!(provider, "aws");
        assert_eq!(id, "i-abc123");
    }

    #[test]
    fn decode_vm_id_with_colons_in_id() {
        // Some providers might have IDs with colons — decode should split on first colon only
        let (provider, id) =
            MultiProviderProvisioner::decode_vm_id("gcp:projects/p/zones/z/instances/i").unwrap();
        assert_eq!(provider, "gcp");
        assert_eq!(id, "projects/p/zones/z/instances/i");
    }

    #[test]
    fn decode_vm_id_no_colon_returns_error() {
        let result = MultiProviderProvisioner::decode_vm_id("no-colon-here");
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(
            err.to_string().contains("invalid composite VM ID"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn decode_vm_id_empty_provider() {
        // ":some-id" should decode with empty provider
        let (provider, id) = MultiProviderProvisioner::decode_vm_id(":some-id").unwrap();
        assert_eq!(provider, "");
        assert_eq!(id, "some-id");
    }

    #[test]
    fn encode_decode_roundtrip() {
        let encoded = MultiProviderProvisioner::encode_vm_id("hetzner", "srv-42");
        let (provider, id) = MultiProviderProvisioner::decode_vm_id(&encoded).unwrap();
        assert_eq!(provider, "hetzner");
        assert_eq!(id, "srv-42");
    }
}
