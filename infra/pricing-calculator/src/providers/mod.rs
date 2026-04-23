//! Provider registry: registers all pricing calculator providers.
pub mod algolia;
pub mod aws_opensearch;
pub mod elastic_cloud;
pub mod griddle;
pub mod meilisearch_resource_based;
pub mod meilisearch_usage_based;
pub mod typesense_cloud;

use crate::types::{CostLineItem, EstimatedCost, ProviderId, ProviderMetadata, WorkloadProfile};
use chrono::{NaiveDate, Utc};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;

type MetadataFn = fn() -> ProviderMetadata;
type EstimateFn = fn(&WorkloadProfile) -> EstimatedCost;

struct ProviderRegistration {
    metadata: MetadataFn,
    estimate: EstimateFn,
}

fn provider_metadata(
    id: ProviderId,
    display_name: &str,
    last_verified: Option<NaiveDate>,
    source_urls: &[&str],
) -> ProviderMetadata {
    ProviderMetadata {
        id,
        display_name: display_name.to_string(),
        last_verified,
        source_urls: source_urls.iter().map(|url| (*url).to_string()).collect(),
    }
}

fn overage_quantity_1k(total: Decimal, included: i64) -> Decimal {
    let included = Decimal::from(included);
    if total <= included {
        Decimal::ZERO
    } else {
        (total - included) / Decimal::from(1_000)
    }
}

fn overage_amount_1k(total: Decimal, included: i64, unit_price_cents: Decimal) -> (Decimal, i64) {
    let quantity = overage_quantity_1k(total, included);
    let amount_cents = rounded_cents(quantity * unit_price_cents);
    (quantity, amount_cents)
}

fn rounded_cents(amount_cents: Decimal) -> i64 {
    amount_cents
        .round_dp(0)
        .to_i64()
        .expect("rounded cent amount fits in i64")
}

fn sum_line_item_amounts(line_items: &[CostLineItem]) -> i64 {
    line_items
        .iter()
        .map(|line_item| line_item.amount_cents)
        .sum()
}

/// Returns the canonical provider registration order used by both metadata and estimate collection to prevent cross-list drift.
fn provider_registry() -> &'static [ProviderRegistration] {
    &[
        ProviderRegistration {
            metadata: algolia::metadata,
            estimate: algolia::estimate,
        },
        ProviderRegistration {
            metadata: griddle::metadata,
            estimate: griddle::estimate,
        },
        ProviderRegistration {
            metadata: meilisearch_usage_based::metadata,
            estimate: meilisearch_usage_based::estimate,
        },
        ProviderRegistration {
            metadata: meilisearch_resource_based::metadata,
            estimate: meilisearch_resource_based::estimate,
        },
        ProviderRegistration {
            metadata: typesense_cloud::metadata,
            estimate: typesense_cloud::estimate,
        },
        ProviderRegistration {
            metadata: elastic_cloud::metadata,
            estimate: elastic_cloud::estimate,
        },
        ProviderRegistration {
            metadata: aws_opensearch::metadata,
            estimate: aws_opensearch::estimate,
        },
    ]
}

/// Returns metadata for all registered providers.
///
/// The provider order is the canonical registry order. Both this function and
/// `all_estimates()` derive from the same module list to prevent drift.
pub fn all_metadata() -> Vec<ProviderMetadata> {
    provider_registry()
        .iter()
        .map(|registration| (registration.metadata)())
        .collect()
}

/// Returns cost estimates from all registered providers.
///
/// All 7 providers are wired (6 competitors + Flapjack Cloud). Uses the same module list as
/// `all_metadata()` to prevent drift.
pub fn all_estimates(workload: &WorkloadProfile) -> Vec<EstimatedCost> {
    provider_registry()
        .iter()
        .map(|registration| (registration.estimate)(workload))
        .collect()
}

/// Returns providers older than the freshness threshold using last_verified dates; providers without dates are excluded from stale output.
fn stale_providers_from_metadata(
    metadata: &[ProviderMetadata],
    as_of: NaiveDate,
    threshold_days: i64,
) -> Vec<ProviderMetadata> {
    let effective_threshold_days = threshold_days.max(0);

    metadata
        .iter()
        .filter(|provider| {
            provider
                .last_verified
                .is_some_and(|date| (as_of - date).num_days() > effective_threshold_days)
        })
        .cloned()
        .collect()
}

