# GAP SPEC

This bundle is non-green. Each entry below is generated from `failure_classifications.json`, raw probe logs, and sidecars in this bundle.

- `verify_email_clickthrough`: rc=1 pass=0
  - Classification: `verify_email_token_invalid_or_expired`
  - Smallest owner path: `scripts/probe_verify_email_clickthrough_e2e.sh`
  - Observed detail: ERROR: verify-email page rendered failure branch — token invalid or expired
  - Reason: No email verification TERMINUS; rendered failure branch reported token invalid or expired.
  - Reference comparison: NEW failure shape relative to `20260603T033009Z_in_vpc_rerun`.
  - Open questions: determine whether this shape is expected staging drift or requires Wave-3 repair before live Section 1 flip.

- `password_reset_clickthrough`: rc=1 pass=0
  - Classification: `password_reset_token_not_cleared`
  - Smallest owner path: `scripts/probe_password_reset_clickthrough_e2e.sh`
  - Observed detail: ERROR: password_reset_token not cleared after reset for resetprobe2026060411523724977@test.flapjack.foo after 15 attempts
  - Reason: No password reset login TERMINUS; database poll did not observe token clearing.
  - Reference comparison: Same broad failure shape as the reference bundle.
  - Open questions: determine whether this shape is expected staging drift or requires Wave-3 repair before live Section 1 flip.

- `dunning_email_inbox`: rc=1 pass=0
  - Classification: `rehearsal_reset_failed`
  - Smallest owner path: `scripts/probe_dunning_email_inbox_e2e.sh`
  - Observed detail: dunning owner script exited 1
  - Reason: Final JSON result did not satisfy terminus_and_result_json detection.
  - Reference comparison: Same broad failure shape as the reference bundle.
  - Open questions: determine whether this shape is expected staging drift or requires Wave-3 repair before live Section 1 flip.

- `staging_dunning_delivery`: rc=1 pass=0
  - Classification: `stripe_cli_missing`
  - Smallest owner path: `scripts/validate_staging_dunning_delivery.sh`
  - Observed detail: Reset flow failed for tenant 193638a5-35f7-407f-a734-3f73de224336: unknown_classification — no_detail
  - Reason: Dunning delivery reset failed before tenant-state assertion because the staging host command path lacked the stripe CLI.
  - Reference comparison: NEW failure shape relative to `20260603T033009Z_in_vpc_rerun`.
  - Open questions: determine whether this shape is expected staging drift or requires Wave-3 repair before live Section 1 flip.
