# Stage 4 Research Findings

## §R1 — Scope Confirmation: Stage 4 Only Adds Usage-Based Estimators and Partial Registry Wiring

### Files touched by Stage 4

| File | Change |
|---|---|
| `providers/algolia.rs` | Add `pub fn estimate(&WorkloadProfile) -> EstimatedCost` + module-local helpers |
| `providers/meilisearch_usage_based.rs` | Add `pub fn estimate(&WorkloadProfile) -> EstimatedCost` + plan-evaluation helper |
| `providers/mod.rs` | Wire 2 estimators in `provider_registry()`, replace Stage 2 registry test |

### Files NOT touched by Stage 4

| File | Reason |
|---|---|
| `types.rs` | No schema changes — `CostLineItem`, `EstimatedCost` already have the needed fields |
| `lib.rs` | `compare_all()` already delegates to `all_estimates()` via `filter_map`; 4 ignored tests stay ignored |
| `ram_heuristics.rs` | Usage-based providers don't need RAM estimation — that's Stage 5 only |
| `providers/{meilisearch_resource_based,typesense_cloud,elastic_cloud,aws_opensearch}.rs` | Stage 5 only |

### Boundary confirmation

- The `EstimateFn` type alias `fn(&WorkloadProfile) -> EstimatedCost` on `mod.rs:11` is the exact function signature both new estimators will implement.
- `all_estimates()` on `mod.rs:63-68` already uses `filter_map` on `Option<EstimateFn>`, so wiring 2 of 6 entries produces exactly 2 estimates without changing `all_estimates()` itself.
- The 4 `#[ignore]` tests in `lib.rs:74-129` expect 6 estimates — they must stay ignored until Stage 6.

---

## §R2 — Module-Local Helper Boundary

### Algolia: anchor to `effective_records()`

The existing seam:
```rust
// algolia.rs:40-42
pub fn effective_records(document_count: i64, sort_directions: u8) -> i64 {
    document_count * (1 + sort_directions as i64)
}
```

This is the **single source of truth** for standard-replica record multiplication. The new `estimate()` function must call this — never re-derive `document_count * (1 + sort_directions)` inline.

**New helpers needed in algolia.rs** (module-local, not public):

1. `fn overage_quantity_1k(total: i64, included: i64) -> Decimal`
   - Computes `max(0, total - included) / 1000` as a Decimal.
   - Used for both record and search overage quantities.
   - Single formula, called twice (once for records, once for searches).

2. `fn line_item_amount_cents(quantity_1k: Decimal, rate_per_1k: Decimal) -> i64`
   - Computes `(quantity_1k * rate_per_1k).round_dp(0)` and converts to i64.
   - Shared rounding logic for all overage line items.

These two helpers keep the overage formula in one place. The `estimate()` function calls them to build each `CostLineItem`.

### Meilisearch: single plan-evaluation helper

The existing seam:
```rust
// meilisearch_usage_based.rs:59-60
pub const PLANS: &[UsagePlan] = &[BUILD_PLAN, PRO_PLAN];
```

**New helper needed in meilisearch_usage_based.rs** (module-local):

1. `fn evaluate_plan(plan: &UsagePlan, workload: &WorkloadProfile) -> i64`
   - Computes total monthly cost in cents for one plan against a workload:
     ```
     base_cents
       + round(max(0, documents - included_documents) / 1000 * doc_overage_rate)
       + round(max(0, searches - included_searches) / 1000 * search_overage_rate)
     ```
   - Returns the total so `estimate()` can compare across plans.
   - **This is the single source of truth for Build-vs-Pro selection.** Tests call this helper to verify plan scoring; `estimate()` calls it to pick the winner. No duplicated comparison logic.

2. The `estimate()` function iterates `PLANS`, calls `evaluate_plan()` for each, selects `min_by_key`, then builds line items for the selected plan.

### Why not a shared cross-provider overage helper?

Both Algolia and Meilisearch use the pattern `max(0, total - included) / 1000 * rate`. Extracting a shared helper into `types.rs` or a new module is tempting but premature:
- Algolia has no base fee; Meilisearch does.
- Algolia's record count includes replicas (`effective_records()`); Meilisearch's doesn't.
- The pattern is 2 lines of code. Duplicating it in 2 files is acceptable; a cross-module abstraction would create coupling without value.

