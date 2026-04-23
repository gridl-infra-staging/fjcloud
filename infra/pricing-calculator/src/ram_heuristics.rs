//! Stub summary for /Users/stuart/parallel_development/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/infra/pricing-calculator/src/ram_heuristics.rs.

use rust_decimal::Decimal;
use rust_decimal_macros::dec;

use crate::types::WorkloadProfile;

// ============================================================================
// Engine family
// ============================================================================

/// Search engine families with distinct RAM sizing characteristics.
///
/// Covers the 4 resource-based providers (Typesense Cloud, Meilisearch
/// Resource-Based, Elastic Cloud, AWS OpenSearch). Usage-based providers
/// (Algolia, Meilisearch Usage-Based) don't need RAM estimation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchEngine {
    /// Typesense: in-memory search engine. All indexed data must fit in RAM.
    Typesense,
    /// Meilisearch: LMDB-backed engine. Memory-maps the entire database.
    Meilisearch,
    /// Elasticsearch/OpenSearch: JVM-based with Lucene. Heap + OS page cache.
    /// Covers both Elastic Cloud and AWS OpenSearch (same engine architecture).
    Elasticsearch,
}

// ============================================================================
// RAM estimation constants
// ============================================================================

/// Typesense RAM multiplier: 2.0× total document storage.
///
/// Official guidance recommends 2–3× the size of searchable fields.
/// Since `storage_gib()` includes all fields (not just searchable), 2.0×
/// of total data is conservative — it equates to roughly 2.5–4× of
/// searchable data alone.
///
/// Source: <https://typesense.org/docs/guide/system-requirements.html>
const TYPESENSE_RAM_MULTIPLIER: Decimal = dec!(2.0);

/// Meilisearch RAM multiplier: 2.5× total document storage.
///
/// LMDB database files can grow to 25–30× the raw JSON size due to
/// indexing overhead. Official docs say a RAM-to-disk ratio of ~1/3
/// doesn't materially impact performance, and ~1/10 often works.
/// Lower bound: 25 / 10 = 2.5× raw data. This is the minimum viable
/// RAM for acceptable search performance.
///
/// Source: <https://www.meilisearch.com/docs/learn/engine/storage>
const MEILISEARCH_RAM_MULTIPLIER: Decimal = dec!(2.5);

/// Elasticsearch/OpenSearch RAM multiplier: 0.5× total document storage.
///
/// Elasticsearch recommends JVM heap ≤ 50% of node RAM. For search-heavy
/// workloads, heap ≈ 50% of indexed data provides good query performance.
/// The remaining node RAM serves as OS filesystem cache for Lucene segments.
///
/// Source: <https://www.elastic.co/docs/reference/elasticsearch/jvm-settings>
/// See also: <https://docs.aws.amazon.com/opensearch-service/latest/developerguide/bp-instances.html>
const ELASTICSEARCH_RAM_MULTIPLIER: Decimal = dec!(0.5);

/// Minimum RAM for Elasticsearch/OpenSearch: 4.0 GiB.
///
/// The JVM needs a baseline heap to function properly for search operations.
/// Below 4 GiB, garbage collection pauses and query processing bottlenecks
/// degrade performance significantly.
const ELASTICSEARCH_MIN_RAM_GIB: Decimal = dec!(4.0);

// ============================================================================
// RAM estimation
// ============================================================================

/// Estimates the RAM needed (in GiB) for a workload on a given search engine.
///
/// Delegates to [`WorkloadProfile::storage_gib()`] for the raw storage
/// calculation — does NOT re-derive from document count × size.
pub fn estimate_ram_gib(workload: &WorkloadProfile, engine: SearchEngine) -> Decimal {
    let storage = workload.storage_gib();
    match engine {
        SearchEngine::Typesense => storage * TYPESENSE_RAM_MULTIPLIER,
        SearchEngine::Meilisearch => storage * MEILISEARCH_RAM_MULTIPLIER,
        SearchEngine::Elasticsearch => {
            let estimate = storage * ELASTICSEARCH_RAM_MULTIPLIER;
            if estimate < ELASTICSEARCH_MIN_RAM_GIB {
                ELASTICSEARCH_MIN_RAM_GIB
            } else {
                estimate
            }
        }
    }
}

