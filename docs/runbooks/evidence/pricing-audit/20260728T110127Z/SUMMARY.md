# Competitor Pricing Audit Closeout — 20260728T110127Z

PURPOSE: Bundle-level closeout for the competitor pricing verification pass run
under `docs/runbooks/pricing-audit.md`. Every fact below is derived from the
artifacts committed in this bundle and from the provider modules at the commit
that landed them; nothing here was re-fetched.

## Result

```
providers_targeted=3
providers_verified=0
providers_left_modelled=3
```

`providers_targeted=0` is `VACUOUS`, never success: a pass that inspected no
provider has proven nothing and must not be read as a clean audit. This pass
targeted three providers, so the result is non-vacuous — but zero of them earned
a source-backed `last_verified` date, and all three remain modelled and
explicitly allowlisted in `TEMPORARILY_UNVERIFIED_COMPETITORS`
(`infra/pricing-calculator/src/providers/mod.rs`).

## Dispositions

Each provider's `summary.md` is the sole owner of the full gap, smallest
unblock, owner files, and usable-proxy bias/tolerance record. Corrections belong
there, not here.

| Provider | Obstacle | Disposition | Record |
| --- | --- | --- | --- |
| Typesense Cloud | The public pricing page and its own calculator fragments returned HTTP 200 but rendered `N/A` instead of hourly prices for every modelled tier request. | ship | [`typesense_cloud/summary.md`](typesense_cloud/summary.md) |
| AWS OpenSearch Service | The OpenSearch page and the AmazonES offer confirmed compute and gp3 rates but only delegated outbound transfer to standard AWS transfer charges, leaving `DATA_TRANSFER_CENTS_PER_GB` modelled. | ship | [`aws_opensearch/summary.md`](aws_opensearch/summary.md) |
| Elastic Cloud | The hosted pricing page confirmed only the `$99/month` 120 GB 2-zone baseline, not the modelled scaled hosted tier table. | ship | [`elastic_cloud/summary.md`](elastic_cloud/summary.md) |

"ship" means: keep the modelled constants in place, keep `last_verified = None`,
and keep the provider allowlisted until its gap is closed. No provider was
reverted or parked.

## Per-provider verification record

### Typesense Cloud

- Fetch: `curl -L --max-time 30 https://cloud.typesense.org/pricing`
- HTTP 200, effective URL `https://cloud.typesense.org/pricing/calculator`
- Additional captures: page-owned `chart_fragment` requests for the modelled 1,
  2, 4, 8, 16, 32, and 64 GB tiers (`chart_n_virginia_*_one_node.html`), each
  HTTP 200.
- Changed: nothing. The page confirmed the modelled RAM option names but exposed
  no source-backed hourly prices, and the calculator fragments rendered `N/A`.
- Known-answer check: none required — no pricing constant changed.
- `metadata().last_verified` remains `None`.

### AWS OpenSearch Service

- Fetch: `curl -L --max-time 30 https://aws.amazon.com/opensearch-service/pricing/`
- HTTP 200, effective URL `https://aws.amazon.com/opensearch-service/pricing/`
- Fetch: `curl -L --max-time 30 https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonES/current/us-east-1/index.json`
- HTTP 200, effective URL unchanged after redirects.
- Changed, in `infra/pricing-calculator/src/providers/aws_opensearch.rs`:

  | Constant | Was | Now | Offer value |
  | --- | --- | --- | --- |
  | `m6g.large.search` hourly | `16.7¢` | `12.8¢` | `$0.128/hr` |
  | `r6g.large.search` hourly | `26.1¢` | `16.7¢` | `$0.167/hr` |
  | `r6g.xlarge.search` hourly | `52.2¢` | `33.5¢` | `$0.335/hr` |
  | `r6g.2xlarge.search` hourly | `104.4¢` | `66.9¢` | `$0.669/hr` |
  | `r6g.4xlarge.search` hourly | `208.8¢` | `133.9¢` | `$1.339/hr` |
  | `EBS_GP3_CENTS_PER_GIB_MONTH` | `8¢` | `12.2¢` | `$0.122/GB-month` |

  `t3.small.search` and `t3.medium.search` still matched the offer and were left
  alone.
- Known-answer checks: the four changed `r6g` rates and the gp3 rate are pinned
  by `aws_opensearch.rs::estimate_r6g_data_node_rates_match_hand_calculated_totals()`,
  which shows its arithmetic independently of the implementation for each tier
  (for example `r6g.large`: 730 hr × 16.7¢ = 12191¢ compute, 32 GiB × 12.2¢ =
  390.4¢ → 390¢ EBS, 0¢ transfer, 12581¢ total). The changed `m6g.large` rate
  and the gp3 rate are additionally pinned by
  `aws_opensearch.rs::estimate_ha_adds_dedicated_masters()`, which hand-computes
  the dedicated-master line as 3 × 730 hr × 12.8¢ = 28032¢. Every changed
  constant therefore has a hand-calculated assertion.
- `metadata().last_verified` remains `None`: outbound transfer pricing is still
  unverified, so the module has not earned a date.

### Elastic Cloud

- Fetch: `curl -L --max-time 30 https://www.elastic.co/pricing/cloud-hosted`
- HTTP 200, effective URL `https://www.elastic.co/pricing/cloud-hosted`
- Changed: nothing. The page confirmed the `$99/month` Standard entry point at
  120 GB storage / 2 zones, but did not publish the modelled 8, 16, 32, and
  64 GB tiers or their bundled-storage assumptions.
- Known-answer check: none required — no pricing constant changed.
- `metadata().last_verified` remains `None`.

## Guard state after this pass

- All three providers are entries in `TEMPORARILY_UNVERIFIED_COMPETITORS`, each
  carrying an obstacle string that names this bundle timestamp.
- `all_competitor_metadata_is_verified_or_explicitly_allowlisted()` passes on
  that basis; deleting any of the three tuples while its `last_verified` is
  still `None` turns it red.
- Undated metadata stays out of `stale_providers()` by design — unverified is
  not the same as stale. See section 3 of `docs/runbooks/pricing-audit.md`.
