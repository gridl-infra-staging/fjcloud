# Stage 3 Research Findings — Shared Estimation Heuristics

## 1. Tier Table Inventory

All four resource-based providers use `ram_gib: u16` and sort tiers ascending by RAM.
All are `&'static [T]` slices. Existing Stage 2 tests enforce the sort invariant.

| Provider | Constant | Struct | Extra fields | Tiers | RAM range |
|----------|----------|--------|-------------|-------|-----------|
| Meilisearch Resource | `INSTANCE_TIERS` | `InstanceTier` | `name`, `vcpus: Decimal`, `monthly_cents: i64` | 5 | 1–16 GiB |
| Typesense Cloud | `RAM_TIERS` | `RamTier` | `hourly_cents: Decimal` | 7 | 1–64 GiB |
| Elastic Cloud | `INSTANCE_TIERS` | `InstanceTier` | `storage_gib: u16`, `monthly_cents: i64` | 5 | 4–64 GiB |
| AWS OpenSearch | `INSTANCE_TYPES` | `InstanceType` | `name`, `vcpus: u8`, `hourly_cents: Decimal` | 7 | 2–128 GiB |

**Key for `pick_tier()` design:** All four share `ram_gib: u16`. A closure `|tier| tier.ram_gib`
is the lightest way to extract the RAM value without adding a trait to four separate modules.

## 2. `estimate_ram_gib()` — Engine Family Enum

**Decision:** Introduce `SearchEngine` enum in `ram_heuristics.rs` with 3 variants:

```rust
pub enum SearchEngine {
    Typesense,
    Meilisearch,
    Elasticsearch, // covers both Elastic Cloud and AWS OpenSearch
}
```

**Why not reuse `ProviderId`?** `ProviderId` includes Algolia and Meilisearch usage-based,
which have no RAM-based pricing. Accepting `ProviderId` would force the function to
panic/error on 2 of 6 variants. A dedicated 3-variant enum is correct by construction.

**Why `Elasticsearch` covers OpenSearch:** Both use the same Lucene-based JVM engine with
identical memory architecture (JVM heap + OS page cache). Same sizing rules apply.

## 3. RAM Multipliers — Official Source Verification

### Typesense: `storage_gib * 2.0`

