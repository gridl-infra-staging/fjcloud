# GAP_SPEC — Stage 4 §1 In-VPC Rerun (20260529T194224Z)

## Symptom
Canonical six-row `_in_vpc_rerun` bundle executed through the existing owner chain but failed the pass gate: `all_green.txt=0` and every probe row in `probe_results.tsv` has `rc=1`, `pass=0`.

## Failed probe IDs
- `verify_email_clickthrough`
- `password_reset_clickthrough`
- `dunning_email_inbox`
- `ses_bounce`
- `ses_complaint`
- `staging_dunning_delivery`

## Blocker detail and concrete unblock owner
- `ses_bounce`, `ses_complaint`: preflight failure `customer_broadcast script not found` in remote checkout.
  - Unblock owner: Stage rerun packaging contract in `chats/icg/may26_5pm_1_a1_in_vpc_probe_rerun.md` Stage 1 tarball list (must include `scripts/customer_broadcast.sh`), and probe dependency in `scripts/probe_ses_bounce_complaint_e2e.sh`.
- `dunning_email_inbox`, `staging_dunning_delivery`: `rehearsal_reset_failed` → `test_tenant_not_found` for an allowlisted tenant before mutation step.
  - Unblock owner: `scripts/validate_staging_dunning_delivery.sh` reset/mutation prerequisites + staging test-tenant data/allowlist source used by Stage rerun env (`FJCLOUD_TEST_TENANT_IDS`).
- `verify_email_clickthrough`, `password_reset_clickthrough`: clickthrough owner probes reached terminus timeout (`email_verified_at not set`, `password_reset_token not cleared`).
  - Unblock owner: clickthrough probe owners (`scripts/probe_verify_email_clickthrough_e2e.sh`, `scripts/probe_password_reset_clickthrough_e2e.sh`) and backing API state-transition path they validate.

## Evidence pointers
- `probe_results.tsv`
- `all_green.txt`
- `*.classification.txt` sidecars for each failed probe
