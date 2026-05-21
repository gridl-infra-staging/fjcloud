# Stage 2 Dashboard Revocation Targets (Stage 3 input)

- captured_at_utc: 2026-05-20T21:41:30Z
- matrix_owner: CONTRACT.md:28-39
- followup_guardrail: chats/icg/may19_pm_3_stripe_key_rotation_and_audit_operator_followup.md:3-15
- runtime_cross_check_owner: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline/02_ssm_runtime_snapshot.md

## Candidate A: prod publishable key suffix from Stage 1 matrix
- identifier_candidate: pk_live_...A1PYb
- current_runtime_conflict: /fjcloud/prod/stripe_publishable_key currently redacts to pk_live...A1PYb in `02_ssm_runtime_snapshot.md`
- stage3_instruction: do NOT revoke `...A1PYb` based on suffix alone while runtime still resolves to the same suffix; first collect Stripe Dashboard proof that identifies a distinct superseded row, or explicitly remove this candidate from the revoke set.
- dashboard_surface_if_superseded: Stripe Dashboard -> Developers -> API keys (Live mode)
- evidence_shape_if_superseded: screenshot/export with row identifier + state=revoked/rolled + suffix match

## Candidate B: old prod webhook signing secret
- identifier: whsec_...sting
- dashboard_surface: Stripe Dashboard -> Developers -> Webhooks -> endpoint signing secrets history (Live)
- locator: suffix match ...sting on superseded secret entry
- stage3_expected_evidence_shape: dashboard state showing superseded/revoked, paired with continuity proof

## Explicit non-target
- current prod STRIPE_SECRET_KEY from /fjcloud/prod/stripe_secret_key remains active and is OUT of revoke scope.
