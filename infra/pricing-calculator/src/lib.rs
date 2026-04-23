//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/lib.rs.
pub mod presets;
pub mod providers;
pub mod ram_heuristics;
pub mod types;

use chrono::Utc;
pub use presets::{preset_scenarios, PresetScenario};
pub use providers::stale_providers;
use types::{ComparisonResult, ProviderMetadata, ValidationError, WorkloadProfile};

/// Compare all registered search providers for the given workload.
///
/// Validates the workload first, then collects estimates from every registered
/// provider, and returns them sorted cheapest-first by `monthly_total_cents`.
pub fn compare_all(workload: &WorkloadProfile) -> Result<ComparisonResult, ValidationError> {
    workload.validate()?;

    let mut estimates = providers::all_estimates(workload);
    estimates.sort_by_key(|e| e.monthly_total_cents);

    Ok(ComparisonResult {
        workload: workload.clone(),
        estimates,
        generated_at: Utc::now(),
    })
}

/// Formats freshness-gate failures with provider names and verification labels so operators know exactly which pricing sources must be refreshed.
fn stale_provider_failure_message(threshold_days: i64, stale: &[ProviderMetadata]) -> String {
    let provider_entries = stale
        .iter()
        .map(|provider| {
            format!(
                "{} ({})",
                provider.display_name,
                provider.verification_label()
            )
        })
        .collect::<Vec<_>>()
        .join(", ");

    format!(
        "Pricing metadata is older than {} days for: {}",
        threshold_days.max(0),
        provider_entries
    )
}

