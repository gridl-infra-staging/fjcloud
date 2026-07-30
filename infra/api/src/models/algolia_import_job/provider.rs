use crate::provisioner::region_map::RegionConfig;

use super::AlgoliaImportErrorCode;

const LOCAL_INTEGRATION_PROVIDER: &str = "local";

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, utoipa::ToSchema,
)]
#[serde(rename_all = "snake_case")]
pub enum SourceImportProvider {
    Algolia,
    Meilisearch,
    Typesense,
}

impl SourceImportProvider {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Algolia => "algolia",
            Self::Meilisearch => "meilisearch",
            Self::Typesense => "typesense",
        }
    }

    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        match value {
            value if value == Self::Algolia.as_str() => Ok(Self::Algolia),
            value if value == Self::Meilisearch.as_str() => Ok(Self::Meilisearch),
            value if value == Self::Typesense.as_str() => Ok(Self::Typesense),
            other => Err(format!(
                "unsupported source provider stored for import job: {other}"
            )),
        }
    }

    pub(crate) fn has_adapter(self) -> bool {
        match self {
            Self::Algolia => true,
            // Meilisearch and Typesense are durable source identities in the
            // closed union, but Stage 2 does not add adapters for either one.
            Self::Meilisearch | Self::Typesense => false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::SourceImportProvider;

    #[test]
    fn source_import_provider_parse_accepts_exact_closed_union() {
        let candidates = ["algolia", "meilisearch", "typesense", "unsupported"];
        let accepted: Vec<&str> = candidates
            .into_iter()
            .filter_map(|candidate| SourceImportProvider::parse(candidate).ok())
            .map(SourceImportProvider::as_str)
            .collect();

        assert_eq!(
            accepted,
            ["algolia", "meilisearch", "typesense"],
            "the source-provider parser must recognize exactly the closed migration union"
        );
    }

    #[test]
    fn source_import_provider_parse_rejects_unsupported_with_exact_error() {
        assert_eq!(
            SourceImportProvider::parse("unsupported"),
            Err("unsupported source provider stored for import job: unsupported".to_string())
        );
    }
}

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
        if !matches!(self.provider.as_str(), "aws" | LOCAL_INTEGRATION_PROVIDER) {
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
