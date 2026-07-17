# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260612T003052Z_in_vpc_rerun`

`all_green.txt` is `0`.

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_not_marked_verified`
  - Current owner: `scripts/probe_verify_email_clickthrough_e2e.sh::verify_email_poll_until_verified`
  - Smallest unblocking owner: `scripts/probe_verify_email_clickthrough_e2e.sh::verify_email_poll_until_verified`
  - Exact blocker: Clickthrough completed far enough to run the poll, but email_verified_at was not set after 15 attempts.
  - Observed detail: ERROR: email_verified_at not set after clickthrough for verifyprobe2026061200343430018@test.flapjack.foo after 15 attempts
  - Proxy evidence and bias/tolerance: The exact saved log is the direct evidence; there is no pass proxy for this row. No positive SES conclusion is taken from this row.
  - Conditional disposition: `blocked_by_current_verify_email_poll_result`
- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_token_not_cleared`
  - Current owner: `scripts/probe_password_reset_clickthrough_e2e.sh::reset_token_poll_until_cleared`
  - Smallest unblocking owner: `scripts/probe_password_reset_clickthrough_e2e.sh::reset_token_poll_until_cleared`
  - Exact blocker: Password reset flow completed far enough to run the token-cleared poll, but password_reset_token remained set after 15 attempts.
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe202606120036128021@test.flapjack.foo after 15 attempts
  - Proxy evidence and bias/tolerance: The exact saved log is the direct evidence; there is no pass proxy for this row. No positive SES conclusion is taken from this row.
  - Conditional disposition: `blocked_by_current_password_reset_poll_result`
- `dunning_email_inbox`: rc=1 pass=0
  - Classification: `dunning_owner_rehearsal_reset_failed`
  - Current owner: `scripts/probe_dunning_email_inbox_e2e.sh::exit_with_validator_result`
  - Smallest unblocking owner: `scripts/probe_dunning_email_inbox_e2e.sh::exit_with_validator_result`
  - Exact blocker: The dunning inbox probe delegated to the staging dunning validator and received rehearsal_reset_failed.
  - Observed detail: dunning owner script exited 1
  - Proxy evidence and bias/tolerance: staging_dunning_delivery carries the deeper reset failure detail from the owner validator. Dunning inbox delivery remains blocked; no inbox success is inferred from this wrapper failure.
  - Conditional disposition: `blocked_by_staging_dunning_delivery_reset_failure`
- `staging_dunning_delivery`: rc=1 pass=0
  - Classification: `tenant_allowlist_shell_quoting_backslash_uuid`
  - Current owner: `scripts/lib/env.sh::load_layered_env_files + scripts/validate_staging_dunning_delivery.sh::run_allowlisted_rehearsal_resets`
  - Smallest unblocking owner: `scripts/lib/env.sh::load_layered_env_files`
  - Exact blocker: FJCLOUD_TEST_TENANT_IDS reached reset_customer_lookup with a trailing backslash, producing invalid UUID syntax.
  - Observed detail: Reset flow failed for tenant 193638a5-35f7-407f-a734-3f73de224336\: reset_customer_lookup_query_failed — reset_customer_lookup query failed: ERROR:  invalid input syntax for type uuid: "193638a5-35f7-407f-a734-3f73de224336\"
LINE 1: ...LECT stripe_customer_id FROM customers WHERE id = '193638a5-...
                                                             ^
  - Proxy evidence and bias/tolerance: ses_bounce and ses_complaint still prove bounce/complaint suppression independently, but they do not prove dunning delivery. Treat only the SES bounce/complaint rows as green; dunning delivery remains conditionally blocked on the env-materialization seam.
  - Conditional disposition: `repo_owned_prerequisite_for_later_runtime_remediation`

## Explicit Carry-Forward

- The staging dunning delivery failure is not a generic dunning failure. The preserved blocker is the `%q`/backslash `FJCLOUD_TEST_TENANT_IDS` env-materialization bug: the reset lookup saw `193638a5-35f7-407f-a734-3f73de224336\` and Postgres rejected it as invalid UUID syntax.
- Runtime remediation is outside this Stage 3 bundle-normalization scope; this document records the repo-owned prerequisite for the later owner lane.

## Open Questions

- none
