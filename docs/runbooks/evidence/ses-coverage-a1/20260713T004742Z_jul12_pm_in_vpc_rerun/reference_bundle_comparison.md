# Reference bundle comparison

- This bundle: `docs/runbooks/evidence/ses-coverage-a1/20260713T004742Z_jul12_pm_in_vpc_rerun`
- Reference: `docs/runbooks/evidence/ses-coverage-a1/20260711T221212Z_in_vpc_rerun`

| probe_id | reference rc/pass | this rc/pass | delta |
| --- | --- | --- | --- |
| verify_email_clickthrough | 1 / ❌ | 0 / ✅ | cleared (email_verified_at set on attempt 1) |
| password_reset_clickthrough | 1 / ❌ | 0 / ✅ | cleared (login with new password succeeded) |
| dunning_email_inbox | 1 / ❌ | 1 / ❌ | still failing, new root cause |
| ses_bounce | 0 / ✅ | 0 / ✅ | unchanged |
| ses_complaint | 0 / ✅ | 0 / ✅ | unchanged |
| staging_dunning_delivery | 1 / ❌ | 1 / ❌ | still failing, new root cause |
| **all_green.txt** | **0** | **0** | unchanged verdict, changed reasons |

## Deployed SHA

- Reference deployed dev_sha: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff` (7 commits behind main at the time)
- This deployed dev_sha: `81a1c486f7b52638af445b34fcf9e22f8c857cfa` (== merged `origin/main`, drift=false)

The current branch descends from the merged `s1_dunning_reset_stripe_json_fix`, which is
included in the deployed SHA here but was not in the reference deploy.

## What changed

1. **verify_email_clickthrough / password_reset_clickthrough:** flipped ❌→✅. The
   deployed merged-main SHA now completes the auth-email clickthrough end-to-end. These
   were the reference's "probe-side residuals". They are green here but not yet retired
   because this bundle is not `all_green=1`.

2. **staging_dunning_delivery:** classification moved from `reset_stripe_list_invalid`
   (Stripe invoice list returned invalid JSON, a product bug in the reset flow) to
   `invoice_email_ses_query_failed` (instance-role IAM denial on CloudWatch Logs read).
   The Stripe-JSON fix cleared the original blocker; the rehearsal now runs through reset,
   preflight, metering, and the live mutation, and fails later at email-evidence capture.

3. **dunning_email_inbox:** still fails, now inheriting Gap 1's IAM block rather than the
   Stripe reset bug.

## Net

Same top-line verdict (`all_green=0`, §1 stays partial), but the failure surface is
materially reduced: 2 rows recovered, and the remaining 2 rows advanced from a product
logic bug to a single downstream ops/IAM prerequisite (see `GAP_SPEC.md`).
