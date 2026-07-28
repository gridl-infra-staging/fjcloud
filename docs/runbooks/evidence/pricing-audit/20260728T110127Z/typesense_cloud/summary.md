# Typesense Cloud Pricing Evidence

PURPOSE: Stage 2 live pricing verification for `infra/pricing-calculator/src/providers/typesense_cloud.rs`.

## Fetches

- `curl -L --max-time 30 https://cloud.typesense.org/pricing`
  - HTTP status: 200
  - Effective URL: `https://cloud.typesense.org/pricing/calculator`
  - Raw response: `body.html`
  - Headers: `headers.txt`
- Calculator fragments were fetched from the page-owned `https://cloud.typesense.org/pricing/chart_fragment` endpoint for the modeled 1, 2, 4, 8, 16, 32, and 64 GB tiers using page-provided vCPU options and `n_virginia` topology.
  - Raw responses: `chart_n_virginia_*_one_node.html`
  - Headers: `chart_n_virginia_*_one_node.headers.txt`
  - Fetch metadata: `chart_n_virginia_*_one_node.fetch.txt`

## Result

- The public page confirmed the modeled RAM option names, including 1, 2, 4, 8, 16, 32, and 64 GB.
- The page did not expose source-backed hourly prices in the static HTML.
- The page-owned calculator fragments returned HTTP 200 but rendered `N/A` for the tested public single-node and HA requests.
- `metadata().last_verified` remains `None`.
- No pricing constants changed.

## Gap Disposition

- Exact gap: the public page did not return usable source-backed hourly tier prices for the modeled requests.
- Smallest unblock: a public Typesense source that renders or returns the hourly per-tier prices for the modeled RAM/vCPU/topology combinations.
- Owner files: `infra/pricing-calculator/src/providers/typesense_cloud.rs`, `infra/pricing-calculator/src/providers/mod.rs`.
- Usable proxy: existing modeled constants only; bias and tolerance are unknown because the fetched public page returned no numeric cluster prices for the modeled configurations.
- Disposition: ship with provider unverified and explicitly allowlisted; revert/refresh constants only after source-backed hourly prices are captured.
