//! Provider registry: registers all pricing calculator providers.
pub mod algolia;
pub mod aws_opensearch;
pub mod elastic_cloud;
pub mod griddle;
pub mod meilisearch_resource_based;
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

/// Explains why a provider is included in freshness-gate output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderFreshnessReason {
    NeverVerified,
    StaleSince(NaiveDate),
}

impl ProviderFreshnessReason {
    pub fn label(self) -> String {
        match self {
            Self::NeverVerified => "never-verified".to_string(),
            Self::StaleSince(date) => format!("stale-since-{date}"),
        }
    }
}

/// A provider whose metadata needs source verification attention.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderFreshnessIssue {
    pub provider: ProviderMetadata,
    pub reason: ProviderFreshnessReason,
}

impl ProviderFreshnessIssue {
    pub fn reason_label(&self) -> String {
        self.reason.label()
    }
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

/// Returns whether a provider is *published* in the compared estimate output.
///
/// Publication is **derived**, never stored: a provider appears in `all_estimates()`
/// exactly when its pricing metadata carries a source-backed verification date. This
/// delegates to `ProviderMetadata::is_verified()` (i.e. `last_verified.is_some()`) so the
/// single meaning of "published" stays canonical for this crate and for Stage 3's API/UI
/// `withheld_providers` contract. There is deliberately no `published` field on
/// `ProviderMetadata` — a stored flag could drift from `last_verified`.
pub fn is_published(metadata: &ProviderMetadata) -> bool {
    metadata.is_verified()
}

/// Returns cost estimates from every *published* provider.
///
/// All 6 providers are registered (5 competitors + Flapjack Cloud), but only those whose
/// metadata is published (`is_published`) appear here — withholding is a publication
/// decision at the estimate seam, not deletion from the registry. `all_metadata()` stays
/// the full denominator. Uses the same module list as `all_metadata()` to prevent drift.
pub fn all_estimates(workload: &WorkloadProfile) -> Vec<EstimatedCost> {
    provider_registry()
        .iter()
        .filter(|registration| is_published(&(registration.metadata)()))
        .map(|registration| (registration.estimate)(workload))
        .collect()
}

/// Returns providers that are either older than the freshness threshold or have never been verified.
pub(crate) fn stale_providers_from_metadata(
    metadata: &[ProviderMetadata],
    as_of: NaiveDate,
    threshold_days: i64,
) -> Vec<ProviderFreshnessIssue> {
    let effective_threshold_days = threshold_days.max(0);

    metadata
        .iter()
        .filter_map(|provider| {
            let reason = match provider.last_verified {
                Some(date) if (as_of - date).num_days() > effective_threshold_days => {
                    ProviderFreshnessReason::StaleSince(date)
                }
                Some(_) => return None,
                None => ProviderFreshnessReason::NeverVerified,
            };

            Some(ProviderFreshnessIssue {
                provider: provider.clone(),
                reason,
            })
        })
        .collect()
}

/// Returns providers whose pricing metadata is older than `threshold_days` or
/// has never been verified.
///
/// Staleness is derived solely from `all_metadata()` and `last_verified`,
/// preserving registry order in the resulting list.
pub fn stale_providers_as_of(as_of: NaiveDate, threshold_days: i64) -> Vec<ProviderFreshnessIssue> {
    let metadata = all_metadata();
    stale_providers_from_metadata(&metadata, as_of, threshold_days)
}

/// Returns providers whose pricing metadata is too old or unverified as of the current UTC date.
pub fn stale_providers(threshold_days: i64) -> Vec<ProviderFreshnessIssue> {
    stale_providers_as_of(Utc::now().date_naive(), threshold_days)
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
    ///
    /// `MeilisearchUsageBased` was retired 2026-07-07 per the Stage 1 evidence
    /// bundle `docs/runbooks/evidence/competitor-pricing/20260707T172320Z_meilisearch/`:
    /// the public pricing page no longer exposes a machine-readable rate card
    /// for the modeled Build/Pro plans, so the provider is removed from compare
    /// output entirely rather than left publishing stale March-2026 assumptions.
    const CANONICAL_PROVIDER_ORDER: &[ProviderId] = &[
        ProviderId::Algolia,
        ProviderId::Griddle,
        ProviderId::MeilisearchResourceBased,
        ProviderId::TypesenseCloud,
        ProviderId::ElasticCloud,
        ProviderId::AwsOpenSearch,
    ];

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

    /// The published id set, in registry order, derived from the same predicate the
    /// production seam uses. Every published-set expectation below derives from this
    /// helper rather than a hardcoded provider list, so it tracks metadata changes.
    fn published_provider_ids() -> Vec<ProviderId> {
        all_metadata()
            .into_iter()
            .filter(is_published)
            .map(|metadata| metadata.id)
            .collect()
    }

    /// The unpublished id set (never-verified metadata), derived from the same predicate.
    fn unpublished_provider_ids() -> Vec<ProviderId> {
        all_metadata()
            .into_iter()
            .filter(|metadata| !is_published(metadata))
            .map(|metadata| metadata.id)
            .collect()
    }

    // --- Publication rule at the estimate seam ---------------------------------

    /// (a) A provider whose `last_verified` is `None` is withheld from `all_estimates()`.
    #[test]
    fn all_estimates_omits_unpublished_providers() {
        let unpublished = unpublished_provider_ids();
        assert!(
            !unpublished.is_empty(),
            "guard is only meaningful when at least one provider is unpublished"
        );

        let estimate_ids: HashSet<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|estimate| estimate.provider)
            .collect();
        for id in unpublished {
            assert!(
                !estimate_ids.contains(&id),
                "unpublished provider {:?} must be withheld from all_estimates()",
                id
            );
        }
    }

