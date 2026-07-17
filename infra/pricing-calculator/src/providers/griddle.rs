//! Flapjack Cloud pricing provider: flat per-MB hot storage pricing with free tier and minimum spend.
use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for the Flapjack Cloud provider.
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::Griddle,
        "Flapjack Cloud",
        None,
        &["https://cloud.flapjack.foo"],
    )
}

/// Flapjack Cloud hot-storage pricing: 5 cents per MB per month, $10 (1000 cents) minimum.
///
/// No search/write dimensions — pricing is storage-only. High availability is
/// bundled at no additional cost.
const CENTS_PER_MB_MONTH: i64 = 5;
const MINIMUM_MONTHLY_CENTS: i64 = 1_000;

/// Estimates monthly cost for Flapjack Cloud.
///
/// The primary line item is hot storage (`workload.storage_mb() * 5`
/// cents/month). When the raw storage total is below `MINIMUM_MONTHLY_CENTS`,
/// a separate monthly-minimum adjustment line item carries the remainder.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let storage_mb = workload.storage_mb();
    let unit_price_cents = rust_decimal::Decimal::from(CENTS_PER_MB_MONTH);

    let raw_cents = super::rounded_cents(storage_mb * unit_price_cents);
    let mut line_items = vec![CostLineItem {
        description: "Hot storage".to_string(),
        quantity: storage_mb,
        unit: "mb_months".to_string(),
        unit_price_cents,
        amount_cents: raw_cents,
    }];
    if raw_cents < MINIMUM_MONTHLY_CENTS {
        let minimum_adjustment_cents = MINIMUM_MONTHLY_CENTS - raw_cents;
        line_items.push(CostLineItem {
            description: "Monthly minimum adjustment".to_string(),
            quantity: rust_decimal::Decimal::ONE,
            unit: "month".to_string(),
            unit_price_cents: rust_decimal::Decimal::from(minimum_adjustment_cents),
            amount_cents: minimum_adjustment_cents,
        });
    }
    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    let mut assumptions = vec![
        "Flapjack Cloud pricing is storage-only — no per-search or per-write charges".to_string(),
        "High availability is bundled at no additional cost".to_string(),
    ];

    if raw_cents < MINIMUM_MONTHLY_CENTS {
        assumptions.push(format!(
            "Monthly minimum applied: raw cost {} cents floored to {} cents",
            raw_cents, MINIMUM_MONTHLY_CENTS
        ));
    }

    EstimatedCost {
        provider: ProviderId::Griddle,
        monthly_total_cents,
        line_items,
        assumptions,
        plan_name: Some("Flapjack Cloud Hot Storage".to_string()),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    fn workload_with_storage_bytes(total_bytes: i64) -> WorkloadProfile {
        // 1 document with avg_size = total_bytes gives exact storage control
        WorkloadProfile {
            document_count: 1,
            avg_document_size_bytes: total_bytes,
            search_requests_per_month: 10_000,
            write_operations_per_month: 500,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- estimate() tests ---

    #[test]
    fn estimate_250_mb_dataset() {
        // 250 MB × 5 cents/MB = 1250 cents ($12.50)
        let w = workload_with_storage_bytes(250_000_000);
        let est = estimate(&w);
        assert_eq!(est.provider, ProviderId::Griddle);
        assert_eq!(est.monthly_total_cents, 1_250);
        assert_eq!(est.line_items.len(), 1);
        assert_eq!(est.line_items[0].quantity, dec!(250));
        assert_eq!(est.line_items[0].unit, "mb_months");
    }

    #[test]
    fn estimate_1_gb_dataset() {
        // 1 GB = 1000 MB × 5 cents/MB = 5000 cents ($50)
        let w = workload_with_storage_bytes(1_000_000_000);
        let est = estimate(&w);
        assert_eq!(est.monthly_total_cents, 5_000);
        assert_eq!(est.line_items[0].quantity, dec!(1000));
    }

    #[test]
    fn estimate_5_gb_dataset() {
        // 5 GB = 5000 MB × 5 cents/MB = 25000 cents ($250)
        let w = workload_with_storage_bytes(5_000_000_000);
        let est = estimate(&w);
        assert_eq!(est.monthly_total_cents, 25_000);
        assert_eq!(est.line_items[0].quantity, dec!(5000));
    }

    #[test]
    fn estimate_below_minimum_floors_to_1000_cents() {
        // 10 MB × 5 cents/MB = 50 cents → floored to 1000 cents ($10 minimum)
        let w = workload_with_storage_bytes(10_000_000);
        let est = estimate(&w);
        assert_eq!(est.monthly_total_cents, 1_000);
        assert!(
            est.assumptions
                .iter()
                .any(|a| a.contains("Monthly minimum")),
            "should note the minimum was applied"
        );
    }

    #[test]
    fn estimate_below_minimum_keeps_storage_math_transparent() {
        let est = estimate(&workload_with_storage_bytes(10_000_000));
        assert_eq!(est.line_items.len(), 2);
        assert_eq!(est.line_items[0].description, "Hot storage");
        assert_eq!(est.line_items[0].quantity, dec!(10));
        assert_eq!(est.line_items[0].unit_price_cents, dec!(5));
        assert_eq!(est.line_items[0].amount_cents, 50);
        assert_eq!(est.line_items[1].description, "Monthly minimum adjustment");
        assert_eq!(est.line_items[1].quantity, dec!(1));
        assert_eq!(est.line_items[1].amount_cents, 950);
    }

    /// Captures Flapjack Cloud pricing behavior where HA is bundled and therefore does not change plan, line items, or monthly total.
    #[test]
    fn estimate_ha_adds_no_surcharge() {
        // HA is bundled — same price as non-HA
        let base = workload_with_storage_bytes(250_000_000);
        let ha = WorkloadProfile {
            high_availability: true,
            ..workload_with_storage_bytes(250_000_000)
        };
        let base_est = estimate(&base);
        let ha_est = estimate(&ha);
        assert_eq!(
            base_est.monthly_total_cents, ha_est.monthly_total_cents,
            "HA must not add a surcharge"
        );
        assert!(
            ha_est
                .assumptions
                .iter()
                .any(|a| a.contains("High availability")),
            "should note HA is bundled"
        );
    }

    #[test]
    fn estimate_line_item_sum_equals_total() {
        let est = estimate(&workload_with_storage_bytes(500_000_000));
        let sum: i64 = est.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(est.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_has_plan_name_and_assumptions() {
        let est = estimate(&workload_with_storage_bytes(250_000_000));
        assert!(est.plan_name.is_some());
        assert!(!est.assumptions.is_empty());
    }

    #[test]
    fn estimate_no_search_or_write_line_items() {
        let est = estimate(&workload_with_storage_bytes(250_000_000));
        for li in &est.line_items {
            assert!(
                !li.description.to_lowercase().contains("search"),
                "Flapjack Cloud must not have search line items"
            );
            assert!(
                !li.description.to_lowercase().contains("write"),
                "Flapjack Cloud must not have write line items"
            );
        }
    }

    // --- metadata() tests ---

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::Griddle);
    }

    #[test]
    fn metadata_has_display_name() {
        assert_eq!(metadata().display_name, "Flapjack Cloud");
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }
}
