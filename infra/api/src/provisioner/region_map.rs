//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/api/src/provisioner/region_map.rs.
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Metadata for a single region.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RegionEntry {
    pub provider: String,
    pub provider_location: String,
    pub display_name: String,
    pub available: bool,
}

/// Maps customer-facing region IDs (e.g. "us-east-1") to provider-specific
/// location info. Loaded from `REGION_CONFIG` env var or built-in defaults.
#[derive(Debug, Clone)]
pub struct RegionConfig {
    regions: HashMap<String, RegionEntry>,
}

impl RegionConfig {
    pub fn from_regions(regions: HashMap<String, RegionEntry>) -> Self {
        Self { regions }
    }

    /// Load region config from `REGION_CONFIG` env var (JSON) or use defaults.
    pub fn from_env() -> Self {
        if let Ok(json) = std::env::var("REGION_CONFIG") {
            if let Ok(regions) = serde_json::from_str::<HashMap<String, RegionEntry>>(&json) {
                return Self { regions };
            }
            tracing::warn!("REGION_CONFIG env var is not valid JSON, using defaults");
        }
        Self::defaults()
    }

    /// Built-in default region mapping: 2 AWS + 4 Hetzner regions.
    pub fn defaults() -> Self {
        let mut regions = HashMap::new();

        regions.insert(
            "us-east-1".to_string(),
            RegionEntry {
                provider: "aws".to_string(),
                provider_location: "us-east-1".to_string(),
                display_name: "US East (Virginia)".to_string(),
                available: true,
            },
        );
        regions.insert(
            "eu-west-1".to_string(),
            RegionEntry {
                provider: "aws".to_string(),
                provider_location: "eu-west-1".to_string(),
                display_name: "EU West (Ireland)".to_string(),
                available: true,
            },
        );
        regions.insert(
            "eu-central-1".to_string(),
            RegionEntry {
                provider: "hetzner".to_string(),
                provider_location: "fsn1".to_string(),
                display_name: "EU Central (Germany)".to_string(),
                available: true,
            },
        );
        regions.insert(
            "eu-north-1".to_string(),
            RegionEntry {
                provider: "hetzner".to_string(),
                provider_location: "hel1".to_string(),
                display_name: "EU North (Helsinki)".to_string(),
                available: true,
            },
        );
        regions.insert(
            "us-east-2".to_string(),
            RegionEntry {
                provider: "hetzner".to_string(),
                provider_location: "ash".to_string(),
                display_name: "US East (Ashburn)".to_string(),
                available: true,
            },
        );
        regions.insert(
            "us-west-1".to_string(),
            RegionEntry {
                provider: "hetzner".to_string(),
                provider_location: "hil".to_string(),
                display_name: "US West (Oregon)".to_string(),
                available: true,
            },
        );

        Self { regions }
    }

    pub fn get_region(&self, id: &str) -> Option<&RegionEntry> {
        self.regions.get(id)
    }

    pub fn get_available_region(&self, id: &str) -> Option<&RegionEntry> {
        self.regions.get(id).filter(|entry| entry.available)
    }

    pub fn available_regions(&self) -> Vec<(&String, &RegionEntry)> {
        let mut result: Vec<_> = self
            .regions
            .iter()
            .filter(|(_, entry)| entry.available)
            .collect();
        result.sort_by_key(|(id, _)| id.as_str());
        result
    }

    pub fn all_regions(&self) -> Vec<(&String, &RegionEntry)> {
        let mut result: Vec<_> = self.regions.iter().collect();
        result.sort_by_key(|(id, _)| id.as_str());
        result
    }

    pub fn available_region_ids(&self) -> Vec<&str> {
        self.available_regions()
            .iter()
            .map(|(id, _)| id.as_str())
            .collect()
    }

    pub fn provider_for_region(&self, id: &str) -> Option<&str> {
        self.regions.get(id).map(|e| e.provider.as_str())
    }

    /// Return a copy of this config that only includes regions whose provider
    /// is in `providers`.
    pub fn filter_to_providers(&self, providers: &HashSet<String>) -> Self {
        let regions = self
            .regions
            .iter()
            .filter(|(_, entry)| providers.contains(&entry.provider))
            .map(|(id, entry)| (id.clone(), entry.clone()))
            .collect();

        Self { regions }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_has_six_regions() {
        let config = RegionConfig::defaults();
        assert_eq!(config.all_regions().len(), 6);
    }

    #[test]
    fn defaults_all_available() {
        let config = RegionConfig::defaults();
        assert_eq!(
            config.available_regions().len(),
            config.all_regions().len(),
            "all default regions should be available"
        );
    }

    #[test]
    fn get_region_returns_known_region() {
        let config = RegionConfig::defaults();
        let entry = config.get_region("us-east-1").unwrap();
        assert_eq!(entry.provider, "aws");
        assert_eq!(entry.provider_location, "us-east-1");
        assert_eq!(entry.display_name, "US East (Virginia)");
    }

    #[test]
    fn get_region_returns_none_for_unknown() {
        let config = RegionConfig::defaults();
        assert!(config.get_region("ap-southeast-99").is_none());
    }

    /// Verifies `get_available_regions` omits entries with `available: false` and includes those with `available: true`.
    #[test]
    fn get_available_region_filters_unavailable() {
        let mut regions = HashMap::new();
        regions.insert(
            "r1".to_string(),
            RegionEntry {
                provider: "aws".to_string(),
                provider_location: "us-east-1".to_string(),
                display_name: "R1".to_string(),
                available: true,
            },
        );
        regions.insert(
            "r2".to_string(),
            RegionEntry {
                provider: "aws".to_string(),
                provider_location: "us-west-2".to_string(),
                display_name: "R2".to_string(),
                available: false,
            },
        );
        let config = RegionConfig::from_regions(regions);

        assert!(config.get_available_region("r1").is_some());
        assert!(config.get_available_region("r2").is_none());
    }

    #[test]
    fn available_region_ids_sorted() {
        let config = RegionConfig::defaults();
        let ids = config.available_region_ids();
        let mut sorted = ids.clone();
        sorted.sort();
        assert_eq!(ids, sorted, "available_region_ids should return sorted IDs");
    }

    #[test]
    fn provider_for_region_aws_and_hetzner() {
        let config = RegionConfig::defaults();
        assert_eq!(config.provider_for_region("us-east-1"), Some("aws"));
        assert_eq!(config.provider_for_region("eu-central-1"), Some("hetzner"));
        assert_eq!(config.provider_for_region("nonexistent"), None);
    }

    #[test]
    fn filter_to_providers_aws_only() {
        let config = RegionConfig::defaults();
        let providers: HashSet<String> = ["aws".to_string()].into_iter().collect();
        let filtered = config.filter_to_providers(&providers);

        assert_eq!(filtered.all_regions().len(), 2);
        for (_, entry) in filtered.all_regions() {
            assert_eq!(entry.provider, "aws");
        }
    }

    #[test]
    fn filter_to_providers_empty_returns_empty() {
        let config = RegionConfig::defaults();
        let providers: HashSet<String> = HashSet::new();
        let filtered = config.filter_to_providers(&providers);
        assert_eq!(filtered.all_regions().len(), 0);
    }

    #[test]
    fn defaults_contains_expected_providers() {
        let config = RegionConfig::defaults();
        let providers: HashSet<&str> = config
            .all_regions()
            .iter()
            .map(|(_, e)| e.provider.as_str())
            .collect();
        assert!(providers.contains("aws"));
        assert!(providers.contains("hetzner"));
    }
}
