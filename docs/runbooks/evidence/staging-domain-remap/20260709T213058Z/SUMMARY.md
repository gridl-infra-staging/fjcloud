# Staging Domain Remap Stage 1 Evidence — 20260709T213058Z

## Purpose

Read-only before-state evidence for the staging-domain-remap gate. This bundle treats served content as authoritative and Cloudflare Pages metadata as explanatory only.

## Command Index

- `FJCLOUD_SECRET_FILE=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret bash scripts/probe_live_state.sh`
  - Live-state source bundle: `docs/live-state/20260709T212731Z/`.
  - Checked files: `SUMMARY.md`, `manifest.txt`, `cloudflare_pages.txt`, `cf_accounts.json`, `cf_pages_projects.json`, `cf_pages_project_flapjack_cloud.json`.
- `curl -sS -L --max-time 30 https://cloud.flapjack.foo/pricing`
  - Raw files: `prod_pricing.curl.txt`, `prod_pricing.headers.txt`, `prod_pricing.body.html`, `prod_pricing.head.html`.
- `curl -sS -L --max-time 30 https://cloud.staging.flapjack.foo/pricing`
  - Raw files: `staging_pricing.curl.txt`, `staging_pricing.headers.txt`, `staging_pricing.body.html`, `staging_pricing.head.html`.
- Broad content checks for `Get Started Free` and `/signup`:
  - Raw file: `pricing_broad_grep.txt`.
- Pricing-main CTA-specific check scoped to `data-testid="pricing-page-main"`:
  - Raw file: `pricing_main_cta_check.txt`.
- `curl -sS -L --max-time 30 https://cloud.flapjack.foo/_app/version.json`
  - Raw files: `prod_version.curl.txt`, `prod_version.headers.txt`, `prod_version.body.json`.
- `curl -sS -L --max-time 30 https://cloud.staging.flapjack.foo/_app/version.json`
  - Raw files: `staging_version.curl.txt`, `staging_version.headers.txt`, `staging_version.body.json`.
- Cloudflare read-only API probes using `X-Auth-Email` and `X-Auth-Key` sourced only from `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`:
  - `GET /client/v4/accounts`: `cf_accounts.curl.txt`, `cf_accounts.headers.txt`, `cf_accounts.redacted.json`, `cf_account_resolution.txt`.
  - `GET /accounts/{acct}/pages/projects/flapjack-cloud/deployments?per_page=10`: `cf_pages_deployments.curl.txt`, `cf_pages_deployments.headers.txt`, `cf_pages_deployments.redacted.json`, `cf_pages_deployments_summary.tsv`.
  - `GET /accounts/{acct}/pages/projects/flapjack-cloud/domains/cloud.staging.flapjack.foo`: `cf_pages_staging_domain.curl.txt`, `cf_pages_staging_domain.headers.txt`, `cf_pages_staging_domain.redacted.json`, `cf_pages_staging_domain_summary.json`.

## Evidence Summary

- The refreshed live-state bundle is `docs/live-state/20260709T212731Z/`; its `SUMMARY.md` reports `cloudflare_pages` as OK, and its `manifest.txt` includes `cloudflare_pages.txt`, `cf_accounts.json`, `cf_pages_projects.json`, and `cf_pages_project_flapjack_cloud.json`.
- Both pricing captures returned HTTP 200: see `prod_pricing.curl.txt` and `staging_pricing.curl.txt`.
- Production pricing HTML contains the pricing-main signup CTA: `pricing_main_cta_check.txt` reports one `./signup` anchor in `data-testid="pricing-page-main"` with label `Get Started Free`.
- Staging pricing HTML does not contain the pricing-main signup CTA: `pricing_main_cta_check.txt` reports zero signup anchors in `data-testid="pricing-page-main"`. `pricing_broad_grep.txt` also shows no `Get Started Free` or `/signup` hit for `staging_pricing`.
- The source-of-truth CTA owner is `web/src/lib/pricing.ts` (`MARKETING_PRICING.cta_label = 'Get Started Free'`) rendered by `web/src/routes/pricing/+page.svelte` inside the pricing main CTA. The shared nav signup link in `web/src/routes/+layout.svelte` is intentionally not enough to prove pricing parity.
- Both `_app/version.json` endpoints returned HTTP 200 and valid JSON, but they are not comparable for parity today: production served `{"version":"1783627077589"}` and staging served `{"version":"1783556911547"}`. The owner config in `web/svelte.config.js` intends `CF_PAGES_COMMIT_SHA` with a local `Date.now()` fallback; these served numeric markers look like fallback timestamps, not 40-character commit SHAs.
- Cloudflare metadata for `flapjack-cloud` reports newest deployment `76349ef5-d192-4bcf-b1f3-1fc9d8e1c920`, branch `main`, status `success`, created `2026-07-09T19:58:16.558352Z`, URL `https://76349ef5.flapjack-cloud.pages.dev`; aliases include both `https://cloud.flapjack.foo` and `https://cloud.staging.flapjack.foo`.
- Cloudflare domain metadata for `cloud.staging.flapjack.foo` reports status `active` and validation status `active`; it does not prove the staged alias serves the same HTML as production.

## Stage 1 Decision

Served content is the single source of truth for Stages 2-5. The Cloudflare Pages metadata is useful for explaining which deployment and aliases Cloudflare believes are active, but it cannot close readiness because the metadata-aligned alias still serves stale staging HTML without the pricing-main signup CTA.

`_app/version.json` is present and stable enough to fetch from both hosts, but it is not trustworthy enough to lead Stage 3 yet. The markers are numeric fallback values rather than `CF_PAGES_COMMIT_SHA` commit hashes, and they differ while the Cloudflare deployment metadata reports both aliases on the same latest deployment. Stage 3 should therefore use pricing CTA content as the primary readiness signal until a later stage proves commit-SHA markers are actually served on both hosts.

## Raw Files To Compare In Stages 2-5

- Primary served-content parity files: `prod_pricing.body.html`, `staging_pricing.body.html`, `pricing_main_cta_check.txt`, `pricing_broad_grep.txt`.
- Secondary marker files: `prod_version.body.json`, `staging_version.body.json`.
- Explanatory Cloudflare metadata files: `cf_pages_deployments.redacted.json`, `cf_pages_deployments_summary.tsv`, `cf_pages_staging_domain.redacted.json`, `cf_pages_staging_domain_summary.json`.
- Live-state reference files: `docs/live-state/20260709T212731Z/SUMMARY.md`, `docs/live-state/20260709T212731Z/manifest.txt`, `docs/live-state/20260709T212731Z/cloudflare_pages.txt`, `docs/live-state/20260709T212731Z/cf_accounts.json`, `docs/live-state/20260709T212731Z/cf_pages_projects.json`, `docs/live-state/20260709T212731Z/cf_pages_project_flapjack_cloud.json`.

## Open Questions

- Why does Cloudflare Pages serve numeric `_app/version.json` values instead of the intended `CF_PAGES_COMMIT_SHA` value from `web/svelte.config.js`?
- Why does `cloud.staging.flapjack.foo` serve stale pricing HTML even though Cloudflare deployment metadata lists both production and staging aliases on the latest successful deployment?
