# Invite-Ready RC Findings

Bundle: `docs/runbooks/evidence/invite-ready-rc/20260604T131655Z/`
Run timestamp: `2026-06-04T13:21:30Z` from harness-owned `summary.json`

## Harness Dispatch

Stage 4 reused the existing RC owner instead of creating a parallel probe path.
`scripts/launch/run_full_backend_validation.sh --paid-beta-rc` wrote the
authoritative `summary.json` and per-step logs directly into this bundle via
`--artifact-dir`. `scripts/launch/post_deploy_evidence_capture.sh:130-338` was
used only as layout precedent for preserving the same harness output under an
evidence directory.

Sources:
- `LAUNCH.md:31-49` defines the allowed paid-beta verdict labels and acceptance policy.
- `docs/launch_verification_matrix.md:29-41` defines the aggregate section-status mapping.
- `docs/launch_verification_matrix.md:82-92` records Section 1 as `partial` and Sections 2-6 as `live`.
- `LAUNCH.md:452-456` preserves the 2026-05-31 precedent that `critical_surface_skipped` rows for `browser_signup_paid` and `browser_portal_cancel` do not count as `other_real` defects by themselves.

## Summary Harvest

Authoritative summary: `summary.json`

Concrete summary facts:
- `mode`: `paid_beta_rc`
- `ready`: `false`
- `rc_exit_code.txt`: `1`
- Step status counts: 10 `pass`, 5 `external_secret_missing`, 3 `live_evidence_gap`, 1 `skip`, 3 `fail`
- Failing rows: `browser_auth_setup` / `browser_auth_setup_failed`, `browser_signup_paid` / `critical_surface_skipped`, `browser_portal_cancel` / `critical_surface_skipped`

The exit-code relationship is internally consistent: the run exited non-zero and
the harness reported `ready=false`.

## Verdict

`verdict.txt` is `NOT-READY`.

Reasoning:
- The Section 1 matrix state still permits the pre-authorized
  `NOT-READY-on-section-1` shape when no other real defect is present.
- The two `critical_surface_skipped` browser rows match the documented 2026-05-31
  allowlist precedent and are not enough by themselves to force plain
  `NOT-READY`.
- `browser_auth_setup` is a separate hard `fail`, and the step log shows
  `ERR_MODULE_NOT_FOUND` for `@playwright/test` plus a live API auth response
  `{"error":"invalid email or password"}` for the configured browser user.
  That is not the Section 1-only residual shape, and Sections 2-6 are currently
  `live`; per the matrix aggregate rule, this fresh regression forces plain
  `NOT-READY`.

Required Wave-3 follow-up path for the plain `NOT-READY` shape:
`chats/icg/wave3_browser_auth_setup.md`.

## Live Build Anchor

Stage 1 live `/version` artifacts anchor the deployed build exercised by this
run:
- staging `dev_sha`: `26530584c00b215cec178044fe371bd0d47678db`
- production `dev_sha`: `26530584c00b215cec178044fe371bd0d47678db`

## Open Questions

- Whether the `browser_auth_setup` failure is caused by missing web dependencies
  in this checkout, stale live seeded browser credentials, or both. The bundle
  preserves the exact owner logs for the Wave-3 lane; Stage 4 does not patch or
  retry harness code.
