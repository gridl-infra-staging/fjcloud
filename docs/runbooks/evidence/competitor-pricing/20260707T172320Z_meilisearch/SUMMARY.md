# Meilisearch Pricing Reverification Summary

PURPOSE: Replace the stale 2026-03-15 Meilisearch usage assumptions with a
reproducible public evidence bundle and a binary disposition for the existing
usage-based provider owner.

Disposition: retire

Bundle: `docs/runbooks/evidence/competitor-pricing/20260707T172320Z_meilisearch/`

## Sources and Evidence

| ID | Evidence | Date attached to claim |
| --- | --- | --- |
| S1 | `raw/http/pricing_meta`, `raw/http/pricing_headers`, `raw/http/pricing_body` for `https://www.meilisearch.com/pricing` | Fetched 2026-07-07T17:24:14Z |
| S2 | `raw/http/usage_based_meta`, `raw/http/usage_based_headers`, `raw/http/usage_based_body` for `https://www.meilisearch.com/usage-based` | Fetched 2026-07-07T17:24:15Z |
| S3 | `raw/probes/pricing_text_extract` and `raw/probes/estimator_code_snippets` extracted from S1 and the captured JS chunks | Extracted 2026-07-07 |
| S4 | `raw/payloads/estimate_usage_*`, guessed endpoint captures, and `raw/probes/xhr_payload_probe` | Fetched/probed 2026-07-07T17:28Z |
| S5 | `raw/http/docs_cloud_billing_*`, `raw/http/docs_cloud_usage_based_*`, `raw/http/docs_cloud_plan_limits_*`, `raw/http/pricing_platform_*`, `raw/http/llms_*` | Fetched 2026-07-07T17:25Z |
| S6 | `raw/archive/pricing_cdx_*`, `raw/archive/snapshot_<timestamp>_*`, `raw/archive/archive_timeline_probe_v2` | CDX fetched 2026-07-07T17:26:38Z; archive timestamps listed below |
| S7 | `infra/pricing-calculator/src/providers/meilisearch_usage_based.rs` | HEAD at investigation time |
| S8 | `docs/competitor-pricing-reference.md` | HEAD at investigation time |
| S9 | `docs/runbooks/pricing-audit.md` | HEAD at investigation time |

## Current Public Pricing Surface

The current public pricing page returned HTTP 200 and stayed at
`https://www.meilisearch.com/pricing` on 2026-07-07T17:24:14Z. The legacy
owner URL `https://www.meilisearch.com/usage-based` returned HTTP 200 but its
effective URL was also `https://www.meilisearch.com/pricing`, so it no longer
provides a separate usage-based rate-card surface. The old platform URL
`https://www.meilisearch.com/pricing/platform` also resolves to the same pricing
page. Evidence: S1, S2, S5.

The current public page text exposes these publishable usage facts:

- Cloud is advertised as starting at $20/month.
- The page offers usage-based or resource-based billing.
- The cost estimator uses monthly documents, monthly searches, and average
  document size as inputs.
- The visible usage-based card shows $30/month and a base allowance of 100K
  documents and 50K searches.

Evidence: `raw/probes/pricing_text_extract` lines 15-21 and 36-82.

The captured current calculator code exposes the usage estimator formula:

- Usage total is base 30 plus document overage plus search overage.
- Document overage is calculated only above 100,000 documents at 0.30 dollars
  per 1,000 documents.
- Search overage is calculated only above 50,000 searches at 0.40 dollars per
  1,000 searches.
- For usage totals above 1,000 dollars, the UI switches to a sales contact link
  instead of continuing to display a numeric bill.

Evidence: `raw/probes/estimator_code_snippets`, especially the extracted
`docOverage`, `searchOverage`, `Base plan`, `Extra docs`, `Extra searches`, and
`Contact us` snippets.

The calculator also embeds resource-based information in the current JS chunks,
including region/instance monthly prices and disk/bandwidth text. That
resource-based data is outside the existing usage-based owner, but it matters
because the current public pricing page presents usage-based and resource-based
as peer models, not as the old Build/Pro table. Evidence: S3.

## Payload and API Probe Result

The public `/api/estimate-usage` endpoint returned HTTP 200 for the saved sample
request and produced slider inputs (`documents`, `searches`, and `docSize`) plus
a prose reason. It did not return included quotas, overage rates, plan names, or
a durable rate-card payload. Evidence: S4.

Guessed public rate-card endpoints all returned HTTP 404:

- `/_next/data/zbApzq17l_zJnw03fCNUL/pricing.json`
- `/api/pricing`
- `/api/pricing/calculator`
- `/pricing.json`
- `/pricing/data.json`

Evidence: `raw/payloads/*_meta` for the guessed endpoint captures and
`raw/probes/xhr_payload_probe`.

Absence note: no public calculator/XHR payload was recovered that exposes a
complete machine-readable usage rate card for the current pricing owner. The
only successful API probe exposes estimated workload dimensions, while the rate
math is embedded in the public JS chunk. Evidence: S4.

## Legacy, KB, and Archive Result

The probed documentation/KB URLs that would have supported old plan details now
return HTTP 404:

- `https://www.meilisearch.com/docs/learn/cloud/billing`
- `https://www.meilisearch.com/docs/learn/cloud/usage_based_billing`
- `https://www.meilisearch.com/docs/learn/cloud/plan_limits`

