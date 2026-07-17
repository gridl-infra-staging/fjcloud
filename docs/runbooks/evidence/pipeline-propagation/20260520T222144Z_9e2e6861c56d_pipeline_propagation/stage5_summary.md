# Stage 5 Live Prod Proof Summary

Closes the may20_3pm_2_pipeline_propagation lane by proving the prod API is
reachable and is running the exact prod mirror SHA frozen in Stage 4.

## Frozen identity inputs

- Stage 2 frozen candidate dev SHA: `9e2e6861c56d4598587538099953086d2604ea93`
- Stage 4 frozen prod mirror SHA:   `3f4370ff52acf7a96e989a949eeb9dbc64169569`
- Stage 4 effective dev SHA after IAM-reconcile delta: `8599b33a41d32f9fba662b47e1bd747ee51dbde8`
- Stage 4 prod CI run: [`26201800954`](https://github.com/gridl-infra-prod/fjcloud/actions/runs/26201800954)
  — all 8 required gates `success`, deploy-prod success at 2026-05-21T03:49:59Z.

## Liveness verdict — `infra/api/src/routes/health.rs` owner

- `GET https://api.flapjack.foo/health` → HTTP 200, body `{"status":"ok"}`
- Evidence: [stage5_health_probe.txt](stage5_health_probe.txt)

## Identity verdict — `infra/api/src/routes/version.rs` + `route_assembly.rs` owner

- `GET https://api.flapjack.foo/version` → HTTP 200
  - `mirror_sha`  = `3f4370ff52acf7a96e989a949eeb9dbc64169569`
  - `dev_sha`     = `8599b33a41d32f9fba662b47e1bd747ee51dbde8`
  - `synced_at`   = `2026-05-21T02:26:59Z`
  - `build_time`  = `2026-05-21T03:33:55Z`
- Evidence: [stage5_version_probe.txt](stage5_version_probe.txt)

### SHA match table

| Contract | Frozen value | Live value | Verdict |
| --- | --- | --- | --- |
| Prod mirror SHA | `3f4370ff…64169569` (Stage 4) | `3f4370ff…64169569` | MATCH |
| `dev_sha` ↔ mirror manifest at `3f4370ff` | `8599b33a…51dbde8` (per `.debbie/sync_manifest.json` at that commit) | `8599b33a…51dbde8` | MATCH |
| `dev_sha` live ↔ Stage 2 frozen candidate | `9e2e6861…04ea93` (Stage 2 freeze) | `8599b33a…51dbde8` | DELTA — expected; this is the IAM reconcile commit pushed during Stage 4 to unblock `deploy-prod`. The mirror SHA `3f4370ff` is the post-reconcile republish; that SHA — not the Stage 2 freeze — is the artifact Stage 4 proved green and that this stage verifies live. See [stage4_prod_summary.md](stage4_prod_summary.md) "Failed-to-Green Delta". |

Full SHA-by-SHA verification at [stage5_sha_verification.txt](stage5_sha_verification.txt).

## Closeout

The propagation contract frozen by Stage 1 — "publish one exact candidate, prove
that exact candidate live" — is not satisfied because the live `dev_sha`
`8599b33a41d32f9fba662b47e1bd747ee51dbde8` differs from the Stage 2 frozen candidate `9e2e6861c56d4598587538099953086d2604ea93`.
This bundle closes out live proof for prod mirror SHA `3f4370ff52acf7a96e989a949eeb9dbc64169569`; the frozen-candidate mismatch remains a deferred follow-up from Stage 4's republish.

No new source of truth introduced. `infra/api/src/routes/health.rs` and
`infra/api/src/routes/version.rs` remain the canonical owners; this bundle is
closeout evidence only.

## Files in this stage

- [stage5_health_probe.txt](stage5_health_probe.txt) — live `/health` probe
- [stage5_version_probe.txt](stage5_version_probe.txt) — live `/version` probe
- [stage5_sha_verification.txt](stage5_sha_verification.txt) — SHA cross-check
- [stage5_summary.md](stage5_summary.md) — this file
