//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs.
use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::ram_heuristics::{self, SearchEngine};
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

pub const DISPLAY_NAME: &str = "Meilisearch Cloud (Resource-Based)";
pub const SOURCE_URLS: &[&str] = &["https://www.meilisearch.com/pricing/platform"];

/// Returns metadata for Meilisearch Cloud (resource-based plans).
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::MeilisearchResourceBased,
        DISPLAY_NAME,
        Some(NaiveDate::from_ymd_opt(2026, 3, 15).expect("valid verification date")),
        SOURCE_URLS,
    )
}

// ============================================================================
// Pricing data — resource-based instance tiers
// ============================================================================

/// An instance tier with its resource allocation and monthly price.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct InstanceTier {
    pub name: &'static str,
    pub vcpus: Decimal,
    pub ram_gib: u16,
    /// Monthly price in cents.
    pub monthly_cents: i64,
}

/// Available instance tiers, ordered by RAM size (smallest first).
/// Stage 5 calculator selects the smallest tier whose RAM fits the workload.
pub const INSTANCE_TIERS: &[InstanceTier] = &[
    InstanceTier {
        name: "XS",
        vcpus: dec!(0.5),
        ram_gib: 1,
        monthly_cents: 2_044,
    },
    InstanceTier {
        name: "S",
        vcpus: dec!(1),
        ram_gib: 2,
        monthly_cents: 4_088,
    },
    InstanceTier {
        name: "M",
        vcpus: dec!(2),
        ram_gib: 4,
        monthly_cents: 8_103,
    },
    InstanceTier {
        name: "L",
        vcpus: dec!(2),
        ram_gib: 8,
        monthly_cents: 16_133,
    },
    InstanceTier {
        name: "XL",
        vcpus: dec!(4),
        ram_gib: 16,
        monthly_cents: 35_332,
    },
];

/// Minimum billed storage per instance.
pub const BASE_STORAGE_GIB: u16 = 32;

/// Extra storage auto-scales in 100 GiB increments.
pub const STORAGE_AUTOSCALE_INCREMENT_GIB: u16 = 100;

/// Additional storage price, in cents per GiB-month.
pub const ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH: Decimal = dec!(16.5);

/// Outbound bandwidth price, in cents per GB.
pub const BANDWIDTH_CENTS_PER_GB: Decimal = dec!(15);

// ============================================================================
// Estimator
// ============================================================================

/// Computes additional storage billed beyond the base allocation.
///
/// Storage auto-scales in `STORAGE_AUTOSCALE_INCREMENT_GIB` (100 GiB) increments.
/// Returns 0 if within the base allocation.
fn additional_storage_gib(workload: &WorkloadProfile) -> Decimal {
    let raw_storage = workload.storage_gib();
    let base = Decimal::from(BASE_STORAGE_GIB);
    if raw_storage <= base {
        return dec!(0);
    }
    let overage = raw_storage - base;
    let increment = Decimal::from(STORAGE_AUTOSCALE_INCREMENT_GIB);
    let increments = (overage / increment).ceil();
    increments * increment
}

