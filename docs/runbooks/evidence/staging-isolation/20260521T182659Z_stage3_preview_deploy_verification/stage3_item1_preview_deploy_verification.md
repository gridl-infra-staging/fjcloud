# Stage 3 Item 1 Deliverable: Staging preview deploy verification

## Scope
- Captured Cloudflare Pages project/deployment readback after Stage 3 direct-upload publish path.
- Proved latest successful `staging` preview deployment metadata from Cloudflare API.
- Probed `https://staging.flapjack-cloud.pages.dev/signup` and asserted OAuth start links target staging API origin.
- Re-ran `bash scripts/canary/contracts/web_api_base_url_contract.sh staging` and captured PASS output.

## Results
1. Cloudflare deployment readback includes a latest successful `preview` deployment for branch `staging`.
2. `/signup` on Pages alias exposes Google/GitHub OAuth-start hrefs that both resolve to `https://api.staging.flapjack.foo`.
3. Contract canary for staging web/API origin mapping returns PASS.

## Artifact index
- Project readback: `raw/cf_pages_project_readback.json`
- Deployments readback: `raw/cf_pages_deployments_readback.json`
- Latest deployment (filtered): `raw/latest_staging_preview_deployment.json`
- Latest deployment summary: `raw/latest_staging_preview_deployment_summary.txt`
- Signup HTML probe: `raw/staging_pages_dev_signup.html`
- OAuth href extraction: `raw/staging_pages_dev_oauth_hrefs.txt`
- OAuth origin dedupe: `raw/staging_pages_dev_oauth_origins.txt`
- Signup assertions: `raw/assertions_stage3_preview_signup.txt`
- Contract rerun output: `raw/web_api_base_url_contract_staging.txt`
