# Stage 2 Research Findings

This document records the Stage 2 research that locks the provider registry
shape, `ProviderMetadata` type, per-module interface, and verified pricing data
before implementation work begins.

## 1. Shared vs. Provider-Local Concerns

### Evidence Sources

- `infra/pricing-calculator/src/types.rs` — existing shared types
- `infra/pricing-calculator/src/providers/mod.rs` — Stage 1 seam
- `infra/billing/src/types.rs` — uses `chrono::NaiveDate` for daily usage
- `infra/api/src/services/tenant_quota.rs` — current free-tier limits owner after billing plan module removal
- `stage_01_research_findings.md` — locked conventions

### Decision: What lives where

**`types.rs` (shared across crate)**

- `ProviderMetadata` struct — the uniform shape that every provider module
  returns and that the registry composes. Lives here because it is consumed by
  `providers/mod.rs`, by tests, and eventually by the web API layer.
- `Option<NaiveDate>` for `last_verified` — reuses the same
  `chrono::NaiveDate` already used by `billing::types::DailyUsageRecord.date`,
  while allowing modules with still-modeled pricing inputs to remain
  explicitly unverified. Day-granularity avoids timezone ambiguity.

**Provider modules (provider-local)**

- Provider-specific pricing structs and constants (plan tiers, rates, instance
  sizes). These are private to each module and only used by that module's
  `metadata()` function now and `estimate()` function later.
- Source URLs, display name, verification date, and `ProviderId` — each module
  owns these literals once so the registry never re-declares them.

**`providers/mod.rs` (composition layer)**

- Declares `pub mod` for each provider module.
- Composes `all_metadata()` by calling each module's `metadata()` function.
- Composes `all_estimates()` by calling each module's `estimate()` function
  (wired in Stages 4-5; returns empty vec until then).
- Does NOT duplicate any provider name, URL, or date literal.

## 2. Stage 2 File Split

```
infra/pricing-calculator/src/providers/
├── mod.rs                        # registry composition
├── algolia.rs                    # usage-priced
├── meilisearch_usage_based.rs    # usage-priced
├── meilisearch_resource_based.rs # resource-priced
├── typesense_cloud.rs            # resource-priced
├── elastic_cloud.rs              # resource-priced
└── aws_opensearch.rs             # resource-priced
```

This matches the six `ProviderId` variants frozen in Stage 1. Each file
corresponds exactly to one enum variant.

## 3. `ProviderMetadata` Shape

```rust
/// Metadata about a search provider in the comparison catalog.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProviderMetadata {
    /// Which provider this metadata describes.
    pub id: ProviderId,
    /// Human-readable provider name (e.g. "Algolia", "Typesense Cloud").
    pub display_name: String,
    /// Date the pricing data was last manually verified against source URLs.
    /// `None` means the module still carries modeled/training-data inputs.
    pub last_verified: Option<NaiveDate>,
    /// URLs where the pricing data was sourced/verified.
    pub source_urls: Vec<String>,
}
```

### Rationale

- `id: ProviderId` — ties metadata to the enum; enables lookup and
  deduplication checks.
- `display_name: String` — owned String (not `&'static str`) for consistency
  with the existing `EstimatedCost` style; allocation is negligible for 6
  providers.
- `last_verified: Option<NaiveDate>` — `chrono::NaiveDate` is already a
  workspace dependency (`chrono = { version = "0.4", features = ["serde"] }`).
  The billing crate uses it for `DailyUsageRecord.date`. Day-granularity avoids
  timezone ambiguity that would arise from `DateTime<Utc>`, while `None`
  prevents unverified pricing models from claiming a source-backed date.
- `source_urls: Vec<String>` — Vec because some providers have multiple pricing
  pages (e.g., AWS has a pricing page plus a calculator). Owned Strings for the
  same reason as `display_name`.
- No `pricing_model` or `billing_dimensions` field — those are provider-specific
  and belong in provider-local structs. `ProviderMetadata` is deliberately
  minimal; it answers "who is this provider and when was it checked?" not
  "how does it bill?"

## 4. Provider Module Interface

Each provider module (`algolia.rs`, `typesense_cloud.rs`, etc.) exposes:

```rust
use crate::types::{ProviderId, ProviderMetadata};
use chrono::NaiveDate;

/// Returns metadata for this provider.
pub fn metadata() -> ProviderMetadata {
    ProviderMetadata {
        id: ProviderId::Algolia,
        display_name: "Algolia".to_string(),
        last_verified: Some(
            NaiveDate::from_ymd_opt(2026, 3, 15)
                .expect("valid verification date"),
        ),
        source_urls: vec![
            "https://www.algolia.com/pricing/".to_string(),
        ],
    }
}

// Provider-local pricing structs/constants below.
// Stage 4-5 adds: pub fn estimate(workload: &WorkloadProfile) -> EstimatedCost
```