// ============================================================================
// Tier selection
// ============================================================================

/// The result of selecting a tier from a provider's tier table.
#[derive(Debug)]
pub struct TierSelection<'a, T> {
    /// The selected tier entry.
    pub tier: &'a T,
    /// `true` if no tier has enough RAM and the largest was returned as fallback.
    /// Callers should generate a provider-specific assumption string when set.
    pub capped: bool,
}

/// Selects the smallest tier whose RAM ≥ the estimated requirement.
///
/// If no tier is large enough, returns the largest available tier with
/// `capped: true`. Panics if `ram_needed_gib` is negative or if `tiers`
/// is empty (precondition: all Stage 2 tier arrays are compile-time
/// non-empty with test coverage).
///
/// `tiers` must be sorted ascending by RAM (enforced by Stage 2 tests).
/// `ram_accessor` extracts the `ram_gib: u16` field from the tier struct.
pub fn pick_tier<T>(
    ram_needed_gib: Decimal,
    tiers: &[T],
    ram_accessor: impl Fn(&T) -> u16,
) -> TierSelection<'_, T> {
    assert!(
        ram_needed_gib >= Decimal::ZERO,
        "pick_tier requires non-negative RAM"
    );

    assert!(
        !tiers.is_empty(),
        "pick_tier requires a non-empty tier slice"
    );

    for tier in tiers {
        if Decimal::from(ram_accessor(tier)) >= ram_needed_gib {
            return TierSelection {
                tier,
                capped: false,
            };
        }
    }

    // No tier is large enough — return the largest with capped flag.
    TierSelection {
        tier: tiers.last().expect("non-empty checked above"),
        capped: true,
    }
}

// ============================================================================
// Bandwidth estimation
// ============================================================================

/// Assumed results per search page for bandwidth estimation.
///
/// Conservative upper bound: Meilisearch and Algolia default to 20 results
/// per page; Typesense and Elasticsearch default to 10. Using 20 avoids
/// underestimating bandwidth costs for providers that charge for data transfer.
///
/// Sources:
/// - Meilisearch default `limit: 20`: <https://www.meilisearch.com/docs/reference/api/search>
/// - Typesense default `per_page: 10`: <https://typesense.org/docs/29.0/api/search.html>
/// - Elasticsearch default `size: 10`: <https://www.elastic.co/guide/en/elasticsearch/reference/8.19/search-search.html>
const RESULTS_PER_PAGE: i64 = 20;

/// Bytes per decimal gigabyte (for network bandwidth, not storage).
const BYTES_PER_GB: i64 = 1_000_000_000;

/// Estimates monthly outbound bandwidth in GB (decimal) for a workload.
///
/// Formula: `searches_per_month × avg_document_size_bytes × RESULTS_PER_PAGE / BYTES_PER_GB`
///
/// Returns decimal GB (not GiB) because network bandwidth pricing is
/// conventionally quoted in decimal GB. Does NOT call `storage_gib()` —
/// bandwidth depends on per-query response payload, not total stored corpus.
pub fn estimate_monthly_bandwidth_gb(workload: &WorkloadProfile) -> Decimal {
    let document_size_gb =
        Decimal::from(workload.avg_document_size_bytes) / Decimal::from(BYTES_PER_GB);

    Decimal::from(workload.search_requests_per_month)
        .checked_mul(document_size_gb)
        .and_then(|monthly_document_gb| {
            monthly_document_gb.checked_mul(Decimal::from(RESULTS_PER_PAGE))
        })
        .expect("bandwidth estimate exceeds Decimal range")
}

