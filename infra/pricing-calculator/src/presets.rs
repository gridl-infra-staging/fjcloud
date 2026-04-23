//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/presets.rs.
use crate::types::WorkloadProfile;

/// Named demo workload that can be compared across all registered providers.
#[derive(Debug, Clone, PartialEq)]
pub struct PresetScenario {
    pub id: String,
    pub name: String,
    pub description: String,
    pub workload: WorkloadProfile,
}

/// Returns the canonical demo workload catalog used by tests, docs, and demos.
pub fn preset_scenarios() -> Vec<PresetScenario> {
    vec![
        PresetScenario {
            id: "starter-catalog".to_string(),
            name: "Starter Catalog".to_string(),
            description: "Small catalog with modest search traffic".to_string(),
            workload: WorkloadProfile {
                document_count: 50_000,
                avg_document_size_bytes: 1_024,
                search_requests_per_month: 250_000,
                write_operations_per_month: 2_500,
                sort_directions: 1,
                num_indexes: 1,
                high_availability: false,
            },
        },
        PresetScenario {
            id: "regional-ecommerce".to_string(),
            name: "Regional Ecommerce".to_string(),
            description: "Mid-size product catalog with steady daily traffic".to_string(),
            workload: WorkloadProfile {
                document_count: 500_000,
                avg_document_size_bytes: 2_048,
                search_requests_per_month: 4_000_000,
                write_operations_per_month: 60_000,
                sort_directions: 2,
                num_indexes: 3,
                high_availability: false,
            },
        },
        PresetScenario {
            id: "media-discovery".to_string(),
            name: "Media Discovery".to_string(),
            description: "Content-heavy workload with multiple sort permutations".to_string(),
            workload: WorkloadProfile {
                document_count: 1_500_000,
                avg_document_size_bytes: 4_096,
                search_requests_per_month: 12_000_000,
                write_operations_per_month: 120_000,
                sort_directions: 4,
                num_indexes: 6,
                high_availability: true,
            },
        },
        PresetScenario {
            id: "global-marketplace".to_string(),
            name: "Global Marketplace".to_string(),
            description: "Large multi-region marketplace with high request volume".to_string(),
            workload: WorkloadProfile {
                document_count: 8_000_000,
                avg_document_size_bytes: 3_072,
                search_requests_per_month: 60_000_000,
                write_operations_per_month: 500_000,
                sort_directions: 5,
                num_indexes: 12,
                high_availability: true,
            },
        },
        PresetScenario {
            id: "analytics-archive".to_string(),
            name: "Analytics Archive".to_string(),
            description: "Very large corpus with low write throughput".to_string(),
            workload: WorkloadProfile {
                document_count: 25_000_000,
                avg_document_size_bytes: 8_192,
                search_requests_per_month: 18_000_000,
                write_operations_per_month: 25_000,
                sort_directions: 1,
                num_indexes: 4,
                high_availability: true,
            },
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::compare_all;
    use std::collections::HashSet;

    fn registered_provider_count() -> usize {
        crate::providers::all_metadata().len()
    }

    #[test]
    fn preset_scenarios_returns_five_named_workloads() {
        let scenarios = preset_scenarios();
        assert_eq!(scenarios.len(), 5, "Expected 5 stable demo scenarios");
    }

    /// Prevents preset catalog drift by requiring stable, non-empty, unique IDs and names used by docs and UI selectors.
    #[test]
    fn preset_scenarios_have_unique_identifiers_and_names() {
        let scenarios = preset_scenarios();
        assert_eq!(scenarios.len(), 5, "Expected 5 stable demo scenarios");

        let unique_ids: HashSet<&str> = scenarios
            .iter()
            .map(|scenario| scenario.id.as_str())
            .collect();
        let unique_names: HashSet<&str> = scenarios
            .iter()
            .map(|scenario| scenario.name.as_str())
            .collect();

        assert_eq!(
            unique_ids.len(),
            scenarios.len(),
            "Scenario IDs must be unique"
        );
        assert_eq!(
            unique_names.len(),
            scenarios.len(),
            "Scenario names must be unique"
        );

        for scenario in &scenarios {
            assert!(
                !scenario.id.trim().is_empty(),
                "Scenario name '{}' has empty id",
                scenario.name
            );
            assert!(
                !scenario.name.trim().is_empty(),
                "Scenario id '{}' has empty name",
                scenario.id
            );
        }
    }

    #[test]
    fn preset_scenarios_all_validate() {
        let scenarios = preset_scenarios();
        assert_eq!(scenarios.len(), 5, "Expected 5 stable demo scenarios");

        for scenario in &scenarios {
            assert!(
                scenario.workload.validate().is_ok(),
                "Scenario '{}' failed validation",
                scenario.id
            );
        }
    }

    /// Verifies each preset follows the same compare invariants as ad-hoc workloads: full provider coverage, sorted totals, and summed line items.
    #[test]
    fn preset_scenarios_compare_all_invariants_hold() {
        let scenarios = preset_scenarios();
        assert_eq!(scenarios.len(), 5, "Expected 5 stable demo scenarios");

        for scenario in &scenarios {
            let comparison = compare_all(&scenario.workload)
                .unwrap_or_else(|err| panic!("compare_all failed for '{}': {}", scenario.id, err));

            assert_eq!(
                comparison.estimates.len(),
                registered_provider_count(),
                "Expected one estimate per provider for scenario '{}'",
                scenario.id
            );

            let totals: Vec<i64> = comparison
                .estimates
                .iter()
                .map(|estimate| estimate.monthly_total_cents)
                .collect();
            for window in totals.windows(2) {
                assert!(
                    window[0] <= window[1],
                    "Scenario '{}' returned unsorted totals: {} > {}",
                    scenario.id,
                    window[0],
                    window[1]
                );
            }

            for estimate in &comparison.estimates {
                let line_item_sum: i64 = estimate
                    .line_items
                    .iter()
                    .map(|item| item.amount_cents)
                    .sum();
                assert_eq!(
                    estimate.monthly_total_cents, line_item_sum,
                    "Scenario '{}', provider {:?}: total {} != line item sum {}",
                    scenario.id, estimate.provider, estimate.monthly_total_cents, line_item_sum
                );
            }
        }
    }
}
