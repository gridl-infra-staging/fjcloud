Stage 1 deploy owners re-read before execution:
- stages.md: Stage 1 is deploy parity only before browser proof.
- chats/icg/jul07_pm_8_polished_beta_staging_verify_rerun6.md: Stage 1 owns debbie sync, API /version parity, and manual Cloudflare Pages parity from the staging mirror.
- .debbie.toml: staging mirror path is /Users/stuart/repos/gridl-infra-staging/fjcloud; downstream is wrangler-manual.
- .debbie/post-sync.sh: post-sync strips scrai docs, commits, and pushes mirror changes.
- .github/workflows/ci.yml: deploy-staging triggers API deploy; e2e-deployed waits on Pages parity before browser proof.
- web/package.json: web build command is npm run build.
- web/wrangler.toml: Pages project is flapjack-cloud, output is .svelte-kit/cloudflare.
