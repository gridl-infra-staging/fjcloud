# Stage 4 Revocation Closeout Matrix

- baseline_bundle: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline/
- stage4_bundle: docs/runbooks/evidence/stripe-revocation/20260520T223952Z_closeout/
- closeout_generated_at_utc: 2026-05-20T22:43:55Z

| target_id | stage3_dashboard_artifact | stage4_runtime_artifact | verification_terminus_used | verdict |
|---|---|---|---|---|
| publishable_key | 20260520T205457Z_baseline/03_publishable_key_dashboard_note.md + 03_dashboard_revocations.md (`publishable_key_conflict_blocked`) | 04_ssm_runtime_snapshot.md (runtime key still `pk_live_...A1PYb`, no distinct superseded row proven) | Dashboard row-state only (required; no authenticated dashboard row evidence available) | BLOCKED (`publishable_key_conflict_blocked`) |
| prod_webhook_secret | 20260520T205457Z_baseline/03_prod_webhook_secret_dashboard_note.md + 03_dashboard_revocations.md (`prod_webhook_secret_deferred`) | 04_prod_webhook_continuity.md (`status":200`, failure strings absent) | Requires both dashboard revoked-state and live continuity proof | PARTIAL (continuity PASS, dashboard revoked-state still DEFERRED) |
| staging_rWUzL | 20260520T205457Z_baseline/03_staging_rWUzL_dashboard_note.md + 03_dashboard_revocations.md (`staging_rWUzL_deferred`) | 04_ssm_runtime_snapshot.md and 20260520T205457Z_baseline/02_old_staging_key_recoverability.md (`401_probe_unavailable`) | Dashboard row-state only per recoverability owner (`401_probe_unavailable`) | DEFERRED (dashboard row-state evidence still pending) |

## Outcome

- lane_verdict: BLOCKED
- reason: Stage 3 dashboard-state outcomes remain unresolved for all contract targets (`publishable_key_conflict_blocked`, `prod_webhook_secret_deferred`, `staging_rWUzL_deferred`), so Stage 4 cannot close GREEN.
