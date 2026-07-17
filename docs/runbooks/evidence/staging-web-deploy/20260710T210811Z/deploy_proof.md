# Stage 2 Deploy Proof Summary

Source: `session_handoffs/stage_02/outcome_20260710T203851Z.md`.

Stage 2 manually deployed the current web build to the Cloudflare Pages `staging` branch
and proved the served staging surface refreshed:

- Verdict marker: `STAGING_REFRESHED_OK`.
- Pre-deploy staging marker: `1783556911547`.
- Post-deploy staging marker: `1783715879386`.
- `cloud.staging.flapjack.foo/pricing` returned the restored `Get Started Free` CTA.

The deploy command matched the existing CI/web owners: install and build from `web/`,
then `wrangler@4 pages deploy .svelte-kit/cloudflare --project-name=flapjack-cloud
--branch=staging --commit-hash="$(git rev-parse HEAD)"`. The served-byte proof reused
the same authoritative surface concept as `scripts/launch/wait_for_pages_parity.sh`.
