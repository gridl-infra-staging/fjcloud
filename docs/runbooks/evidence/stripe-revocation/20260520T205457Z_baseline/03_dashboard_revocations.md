# Stage 3 Dashboard Revocation Action Log

- log_type: append_only
- bundle_owner: docs/runbooks/evidence/stripe-revocation/20260520T205457Z_baseline/
- created_at_utc: 2026-05-20T22:47:00Z
- prerequisite_packet: REVOCATION_READY.md

## Target Scope Lock

- in_scope_targets: publishable_key, prod_webhook_secret, staging_rWUzL
- explicit_non_target: current prod stripe_secret_key from 02_dashboard_targets.md remains active and out of scope
- unsuffixed_active_runtime_credentials_revoked: no

## Action Entries

### 2026-05-20T22:47:30Z publishable_key
- stable_target_id: publishable_key
- identifier: pk_live_...A1PYb
- dashboard_surface: Stripe Dashboard -> Developers -> API keys (Live)
- row_identifier_status: unresolved_without_authenticated_dashboard_session
- note_artifact: 03_publishable_key_dashboard_note.md
- decision: do_not_revoke_without_distinct_superseded_row_identity
outcome: publishable_key_conflict_blocked

### 2026-05-20T22:48:00Z prod_webhook_secret
- stable_target_id: prod_webhook_secret
- identifier: whsec_...sting
- dashboard_surface: Stripe Dashboard -> Developers -> Webhooks -> endpoint signing secrets history (Live)
- row_identifier_status: operator_dashboard_access_required
- note_artifact: 03_prod_webhook_secret_dashboard_note.md
- decision: deferred_pending_operator_visible_row_state
outcome: prod_webhook_secret_deferred

### 2026-05-20T22:48:30Z staging_rWUzL
- stable_target_id: staging_rWUzL
- identifier: ...rWUzL
- dashboard_surface: Stripe Dashboard staging key row for exact suffix
- gate_state_source: 02_staging_24h_gate.md (gate_passed_for_rWUzL_revoke)
- row_identifier_status: operator_dashboard_access_required
- note_artifact: 03_staging_rWUzL_dashboard_note.md
- decision: deferred_pending_operator_visible_row_state
outcome: staging_rWUzL_deferred

## Stage 4 Verification Handoff

- publishable_key (`pk_live_...A1PYb`): dashboard-only verification path; keep as dashboard state evidence and do not require API auth probe.
- prod_webhook_secret (`whsec_...sting`): requires dashboard state plus fresh webhook continuity verification after operator action.
- staging suffix (`...rWUzL`): dashboard-only verification path because `02_old_staging_key_recoverability.md` recorded `401_probe_unavailable`.
