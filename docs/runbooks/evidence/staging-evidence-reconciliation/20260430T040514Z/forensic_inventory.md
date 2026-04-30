# Forensic Inventory — Staging Evidence Reconciliation

## Purpose/scope
- UTC stamp: `20260430T040514Z`
- Stage: 1 of 5 (research-only)
- Purpose: establish a claim-by-claim forensic inventory of staging deploy/runtime assertions before any canonical status text is edited.
- Out-of-scope (explicit): no edits to `docs/runbooks/staging-evidence.md`, `PRIORITIES.md`, or `ROADMAP.md`; no launch go/no-go decision in Stage 1.

## Claim ledger table
| claim_id | claim text | source file | source date/context | implied status | existing proof artifacts (first) | contradiction class | owner command/script | pending-required probe command |
|---|---|---|---|---|---|---|---|---|
| CLM-001 | Staging is deployed/running (EC2 healthy, API responding, RDS connected, alarms OK). | `PRIORITIES.md` | lines 5, 41 (2026-04-29 update) | running | `docs/runbooks/staging-evidence.md`; `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/53_runtime_snapshot_recheck.txt` | ambiguous | `ops/scripts/deploy.sh` + runtime-health readback | `aws ssm get-parameter --name /fjcloud/staging/last_deploy_sha ...` + host `curl -sf http://127.0.0.1:3001/health` via SSM |
| CLM-002 | Launch remains blocked by preserved Stage 3 paid-beta RC verdict (`ready=false`, `verdict=fail`). | `PRIORITIES.md`, `ROADMAP.md`, `docs/runbooks/staging-evidence.md` | PR lines 5/43; RM lines 3-4; SE lines 409-410 | blocked | preserved artifact path embedded in sources; owner mapping in `docs/runbooks/staging-evidence.md` | confirmed | `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...` | rerun coordinator from current `main` and compare emitted `summary.json`/final verdict |
| CLM-003 | Staging alert lane has deployed-readiness PASS but persisted-send proof failed for selected invoice. | `docs/runbooks/staging-evidence.md` + alert evidence | Stage 2/3 alert bundle pointers | partial / failed | `docs/runbooks/evidence/alert-delivery/.current_bundle`; `.../08_stage2_readiness_gate.txt`; `.../15_stage3_verdict.txt` | confirmed | `scripts/probe_alert_delivery.sh` + webhook replay owner flow in bundle | create qualifying finalized invoice state, replay once, then verify `alerts.delivery_status='sent'` row exists |
| CLM-004 | Current deployed alert proof is Discord-only; Slack webhook in staging SSM is absent. | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md`; `ROADMAP.md` line 134 | Apr 29-30 operator note + roadmap status | partial coverage | `docs/runbooks/evidence/alert-delivery/20260429T191355Z_post_apr29_merge/SUMMARY.md` | confirmed | `scripts/probe_alert_delivery.sh --readback` | if Slack required, populate `/fjcloud/staging/slack_webhook_url` then rerun owner probe |
| CLM-005 | Billing paid lifecycle lane passed with `CROSS_CHECK_PASSED` at zero-cent tolerance. | `docs/runbooks/staging-evidence.md`, `PRIORITIES.md`, `ROADMAP.md` | SE paid-lifecycle section; PR line 111; RM line 111 | passed | `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/{SUMMARY.md,cross_check_result.json,CROSS_CHECK_RESULT.md}` | confirmed | `scripts/staging_billing_rehearsal.sh` | fresh current-main rerun for intended month/tenant using same owner script |
| CLM-006 | Billing readiness still requires fresh credentialed current-main rerun, despite earlier paid-lifecycle pass. | `PRIORITIES.md`, `ROADMAP.md` | PR lines 5/51; RM lines 95/112/137 | pending | same paid-lifecycle bundle + preserved RC artifact | confirmed | `scripts/launch/run_full_backend_validation.sh --paid-beta-rc ...` and `scripts/staging_billing_rehearsal.sh` | run both owners on current main and preserve new artifact bundle |
| CLM-007 | SES sender/domain setup is reconciled (`system@flapjack.foo`, DKIM success, SPF/MAIL FROM configured). | `docs/runbooks/staging-evidence.md` + SES reconciliation doc | SE SES section; `reconciliation_summary.md` (2026-04-24) | configured | `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md`; DNS/identity artifacts in same directory | confirmed | `scripts/validate_ses_readiness.sh` and `scripts/launch/ses_deliverability_evidence.sh` | optional freshness rerun only; no contradiction in config-side evidence |
| CLM-008 | Historical claim `MailFromDomainStatus=PENDING` is stale; live reconciliation shows `SUCCESS`. | `docs/runbooks/staging-evidence.md` + SES reconciliation | SE historical note vs reconciliation table | stale statement present | `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md` | drifted | `scripts/validate_ses_readiness.sh` (read-only) | Stage 2 text correction in `docs/runbooks/staging-evidence.md` with citation to reconciliation artifact |
| CLM-009 | SES deliverability boundaries (first-send retrieval, inbox receipt, bounce/complaint handling) remain unproven/open. | `docs/runbooks/staging-evidence.md`; `ROADMAP.md` line 117; first-send status artifact | open boundary | `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md`; blocker artifacts in same dir | confirmed | `scripts/probe_ses_bounce_complaint_e2e.sh`; `scripts/launch/ses_deliverability_evidence.sh` | run bounce and complaint probes with staging env and preserve suppression/audit outputs |
| CLM-010 | Stage 3 live SES roundtrip probe passed (send + inbound S3 + auth verdict). | SES evidence artifact | `20260427_stage5_live_probe/roundtrip.json` | passed | `docs/runbooks/evidence/ses-deliverability/20260427_stage5_live_probe/roundtrip.json` | confirmed | `scripts/validate_inbound_email_roundtrip.sh` owner lane | keep as supporting proof; does not close bounce/complaint boundary |
| CLM-011 | Deliverability canary had two passing runs. | SES canary artifact | `20260428T195818Z_deliverability_canary/gate_summary.json` | passed | gate summary + run_1/run_2 json artifacts | confirmed | `scripts/canary/support_email_deliverability.sh` | periodic rerun per canary schedule |
| CLM-012 | Deploy owner uses SSM `last_deploy_sha`, health-check loop, rollback on failure, and control-plane host targeting by Name tag. | `ops/scripts/deploy.sh` | script contract | owner contract defined | script source; historical probe `08_predeploy_last_deploy_sha.txt` | confirmed | `ops/scripts/deploy.sh` | none for ownership mapping |
| CLM-013 | Older deploy-state claim that `f68856f7` was the prior successful deploy is incorrect; deploy pipeline had rollback ping-pongs since Apr 27. | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md` | corrected progress update 2026-04-30 ~01:30 UTC | prior claim invalidated | operator next-steps corrected section; historical `08_predeploy_last_deploy_sha.txt` shows earlier readback | drifted | `ops/scripts/deploy.sh` + SSM readbacks | capture current SSM parameter history and runtime binary SHA in fresh deploy-state evidence bundle |
| CLM-014 | Root-cause claim: Apr 27 commit added metering-env hard-fail on missing tags, breaking control-plane deploy path; later fixed by conditional generation. | `OPERATOR_NEXT_STEPS.md`; `ops/scripts/deploy.sh`; `ops/scripts/lib/generate_ssm_env.sh` | Apr 30 corrected note + current script behavior | fixed in code / needs live proof | script now conditionally skips metering-env on control-plane instance | ambiguous | `ops/scripts/deploy.sh` | prove with a fresh deploy execution artifact showing success through current path |
| CLM-015 | Stripe cutover Stage 2 SSM mutation passed (parameter version advanced to 2). | stripe cutover evidence | `STAGE_2_ssm_rotation.json` (2026-04-29T19:12:34Z) | passed | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/STAGE_2_ssm_rotation.json` | confirmed | owner command documented in `STAGE_2_PLAN.md` and operator steps | optional readback refresh only |
| CLM-016 | Stripe validation (Stage 4) passed full invoice lifecycle in 4296ms. | stripe cutover evidence | `STAGE_4_validate_stripe_output.json` | passed | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/STAGE_4_validate_stripe_output.json` | confirmed | `scripts/validate-stripe.sh` | none (already proven) |
| CLM-017 | Roadmap/Priorities assert deploy-via-OIDC contract restored; remaining work is fresh current-main deploy/rerun proof. | `PRIORITIES.md`, `ROADMAP.md` | PR line 5; RM lines 29, 95, 113, 128 | partially proven | `docs/runbooks/staging-evidence.md` references + deploy probe directory `20260429T041440_stage6_deploy_probe` | ambiguous | `ops/scripts/deploy.sh` + staging CI/deploy workflow | fresh deploy artifact from current main with runtime readback + owner lane reruns |
| CLM-018 | Some status claims rely on external/private temp artifact paths under private local directories and `/var/folders/`, not checked-in owner bundles. | `docs/runbooks/staging-evidence.md`, `PRIORITIES.md`, `ROADMAP.md` | multiple references to private temp paths | evidentiary fragility | example: preserved RC artifact + browser stage2 summary paths | missing-evidence | owner seams already exist (`run_full_backend_validation`, browser evidence owners, SES/billing owners) | re-materialize public-safe checked-in evidence under the checked-in runbook evidence tree and retarget citations |

