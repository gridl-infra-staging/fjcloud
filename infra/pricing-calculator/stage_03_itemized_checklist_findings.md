# Stage 3 Itemized Checklist Findings (Research Deliverables)

Date: 2026-03-15
Scope: Stage 3 checklist topics for shared heuristics module (`ram_heuristics.rs`)

## Evidence Base
- Internal code evidence from `infra/pricing-calculator/src/{types.rs,lib.rs,providers/*.rs}`.
- Prior Stage 3 findings: `infra/pricing-calculator/stage_03_research_findings.md`.
- External primary sources listed in [Sources](#sources).

## R1
Checklist item: Re-read `types.rs` + provider modules to inventory tier tables, storage constants, calculator seams.

Deliverable: Inventory confirmation and seam map.
- All resource-based providers expose ascending RAM tiers and compatible RAM field names:
  - Meilisearch `INSTANCE_TIERS[*].ram_gib: u16` ([infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:30](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:30), [37](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:37), sorted test [112](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:112)).
  - Typesense `RAM_TIERS[*].ram_gib: u16` ([infra/pricing-calculator/src/providers/typesense_cloud.rs:26](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/typesense_cloud.rs:26), [34](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/typesense_cloud.rs:34), sorted test [92](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/typesense_cloud.rs:92)).
  - Elastic `INSTANCE_TIERS[*].ram_gib: u16` ([infra/pricing-calculator/src/providers/elastic_cloud.rs:25](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/elastic_cloud.rs:25), [34](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/elastic_cloud.rs:34), sorted test [86](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/elastic_cloud.rs:86)).
  - AWS OpenSearch `INSTANCE_TYPES[*].ram_gib: u16` ([infra/pricing-calculator/src/providers/aws_opensearch.rs:29](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/aws_opensearch.rs:29), [37](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/aws_opensearch.rs:37), sorted test [112](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/aws_opensearch.rs:112)).
- Storage and bandwidth constants exist only in providers today, not in shared helpers yet:
  - Meili storage/bandwidth constants: [71](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:71), [80](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:80).
  - AWS storage constant: [83](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/aws_opensearch.rs:83).
Open questions:
- None blocking; seam is consistent for Stage 3 helper extraction.

## R2
Checklist item: Decide public API in `ram_heuristics.rs` (`estimate_ram_gib`, `pick_tier`, numeric type for `estimate_monthly_bandwidth_gb`).

Deliverable: API contract recommendation.
- `estimate_ram_gib(workload, engine: SearchEngine) -> Decimal` where `SearchEngine = {Typesense, Meilisearch, Elasticsearch}`.
- `pick_tier<T>(ram_needed_gib: Decimal, tiers: &[T], ram_accessor: impl Fn(&T)->u16) -> TierSelection<'_, T>`.
- `estimate_monthly_bandwidth_gb(workload) -> Decimal`.
- `Decimal` matches existing cost types (`CostLineItem.quantity`, `unit_price_cents`) and avoids premature float rounding ([infra/pricing-calculator/src/types.rs:147](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/types.rs:147), [151](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/types.rs:151)).
Open questions:
- Whether to split `Elasticsearch` and `OpenSearch` into separate enum variants for future divergence (not needed for Stage 3).

## R3
Checklist item: Choose lightest genericity for `pick_tier()` (closure/accessor preferred over trait unless needed).

Deliverable: Genericity decision with proof.
- Closure-based accessor works unchanged across all four tier slices because each has `ram_gib: u16` and is sorted ascending (R1 evidence).
- Trait-based approach would add cross-module boilerplate with no extra safety in Stage 3.
Open questions:
- None for Stage 3; revisit only if provider tier structs diverge from `ram_gib`.

## R4
Checklist item: Confirm only `lib.rs` export changes now (`pub mod ram_heuristics;`) while `providers/mod.rs` stays unchanged.

Deliverable: Export boundary audit.
- `lib.rs` currently exports only `providers` and `types` ([infra/pricing-calculator/src/lib.rs:1](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/lib.rs:1)).
- `providers/mod.rs` is Stage 2 registry plumbing and should not be touched for Stage 3 helper introduction ([infra/pricing-calculator/src/providers/mod.rs:1](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/mod.rs:1), [63](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/mod.rs:63)).
Open questions:
- None.

## B1
Checklist item: Add failing inline tests for `estimate_ram_gib()` (small/medium/large workloads across families).

Deliverable: Test matrix with expected values.
- Workload A: `100_000 docs * 2048 B` -> `storage_gib = 0.19073486328125`.
  - Typesense (2.0x): `0.3814697265625`.
  - Meilisearch (2.5x): `0.476837158203125`.
  - Elasticsearch/OpenSearch (`max(0.5x, 4)`): `4`.
- Workload B: `1_000_000 docs * 5120 B` -> `storage_gib = 4.76837158203125`.
  - Typesense: `9.5367431640625`.
  - Meilisearch: `11.920928955078125`.
  - Elasticsearch/OpenSearch: `4` (minimum still binds).
- Workload C: `10_000_000 docs * 5120 B` -> `storage_gib = 47.6837158203125`.
  - Elasticsearch/OpenSearch: `23.84185791015625` (ratio now above 4 GiB floor).
Evidence anchor: `storage_gib()` should remain single source ([infra/pricing-calculator/src/types.rs:86](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/types.rs:86)).
Open questions:
- Do we want explicit rounding in tests, or exact-decimal assertions via `Decimal` constants? Recommendation: exact-decimal assertions.

## B2
Checklist item: Implement constants + `estimate_ram_gib(workload, engine)` using `WorkloadProfile::storage_gib()`.

Deliverable: Implementation design (no code in this session).
- Required constants:
  - `TYPESENSE_RAM_MULTIPLIER = dec!(2.0)`.
  - `MEILISEARCH_RAM_MULTIPLIER = dec!(2.5)`.
  - `ELASTICSEARCH_RAM_MULTIPLIER = dec!(0.5)`.
  - `ELASTICSEARCH_MIN_RAM_GIB = dec!(4)`.
- Logic must call `workload.storage_gib()` exactly once and derive RAM from that value.
- Avoid second raw-byte conversion path to preserve Stage 1 single-source rule.
External rationale:
- Typesense keyword-search RAM guidance: 2x-3x searchable data [S1].
- Meilisearch memory behavior and viable RAM-to-disk guidance [S2].
- Elasticsearch heap + filesystem cache guidance [S3].
- AWS OpenSearch initial sizing guidance [S4].
Open questions:
- Should Meilisearch multiplier be configurable in future for perf vs cost bias? Not required in Stage 3.

## B3
Checklist item: Add doc comments for each multiplier/sizing rule with source/rationale.

Deliverable: Doc-comment template and source mapping.
- Each constant should include one concise rationale line + source ref URL.
- Suggested structure:
  - What the multiplier is.
  - Why chosen (cost-conservative vs performance-conservative).
  - Link(s) to source docs.
- External sources to cite directly in code comments: [S1], [S2], [S3], [S4].
Open questions:
- No blocker; comment style only.

## B4
Checklist item: Validate `cargo test -p pricing-calculator -- ram_heuristics` and `cargo check -p pricing-calculator`.

Deliverable: Validation plan.
- Run both commands after helper + tests exist.
- Capture results in shared testing log with SHA and exact command.
- No cache-hit expected now because command target does not exist yet in current HEAD.
Open questions:
- None.

## T1
Checklist item: Add failing tests for `pick_tier()` (exact fit, next-tier, fractional, exceed-largest).

Deliverable: Test-case design.
- Exact fit: need `8` with tiers `[4,8,16]` -> select `8`, `capped=false`.
- Between tiers: need `9` -> select `16`, `capped=false`.
- Fractional requirement: need `7.5` -> select `8`, `capped=false`.
- Exceed max: need `20` -> select `16`, `capped=true`.
- Additional precondition test: empty tier list should panic (or return Option if API changes).
Open questions:
- Panic vs `Option/Result` for empty tiers. Current recommendation: panic precondition because provider arrays are compile-time non-empty with tests.

## T2
Checklist item: Implement generic `pick_tier()` reusable across all 4 provider tier arrays.

Deliverable: API implementation contract.
- Signature should remain accessor-based and provider-agnostic.
- Requires no provider-module edits for field extraction.
- Compatibility proof from R1 evidence (same `ram_gib: u16` shape).
Open questions:
- None for Stage 3.

## T3
Checklist item: Export `ram_heuristics` from `lib.rs` after helper compiles.

Deliverable: Export sequencing note.
- Add `pub mod ram_heuristics;` once file compiles to avoid temporary broken exports.
- Keep registry untouched in Stage 3 (R4 boundary).
Open questions:
- None.

## T4
Checklist item: Validate `cargo test -p pricing-calculator -- pick_tier` and `cargo clippy -p pricing-calculator -- -D warnings`.

Deliverable: Validation plan.
- Execute after `pick_tier` code + tests are present.
- Record in testing log with command-accurate entries.
Open questions:
- None.

## BW1
Checklist item: Add failing tests for `estimate_monthly_bandwidth_gb()` and storage-reuse regression coverage.

Deliverable: Test matrix and regression intent.
- Bandwidth formula candidate:
  - `search_requests_per_month * avg_document_size_bytes * RESULTS_PER_PAGE / 1_000_000_000`.
- Example expected value:
  - `50_000 * 2048 * 20 / 1_000_000_000 = 2.048 GB`.
- Regression anchor tests:
  - RAM helper output should equal `workload.storage_gib() * multiplier` for each engine.
  - This proves helpers remain coupled to `storage_gib()` derivation, not ad hoc math.
External defaults used for `RESULTS_PER_PAGE` rationale:
- Meilisearch `limit` default `20` [S5].
- Typesense `per_page` default `10` [S6].
- Elasticsearch `size` default `10` [S7].
Open questions:
- Whether to choose `RESULTS_PER_PAGE=10` (neutral) vs `20` (cost-conservative upper bound). Current recommendation: `20`.

## BW2
Checklist item: Implement `estimate_monthly_bandwidth_gb(workload)` and supporting constants without provider-pricing concerns.

Deliverable: Implementation boundary.
- Use decimal GB for bandwidth (network billing conventions + existing provider constant naming uses GB).
- Keep function independent of cents/rates.
- Do not invoke `storage_gib()` here; bandwidth is per-query payload flow, not stored corpus size.
Evidence:
- Meili pricing constant is per-GB, not GiB ([infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:80](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/providers/meilisearch_resource_based.rs:80)).
Open questions:
- If Stage 5 adds response compression assumptions, should helper expose tunable compression factor? Not required now.

## BW3
Checklist item: Validate `cargo test -p pricing-calculator -- bandwidth` and `cargo check -p pricing-calculator`.

Deliverable: Validation plan.
- Run once bandwidth tests + helper are implemented.
- Append one-line PASS/FAIL summaries to testing log.
Open questions:
- None.

## A1
Checklist item: Audit `ram_heuristics.rs`, `types.rs`, `lib.rs` for duplicated storage math or provider-specific sizing branches.

Deliverable: Audit criteria.
- Reject any new raw storage derivation duplicating `storage_gib()` formula.
- Reject provider-specific branch logic in shared helper (engine family only).
- Reject duplicate heuristic constants in provider modules once Stage 5 wiring starts.
Evidence anchor: single-source storage derivation in [infra/pricing-calculator/src/types.rs:86](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/types.rs:86).
Open questions:
- None.

## A2
Checklist item: Re-run full crate tests + clippy; confirm only Stage 6 ignored comparison-contract tests remain deferred.

Deliverable: audit expectation.
- Expected remaining ignores in `lib.rs` test block are the Stage 6 comparison contract tests ([infra/pricing-calculator/src/lib.rs:74](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/lib.rs:74), [85](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/lib.rs:85), [104](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/lib.rs:104), [117](/Users/stuart/parallel_development/fjcloud_dev/MAR15_pricing_comparison_calculator/fjcloud_dev/infra/pricing-calculator/src/lib.rs:117)).
Open questions:
- None.

## A3
Checklist item: Confirm Stage 5 provider calculators can consume shared helpers directly; if not, handoff note instead of ad hoc utils.

Deliverable: Compatibility checkpoint.
- Existing provider tiers are accessor-compatible now (R1).
- No extra helper modules should be added in provider folders unless a concrete incompatibility appears.
- If a future provider requires multidimensional tier fit (RAM + storage), keep `pick_tier` RAM-only and compose provider-side decision logic in Stage 5.
Open questions:
- Elastic includes `storage_gib` on tier; Stage 5 may need a second fit check after RAM fit.

## Source-backed Assumption Summary
- Typesense RAM heuristic baseline: 2x indexed/searchable data is the lower bound in official guidance [S1].
- Meilisearch memory heuristic: docs explicitly say ~1/3 RAM-to-disk is generally fine and ~1/10 often works [S2].
- Elasticsearch/OpenSearch memory model: heap should be <=50% and filesystem cache matters [S3], with AWS giving a storage-oriented initial estimate [S4].
- Bandwidth default page-size rationale: Meili default 20, Typesense/Elasticsearch default 10 [S5][S6][S7].

## Open Questions (Stage 5 Handoff)
1. Keep one Elasticsearch-family multiplier for both Elastic Cloud and AWS OpenSearch, or introduce per-provider override knobs?
2. Should `pick_tier()` codify empty-slice handling as panic precondition (current recommendation) or explicit `Result`?
3. Should `estimate_monthly_bandwidth_gb()` include compression factor and/or provider-specific default page-size in Stage 5?

## Sources
- [S1] Typesense System Requirements (Choosing RAM): https://typesense.org/docs/guide/system-requirements.html
- [S2] Meilisearch Storage / Engine Storage docs: https://www.meilisearch.com/docs/learn/engine/storage
- [S3] Elasticsearch JVM settings (heap <= 50%, filesystem cache): https://www.elastic.co/docs/reference/elasticsearch/jvm-settings
- [S4] AWS OpenSearch choosing instances/testing: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/bp-instances.html
- [S5] Meilisearch Search API (default `limit: 20`): https://www.meilisearch.com/docs/reference/api/search/search-with-post
- [S6] Typesense Search API (default `per_page: 10`): https://typesense.org/docs/29.0/api/search.html
- [S7] Elasticsearch Search API (default `size: 10`): https://www.elastic.co/guide/en/elasticsearch/reference/8.19/search-search.html
