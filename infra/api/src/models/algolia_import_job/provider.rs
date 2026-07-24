use crate::provisioner::region_map::RegionConfig;

use super::AlgoliaImportErrorCode;

pub fn validate_algolia_create_provider(
    config: &RegionConfig,
    region: &str,
) -> Result<(), AlgoliaImportErrorCode> {
    match config.get_available_region(region) {
        Some(entry) if entry.provider == "aws" => Ok(()),
        _ => Err(AlgoliaImportErrorCode::MigrationProviderUnsupported),
    }
}

pub fn algolia_eligible_regions(
    config: &RegionConfig,
) -> Vec<(&String, &crate::provisioner::region_map::RegionEntry)> {
    config
        .available_regions()
        .into_iter()
        .filter(|(_, entry)| entry.provider == "aws")
        .collect()
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AlgoliaReplaceTargetFacts {
    pub provider: String,
    pub vm_status: String,
    pub deployment_status: String,
    pub health_status: String,
    pub service_type: String,
    pub has_active_lifecycle_operation: bool,
    pub has_active_import_lease: bool,
    pub has_flapjack_url: bool,
}

impl AlgoliaReplaceTargetFacts {
    pub fn validate(&self) -> Result<(), AlgoliaImportErrorCode> {
        if self.provider != "aws" {
            return Err(AlgoliaImportErrorCode::MigrationProviderUnsupported);
        }
        if self.service_type != "flapjack" {
            return Err(AlgoliaImportErrorCode::MigrationHaNotSupported);
        }
        if self.vm_status != "active" || self.deployment_status != "active" {
            return Err(AlgoliaImportErrorCode::BackendUnavailable);
        }
        if self.health_status != "healthy" {
            return Err(AlgoliaImportErrorCode::BackendUnavailable);
        }
        if !self.has_flapjack_url {
            return Err(AlgoliaImportErrorCode::BackendUnavailable);
        }
        if self.has_active_lifecycle_operation || self.has_active_import_lease {
            return Err(AlgoliaImportErrorCode::DestinationConflict);
        }
        Ok(())
    }
}
