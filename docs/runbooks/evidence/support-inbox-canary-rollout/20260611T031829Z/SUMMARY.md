# Support Inbox + Synthetic Canary Rollout — Evidence Summary

## Provenance

| Field | Value |
| --- | --- |
| Target environment | staging |
| UTC timestamp | 20260611T031829Z |
| HEAD_SHA | 7e5db7f560177fd99358d7ba34810f5afa24a91e |
| ORIGIN_MAIN_SHA | 7e5db7f560177fd99358d7ba34810f5afa24a91e |
| Live-state baseline | docs/live-state/20260611T031830Z/ |
| Evidence bundle | docs/runbooks/evidence/support-inbox-canary-rollout/20260611T031829Z/ |

## Commands

All commands sourced from `commands.md` in this bundle. Project secret loader is the single owner of AWS auth; inherited AWS credential env vars were unset before each rerun.

| Lane | Command |
| --- | --- |
| Live-state baseline | `set -o pipefail; FJCLOUD_SECRET_FILE="$FJCLOUD_SECRET_FILE" bash scripts/probe_live_state.sh` |
| Support email deliverability | `set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && ENVIRONMENT=staging bash scripts/canary/support_email_deliverability.sh` |
| Canary live-state (staging) | `set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && bash scripts/probe_canary_live_state.sh staging --json` |
| Synthetic seeder dry-run | `set -o pipefail; bash scripts/launch/seed_synthetic_traffic.sh --tenant A --dry-run` |
| Post-lane canary guard | `set -o pipefail; source scripts/lib/env.sh && load_env_file "$FJCLOUD_SECRET_FILE" && bash scripts/probe_canary_live_state.sh staging --json` |

## Verdicts

| Lane | Exit code | Verdict | Detail |
| --- | --- | --- | --- |
| Canary live-state (staging) | 1 | blocked | READY=false; ALL_CHECKS_PASS=false; failed=errors_24h (1.0 errors in last 24h); alarms=pass; invocations_24h=pass |
| Support email deliverability | 0 | green | PASSED=true; AUTH_VERDICT_PASSED=true; no failed step |
| Synthetic seeder dry-run (tenant A) | 0 | green (non-mutating CLI evidence only) | Proves CLI parsing, tenant-definition loading, and safety-gate enforcement; does NOT prove live mutation or `usage_records` attribution |
| Post-lane canary guard (staging) | 1 | blocked | READY=false; ALL_CHECKS_PASS=false; failed=errors_24h; alarms=pass; matches Stage 2 baseline — lane did not regress canary |

## Final disposition

**blocked on canary** — Canary `errors_24h` fails at both Stage 2 baseline and post-lane reruns (1.0 error / 24h window against the staging customer-loop canary). Support-email deliverability is green. Synthetic seeder dry-run is green for the non-mutating CLI path only; live synthetic-traffic mutation and `usage_records` attribution proof remain open per `seed_synthetic_dry_run_disposition.env` and `docs/launch/synthetic_traffic_seeder_plan.md`. ROADMAP Platform Ledger status stays `Open seam` until canary `errors_24h` clears and the seeder execute-mode evidence is captured.
