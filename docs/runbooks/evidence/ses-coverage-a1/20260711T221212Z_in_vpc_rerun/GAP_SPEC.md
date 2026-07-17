# GAP SPEC

Bundle: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`

`all_green.txt` is `0`.

## Terminal Rule

Stage 2 classified the verify-email and password-reset residuals as probe-side. No product-side local-only residual exists in the required source classification, so no post-deploy Wave 2 product-fix containment branch applies. These residuals can close only when a deployed six-row bundle records `all_green.txt=1`.

## Non-Green Rows

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_clickthrough_not_green`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: ERROR: email_verified_at not set after clickthrough for verifyprobe2026071122150123670@test.flapjack.foo after 15 attempts
  - Reason: Probe-side residual can be retired only by a green deployed bundle; this row did not satisfy rc=0/pass=1.
  - Section 1 partial match: `False`
  - Disposition: `probe_side_residual_requires_green_deployed_bundle`

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_clickthrough_not_green`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe2026071122161327557@test.flapjack.foo after 15 attempts
  - Reason: Probe-side residual can be retired only by a green deployed bundle; this row did not satisfy rc=0/pass=1.
  - Section 1 partial match: `False`
  - Disposition: `probe_side_residual_requires_green_deployed_bundle`

- `dunning_email_inbox`: rc=1 pass=0
  - Classification: `dunning_email_inbox_not_green`
  - Smallest owner path: `scripts/probe_dunning_email_inbox_e2e.sh`
  - Observed detail: probe did not reach its parser-owned pass terminus
  - Reason: This row was expected green in the terminal six-row bundle but did not satisfy rc=0/pass=1.
  - Section 1 partial match: `False`
  - Disposition: `new_terminal_bundle_failure`

- `staging_dunning_delivery`: rc=1 pass=0
  - Classification: `staging_dunning_delivery_not_green`
  - Smallest owner path: `scripts/validate_staging_dunning_delivery.sh`
  - Observed detail: probe did not reach its parser-owned pass terminus
  - Reason: This row was expected green in the terminal six-row bundle but did not satisfy rc=0/pass=1.
  - Section 1 partial match: `False`
  - Disposition: `new_terminal_bundle_failure`

