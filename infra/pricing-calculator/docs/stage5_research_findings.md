# Stage 5 Research Findings — Resource-Based Calculator Boundaries

Session: s98 | Date: 2026-03-15

## R1: Pricing Data Seams & Missing Constants

### Shared Heuristics (confirmed, no changes needed)

All shared infrastructure in `ram_heuristics.rs` and `types.rs` is ready for Stage 5
consumption:

| Helper | Location | Purpose |
|--------|----------|---------|
| `estimate_ram_gib(workload, engine)` | `ram_heuristics.rs:82` | RAM estimation for 3 engine families |
| `pick_tier(ram, tiers, accessor)` | `ram_heuristics.rs:121` | Generic tier selection with `capped` flag |
| `estimate_monthly_bandwidth_gb(workload)` | `ram_heuristics.rs:178` | Outbound bandwidth in decimal GB |
| `HOURS_PER_MONTH` | `types.rs:54` | `dec!(730)` — hourly→monthly constant |
| `WorkloadProfile::storage_gib()` | `types.rs:90` | Single source of truth for storage |

### Per-Provider Pricing Data Status

**Typesense Cloud** (`typesense_cloud.rs`) — complete, no changes needed:
- `RAM_TIERS`: 7 tiers (1–64 GiB), hourly pricing in `Decimal` cents
- `HA_NODE_COUNT: i64 = 3`

**Meilisearch Resource-Based** (`meilisearch_resource_based.rs`) — complete, no changes needed:
- `INSTANCE_TIERS`: 5 tiers (XS–XL, 1–16 GiB RAM), monthly cents
- `BASE_STORAGE_GIB: u16 = 32`
- `STORAGE_AUTOSCALE_INCREMENT_GIB: u16 = 100`
- `ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH: Decimal = dec!(16.5)`
- `BANDWIDTH_CENTS_PER_GB: Decimal = dec!(15)`

**Elastic Cloud** (`elastic_cloud.rs`) — complete, no changes needed:
- `INSTANCE_TIERS`: 5 tiers (4–64 GiB RAM), monthly cents with bundled storage
- Each tier has `storage_gib` field (120–1920 GiB)
- Standard subscription pricing includes 2-AZ deployment

**AWS OpenSearch** (`aws_opensearch.rs`) — 3 missing constants must be added:

| Constant | Value | Source |
|----------|-------|--------|
| `DATA_TRANSFER_CENTS_PER_GB` | `dec!(9)` | AWS standard data transfer out to internet, us-east-1, first 10 TB/month tier ($0.09/GB) |
| `DEDICATED_MASTER_NODE_COUNT` | `3` | AWS recommendation for all production domains (quorum requires odd count ≥ 3) |
| `DEDICATED_MASTER_HOURLY_CENTS` | `dec!(16.7)` | m6g.large.search pricing — 8 GiB RAM, supports up to 30 data nodes / 15K shards per AWS sizing table |

**Evidence for data transfer rate**: AWS standard data transfer out to internet pricing
for us-east-1 is tiered: $0.09/GB for the first 10 TB/month, $0.085/GB for the next
40 TB, $0.07/GB for the next 100 TB. Using the first-tier rate ($0.09 = 9 cents/GB)
is the conservative default; volume discounts will be noted as an assumption.
Source: https://aws.amazon.com/ec2/pricing/on-demand/ (Data Transfer tab),
https://aws.amazon.com/opensearch-service/pricing/

**Evidence for dedicated master node config**: AWS docs state "We recommend three
dedicated master nodes for production OpenSearch Service domains." The sizing table
maps 8 GiB RAM masters to support up to 30 data nodes and 15K shards (OpenSearch 2.17+).
Since our calculator targets clusters with 1–2 data nodes, m6g.large.search (8 GiB,
already in INSTANCE_TYPES at line 52) is more than adequate.
Source: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-dedicatedmasternodes.html

---

## R2: Expected EstimatedCost Output Shape

All calculators follow the pattern established by Algolia (`algolia.rs:73`) and
Meilisearch Usage-Based (`meilisearch_usage_based.rs:104`):
- `monthly_total_cents` always equals `line_items.iter().map(|li| li.amount_cents).sum()`
- `plan_name` is always `Some(...)` with the selected tier/plan name
- `assumptions` is always non-empty
- `amount_cents` uses banker's rounding: `(quantity * unit_price_cents).round_dp(0).to_i64().unwrap()`

### Typesense Cloud

