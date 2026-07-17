use rust_decimal::prelude::*;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::ram_heuristics::{self, SearchEngine};
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for Typesense Cloud.
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::TypesenseCloud,
        "Typesense Cloud",
        None,
        &["https://cloud.typesense.org/pricing"],
    )
}

// ============================================================================
// Pricing data — RAM-based hourly pricing (single node)
// ============================================================================

/// A RAM tier with its hourly price.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RamTier {
    /// RAM in GiB.
    pub ram_gib: u16,
    /// Hourly price in cents (single node).
    pub hourly_cents: Decimal,
}

/// Available RAM tiers, ordered by size (smallest first).
/// No per-record or per-search charges — purely resource-based.
/// Stage 5 calculator selects the smallest tier whose RAM fits the workload.
pub const RAM_TIERS: &[RamTier] = &[
    RamTier {
        ram_gib: 1,
        hourly_cents: dec!(5.4), // ~$0.054/hr
    },
    RamTier {
        ram_gib: 2,
        hourly_cents: dec!(10), // ~$0.10/hr
    },
    RamTier {
        ram_gib: 4,
        hourly_cents: dec!(19), // ~$0.19/hr
    },
    RamTier {
        ram_gib: 8,
        hourly_cents: dec!(38), // ~$0.38/hr
    },
    RamTier {
        ram_gib: 16,
        hourly_cents: dec!(74), // ~$0.74/hr
    },
    RamTier {
        ram_gib: 32,
        hourly_cents: dec!(139), // ~$1.39/hr
    },
    RamTier {
        ram_gib: 64,
        hourly_cents: dec!(246), // ~$2.46/hr
    },
];

/// HA multiplier: 3 nodes for high availability.
pub const HA_NODE_COUNT: i64 = 3;

// ============================================================================
// Estimator
// ============================================================================

/// Estimates monthly cost for Typesense Cloud.
///
/// Single line item: compute (hourly × HOURS_PER_MONTH × node_count).
/// HA triples the cost via `HA_NODE_COUNT`.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let ram_needed = ram_heuristics::estimate_ram_gib(workload, SearchEngine::Typesense);
    let selection = ram_heuristics::pick_tier(ram_needed, RAM_TIERS, |t| t.ram_gib);
    let tier = selection.tier;

    let node_count: i64 = if workload.high_availability {
        HA_NODE_COUNT
    } else {
        1
    };

    let quantity = Decimal::from(node_count) * crate::types::HOURS_PER_MONTH;
    let amount_cents = (quantity * tier.hourly_cents)
        .round_dp(0)
        .to_i64()
        .expect("rounded amount fits in i64");

    let line_items = vec![CostLineItem {
        description: format!("Compute ({} GiB × {} node(s))", tier.ram_gib, node_count),
        quantity,
        unit: "instance_hours".to_string(),
        unit_price_cents: tier.hourly_cents,
        amount_cents,
    }];

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    let mut assumptions =
        vec!["Typesense Cloud hourly pricing; annual commitment discounts not modeled".to_string()];
    if workload.high_availability {
        assumptions.push("High availability: 3-node cluster".to_string());
    }
    if selection.capped {
        assumptions.push(format!(
            "Workload exceeds largest available tier ({} GiB); estimate capped",
            tier.ram_gib
        ));
    }

    EstimatedCost {
        provider: ProviderId::TypesenseCloud,
        monthly_total_cents,
        line_items,
        assumptions,
        plan_name: Some(format!("{} GiB RAM", tier.ram_gib)),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    fn small_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2048,
            search_requests_per_month: 50_000,
            write_operations_per_month: 1_000,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- estimate() tests ---

    #[test]
    fn estimate_small_workload_single_node() {
        // 100K docs × 2048 B ≈ 0.19 GiB → ×2.0 = 0.38 GiB → 1 GiB tier
        let est = estimate(&small_workload());
        assert_eq!(est.provider, ProviderId::TypesenseCloud);
        assert_eq!(est.plan_name, Some("1 GiB RAM".to_string()));
        assert_eq!(est.line_items.len(), 1);
        // 1 node × 730 hrs × 5.4 cents = 3942 cents
        assert_eq!(est.monthly_total_cents, 3942);
        assert_eq!(est.line_items[0].unit, "instance_hours");
    }

    #[test]
    fn estimate_ha_workload_triples_cost() {
        let w = WorkloadProfile {
            high_availability: true,
            ..small_workload()
        };
        let est = estimate(&w);
        // 3 nodes × 730 hrs × 5.4 cents = 11826
        assert_eq!(est.monthly_total_cents, 11826);
        assert!(est.assumptions.iter().any(|a| a.contains("3-node")));
    }

    #[test]
    fn estimate_large_workload_capped() {
        // Force RAM > 64 GiB: need storage > 32 GiB → ×2.0 = >64 GiB
        // 35 GiB storage → doc_count × avg_size = 35 × 1073741824
        let w = WorkloadProfile {
            document_count: 35,
            avg_document_size_bytes: 1_073_741_824, // 1 GiB
            high_availability: false,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("64 GiB RAM".to_string()));
        assert!(est.assumptions.iter().any(|a| a.contains("capped")));
    }

    #[test]
    fn estimate_line_item_sum_equals_total() {
        let est = estimate(&small_workload());
        let sum: i64 = est.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(est.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_has_plan_name_and_assumptions() {
        let est = estimate(&small_workload());
        assert!(est.plan_name.is_some());
        assert!(!est.assumptions.is_empty());
    }

    #[test]
    fn estimate_medium_workload_picks_correct_tier() {
        // 1M docs × 5120 B ≈ 4.77 GiB → ×2.0 = 9.54 GiB → 16 GiB tier
        let w = WorkloadProfile {
            document_count: 1_000_000,
            avg_document_size_bytes: 5120,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("16 GiB RAM".to_string()));
        // 1 node × 730 hrs × 74 cents = 54020
        assert_eq!(est.monthly_total_cents, 54020);
    }

    // --- pre-existing metadata/tier tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::TypesenseCloud);
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn ram_tiers_are_non_empty() {
        assert!(!RAM_TIERS.is_empty());
    }

    #[test]
    fn ram_tiers_sorted_by_size() {
        for window in RAM_TIERS.windows(2) {
            assert!(
                window[0].ram_gib < window[1].ram_gib,
                "RAM tiers not sorted: {} >= {}",
                window[0].ram_gib,
                window[1].ram_gib
            );
        }
    }

    #[test]
    fn ram_tiers_have_positive_hourly_prices() {
        for tier in RAM_TIERS {
            assert!(
                tier.hourly_cents > Decimal::ZERO,
                "Tier with {} GiB RAM has non-positive hourly price",
                tier.ram_gib
            );
        }
    }

    #[test]
    fn ha_node_count_is_at_least_two() {
        const { assert!(HA_NODE_COUNT >= 2) };
    }
}