/// Estimates monthly cost for Meilisearch Cloud resource-based plans.
///
/// Three line items: instance tier + additional storage + outbound bandwidth.
/// No HA multiplier — resource-based plans are single-instance.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let ram_needed = ram_heuristics::estimate_ram_gib(workload, SearchEngine::Meilisearch);
    let selection = ram_heuristics::pick_tier(ram_needed, INSTANCE_TIERS, |t| t.ram_gib);
    let tier = selection.tier;

    // Line item 1: instance tier
    let instance_amount = tier.monthly_cents;

    // Line item 2: additional storage
    let extra_storage = additional_storage_gib(workload);
    let storage_amount =
        super::rounded_cents(extra_storage * ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH);

    // Line item 3: outbound bandwidth
    let bandwidth_gb = ram_heuristics::estimate_monthly_bandwidth_gb(workload);
    let bandwidth_amount = super::rounded_cents(bandwidth_gb * BANDWIDTH_CENTS_PER_GB);

    let line_items = vec![
        CostLineItem {
            description: format!("{} instance", tier.name),
            quantity: dec!(1),
            unit: "month".to_string(),
            unit_price_cents: Decimal::from(tier.monthly_cents),
            amount_cents: instance_amount,
        },
        CostLineItem {
            description: "Additional storage".to_string(),
            quantity: extra_storage,
            unit: "gib_months".to_string(),
            unit_price_cents: ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH,
            amount_cents: storage_amount,
        },
        CostLineItem {
            description: "Outbound bandwidth".to_string(),
            quantity: bandwidth_gb,
            unit: "gb".to_string(),
            unit_price_cents: BANDWIDTH_CENTS_PER_GB,
            amount_cents: bandwidth_amount,
        },
    ];

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    let mut assumptions = vec![
        "Meilisearch Cloud resource-based pricing; custom plans not modeled".to_string(),
        "Single-instance deployment; no built-in HA multiplier in resource-based pricing"
            .to_string(),
    ];
    if extra_storage > dec!(0) {
        assumptions.push(format!(
            "Storage auto-scaled in {} GiB increments beyond {} GiB base",
            STORAGE_AUTOSCALE_INCREMENT_GIB, BASE_STORAGE_GIB
        ));
    }
    if selection.capped {
        assumptions.push(format!(
            "Workload exceeds largest available tier ({} GiB); estimate capped",
            tier.ram_gib
        ));
    }

    EstimatedCost {
        provider: ProviderId::MeilisearchResourceBased,
        monthly_total_cents,
        line_items,
        assumptions,
        plan_name: Some(tier.name.to_string()),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal::Decimal;

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
    fn estimate_small_workload_within_base_storage() {
        // 100K × 2048 B ≈ 0.19 GiB storage, well within 32 GiB base
        // RAM: 0.19 × 2.5 = 0.48 GiB → XS tier (1 GiB, 2044 cents/mo)
        let est = estimate(&small_workload());
        assert_eq!(est.provider, ProviderId::MeilisearchResourceBased);
        assert_eq!(est.plan_name, Some("XS".to_string()));
        assert_eq!(est.line_items.len(), 3);
        assert_eq!(est.line_items[0].amount_cents, 2044); // XS instance
        assert_eq!(est.line_items[1].amount_cents, 0); // no storage overage
    }

    /// Verifies storage overage rounds up to the required 100 GiB billing increment, protecting conservative overage accounting.
    #[test]
    fn estimate_storage_overage_ceils_to_100gib_increment() {
        // Need >32 GiB storage. 40 GiB storage → overage = 8 GiB → ceil to 100 GiB
        // 40 GiB storage: doc_count=40, avg_size=1073741824 (1GiB each)
        // RAM: 40 × 2.5 = 100 GiB → capped at XL (16 GiB)
        let w = WorkloadProfile {
            document_count: 40,
            avg_document_size_bytes: 1_073_741_824,
            search_requests_per_month: 0,
            ..small_workload()
        };
        let est = estimate(&w);
        // Storage: 40 GiB total, 32 base, 8 overage → ceil to 100 GiB increment
        assert_eq!(est.line_items[1].quantity, dec!(100));
        // 100 × 16.5 = 1650 cents
        assert_eq!(est.line_items[1].amount_cents, 1650);
        assert!(est.assumptions.iter().any(|a| a.contains("auto-scaled")));
    }

    #[test]
    fn estimate_bandwidth_cost() {
        // 1M searches × 2048 B × 20 results / 1_000_000_000 = 40.96 GB
        // 40.96 × 15 cents/GB = 614.4 → rounds to 614
        let w = WorkloadProfile {
            search_requests_per_month: 1_000_000,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[2].amount_cents, 614);
    }

    #[test]
    fn estimate_bandwidth_rounds_half_cent_to_even() {
        // 60K × 250 B × 20 / 1B = 0.3 GB
        // 0.3 × 15 = 4.5 cents -> banker's rounding => 4
        let w = WorkloadProfile {
            avg_document_size_bytes: 250,
            search_requests_per_month: 60_000,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[2].quantity, dec!(0.3));
        assert_eq!(est.line_items[2].amount_cents, 4);
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
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains("Single-instance")));
    }

    #[test]
    fn estimate_capped_tier() {
        // Force RAM > 16 GiB (XL max): need storage > 6.4 GiB → ×2.5 > 16
        // 7 GiB storage → 7 × 2.5 = 17.5 GiB → capped at XL
        let w = WorkloadProfile {
            document_count: 7,
            avg_document_size_bytes: 1_073_741_824,
            search_requests_per_month: 0,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("XL".to_string()));
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
        assert!(ha.assumptions.iter().any(|a| a.contains("Single-instance")));
    }

    // --- pre-existing metadata/tier tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::MeilisearchResourceBased);
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn source_urls_include_platform_pricing_page() {
        assert!(SOURCE_URLS.contains(&"https://www.meilisearch.com/pricing/platform"));
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
    fn instance_tiers_have_positive_ram() {
        for tier in INSTANCE_TIERS {
            assert!(tier.ram_gib > 0);
        }
    }

    #[test]
    fn instance_tiers_match_official_platform_page() {
        assert_eq!(INSTANCE_TIERS.len(), 5);
        assert_eq!(INSTANCE_TIERS[0].name, "XS");
        assert_eq!(INSTANCE_TIERS[0].vcpus, Decimal::new(5, 1));
        assert_eq!(INSTANCE_TIERS[0].ram_gib, 1);
        assert_eq!(INSTANCE_TIERS[0].monthly_cents, 2_044);
        assert_eq!(INSTANCE_TIERS[4].name, "XL");
        assert_eq!(INSTANCE_TIERS[4].ram_gib, 16);
        assert_eq!(INSTANCE_TIERS[4].monthly_cents, 35_332);
    }

    #[test]
    fn disk_and_bandwidth_pricing_match_official_platform_page() {
        assert_eq!(BASE_STORAGE_GIB, 32);
        assert_eq!(ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH, Decimal::new(165, 1));
        assert_eq!(BANDWIDTH_CENTS_PER_GB, Decimal::new(15, 0));
    }
}