### Registry Composition Pattern

`providers/mod.rs` lists each module and composes both `all_metadata()` and
(later) `all_estimates()` from the same module list:

```rust
pub mod algolia;
pub mod meilisearch_usage_based;
pub mod meilisearch_resource_based;
pub mod typesense_cloud;
pub mod elastic_cloud;
pub mod aws_opensearch;

pub fn all_metadata() -> Vec<ProviderMetadata> {
    vec![
        algolia::metadata(),
        meilisearch_usage_based::metadata(),
        meilisearch_resource_based::metadata(),
        typesense_cloud::metadata(),
        elastic_cloud::metadata(),
        aws_opensearch::metadata(),
    ]
}

pub fn all_estimates(_workload: &WorkloadProfile) -> Vec<EstimatedCost> {
    // Stage 4-5 wires: vec![algolia::estimate(workload), ...]
    vec![]
}
```

The test-audit step adds a regression test asserting that `all_metadata()`
returns exactly the 6 `ProviderId` variants and preserves the order declared
in `mod.rs`.

### Why not a macro or function-pointer array?

- A `macro_rules!` registry adds indirection for negligible DRY benefit across
  two 6-item lists.
- A `&[fn() -> ProviderMetadata]` const array can't be used because
  `all_estimates` has a different signature (`fn(&WorkloadProfile) -> EstimatedCost`).
- Explicit lists are readable, grep-able, and the regression test catches drift.
  This matches the billing crate's exhaustive tier-to-limits match pattern
  without abstraction.

## 5. Verified Pricing Data Per Provider

All prices verified 2026-03-15 unless noted. Prices marked `[training-data]`
could not be confirmed from live web fetch and must be re-verified before the
implementation session sets `last_verified = Some(...)`.

### 5.1 Algolia (usage-priced)

**Source:** https://www.algolia.com/pricing/ (fetched 2026-03-15)

| Dimension | Grow Plan | Grow Plus Plan |
|-----------|-----------|----------------|
| Free tier | 10K searches/mo + 100K records | 10K searches/mo + 100K records |
| Search overage | $0.50 / 1K requests | $1.75 / 1K requests |
| Record overage | $0.40 / 1K records | $0.40 / 1K records |
| Elevate (enterprise) | Custom / annual contract | — |

**Key billing mechanic:** Standard replicas (used for sort directions) multiply
the record count. Each sort direction adds one standard replica per index,
so effective records = `document_count × (1 + sort_directions)`. The 3
highest-usage days per month are ignored for record billing.

**Calculator implications (Stage 4):**
- Bill search requests at $0.50/1K after 10K free.
- Bill records at $0.40/1K after 100K free, multiplied by `(1 + sort_directions)`.
- Use Grow plan (cheapest) as the default estimate.

### 5.2 Meilisearch Usage-Based (usage-priced)

**Source:** https://www.meilisearch.com/pricing (fetched 2026-03-15, limited detail)

| Dimension | Value | Confidence |
|-----------|-------|------------|
| Base plan | Starting at $30/mo | Confirmed |
| Pricing model | Pre-set search + document limits, overage billing | Confirmed |
| Specific overage rates | Not disclosed on public page | NEEDS VERIFICATION |

**[training-data] Estimated plan structure:**
- Build plan: ~$30/mo, ~10K searches/mo, ~100K documents
- Pro plan: ~$300/mo, higher limits
- Overage rates: ~$1.00/1K extra searches, ~$0.25/1K extra documents

**Open question:** The exact rate card is not publicly disclosed on the pricing
page. The implementation should use the best available data while keeping
`last_verified = None` until the rate card is directly source-backed.

### 5.3 Meilisearch Resource-Based (resource-priced)

**Source:** https://www.meilisearch.com/pricing (fetched 2026-03-15)

| Dimension | Value | Confidence |
|-----------|-------|------------|
| Pricing model | Pay by CPU, RAM, and storage | Confirmed |
| Specific instance prices | Not disclosed on public page | NEEDS VERIFICATION |

**[training-data] Estimated instance pricing:**
- Small (2 vCPU, 4 GB RAM): ~$65/mo
- Medium (4 vCPU, 8 GB RAM): ~$130/mo
- Large (8 vCPU, 16 GB RAM): ~$260/mo

**Calculator implications (Stage 5):** The calculator needs to select the
smallest instance whose RAM fits the workload's estimated RAM requirement
(derived from `storage_gib()` via the RAM heuristic in Stage 3).

### 5.4 Typesense Cloud (resource-priced)

**Source:** https://cloud.typesense.org (fetched 2026-03-15, limited detail)

| Dimension | Value | Confidence |
|-----------|-------|------------|
| Pricing model | Hourly, dedicated clusters | Confirmed |
| Per-record/operation charges | None | Confirmed |
| RAM range | 0.5 GB to 1 TB | Confirmed |
| vCPU range | Up to 960 | Confirmed |
| HA model | 3-node clusters | Confirmed |
| Specific hourly rates | Not on public page | NEEDS VERIFICATION |

