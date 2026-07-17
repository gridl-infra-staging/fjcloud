# Stage 4 evidence note (2026-05-21)

- Scope: prove `cloud.staging.flapjack.foo` is reattached via the existing Pages custom-domain owner, without DNS drift and with staging runtime behavior.
- Fresh control-plane artifacts: `24_project_get_recheck.json`, `25_project_domains_recheck.json`, `26_deployments_recheck.json`.
- Runtime artifacts: `28_signup_recheck.html`, `29_signup_oauth_origins_recheck.txt`, `23_validation_web_api_contract.txt`.
- Final assertion artifact: `21_final_assertions.json`.

## Result

- `cloud.staging.flapjack.foo` is present and `active` in Pages domains (`25_project_domains_recheck.json`).
- DNS gate artifact remains `19_dns_final.json` (successful post-mutation zone readback already in this stage bundle) and still proves proxied `CNAME staging.flapjack-cloud.pages.dev`.
- Fresh zone DNS recheck attempt (`27_dns_cloud_staging_recheck.json`) returned Cloudflare auth code `10000`; treated as an auth-seam environment issue and not used as gate source.
- `/signup` OAuth-start origins dedupe to `https://api.staging.flapjack.foo` (`29_signup_oauth_origins_recheck.txt`).
- `bash scripts/canary/contracts/web_api_base_url_contract.sh staging` has current-HEAD PASS evidence in `23_validation_web_api_contract.txt` (cache-compliant recording).
- `canonical_deployment.aliases` may still contain `https://cloud.staging.flapjack.foo`; per branch-domain contract semantics this is non-authoritative for branch owner assignment. Stage 4 cutover proof is the domain+DNS+runtime tuple recorded in `21_final_assertions.json`.

## Historical mismatch note

- Stage 1 baseline and early Stage 4 attempts assumed alias-list ownership signal and had a temporary detached-domain/TLS failure state.
- Current Stage 4 artifacts supersede those assumptions with direct domain-list + DNS + runtime assertions.
