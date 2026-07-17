# Stage 3 First-Send Retrieval Status (2026-04-24)

- Wrapper run directory: `/tmp/fjcloud_stage3_first_send_boundary/fjcloud_ses_deliverability_evidence_20260424T213201Z_91803`
- Wrapper summary artifact: `/tmp/fjcloud_stage3_first_send_boundary/fjcloud_ses_deliverability_evidence_20260424T213201Z_91803/summary.json`
- Chosen recipient class: SES mailbox simulator (`success@simulator.amazonses.com`)
- Send-side wrapper verdict: `overall_verdict=pass` with `send_attempt.status=pass`
- Supplemental retrieval owner path: `scripts/lib/staging_billing_rehearsal_email_evidence.sh` (existing owner seam to extend for SES first-send inbox/header retrieval automation).
- Inbox/header evidence path: `docs/runbooks/evidence/ses-deliverability/20260424_boundary_proof/first_send_retrieval_status.md` (this artifact remains the checked-in Stage 3 owner until supplemental SES retrieval output is automated).
- No manual mailbox validation is allowed.
- Boundary state must remain open: `deliverability_boundaries.first_send_evidence=unproven`
- Boundary state must remain open: `deliverability_boundaries.inbox_receipt_proof=unproven`
