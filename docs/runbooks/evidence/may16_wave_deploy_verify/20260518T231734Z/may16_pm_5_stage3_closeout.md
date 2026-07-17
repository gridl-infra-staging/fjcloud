# Stage 3 Closeout — Upgrade Trust-Ratchet (Staging)

- Final staging deploy SHA: `435f5e6dd8120d6aad3aa740725f630a4f7cd820`
- Final live probe transcript:
  - `docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/may16_pm_5_stage3.stdout`
  - `docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/may16_pm_5_stage3.stderr`
  - `docs/runbooks/evidence/may16_wave_deploy_verify/20260518T231734Z/may16_pm_5_stage3.exit`
- Final owner artifact bundle:
  - `docs/runbooks/evidence/browser-evidence/20260519T020552Z_upgrade_trust_ratchet/`

## Contract verdicts

- success_paid: pass
  - HTTP `200`
  - `billing_plan="shared"`
  - non-empty `subscription_cycle_anchor_at`
  - non-empty `stripe_invoice_id`
  - `post_upgrade_status.upgrade_ready=false`
  - `stripe_invoice.status="paid"`
- declined_402: pass
  - HTTP `402`
  - `upgrade_response.code="card_declined"`
  - `post_upgrade_status.upgrade_ready=true`
- requires_action_402: pass
  - HTTP `402`
  - `upgrade_response.code="invoice_payment_intent_requires_action"`
  - `post_upgrade_status.upgrade_ready=true`

## Owner seam fixes landed this stage

- `infra/api/src/stripe/live.rs`
  - Recover `Invoice::pay` JSON-serialize failures by returning a deterministic requires-action payment result (`invoice_payment_intent_requires_action`) instead of bubbling a 500.
  - Recover `Invoice::void` JSON-serialize failures in rollback paths to avoid masking retryable payment-required outcomes.
- `scripts/launch/capture_upgrade_trust_ratchet_evidence.sh`
  - Quote SUMMARY heredoc delimiter to prevent markdown backticks from executing as shell commands.
- `scripts/tests/capture_upgrade_trust_ratchet_evidence_test.sh`
  - Added regression assertion locking quoted SUMMARY heredoc behavior.
