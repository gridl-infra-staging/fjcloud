# Meilisearch Pricing Evidence Commands

PURPOSE: Preserve the reproducible fetch and probe commands used to build this
bundle. Commands were run from the repository root on 2026-07-07 UTC.

Bundle root:

```bash
BUNDLE=docs/runbooks/evidence/competitor-pricing/20260707T172320Z_meilisearch
mkdir -p "$BUNDLE/raw/http" "$BUNDLE/raw/probes" "$BUNDLE/raw/payloads" "$BUNDLE/raw/archive"
```

Primary pricing page:

```bash
curl -fsSL \
  -D "$BUNDLE/raw/http/pricing_headers" \
  -o "$BUNDLE/raw/http/pricing_body" \
  -w 'fetch_utc=%{time_starttransfer}\nsource_url=https://www.meilisearch.com/pricing\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n' \
  https://www.meilisearch.com/pricing > "$BUNDLE/raw/http/pricing_meta"
```

The recorded `fetch_utc` fields in this bundle were normalized to ISO-8601 UTC
using `date -u +"%Y-%m-%dT%H:%M:%SZ"` at fetch time.

Owner URLs and adjacent public URLs:

```bash
probe_url() {
  name="$1"
  url="$2"
  curl -sSL \
    -D "$BUNDLE/raw/http/${name}_headers" \
    -o "$BUNDLE/raw/http/${name}_body" \
    -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=$url\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
    "$url" > "$BUNDLE/raw/http/${name}_meta"
}

probe_url usage_based https://www.meilisearch.com/usage-based
probe_url pricing_platform https://www.meilisearch.com/pricing/platform
probe_url docs_cloud_billing https://www.meilisearch.com/docs/learn/cloud/billing
probe_url docs_cloud_usage_based https://www.meilisearch.com/docs/learn/cloud/usage_based_billing
probe_url docs_cloud_plan_limits https://www.meilisearch.com/docs/learn/cloud/plan_limits
probe_url blog_algolia_pricing https://www.meilisearch.com/blog/algolia-pricing
probe_url blog_typesense_pricing https://www.meilisearch.com/blog/typesense-pricing
probe_url llms https://www.meilisearch.com/llms.txt
```

Pricing page text, script, and chunk probes:

```bash
perl -0pe 's/<script/\n<script/g; s/<\/script>/<\/script>\n/g; s/<[^>]+>/\n/g; s/&nbsp;/ /g; s/&amp;/\&/g; s/[ \t]+/ /g; s/\n{2,}/\n/g' \
  "$BUNDLE/raw/http/pricing_body" > "$BUNDLE/raw/probes/pricing_text_extract"

rg -o 'src="[^"]+\.js"' "$BUNDLE/raw/http/pricing_body" \
  | sed 's/^src="//; s/"$//' \
  | sort -u > "$BUNDLE/raw/probes/pricing_script_srcs"

i=1
while IFS= read -r src; do
  url="https://www.meilisearch.com$src"
  name=$(printf 'chunk_%02d' "$i")
  printf '%s %s\n' "$name" "$url" >> "$BUNDLE/raw/payloads/chunks_manifest"
  curl -sSL -D "$BUNDLE/raw/payloads/${name}_headers" \
    -o "$BUNDLE/raw/payloads/${name}_body" \
    -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=$url\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
    "$url" > "$BUNDLE/raw/payloads/${name}_meta"
  i=$((i + 1))
done < "$BUNDLE/raw/probes/pricing_script_srcs"

rg -n 'docOverage|searchOverage|Base plan|Resource-based|cost/month|/api/estimate-usage|Additional storage|Bandwidth pricing' \
  "$BUNDLE/raw/payloads/chunk_12_body" > "$BUNDLE/raw/probes/estimator_code_snippets"

{
  printf 'Clean current-page Pro/rate-card absence probe run at %s UTC\n\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Normalized pricing text matches for old Pro/rate-card terms:\n'
  rg -n 'Build|Pro|\$300|1M|250K|\$0\.20|0\.20/1K|Pro plan|Build plan' "$BUNDLE/raw/probes/pricing_text_extract" || true
  printf '\nEstimator chunk controlled matches for usage formula terms:\n'
  rg -n 'docOverage|searchOverage|Base plan|Extra docs|Extra searches|Contact us' "$BUNDLE/raw/probes/estimator_code_snippets" || true
  printf '\nPricing page linked URLs with pricing/usage/billing/calculator/cloud terms:\n'
  rg -o 'href="[^"]+"' "$BUNDLE/raw/http/pricing_body" | sed 's/^href="//; s/"$//' | sort -u \
    | rg 'pricing|usage|billing|calculator|cloud|docs|blog|meet' || true
} > "$BUNDLE/raw/probes/current_page_absence_note"
```

