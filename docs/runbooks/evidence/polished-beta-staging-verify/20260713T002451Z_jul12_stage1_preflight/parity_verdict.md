# Pages Parity Verdict

- Target source: `deploy_status_final.json` `.envs.staging.mirror_sha`
- Target mirror SHA: `a787e504ef65415543856887327ed7ba13fd08d0`
- Served `_app/version.json` SHA: `a787e504ef65415543856887327ed7ba13fd08d0`
- `wait_for_pages_parity.sh` exit: `0`
- `GITHUB_OUTPUT` ready: `true`
- Cloudflare alias: `https://cloud.staging.flapjack.foo`

Verdict: green.

The Pages target is the converged staging `mirror_sha` from `deploy_status_final.json`, not the dev `origin/main` SHA. This explicitly avoids the 20260712 target-mismatch failure mode where the API `/version.dev_sha` was used as the Pages served-byte target even though Cloudflare Pages records the staging mirror commit hash.
