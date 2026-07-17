# Meilisearch Pricing Evidence Artifact Index

> **Post-hoc hygiene note (2026-07-07):** the `raw/` payload tree referenced below was
> removed from the repo after capture. The scraped third-party page bodies embedded
> Meilisearch's public frontend tokens (docs-search/analytics keys), which trip the
> staging secret-scan gate. The processed evidence (SUMMARY.md, COMMANDS.md, this
> index) remains authoritative; re-run COMMANDS.md to regenerate raw bodies locally.


PURPOSE: Map each Stage 1 evidence requirement to raw files in this bundle.

Bundle: `docs/runbooks/evidence/competitor-pricing/20260707T172320Z_meilisearch/`

## Primary Captures

| Artifact | Source | Result |
| --- | --- | --- |
| `raw/http/pricing_meta`, `raw/http/pricing_headers`, `raw/http/pricing_body` | `https://www.meilisearch.com/pricing` | HTTP 200 on 2026-07-07T17:24:14Z; final URL stayed `/pricing`; HTML body saved. |
| `raw/http/usage_based_meta`, `raw/http/usage_based_headers`, `raw/http/usage_based_body` | `https://www.meilisearch.com/usage-based` | HTTP 200 on 2026-07-07T17:24:15Z; final URL was `/pricing`; legacy owner URL no longer returns a distinct usage-based rate card. |
| `raw/http/pricing_platform_meta`, `raw/http/pricing_platform_headers`, `raw/http/pricing_platform_body` | `https://www.meilisearch.com/pricing/platform` | HTTP 200 on 2026-07-07T17:25:36Z; final URL was `/pricing`; legacy resource URL also resolves to the current pricing page. |

## Public Legacy, Docs, and KB Probes

| Artifact | Source | Result |
| --- | --- | --- |
| `raw/http/docs_cloud_billing_*` | `https://www.meilisearch.com/docs/learn/cloud/billing` | HTTP 404 on 2026-07-07T17:25:36Z. |
| `raw/http/docs_cloud_usage_based_*` | `https://www.meilisearch.com/docs/learn/cloud/usage_based_billing` | HTTP 404 on 2026-07-07T17:25:37Z. |
| `raw/http/docs_cloud_plan_limits_*` | `https://www.meilisearch.com/docs/learn/cloud/plan_limits` | HTTP 404 on 2026-07-07T17:25:38Z. |
| `raw/http/blog_algolia_pricing_*` | `https://www.meilisearch.com/blog/algolia-pricing` | HTTP 200 on 2026-07-07T17:25:38Z; captured as non-canonical public marketing context, not as the current rate-card authority. |
| `raw/http/blog_typesense_pricing_*` | `https://www.meilisearch.com/blog/typesense-pricing` | HTTP 200 on 2026-07-07T17:25:40Z; captured as non-canonical public marketing context, not as the current rate-card authority. |
| `raw/http/llms_*`, `raw/probes/llms_pricing_probe` | `https://www.meilisearch.com/llms.txt` | HTTP 200 on 2026-07-07T17:25:42Z; pricing guidance points to `/pricing`. |

## Current Pricing Page Probes

| Artifact | Purpose | Result |
| --- | --- | --- |
| `raw/probes/pricing_text_extract` | Plain-text extraction from the current `/pricing` body. | Shows the current Cloud, estimator, usage-based, and resource-based page text. |
| `raw/probes/pricing_script_srcs` | Script URLs referenced by the pricing page. | Found 20 Next/Turbopack JS chunks. |
| `raw/payloads/chunks_manifest` and `raw/payloads/chunk_01_*` through `raw/payloads/chunk_20_*` | Raw JS chunk captures. | Preserves the current calculator code and embedded resource-region table. |
| `raw/probes/estimator_code_snippets` | Targeted extraction from `chunk_12_body`. | Captures current usage formula and resource calculator snippets. |
| `raw/probes/current_page_absence_note` | Required absence note for unrecovered Pro/rate-card evidence. | Lists terms and links probed; only current base usage formula evidence was recovered, not a Pro plan rate card. |
| `raw/probes/current_page_pro_plan_probe` | Broader current-page probe for old owner terms. | Confirms current page/chunks do not expose the old Build/Pro table as a current public rate card. |

## Public Payload and API Probes

| Artifact | Source | Result |
| --- | --- | --- |
| `raw/payloads/next_pricing_json_*` | `/_next/data/zbApzq17l_zJnw03fCNUL/pricing.json` | HTTP 404 on 2026-07-07T17:28:06Z. |
| `raw/payloads/api_pricing_*` | `/api/pricing` | HTTP 404 on 2026-07-07T17:28:06Z. |
| `raw/payloads/api_pricing_calculator_*` | `/api/pricing/calculator` | HTTP 404 on 2026-07-07T17:28:06Z. |
| `raw/payloads/pricing_json_*` | `/pricing.json` | HTTP 404 on 2026-07-07T17:28:06Z. |
| `raw/payloads/pricing_data_json_*` | `/pricing/data.json` | HTTP 404 on 2026-07-07T17:28:07Z. |
| `raw/payloads/estimate_usage_request`, `raw/payloads/estimate_usage_meta`, `raw/payloads/estimate_usage_headers`, `raw/payloads/estimate_usage_body` | `/api/estimate-usage` POST | HTTP 200 on 2026-07-07T17:28:21Z; returns estimated slider inputs, not a rate card. |
| `raw/probes/xhr_payload_probe` | XHR/API search and guessed endpoint result log. | Records JS-discovered `/api/estimate-usage` and the 404 results for guessed pricing data endpoints. |

## Archive.org Corroboration

| Artifact | Source | Result |
| --- | --- | --- |
| `raw/archive/pricing_cdx_*` | Archive.org CDX query for `/pricing`, 2026-03-01 through 2026-07-07. | HTTP 200 on 2026-07-07T17:26:38Z; lists 9 collapsed 200 captures. |
| `raw/archive/snapshots_manifest` | Snapshot timestamps from the CDX result. | Lists 20260309122639, 20260319040003, 20260320212215, 20260401152105, 20260416142505, 20260506161533, 20260605225323, 20260608054859, and 20260615100855. |
| `raw/archive/snapshot_<timestamp>_*` | Raw archived snapshot captures for each timestamp. | Preserves raw historical bodies, headers, and meta files. |
| `raw/archive/archive_timeline_probe_v2` | Token probe across archive snapshots. | Inconclusive for old Build/Pro rate-card disappearance; not used as a source for current pricing. |

## Written Deliverables

| Artifact | Purpose |
| --- | --- |
| `COMMANDS.md` | Reproducible fetch/probe command log. |
| `ARTIFACT_INDEX.md` | Index from checklist requirements to raw evidence files. |
| `SUMMARY.md` | Stage 1 findings, source-backed facts, gap spec, binary disposition, and Stage 2 handoff. |
