# Stage 1 Item 1 Deliverable: Pages and DNS Baseline (2026-05-21T17:10:11Z)

## Scope
- Stage contract and risk hypothesis: `stages.md:1-2` and `docs/NOW.md:15-21`.
- Live read-only probes only. No Cloudflare or AWS mutation commands.

## Sources consulted
- `stages.md:1-2`
- `docs/NOW.md:15-21`
- `ops/runbooks/site_takedown_20260503/restore.sh:16-21` (Cloudflare auth and header seam)
- `docs/runbooks/staging_dns_contract.md:9-19` (staging DNS owner contract)
- `scripts/canary/contracts/web_api_base_url_contract.sh:19-29,99-111` (OAuth href contract)

## Evidence bundle
- Raw artifacts are under `raw/` in this directory.
- Key extracted snapshot is `raw/cf_pages_extracted_fields.json`.

## Findings
1. Hypothesis is supported. Staging web is still cross-environment.
- Evidence: `raw/canary_web_api_base_url_staging.txt` reports FAIL with observed API origin `https://api.flapjack.foo` and expected `https://api.staging.flapjack.foo`.
- Evidence: `raw/staging_signup_oauth_hrefs.txt` shows both OAuth start links pointing to prod API.
- Counter-check: `raw/canary_web_api_base_url_prod.txt` passes for prod.

2. `cloud.staging.flapjack.foo` is active on `flapjack-cloud`, and current aliasing still binds that host with production routing state.
- Evidence: `raw/cf_pages_domains.json` includes active `cloud.staging.flapjack.foo`.
- Evidence: `raw/cf_pages_deployments.json` shows the latest production deployment aliases include `https://cloud.staging.flapjack.foo`.

3. Pages preview env map is drifted.
- Evidence: `raw/cf_pages_project.json` and `raw/cf_pages_extracted_fields.json` show `deployment_configs.preview.env_vars.API_BASE_URL=https://api.flapjack.foo`.
- Evidence: production env map currently mirrors preview values, including `ENVIRONMENT=staging`.

4. Project mode indicators point to non Git ad hoc deployment flow, but `source.type` is null in readback.
- Evidence: `raw/cf_pages_project.json` has `source` unset.
- Evidence: deployments show `deployment_trigger.type=ad_hoc` and preview and prod deployments for branches `staging` and `main`.
- Interpretation: treat current mode as ad hoc or direct upload style until Cloudflare exposes non-null `source.type`.

5. DNS ownership contract alignment: Cloudflare zone readback matches Pages staging target. Public `dig +short CNAME` is empty due proxy behavior.
- Evidence: `raw/cf_zone_cloud_staging_dns.json` shows CNAME content `staging.flapjack-cloud.pages.dev` with `proxied=true`.
- Evidence: `raw/dig_cloud_staging_cname.txt` is empty, while `raw/dig_cloud_staging_resolution.txt` resolves edge IPs.

## Open questions
- Cloudflare API returns null `source.type`; verify in Stage 2 or Stage 3 whether this API surface omits the field for this project mode.
- `deployment_configs.production.env_vars.ENVIRONMENT=staging` looks suspicious; keep this as a scoped follow-on check without widening Stage 1 scope.