/// Enforces pricing metadata freshness for all registered providers.
///
/// Returns `Ok(())` when no providers are stale at the given threshold, or an
/// error message naming each stale provider and its verification label.
pub fn ensure_pricing_freshness(threshold_days: i64) -> Result<(), String> {
    let stale = stale_providers(threshold_days);
    if stale.is_empty() {
        return Ok(());
    }

    Err(stale_provider_failure_message(threshold_days, &stale))
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ProviderId, WorkloadProfile};
    use chrono::{Duration, NaiveDate};

    fn valid_workload() -> WorkloadProfile {
        WorkloadProfile {
            document_count: 100_000,
            avg_document_size_bytes: 2048,
            search_requests_per_month: 50_000,
            write_operations_per_month: 1_000,
            sort_directions: 3,
            num_indexes: 2,
            high_availability: false,
        }
    }

    // --- Validation at boundary (green now) ----------------------------------

    #[test]
    fn compare_all_rejects_invalid_workload() {
        let bad = WorkloadProfile {
            document_count: 0,
            ..valid_workload()
        };
        assert!(compare_all(&bad).is_err());
    }

    #[test]
    fn compare_all_rejects_negative_doc_size() {
        let bad = WorkloadProfile {
            avg_document_size_bytes: -1,
            ..valid_workload()
        };
        assert!(compare_all(&bad).is_err());
    }

    #[test]
    fn compare_all_returns_ok_for_valid_workload() {
        let result = compare_all(&valid_workload());
        assert!(result.is_ok());
    }

    /// Guards the top-level comparison path against overflow-class inputs by requiring a validation error instead of a panic.
    #[test]
    fn compare_all_rejects_extreme_inputs_without_panicking() {
        let extreme = WorkloadProfile {
            document_count: i64::MAX,
            avg_document_size_bytes: i64::MAX,
            search_requests_per_month: i64::MAX,
            write_operations_per_month: 0,
            sort_directions: 10,
            num_indexes: 0,
            high_availability: true,
        };

        let guarded = std::panic::catch_unwind(|| compare_all(&extreme));
        assert!(
            guarded.is_ok(),
            "compare_all should return a validation error, not panic"
        );
        assert!(
            guarded.unwrap().is_err(),
            "extreme workloads must be rejected by validation"
        );
    }

    fn registered_provider_count() -> usize {
        crate::providers::all_metadata().len()
    }

    // --- Comparison contract ---------------------------------------------------

    #[test]
    fn compare_all_returns_one_estimate_per_registered_provider() {
        let result = compare_all(&valid_workload()).unwrap();
        assert_eq!(
            result.estimates.len(),
            registered_provider_count(),
            "Expected one estimate per registered provider"
        );
    }

    /// Locks in the public contract that compare_all returns estimates sorted by ascending monthly cost for deterministic ranking.
    #[test]
    fn compare_all_sorted_cheapest_first() {
        let result = compare_all(&valid_workload()).unwrap();
        let totals: Vec<i64> = result
            .estimates
            .iter()
            .map(|e| e.monthly_total_cents)
            .collect();
        for window in totals.windows(2) {
            assert!(
                window[0] <= window[1],
                "Estimates not sorted cheapest-first: {} > {}",
                window[0],
                window[1]
            );
        }
    }

    #[test]
    fn compare_all_every_estimate_has_line_items() {
        let result = compare_all(&valid_workload()).unwrap();
        for est in &result.estimates {
            assert!(
                !est.line_items.is_empty(),
                "Provider {:?} has no line items",
                est.provider
            );
        }
    }

    #[test]
    fn compare_all_line_item_sums_match_totals() {
        let result = compare_all(&valid_workload()).unwrap();
        for est in &result.estimates {
            let sum: i64 = est.line_items.iter().map(|li| li.amount_cents).sum();
            assert_eq!(
                est.monthly_total_cents, sum,
                "Provider {:?}: total {} != line item sum {}",
                est.provider, est.monthly_total_cents, sum
            );
        }
    }

    #[test]
    fn compare_all_sets_generated_at_timestamp() {
        let before_call = Utc::now();
        let result = compare_all(&valid_workload()).unwrap();
        let after_call = Utc::now();

        assert!(
            result.generated_at >= before_call - Duration::seconds(1),
            "generated_at should reflect current request time"
        );
        assert!(
            result.generated_at <= after_call + Duration::seconds(1),
            "generated_at should not be in the future beyond test tolerance"
        );
    }

    /// Ensures stale_providers and ensure_pricing_freshness stay aligned so gate failures describe the same stale metadata set.
    #[test]
    fn stale_provider_freshness_gate_matches_provider_staleness() {
        let stale = stale_providers(90);
        match ensure_pricing_freshness(90) {
            Ok(()) => assert!(
                stale.is_empty(),
                "freshness gate passed despite stale providers: {:?}",
                stale
                    .iter()
                    .map(|provider| &provider.display_name)
                    .collect::<Vec<_>>()
            ),
            Err(message) => {
                assert!(
                    !stale.is_empty(),
                    "freshness gate failed without any stale providers: {message}"
                );

                for provider in &stale {
                    assert!(
                        message.contains(&provider.display_name),
                        "failure message missing provider name '{}'",
                        provider.display_name
                    );
                    let verification_label = provider.verification_label();
                    assert!(
                        message.contains(&verification_label),
                        "failure message missing verification label '{}'",
                        verification_label
                    );
                }

                panic!("stale provider metadata must be refreshed: {message}");
            }
        }
    }

    #[test]
    fn stale_provider_failure_message_labels_unverified_metadata() {
        let stale = vec![ProviderMetadata {
            id: ProviderId::TypesenseCloud,
            display_name: "Typesense Cloud".to_string(),
            last_verified: None,
            source_urls: vec!["https://example.com/pricing".to_string()],
        }];

        let message = stale_provider_failure_message(90, &stale);
        assert!(
            message.contains("Typesense Cloud (unverified)"),
            "failure message should distinguish unverified metadata: {message}"
        );
    }

    #[test]
    fn stale_provider_failure_message_keeps_verified_dates() {
        let stale = vec![ProviderMetadata {
            id: ProviderId::Algolia,
            display_name: "Algolia".to_string(),
            last_verified: Some(NaiveDate::from_ymd_opt(2026, 3, 15).expect("valid date")),
            source_urls: vec!["https://example.com/pricing".to_string()],
        }];

        let message = stale_provider_failure_message(90, &stale);
        assert!(
            message.contains("Algolia (2026-03-15)"),
            "failure message should keep explicit verification dates: {message}"
        );
    }
}