Public JSON/API/XHR probes:

```bash
probe_payload() {
  name="$1"
  url="$2"
  curl -sSL -D "$BUNDLE/raw/payloads/${name}_headers" \
    -o "$BUNDLE/raw/payloads/${name}_body" \
    -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=$url\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
    "$url" > "$BUNDLE/raw/payloads/${name}_meta"
}

probe_payload next_pricing_json https://www.meilisearch.com/_next/data/zbApzq17l_zJnw03fCNUL/pricing.json
probe_payload api_pricing https://www.meilisearch.com/api/pricing
probe_payload api_pricing_calculator https://www.meilisearch.com/api/pricing/calculator
probe_payload pricing_json https://www.meilisearch.com/pricing.json
probe_payload pricing_data_json https://www.meilisearch.com/pricing/data.json

printf '{"description":"We run an ecommerce catalog with 100000 products and 50000 monthly searches."}' \
  > "$BUNDLE/raw/payloads/estimate_usage_request"
curl -sSL -X POST \
  -H 'content-type: application/json' \
  --data-binary "@$BUNDLE/raw/payloads/estimate_usage_request" \
  -D "$BUNDLE/raw/payloads/estimate_usage_headers" \
  -o "$BUNDLE/raw/payloads/estimate_usage_body" \
  -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=https://www.meilisearch.com/api/estimate-usage\nmethod=POST\nrequest_body_file=raw/payloads/estimate_usage_request\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
  https://www.meilisearch.com/api/estimate-usage > "$BUNDLE/raw/payloads/estimate_usage_meta"
```

Archive.org corroboration probe:

```bash
curl -sSL \
  -D "$BUNDLE/raw/archive/pricing_cdx_headers" \
  -o "$BUNDLE/raw/archive/pricing_cdx_body" \
  -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=https://web.archive.org/cdx?url=https://www.meilisearch.com/pricing&from=20260301&to=20260707&output=json&fl=timestamp,original,statuscode,mimetype,digest&filter=statuscode:200&collapse=digest\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
  'https://web.archive.org/cdx?url=https://www.meilisearch.com/pricing&from=20260301&to=20260707&output=json&fl=timestamp,original,statuscode,mimetype,digest&filter=statuscode:200&collapse=digest' \
  > "$BUNDLE/raw/archive/pricing_cdx_meta"

tail -n +2 "$BUNDLE/raw/archive/pricing_cdx_body" \
  | sed 's/[][]//g; s/"//g; s/,$//' \
  | awk -F, '{print $1}' > "$BUNDLE/raw/archive/snapshots_manifest"

while IFS= read -r ts; do
  url="https://web.archive.org/web/${ts}id_/https://www.meilisearch.com/pricing"
  curl -sSL -D "$BUNDLE/raw/archive/snapshot_${ts}_headers" \
    -o "$BUNDLE/raw/archive/snapshot_${ts}_body" \
    -w "fetch_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")\nsource_url=$url\nhttp_code=%{http_code}\nurl_effective=%{url_effective}\ncontent_type=%{content_type}\nsize_download=%{size_download}\n" \
    "$url" > "$BUNDLE/raw/archive/snapshot_${ts}_meta"
done < "$BUNDLE/raw/archive/snapshots_manifest"

for body in "$BUNDLE"/raw/archive/snapshot_*_body; do
  ts=$(basename "$body" | sed 's/snapshot_//; s/_body//')
  printf '## %s\n' "$ts"
  for term in Build Pro Dedicated 'Base plan' Usage-based Resource-based '50,000' '100,000' '250,000' '1,000,000' '$300' '$30' '$0.30' '$0.40' '$0.20' overage 'Cost Estimator' 'Starting at'; do
    if rg -q "$term" "$body"; then printf '%s: True\n' "$term"; else printf '%s: False\n' "$term"; fi
  done
  printf '\n'
done > "$BUNDLE/raw/archive/archive_timeline_probe_v2"
```
