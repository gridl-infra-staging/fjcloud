# SES Stage 1 Reconciliation Summary (2026-04-24)

## Scope and method

- Owner contracts reviewed before probing: `scripts/validate_ses_readiness.sh`, `scripts/lib/env.sh::load_env_file`, `docs/runbooks/email-production.md` (Read-Only SES Readiness Contract + Stage 1 truth snapshot), and `docs/runbooks/staging-evidence.md` (SES DNS/account claims).
- Read-only evidence captured under this directory:
  - `readiness_probe.txt`
  - `ses_account.json`
  - `sender_identity.json` + `sender_identity.stderr.txt`
  - `domain_identity.json`
  - `dns_apex_spf.txt`
  - `dns_dkim_*.txt`
  - `dns_mail_from_mx.txt`
  - `dns_mail_from_txt.txt`

## Claim-by-claim reconciliation

| Claim                                                                                         | Checked-in owner surface                                                                 | Live evidence                                                                                                                                                                      | Result           |
| --------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| Canonical sender/region should resolve to `system@flapjack.foo` / `us-east-1` before probing. | `docs/runbooks/email-production.md` (Stage 1 truth snapshot)                             | `resolved_inputs.txt` (loaded with `load_env_file` semantics from explicit alternate-checkout secret path)                                                                         | `match`          |
| Account should be production-enabled and sending-enabled.                                     | `docs/runbooks/email-production.md` + `docs/runbooks/staging-evidence.md:38-39, 274-284` | `ses_account.json` (`SendingEnabled=true`, `ProductionAccessEnabled=true`) and `readiness_probe.txt`                                                                               | `match`          |
| Sender path is `system@flapjack.foo` via inherited `flapjack.foo` domain identity/DKIM.       | `docs/runbooks/email-production.md:129` and `docs/runbooks/staging-evidence.md:44`       | `sender_identity.stderr.txt` (`NotFoundException` for direct email identity) plus `readiness_probe.txt` showing inherited-domain `identity_verified` and `dkim_verified` `SUCCESS` | `match`          |
| Domain identity verification and DKIM should be successful.                                   | `docs/runbooks/staging-evidence.md:38-39`                                                | `domain_identity.json` (`VerificationStatus=SUCCESS`, `DkimAttributes.Status=SUCCESS`)                                                                                             | `match`          |
| Apex SPF TXT for `flapjack.foo` should include Amazon SES + privateemail includes.            | `docs/runbooks/staging-evidence.md:48-50`                                                | `dns_apex_spf.txt` (`v=spf1 include:amazonses.com include:spf.privateemail.com ~all`)                                                                                              | `match`          |
| DKIM CNAMEs for the active SES tokens should resolve to `*.dkim.amazonses.com`.               | `docs/runbooks/staging-evidence.md:38-39` (DKIM success claim)                           | `dns_dkim_1_52evdzqlkiebbauhe6az2v5towsz2dk4.txt`, `dns_dkim_2_a76vb5g3t4par7ncph6gemrtxwfdfo5f.txt`, `dns_dkim_3_7e7tprovcaugklqyn5aenrl4xxfnpm4r.txt`                            | `match`          |
| Custom MAIL FROM DNS should publish SES MX + SES SPF TXT.                                     | `docs/runbooks/staging-evidence.md:51-53`                                                | `dns_mail_from_mx.txt`, `dns_mail_from_txt.txt`                                                                                                                                    | `match`          |
| MAIL FROM status should be `PENDING` until AWS poll completes.                                | `docs/runbooks/staging-evidence.md:54`                                                   | `domain_identity.json` (`MailFromDomainStatus=SUCCESS`)                                                                                                                            | `drift`          |
| Deliverability boundaries not proven by readiness probe remain open.                          | `docs/runbooks/email-production.md:83` and `docs/runbooks/staging-evidence.md:285-287`   | `readiness_probe.txt` includes `unproven_deliverability_items` for SPF/MAIL FROM/bounce/complaint/first-send/inbox evidence                                                        | `still unproven` |

## Historical transcript reconciliation (required treatment)

- Preserved transcript source: `docs/runbooks/evidence/ses-deliverability/20260423T202158Z_ses_boundary_proof_full.txt` (`captured_at: 2026-04-23T20:21:58Z`).
- The preserved transcript reports `MailFromDomainStatus: PENDING` and includes historical live-send MessageIds; this conflicts with current read-only Stage 1 evidence (`domain_identity.json` now reports `MailFromDomainStatus=SUCCESS`).
- Per owner guidance in `docs/runbooks/staging-evidence.md:62-64`, the preserved transcript is treated as historical context and not as a competing source of truth for current Stage 1 reconciliation.
- Current reconciliation authority remains the owner surfaces (`docs/runbooks/email-production.md:123-132`, `docs/runbooks/staging-evidence.md:38-65`, `docs/runbooks/staging-evidence.md:274-287`) plus the fresh raw artifacts in this directory.

## Stage 6 boundary companion linkage (single human-readable note)

- Canonical Stage 4 wrapper run directory (machine-readable owner remains `summary.json` in this run): `/Users/stuart/.matt/projects/fjcloud_dev-cd6902f9/apr23_am_1_ses_deliverability_refined.md-4c6ea1bd/artifacts/stage_04_ses_deliverability/fjcloud_ses_deliverability_evidence_20260423T063739Z_63867`.
- Stage 3 first-send companion status: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md` (retrieval owner still missing; boundaries remain open).
- Stage 4 bounce companion artifact: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/bounce_blocker.txt` (or `bounce_event.json` when checked-in retrieval proof exists).
- Stage 5 complaint companion artifact: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/complaint_blocker.txt` (or `complaint_event.json` when checked-in retrieval proof exists).
- These links record provenance and residual blockers only; SPF/MAIL FROM/bounce/complaint/first-send/inbox evidence boundaries are still unproven.

## Scope-close validation (required before handoff)

- JSON parse validation: `jq empty ses_account.json sender_identity.json domain_identity.json` passed for all captured JSON artifacts.
- Evidence set completeness was re-checked in this directory: raw probe outputs (`readiness_probe.txt`, `ses_account.json`, `sender_identity.json`, `domain_identity.json`), DNS lookups (`dns_apex_spf.txt`, `dns_dkim_*.txt`, `dns_mail_from_mx.txt`, `dns_mail_from_txt.txt`), and reconciliation outputs (`reconciliation_summary.md`, `drift_blocker.md`) are present.
- No send-capable owners were run in this stage. Stage artifacts only include readiness/account/identity/DNS reconciliation outputs (see `command_exit_codes.txt` and `readiness_probe.txt`); no wrapper send transcript was generated under this 2026-04-24 evidence path.

## Notes

- Direct sender identity lookup (`aws sesv2 get-email-identity --email-identity system@flapjack.foo`) now returns `NotFoundException`; this is consistent with the inherited-domain sender path and is not itself a drift from the documented contract.
- For JSON-parse hygiene in this stage, `sender_identity.json` stores a structured error object while preserving raw AWS stderr in `sender_identity.stderr.txt`.

## Open questions

- Should the checked-in claim in `docs/runbooks/staging-evidence.md:54` be updated from `MailFromDomainStatus=PENDING` to reflect observed live `SUCCESS`? (Blocked in this stage because status-doc rewrites are out of scope.)
- This checkout does not contain repo-local `.secret/.env.secret`; this run used the documented alternate-checkout secret path snapshot. Should future Stage 1 runs enforce a local secret-file prerequisite in this workspace layout?
