use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::ram_heuristics::{self, SearchEngine};
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for Elastic Cloud.
pub fn metadata() -> ProviderMetadata {
    ProviderMetadata {
        id: ProviderId::ElasticCloud,
        display_name: "Elastic Cloud".to_string(),
        last_verified: None,
        source_urls: vec!["https://www.elastic.co/pricing/cloud-hosted".to_string()],
    }
}

// ============================================================================
// Pricing data — Standard tier, instance-based scaling
// ============================================================================

/// An instance tier with its resource allocation and monthly price.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstanceTier {
    pub ram_gib: u16,
    pub storage_gib: u16,
    /// Monthly price in cents (Standard subscription, 2 availability zones).
    pub monthly_cents: i64,
}

/// Available instance tiers, ordered by RAM (smallest first).
/// Based on Elastic Cloud Standard subscription pricing.
/// Stage 5 calculator selects the smallest tier whose RAM fits the workload.
pub const INSTANCE_TIERS: &[InstanceTier] = &[
    InstanceTier {
        ram_gib: 4,
        storage_gib: 120,
        monthly_cents: 9_900, // $99/mo — Standard base
    },
    InstanceTier {
        ram_gib: 8,
        storage_gib: 240,
        monthly_cents: 19_800, // ~$198/mo — scaled 2×
    },
    InstanceTier {
        ram_gib: 16,
        storage_gib: 480,
        monthly_cents: 39_600, // ~$396/mo — scaled 4×
    },
    InstanceTier {
        ram_gib: 32,
        storage_gib: 960,
        monthly_cents: 79_200, // ~$792/mo — scaled 8×
    },
    InstanceTier {
        ram_gib: 64,
        storage_gib: 1920,
        monthly_cents: 158_400, // ~$1584/mo — scaled 16×
    },
];

// ============================================================================
// Estimator
// ============================================================================

/// Estimates monthly cost for Elastic Cloud Standard subscription.
///
/// Single line item: instance tier monthly cost.
/// Standard pricing already includes 2-AZ deployment.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let ram_needed = ram_heuristics::estimate_ram_gib(workload, SearchEngine::Elasticsearch);
    let selection = ram_heuristics::pick_tier(ram_needed, INSTANCE_TIERS, |t| t.ram_gib);
    let tier = selection.tier;

    let line_items = vec![CostLineItem {
        description: format!("{} GiB RAM instance", tier.ram_gib),
        quantity: dec!(1),
        unit: "month".to_string(),
        unit_price_cents: Decimal::from(tier.monthly_cents),
        amount_cents: tier.monthly_cents,
    }];

    let monthly_total_cents = line_items.iter().map(|li| li.amount_cents).sum();

    let mut assumptions = vec![
        "Elastic Cloud Standard subscription; includes 2-AZ deployment".to_string(),
        format!("Bundled storage: {} GiB per tier", tier.storage_gib),
    ];

    let workload_storage = workload.storage_gib();
    if workload_storage > Decimal::from(tier.storage_gib) {
        assumptions.push(format!(
            "Workload storage exceeds bundled {} GiB; additional storage costs not modeled",
            tier.storage_gib
        ));
    }
    if selection.capped {
        assumptions.push(format!(
            "Workload exceeds largest available tier ({} GiB); estimate capped",
            tier.ram_gib
        ));
    }

    EstimatedCost {
        provider: ProviderId::ElasticCloud,
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
    fn estimate_small_workload_hits_minimum_tier() {
        // 100K × 2048 B ≈ 0.19 GiB → ×0.5 = 0.095, min 4.0 → 4 GiB tier
        let est = estimate(&small_workload());
        assert_eq!(est.provider, ProviderId::ElasticCloud);
        assert_eq!(est.plan_name, Some("4 GiB RAM".to_string()));
        assert_eq!(est.line_items.len(), 1);
        assert_eq!(est.monthly_total_cents, 9900); // $99/mo
    }

    #[test]
    fn estimate_larger_workload_requires_tier_upgrade() {
        // 1M × 10240 B ≈ 9.54 GiB → ×0.5 = 4.77 GiB → 8 GiB tier
        let w = WorkloadProfile {
            document_count: 1_000_000,
            avg_document_size_bytes: 10240,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("8 GiB RAM".to_string()));
        assert_eq!(est.monthly_total_cents, 19800);
    }

    #[test]
    fn estimate_storage_exceeds_bundled_adds_assumption() {
        // 2000 × 1 GiB = 2000 GiB → ram = 1000 → capped at 64 GiB (1920 GiB bundled)
        let w = WorkloadProfile {
            document_count: 2000,
            avg_document_size_bytes: 1_073_741_824,
            ..small_workload()
        };
        let est = estimate(&w);
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains("exceeds bundled")));
        assert!(est.assumptions.iter().any(|a| a.contains("capped")));
    }

    #[test]
    fn estimate_ha_has_same_price_as_non_ha() {
        let non_ha = estimate(&small_workload());
        let ha = estimate(&WorkloadProfile {
            high_availability: true,
            ..small_workload()
        });
        assert_eq!(ha.plan_name, non_ha.plan_name);
        assert_eq!(ha.line_items, non_ha.line_items);
        assert_eq!(ha.monthly_total_cents, non_ha.monthly_total_cents);
        assert!(ha.assumptions.iter().any(|a| a.contains("includes 2-AZ")));
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
        assert!(est.assumptions.iter().any(|a| a.contains("2-AZ")));
    }

    // --- pre-existing metadata/tier tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::ElasticCloud);
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn instance_tiers_are_non_empty() {
        assert!(!INSTANCE_TIERS.is_empty());
    }

    #[test]
    fn instance_tiers_sorted_by_ram() {
        for window in INSTANCE_TIERS.windows(2) {
            assert!(
                window[0].ram_gib < window[1].ram_gib,
                "Instance tiers not sorted by RAM: {} >= {}",
                window[0].ram_gib,
                window[1].ram_gib
            );
        }
    }

    #[test]
    fn instance_tiers_have_positive_prices() {
        for tier in INSTANCE_TIERS {
            assert!(
                tier.monthly_cents > 0,
                "Tier with {} GiB RAM has non-positive price",
                tier.ram_gib
            );
        }
    }

    #[test]
    fn base_tier_matches_published_price() {
        // $99/mo = 9900 cents
        assert_eq!(INSTANCE_TIERS[0].monthly_cents, 9_900);
    }
}
