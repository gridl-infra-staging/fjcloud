# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260609T174733Z_in_vpc_rerun`

`all_green.txt` is `0`.

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_not_marked_verified`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: ERROR: email_verified_at not set after clickthrough for verifyprobe2026060917492014593@test.flapjack.foo after 15 attempts
  - Reason: No email verification TERMINUS; database poll did not observe email_verified_at after clickthrough in this current staging bundle.
  - Section 1 partial match: `False`
  - Disposition: `same_deployed_sha_repeat_required`

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_token_not_cleared`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe2026060917505717458@test.flapjack.foo after 15 attempts
  - Reason: No password reset login TERMINUS; database poll did not observe token clearing.
  - Section 1 partial match: `True`
  - Disposition: `pre_authorized_section1_partial`

## Open Questions

- `verify_email_clickthrough` is non-green again in this fresh current-staging bundle. Stage 2 resolved the stale-evidence question for an earlier unchanged deployed SHA, but this bundle is on a newer `dev_sha`; repeat against the same deployed `dev_sha` before recommending product remediation.
