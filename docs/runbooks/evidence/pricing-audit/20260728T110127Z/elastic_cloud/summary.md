# Elastic Cloud Pricing Evidence

PURPOSE: Stage 2 live pricing verification for `infra/pricing-calculator/src/providers/elastic_cloud.rs`.

## Fetches

- `curl -L --max-time 30 https://www.elastic.co/pricing/cloud-hosted`
  - HTTP status: 200
  - Effective URL: `https://www.elastic.co/pricing/cloud-hosted`
  - Raw response: `body.html`
  - Headers: `headers.txt`

## Result

- The hosted pricing page confirms the Standard entry-level claim: `$99 per month` based on a production configuration with `120 GB storage / 2 zones`.
- The page did not expose the modeled scaled hosted tier table for 8, 16, 32, and 64 GB RAM or the corresponding bundled-storage assumptions.
- `metadata().last_verified` remains `None`.
- No pricing constants changed.

## Gap Disposition

- Exact gap: the public hosted pricing page confirms only the baseline Standard price and storage note, not the complete modeled scaled tier table.
- Smallest unblock: a public Elastic hosted pricing calculator/API artifact that provides source-backed Standard tier prices and bundled storage for every modeled tier.
- Owner files: `infra/pricing-calculator/src/providers/elastic_cloud.rs`, `infra/pricing-calculator/src/providers/mod.rs`.
- Usable proxy: existing linear scale from the `$99/month`, 120 GB, 2-zone baseline; bias and tolerance are unknown for non-baseline tiers because the public page does not publish those exact modeled tiers.
- Disposition: ship with provider unverified and explicitly allowlisted; only set `last_verified` after all modeled hosted tiers are source-backed.
