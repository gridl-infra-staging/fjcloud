//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_usage_based.rs.
use chrono::NaiveDate;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};

pub const DISPLAY_NAME: &str = "Meilisearch Cloud (Usage-Based)";
pub const SOURCE_URLS: &[&str] = &[
    "https://www.meilisearch.com/usage-based",
    "https://help.meilisearch.com/articles/5542905035-what-happens-if-i-exceed-my-plan-limits",
];

/// Returns metadata for Meilisearch Cloud (usage-based plans).
pub fn metadata() -> ProviderMetadata {
    super::provider_metadata(
        ProviderId::MeilisearchUsageBased,
        DISPLAY_NAME,
        Some(NaiveDate::from_ymd_opt(2026, 3, 15).expect("valid verification date")),
        SOURCE_URLS,
    )
}

// ============================================================================
// Pricing data — usage-based Build and Pro plans
// ============================================================================

/// A Meilisearch usage-based plan with included usage and overage rates.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct UsagePlan {
    pub name: &'static str,
    pub monthly_base_cents: i64,
    pub included_searches: i64,
    pub included_documents: i64,
    pub search_overage_cents_per_1k: Decimal,
    pub document_overage_cents_per_1k: Decimal,
}

/// Build plan, verified from the public usage-based pricing page and billing KB.
pub const BUILD_PLAN: UsagePlan = UsagePlan {
    name: "Build",
    monthly_base_cents: 3_000,
    included_searches: 50_000,
    included_documents: 100_000,
    search_overage_cents_per_1k: dec!(40),
    document_overage_cents_per_1k: dec!(30),
};

/// Pro plan, verified from the public usage-based pricing page and billing KB.
pub const PRO_PLAN: UsagePlan = UsagePlan {
    name: "Pro",
    monthly_base_cents: 30_000,
    included_searches: 250_000,
    included_documents: 1_000_000,
    search_overage_cents_per_1k: dec!(30),
    document_overage_cents_per_1k: dec!(20),
};

/// Available usage-based plans, ordered by monthly base price.
pub const PLANS: &[UsagePlan] = &[BUILD_PLAN, PRO_PLAN];

// ============================================================================
// Usage-based estimator — automatic Build/Pro selection (Stage 4)
// ============================================================================

/// Scores a single plan against a workload, returning total monthly cost in cents.
///
/// This is the single source of truth for Build-vs-Pro selection. Both `estimate()`
/// and tests call this helper — no duplicated comparison logic.
fn evaluate_plan(plan: &UsagePlan, workload: &WorkloadProfile) -> i64 {
    let doc_qty_1k = super::overage_quantity_1k(
        Decimal::from(workload.document_count),
        plan.included_documents,
    );
    let doc_overage_cents = super::rounded_cents(doc_qty_1k * plan.document_overage_cents_per_1k);

    let search_qty_1k = super::overage_quantity_1k(
        Decimal::from(workload.search_requests_per_month),
        plan.included_searches,
    );
    let search_overage_cents =
        super::rounded_cents(search_qty_1k * plan.search_overage_cents_per_1k);

    plan.monthly_base_cents + doc_overage_cents + search_overage_cents
}

