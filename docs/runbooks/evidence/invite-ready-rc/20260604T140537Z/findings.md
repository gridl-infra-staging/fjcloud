---
created: 2026-06-04
updated: 2026-06-04
---

# Invite-Ready RC Rerun Findings

Bundle: `docs/runbooks/evidence/invite-ready-rc/20260604T140537Z/`
Run timestamp: `2026-06-04T14:06:11Z` from harness-owned `summary.json`

## Harness Owner

Stage 4 reused `scripts/launch/run_full_backend_validation.sh --paid-beta-rc`.
The harness wrote the authoritative `summary.json` and per-step logs directly
into this bundle via `--artifact-dir`. `scripts/launch/post_deploy_evidence_capture.sh:130-338`
remains only the wrapper-layout precedent.

## Summary Harvest

Authoritative summary: `summary.json`.

Concrete summary facts:

- `mode`: `paid_beta_rc`
- `ready`: `false`
- `rc_exit_code.txt`: `1`
- Step status counts: 10 `pass`, 6 `external_secret_missing`, 3
  `live_evidence_gap`, 1 `skip`, 2 `fail`
- Hard failing rows: `browser_signup_paid` / `critical_surface_skipped` and
  `browser_portal_cancel` / `critical_surface_skipped`
- `browser_auth_setup` is `external_secret_missing` with reason
  `browser_auth_setup_env_gap`

The exit-code relationship is internally consistent: the run exited non-zero
and the harness reported `ready=false`.

## Verdict

`verdict.txt` is `NOT-READY-on-section-1`.

Reasoning:

- `docs/launch_verification_matrix.md:29-41` maps the only
  pre-authorized not-live launch shape to Section 1 partial.
- `docs/launch_verification_matrix.md:82-92` records Section 1 as `partial`
  and Sections 2-6 as `live`.
- The only hard failures in this fresh RC summary are the documented
  `critical_surface_skipped` allowlist rows for `browser_signup_paid` and
  `browser_portal_cancel`.
- `LAUNCH.md:452-456` preserves the 2026-05-31 precedent that those
  `critical_surface_skipped` rows do not count as `other_real` defects by
  themselves.

## Live Build Anchor

Required Stage 1 deploy-state artifacts record both live surfaces at
`dev_sha=26530584c00b215cec178044fe371bd0d47678db`:

- `/Users/stuart/.matt/projects/fjcloud_dev-051f15c3/jun04_am_4_invite_ready_section1_evidence_and_rc_verdict.md-eea0cb6e/stage_artifacts/stage_01/version_staging.json`
- `/Users/stuart/.matt/projects/fjcloud_dev-051f15c3/jun04_am_4_invite_ready_section1_evidence_and_rc_verdict.md-eea0cb6e/stage_artifacts/stage_01/version_prod.json`

Because this rerun happened later, the live `/version` owner was re-probed with
`bash scripts/deploy_status.sh --json` and preserved as `deploy_status.json`.
That fresh probe reports both prod and staging at
`dev_sha=802e16e09c3cc47a4fa3e553a286756b5c9b1610`, with build times
`2026-06-04T12:24:23Z` and `2026-06-04T12:24:54Z` respectively, before the
`2026-06-04T14:06:11Z` harness summary timestamp. This rerun should therefore
be cited against the `802e16e...` deployed build, while the original Stage 1
artifacts remain the earlier gate evidence.

## Open Questions

Open questions: none.
