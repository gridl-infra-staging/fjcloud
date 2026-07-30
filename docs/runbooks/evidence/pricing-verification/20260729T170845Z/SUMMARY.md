# Pricing Verification Evidence Summary

UTC timestamp: 2026-07-29T17:08:45Z

HEAD: 71adc2c29ecf22e11425f1a7f58328eb600ac8ea

Evidence path: `docs/runbooks/evidence/pricing-verification/20260729T170845Z/`

## Runtime-Derived Counts

Provider denominator source: `infra/pricing-calculator/src/providers/mod.rs::provider_registry()` and `all_metadata()` at HEAD, excluding only `ProviderId::Griddle`.

Registered third-party providers: 5.

Verified third-party providers before this evidence bundle: 2 of 5 (`Algolia`, `MeilisearchResourceBased`).

Verified third-party providers after this evidence bundle: 2 of 5. This is not `VACUOUS`; denominator is non-zero.

Remaining unverified third-party providers: 3 of 5 (`TypesenseCloud`, `ElasticCloud`, `AwsOpenSearch`).

## Provider Verdicts

| provider | declared URL | HTTP status | effective URL | verdict | metadata change |
| --- | --- | ---: | --- | --- | --- |
| Typesense Cloud | https://cloud.typesense.org/pricing | 200 | https://cloud.typesense.org/pricing/calculator | unverified: RAM and HA selector values found, hourly tier prices not found | keep `last_verified = None` |
| Elastic Cloud | https://www.elastic.co/pricing/cloud-hosted | 200 | https://www.elastic.co/pricing/cloud-hosted | unverified: Standard $99/month and 120 GB / 2-zone baseline found, scaled modeled tiers not found | keep `last_verified = None` |
| AWS OpenSearch Service | https://aws.amazon.com/opensearch-service/pricing/ | 200 | https://aws.amazon.com/opensearch-service/pricing/ | unverified: gp3 and one r6g.xlarge rate found, full modeled instance table and exact outbound transfer rate not found; dedicated master instance differs from examples | keep `last_verified = None` |

## Changed Constants

No provider pricing constants were changed. The public sources did not support a complete replacement for any modeled constant set.

The existing temporary registry allowlist reasons in `infra/pricing-calculator/src/providers/mod.rs` were updated to cite this evidence bundle timestamp so Stage 3 can continue surfacing `last_verified = None` through the real freshness guard/reporting path.

## Remaining Unverified Reasons

Typesense Cloud: fetched page exposed RAM options from 1 GB through 64 GB and the 3-node HA option, but not the modeled single-node hourly rates.

Elastic Cloud: fetched page exposed Standard as low as $99/month and a footnote for 120 GB storage / 2 zones, but not the modeled 8/16/32/64 GiB scaled tier prices.

AWS OpenSearch Service: fetched page exposed managed-cluster billing dimensions, gp3 storage examples, and an `r6g.xlarge.search` example at $0.335/hour, but did not expose every modeled instance rate, did not source the exact $0.09/GB transfer rate on the declared OpenSearch page, and example cluster manager nodes used `c6g.large.search` or `r8g.large.search` rather than modeled `m6g.large.search`.

## Stage 4 Citation

Allowlist or residual freshness notes should cite:

`docs/runbooks/evidence/pricing-verification/20260729T170845Z/SUMMARY.md`