```
provider: ProviderId::TypesenseCloud
plan_name: Some("{ram_gib} GiB RAM")    // e.g. "16 GiB RAM"

line_items:
  [0] description: "Compute ({ram_gib} GiB × {node_count} node(s))"
      quantity:     Decimal::from(node_count) * HOURS_PER_MONTH   // e.g. 730 or 2190
      unit:         "instance_hours"
      unit_price_cents: tier.hourly_cents
      amount_cents: rounded(quantity × unit_price_cents)

assumptions (always present):
  - "Typesense Cloud hourly pricing; annual commitment discounts not modeled"
  + if HA: "High availability: 3-node cluster"
  + if capped: "Workload exceeds largest available tier (64 GiB); estimate capped"
```

**Node count logic**: `if workload.high_availability { HA_NODE_COUNT } else { 1 }`

### Meilisearch Resource-Based

```
provider: ProviderId::MeilisearchResourceBased
plan_name: Some("{tier.name}")    // e.g. "M"

line_items:
  [0] description: "{tier.name} instance"
      quantity:     dec!(1)
      unit:         "month"
      unit_price_cents: Decimal::from(tier.monthly_cents)
      amount_cents: tier.monthly_cents

  [1] description: "Additional storage"     // always emitted, $0 if within base
      quantity:     additional_storage_gib   // Decimal, 0 if within base
      unit:         "gib_months"
      unit_price_cents: ADDITIONAL_STORAGE_CENTS_PER_GIB_MONTH
      amount_cents: rounded(quantity × unit_price_cents)

  [2] description: "Outbound bandwidth"     // always emitted
      quantity:     estimate_monthly_bandwidth_gb(workload)
      unit:         "gb"
      unit_price_cents: BANDWIDTH_CENTS_PER_GB
      amount_cents: rounded(quantity × unit_price_cents)

assumptions (always present):
  - "Meilisearch Cloud resource-based pricing; custom plans not modeled"
  - "Single-instance deployment; no built-in HA multiplier in resource-based pricing"
  + if storage overage: "Storage auto-scaled in 100 GiB increments beyond 32 GiB base"
  + if capped: "Workload exceeds largest available tier (16 GiB); estimate capped"
```

**Storage overage logic**:
```
let raw_storage = workload.storage_gib();
if raw_storage <= Decimal::from(BASE_STORAGE_GIB) {
    additional_storage_gib = dec!(0);
} else {
    let overage = raw_storage - Decimal::from(BASE_STORAGE_GIB);
    let increment = Decimal::from(STORAGE_AUTOSCALE_INCREMENT_GIB);
    // Ceiling to next 100 GiB increment
    let increments = (overage / increment).ceil();
    additional_storage_gib = increments * increment;
}
```

### Elastic Cloud

```
provider: ProviderId::ElasticCloud
plan_name: Some("{ram_gib} GiB RAM")    // e.g. "4 GiB RAM"

line_items:
  [0] description: "Standard subscription ({ram_gib} GiB RAM, {storage_gib} GiB storage)"
      quantity:     dec!(1)
      unit:         "month"
      unit_price_cents: Decimal::from(tier.monthly_cents)
      amount_cents: tier.monthly_cents

assumptions (always present):
  - "Elastic Cloud Standard subscription; Gold/Platinum tiers not modeled"
  - "Pricing includes 2-AZ deployment (standard for all tiers)"
  - "Storage bundled with tier ({storage_gib} GiB included)"
  + if workload.storage_gib() > tier.storage_gib:
    "Workload storage ({X:.1} GiB) exceeds tier's bundled {Y} GiB; may require custom configuration"
  + if capped: "Workload exceeds largest available tier (64 GiB RAM); estimate capped"
```

**Simplest calculator**: No separate storage, bandwidth, or HA line items. The tier
price is the total price. `high_availability` flag does not change the price because
Standard subscription pricing already includes 2-AZ deployment.

### AWS OpenSearch

