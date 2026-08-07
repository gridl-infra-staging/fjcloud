use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::ram_heuristics::{self, SearchEngine};
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for AWS OpenSearch Service.
pub fn metadata() -> ProviderMetadata {
    // Keep unpublished: the current evidence bundle does not source every load-bearing
    // sizing and transfer input. See
    // docs/audits/pricing-verification/20260806T151052Z/aws_opensearch.md.
    super::provider_metadata(
        ProviderId::AwsOpenSearch,
        "AWS OpenSearch Service",
        None,
        &["https://aws.amazon.com/opensearch-service/pricing/"],
    )
}

// ============================================================================
// Pricing data — on-demand instance pricing (us-east-1)
// ============================================================================

/// An OpenSearch instance type with its resource allocation and hourly price.
#[derive(Debug, Clone, PartialEq)]
pub struct InstanceType {
    pub name: &'static str,
    pub vcpus: u8,
    pub ram_gib: u16,
    /// Hourly on-demand price in cents (us-east-1).
    pub hourly_cents: Decimal,
}

/// Available instance types, ordered by RAM (smallest first).
/// Focused on memory-optimized `r6g` family for search workloads,
/// with `t3` and `m6g` for smaller workloads.
pub const INSTANCE_TYPES: &[InstanceType] = &[
    InstanceType {
        name: "t3.small.search",
        vcpus: 2,
        ram_gib: 2,
        hourly_cents: dec!(3.6), // ~$0.036/hr
    },
    InstanceType {
        name: "t3.medium.search",
        vcpus: 2,
        ram_gib: 4,
        hourly_cents: dec!(7.3), // ~$0.073/hr
    },
    InstanceType {
        name: "m6g.large.search",
        vcpus: 2,
        ram_gib: 8,
        hourly_cents: dec!(12.8), // 20260728 AWS offer: $0.128/hr
    },
    InstanceType {
        name: "r6g.large.search",
        vcpus: 2,
        ram_gib: 16,
        hourly_cents: dec!(16.7), // 20260728 AWS offer: $0.167/hr
    },
    InstanceType {
        name: "r6g.xlarge.search",
        vcpus: 4,
        ram_gib: 32,
        hourly_cents: dec!(33.5), // 20260728 AWS offer: $0.335/hr
    },
    InstanceType {
        name: "r6g.2xlarge.search",
        vcpus: 8,
        ram_gib: 64,
        hourly_cents: dec!(66.9), // 20260728 AWS offer: $0.669/hr
    },
    InstanceType {
        name: "r6g.4xlarge.search",
        vcpus: 16,
        ram_gib: 128,
        hourly_cents: dec!(133.9), // 20260728 AWS offer: $1.339/hr
    },
];

/// EBS gp3 storage price per GiB per month, in cents (us-east-1).
pub const EBS_GP3_CENTS_PER_GIB_MONTH: Decimal = dec!(12.2); // 20260728 AWS offer: $0.122/GB-month

/// HA requires multi-AZ: minimum 2 data nodes.
pub const HA_MIN_DATA_NODES: i64 = 2;

/// Outbound data transfer price, in cents per GB (us-east-1, first 10 TB/mo).
pub const DATA_TRANSFER_CENTS_PER_GB: Decimal = dec!(9); // ~$0.09/GB

/// Dedicated master nodes for HA: 3 nodes (AWS-recommended odd count for quorum).
pub const DEDICATED_MASTER_NODE_COUNT: i64 = 3;

/// Dedicated master instance type name (used in line-item and assumption text).
///
/// This is a modeling assumption, not a fetched AWS price recommendation:
/// Stage 2 evidence
/// found AWS examples using other cluster-manager types (`c6g.large.search`,
/// `r8g.large.search`, `r6g.xlarge.search`) rather than this encoded type.
pub const DEDICATED_MASTER_INSTANCE_NAME: &str = "m6g.large.search";

fn dedicated_master_instance() -> &'static InstanceType {
    INSTANCE_TYPES
        .iter()
        .find(|instance| instance.name == DEDICATED_MASTER_INSTANCE_NAME)
        .expect("dedicated master instance must exist in instance table")
}

// ============================================================================
// Estimator
// ============================================================================