Evidence: S5.

`https://www.meilisearch.com/llms.txt` returned HTTP 200 and directs
up-to-date pricing readers to `https://www.meilisearch.com/pricing`. That makes
the current pricing page the public authority for this research lane. Evidence:
`raw/probes/llms_pricing_probe`.

Two public Meilisearch blog pages were captured because the live surface and
search/indexed marketing content still expose older pricing language. They are
not treated as a current rate card because the current pricing guidance points
to `/pricing`, and the pricing-audit runbook requires source-backed current
pricing before refreshing verification. Evidence: `raw/http/blog_*`.

Archive.org CDX returned 200 captures for these `/pricing` snapshots:
20260309122639, 20260319040003, 20260320212215, 20260401152105,
20260416142505, 20260506161533, 20260605225323, 20260608054859, and
20260615100855. The raw token probe did not recover the old Build/Pro numeric
rate card from those archived bodies, so the archive evidence is inconclusive
for the exact disappearance date and is not used as a current source. Evidence:
S6.

## Comparison Against Current Owner

The current modeled owner is
`infra/pricing-calculator/src/providers/meilisearch_usage_based.rs`:

| Owner assumption | Current public evidence | Disposition |
| --- | --- | --- |
| `metadata().last_verified = None` | Correct under `docs/runbooks/pricing-audit.md`; current public sources do not support the full modeled owner. | Keep unverified until Stage 2 retires or replaces the owner. |
| `SOURCE_URLS` includes `/usage-based` and `/pricing` | `/usage-based` resolves to `/pricing`; `/pricing` is the current public surface. | `/usage-based` is legacy redirect evidence, not a distinct rate-card source. |
| `BUILD_PLAN.name = "Build"` | Current public page exposes a $30 usage-based base plan but does not label it Build in the current pricing text. | Old name lacks current-source support. |
| Build base fee $30/month | Current usage estimator supports $30/month base usage pricing. | Supported for a base usage card only. |
| Build included 100K documents and 50K searches | Current usage estimator supports 100K documents and 50K searches in the base plan. | Supported for a base usage card only. |
| Build overages: $0.30/1K documents and $0.40/1K searches | Current calculator code supports these formula constants. | Supported for a base usage estimator only. |
| `PRO_PLAN.name = "Pro"` | Current pricing page and current calculator probes do not expose a Pro usage plan as a current public rate card. | Unsupported. |
| Pro base fee $300/month | No current pricing-page or calculator evidence recovered. | Unsupported. |
| Pro included 1M documents and 250K searches | No current Pro rate-card evidence recovered. The text probe sees 250K only as a slider marker, not as a Pro allowance. | Unsupported. |
| Pro overages: $0.20/1K documents and $0.30/1K searches | No current Pro overage evidence recovered. | Unsupported. |
| `PLANS = [BUILD_PLAN, PRO_PLAN]` and automatic cheapest-plan selection in `evaluate_plan` | Current public surface presents one usage-based estimator and a separate resource-based estimator. It does not publish automatic Build/Pro selection. | Unsupported for the existing owner. |

The stale public reference in `docs/competitor-pricing-reference.md` still
publishes the old 2026-03-15 Build/Pro table. This bundle does not provide
current public evidence for that table. Evidence: S8.

## Policy Boundary

`docs/runbooks/pricing-audit.md` says `last_verified` should be refreshed only
after pricing constants and plan assumptions match published sources, and that
providers relying on modeled or training-data inputs must keep
`last_verified = None`. Because current public sources do not support the full
Build/Pro owner, Stage 2 must not refresh `last_verified` for the existing
owner. Evidence: S9.

## Gap Spec

The recovered current public evidence is insufficient to re-anchor the existing
usage-based owner because these required owner facts are missing:

- A current public Pro usage plan.
- Current Pro included document and search quotas.
- Current Pro document and search overage rates.
- A current public rule that selects between Build and Pro by lowest total cost.
- A durable machine-readable rate card that Stage 2 can encode as known-answer
  tests for the existing Build/Pro owner.

The current public page does expose a narrower base usage estimator, but that is
not the same behavioral owner as `PLANS = [BUILD_PLAN, PRO_PLAN]` with automatic
cheapest-plan selection.

Open questions:

- Did Meilisearch intentionally retire the public Pro usage plan, or did it move
  behind sales/contact flow?
- Is the current base usage estimator contractual billing input, marketing
  estimate, or both?
- Should Stage 2 remove the usage-based provider entirely, or replace it with a
  narrower current-public "base usage estimator" provider after a separate owner
  decision?

## Stage 2 Handoff

Recommended Stage 2 path: retire the existing usage-based owner unless a new
public source appears before implementation.

Stage 2 owners to inspect and update:

- `infra/pricing-calculator/src/providers/mod.rs`
- `infra/pricing-calculator/src/types.rs::ProviderMetadata.last_verified`
- `infra/api/tests/integration/pricing_compare_test.rs`

Stage 2 should keep the distinction clear:

- Retiring the existing owner is supported by this bundle.
- Replacing it with a new, narrower current-public base usage estimator would be
  a new product decision and would need known-answer tests tied to S1-S4.
- Refreshing `last_verified` for the current Build/Pro owner is not defensible
  from this evidence.

Stage 1 made no production code edits.
