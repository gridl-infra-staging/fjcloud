use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for Algolia.
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::Algolia,
        "Algolia",
        Some(NaiveDate::from_ymd_opt(2026, 3, 15).expect("valid verification date")),
        &["https://www.algolia.com/pricing/"],
    )
}

// ============================================================================
// Pricing data — Grow plan (usage-based, pay-as-you-go)
// ============================================================================

/// Free tier: searches included per month before overage kicks in.
pub const FREE_SEARCHES_PER_MONTH: i64 = 10_000;

/// Free tier: records included before overage kicks in.
pub const FREE_RECORDS: i64 = 100_000;

/// Overage rate per 1K search requests beyond the free tier (in cents).
/// $0.50 / 1K = 50 cents / 1K.
pub const SEARCH_OVERAGE_CENTS_PER_1K: Decimal = dec!(50);

/// Overage rate per 1K records beyond the free tier (in cents).
/// $0.40 / 1K = 40 cents / 1K.
pub const RECORD_OVERAGE_CENTS_PER_1K: Decimal = dec!(40);

/// Standard replicas multiply the record count. Each sort direction adds one
/// standard replica, so effective records = `document_count * (1 + sort_directions)`.
/// The 3 highest-usage days per month are ignored for record billing, but this
/// calculator uses worst-case (no exclusion) for simplicity.
pub fn effective_records(document_count: i64, sort_directions: u8) -> Decimal {
    Decimal::from(document_count)
        .checked_mul(Decimal::from(1 + i64::from(sort_directions)))
        .expect("effective record calculation fits in Decimal")
}

// ============================================================================
// Usage-based estimator — Grow plan (Stage 4)
// ============================================================================

