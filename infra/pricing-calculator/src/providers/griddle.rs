//! Flapjack Cloud pricing provider: flat per-MB hot storage pricing with free tier and minimum spend.
use chrono::NaiveDate;

use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

/// Returns metadata for the Flapjack Cloud provider.
pub fn metadata() -> ProviderMetadata {
    // The first-party published rate card was independently checked on
    // 2026-08-05, so Flapjack Cloud stays under the uniform registry freshness
    // contract rather than gaining a product-owner exemption.
    super::provider_metadata(
        ProviderId::Griddle,
        "Flapjack Cloud",
        Some(NaiveDate::from_ymd_opt(2026, 8, 5).expect("valid verification date")),
        &["https://cloud.flapjack.foo"],
    )
}

// ============================================================================
// Published pricing contract
// ============================================================================
//
// The single calculator-side representation of the Flapjack Cloud rate card
// published at <https://cloud.flapjack.foo/pricing>, verified 2026-08-05.
// Billing-engine rate-card structures are deliberately not mirrored here; this
// crate only needs the published customer-facing numbers.
//
// Free and Paid are mutually exclusive plans, not a base plan plus an
// allowance. A workload inside EVERY Free cap costs nothing. A workload outside
// ANY Free cap is a Paid account, and Paid bills the workload's *entire*
// hot storage — the 250 MB Free cap is an eligibility threshold, never a
// deductible from paid usage.

/// Paid hot index storage: "Hot index storage / per MB-month / $0.05".
const CENTS_PER_MB_MONTH: i64 = 5;

/// Paid-plan floor: "Paid-plan minimum / per month / $15". Corroborated in-repo
/// by `shared_minimum_spend_cents = 1500` in
/// `infra/migrations/072_raise_paid_plan_minimum_to_15.sql`, which supersedes the
/// $5 value seeded by migration 042.
///
/// The `SHARED_` prefix deliberately mirrors that DB column name so the
/// traceability link stays greppable across the two layers. "Shared" is the
/// internal plan identifier only; every customer-facing string in this module
/// says "Paid" — see `estimate_plan_names_use_public_paid_vocabulary`.
const SHARED_MINIMUM_MONTHLY_CENTS: i64 = 1_500;

/// Free cap: "250 MB hot storage".
const FREE_HOT_STORAGE_MB: rust_decimal::Decimal = rust_decimal_macros::dec!(250);
/// Free cap: "100,000 records".
const FREE_RECORDS: i64 = 100_000;
/// Free cap: "50,000 searches per month".
const FREE_SEARCHES_PER_MONTH: i64 = 50_000;
/// Free cap: "3 indices".
const FREE_INDEXES: i64 = 3;

/// Whether the workload stays inside every published Free cap.
///
/// All four caps must hold; breaching any one moves the account to Paid.
fn qualifies_for_free_plan(workload: &WorkloadProfile) -> bool {
    workload.storage_mb() <= FREE_HOT_STORAGE_MB
        && workload.document_count <= FREE_RECORDS
        && workload.search_requests_per_month <= FREE_SEARCHES_PER_MONTH
        && workload.num_indexes <= FREE_INDEXES
}

/// Estimates monthly cost for Flapjack Cloud.
///
/// Free workloads get a single zero-cost line item so the storage they use is
/// still visible. Paid workloads are billed on their full hot-storage
/// quantity, and a separate monthly-minimum adjustment line item carries the
/// remainder whenever that charge lands below `SHARED_MINIMUM_MONTHLY_CENTS`.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let storage_mb = workload.storage_mb();

    if qualifies_for_free_plan(workload) {
        return free_plan_estimate(storage_mb);
    }

    let unit_price_cents = rust_decimal::Decimal::from(CENTS_PER_MB_MONTH);
    let raw_cents = super::rounded_cents(storage_mb * unit_price_cents);
    let mut line_items = vec![CostLineItem {
        description: "Hot storage".to_string(),
        quantity: storage_mb,
        unit: "mb_months".to_string(),
        unit_price_cents,
        amount_cents: raw_cents,
    }];

    let mut assumptions = shared_assumptions();
    if raw_cents < SHARED_MINIMUM_MONTHLY_CENTS {
        let minimum_adjustment_cents = SHARED_MINIMUM_MONTHLY_CENTS - raw_cents;
        line_items.push(CostLineItem {
            description: "Monthly minimum adjustment".to_string(),
            quantity: rust_decimal::Decimal::ONE,
            unit: "month".to_string(),
            unit_price_cents: rust_decimal::Decimal::from(minimum_adjustment_cents),
            amount_cents: minimum_adjustment_cents,
        });
        assumptions.push(format!(
            "Monthly minimum applied: raw cost {raw_cents} cents floored to {SHARED_MINIMUM_MONTHLY_CENTS} cents"
        ));
    }

    EstimatedCost {
        provider: ProviderId::Griddle,
        verification_label: metadata().verification_label(),
        monthly_total_cents: super::sum_line_item_amounts(&line_items),
        line_items,
        assumptions,
        plan_name: Some("Flapjack Cloud Paid".to_string()),
    }
}