// ============================================================================
// Tests
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::{
        aws_opensearch, elastic_cloud, meilisearch_resource_based, typesense_cloud,
    };
    use crate::types::WorkloadProfile;
    use rust_decimal_macros::dec;

    fn workload(doc_count: i64, avg_bytes: i64) -> WorkloadProfile {
        WorkloadProfile {
            document_count: doc_count,
            avg_document_size_bytes: avg_bytes,
            search_requests_per_month: 50_000,
            write_operations_per_month: 1_000,
            sort_directions: 0,
            num_indexes: 1,
            high_availability: false,
        }
    }

    // --- estimate_ram_gib() --------------------------------------------------

    #[test]
    fn ram_typesense_small_workload() {
        // 100K docs × 2048 B → 2.0× storage_gib
        let w = workload(100_000, 2048);
        let ram = estimate_ram_gib(&w, SearchEngine::Typesense);
        let storage = w.storage_gib();
        assert_eq!(ram, storage * dec!(2.0));
    }

    #[test]
    fn ram_meilisearch_small_workload() {
        // 100K docs × 2048 B → 2.5× storage_gib
        let w = workload(100_000, 2048);
        let ram = estimate_ram_gib(&w, SearchEngine::Meilisearch);
        let storage = w.storage_gib();
        assert_eq!(ram, storage * dec!(2.5));
    }

    #[test]
    fn ram_elasticsearch_small_workload_hits_minimum() {
        // 100K docs × 2048 B ≈ 0.19 GiB → 0.5× ≈ 0.095 GiB < 4.0 GiB minimum
        let w = workload(100_000, 2048);
        let ram = estimate_ram_gib(&w, SearchEngine::Elasticsearch);
        assert_eq!(ram, dec!(4.0));
    }

    #[test]
    fn ram_typesense_medium_workload() {
        // 1M docs × 5120 B → 2.0× storage_gib
        let w = workload(1_000_000, 5120);
        let ram = estimate_ram_gib(&w, SearchEngine::Typesense);
        let storage = w.storage_gib();
        assert_eq!(ram, storage * dec!(2.0));
    }

    #[test]
    fn ram_meilisearch_medium_workload() {
        // 1M docs × 5120 B → 2.5× storage_gib
        let w = workload(1_000_000, 5120);
        let ram = estimate_ram_gib(&w, SearchEngine::Meilisearch);
        let storage = w.storage_gib();
        assert_eq!(ram, storage * dec!(2.5));
    }

    #[test]
    fn ram_elasticsearch_medium_workload_still_at_minimum() {
        // 1M docs × 5120 B ≈ 4.77 GiB → 0.5× ≈ 2.38 GiB < 4.0 GiB minimum
        let w = workload(1_000_000, 5120);
        let ram = estimate_ram_gib(&w, SearchEngine::Elasticsearch);
        assert_eq!(ram, dec!(4.0));
    }

    #[test]
    fn ram_elasticsearch_large_workload_exceeds_minimum() {
        // 10M docs × 5120 B ≈ 47.68 GiB → 0.5× ≈ 23.84 GiB > 4.0 GiB minimum
        let w = workload(10_000_000, 5120);
        let ram = estimate_ram_gib(&w, SearchEngine::Elasticsearch);
        let storage = w.storage_gib();
        assert_eq!(ram, storage * dec!(0.5));
        assert!(ram > dec!(4.0));
    }

    #[test]
    fn ram_delegates_to_storage_gib() {
        // 1 doc × exactly 1 GiB = storage_gib() == 1.0
        let w = workload(1, 1_073_741_824);
        assert_eq!(w.storage_gib(), dec!(1));
        assert_eq!(estimate_ram_gib(&w, SearchEngine::Typesense), dec!(2.0));
        assert_eq!(estimate_ram_gib(&w, SearchEngine::Meilisearch), dec!(2.5));
        // 0.5 GiB < 4.0 GiB minimum → clamped
        assert_eq!(estimate_ram_gib(&w, SearchEngine::Elasticsearch), dec!(4.0));
    }

    // --- pick_tier() ---------------------------------------------------------

    #[derive(Debug)]
    struct FakeTier {
        ram_gib: u16,
    }

    fn fake_tiers() -> Vec<FakeTier> {
        vec![
            FakeTier { ram_gib: 4 },
            FakeTier { ram_gib: 8 },
            FakeTier { ram_gib: 16 },
            FakeTier { ram_gib: 32 },
        ]
    }

    #[test]
    fn pick_tier_exact_fit() {
        let tiers = fake_tiers();
        let sel = pick_tier(dec!(8), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 8);
        assert!(!sel.capped);
    }

    #[test]
    fn pick_tier_between_tiers() {
        let tiers = fake_tiers();
        let sel = pick_tier(dec!(9), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 16);
        assert!(!sel.capped);
    }

    #[test]
    fn pick_tier_fractional_requirement() {
        let tiers = fake_tiers();
        let sel = pick_tier(dec!(7.5), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 8);
        assert!(!sel.capped);
    }

    #[test]
    fn pick_tier_exceeds_largest() {
        let tiers = fake_tiers();
        let sel = pick_tier(dec!(64), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 32);
        assert!(sel.capped);
    }

    #[test]
    fn pick_tier_selects_smallest_fitting() {
        let tiers = fake_tiers();
        let sel = pick_tier(dec!(1), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 4);
        assert!(!sel.capped);
    }

    #[test]
    #[should_panic(expected = "non-empty")]
    fn pick_tier_panics_on_empty_slice() {
        let empty: Vec<FakeTier> = vec![];
        pick_tier(dec!(1), &empty, |t| t.ram_gib);
    }

    #[test]
    #[should_panic(expected = "non-negative RAM")]
    fn pick_tier_panics_on_negative_ram_requirement() {
        let tiers = fake_tiers();
        let _ = pick_tier(dec!(-1), &tiers, |t| t.ram_gib);
    }

    /// Confirms generic tier picking works with real provider tier catalogs, not just synthetic fixtures, so production RAM selection stays valid.
    #[test]
    fn pick_tier_accepts_real_provider_tables() {
        let typesense = pick_tier(dec!(12), typesense_cloud::RAM_TIERS, |tier| tier.ram_gib);
        assert_eq!(typesense.tier.ram_gib, 16);
        assert!(!typesense.capped);

        let meilisearch = pick_tier(
            dec!(3.5),
            meilisearch_resource_based::INSTANCE_TIERS,
            |tier| tier.ram_gib,
        );
        assert_eq!(meilisearch.tier.name, "M");
        assert!(!meilisearch.capped);

        let elastic = pick_tier(dec!(17), elastic_cloud::INSTANCE_TIERS, |tier| tier.ram_gib);
        assert_eq!(elastic.tier.storage_gib, 960);
        assert!(!elastic.capped);

        let opensearch = pick_tier(dec!(96), aws_opensearch::INSTANCE_TYPES, |tier| {
            tier.ram_gib
        });
        assert_eq!(opensearch.tier.name, "r6g.4xlarge.search");
        assert!(!opensearch.capped);
    }

    // --- estimate_monthly_bandwidth_gb() -------------------------------------

    #[test]
    fn bandwidth_standard_workload() {
        // 50K searches × 2048 B × 20 results / 1_000_000_000 = 2.048 GB
        let w = workload(100_000, 2048);
        let bw = estimate_monthly_bandwidth_gb(&w);
        assert_eq!(bw, dec!(2.048));
    }

    #[test]
    fn bandwidth_zero_searches() {
        let w = WorkloadProfile {
            search_requests_per_month: 0,
            ..workload(100_000, 2048)
        };
        let bw = estimate_monthly_bandwidth_gb(&w);
        assert_eq!(bw, dec!(0));
    }

    #[test]
    fn bandwidth_large_workload() {
        // 5M searches × 3000 B × 20 results / 1_000_000_000 = 300 GB
        let w = WorkloadProfile {
            search_requests_per_month: 5_000_000,
            ..workload(10_000_000, 3000)
        };
        let bw = estimate_monthly_bandwidth_gb(&w);
        assert_eq!(bw, dec!(300));
    }

    #[test]
    fn bandwidth_large_representable_workload_does_not_overflow() {
        let w = WorkloadProfile {
            search_requests_per_month: 1_000_000_000,
            ..workload(1, 5_000_000_000_000_000_000)
        };

        let bw = estimate_monthly_bandwidth_gb(&w);

        assert_eq!(
            bw,
            Decimal::from_i128_with_scale(100_000_000_000_000_000_000i128, 0)
        );
    }

    #[test]
    fn ram_elasticsearch_exactly_at_boundary() {
        // storage_gib * 0.5 == 4.0 exactly → should return 4.0 (estimate, not minimum clamp)
        // Requires: storage_gib = 8.0 → doc_count × avg_size = 8 GiB
        // 8 × 1_073_741_824 = 8_589_934_592
        let w = workload(8, 1_073_741_824);
        assert_eq!(w.storage_gib(), dec!(8));
        let ram = estimate_ram_gib(&w, SearchEngine::Elasticsearch);
        assert_eq!(ram, dec!(4.0));
        // Confirm this is the estimate path, not the clamp — the estimate equals the minimum
        assert_eq!(ram, w.storage_gib() * dec!(0.5));
    }

    #[test]
    fn pick_tier_zero_ram() {
        let tiers = fake_tiers();
        let sel = pick_tier(Decimal::ZERO, &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 4);
        assert!(!sel.capped);
    }

    #[test]
    fn pick_tier_single_element_fits() {
        let tiers = vec![FakeTier { ram_gib: 8 }];
        let sel = pick_tier(dec!(4), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 8);
        assert!(!sel.capped);
    }

    #[test]
    fn pick_tier_single_element_capped() {
        let tiers = vec![FakeTier { ram_gib: 8 }];
        let sel = pick_tier(dec!(16), &tiers, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 8);
        assert!(sel.capped);
    }

    /// Protects the transfer-cost model invariant that bandwidth depends on request volume and payload size, not corpus document count.
    #[test]
    fn bandwidth_independent_of_document_count() {
        // Bandwidth depends on search_requests × avg_doc_size × RESULTS_PER_PAGE,
        // NOT on document_count. Changing document_count must not change bandwidth.
        let w1 = WorkloadProfile {
            document_count: 1_000,
            ..workload(1_000, 2048)
        };
        let w2 = WorkloadProfile {
            document_count: 10_000_000,
            ..workload(10_000_000, 2048)
        };
        assert_eq!(
            estimate_monthly_bandwidth_gb(&w1),
            estimate_monthly_bandwidth_gb(&w2),
            "Bandwidth diverged despite identical search volume and doc size"
        );
    }

    // --- estimate_ram_gib → pick_tier integration ----------------------------

    #[test]
    fn estimate_ram_then_pick_tier_typesense() {
        // 1M docs × 5120 B ≈ 4.77 GiB storage → 2.0× = 9.54 GiB RAM → Typesense 16 GiB tier
        let w = workload(1_000_000, 5120);
        let ram = estimate_ram_gib(&w, SearchEngine::Typesense);
        let sel = pick_tier(ram, typesense_cloud::RAM_TIERS, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 16);
        assert!(!sel.capped);
    }

    #[test]
    fn estimate_ram_then_pick_tier_elasticsearch() {
        // 100K docs × 2048 B → ES hits 4.0 GiB minimum → Elastic Cloud 4 GiB tier
        let w = workload(100_000, 2048);
        let ram = estimate_ram_gib(&w, SearchEngine::Elasticsearch);
        assert_eq!(ram, dec!(4.0));
        let sel = pick_tier(ram, elastic_cloud::INSTANCE_TIERS, |t| t.ram_gib);
        assert_eq!(sel.tier.ram_gib, 4);
        assert!(!sel.capped);
    }

    // --- storage-derivation regression coverage ------------------------------

    /// Ensures RAM sizing stays anchored to storage footprint and does not drift with unrelated workload knobs like traffic or HA.
    #[test]
    fn ram_always_anchored_to_storage_gib() {
        // RAM must depend only on doc_count × avg_size (via storage_gib),
        // not on search volume, HA, or other workload parameters.
        let w1 = WorkloadProfile {
            search_requests_per_month: 0,
            high_availability: false,
            ..workload(500_000, 4096)
        };
        let w2 = WorkloadProfile {
            search_requests_per_month: 10_000_000,
            high_availability: true,
            ..workload(500_000, 4096)
        };
        assert_eq!(w1.storage_gib(), w2.storage_gib());
        for engine in [
            SearchEngine::Typesense,
            SearchEngine::Meilisearch,
            SearchEngine::Elasticsearch,
        ] {
            assert_eq!(
                estimate_ram_gib(&w1, engine),
                estimate_ram_gib(&w2, engine),
                "RAM estimate diverged for {:?} despite identical doc count × size",
                engine
            );
        }
    }
}
