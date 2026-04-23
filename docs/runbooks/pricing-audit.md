# Pricing Audit Runbook

Use this runbook whenever provider pricing inputs change in
`infra/pricing-calculator/src/providers/`.

## Goal

Keep the public comparison surface accurate by updating provider pricing inputs,
refreshing each provider module's `last_verified` date only after full source
verification, and enforcing freshness through the `stale_providers(90)` gate.

## When To Run

- Any provider rate/plan change
- Any provider billing-model assumption change
- Any metadata source URL change
- Scheduled periodic pricing re-verification

## 1. Re-verify provider pricing sources

For every registered provider module in
`infra/pricing-calculator/src/providers/`:

- Re-open the source URLs from that module's `metadata().source_urls`
- Confirm pricing constants and plan assumptions still match published sources
- Update constants/assumptions in that provider module if needed

## 2. Refresh `last_verified` in each provider module

After verification, set `metadata().last_verified` in each provider module to
`Some(current_verification_date)`.

If a provider still relies on modeled or training-data inputs, keep
`metadata().last_verified = None` so the module does not claim a source-backed
verification date it does not actually have.

Expected provider modules:

- `algolia.rs`
- `meilisearch_usage_based.rs`
- `meilisearch_resource_based.rs`
- `typesense_cloud.rs`
- `elastic_cloud.rs`
- `aws_opensearch.rs`

## 3. Run the freshness gate

Run the stale-provider suite (includes freshness gate assertion):

```bash
cd infra && cargo test -p pricing-calculator -- stale
```

Freshness logic:

- `stale_providers(90)` returns providers with explicit verification dates older than 90 days
- `ensure_pricing_freshness(90)` returns an error message naming stale providers
  and their verification labels

## 4. Run full validation commands

Run this exact command set after pricing updates:

```bash
cd infra && cargo test -p pricing-calculator -- compare_all
cd infra && cargo test -p pricing-calculator -- preset
cd infra && cargo test -p pricing-calculator -- stale
cd infra && cargo test -p pricing-calculator
cd infra && cargo check -p pricing-calculator
cd infra && cargo clippy -p pricing-calculator -- -D warnings
```

## 5. Update docs if public surface changed

If API names or maintenance workflow changed, update:

- `infra/pricing-calculator/src/lib.rs` exports
- `README.md` key-files/repo-structure references
- `FEATURES.md` pricing calculator feature entries
