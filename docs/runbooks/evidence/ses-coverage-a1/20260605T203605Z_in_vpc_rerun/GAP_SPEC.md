# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260605T203605Z_in_vpc_rerun`

`all_green.txt` is `0`.

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_not_marked_verified`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: ERROR: email_verified_at not set after clickthrough for verifyprobe202606052038412652@test.flapjack.foo after 15 attempts
  - Reason: No email verification TERMINUS; database poll did not observe email_verified_at after clickthrough.
  - Section 1 partial match: `False`
  - Disposition: `same_deployed_sha_repeat_required`

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_token_not_cleared`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe202606052039487290@test.flapjack.foo after 15 attempts
  - Reason: No password reset login TERMINUS; database poll did not observe token clearing.
  - Section 1 partial match: `True`
  - Disposition: `pre_authorized_section1_partial`

## Open Questions

- `verify_email_clickthrough` / `verify_email_not_marked_verified` remains non-green in this fresh bundle, but product remediation is not recommended until two consecutive live reruns on the same deployed `dev_sha` reproduce the failure.
