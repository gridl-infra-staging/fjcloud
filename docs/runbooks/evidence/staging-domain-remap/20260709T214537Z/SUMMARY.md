# Staging Domain Remap Stage 2 Evidence - 20260709T214537Z

## Purpose

Stage 2 attempted to repair the existing `cloud.staging.flapjack.foo` Cloudflare Pages custom-domain attachment so staging serves the current `flapjack-cloud` pricing page. Served `/pricing` content is the readiness source of truth; Cloudflare metadata is explanatory only.

## Disposition

anti-stop gap: all executable remedies failed to make the final served-content gate pass.

There is no trustworthy proxy for staging while served `/pricing` is stale. Cloudflare Pages domain metadata reports the custom domain as active, and the zone purge API returned success, but the served-content gate still fails:

- `final_staging_pricing_cta_grep.txt`: `exit_code=1`, `result=fail` for `curl -sS -L --max-time 30 https://cloud.staging.flapjack.foo/pricing | grep -qE 'Get Started Free|href="/signup"|/signup'`.

## Stage 1 Pointer

- Stage 1 evidence bundle: `docs/runbooks/evidence/staging-domain-remap/20260709T213058Z/`.
- Stage 1 live-state bundle: `docs/live-state/20260709T212731Z/`.

## Pre-write Evidence

- Credentials were loaded only through `scripts/lib/env.sh::load_env_file` from `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`; values were not written to evidence.
- `prewrite_cf_accounts.http_code.txt`: account list returned HTTP 200.
- `prewrite_cf_account_resolution.txt`: resolved account id `99deba6554f68cb3544bd9ecfd08ff06`.
- `prewrite_cf_domain.http_code.txt`: domain readback returned HTTP 200.
- `prewrite_cf_domain.summary.json`: `cloud.staging.flapjack.foo` was `active`, validation `active`, zone tag `fafbf95a076d7e8ee984dbd18a62c933`.
- `prewrite_staging_pricing.http_code.txt`: served `/pricing` returned HTTP 200.
- `prewrite_staging_pricing_cta_grep.txt`: CTA grep failed before mutation, so no-write drift did not apply.

## Remedy #1 - Custom Domain Detach/Reattach

Executed the required in-place Pages custom-domain reattachment:

- DELETE request metadata: `remedy1_delete.request.txt`.
- DELETE response: `remedy1_delete.http_code.txt` HTTP 200, `remedy1_delete.redacted.json` success true.
- POST request metadata/body description: `remedy1_post.request.txt`.
- POST response: `remedy1_post.http_code.txt` HTTP 200, `remedy1_post.redacted.json` success true with status `initializing`.
- Poll evidence: `remedy1_poll.tsv`.
- Result: `remedy1_timeline.txt` records `poll_pass=0`; later polls returned HTTP 200 but CTA grep exit 1.
- Outage observed: `remedy1_poll.tsv` attempts 1-10 returned curl exit 35 / HTTP 000 from `2026-07-09T21:47:01Z` through `2026-07-09T21:48:32Z`; the hostname recovered by attempt 11 at `2026-07-09T21:48:42Z` but still served stale content.

## Remedy #2 - Existing Pages Deploy

Not executable in this operator environment under the checklist's credential model:

- `remedy2_deploy_auth_presence.txt`: `CLOUDFLARE_API_TOKEN=absent` and `CLOUDFLARE_ACCOUNT_ID=absent` after loading the authorized secret file.
- Owner: `.github/workflows/ci.yml::deploy-staging` / `Deploy web to Cloudflare Pages`.
- Decision: did not run wrangler with the legacy global key and did not create a second deployer path.

## Remedy #3 - Host Cache Purge

Executed the authorized zone purge for the staging hostname:

- Fresh domain readback: `remedy3_pre_purge_domain.http_code.txt` HTTP 200 and `remedy3_pre_purge_domain.summary.json` status `active`, validation `active`, verification `active`, zone tag `fafbf95a076d7e8ee984dbd18a62c933`.
- Purge request metadata/body: `remedy3_purge.request.txt`, `remedy3_purge.request_body.json`.
- Purge response: `remedy3_purge.http_code.txt` HTTP 200, `remedy3_purge.redacted.json` success true.
- Poll evidence: `remedy3_poll.tsv`.
- Result: `remedy3_timeline.txt` records `poll_pass=0`; every poll returned HTTP 200 with CTA grep exit 1.

## Smallest Remaining Unblocker

Provide or execute the existing Pages deploy credential model owned by `.github/workflows/ci.yml::deploy-staging`: `CLOUDFLARE_API_TOKEN` plus `CLOUDFLARE_ACCOUNT_ID` for `wrangler pages deploy` against `flapjack-cloud`. Once that is available, rerun only the existing deploy path from `web/` (`npm ci`, `npm run build`, `npx --yes wrangler@4 pages deploy .svelte-kit/cloudflare --project-name=flapjack-cloud --branch=main --commit-hash="$GITHUB_SHA"`) and then require the exact served `/pricing` CTA grep to pass.
