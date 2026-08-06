use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::ram_heuristics::{self, SearchEngine};
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for Typesense Cloud.
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::TypesenseCloud,
        "Typesense Cloud",
        Some(NaiveDate::from_ymd_opt(2026, 8, 5).expect("valid verification date")),
        &["https://cloud.typesense.org/pricing"],
    )
}

// ============================================================================
// Pricing data — published RAM sizes in both published price modes
// ============================================================================

/// A published RAM size with Typesense Cloud's price in each of its two
/// published deployment modes.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RamTier {
    /// RAM in GiB. `Decimal` because the published entry tier is 0.5 GB.
    pub ram_gib: Decimal,
    /// Hourly price in cents for a single node.
    pub single_node_hourly_cents: Decimal,
    /// Hourly price in cents for the whole [`HA_NODE_COUNT`]-node cluster.
    pub ha_cluster_hourly_cents: Decimal,
}

/// Every RAM size Typesense Cloud publishes, smallest first. No per-record or
/// per-search charges — pricing is purely resource-based, and the calculator
/// selects the least-expensive tier whose RAM fits the workload.
///
/// Published-value contract for this whole table: captured `2026-08-05` from
/// <https://cloud.typesense.org/pricing> with region N Virginia, GPU off,
/// high-performance disk off, and search delivery network off. Typesense sells a
/// RAM size together with a vCPU option and this calculator models RAM only, so
/// every row carries the cheapest published vCPU option for its size in each
/// deployment mode. The two modes were swept independently.
/// `ha_cluster_hourly_cents` is the published price of the entire 3-node
/// cluster — it is neither a per-node price nor three times the single-node
/// price, because Typesense charges more per node under HA (1 GB: $0.15/hr
/// cluster vs 3 × $0.04/hr = $0.12/hr).
/// Reproduce with
/// `docs/audits/pricing-verification/20260805T155326Z/probe_typesense_prices.sh`.
pub const RAM_TIERS: &[RamTier] = &[
    RamTier {
        ram_gib: dec!(0.5),
        single_node_hourly_cents: dec!(3.0),
        ha_cluster_hourly_cents: dec!(12.0),
    },
    RamTier {
        ram_gib: dec!(1),
        single_node_hourly_cents: dec!(4.0),
        ha_cluster_hourly_cents: dec!(15.0),
    },
    RamTier {
        ram_gib: dec!(2),
        single_node_hourly_cents: dec!(6.0),
        ha_cluster_hourly_cents: dec!(21.0),
    },
    RamTier {
        ram_gib: dec!(4),
        single_node_hourly_cents: dec!(10.0),
        ha_cluster_hourly_cents: dec!(33.0),
    },
    RamTier {
        ram_gib: dec!(8),
        single_node_hourly_cents: dec!(18.0),
        ha_cluster_hourly_cents: dec!(60.0),
    },
    RamTier {
        ram_gib: dec!(16),
        single_node_hourly_cents: dec!(27.0),
        ha_cluster_hourly_cents: dec!(90.0),
    },
    RamTier {
        ram_gib: dec!(32),
        single_node_hourly_cents: dec!(53.0),
        ha_cluster_hourly_cents: dec!(171.0),
    },
    RamTier {
        ram_gib: dec!(64),
        single_node_hourly_cents: dec!(101.0),
        ha_cluster_hourly_cents: dec!(318.0),
    },
    RamTier {
        ram_gib: dec!(96),
        single_node_hourly_cents: dec!(238.0),
        ha_cluster_hourly_cents: dec!(732.0),
    },
    RamTier {
        ram_gib: dec!(128),
        single_node_hourly_cents: dec!(186.0),
        ha_cluster_hourly_cents: dec!(573.0),
    },
    RamTier {
        ram_gib: dec!(192),
        single_node_hourly_cents: dec!(452.0),
        ha_cluster_hourly_cents: dec!(1386.0),
    },
    RamTier {
        ram_gib: dec!(256),
        single_node_hourly_cents: dec!(371.0),
        ha_cluster_hourly_cents: dec!(1131.0),
    },
    RamTier {
        ram_gib: dec!(384),
        single_node_hourly_cents: dec!(612.0),
        ha_cluster_hourly_cents: dec!(1866.0),
    },
    RamTier {
        ram_gib: dec!(512),
        single_node_hourly_cents: dec!(740.0),
        ha_cluster_hourly_cents: dec!(2241.0),
    },
    RamTier {
        ram_gib: dec!(768),
        single_node_hourly_cents: dec!(1109.0),
        ha_cluster_hourly_cents: dec!(3348.0),
    },
    RamTier {
        ram_gib: dec!(1024),
        single_node_hourly_cents: dec!(1478.0),
        ha_cluster_hourly_cents: dec!(4461.0),
    },
];