```
provider: ProviderId::AwsOpenSearch
plan_name: Some("{instance_name}")    // e.g. "r6g.large.search"

line_items:
  [0] description: "Data node(s) ({instance_name} × {data_node_count})"
      quantity:     Decimal::from(data_node_count) * HOURS_PER_MONTH
      unit:         "instance_hours"
      unit_price_cents: tier.hourly_cents
      amount_cents: rounded(quantity × unit_price_cents)

  [1] description: "EBS gp3 storage"
      quantity:     workload.storage_gib() * Decimal::from(data_node_count)
      unit:         "gib_months"
      unit_price_cents: EBS_GP3_CENTS_PER_GIB_MONTH
      amount_cents: rounded(quantity × unit_price_cents)

  [2] description: "Data transfer out"    // always emitted
      quantity:     estimate_monthly_bandwidth_gb(workload)
      unit:         "gb"
      unit_price_cents: DATA_TRANSFER_CENTS_PER_GB
      amount_cents: rounded(quantity × unit_price_cents)

  [3] (HA only) description: "Dedicated master nodes (m6g.large.search × 3)"
      quantity:     Decimal::from(DEDICATED_MASTER_NODE_COUNT) * HOURS_PER_MONTH
      unit:         "instance_hours"
      unit_price_cents: DEDICATED_MASTER_HOURLY_CENTS
      amount_cents: rounded(quantity × unit_price_cents)

assumptions (always present):
  - "AWS OpenSearch on-demand pricing (us-east-1); reserved instance discounts not modeled"
  - "EBS gp3 storage at default provisioned IOPS/throughput"
  - "Data transfer uses first-tier rate ($0.09/GB); volume discounts above 10 TB/month not modeled"
  + if HA: "Multi-AZ: 2 data nodes + 3 dedicated master nodes (m6g.large.search)"
  + if !HA: "Single-AZ: 1 data node, no dedicated master nodes"
  + if capped: "Workload exceeds largest available instance (128 GiB RAM); estimate capped"
```

**Data node count logic**: `if workload.high_availability { HA_MIN_DATA_NODES } else { 1 }`

**EBS storage per node**: Each data node gets its own copy of storage. In HA mode with
2 data nodes, EBS volume count doubles (each node replicates the data).

---

## R3: HA Semantics — Locked Per Provider

| Provider | HA Model | `high_availability: true` | `high_availability: false` |
|----------|----------|---------------------------|----------------------------|
| **Typesense Cloud** | Node multiplier | 3 nodes (`HA_NODE_COUNT`) | 1 node |
| **Meilisearch Resource** | No HA in pricing model | Same price (noted in assumptions) | Same price |
| **Elastic Cloud** | Bundled 2-AZ | Same price (2-AZ always included) | Same price (2-AZ always included) |
| **AWS OpenSearch** | Multi-AZ with masters | 2 data nodes + 3 dedicated masters + doubled EBS | 1 data node, no masters |

### Detailed HA Rationale

**Typesense Cloud**: The HA_NODE_COUNT constant (3) is already defined. Typesense Cloud's
HA topology is a 3-node cluster where all nodes serve both reads and writes. The cost
simply triples. No storage/bandwidth impact — purely a compute multiplier.

**Meilisearch Resource-Based**: The resource-based pricing page lists single-instance
tiers only. There is no documented HA multiplier or multi-node option in the published
pricing. The calculator will use the same price for both HA and non-HA workloads, with
an assumption noting the limitation: "Single-instance deployment; no built-in HA
multiplier in resource-based pricing."

**Elastic Cloud**: Standard subscription pricing already includes 2-AZ deployment
topology. This is confirmed by the tier descriptions on the pricing page (e.g., "2
availability zones" is part of the Standard offering). The `high_availability` flag
does not change the Elastic Cloud estimate — both values use the same tier price.
The assumption will note: "Pricing includes 2-AZ deployment (standard for all tiers)."

**AWS OpenSearch**: The most complex HA model. AWS OpenSearch HA requires:
1. Minimum 2 data nodes across 2 AZs (HA_MIN_DATA_NODES = 2)
2. 3 dedicated master nodes for cluster management (always 3 per AWS best practice)
3. Each data node gets its own EBS volume (storage doubles)
4. Master nodes use m6g.large.search (8 GiB RAM, dec!(16.7) hourly)
5. Data transfer out is NOT doubled — it's based on query response volume, not stored data

Source: https://docs.aws.amazon.com/opensearch-service/latest/developerguide/managedomains-multiaz.html

---

## Open Questions (deferred to Stage 6 handoff notes)

1. **AWS OpenSearch tiered data transfer pricing**: We use the first-tier rate ($0.09/GB).
   Workloads exceeding 10 TB/month outbound would benefit from lower tiered rates. This
   is an acceptable simplification for a comparison calculator.

2. **Elastic Cloud storage overage**: When workload storage exceeds the selected tier's
   bundled storage, the calculator notes this as an assumption rather than calculating
   an additional cost. Elastic Cloud does not publish à-la-carte storage add-on pricing
   for Standard tier; the next tier up is the recommended solution.

3. **AWS OpenSearch reserved instances**: Significant discounts (30–50%) available with
   1-year or 3-year commitments. Not modeled — noted as assumption.

4. **Typesense Cloud annual commitments**: Discounted hourly rates available with annual
   commitment. Not modeled — noted as assumption.
