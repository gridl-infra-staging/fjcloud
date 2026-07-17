# Stage 1 — Polished Beta Staging Verify — Deploy Convergence Summary

## Classification

- **classification**: `parity_unconvergeable`
- **ready**: `false`
- **head_sha**: `c36e3e71bcc1f8ebc3578956fb8520fc9bf38eae`
- **mirror_sha**: `2d7b5189e892060a61d4b561a6eb2496cc9b8fce`

## Legs

### Control plane (API deploys — staging + prod)

- **status**: FAILED (never converged)
- Final `staging.commits_behind_main`: `36`
- Final `prod.commits_behind_main`: `174`
- Poll ran the full budget (40 attempts × 30s = 20 min). Deployed `dev_sha` never advanced.
- `debbie sync staging` and `debbie sync prod` both succeeded on attempt 1; the deploy pipeline did not rebuild/redeploy because public-mirror CI is red on the post-sync commits.
- **follow_up_stub**: `chats/icg/stubs/jun11_pm_9_parity_unconvergeable_control_plane_timeout.md`

### Web plane (manual Cloudflare Pages deploy)

- **status**: PASSED
- `wait_for_pages_parity.sh` reported `ready=true` (see `pages_parity.out`).
- Deployment commit-hash: `2d7b5189e892060a61d4b561a6eb2496cc9b8fce` (built from staging mirror HEAD).
- Alias verified: `https://cloud.staging.flapjack.foo`.

## Aggregate Verdict

Control leg failed even though the web leg passed, so the aggregate Stage 1 verdict is
`parity_unconvergeable`. Stage 2 (browser proof) MUST block on the control-plane stub until
public-mirror CI is green and the control plane reaches parity with `origin/main`.

## Disposition (single-use)

This verdict and its follow-up stub are single-use for this run. Wave 4 must NOT carry this
`parity_unconvergeable` result forward to any `LAUNCH.md` anchor — it is a per-run deploy-stage
observation, not a durable launch-readiness fact.
