# Tenant Isolation Proptest — Stage 3 Verification Bundle

Verification UTC: 20260710T210633Z
Command-run HEAD (local proof): `cb551b1078156c0289441d6f3ff939a6b51f86f2`
Packaging HEAD: `9d052f430556e4cfd1ee2a3d3851f7bd07f20316`

The local proof logs were captured while running the Stage 1 commands at HEAD
`cb551b107`. Packaging happened at `9d052f430`; `git diff cb551b107..9d052f430 -- infra/`
is empty, so the tenant-isolation runtime under test is byte-identical between the
two commits (the intervening commits are checklist/matt bookkeeping only).

## Disposition

**deployed-confirmed.** The tenant-isolation regression first seen on staging
nightly run `29012587136` (2026-07-09) is closed. The local proptest lane is
green at current main, and the deployed staging nightly re-ran the exact nightly
command against a mirror that contains the fix and reported the
`tenant-isolation-proptest` job as `success`.

This supersedes the prior "deployed-nightly confirmation is still unproven"
residual noted in the 2026-07-09 bundle
(`docs/runbooks/evidence/tenant-isolation-proptest/20260709T184001Z/SUMMARY.md`),
which remains the canonical root-cause narrative (test-contract drift, not a
cross-tenant leak).

## Local Proof (Stage 1)

Both commands were run from the repo root at HEAD `cb551b107`; raw stdout is stored
beside this file.

- PASS: `cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::`
  - Raw log: `tenant_isolation_proptest.stdout.txt`.
  - Result: `test result: ok. 6 passed; 0 failed; 0 ignored; 0 measured; 1087 filtered out`.
  - All six module tests pass, including `tenant_isolation_proptest_route_family`
    and `tenant_isolation_proptest_deliberate_leaky_variant_trips_failure_signature`
    (the leaky-variant guard proving the isolation assertion still has teeth).
- PASS: `cargo test -p api --test platform` (surrounding platform lane)
  - Raw log: `platform.stdout.txt`.
  - Result: `test result: ok. 1079 passed; 0 failed; 8 ignored; 0 measured; 0 filtered out`.

## Deployed Nightly Proof (Stage 2)

Nightly owner: `.github/workflows/nightly.yml:39-64`. The job runs the exact same
command as the local proof: `cd infra && cargo test -p api --test platform
--features proptest-tests tenant_isolation_proptest::`.

Read-only staging evidence (raw sidecars stored beside this file):

- Run list: `nightly_run_list.json` — the newest `nightly.yml` run remains
  `29078095358` (created 2026-07-10T07:54:35Z, `headSha`
  `c690aa8783b73b47b0100e520da377ecf6f4aec8`, workflow conclusion `success`). No
  newer post-boundary nightly exists, so `29078095358` is the controlling
  deployed evidence.
- Job projection: `nightly_run_29078095358_jobs.json` — records
  `tenant-isolation-proptest` job conclusion `success` (alongside
  `stripe-test-clock-live` and `pricing-freshness`, both `success`).
- Boundary proof: `nightly_boundary_proof.json` — the controlling run head
  `c690aa8783b73b47b0100e520da377ecf6f4aec8` is **after** the exact post-fix mirror
  boundary `a2ffa5f9c92da7e0e623eda0a5cde85a77f4717f`, whose
  `.debbie/sync_manifest.json` `dev_sha` is exactly
  `c0dfeebe8f41bb505c7e361fdde3427e1974ab05` (the merged fix commit). The compare
  `a2ffa5f9…c690aa87` is `ahead_by: 3, behind_by: 0` — the run head strictly
  descends from the boundary, so the deployed test exercised code that contains
  the fix.

### Distinguishing deployed-confirmed from local-only

- `deployed-confirmed` requires (a) a green local proptest lane **and** (b) a
  staging `nightly.yml` run whose head descends from a mirror commit carrying the
  fix (`dev_sha == c0dfeebe8…`) with `tenant-isolation-proptest` job `success`.
- `local-only pending nightly` would apply if only (a) held — i.e. the newest
  nightly predated the fix mirror boundary or its job was not `success`.
- Both (a) and (b) hold here, so the disposition is `deployed-confirmed`.

## Controlling Run / Commit IDs

| Role | Value |
| --- | --- |
| Original failing nightly | `29012587136` (2026-07-09, `headSha` `8f6aa59f…`, conclusion `failure`) |
| Fix commit (dev) | `c0dfeebe8f41bb505c7e361fdde3427e1974ab05` |
| Post-fix mirror boundary (staging) | `a2ffa5f9c92da7e0e623eda0a5cde85a77f4717f` (`dev_sha` `c0dfeebe8…`) |
| Controlling deployed nightly | `29078095358` (2026-07-10T07:54:35Z, `headSha` `c690aa8783b73b47b0100e520da377ecf6f4aec8`) |
| Prior post-boundary nightly (context only) | `29044920073` (2026-07-09T19:36:03Z, `headSha` `a2f013b5…`, conclusion `success`) |

## Portability Note

Ephemeral worktree path prefixes in the cargo compile-location lines of the local
logs were scrubbed to repo-relative paths before commit (matching
`scripts/sanitize_worktree_paths.sh` behavior) so the bundle stays portable and
passes the source-pollution gate. Command text, pass/fail lines, and durations are
preserved verbatim.