/// Estimates monthly cost for Meilisearch Cloud usage-based pricing.
///
/// Evaluates all plans, selects the cheapest, and returns 3 line items
/// (base fee + document overage + search overage) with the selected plan name.
pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost {
    let selected = PLANS
        .iter()
        .min_by_key(|plan| evaluate_plan(plan, workload))
        .expect("PLANS is non-empty");

    let doc_qty_1k = super::overage_quantity_1k(
        Decimal::from(workload.document_count),
        selected.included_documents,
    );
    let doc_cents = super::rounded_cents(doc_qty_1k * selected.document_overage_cents_per_1k);

    let search_qty_1k = super::overage_quantity_1k(
        Decimal::from(workload.search_requests_per_month),
        selected.included_searches,
    );
    let search_cents = super::rounded_cents(search_qty_1k * selected.search_overage_cents_per_1k);

    let line_items = vec![
        CostLineItem {
            description: format!("{} plan base fee", selected.name),
            quantity: dec!(1),
            unit: "month".to_string(),
            unit_price_cents: Decimal::from(selected.monthly_base_cents),
            amount_cents: selected.monthly_base_cents,
        },
        CostLineItem {
            description: "Document overage".to_string(),
            quantity: doc_qty_1k,
            unit: "documents_1k".to_string(),
            unit_price_cents: selected.document_overage_cents_per_1k,
            amount_cents: doc_cents,
        },
        CostLineItem {
            description: "Search request overage".to_string(),
            quantity: search_qty_1k,
            unit: "searches_1k".to_string(),
            unit_price_cents: selected.search_overage_cents_per_1k,
            amount_cents: search_cents,
        },
    ];

    let monthly_total_cents = super::sum_line_item_amounts(&line_items);

    EstimatedCost {
        provider: ProviderId::MeilisearchUsageBased,
        monthly_total_cents,
        line_items,
        assumptions: vec![
            format!(
                "Automatically selected {} plan (lowest total cost)",
                selected.name
            ),
            "Overage billing applies when exceeding plan included amounts".to_string(),
        ],
        plan_name: Some(selected.name.to_string()),
    }
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::WorkloadProfile;
    use rust_decimal_macros::dec;

    fn base_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 50_000,
            avg_document_size_bytes: 2048,
            search_requests_per_month: 20_000,
            write_operations_per_month: 500,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- evaluate_plan() tests -----------------------------------------------

    #[test]
    fn evaluate_plan_build_within_included() {
        // 50K docs < 100K included, 20K searches < 50K included → base only
        let w = base_workload();
        assert_eq!(evaluate_plan(&BUILD_PLAN, &w), 3_000);
    }

    #[test]
    fn evaluate_plan_pro_within_included() {
        let w = base_workload();
        assert_eq!(evaluate_plan(&PRO_PLAN, &w), 30_000);
    }

    #[test]
    fn evaluate_plan_build_with_overages() {
        // 2M docs, 500K searches on Build:
        // base: 3000
        // doc overage: (2M - 100K) / 1000 * 30 = 1900 * 30 = 57000
        // search overage: (500K - 50K) / 1000 * 40 = 450 * 40 = 18000
        // total: 78000
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        assert_eq!(evaluate_plan(&BUILD_PLAN, &w), 78_000);
    }

    #[test]
    fn evaluate_plan_pro_with_overages() {
        // 2M docs, 500K searches on Pro:
        // base: 30000
        // doc overage: (2M - 1M) / 1000 * 20 = 1000 * 20 = 20000
        // search overage: (500K - 250K) / 1000 * 30 = 250 * 30 = 7500
        // total: 57500
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        assert_eq!(evaluate_plan(&PRO_PLAN, &w), 57_500);
    }

    // --- estimate() tests ----------------------------------------------------

    #[test]
    fn estimate_selects_build_for_small_workload() {
        let result = estimate(&base_workload());
        assert_eq!(result.plan_name, Some("Build".to_string()));
        assert_eq!(result.monthly_total_cents, 3_000);
    }

    #[test]
    fn estimate_selects_pro_when_cheaper() {
        // Pro (57500) < Build (78000) for this heavy workload
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.plan_name, Some("Pro".to_string()));
        assert_eq!(result.monthly_total_cents, 57_500);
    }

    #[test]
    fn estimate_emits_three_line_items() {
        let result = estimate(&base_workload());
        assert_eq!(
            result.line_items.len(),
            3,
            "Must emit base + doc overage + search overage"
        );
    }

    #[test]
    fn estimate_line_item_sum_equals_total() {
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        let result = estimate(&w);
        let sum: i64 = result.line_items.iter().map(|li| li.amount_cents).sum();
        assert_eq!(result.monthly_total_cents, sum);
    }

    #[test]
    fn estimate_base_fee_line_item_shape() {
        let result = estimate(&base_workload());
        let base_li = &result.line_items[0];
        assert_eq!(base_li.quantity, dec!(1));
        assert_eq!(base_li.unit, "month");
        assert_eq!(base_li.amount_cents, BUILD_PLAN.monthly_base_cents);
    }

    #[test]
    fn estimate_overage_line_items_zero_when_within_included() {
        let result = estimate(&base_workload());
        assert_eq!(result.line_items[1].amount_cents, 0); // doc overage
        assert_eq!(result.line_items[2].amount_cents, 0); // search overage
    }

    #[test]
    fn estimate_has_provider_id() {
        let result = estimate(&base_workload());
        assert_eq!(result.provider, ProviderId::MeilisearchUsageBased);
    }

    #[test]
    fn estimate_has_two_assumptions() {
        let result = estimate(&base_workload());
        assert_eq!(result.assumptions.len(), 2);
        assert!(result.assumptions.iter().all(|a: &String| !a.is_empty()));
    }

    #[test]
    fn estimate_doc_overage_line_item_shape() {
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        let result = estimate(&w);
        // Pro selected, doc overage: (2M - 1M) / 1000 = 1000 units
        assert_eq!(result.line_items[1].quantity, dec!(1000));
        assert_eq!(result.line_items[1].unit, "documents_1k");
        assert_eq!(
            result.line_items[1].unit_price_cents,
            PRO_PLAN.document_overage_cents_per_1k
        );
    }

    #[test]
    fn estimate_search_overage_line_item_shape() {
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 500_000,
            ..base_workload()
        };
        let result = estimate(&w);
        // Pro selected, search overage: (500K - 250K) / 1000 = 250 units
        assert_eq!(result.line_items[2].quantity, dec!(250));
        assert_eq!(result.line_items[2].unit, "searches_1k");
        assert_eq!(
            result.line_items[2].unit_price_cents,
            PRO_PLAN.search_overage_cents_per_1k
        );
    }

    // --- boundary tests -------------------------------------------------------

    #[test]
    fn estimate_exactly_at_build_document_boundary() {
        // 100K docs = Build included_documents → no doc overage, Build wins
        let w = WorkloadProfile {
            document_count: 100_000,
            search_requests_per_month: 0,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.plan_name, Some("Build".to_string()));
        assert_eq!(
            result.line_items[1].amount_cents, 0,
            "exactly at boundary should be free"
        );
    }

    #[test]
    fn estimate_one_doc_over_build_boundary() {
        // 100_001 docs → Build doc overage: 1/1000 * 30 = 0.03 → rounds to 0
        let w = WorkloadProfile {
            document_count: 100_001,
            search_requests_per_month: 0,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(result.plan_name, Some("Build".to_string()));
        assert_eq!(result.line_items[1].amount_cents, 0);
    }

    #[test]
    fn estimate_exactly_at_build_search_boundary() {
        // 50K searches = Build included → no search overage
        let w = WorkloadProfile {
            search_requests_per_month: 50_000,
            ..base_workload()
        };
        let result = estimate(&w);
        assert_eq!(
            result.line_items[2].amount_cents, 0,
            "exactly at search boundary should be free"
        );
    }

    /// Demonstrates the Build-to-Pro crossover point and ensures plan selection switches when Pro becomes cheaper at high usage.
    #[test]
    fn evaluate_plan_build_versus_pro_crossover_point() {
        // Find a workload where Build cost equals or crosses Pro cost
        // Build: 3000 + (500K - 100K)/1000 * 30 + (100K - 50K)/1000 * 40 = 3000 + 12000 + 2000 = 17000
        // Pro: 30000 + 0 + 0 = 30000
        // Build still wins here. Go bigger:
        // Build: 3000 + (2M - 100K)/1000 * 30 + (200K - 50K)/1000 * 40 = 3000 + 57000 + 6000 = 66000
        // Pro: 30000 + (2M - 1M)/1000 * 20 + 0 = 30000 + 20000 = 50000
        // Pro wins at this point.
        let w = WorkloadProfile {
            document_count: 2_000_000,
            search_requests_per_month: 200_000,
            ..base_workload()
        };
        assert!(evaluate_plan(&BUILD_PLAN, &w) > evaluate_plan(&PRO_PLAN, &w));
        let result = estimate(&w);
        assert_eq!(result.plan_name, Some("Pro".to_string()));
    }

    // --- metadata tests (Stage 2) --------------------------------------------

    #[test]
    fn metadata_has_correct_provider_id() {
        assert_eq!(metadata().id, ProviderId::MeilisearchUsageBased);
    }

    #[test]
    fn metadata_has_stable_display_name() {
        assert_eq!(metadata().display_name, DISPLAY_NAME);
    }

    #[test]
    fn metadata_has_at_least_one_source_url() {
        assert!(!metadata().source_urls.is_empty());
    }

    #[test]
    fn source_urls_include_usage_based_page() {
        assert!(SOURCE_URLS.contains(&"https://www.meilisearch.com/usage-based"));
    }

    #[test]
    fn build_plan_matches_official_usage_page() {
        assert_eq!(BUILD_PLAN.name, "Build");
        assert_eq!(BUILD_PLAN.monthly_base_cents, 3_000);
        assert_eq!(BUILD_PLAN.included_searches, 50_000);
        assert_eq!(BUILD_PLAN.included_documents, 100_000);
    }

    #[test]
    fn pro_plan_matches_official_usage_page() {
        assert_eq!(PRO_PLAN.name, "Pro");
        assert_eq!(PRO_PLAN.monthly_base_cents, 30_000);
        assert_eq!(PRO_PLAN.included_searches, 250_000);
        assert_eq!(PRO_PLAN.included_documents, 1_000_000);
    }

    #[test]
    fn plans_are_sorted_by_monthly_base_price() {
        for window in PLANS.windows(2) {
            assert!(
                window[0].monthly_base_cents < window[1].monthly_base_cents,
                "Usage plans are not sorted by base price: {} >= {}",
                window[0].monthly_base_cents,
                window[1].monthly_base_cents
            );
        }
    }

    #[test]
    fn every_plan_has_positive_included_amounts_and_overage_rates() {
        for plan in PLANS {
            assert!(plan.monthly_base_cents > 0);
            assert!(plan.included_searches > 0);
            assert!(plan.included_documents > 0);
            assert!(plan.search_overage_cents_per_1k > Decimal::ZERO);
            assert!(plan.document_overage_cents_per_1k > Decimal::ZERO);
        }
    }
}