/// Estimates monthly cost for Algolia's Grow plan (usage-based, pay-as-you-go).
///
/// Returns two line items (record overage + search overage), always emitted even
/// when $0, with `plan_name: Some("Grow")` and 3 assumption strings.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let total_records = effective_records(workload.document_count, workload.sort_directions);

    let (record_qty_1k, record_cents) =
        super::overage_amount_1k(total_records, FREE_RECORDS, RECORD_OVERAGE_CENTS_PER_1K);
    let (search_qty_1k, search_cents) = super::overage_amount_1k(
        Decimal::from(workload.search_requests_per_month),
        FREE_SEARCHES_PER_MONTH,
        SEARCH_OVERAGE_CENTS_PER_1K,
    );

    let line_items = vec![
        CostLineItem {
            description: "Record overage (includes standard replicas)".to_string(),
            quantity: record_qty_1k,
            unit: "records_1k".to_string(),
            unit_price_cents: RECORD_OVERAGE_CENTS_PER_1K,
            amount_cents: record_cents,
        },
        CostLineItem {
            description: "Search request overage".to_string(),
            quantity: search_qty_1k,
            unit: "searches_1k".to_string(),
            unit_price_cents: SEARCH_OVERAGE_CENTS_PER_1K,
            amount_cents: search_cents,
        },
    ];

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    EstimatedCost {
        provider: ProviderId::Algolia,
        monthly_total_cents,
        line_items,
        assumptions: vec![
            "Algolia Grow plan (pay-as-you-go); Grow Plus volume discounts not modeled".to_string(),
            "Standard replicas used for sort directions; virtual replicas are a zero-cost alternative".to_string(),
            "Record billing uses worst-case month (3-day peak exclusion not applied)".to_string(),
        ],
        plan_name: Some("Grow".to_string()),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::WorkloadProfile;
    use rust_decimal::Decimal;
    use rust_decimal_macros::dec;

    fn base_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 50_000,
            avg_document_size_bytes: 2048,
            search_requests_per_month: 5_000,
            write_operations_per_month: 500,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- estimate() tests (Stage 4) ------------------------------------------

    #[test]
    fn estimate_within_free_tier_has_zero_total() {
        // 50K docs, 0 sort dirs → 50K effective records < 100K free
        // 5K searches < 10K free
        let result = estimate(&base_workload());
        assert_eq!(result.monthly_total_cents, 0);
    }

    #[test]
    fn estimate_within_free_tier_still_emits_both_line_items() {
        let result = estimate(&base_workload());
        assert_eq!(
            result.line_items.len(),
            2,
            "Must emit record + search line items even when $0"
        );
        assert!(result.line_items.iter().all(|li| li.amount_cents == 0));
    }

    #[test]
    fn estimate_sort_directions_create_record_overage() {
        // 50K docs × (1 + 3) = 200K effective records
        // Overage: 200K - 100K = 100K → 100 units × $0.40/1K = $40.00 = 4000 cents
        let w = WorkloadProfile {
            sort_directions: 3,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.monthly_total_cents, 4000);
        assert_eq!(result.line_items[0].amount_cents, 4000); // record overage
        assert_eq!(result.line_items[1].amount_cents, 0); // search still free
    }

    #[test]
    fn estimate_search_overage() {
        // 60K searches → overage: 60K - 10K = 50K → 50 units × $0.50/1K = $25.00 = 2500 cents
        let w = WorkloadProfile {
            search_requests_per_month: 60_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.monthly_total_cents, 2500);
        assert_eq!(result.line_items[0].amount_cents, 0); // records still free
        assert_eq!(result.line_items[1].amount_cents, 2500); // search overage
    }

    #[test]
    fn estimate_both_overages_combined() {
        // 50K docs × 4 = 200K records → 100K overage → 100 × 40 = 4000
        // 60K searches → 50K overage → 50 × 50 = 2500
        // Total: 6500
        let w = WorkloadProfile {
            sort_directions: 3,
            search_requests_per_month: 60_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.monthly_total_cents, 6500);
    }

    #[test]
    fn estimate_line_item_sum_equals_total() {
        let w = WorkloadProfile {
            sort_directions: 3,
            search_requests_per_month: 60_000,
            ..base_workload()
        };
        let result = estimate(&w);
        let sum: i64 = result.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(result.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_has_plan_name_grow() {
        let result = estimate(&base_workload());
        assert_eq!(result.plan_name, Some("Grow".to_string()));
    }

    #[test]
    fn estimate_has_provider_id_algolia() {
        let result = estimate(&base_workload());
        assert_eq!(result.provider, ProviderId::Algolia);
    }

    #[test]
    fn estimate_has_three_assumptions() {
        let result = estimate(&base_workload());
        assert_eq!(result.assumptions.len(), 3);
        assert!(result.assumptions.iter().all(|a: &String| !a.is_empty()));
    }

    #[test]
    fn estimate_record_line_item_uses_effective_records() {
        // Verify that the record overage quantity reflects effective_records()
        // 50K docs × 4 = 200K → overage = 100K → quantity = 100 (in 1K units)
        let w = WorkloadProfile {
            sort_directions: 3,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.line_items[0].quantity, dec!(100));
        assert_eq!(
            result.line_items[0].unit_price_cents,
            RECORD_OVERAGE_CENTS_PER_1K
        );
        assert_eq!(result.line_items[0].unit, "records_1k");
    }

    #[test]
    fn estimate_search_line_item_shape() {
        // 60K searches → overage = 50K → quantity = 50 (in 1K units)
        let w = WorkloadProfile {
            search_requests_per_month: 60_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.line_items[1].quantity, dec!(50));
        assert_eq!(
            result.line_items[1].unit_price_cents,
            SEARCH_OVERAGE_CENTS_PER_1K
        );
        assert_eq!(result.line_items[1].unit, "searches_1k");
    }

    #[test]
    fn estimate_exactly_at_record_free_tier_boundary() {
        // 100K docs, 0 sort dirs → exactly 100K effective = 100K free → no overage
        let w = WorkloadProfile {
            document_count: 100_000,
            sort_directions: 0,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(
            result.line_items[0].amount_cents, 0,
            "exactly at boundary should be free"
        );
    }

    #[test]
    fn estimate_one_record_over_free_tier() {
        // 100_001 docs, 0 sort dirs → 1 record overage → 0.001 × 40 = 0.04 → rounds to 0
        let w = WorkloadProfile {
            document_count: 100_001,
            sort_directions: 0,
            ..base_workload()
        };
        let result = estimate(&w);
        // 1 record / 1000 * 40 = 0.04 cents → banker's rounding → 0
        assert_eq!(result.line_items[0].amount_cents, 0);
    }

    #[test]
    fn estimate_exactly_at_search_free_tier_boundary() {
        // Exactly 10K searches = 10K free → no overage
        let w = WorkloadProfile {
            search_requests_per_month: 10_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(
            result.line_items[1].amount_cents, 0,
            "exactly at boundary should be free"
        );
    }

    #[test]
    fn estimate_one_search_over_free_tier() {
        // 10_001 searches → 1 overage → 0.001 × 50 = 0.05 → rounds to 0
        let w = WorkloadProfile {
            search_requests_per_month: 10_001,
            ..base_workload()
        };
        let result = estimate(&w);
        // 1 search / 1000 * 50 = 0.05 cents → banker's rounding → 0
        assert_eq!(result.line_items[1].amount_cents, 0);
    }

    #[test]
    fn estimate_large_valid_workload_does_not_overflow() {
        let w = WorkloadProfile {
            document_count: i64::MAX,
            sort_directions: 10,
            search_requests_per_month: 0,
            ..base_workload()
        };

        let result = estimate(&w);
        assert!(result.monthly_total_cents > 0);
        assert_eq!(
            result.monthly_total_cents,
            result
                .line_items
                .iter()
                .map(|li| li.amount_cents)
                .sum::<i64>()
        );
    }

    // --- metadata tests (Stage 2) --------------------------------------------

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::Algolia);
    }

    #[test]
    fn metadata_has_stable_display_name() {
        assert_eq!(metadata().display_name, "Algolia");
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn search_overage_rate_is_positive() {
        assert!(SEARCH_OVERAGE_CENTS_PER_1K > Decimal::ZERO);
    }

    #[test]
    fn record_overage_rate_is_positive() {
        assert!(RECORD_OVERAGE_CENTS_PER_1K > Decimal::ZERO);
    }

    #[test]
    fn free_tier_searches_is_positive() {
        const { assert!(FREE_SEARCHES_PER_MONTH > 0) };
    }

    #[test]
    fn free_tier_records_is_positive() {
        const { assert!(FREE_RECORDS > 0) };
    }

    #[test]
    fn effective_records_no_sort_directions() {
        assert_eq!(effective_records(100_000, 0), dec!(100000));
    }

    #[test]
    fn effective_records_with_sort_directions() {
        // 100K docs × (1 + 3 sort directions) = 400K
        assert_eq!(effective_records(100_000, 3), dec!(400000));
    }

    #[test]
    fn effective_records_large_valid_input_does_not_panic() {
        let result = std::panic::catch_unwind(|| effective_records(i64::MAX, 10));
        assert!(
            result.is_ok(),
            "effective_records should handle validated max workloads"
        );
        assert_eq!(result.unwrap(), Decimal::from(i64::MAX) * dec!(11));
    }
}