**Official guidance:** "If the size of your dataset (only including fields you want to search
on) is X MB, you'd typically need 2X-3X MB RAM to index the data."
— [typesense.org/docs/guide/system-requirements.html](https://typesense.org/docs/guide/system-requirements.html)

**Our multiplier:** 2.0x of total document size (via `storage_gib()`). Since `storage_gib()`
includes all fields (not just searchable), 2.0x of total ≈ 2.5-4x of searchable fields.
This is within or above the official 2-3x range. Conservative enough for cost estimation.

### Meilisearch: `storage_gib * 2.5`

**Official guidance:** Database files can be 25-30x the raw JSON size due to LMDB indexing.
However, "a RAM-to-disk ratio around 1/3 does not materially impact performance," with
some workloads acceptable at 1/10.
— [meilisearch.com/docs/learn/advanced/storage](https://www.meilisearch.com/docs/learn/advanced/storage)

**Derivation:** disk_usage ≈ raw_data × 25. Viable RAM ≈ disk_usage / 10 to disk_usage / 3.
Lower bound: 25 / 10 = 2.5x. Upper bound: 25 / 3 ≈ 8.3x.

**Our multiplier:** 2.5x — the minimum viable RAM for acceptable performance. Appropriate
for a cost calculator that estimates the cheapest adequate configuration.

### Elasticsearch/OpenSearch: `max(storage_gib * 0.5, 4.0)`

**Official guidance (Elastic):** "Set Xms and Xmx to no more than 50% of the total memory."
JVM heap handles query processing; OS page cache speeds disk reads.
— [elastic.co/guide/en/elasticsearch/reference/current/advanced-configuration.html](https://www.elastic.co/guide/en/elasticsearch/reference/current/advanced-configuration.html)

**Official guidance (AWS):** "2 vCPU cores and 8 GiB of memory for every 100 GiB of storage"
for heavy workloads = 0.08x RAM:storage ratio.
— [docs.aws.amazon.com/opensearch-service/latest/developerguide/bp-instances.html](https://docs.aws.amazon.com/opensearch-service/latest/developerguide/bp-instances.html)

**Our multiplier:** `max(storage_gib * 0.5, 4.0 GiB)`. The 0.5x accounts for the JVM heap
need (search-heavy workloads benefit from heap ≈ 50% of data) plus some filesystem cache.
4.0 GiB minimum ensures JVM has enough baseline heap. This is higher than the AWS 0.08x
recommendation for storage-heavy workloads but appropriate for search-focused use cases
where query performance matters.

**Note:** Elastic Cloud bundles storage with each tier (`storage_gib` field), so the
Stage 5 calculator may also need to consider storage fit when selecting tiers. That's
a Stage 5 concern — `pick_tier()` selects purely on RAM.

## 4. `pick_tier()` — Generic Tier Selection API

**Signature:**
```rust
pub struct TierSelection<'a, T> {
    pub tier: &'a T,
    pub capped: bool,
}

pub fn pick_tier<T>(
    ram_needed_gib: Decimal,
    tiers: &[T],
    ram_accessor: impl Fn(&T) -> u16,
) -> TierSelection<'_, T>
```

**Behavior:**
1. Scan `tiers` (sorted ascending by RAM) for the first entry where `ram_accessor(tier) >= ram_needed_gib`.
2. If found: return `TierSelection { tier, capped: false }`.
3. If no tier is large enough: return the last (largest) tier with `capped: true`.
4. Panics if `tiers` is empty (precondition; all Stage 2 arrays are non-empty with test coverage).

**Why closure over trait:** Adding a `HasRamGib` trait would require 4 `impl` blocks across
4 provider modules for a single field accessor. A closure avoids cross-module coupling
and is idiomatic Rust for this pattern (cf. `Iterator::max_by_key`).

**Why `capped: bool` over assumption strings:** The caller has provider-specific context
(tier name, RAM amount, provider display name) to generate a meaningful assumption string.
`pick_tier()` returning generic strings would be less informative.

## 5. `estimate_monthly_bandwidth_gb()` — Bandwidth Estimation

**Signature:**
```rust
pub fn estimate_monthly_bandwidth_gb(workload: &WorkloadProfile) -> Decimal
```

**Formula:** `searches_per_month × avg_document_size_bytes × RESULTS_PER_PAGE / BYTES_PER_GB`

**Constants:**
- `RESULTS_PER_PAGE: i64 = 20` — conservative estimate. Meilisearch and Algolia default
  to 20 results/page; Typesense and Elasticsearch default to 10. Using 20 avoids
  underestimating bandwidth costs.
- `BYTES_PER_GB: i64 = 1_000_000_000` — decimal gigabytes for network transfer (not GiB).
  Provider bandwidth pricing (Meilisearch `BANDWIDTH_CENTS_PER_GB`, OpenSearch data transfer)
  is quoted in GB.

**Unit convention:** Returns GB (decimal), NOT GiB. Network bandwidth is conventionally
measured in decimal GB. This is distinct from `estimate_ram_gib()` which returns GiB
because RAM/storage is conventionally measured in binary GiB.

**Consumers:**
- Meilisearch resource-based: `bandwidth_gb × BANDWIDTH_CENTS_PER_GB` (15 ¢/GB)
- AWS OpenSearch: `bandwidth_gb × transfer_rate` (to be defined in Stage 5)

**Does NOT call `storage_gib()`:** Bandwidth depends on response payload size (searches ×
doc_size × results), not total storage. Different calculation path, no DRY violation.

## 6. `lib.rs` Export Plan

**Only change:** Add `pub mod ram_heuristics;` to `lib.rs`.

**No changes to `providers/mod.rs`:** Provider modules don't import from `ram_heuristics`
until Stage 5 wires the calculators. The registry stays untouched.

## 7. Numeric Type Decision

All three functions return `Decimal` (from `rust_decimal`):
- `estimate_ram_gib()` → `Decimal` — compared against `u16` tier fields via `Decimal::from(tier.ram_gib)`
- `pick_tier()` → `TierSelection<'_, T>` (tier reference, not a numeric)
- `estimate_monthly_bandwidth_gb()` → `Decimal` — multiplied by cents-per-GB `Decimal` in Stage 5

`Decimal` preserves precision until the final rounding to `i64` cents in each provider calculator.
This matches the existing convention in `types.rs` (`CostLineItem::quantity`, `unit_price_cents`).

## 8. Sanity Check — Multiplier vs Tier Range

| Workload | Raw GiB | Typesense (2.0×) | Meili (2.5×) | ES/OS (max 0.5×, 4) |
|----------|---------|-------------------|--------------|----------------------|
| 100K × 2KB | 0.19 | 0.37 → 1 GiB tier | 0.47 → 1 GiB tier | 4.0 → 4 GiB tier |
| 500K × 2KB | 0.93 | 1.86 → 2 GiB tier | 2.33 → 4 GiB tier | 4.0 → 4 GiB tier |
| 1M × 5KB | 4.66 | 9.31 → 16 GiB tier | 11.64 → 16 GiB tier | 4.0 → 4 GiB tier |
| 10M × 5KB | 46.57 | 93.13 → 128 GiB (OS only, TS capped@64) | 116.42 → capped@16 | 23.28 → 32 GiB tier |

The multipliers produce tier selections that align with industry expectations:
- Small workloads land on small tiers across all providers.
- Large workloads approach or exceed Meilisearch's max tier — this is realistic since
  Meilisearch resource-based plans cap at 16 GiB (XL), and very large datasets would
  need their usage-based plan or a custom arrangement.
- Elasticsearch's lower multiplier reflects its reliance on OS page cache over heap.
