---
created: 2026-04-23
updated: 2026-04-25
---

# Stage 1 SES Boundary Research Findings (Read-Only)

## Objective

Freeze one source-backed map of current SES proof boundaries without changing runtime behavior, and identify which existing owner seam should be extended in Stage 2/3.

## Evidence Inputs

### Canonical local owner surfaces re-read

- `docs/runbooks/email-production.md:51-135,170-190,265-280`
- `docs/runbooks/staging-evidence.md:44-67,328-349`
- `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md:18-43`
- `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/drift_blocker.md:4-24`
- `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md:3-11`
- `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/bounce_blocker.txt:15-29`
- `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/complaint_blocker.txt:14-28`
- `scripts/launch/ses_deliverability_evidence.sh:268-353,403-460,463-550,553-631`
- `scripts/validate_ses_readiness.sh:160-162,224-287`
- `scripts/tests/ses_runbook_test.sh:47-75,142-167`
- `scripts/tests/ses_boundary_proof_artifact_test.sh:220-238,288-339`
- `scripts/tests/ses_deliverability_evidence_test.sh:570-594,717-763,765-791`
- `scripts/lib/staging_billing_rehearsal_email_evidence.sh:1,244-249,285-323`
- `infra/api/tests/email_test.rs:349-379`

### Baseline contract checks (unchanged commands)

- `bash scripts/tests/ses_runbook_test.sh` -> pass (`64 passed, 0 failed`)
- `bash scripts/tests/ses_boundary_proof_artifact_test.sh` -> pass (`62 passed, 0 failed`)
- `bash scripts/tests/ses_deliverability_evidence_test.sh` -> pass (`127 passed, 0 failed`)
- Validation cache check/record executed before/after each command at current HEAD `6ce3283d11819bf6e569461e23061a0627b10acc` (clean tree run, session `s16`).

### AWS official documentation verification (2026-04-25)

- Mailbox simulator semantics and limits:
  - <https://docs.aws.amazon.com/ses/latest/dg/send-an-email-from-console.html>
  - <https://docs.aws.amazon.com/ses/latest/dg/send-email-concepts-process.html>
- SES notification schema:
  - <https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html>
- Identity and DKIM behavior:
  - <https://docs.aws.amazon.com/ses/latest/dg/creating-identities.html>
  - <https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim.html>
  - <https://docs.aws.amazon.com/ses/latest/dg/verify-addresses-and-domains.html>

## Boundary Matrix (Current Truth)

| Boundary | Status | Why still open | Owner evidence |
| --- | --- | --- | --- |
| `spf` | `unproven` | Wrapper summary intentionally emits `deliverability_boundaries.spf="unproven"`; reconciliation also states remaining boundaries are still unproven. | `scripts/launch/ses_deliverability_evidence.sh:618-626`; `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/reconciliation_summary.md:28,43` |
| `mail_from` | `unproven` | Even with MAIL FROM DNS status reconciled, wrapper contract intentionally keeps MAIL FROM as unproven proof boundary in Stage 1/4 semantics. | `scripts/launch/ses_deliverability_evidence.sh:620,626`; `reconciliation_summary.md:27-28,43`; `scripts/tests/ses_deliverability_evidence_test.sh:738-753` |
| `bounce_proof` | `unproven` | Bounce send artifact exists, but blocker file states missing checked-in retrieval owner and forbids manual mailbox validation. | `bounce_blocker.txt:3-4,19-24,29`; `scripts/tests/ses_boundary_proof_artifact_test.sh:312-319` |
| `complaint_proof` | `unproven` | Complaint send artifact exists, but blocker file states missing checked-in retrieval owner and forbids manual mailbox validation. | `complaint_blocker.txt:3-4,18-23,28`; `scripts/tests/ses_boundary_proof_artifact_test.sh:333-339` |
| `first_send_evidence` | `unproven` | Wrapper send seam passed, but retrieval owner for SES inbox/header proof is explicitly missing. | `first_send_retrieval_status.md:6-11`; `scripts/tests/ses_deliverability_evidence_test.sh:765-788` |
| `inbox_receipt_proof` | `unproven` | No checked-in retrieval owner for inbox/header proof; policy explicitly blocks manual mailbox validation. | `first_send_retrieval_status.md:7-11`; `scripts/tests/ses_boundary_proof_artifact_test.sh:300-305` |

## Wrapper Semantics: Proven vs Intentionally Unproven

- `delegate_readiness_check` proves/blocks account + identity prerequisites only.
  - Missing `SES_FROM_ADDRESS` or `SES_REGION` -> blocked before send seam.
  - Uses delegated readiness owner output to set account/identity gate status.
  - Source: `scripts/launch/ses_deliverability_evidence.sh:268-353`.
- `run_recipient_preflight` proves recipient preflight only.
  - Simulator recipient is allowed for send evidence without inbox-receipt closure.
  - Non-simulator can pass via verified identity path, but this is still preflight, not inbox retrieval.
  - Source: `scripts/launch/ses_deliverability_evidence.sh:403-460`.
- `run_live_send_seam` proves only that canonical ignored cargo seam executed with positive named-test marker.
  - It does not claim inbox retrieval proof.
  - Source: `scripts/launch/ses_deliverability_evidence.sh:463-538`; `scripts/tests/ses_deliverability_evidence_test.sh:570-594`.