If Stage 5 resource-based providers also need overage math (they won't — they use tier-based pricing), extraction can happen then.

---

## §R3 — EstimatedCost Output Shape

### Per-line-item rounding strategy (LOCKED)

1. All billing math uses `rust_decimal::Decimal` — no f64 anywhere.
2. Overage quantity: `Decimal::from(max(0, total - included)) / dec!(1000)`.
3. `amount_cents`: `(quantity * unit_price_cents).round_dp(0).to_i64().unwrap()`.
   - `round_dp(0)` uses banker's rounding (midpoint nearest even). Acceptable for estimates — the max rounding error per line item is ±0.5 cents.
4. `monthly_total_cents`: `line_items.iter().map(|li| li.amount_cents).sum::<i64>()`.
5. This guarantees the line-item-sum invariant: each `amount_cents` is an integer before summing, so no floating-point drift.

### Algolia output shape

```rust
EstimatedCost {
    provider: ProviderId::Algolia,
    monthly_total_cents: /* sum of line items */,
    line_items: vec![
        CostLineItem {
            description: "Record overage (includes standard replicas)".to_string(),
            quantity: /* overage_records / 1000 as Decimal */,
            unit: "records_1k".to_string(),
            unit_price_cents: RECORD_OVERAGE_CENTS_PER_1K,  // dec!(40)
            amount_cents: /* rounded */,
        },
        CostLineItem {
            description: "Search request overage".to_string(),
            quantity: /* overage_searches / 1000 as Decimal */,
            unit: "searches_1k".to_string(),
            unit_price_cents: SEARCH_OVERAGE_CENTS_PER_1K,  // dec!(50)
            amount_cents: /* rounded */,
        },
    ],
    assumptions: vec![
        "Algolia Grow plan (pay-as-you-go); Grow Plus volume discounts not modeled".to_string(),
        "Standard replicas used for sort directions; virtual replicas are a zero-cost alternative".to_string(),
        "Record billing uses worst-case month (3-day peak exclusion not applied)".to_string(),
    ],
    plan_name: Some("Grow".to_string()),
}
```

**Design decisions:**
- Always emit both line items, even when quantity is 0 and amount_cents is 0 (within free tier). This makes the free-tier status visible and shows all billing dimensions.
- `plan_name` is always `Some("Grow")` — the only usage-based Algolia plan modeled.
- 3 assumption strings covering: plan scope, replica model, and billing conservatism.

### Meilisearch output shape

```rust
EstimatedCost {
    provider: ProviderId::MeilisearchUsageBased,
    monthly_total_cents: /* sum of line items */,
    line_items: vec![
        CostLineItem {
            description: format!("{} plan base fee", selected_plan.name),
            quantity: dec!(1),
            unit: "month".to_string(),
            unit_price_cents: Decimal::from(selected_plan.monthly_base_cents),
            amount_cents: selected_plan.monthly_base_cents,
        },
        CostLineItem {
            description: "Document overage".to_string(),
            quantity: /* overage_docs / 1000 as Decimal */,
            unit: "documents_1k".to_string(),
            unit_price_cents: selected_plan.document_overage_cents_per_1k,
            amount_cents: /* rounded */,
        },
        CostLineItem {
            description: "Search request overage".to_string(),
            quantity: /* overage_searches / 1000 as Decimal */,
            unit: "searches_1k".to_string(),
            unit_price_cents: selected_plan.search_overage_cents_per_1k,
            amount_cents: /* rounded */,
        },
    ],
    assumptions: vec![
        format!("Automatically selected {} plan (lowest total cost)", selected_plan.name),
        "Overage billing applies when exceeding plan included amounts".to_string(),
    ],
    plan_name: Some(selected_plan.name.to_string()),
}
```

**Design decisions:**
- 3 line items: base fee + document overage + search overage.
- `plan_name` is always populated with the selected plan name ("Build" or "Pro").
- 2 assumption strings: explains the automatic plan selection and overage model.
- Document overage and search overage line items emitted even when 0 (same rationale as Algolia).

---

## §R4 — Stage 4 Registry Change

### Exact change in `providers/mod.rs`

```rust
fn provider_registry() -> &'static [ProviderRegistration] {
    &[
        ProviderRegistration {
            metadata: algolia::metadata,
            estimate: Some(algolia::estimate),  // was: None
        },
        ProviderRegistration {
            metadata: meilisearch_usage_based::metadata,
            estimate: Some(meilisearch_usage_based::estimate),  // was: None
        },
        // These 4 stay None until Stage 5:
        ProviderRegistration {
            metadata: meilisearch_resource_based::metadata,
            estimate: None,
        },
        ProviderRegistration {
            metadata: typesense_cloud::metadata,
            estimate: None,
        },
        ProviderRegistration {
            metadata: elastic_cloud::metadata,
            estimate: None,
        },
        ProviderRegistration {
            metadata: aws_opensearch::metadata,
            estimate: None,
        },
    ]
}
```

### Stage 2 test disposition

The test `provider_registry_has_no_estimators_in_stage_two` (mod.rs:179-185) asserts all estimates are `None`. This will fail as soon as estimators are wired. Action: **remove this test** and replace with Stage 4 registry tests:

1. `all_estimates_returns_exactly_two_in_stage_four` — asserts `all_estimates(&workload).len() == 2`
2. `all_estimates_contains_algolia_and_meilisearch_usage` — asserts the two returned estimates have `provider == ProviderId::Algolia` and `provider == ProviderId::MeilisearchUsageBased`
3. `all_estimates_preserves_registry_order` — asserts Algolia comes before Meilisearch (matching the registry order)

### Ignored tests in lib.rs

The 4 `#[ignore]` tests in lib.rs (lines 74-129) stay ignored. They expect 6 estimates and won't pass until all 6 providers have estimators wired (Stage 5/6). No changes to lib.rs in Stage 4.

---

## Open Questions (none blocking)

1. **Algolia Grow Plus**: The calculator models only the Grow plan. Grow Plus offers volume discounts for larger workloads but requires a sales conversation for pricing. This is correctly captured as an assumption string — no action needed in Stage 4.

2. **Meilisearch plan ties**: If Build and Pro produce the same total cost, the helper picks whichever `min_by_key` returns first (Build, since PLANS is sorted by base price). This is acceptable — the lower-base plan is the reasonable default when totals are tied.