## Probe evidence log
### Existing evidence pointers used in this stage
- Alert delivery lane:
  - `docs/runbooks/evidence/alert-delivery/.current_bundle`
  - `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/08_stage2_readiness_gate.txt`
  - `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/15_stage3_verdict.txt`
  - `docs/runbooks/evidence/alert-delivery/20260429T191355Z_post_apr29_merge/SUMMARY.md`
- Billing lane:
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/SUMMARY.md`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/cross_check_result.json`
  - `docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/CROSS_CHECK_RESULT.md`
- SES lane:
  - `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md`
  - `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md`
  - `docs/runbooks/evidence/ses-deliverability/20260427_stage5_live_probe/roundtrip.json`
  - `docs/runbooks/evidence/ses-deliverability/20260428T195818Z_deliverability_canary/gate_summary.json`
- Deploy/stripe cutover lane:
  - `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/08_predeploy_last_deploy_sha.txt`
  - `docs/runbooks/evidence/ses-deliverability/20260429T041440_stage6_deploy_probe/53_runtime_snapshot_recheck.txt`
  - `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md`
  - `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/STAGE_2_ssm_rotation.json`
  - `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/STAGE_4_validate_stripe_output.json`

## Commands run / commands required
### Commands run (research-only, non-mutating)
```bash
# Claim/source extraction and owner mapping
sed -n '1,260p' docs/runbooks/staging-evidence.md docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md PRIORITIES.md ROADMAP.md
rg -n "staging|deploy|deployment|runtime|billing|Stripe|SES|alert|webhook|ready|verdict|launch|probe|evidence" PRIORITIES.md ROADMAP.md docs/runbooks/staging-evidence.md docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md
sed -n '1,320p' ops/scripts/deploy.sh ops/scripts/rollback.sh ops/scripts/lib/generate_ssm_env.sh
sed -n '1,260p' scripts/probe_alert_delivery.sh scripts/probe_ses_bounce_complaint_e2e.sh scripts/staging_billing_rehearsal.sh scripts/launch/run_full_backend_validation.sh

# Evidence pointer readback
cat docs/runbooks/evidence/alert-delivery/.current_bundle \
    docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/08_stage2_readiness_gate.txt \
    docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/15_stage3_verdict.txt
cat docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/SUMMARY.md \
    docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/cross_check_result.json
cat docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md \
    docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md
```