- `derive_overall_verdict`/`assemble_summary_json` encode hard boundary truth.
  - `fail` only on send failure; blocked on missing prerequisites.
  - `deliverability_boundaries` intentionally remain unproven for SPF, MAIL FROM, bounce/complaint handling, first-send evidence, and inbox receipt.
  - Source: `scripts/launch/ses_deliverability_evidence.sh:540-550,553-631`.

## Test-Owned Contract Truth (No Parallel Owners)

- No checked-in machine `summary.json` owner under Stage 1 boundary-proof directory is allowed.
  - Source: `scripts/tests/ses_boundary_proof_artifact_test.sh:220-229`; `scripts/tests/ses_runbook_test.sh:166-167`.
- No manual mailbox validation is allowed in first-send/bounce/complaint blocker paths.
  - Source: `scripts/tests/ses_boundary_proof_artifact_test.sh:121-124,300-305`; `scripts/tests/ses_deliverability_evidence_test.sh:783-788`.
- Feedback proof contract shape is explicit when event artifacts exist:
  - `notificationType`, `mail.messageId`, `bounce.bouncedRecipients`, `complaint.complainedRecipients`.
  - Source: `scripts/tests/ses_boundary_proof_artifact_test.sh:163-177,317,338`.

## AWS Assumptions Verified For Stage 2/3

- Mailbox simulator sends are valid for exercising SES send/notification scenarios, including sandbox use and simulated success/bounce/complaint outcomes, but this is simulator path evidence, not a repo-owned inbox retrieval proof seam.
  - AWS docs define simulator "successful delivery" as recipient provider acceptance and optional SNS delivery notification, and separately document simulator behavior/limits.
  - Sources: <https://docs.aws.amazon.com/ses/latest/dg/send-an-email-from-console.html>, <https://docs.aws.amazon.com/ses/latest/dg/send-email-concepts-process.html>.
  - Inference: simulator success alone does not close `inbox_receipt_proof` because no inbox/header retrieval owner is executed.
- Notification schema assumptions in artifact contracts match AWS docs:
  - top-level `notificationType` (or `eventType` for event publishing), `mail.messageId`, bounce `bouncedRecipients`, complaint `complainedRecipients`.
  - Source: <https://docs.aws.amazon.com/ses/latest/dg/notification-contents.html>.
- Identity/readiness fallback assumptions are AWS-consistent:
  - Domain and email identities can coexist; domain verification usually eliminates need to verify each email identity for straightforward sending.
  - DKIM inheritance applies from verified domain to email addresses on that domain.
  - Sandbox still requires verified recipients except mailbox simulator addresses.
  - Sources: <https://docs.aws.amazon.com/ses/latest/dg/creating-identities.html>, <https://docs.aws.amazon.com/ses/latest/dg/send-email-authentication-dkim.html>, <https://docs.aws.amazon.com/ses/latest/dg/verify-addresses-and-domains.html>.

## Current Open Boundaries And Reasons

- `first_send_evidence` is open because send-side success exists but no checked-in inbox/header retrieval owner exists.
- `inbox_receipt_proof` is open for the same retrieval-owner gap and explicit no-manual-validation constraint.
- `bounce_proof` is open because bounce retrieval ownership is missing; blocker path is intentionally preserved.
- `complaint_proof` is open because complaint retrieval ownership is missing; blocker path is intentionally preserved.
- `spf` and `mail_from` remain open because wrapper contract intentionally does not close those proofs in this boundary phase.

## Reuse/Owner Seam (Stage 2/3 Guidance)

- Existing seams to extend (do not create parallel owners):
  - Wrapper owner: `scripts/launch/ses_deliverability_evidence.sh`
  - Boundary artifact contract owners: `scripts/tests/ses_boundary_proof_artifact_test.sh`, `scripts/tests/ses_deliverability_evidence_test.sh`
  - Existing blocker/status artifacts under `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/`
- Confirmed non-owners:
  - `scripts/lib/staging_billing_rehearsal_email_evidence.sh` is Mailpit-only evidence.
  - `infra/api/tests/email_test.rs::ses_live_smoke_sends_verification_email` is send seam only.

### Stage 2 handoff note (highest-leverage first red seam)

- First red target: **SES inbox/header retrieval seam for first non-simulator send proof**.
  - Why first: it closes the most central unresolved proof dependency (first-send + inbox receipt) while reusing existing wrapper + artifact contracts.
  - Keep separate and still open after that red: bounce and complaint retrieval proof (distinct feedback-event retrieval seam).
- Out-of-scope reminders for Stage 2/3:
  - no production runtime behavior changes in Stage 1 truth lock,
  - no manual mailbox validation,
  - no parallel checked-in proof owner files (especially no second boundary `summary.json` owner).

## Open Questions

- Which existing operational substrate should own inbox/header retrieval evidence for SES (without introducing a parallel owner): an SES-native retrieval path, or an approved existing inbox system contract?
- For complaint proof, do we require recipient disambiguation policy in red tests (AWS documents that `complainedRecipients` may include possible recipients, not guaranteed single submitter)?
