# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`

`all_green.txt` is `0`.

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_not_marked_verified`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: ERROR: email_verified_at not set after clickthrough for verifyprobe2026071121293132250@test.flapjack.foo after 15 attempts
  - Reason: No email verification TERMINUS; database poll did not observe email_verified_at after clickthrough in this current staging bundle.

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_token_not_cleared`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe2026071121304318305@test.flapjack.foo after 15 attempts
  - Reason: No password reset login TERMINUS; database poll did not observe token clearing.

- `dunning_email_inbox`: rc=1 pass=0
  - Classification: `dunning_email_inbox_non_green`
  - Smallest owner path: `scripts/probe_dunning_email_inbox_e2e.sh`
  - Observed detail: dunning inbox row did not reach parser pass
  - Reason: No dunning inbox parser pass terminus in this bundle.

- `staging_dunning_delivery`: rc=1 pass=0
  - Classification: `staging_dunning_delivery_non_green`
  - Smallest owner path: `scripts/validate_staging_dunning_delivery.sh`
  - Observed detail: staging dunning delivery row did not reach parser pass
  - Reason: Staging dunning delivery row did not reach final JSON result=passed.

## Open Questions

- Clickthrough residual owner classification is recorded in the second same-SHA bundle classification.md.