/// Returns providers whose pricing metadata is older than `threshold_days`.
///
/// Staleness is derived solely from `all_metadata()` and `last_verified`,
/// preserving registry order in the resulting list.
pub fn stale_providers(threshold_days: i64) -> Vec<ProviderMetadata> {
    let as_of = Utc::now().date_naive();
    let metadata = all_metadata();
    stale_providers_from_metadata(&metadata, as_of, threshold_days)
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::types::{ProviderId, ProviderMetadata};
    use chrono::NaiveDate;
    use std::collections::HashSet;

    // --- Canonical provider expectations (single source of truth) -------------

    /// The expected registry order. Every coverage, order, and count test in this
    /// module derives its expectations from this one list. When a provider is
    /// added or reordered, update this single constant.
    const CANONICAL_PROVIDER_ORDER: &[ProviderId] = &[
        ProviderId::Algolia,
        ProviderId::Griddle,
        ProviderId::MeilisearchUsageBased,
        ProviderId::MeilisearchResourceBased,
        ProviderId::TypesenseCloud,
        ProviderId::ElasticCloud,
        ProviderId::AwsOpenSearch,
    ];

    /// Expected verification status per provider. Verified means the provider
    /// module has a `last_verified` date backed by source-checked pricing inputs.
    fn expected_verified(id: ProviderId) -> bool {
        matches!(
            id,
            ProviderId::Algolia
                | ProviderId::MeilisearchUsageBased
                | ProviderId::MeilisearchResourceBased
        )
    }

    // --- all_metadata() contract tests ----------------------------------------

    #[test]
    fn all_metadata_returns_one_entry_per_registered_provider() {
        let metadata = all_metadata();
        assert_eq!(
            metadata.len(),
            provider_registry().len(),
            "Expected one metadata entry per provider registration"
        );
    }

    #[test]
    fn all_metadata_has_unique_provider_ids() {
        let metadata = all_metadata();
        let ids: HashSet<ProviderId> = metadata.iter().map(|m| m.id).collect();
        assert_eq!(
            ids.len(),
            metadata.len(),
            "Provider IDs are not unique: {:?}",
            metadata.iter().map(|m| m.id).collect::<Vec<_>>()
        );
    }

    #[test]
    fn all_metadata_every_entry_has_non_empty_display_name() {
        for m in all_metadata() {
            assert!(
                !m.display_name.is_empty(),
                "Provider {:?} has empty display_name",
                m.id
            );
        }
    }

    /// Ensures every provider exposes at least one non-empty source URL so pricing assumptions remain auditable.
    #[test]
    fn all_metadata_every_entry_has_non_empty_source_urls() {
        for m in all_metadata() {
            assert!(
                !m.source_urls.is_empty(),
                "Provider {:?} has no source_urls",
                m.id
            );
            for url in &m.source_urls {
                assert!(
                    !url.is_empty(),
                    "Provider {:?} has an empty source URL",
                    m.id
                );
            }
        }
    }

    #[test]
    fn all_metadata_covers_full_provider_id_set() {
        let expected: HashSet<ProviderId> = CANONICAL_PROVIDER_ORDER.iter().copied().collect();
        let actual: HashSet<ProviderId> = all_metadata().iter().map(|m| m.id).collect();
        assert_eq!(
            expected, actual,
            "all_metadata() does not cover the full ProviderId set"
        );
    }

    #[test]
    fn all_metadata_preserves_registry_order() {
        let ids: Vec<ProviderId> = all_metadata().iter().map(|m| m.id).collect();
        assert_eq!(
            ids, CANONICAL_PROVIDER_ORDER,
            "Registry order does not match the declared order in providers/mod.rs"
        );
    }

    #[test]
    fn provider_registry_contains_all_provider_variants() {
        assert_eq!(provider_registry().len(), CANONICAL_PROVIDER_ORDER.len());
    }

    // --- all_estimates() contract tests ----------------------------------------

    fn test_workload() -> WorkloadProfile {
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

    #[test]
    fn all_estimates_returns_one_estimate_per_registered_provider() {
        let estimates = all_estimates(&test_workload());
        assert_eq!(
            estimates.len(),
            provider_registry().len(),
            "Expected one estimate per provider registration"
        );
    }

    #[test]
    fn all_estimates_covers_all_provider_ids() {
        let actual: HashSet<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|e| e.provider)
            .collect();
        let expected: HashSet<ProviderId> = CANONICAL_PROVIDER_ORDER.iter().copied().collect();
        assert_eq!(expected, actual);
    }

    #[test]
    fn all_estimates_preserves_registry_order() {
        let ids: Vec<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|e| e.provider)
            .collect();
        assert_eq!(ids, CANONICAL_PROVIDER_ORDER);
    }

    /// Verifies every estimate carries explainability fields (assumptions and line items) needed for human-auditable cost output.
    #[test]
    fn all_estimates_include_transparency_fields() {
        let estimates = all_estimates(&test_workload());
        assert_eq!(
            estimates.len(),
            provider_registry().len(),
            "Expected transparency checks over all registered providers"
        );
        for estimate in estimates {
            assert!(
                !estimate.line_items.is_empty(),
                "{:?} has no line items",
                estimate.provider
            );
            assert!(
                !estimate.assumptions.is_empty(),
                "{:?} has no assumptions",
                estimate.provider
            );
            assert!(
                estimate
                    .plan_name
                    .as_deref()
                    .is_some_and(|name| !name.trim().is_empty()),
                "{:?} has no plan_name",
                estimate.provider
            );

            let line_item_sum = sum_line_item_amounts(&estimate.line_items);
            assert_eq!(
                estimate.monthly_total_cents, line_item_sum,
                "{:?} total != line_item sum",
                estimate.provider
            );
        }
    }

    #[test]
    fn all_metadata_marks_only_fully_reverified_providers_as_verified() {
        let actual: Vec<(ProviderId, bool)> = all_metadata()
            .iter()
            .map(|m| (m.id, m.is_verified()))
            .collect();
        let expected: Vec<(ProviderId, bool)> = CANONICAL_PROVIDER_ORDER
            .iter()
            .map(|&id| (id, expected_verified(id)))
            .collect();
        assert_eq!(
            actual, expected,
            "Only providers with source-backed pricing inputs should expose a verification date"
        );
    }

    fn metadata_fixture(
        id: ProviderId,
        display_name: &str,
        last_verified: Option<NaiveDate>,
    ) -> ProviderMetadata {
        ProviderMetadata {
            id,
            display_name: display_name.to_string(),
            last_verified,
            source_urls: vec!["https://example.com/pricing".to_string()],
        }
    }

    /// Locks boundary behavior: a provider verified exactly threshold_days ago is still considered fresh.
    #[test]
    fn stale_providers_exact_threshold_is_fresh() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let threshold_days = 90;
        let exactly_threshold_old = NaiveDate::from_ymd_opt(2025, 12, 16).expect("valid date");

        let metadata = vec![metadata_fixture(
            ProviderId::Algolia,
            "Algolia",
            Some(exactly_threshold_old),
        )];

        let stale = stale_providers_from_metadata(&metadata, as_of, threshold_days);
        assert!(
            stale.is_empty(),
            "Provider exactly at threshold should remain fresh"
        );
    }

    /// Verifies providers older than threshold_days are reported stale so freshness gating fails only for truly out-of-date data.
    #[test]
    fn stale_providers_over_threshold_is_reported() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let threshold_days = 90;
        let stale_date = NaiveDate::from_ymd_opt(2025, 12, 15).expect("valid date");

        let metadata = vec![metadata_fixture(
            ProviderId::Algolia,
            "Algolia",
            Some(stale_date),
        )];

        let stale = stale_providers_from_metadata(&metadata, as_of, threshold_days);
        assert_eq!(
            stale.len(),
            1,
            "Provider older than threshold should be stale"
        );
        assert_eq!(stale[0].id, ProviderId::Algolia);
    }

    /// Ensures stale-provider output preserves input order so downstream messaging remains stable and deterministic.
    #[test]
    fn stale_providers_preserve_registry_order() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let threshold_days = 90;

        let metadata = vec![
            metadata_fixture(
                ProviderId::Algolia,
                "Algolia",
                Some(NaiveDate::from_ymd_opt(2026, 3, 1).expect("valid date")),
            ),
            metadata_fixture(
                ProviderId::MeilisearchUsageBased,
                "Meilisearch Cloud (Usage-Based)",
                Some(NaiveDate::from_ymd_opt(2025, 10, 1).expect("valid date")),
            ),
            metadata_fixture(
                ProviderId::MeilisearchResourceBased,
                "Meilisearch Cloud (Resource-Based)",
                Some(NaiveDate::from_ymd_opt(2025, 9, 1).expect("valid date")),
            ),
            metadata_fixture(
                ProviderId::TypesenseCloud,
                "Typesense Cloud",
                Some(NaiveDate::from_ymd_opt(2026, 2, 1).expect("valid date")),
            ),
        ];

        let stale = stale_providers_from_metadata(&metadata, as_of, threshold_days);
        let stale_ids: Vec<ProviderId> = stale.iter().map(|provider| provider.id).collect();
        assert_eq!(
            stale_ids,
            vec![
                ProviderId::MeilisearchUsageBased,
                ProviderId::MeilisearchResourceBased,
            ],
            "Stale providers should preserve source metadata order"
        );
    }

    /// Confirms undated metadata entries are not auto-marked stale, matching the policy that only explicitly dated entries can age out.
    #[test]
    fn stale_providers_exclude_unverified_metadata_without_dates() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let threshold_days = 90;

        let metadata = vec![
            metadata_fixture(
                ProviderId::Algolia,
                "Algolia",
                Some(NaiveDate::from_ymd_opt(2026, 3, 1).expect("valid date")),
            ),
            metadata_fixture(ProviderId::TypesenseCloud, "Typesense Cloud", None),
        ];

        let stale = stale_providers_from_metadata(&metadata, as_of, threshold_days);
        let stale_ids: Vec<ProviderId> = stale.iter().map(|provider| provider.id).collect();
        assert_eq!(
            stale_ids,
            Vec::<ProviderId>::new(),
            "Freshness aging only applies to providers with explicit verification dates"
        );
    }
}