### Commands required (pending probes; do not run in Stage 1)
```bash
# Deploy-state reconciliation owner readbacks
aws ssm get-parameter --name /fjcloud/staging/last_deploy_sha --with-decryption --region us-east-1
aws ssm send-command --region us-east-1 --document-name AWS-RunShellScript --instance-ids <staging-api-instance> --parameters commands='["systemctl status fjcloud-api --no-pager","curl -sf http://127.0.0.1:3001/health"]'

# Billing readiness rerun owner
bash scripts/staging_billing_rehearsal.sh --env-file <staging-env-file> --month <YYYY-MM> --confirm-live-mutation
bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc --credential-env-file <staging-env-file>

# Alert-delivery owner proof (dispatch + deployed-runtime uptake)
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
bash scripts/probe_alert_delivery.sh --readback
# plus deployed-host startup log readback proving webhook config uptake

# SES bounce/complaint suppression owner proof
bash scripts/probe_ses_bounce_complaint_e2e.sh bounce <staging-env-file>
bash scripts/probe_ses_bounce_complaint_e2e.sh complaint <staging-env-file>
```

## Contradictions
| claim_id | contradiction summary | class | evidence |
|---|---|---|---|
| CLM-008 | Historical `MailFromDomainStatus=PENDING` conflicts with later reconciliation `SUCCESS`. | drifted | `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md` |
| CLM-013 | Older “previous successful deploy = f68856f7” claim is explicitly corrected as incorrect due rollback ping-pongs/manual intervention. | drifted | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md` corrected section |
| CLM-003 | Alert lane readiness PASS does not imply persisted-send proof PASS; Stage 3 verdict explicitly failed. | confirmed contradiction across sub-claims | `.../08_stage2_readiness_gate.txt` vs `.../15_stage3_verdict.txt` |
| CLM-018 | Several status claims cite private temporary artifacts outside checked-in evidence tree; reproducibility risk. | missing-evidence | path references in `docs/runbooks/staging-evidence.md`, `PRIORITIES.md`, `ROADMAP.md` |

## Open questions
- OQ-001: What is the current authoritative staging deployed SHA after Apr 30 fixes (`59c0d532` path) and does `/fjcloud/staging/last_deploy_sha` reflect a successful deploy versus rollback target history?
- OQ-002: Should staging contract explicitly remain Discord-only for alerts, or is Slack required and currently missing from SSM?
- OQ-003: For SES boundary closure, which owner lane will publish first checked-in bounce/complaint suppression proof as canonical SSOT (`probe_ses_bounce_complaint_e2e.sh` vs wrapper lane)?
- OQ-004: Which private-path artifacts must be re-materialized into checked-in runbook evidence paths before Stage 2 status-doc reconciliation?

## Next-stage edit set
### Minimum correction targets (no edits applied in Stage 1)
| claim_id | target doc | replacement statement shape | required citation |
|---|---|---|---|
| CLM-008 | `docs/runbooks/staging-evidence.md` | Replace stale MAIL FROM status wording with “historical PENDING, current SUCCESS as of reconciliation artifact”. | `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md` |
| CLM-013 | `docs/runbooks/staging-evidence.md` and possibly `PRIORITIES.md`/`ROADMAP.md` pointers | Replace deprecated “f68856f7 previous successful deploy” interpretations with corrected deploy-history statement scoped by timestamp. | `docs/runbooks/evidence/secret-rotation/20260429T183138Z_stripe_cutover/OPERATOR_NEXT_STEPS.md` + fresh Stage 2 deploy readback artifact |
| CLM-003 | `docs/runbooks/staging-evidence.md` reconciliation section | Keep split between Stage 2 readiness PASS and Stage 3 persisted-send failure explicit; avoid collapsing into single PASS/FAIL shorthand. | `docs/runbooks/evidence/alert-delivery/20260429T052555Z_deployed_staging/{08_stage2_readiness_gate.txt,15_stage3_verdict.txt}` |
| CLM-018 | `PRIORITIES.md`/`ROADMAP.md` pointer lines (pointer-only updates) | Retarget private temp-path citations to checked-in evidence bundles where available; mark missing checked-in equivalents as pending-required artifacts. | specific checked-in bundle paths per claim |
| CLM-006 | `PRIORITIES.md`/`ROADMAP.md` status phrasing | Preserve “fresh current-main rerun required” wording until new owner rerun artifacts land; do not restate stale run state as current. | new `run_full_backend_validation` + `staging_billing_rehearsal` artifacts |

### Non-owner/ad-hoc checks flagged for seam reuse
- Any claim currently justified only by private `.matt`/`/var/folders/...` artifacts should be remapped to checked-in owner seams:
  - deploy/runtime: `ops/scripts/deploy.sh` + SSM readback artifacts
  - billing readiness: `scripts/staging_billing_rehearsal.sh`, `scripts/launch/run_full_backend_validation.sh --paid-beta-rc`
  - alert delivery: `scripts/probe_alert_delivery.sh` + deployed-host startup/journal proof
  - SES suppression: `scripts/probe_ses_bounce_complaint_e2e.sh`
