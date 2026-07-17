# Stage 2 Item 1 Deliverable: Preview Env Merge Patch (20260521T173423Z)

## Scope
- Updated only `deployment_configs.preview.env_vars` on Cloudflare Pages project `flapjack-cloud`.
- No production env mutation intended; validated unchanged by structured diff.
- No app-code changes; runtime owner remains `web/src/lib/config.ts::getApiBaseUrl` and existing login/signup loads.
- No deploy attempt; live /signup behavior is expected to remain unchanged until Stage 3 publishes a fresh staging preview deployment.

## Commands run
- Pre-patch readback: Cloudflare Pages GET project.
- Red-state contract: `scripts/canary/contracts/web_api_base_url_contract.sh staging`.
- Secret source chain probe: `aws sts get-caller-identity` and `ops/scripts/lib/generate_ssm_env.sh staging`.
- Patch: Cloudflare Pages PATCH (preview env merge only) then post-patch GET.
- Assertions: `raw/assertions_stage2_preview_patch.py`.

## Results
1. Pre-patch readback captured under `raw/cf_pages_project_pre_patch.json` and env extracts.
2. Staging contract remained FAIL pre-patch as expected before Stage 3 redeploy.
3. AWS credential probe failed (invalid security token), so staging SSM secret material could not be read in this session.
4. Preview env map patched by merge with secret keys preserved as secret_text entries from live readback, and API/base env corrected:
   - `API_BASE_URL` => `https://api.staging.flapjack.foo`
   - `ENVIRONMENT` => `staging`
5. Post-patch assertions passed:
   - preview map retained preexisting keys (including `WEB_DEV_LOG_RAW_ERRORS`)
   - expected value types preserved
   - production env map byte-for-byte unchanged from pre-patch snapshot.

## Artifact index
- Pre-patch GET: `raw/cf_pages_project_pre_patch.json`
- PATCH response: `raw/cf_pages_patch_response.json`
- Post-patch GET: `raw/cf_pages_project_post_patch.json`
- Preview/prod extracts: `raw/*_env_*_patch.json`
- Assertions: `raw/assertions_stage2_preview_patch.py`, `raw/assertions_stage2_preview_patch.txt`
- AWS probe evidence: `raw/aws_sts_get_caller_identity.err`, `raw/generate_ssm_env_staging.log`, `raw/ssm_probe_status.txt`
