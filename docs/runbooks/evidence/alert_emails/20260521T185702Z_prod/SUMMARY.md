# Alert Emails Lane Closeout Summary — 20260521T185702Z_prod

## Closeout posture (partial closeout, supervisor-authorized)

This bundle is the Stage 5 audit closeout artifact for the alert-emails lane.
It is **partially closed** under supervisor authorization documented in
`SUPERVISOR_PARTIAL_CLOSEOUT_AUTHORIZATION.md` (2026-05-22T03:40Z). The strict
set-equality gate remains red (2 stale PendingConfirmation endpoints on the live
topic beyond canonical `prod_inputs.json`), but the SNS publish probe was
executed successfully and the confirmed recipient received the probe message.

## Proof chain captured in this bundle

- Staging evidence root: `docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/`
- Prod evidence root: `docs/runbooks/evidence/alert_emails/20260521T185702Z_prod/`
- Saved gate states used as canonical truth:
  - `stage2_status.txt` = `verification_passed`
  - `stage3_status.txt` = `done`
  - `prod_scope_check.txt` includes `scope_gate_result=PASS`
  - `stage4_status.txt` = `partial_closeout_authorized`
  - `stage4_verification_summary.txt` includes `set_equality_gate_result=FAIL` and
    `pending_confirmation_gate_result=PASS`
- Publish evidence in `stage4_verification_summary.txt` and saved artifacts:
  - `probe_publish_state=EXECUTED_SUPERVISOR_AUTHORIZED`
  - `probe_message_id=6fbf2f5c-5ad8-503d-9c29-4dd650a900da`
  - `probe_publish_json_file=docs/runbooks/evidence/alert_emails/20260521T185702Z_prod/prod_publish.json`
  - `probe_authorization=docs/runbooks/evidence/alert_emails/20260521T185702Z_prod/SUPERVISOR_PARTIAL_CLOSEOUT_AUTHORIZATION.md`
  - `confirmed_recipient_endpoint_map=stuart.clifford@gmail.com -> arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod:a5652566-d817-47c3-8e08-f2195e87cd80 -> MessageId:6fbf2f5c-5ad8-503d-9c29-4dd650a900da`

## Canonical input to observed-state mapping (saved files only)

- Staging canonical input:
  - Input file: `docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/staging_inputs.json`
  - Final observed snapshots: `stage2_subscriptions_poll_12.json` and
    `stage2_live_endpoints_poll_12.txt`
  - Gate summary: `stage2_verification_summary.txt` reports
    `set_equality_gate_result=PASS` and `pending_confirmation_gate_result=PASS`
  - Publish evidence: no staged publish `MessageId` artifact is present in this bundle;
    Stage 2 verification is represented by the saved endpoint/subscription polls and
    summary gate outputs.

- Prod canonical input:
  - Input file: `docs/runbooks/evidence/alert_emails/20260521T175914Z_staging/prod_inputs.json`
  - Final observed snapshot: `docs/runbooks/evidence/alert_emails/20260521T185702Z_prod/prod_subscriptions_poll_5.json`
  - Final endpoint lists:
    - Expected: `prod_expected_endpoints_final.txt`
    - Live: `prod_live_endpoints_final.txt`
    - Pending intended: `prod_pending_intended_endpoints_final.txt`
  - Gate summary: `stage4_verification_summary.txt` shows `set_equality_gate_result=FAIL`
    (advisory under supervisor authorization) and `pending_confirmation_gate_result=PASS`;
    publish probe was executed with `MessageId=6fbf2f5c-5ad8-503d-9c29-4dd650a900da`.

## Remaining follow-up proven by final probes

- Saved prod evidence shows a strict set mismatch between canonical `prod_inputs.json`
  and live prod endpoints (`prod_live_endpoints_final.txt` includes extra recipients:
  `clifford.kriv@gmail.com` and `stacy.saunders.2002@gmail.com`, both PendingConfirmation).
- Per `SUPERVISOR_PARTIAL_CLOSEOUT_AUTHORIZATION.md` (2026-05-22T03:40Z), set-equality
  is treated as advisory; the 2 extra endpoints are not terraform-managed, cannot be
  API-removed, and auto-expire in ~3 days.
- The publish probe was executed under supervisor authorization:
  `MessageId=6fbf2f5c-5ad8-503d-9c29-4dd650a900da` saved in `prod_publish.json`.
- The confirmed recipient (`stuart.clifford@gmail.com`) received the probe message.

## Verifier semantics

- Stage 5 uses saved artifact truth and does not rerun Terraform, AWS queries, or
  mutate infra state.
- Equality remains strict; no invariant was weakened to force a green closeout.

## What this lane proves

- The saved staging lane artifacts are internally consistent and green.
- The saved prod scope gate (`prod_scope_check.txt`) passed for the alert-subscription seam.
- The saved prod verification gates preserve strict equality logic and correctly fail closed.

## What this lane does not prove

- It does not prove a green prod recipient-set equality state (strict set-equality
  remains FAIL due to 2 stale PendingConfirmation endpoints; treated as advisory
  per supervisor authorization).

## What this lane now proves (under supervisor authorization)

- A successful prod publish probe with `MessageId=6fbf2f5c-5ad8-503d-9c29-4dd650a900da`.
- The confirmed recipient `stuart.clifford@gmail.com` is mapped to the probe via
  subscription ARN `arn:aws:sns:us-east-1:213880904778:fjcloud-alerts-prod:a5652566-d817-47c3-8e08-f2195e87cd80`.
- Partial closeout is authorized per `SUPERVISOR_PARTIAL_CLOSEOUT_AUTHORIZATION.md`.