/// Estimates monthly cost for AWS OpenSearch Service.
///
/// Line items: data node compute + EBS storage + data transfer,
/// plus dedicated master nodes when HA is enabled.
///
/// The global 100 GB/month free egress allowance is deliberately not modeled.
/// This conservative choice overstates small AWS workloads by up to $9/month
/// while keeping this calculator's transfer line item on the published
/// first-tier outbound rate.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let ram_needed = ram_heuristics::estimate_ram_gib(workload, SearchEngine::Elasticsearch);
    let selection =
        ram_heuristics::pick_tier(ram_needed, INSTANCE_TYPES, |t| Decimal::from(t.ram_gib));
    let instance = selection.tier;

    let data_node_count: i64 = if workload.high_availability {
        HA_MIN_DATA_NODES
    } else {
        1
    };

    // Line item 1: data node compute
    let compute_quantity = Decimal::from(data_node_count) * crate::types::HOURS_PER_MONTH;
    let compute_amount = super::rounded_cents(compute_quantity * instance.hourly_cents);

    // Line item 2: EBS gp3 storage (per node)
    let storage = workload.storage_gib();
    let ebs_amount = super::rounded_cents(
        storage * EBS_GP3_CENTS_PER_GIB_MONTH * Decimal::from(data_node_count),
    );

    // Line item 3: outbound data transfer
    let bandwidth_gb = ram_heuristics::estimate_monthly_bandwidth_gb(workload);
    let transfer_amount = super::rounded_cents(bandwidth_gb * DATA_TRANSFER_CENTS_PER_GB);

    let mut line_items = vec![
        CostLineItem {
            description: format!("{} × {} data node(s)", instance.name, data_node_count),
            quantity: compute_quantity,
            unit: "instance_hours".to_string(),
            unit_price_cents: instance.hourly_cents,
            amount_cents: compute_amount,
        },
        CostLineItem {
            description: "EBS gp3 storage".to_string(),
            quantity: storage * Decimal::from(data_node_count),
            unit: "gib_months".to_string(),
            unit_price_cents: EBS_GP3_CENTS_PER_GIB_MONTH,
            amount_cents: ebs_amount,
        },
        CostLineItem {
            description: "Outbound data transfer".to_string(),
            quantity: bandwidth_gb,
            unit: "gb".to_string(),
            unit_price_cents: DATA_TRANSFER_CENTS_PER_GB,
            amount_cents: transfer_amount,
        },
    ];

    // Line item 4 (HA only): dedicated master nodes
    if workload.high_availability {
        let dedicated_master = dedicated_master_instance();
        let master_quantity =
            Decimal::from(DEDICATED_MASTER_NODE_COUNT) * crate::types::HOURS_PER_MONTH;
        let master_amount = super::rounded_cents(master_quantity * dedicated_master.hourly_cents);

        line_items.push(CostLineItem {
            description: format!(
                "Dedicated master nodes ({} × {})",
                dedicated_master.name, DEDICATED_MASTER_NODE_COUNT
            ),
            quantity: master_quantity,
            unit: "instance_hours".to_string(),
            unit_price_cents: dedicated_master.hourly_cents,
            amount_cents: master_amount,
        });
    }

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    let mut assumptions = vec![
        "AWS OpenSearch on-demand pricing (us-east-1); reserved instance discounts not modeled"
            .to_string(),
        "EBS gp3 storage at default provisioned IOPS/throughput".to_string(),
        "Data transfer uses first-tier rate ($0.09/GB); volume discounts above 10 TB/month not modeled"
            .to_string(),
    ];
    if workload.high_availability {
        assumptions.push(format!(
            "Multi-AZ: {} data nodes + {} dedicated master nodes ({})",
            HA_MIN_DATA_NODES, DEDICATED_MASTER_NODE_COUNT, DEDICATED_MASTER_INSTANCE_NAME
        ));
    } else {
        assumptions.push("Single-AZ: 1 data node, no dedicated master nodes".to_string());
    }
    if selection.capped {
        assumptions.push(format!(
            "Workload exceeds largest available instance ({} GiB); estimate capped",
            instance.ram_gib
        ));
    }

    EstimatedCost {
        provider: ProviderId::AwsOpenSearch,
        verification_label: metadata().verification_label(),
        monthly_total_cents,
        line_items,
        assumptions,
        plan_name: Some(instance.name.to_string()),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::doc_comment_immediately_before;

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

    fn workload_with_exact_storage_gib(storage_gib: i64) -> WorkloadProfile {
        WorkloadProfile {
            document_count: storage_gib,
            avg_document_size_bytes: 1_073_741_824,
            search_requests_per_month: 0,
            ..small_workload()
        }
    }

    // --- estimate() tests ---

    /// Covers the baseline AWS OpenSearch path: one data node, no dedicated masters, and expected compute plus storage line items.
    #[test]
    fn estimate_non_ha_single_data_node() {
        // 100K × 2048 B ≈ 0.19 GiB → ×0.5 = 0.095, min 4.0 → t3.medium (4 GiB, 7.3¢/hr)
        // Compute: 1 × 730 × 7.3 = 5329
        let est = estimate(&small_workload());
        assert_eq!(est.provider, ProviderId::AwsOpenSearch);
        assert_eq!(est.plan_name, Some("t3.medium.search".to_string()));
        assert_eq!(est.line_items.len(), 3); // compute + EBS + transfer
        assert_eq!(est.line_items[0].amount_cents, 5329);
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains("Single-AZ: 1 data node, no dedicated master nodes")));
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains("EBS gp3 storage at default provisioned IOPS/throughput")));
        assert!(est.assumptions.iter().any(|a| a.contains(
            "Data transfer uses first-tier rate ($0.09/GB); volume discounts above 10 TB/month not modeled"
        )));
    }

    /// Verifies HA pricing adds dedicated master nodes and raises total cost while keeping data-node tier selection consistent.
    #[test]
    fn estimate_ha_adds_dedicated_masters() {
        // HA: 2 data nodes + 3 dedicated masters
        // Compute: 2 × 730 × 7.3 = 10658
        // Storage: (100000 × 2048 / 1073741824) GiB × 2 nodes × 12.2¢ = 4.65¢ → 5¢
        // Transfer: 50000 searches × 2048 B × 20 results / 1B × 9¢ = 18.43¢ → 18¢
        // Masters: 3 × 730 × 12.8 = 28032
        // Total: 10658 + 5 + 18 + 28032 = 38713
        let w = WorkloadProfile {
            high_availability: true,
            ..small_workload()
        };
        let non_ha = estimate(&small_workload());
        let est = estimate(&w);
        assert_eq!(est.line_items.len(), 4); // compute + EBS + transfer + masters
        assert_eq!(est.line_items[0].amount_cents, 10658); // doubled compute
        assert_eq!(
            est.line_items[1].quantity,
            non_ha.line_items[1].quantity * Decimal::from(HA_MIN_DATA_NODES)
        ); // doubled EBS quantity
        assert_eq!(est.line_items[1].amount_cents, 5); // HA EBS uses doubled storage before rounding
        assert_eq!(est.line_items[2].amount_cents, 18);
        assert_eq!(est.line_items[3].amount_cents, 28032); // dedicated masters
        assert_eq!(est.monthly_total_cents, 38713);
        assert!(est.line_items[3]
            .description
            .contains(DEDICATED_MASTER_INSTANCE_NAME));
        assert!(est.assumptions.iter().any(|a| a.contains("Multi-AZ")));
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains(DEDICATED_MASTER_INSTANCE_NAME)));
        assert!(est
            .assumptions
            .iter()
            .any(|a| a.contains("EBS gp3 storage at default provisioned IOPS/throughput")));
        assert!(est.assumptions.iter().any(|a| a.contains(
            "Data transfer uses first-tier rate ($0.09/GB); volume discounts above 10 TB/month not modeled"
        )));
    }

    #[test]
    fn estimate_data_transfer_cost() {
        // 1M searches × 2048 B × 20 results / 1B = 40.96 GB
        // 40.96 × 9 = 368.64 → rounds to 369
        let w = WorkloadProfile {
            search_requests_per_month: 1_000_000,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[2].amount_cents, 369);
    }

    #[test]
    fn estimate_large_workload_sets_capped_assumption() {
        // 300 × 1 GiB = 300 GiB storage -> 0.5x RAM heuristic = 150 GiB
        // Largest data node instance is 128 GiB, so estimate must cap.
        let w = WorkloadProfile {
            document_count: 300,
            avg_document_size_bytes: 1_073_741_824,
            search_requests_per_month: 0,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.plan_name, Some("r6g.4xlarge.search".to_string()));
        assert!(est.assumptions.iter().any(|a| a.contains("capped")));
        assert!(est.assumptions.iter().any(|a| a.contains("128 GiB")));
    }

    #[test]
    fn estimate_r6g_data_node_rates_match_hand_calculated_totals() {
        let cases = [
            // 32 GiB storage -> 16 GiB RAM -> r6g.large.
            // Compute: 730 hr × 16.7¢ = 12191¢. EBS: 32 GiB × 12.2¢ = 390.4¢ -> 390¢.
            // Transfer: 0 searches = 0¢. Total: 12191 + 390 + 0 = 12581¢.
            ("r6g.large.search", 32, 12191, 390, 12581),
            // 64 GiB storage -> 32 GiB RAM -> r6g.xlarge.
            // Compute: 730 hr × 33.5¢ = 24455¢. EBS: 64 GiB × 12.2¢ = 780.8¢ -> 781¢.
            // Transfer: 0 searches = 0¢. Total: 24455 + 781 + 0 = 25236¢.
            ("r6g.xlarge.search", 64, 24455, 781, 25236),
            // 128 GiB storage -> 64 GiB RAM -> r6g.2xlarge.
            // Compute: 730 hr × 66.9¢ = 48837¢. EBS: 128 GiB × 12.2¢ = 1561.6¢ -> 1562¢.
            // Transfer: 0 searches = 0¢. Total: 48837 + 1562 + 0 = 50399¢.
            ("r6g.2xlarge.search", 128, 48837, 1562, 50399),
            // 256 GiB storage -> 128 GiB RAM -> r6g.4xlarge.
            // Compute: 730 hr × 133.9¢ = 97747¢. EBS: 256 GiB × 12.2¢ = 3123.2¢ -> 3123¢.
            // Transfer: 0 searches = 0¢. Total: 97747 + 3123 + 0 = 100870¢.
            ("r6g.4xlarge.search", 256, 97747, 3123, 100870),
        ];

        for (plan_name, storage_gib, compute_cents, ebs_cents, total_cents) in cases {
            let estimate = estimate(&workload_with_exact_storage_gib(storage_gib));

            assert_eq!(estimate.plan_name, Some(plan_name.to_string()));
            assert_eq!(estimate.line_items[0].amount_cents, compute_cents);
            assert_eq!(estimate.line_items[1].amount_cents, ebs_cents);
            assert_eq!(estimate.line_items[2].amount_cents, 0);
            assert_eq!(estimate.monthly_total_cents, total_cents);
        }
    }

    #[test]
    fn estimate_non_ha_excludes_dedicated_masters() {
        let est = estimate(&small_workload());
        assert_eq!(est.line_items.len(), 3);
        assert!(!est
            .line_items
            .iter()
            .any(|li| li.description.contains("Dedicated master nodes")));
        assert!(!est.assumptions.iter().any(|a| a.contains("Multi-AZ")));
    }

    #[test]
    fn estimate_transfer_rounds_half_cent_to_even() {
        // 100K × 250 B × 20 / 1B = 0.5 GB
        // 0.5 × 9 = 4.5 cents -> banker's rounding => 4
        let w = WorkloadProfile {
            avg_document_size_bytes: 250,
            search_requests_per_month: 100_000,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[2].quantity, dec!(0.5));
        assert_eq!(est.line_items[2].amount_cents, 4);
    }

    #[test]
    fn estimate_ebs_rounds_half_cent_to_even() {
        // 1 doc × 44,000,000 B = 0.040978 GiB
        // 0.040978 × 12.2 = 0.49993 cents -> rounds to 0
        let w = WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: 44_000_000,
            search_requests_per_month: 0,
            ..small_workload()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[1].quantity.round_dp(6), dec!(0.040978));
        assert_eq!(est.line_items[1].amount_cents, 0);
    }

    #[test]
    fn source_backed_on_demand_constants_match_us_east_1_offer_snapshot() {
        // Captured AWS offer file effective 2026-07-01:
        // t3.small $0.036/hr = 3.6¢, t3.medium $0.073/hr = 7.3¢,
        // m6g.large $0.128/hr = 12.8¢, r6g.large $0.167/hr = 16.7¢,
        // r6g.xlarge $0.335/hr = 33.5¢, r6g.2xlarge $0.669/hr = 66.9¢,
        // r6g.4xlarge $1.339/hr = 133.9¢, gp3 $0.122/GB-month = 12.2¢.
        let expected = [
            ("t3.small.search", 2, 2, dec!(3.6)),
            ("t3.medium.search", 2, 4, dec!(7.3)),
            ("m6g.large.search", 2, 8, dec!(12.8)),
            ("r6g.large.search", 2, 16, dec!(16.7)),
            ("r6g.xlarge.search", 4, 32, dec!(33.5)),
            ("r6g.2xlarge.search", 8, 64, dec!(66.9)),
            ("r6g.4xlarge.search", 16, 128, dec!(133.9)),
        ];

        for (instance, (name, vcpus, ram_gib, hourly_cents)) in INSTANCE_TYPES.iter().zip(expected)
        {
            assert_eq!(
                (
                    instance.name,
                    instance.vcpus,
                    instance.ram_gib,
                    instance.hourly_cents
                ),
                (name, vcpus, ram_gib, hourly_cents)
            );
        }
        assert_eq!(EBS_GP3_CENTS_PER_GIB_MONTH, dec!(12.2));
    }

    #[test]
    fn estimate_line_item_sum_equals_total() {
        let est = estimate(&small_workload());
        let sum: i64 = est.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(est.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_ha_line_item_sum_equals_total() {
        let w = WorkloadProfile {
            high_availability: true,
            ..small_workload()
        };
        let est = estimate(&w);
        let sum: i64 = est.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(est.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_has_plan_name_and_assumptions() {
        let est = estimate(&small_workload());
        assert!(est.plan_name.is_some());
        assert!(!est.assumptions.is_empty());
        assert!(est.assumptions.iter().any(|a| a.contains("us-east-1")));
    }

    // --- pre-existing metadata/tier tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::AwsOpenSearch);
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn instance_types_are_non_empty() {
        assert!(!INSTANCE_TYPES.is_empty());
    }

    #[test]
    fn instance_types_sorted_by_ram() {
        for window in INSTANCE_TYPES.windows(2) {
            assert!(
                window[0].ram_gib < window[1].ram_gib,
                "Instance types not sorted by RAM: {} ({}) >= {} ({})",
                window[0].name,
                window[0].ram_gib,
                window[1].name,
                window[1].ram_gib
            );
        }
    }

    #[test]
    fn instance_types_have_positive_hourly_prices() {
        for instance in INSTANCE_TYPES {
            assert!(
                instance.hourly_cents > Decimal::ZERO,
                "Instance {} has non-positive hourly price",
                instance.name
            );
        }
    }

    #[test]
    fn ebs_storage_price_is_positive() {
        assert!(EBS_GP3_CENTS_PER_GIB_MONTH > Decimal::ZERO);
    }

    #[test]
    fn data_transfer_price_is_positive() {
        assert!(DATA_TRANSFER_CENTS_PER_GB > Decimal::ZERO);
    }

    #[test]
    fn dedicated_master_node_count_is_odd_and_at_least_three() {
        const { assert!(DEDICATED_MASTER_NODE_COUNT >= 3) };
        assert_eq!(DEDICATED_MASTER_NODE_COUNT % 2, 1);
    }

    #[test]
    fn dedicated_master_instance_uses_table_entry() {
        let expected = INSTANCE_TYPES
            .iter()
            .find(|instance| instance.name == DEDICATED_MASTER_INSTANCE_NAME)
            .expect("dedicated master instance must exist in instance table");
        assert_eq!(dedicated_master_instance(), expected);
    }

    #[test]
    fn dedicated_master_instance_comment_labels_assumption() {
        let source = include_str!("aws_opensearch.rs");
        let comment = doc_comment_immediately_before(
            source,
            "pub const DEDICATED_MASTER_INSTANCE_NAME: &str = \"m6g.large.search\";",
        )
        .expect("source should contain dedicated master constant");

        assert!(comment.contains("modeling assumption"));
        assert!(comment.contains("not a fetched AWS price"));
        assert!(comment.contains("c6g.large.search"));
        assert!(comment.contains("r8g.large.search"));
        assert!(comment.contains("r6g.xlarge.search"));
    }

    #[test]
    fn estimate_docs_label_unmodeled_egress_free_tier() {
        let source = include_str!("aws_opensearch.rs");
        let docs = doc_comment_immediately_before(
            source,
            "pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {",
        )
        .expect("source should contain estimate function");

        assert!(docs.contains("100 GB/month"));
        assert!(docs.contains("free egress allowance"));
        assert!(docs.contains("not modeled"));
        assert!(docs.contains("overstates small AWS workloads by up to $9/month"));
    }
}