    /// (b) The withheld providers still appear in `all_metadata()` — the registry stays
    /// the full denominator; withholding is a publication decision, not deletion.
    #[test]
    fn all_metadata_retains_unpublished_providers() {
        let unpublished = unpublished_provider_ids();
        assert!(
            !unpublished.is_empty(),
            "guard is only meaningful when at least one provider is unpublished"
        );

        let metadata_ids: HashSet<ProviderId> = all_metadata().iter().map(|m| m.id).collect();
        for id in unpublished {
            assert!(
                metadata_ids.contains(&id),
                "registry denominator must retain unpublished provider {:?}",
                id
            );
        }
    }

    /// `all_estimates()` publishes exactly the published id set, in registry order.
    #[test]
    fn all_estimates_publishes_exactly_the_published_set() {
        let estimate_ids: Vec<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|estimate| estimate.provider)
            .collect();
        assert_eq!(
            estimate_ids,
            published_provider_ids(),
            "all_estimates() must publish exactly the published set in registry order"
        );
    }

    #[test]
    fn all_estimates_returns_one_estimate_per_registered_provider() {
        let estimates = all_estimates(&test_workload());
        assert_eq!(
            estimates.len(),
            published_provider_ids().len(),
            "Expected one estimate per published provider"
        );
    }

    #[test]
    fn all_estimates_covers_all_provider_ids() {
        let actual: HashSet<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|e| e.provider)
            .collect();
        let expected: HashSet<ProviderId> = published_provider_ids().into_iter().collect();
        assert_eq!(expected, actual);
    }

    #[test]
    fn all_estimates_preserves_registry_order() {
        let ids: Vec<ProviderId> = all_estimates(&test_workload())
            .iter()
            .map(|e| e.provider)
            .collect();
        assert_eq!(ids, published_provider_ids());
    }

    /// Verifies every estimate carries explainability fields (assumptions and line items) needed for human-auditable cost output.
    #[test]
    fn all_estimates_include_transparency_fields() {
        let estimates = all_estimates(&test_workload());
        assert_eq!(
            estimates.len(),
            published_provider_ids().len(),
            "Expected transparency checks over all published providers"
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

    const STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE: &[(ProviderId, &str)] = &[
        (
            ProviderId::ElasticCloud,
            "docs/audits/pricing-verification/20260806T151052Z/: source gap: hosted pricing page confirms the $99/month 120 GB 2-zone Standard baseline but does not expose the modeled RAM-indexed tier ladder, the shared storage-to-RAM multiplier, or ELASTICSEARCH_MIN_RAM_GIB",
        ),
        (
            ProviderId::AwsOpenSearch,
            "docs/audits/pricing-verification/20260806T151052Z/: source gap: AWS offer files back every price, but fetched sources do not back DEDICATED_MASTER_INSTANCE_NAME, six of seven instance RAM values, the shared storage-to-RAM multiplier, or ELASTICSEARCH_MIN_RAM_GIB; RESULTS_PER_PAGE also differs from the documented OpenSearch default",
        ),
    ];

    #[test]
    fn undated_third_party_metadata_is_reported_as_never_verified() {
        for (id, reason) in STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE {
            assert!(
                !reason.trim().is_empty(),
                "Stage 2 evidence reason must be non-empty for {:?}",
                id
            );
        }

        let metadata = all_metadata();
        let competitors: Vec<&ProviderMetadata> = metadata
            .iter()
            // Flapjack Cloud owns its pricing inputs; third-party metadata must be source verifiable.
            .filter(|provider| provider.id != ProviderId::Griddle)
            .collect();
        let provider_count = competitors.len();
        let unverified: Vec<&ProviderMetadata> = competitors
            .iter()
            .copied()
            .filter(|provider| !provider.is_verified())
            .collect();
        let never_verified: HashSet<ProviderId> =
            stale_providers_from_metadata(&metadata, NaiveDate::MAX, 90)
                .iter()
                .filter(|issue| issue.reason == ProviderFreshnessReason::NeverVerified)
                .map(|issue| issue.provider.id)
                .collect();

        assert!(
            provider_count > 0,
            "competitor verification guard must inspect at least one provider"
        );
        assert_eq!(provider_count, provider_registry().len() - 1);
        let expected_unverified: Vec<ProviderId> = STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE
            .iter()
            .map(|(id, _)| *id)
            .collect();
        assert_eq!(
            unverified
                .iter()
                .map(|provider| provider.id)
                .collect::<Vec<_>>(),
            expected_unverified
        );
        for provider in unverified {
            assert!(
                never_verified.contains(&provider.id),
                "undated third-party provider {:?} missing never-verified freshness issue",
                provider.id
            );
        }
    }

    #[test]
    fn unverified_competitor_evidence_reasons_record_observed_stage_2_status() {
        for (id, reason) in STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE {
            assert!(
                !reason.contains("pending live source verification in Stage 2"),
                "Stage 2 evidence reason for {:?} must record the observed Stage 2 obstacle",
                id
            );
            assert!(
                reason.contains("docs/audits/pricing-verification/20260806T151052Z/"),
                "Stage 2 evidence reason for {:?} must point to the current evidence bundle",
                id
            );
            assert!(
                reason.contains("source gap"),
                "Stage 2 evidence reason for {:?} must name the current source gap",
                id
            );
        }
    }

    #[test]
    fn pricing_audit_runbook_names_current_competitor_evidence_owners() {
        const PRICING_AUDIT_RUNBOOK: &str =
            include_str!("../../../../docs/runbooks/pricing-audit.md");
        const STALE_OWNER_NAMES: &[&str] = &[
            "TEMPORARILY_UNVERIFIED_COMPETITORS",
            "all_competitor_metadata_is_verified_or_explicitly_allowlisted()",
            "temporary_competitor_allowlist_reasons_record_observed_stage_2_status()",
        ];
        const CURRENT_OWNER_NAMES: &[&str] = &[
            "STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE",
            "undated_third_party_metadata_is_reported_as_never_verified()",
            "unverified_competitor_evidence_reasons_record_observed_stage_2_status()",
        ];
        const CURRENT_FRESHNESS_BEHAVIOR: &[&str] = &[
            "dated providers older than 90 days",
            "undated providers as `NeverVerified`",
            "`ensure_pricing_freshness(90)` returns an error when either kind is present",
        ];
        const STALE_FRESHNESS_CLAIMS: &[&str] =
            &["returns providers with explicit verification dates older than 90 days"];

        let _current_owner_tests: [fn(); 2] = [
            undated_third_party_metadata_is_reported_as_never_verified,
            unverified_competitor_evidence_reasons_record_observed_stage_2_status,
        ];
        assert!(!STAGE_2_UNVERIFIED_COMPETITOR_EVIDENCE.is_empty());

        for stale_owner_name in STALE_OWNER_NAMES {
            assert!(
                !PRICING_AUDIT_RUNBOOK.contains(stale_owner_name),
                "pricing-audit runbook still names stale identifier `{stale_owner_name}`"
            );
        }
        for stale_freshness_claim in STALE_FRESHNESS_CLAIMS {
            assert!(
                !PRICING_AUDIT_RUNBOOK.contains(stale_freshness_claim),
                "pricing-audit runbook still states dated-only freshness behavior `{stale_freshness_claim}`"
            );
        }
        for current_owner_name in CURRENT_OWNER_NAMES {
            assert!(
                PRICING_AUDIT_RUNBOOK.contains(current_owner_name),
                "pricing-audit runbook must name current owner `{current_owner_name}`"
            );
        }
        for current_behavior in CURRENT_FRESHNESS_BEHAVIOR {
            assert!(
                PRICING_AUDIT_RUNBOOK.contains(current_behavior),
                "pricing-audit runbook must describe freshness behavior `{current_behavior}`"
            );
        }
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

    /// Verifies freshness issues explain both dated stale metadata and metadata that has never been verified.
    #[test]
    fn stale_providers_over_threshold_and_never_verified_are_reported() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let threshold_days = 90;
        let stale_date = NaiveDate::from_ymd_opt(2025, 12, 15).expect("valid date");

        let metadata = vec![
            metadata_fixture(ProviderId::Algolia, "Algolia", Some(stale_date)),
            metadata_fixture(ProviderId::TypesenseCloud, "Typesense Cloud", None),
        ];

        let stale = stale_providers_from_metadata(&metadata, as_of, threshold_days);
        assert_eq!(
            stale.len(),
            2,
            "Stale dated and never-verified providers should be reported"
        );
        assert_eq!(stale[0].provider.id, ProviderId::Algolia);
        assert_eq!(stale[0].reason_label(), "stale-since-2025-12-15");
        assert_eq!(stale[1].provider.id, ProviderId::TypesenseCloud);
        assert_eq!(stale[1].reason_label(), "never-verified");
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
        let stale_ids: Vec<ProviderId> = stale.iter().map(|issue| issue.provider.id).collect();
        assert_eq!(
            stale_ids,
            vec![
                ProviderId::MeilisearchUsageBased,
                ProviderId::MeilisearchResourceBased,
            ],
            "Stale providers should preserve source metadata order"
        );
    }

    /// Confirms undated metadata entries are reported as never verified instead of disappearing from freshness output.
    #[test]
    fn stale_providers_report_unverified_metadata_without_dates() {
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
        let stale_ids: Vec<ProviderId> = stale.iter().map(|issue| issue.provider.id).collect();
        assert_eq!(
            stale_ids,
            vec![ProviderId::TypesenseCloud],
            "Undated providers must be reported as never verified"
        );
        assert_eq!(stale[0].reason_label(), "never-verified");
    }

    #[test]
    fn stale_providers_include_unverified_third_party_metadata_without_dates() {
        let as_of = NaiveDate::from_ymd_opt(2026, 3, 16).expect("valid test date");
        let metadata = vec![metadata_fixture(
            ProviderId::TypesenseCloud,
            "Typesense Cloud",
            None,
        )];

        let stale = stale_providers_from_metadata(&metadata, as_of, 90);
        let stale_ids: Vec<ProviderId> = stale.iter().map(|issue| issue.provider.id).collect();

        assert!(
            stale_ids.contains(&ProviderId::TypesenseCloud),
            "unverified third-party metadata must be visible to the freshness selector; stale IDs: {:?}",
            stale_ids
        );
    }
}