/// The zero-cost estimate for a workload inside every Free cap. The storage
/// quantity is still reported so the customer can see how much of the Free
/// allowance the workload consumes.
fn free_plan_estimate(storage_mb: rust_decimal::Decimal) -> EstimatedCost {
    let line_items = vec![CostLineItem {
        description: "Hot storage (Free plan)".to_string(),
        quantity: storage_mb,
        unit: "mb_months".to_string(),
        unit_price_cents: rust_decimal::Decimal::ZERO,
        amount_cents: 0,
    }];

    let mut assumptions = shared_assumptions();
    assumptions.push(format!(
        "Free plan: within all published caps ({FREE_HOT_STORAGE_MB} MB hot storage, \
         {FREE_RECORDS} records, {FREE_SEARCHES_PER_MONTH} searches/month, {FREE_INDEXES} indices)"
    ));

    EstimatedCost {
        provider: ProviderId::Griddle,
        verification_label: metadata().verification_label(),
        monthly_total_cents: super::sum_line_item_amounts(&line_items),
        line_items,
        assumptions,
        plan_name: Some("Flapjack Cloud Free".to_string()),
    }
}

/// Assumptions that hold on both plans.
fn shared_assumptions() -> Vec<String> {
    vec![
        "Flapjack Cloud pricing is storage-only — no per-search or per-write charges".to_string(),
        "High availability is bundled at no additional cost".to_string(),
    ]
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

    /// Sits exactly on all four published Free caps: 100_000 × 2_500 B = 250 MB
    /// of hot storage, 100_000 records, 50_000 searches, 3 indices.
    fn workload_at_every_free_cap() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2_500,
            search_requests_per_month: 50_000,
            write_operations_per_month: 500,
            sort_directions: 0,
            num_indexes: 3,
            high_availability: false,
        }
    }

    /// 10_000 × 1_000 B = 10 MB of hot storage — 50 cents raw, far below the $15
    /// Paid minimum — and inside every Free cap. Boundary tests break exactly
    /// one non-storage cap so the Paid floor is what they actually measure.
    fn sub_minimum_storage_within_free_caps() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 10_000,
            avg_document_size_bytes: 1_000,
            search_requests_per_month: 10_000,
            write_operations_per_month: 500,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- Free-tier eligibility -----------------------------------------------

    #[test]
    fn estimate_at_every_free_cap_costs_nothing() {
        let est = estimate(&workload_at_every_free_cap());
        assert_eq!(est.provider, ProviderId::Griddle);
        assert_eq!(est.monthly_total_cents, 0);
        assert_eq!(est.line_items.len(), 1);
        assert_eq!(est.line_items[0].quantity, dec!(250));
        assert_eq!(est.line_items[0].unit, "mb_months");
        assert_eq!(est.line_items[0].unit_price_cents, dec!(0));
        assert_eq!(est.line_items[0].amount_cents, 0);
        assert!(
            !est.assumptions.iter().any(|a| a.contains("minimum")),
            "a Free workload must not carry a minimum-spend note: {:?}",
            est.assumptions
        );
    }

    #[test]
    fn estimate_one_mb_over_the_free_storage_cap_bills_all_storage() {
        // 100_000 × 2_510 B = 251 MB. The Free 250 MB cap is an eligibility
        // threshold, not a deductible allowance: the Paid path bills all
        // 251 MB × 5 cents = 1255 cents, not the 1 MB above the cap.
        //
        // The storage line item is asserted directly rather than via the total,
        // because 1255 cents sits below the $15 paid minimum and the floor would
        // otherwise mask whether all 251 MB was billed. That masking is the whole
        // point of this test, so it must assert the pre-floor number.
        let w = WorkloadProfile {
            avg_document_size_bytes: 2_510,
            ..workload_at_every_free_cap()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[0].quantity, dec!(251));
        assert_eq!(
            est.line_items[0].amount_cents, 1_255,
            "all 251 MB must be billed, not just the 1 MB above the cap"
        );
        assert_eq!(est.line_items.len(), 2, "storage plus minimum adjustment");
        assert_eq!(est.line_items[1].amount_cents, 245);
        assert_eq!(est.monthly_total_cents, 1_500);
    }

    #[test]
    fn estimate_over_only_the_free_record_cap_floors_to_paid_minimum() {
        // 100_001 × 100 B = 10.0001 MB → 50 cents raw, inside every other cap.
        let w = WorkloadProfile {
            document_count: 100_001,
            avg_document_size_bytes: 100,
            ..sub_minimum_storage_within_free_caps()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[0].amount_cents, 50);
        assert_eq!(est.line_items[1].amount_cents, 1_450);
        assert_eq!(est.monthly_total_cents, 1_500);
    }

    #[test]
    fn estimate_over_only_the_free_search_cap_floors_to_paid_minimum() {
        let w = WorkloadProfile {
            search_requests_per_month: 50_001,
            ..sub_minimum_storage_within_free_caps()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[0].amount_cents, 50);
        assert_eq!(est.line_items[1].amount_cents, 1_450);
        assert_eq!(est.monthly_total_cents, 1_500);
    }

    #[test]
    fn estimate_over_only_the_free_index_cap_floors_to_paid_minimum() {
        let w = WorkloadProfile {
            num_indexes: 4,
            ..sub_minimum_storage_within_free_caps()
        };
        let est = estimate(&w);
        assert_eq!(est.line_items[0].amount_cents, 50);
        assert_eq!(est.line_items[1].amount_cents, 1_450);
        assert_eq!(est.monthly_total_cents, 1_500);
    }

    #[test]
    fn free_caps_match_the_published_rate_card() {
        assert_eq!(FREE_HOT_STORAGE_MB, dec!(250));
        assert_eq!(FREE_RECORDS, 100_000);
        assert_eq!(FREE_SEARCHES_PER_MONTH, 50_000);
        assert_eq!(FREE_INDEXES, 3);
        assert_eq!(CENTS_PER_MB_MONTH, 5);
        assert_eq!(SHARED_MINIMUM_MONTHLY_CENTS, 1_500);
    }

    // --- estimate() tests ---

    #[test]
    fn estimate_250_mb_dataset() {
        // 250 MB is exactly the Free hot-storage cap, and this fixture is inside
        // every other Free cap too (1 record, 10K searches, 1 index) — so it is
        // a Free workload, not $12.50 of Paid storage.
        let w = workload_with_storage_bytes(250_000_000);
        let est = estimate(&w);
        assert_eq!(est.provider, ProviderId::Griddle);
        assert_eq!(est.monthly_total_cents, 0);
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
    fn estimate_below_minimum_floors_to_paid_minimum() {
        // 10 MB × 5 cents/MB = 50 cents raw. The workload exceeds the Free index
        // cap, so it is a Paid account and floors to the $15 paid-plan minimum.
        let w = WorkloadProfile {
            num_indexes: 4,
            ..sub_minimum_storage_within_free_caps()
        };
        let est = estimate(&w);
        assert_eq!(est.monthly_total_cents, 1_500);
        assert!(
            est.assumptions
                .iter()
                .any(|a| a.contains("Monthly minimum")),
            "should note the minimum was applied"
        );
    }

    #[test]
    fn estimate_below_minimum_keeps_storage_math_transparent() {
        let est = estimate(&WorkloadProfile {
            num_indexes: 4,
            ..sub_minimum_storage_within_free_caps()
        });
        assert_eq!(est.line_items.len(), 2);
        assert_eq!(est.line_items[0].description, "Hot storage");
        assert_eq!(est.line_items[0].quantity, dec!(10));
        assert_eq!(est.line_items[0].unit_price_cents, dec!(5));
        assert_eq!(est.line_items[0].amount_cents, 50);
        assert_eq!(est.line_items[1].description, "Monthly minimum adjustment");
        assert_eq!(est.line_items[1].quantity, dec!(1));
        assert_eq!(est.line_items[1].amount_cents, 1_450);
    }

    /// Captures Flapjack Cloud pricing behavior where HA is bundled and therefore does not change plan, line items, or monthly total.
    #[test]
    fn estimate_ha_adds_no_surcharge() {
        // HA is bundled — same price as non-HA. Uses a paid (1 GB) workload so
        // the assertion compares a real charge rather than 0 against 0.
        let base = workload_with_storage_bytes(1_000_000_000);
        let ha = WorkloadProfile {
            high_availability: true,
            ..workload_with_storage_bytes(1_000_000_000)
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

    /// `plan_name` is rendered verbatim to the public landing page — the API
    /// route `routes/pricing.rs` hands this estimate to
    /// `LandingPricingCalculator.svelte`, which prints `estimate.plan_name`.
    /// So these strings must use the *public* plan vocabulary.
    ///
    /// Public copy calls the paid plan "Paid" (`/pricing` renders "Paid
    /// accounts have a $X/month paid-plan minimum"). "Shared" is an
    /// internal-only identifier — `BillingPlan::Shared`, the persisted
    /// `"shared"` string, and the `shared_minimum_spend_cents` column — and
    /// must never reach a customer surface.
    ///
    /// This replaced a `plan_name.is_some()` assertion that could not fail for
    /// a wrong name, which is how "Flapjack Cloud Shared" reached the landing
    /// page unnoticed.
    #[test]
    fn estimate_plan_names_use_public_paid_vocabulary() {
        // Breaches the Free index cap, so this takes the paid branch.
        let paid = estimate(&WorkloadProfile {
            num_indexes: 4,
            ..sub_minimum_storage_within_free_caps()
        });
        let free = estimate(&workload_at_every_free_cap());

        assert_eq!(paid.plan_name.as_deref(), Some("Flapjack Cloud Paid"));
        assert_eq!(free.plan_name.as_deref(), Some("Flapjack Cloud Free"));
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
}
