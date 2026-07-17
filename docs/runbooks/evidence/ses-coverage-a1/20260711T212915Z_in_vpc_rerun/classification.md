## verify_email_clickthrough

Classification: `probe_defect`

Deployed `dev_sha`: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`

Evidence:

- Bundle 1: `docs/runbooks/evidence/ses-coverage-a1/20260711T212230Z_in_vpc_rerun`
  - Row: `rc=1`, parser `pass=0`
  - Parser terminus: missing `TERMINUS: email_verified=true`
  - Saved failure detail: `ERROR: email_verified_at not set after clickthrough for verifyprobe2026071121224729508@test.flapjack.foo after 15 attempts`
- Bundle 2: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`
  - Row: `rc=1`, parser `pass=0`
  - Parser terminus: missing `TERMINUS: email_verified=true`
  - Saved failure detail: `ERROR: email_verified_at not set after clickthrough for verifyprobe2026071121293132250@test.flapjack.foo after 15 attempts`

Concrete owner evidence:

- Probe assertion owner: `scripts/probe_verify_email_clickthrough_e2e.sh`. At deployed SHA `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`, the probe registers a customer, extracts the email token, requests `${APP_BASE_URL}/verify-email/${verify_token}`, requires HTTP 200, requires `data-success="true"`, then runs the DB assertion `SELECT CASE WHEN email_verified_at IS NULL THEN 'false' ELSE 'true' END FROM customers WHERE email = ...` before emitting `TERMINUS: email_verified=true`.
- Product route/repo owner: `infra/api/src/routes/auth.rs` calls `customer_repo.verify_email(&req.token)` and returns 200 only after that repo call returns a customer. `infra/api/src/repos/pg_customer_repo/verification.rs` updates `email_verified_at = NOW()`, clears `email_verify_token`, clears `email_verify_expires_at`, and then reloads the customer.

Disposition:

The red signal is current and reproducible on the same deployed SHA, but the saved logs reached the probe's final DB assertion rather than an earlier registration, inbox, HTTP, or page-success gate. The smallest later fix owner is `scripts/probe_verify_email_clickthrough_e2e.sh`; if the later fix proves the nested staging DB read is shared, the owner can narrow to `scripts/lib/clickthrough_probe_common.sh`.

Open questions:

- The exact DB-read mismatch is not isolated in this stage. The common hypothesis is that the probe-owned SQL assertion path is reading a different or stale DB view from the API/page path that just returned success.

## password_reset_clickthrough

Classification: `probe_defect`

Deployed `dev_sha`: `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`

Evidence:

- Bundle 1: `docs/runbooks/evidence/ses-coverage-a1/20260711T212230Z_in_vpc_rerun`
  - Row: `rc=1`, parser `pass=0`
  - Parser terminus: missing `TERMINUS: login succeeded with new password`
  - Saved failure detail: `ERROR: password_reset_token not cleared after reset for resetprobe202607112123593882@test.flapjack.foo after 15 attempts`
- Bundle 2: `docs/runbooks/evidence/ses-coverage-a1/20260711T212915Z_in_vpc_rerun`
  - Row: `rc=1`, parser `pass=0`
  - Parser terminus: missing `TERMINUS: login succeeded with new password`
  - Saved failure detail: `ERROR: password_reset_token not cleared after reset for resetprobe2026071121304318305@test.flapjack.foo after 15 attempts`

Concrete owner evidence:

- Probe assertion owner: `scripts/probe_password_reset_clickthrough_e2e.sh`. At deployed SHA `b0fc91ff9580e5e79d7c4f5a0d4576f41e55f4ff`, the probe registers a customer, requests a reset email, extracts the reset token, posts `/auth/reset-password`, then logs in with the new password and matching `customer_id` before running the DB assertion `SELECT CASE WHEN password_reset_token IS NULL THEN 'cleared' ELSE 'present' END FROM customers WHERE id = ...`.
- Product route/repo owner: `infra/api/src/routes/auth.rs` hashes the new password, calls `customer_repo.reset_password(&req.token, &new_hash)`, and returns 200 only if the repo update reports success. `infra/api/src/repos/pg_customer_repo/password_reset.rs` updates the same row by `password_reset_token`, sets `password_hash = $2`, clears `password_reset_token`, clears `password_reset_expires_at`, and returns `rows_affected() > 0`.

Disposition:

The red signal is current and reproducible on the same deployed SHA, but the probe passed the user-visible reset and login gates before failing only the DB token-clear assertion. Because the product repo clears the token in the same SQL update that makes the new password usable, the smallest later fix owner is `scripts/probe_password_reset_clickthrough_e2e.sh`; if the later fix proves the nested staging DB read is shared, the owner can narrow to `scripts/lib/clickthrough_probe_common.sh`.

Open questions:

- The exact DB-read mismatch is not isolated in this stage. The common hypothesis is that the probe-owned SQL assertion path is reading a different or stale DB view from the API/login path that just authenticated the new password.