/// Node count in the published high-availability cluster.
///
/// Describes the deployment [`RamTier::ha_cluster_hourly_cents`] prices; it is
/// not a price multiplier.
pub const HA_NODE_COUNT: i64 = 3;

/// Hours Typesense Cloud uses to convert its hourly rates to monthly.
///
/// Typesense quotes "works out to $X /month" as exactly `hourly × 720` in every
/// probe in the 2026-08-05 sweep, so this provider must not use the shared
/// [`crate::types::HOURS_PER_MONTH`] default of 730 — that would overstate every
/// Typesense total by 1.4%.
const TYPESENSE_HOURS_PER_MONTH: Decimal = dec!(720);

// ============================================================================
// Estimator
// ============================================================================

/// Estimates monthly cost for Typesense Cloud.
///
/// Single line item: the published hourly rate for the selected deployment mode
/// (single node, or the [`HA_NODE_COUNT`]-node cluster as one priced unit)
/// × [`TYPESENSE_HOURS_PER_MONTH`].
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let ram_needed = ram_heuristics::estimate_ram_gib(workload, SearchEngine::Typesense);
    let selection = ram_heuristics::pick_cheapest_fitting_tier(
        ram_needed,
        RAM_TIERS,
        |tier| tier.ram_gib,
        |tier| {
            if workload.high_availability {
                tier.ha_cluster_hourly_cents
            } else {
                tier.single_node_hourly_cents
            }
        },
    );
    let tier = selection.tier;

    // Both modes are priced per hour of the deployed unit, so the quantity is
    // the same either way — what changes is whether that unit is one node or
    // the whole HA cluster.
    let (hourly_cents, unit, description) = if workload.high_availability {
        (
            tier.ha_cluster_hourly_cents,
            "cluster_hours",
            format!(
                "Compute ({} GiB × {}-node HA cluster)",
                tier.ram_gib, HA_NODE_COUNT
            ),
        )
    } else {
        (
            tier.single_node_hourly_cents,
            "instance_hours",
            format!("Compute ({} GiB × 1 node)", tier.ram_gib),
        )
    };

    let quantity = TYPESENSE_HOURS_PER_MONTH;
    let amount_cents = super::rounded_cents(quantity * hourly_cents);

    let line_items = vec![CostLineItem {
        description,
        quantity,
        unit: unit.to_string(),
        unit_price_cents: hourly_cents,
        amount_cents,
    }];

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    let mut assumptions =
        vec!["Typesense Cloud hourly pricing; annual commitment discounts not modeled".to_string()];
    if workload.high_availability {
        assumptions.push(format!(
            "High availability: {HA_NODE_COUNT}-node cluster priced at the published cluster rate"
        ));
    }
    if selection.capped {
        assumptions.push(format!(
            "Workload exceeds largest available tier ({} GiB); estimate capped",
            tier.ram_gib
        ));
    }

    EstimatedCost {
        provider: ProviderId::TypesenseCloud,
        verification_label: metadata().verification_label(),
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

    /// 1 doc × 0.4 GiB → ×2.0 = 0.8 GiB, i.e. above the 0.5 GiB entry tier and
    /// no more than the 1 GiB tier.
    fn one_gib_tier_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 429_496_730, // 0.4 GiB
            ..small_workload()
        }
    }

    #[test]
    fn estimate_small_workload_single_node() {
        // 100K docs × 2048 B ≈ 0.19 GiB → ×2.0 = 0.38 GiB → 0.5 GiB entry tier
        let est = estimate(&small_workload());
        assert_eq!(est.provider, ProviderId::TypesenseCloud);
        assert_eq!(est.plan_name, Some("0.5 GiB RAM".to_string()));
        assert_eq!(est.line_items.len(), 1);
        // 1 node × 720 hrs × 3.0 cents = 2160 cents
        assert_eq!(est.monthly_total_cents, 2160);
        assert_eq!(est.line_items[0].unit, "instance_hours");
    }

    #[test]
    fn estimate_one_gib_workload_single_node() {
        let est = estimate(&one_gib_tier_workload());
        assert_eq!(est.plan_name, Some("1 GiB RAM".to_string()));
        // 720 hrs × published 1 GiB single-node rate 4.0 cents = 2880 cents
        assert_eq!(est.monthly_total_cents, 2880);
    }

    #[test]
    fn estimate_ha_workload_uses_published_cluster_rate() {
        let w = WorkloadProfile {
            high_availability: true,
            ..one_gib_tier_workload()
        };
        let est = estimate(&w);
        // 720 hrs × published 1 GiB 3-node cluster rate 15.0 cents = 10800 cents.
        // Deliberately NOT 3 × the single-node rate: Typesense publishes $0.15/hr
        // for the cluster while 3 × $0.04 would be $0.12/hr.
        assert_eq!(est.monthly_total_cents, 10800);
        assert!(est.assumptions.iter().any(|a| a.contains("3-node")));
    }

    #[test]
    fn estimate_skips_both_published_price_inversions_in_both_modes() {
        let cases = [
            // 70 GiB fits 96 GiB, but 128 GiB is cheaper in both modes.
            (35, "128 GiB RAM", 133_920, 412_560),
            // 130 GiB fits 192 GiB, but 256 GiB is cheaper in both modes.
            (65, "256 GiB RAM", 267_120, 814_320),
        ];

        for (storage_gib, expected_plan, single_total, ha_total) in cases {
            for (high_availability, expected_total) in [(false, single_total), (true, ha_total)] {
                let estimate = estimate(&WorkloadProfile {
                    document_count: storage_gib,
                    avg_document_size_bytes: 1_073_741_824,
                    high_availability,
                    ..small_workload()
                });

                assert_eq!(estimate.plan_name.as_deref(), Some(expected_plan));
                assert_eq!(estimate.monthly_total_cents, expected_total);
                assert!(!estimate
                    .assumptions
                    .iter()
                    .any(|item| item.contains("capped")));
            }
        }
    }

    #[test]
    fn estimate_large_workload_capped() {
        // Capping may only occur above the largest published tier (1024 GiB):
        // 600 GiB storage → ×2.0 = 1200 GiB.
        let w = WorkloadProfile {
            document_count: 600,
            avg_document_size_bytes: 1_073_741_824, // 1 GiB
            high_availability: false,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("1024 GiB RAM".to_string()));
        assert!(est.assumptions.iter().any(|a| a.contains("capped")));
        // 720 hrs × published 1024 GiB single-node rate 1478.0 cents = 1064160 cents
        assert_eq!(est.monthly_total_cents, 1_064_160);
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
        // 1 node × 720 hrs × published 16 GiB rate 27.0 cents = 19440 cents
        assert_eq!(est.monthly_total_cents, 19_440);
    }

    // --- pre-existing metadata/tier tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::TypesenseCloud);
    }

    #[test]
    fn metadata_records_august_2026_verification_date() {
        assert_eq!(
            metadata().last_verified,
            Some(chrono::NaiveDate::from_ymd_opt(2026, 8, 5).expect("valid verification date"))
        );
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    /// Every published RAM size with its single-node and 3-node-HA cluster
    /// hourly price in cents, as captured 2026-08-05 by
    /// `docs/audits/pricing-verification/20260805T155326Z/probe_typesense_prices.sh`
    /// (raw sweeps: `raw/typesense_price_sweep.txt`, `raw/typesense_ha3_sweep.txt`,
    /// selection: `raw/typesense_cheapest_per_size.txt`).
    ///
    /// This is transcribed from the evidence bundle, not from `RAM_TIERS`, so it
    /// fails if a constant is edited away from the published value.
    const PUBLISHED_RATES: &[(Decimal, Decimal, Decimal)] = &[
        (dec!(0.5), dec!(3.0), dec!(12.0)),
        (dec!(1), dec!(4.0), dec!(15.0)),
        (dec!(2), dec!(6.0), dec!(21.0)),
        (dec!(4), dec!(10.0), dec!(33.0)),
        (dec!(8), dec!(18.0), dec!(60.0)),
        (dec!(16), dec!(27.0), dec!(90.0)),
        (dec!(32), dec!(53.0), dec!(171.0)),
        (dec!(64), dec!(101.0), dec!(318.0)),
        (dec!(96), dec!(238.0), dec!(732.0)),
        (dec!(128), dec!(186.0), dec!(573.0)),
        (dec!(192), dec!(452.0), dec!(1386.0)),
        (dec!(256), dec!(371.0), dec!(1131.0)),
        (dec!(384), dec!(612.0), dec!(1866.0)),
        (dec!(512), dec!(740.0), dec!(2241.0)),
        (dec!(768), dec!(1109.0), dec!(3348.0)),
        (dec!(1024), dec!(1478.0), dec!(4461.0)),
    ];

    #[test]
    fn ram_tiers_match_published_rates_in_both_price_modes() {
        assert_eq!(
            RAM_TIERS.len(),
            PUBLISHED_RATES.len(),
            "RAM_TIERS must cover exactly the published RAM sizes"
        );
        for (tier, &(ram_gib, single_node, ha_cluster)) in RAM_TIERS.iter().zip(PUBLISHED_RATES) {
            assert_eq!(tier.ram_gib, ram_gib, "tier order diverged from published");
            assert_eq!(
                tier.single_node_hourly_cents, single_node,
                "{ram_gib} GiB single-node rate is not the published rate"
            );
            assert_eq!(
                tier.ha_cluster_hourly_cents, ha_cluster,
                "{ram_gib} GiB 3-node HA cluster rate is not the published rate"
            );
        }
    }

    /// The HA cluster rate is captured from source independently. Guards against
    /// anyone re-deriving it as `HA_NODE_COUNT × single_node_hourly_cents`, which
    /// understates every published cluster price.
    #[test]
    fn ha_cluster_rate_is_not_three_times_the_single_node_rate() {
        for tier in RAM_TIERS {
            assert_ne!(
                tier.ha_cluster_hourly_cents,
                tier.single_node_hourly_cents * Decimal::from(HA_NODE_COUNT),
                "{} GiB HA rate must come from source, not a 3× multiplier",
                tier.ram_gib
            );
        }
    }

    #[test]
    fn ram_tiers_are_non_empty() {
        assert!(!RAM_TIERS.is_empty());
    }

    #[test]
    fn ram_tiers_start_at_published_entry_size_and_end_at_published_maximum() {
        assert_eq!(RAM_TIERS.first().expect("non-empty").ram_gib, dec!(0.5));
        assert_eq!(RAM_TIERS.last().expect("non-empty").ram_gib, dec!(1024));
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
                tier.single_node_hourly_cents > Decimal::ZERO,
                "Tier with {} GiB RAM has non-positive single-node hourly price",
                tier.ram_gib
            );
            assert!(
                tier.ha_cluster_hourly_cents > tier.single_node_hourly_cents,
                "Tier with {} GiB RAM prices an HA cluster at or below one node",
                tier.ram_gib
            );
        }
    }

    /// Typesense publishes monthly figures as `hourly × 720`, not the shared
    /// 730-hour default. Pins the conversion the estimator must use.
    #[test]
    fn monthly_conversion_uses_typesense_published_720_hours() {
        assert_eq!(TYPESENSE_HOURS_PER_MONTH, dec!(720));
        assert_ne!(TYPESENSE_HOURS_PER_MONTH, crate::types::HOURS_PER_MONTH);
        let est = estimate(&small_workload());
        assert_eq!(est.line_items[0].quantity, dec!(720));
    }

    /// Line items are the billing-transparency surface: quantity × unit price
    /// must reproduce the amount in both published price modes.
    #[test]
    fn line_item_quantity_times_unit_price_equals_amount_in_both_modes() {
        for high_availability in [false, true] {
            let est = estimate(&WorkloadProfile {
                high_availability,
                ..one_gib_tier_workload()
            });
            let line_item = &est.line_items[0];
            assert_eq!(
                Decimal::from(line_item.amount_cents),
                line_item.quantity * line_item.unit_price_cents,
                "line item is internally inconsistent (high_availability={high_availability})"
            );
        }
    }

    #[test]
    fn ha_line_item_prices_the_cluster_not_a_single_node() {
        let est = estimate(&WorkloadProfile {
            high_availability: true,
            ..one_gib_tier_workload()
        });
        let line_item = &est.line_items[0];
        assert_eq!(line_item.unit, "cluster_hours");
        assert_eq!(line_item.unit_price_cents, dec!(15.0));
        assert!(
            line_item.description.contains("3-node HA cluster"),
            "description must name the published deployment: {}",
            line_item.description
        );
    }

    #[test]
    fn ha_node_count_is_at_least_two() {
        const { assert!(HA_NODE_COUNT >= 2) };
    }
}