**[training-data] Estimated hourly pricing (single node):**

| RAM | Hourly | Monthly (~730 hrs) |
|-----|--------|-------------------|
| 0.5 GB | ~$0.030 | ~$22 |
| 1 GB | ~$0.054 | ~$39 |
| 2 GB | ~$0.100 | ~$73 |
| 4 GB | ~$0.190 | ~$139 |
| 8 GB | ~$0.380 | ~$277 |
| 16 GB | ~$0.740 | ~$540 |
| 32 GB | ~$1.390 | ~$1,015 |
| 64 GB | ~$2.460 | ~$1,796 |

HA multiplier: 3× (3 nodes for high availability).

**Calculator implications (Stage 5):** Select the smallest RAM tier that fits
the workload's RAM heuristic. Multiply by 3 if `high_availability` is true.
No per-search or per-record charges.

### 5.5 Elastic Cloud (resource-priced)

**Source:** https://www.elastic.co/pricing/cloud-hosted (fetched 2026-03-15)

| Tier | Starting Price | Confidence |
|------|---------------|------------|
| Standard | $99/mo | Confirmed |
| Gold | $114/mo | Confirmed |
| Platinum | $131/mo | Confirmed |
| Enterprise | $184/mo | Confirmed |

Base configuration: 120 GB storage, 2 availability zones, instance-type
usage-based pricing.

**[training-data] Estimated instance sizing:**
- Standard base corresponds to ~4 GB RAM Elasticsearch node
- Pricing scales with additional RAM, storage, and zones
- Approximate scaling: ~$0.30-0.40/GB-RAM-hour for data nodes

**Calculator implications (Stage 5):** Use the Standard tier as baseline.
Scale cost linearly with required RAM beyond the base 4 GB allocation.
The $99/mo minimum applies regardless of workload size.

### 5.6 AWS OpenSearch Service (resource-priced)

**Source:** https://aws.amazon.com/opensearch-service/pricing/ (fetched
2026-03-15, pricing tables dynamically rendered — not extractable via fetch)

**[training-data] On-demand pricing (us-east-1):**

| Instance Type | vCPU | Memory (GiB) | Hourly | Monthly (~730 hrs) |
|--------------|------|-------------|--------|-------------------|
| t3.small.search | 2 | 2 | ~$0.036 | ~$26 |
| t3.medium.search | 2 | 4 | ~$0.073 | ~$53 |
| m6g.large.search | 2 | 8 | ~$0.167 | ~$122 |
| r6g.large.search | 2 | 16 | ~$0.261 | ~$191 |
| r6g.xlarge.search | 4 | 32 | ~$0.522 | ~$381 |
| r6g.2xlarge.search | 8 | 64 | ~$1.044 | ~$762 |
| r6g.4xlarge.search | 16 | 128 | ~$2.088 | ~$1,524 |

**EBS storage pricing (us-east-1):**
- gp3: ~$0.08/GB-month
- gp2: ~$0.10/GB-month

**Calculator implications (Stage 5):** Select the smallest instance whose
memory fits the RAM heuristic. Add EBS gp3 storage cost for the workload's
`storage_gib()`. HA requires 2+ data nodes (multi-AZ). Default to `r6g`
family for memory-optimized search workloads.

## 6. Pricing Model Categories

The six providers fall into two pricing model categories that map directly to
which calculator stage implements their `estimate()` function:

| Category | Stage | Providers | Billing Dimensions |
|----------|-------|-----------|-------------------|
| Usage-priced | Stage 4 | Algolia, Meilisearch Usage-Based | searches/mo, records/documents |
| Resource-priced | Stage 5 | Meilisearch Resource-Based, Typesense Cloud, Elastic Cloud, AWS OpenSearch | RAM, storage, instance hours |

This split is already reflected in the Stage 2 checklist's build groups.

## 7. Open Questions

1. **Meilisearch usage-based rate card:** The exact per-search and per-document
   overage rates were initially unclear. Any implementation using estimates
   should keep `last_verified = None` until those values are source-backed.

2. **Typesense Cloud exact hourly rates:** The pricing configurator renders
   prices dynamically. Training-data estimates should remain explicitly
   unverified (`last_verified = None`) until manually confirmed.

3. **Elastic Cloud scaling beyond base tier:** The $99/mo Standard tier includes
   120 GB storage and 2 zones, but the exact per-GB-RAM scaling above the base
   allocation is not publicly documented in a simple rate card. The
   implementation may need to model this as discrete instance size tiers
   rather than continuous scaling.

4. **AWS OpenSearch exact pricing:** The pricing page renders instance tables
   dynamically (JavaScript). Training-data estimates are close but should be
   verified against the AWS Pricing Calculator or CLI during the build session.
