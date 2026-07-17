# Stage 3 Revocation Ready Packet

- bundle_owner: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline/
- scope_owner: CONTRACT.md:20-81
- targets_owner: 02_dashboard_targets.md
- staging_gate_owner: 02_staging_24h_gate.md
- recoverability_owner: 02_old_staging_key_recoverability.md
- action_order_owner: chats/icg/may19_pm_3_stripe_key_rotation_and_audit_operator_followup.md:8-10

## Candidate Targets

| stable_target_id | candidate_identifier | stripe_dashboard_surface | required_evidence_shape | stage4_verification_terminus | stage3_readiness |
|---|---|---|---|---|---|
| publishable_key | pk_live_...A1PYb | Stripe Dashboard -> Developers -> API keys (Live) | Distinct superseded row identifier with suffix-safe match and revoked/rolled state proof | Dashboard row-state only (not API auth) | conflict_blocked unless dashboard proves a distinct superseded row separate from runtime-active suffix in 02_ssm_runtime_snapshot.md |
| prod_webhook_secret | whsec_...sting | Stripe Dashboard -> Developers -> Webhooks -> endpoint signing secrets history (Live) | Suffix-safe dashboard state evidence plus action-log note with exact endpoint surface | Dashboard state plus fresh webhook continuity check in Stage 4 | ready_for_operator_dashboard_action |
| staging_rWUzL | ...rWUzL | Stripe Dashboard -> Developers -> API keys -> Restricted keys (Live) | Suffix-safe row match and revoked/deferred evidence in append-only action log | Dashboard row-state only, because 02_old_staging_key_recoverability.md recorded 401_probe_unavailable | gate_passed_for_rWUzL_revoke from 02_staging_24h_gate.md |

## Required Stage 2 Guardrails Carried Forward

- Publishable key guard: do not revoke based on suffix alone. If Stripe Dashboard cannot prove a distinct superseded `pk_live_...A1PYb` row separate from the runtime-active suffix in `02_ssm_runtime_snapshot.md`, outcome must remain `publishable_key_conflict_blocked`.
- Current prod `stripe_secret_key` is explicitly out of revoke scope and must remain untouched.

## Mandatory Action Order (Owned by Follow-up Chat)

Per `chats/icg/may19_pm_3_stripe_key_rotation_and_audit_operator_followup.md:8-10`, the operator order remains:
1. publishable key first
2. prod webhook signing secret second
3. staging suffix `...rWUzL` last

Order annotation with current Stage 2 gate state:
- `02_staging_24h_gate.md` records `gate_passed_for_rWUzL_revoke`.
- `02_old_staging_key_recoverability.md` records `401_probe_unavailable`.
- Stage 4 must therefore close staging revocation by dashboard row-state evidence rather than a post-revoke API 401 probe.
