# Stage 4 Blocker — source-pollution gate blocks the closeout push

> **RESOLVED (session s24):** This `repo-owned-prerequisite` blocker was fixed in
> the repo rather than deferred a second time. `scripts/sanitize_worktree_paths.sh
> --write` scrubbed the 11 rewritable evidence/DIRMAP files, and the two
> source/config leaks (`infra/api/src/router.rs` line 1,
> `web/tests/e2e-ui/full/index_detail_helpers.ts` line 2) had their
> worktree-absolute prefix replaced with the repo-relative path in place (stub
> text preserved). `scripts/sanitize_worktree_paths.sh --check` is now clean and
> `bash scripts/local-ci.sh --fast` reports `pass=17 fail=0`. The record below is
> retained so the Stage 1 output-quality regression stays visible in history.

- evidence_dir: docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z
- blocker_class: repo-owned-prerequisite (pre-existing, introduced before Stage 4)
- blocking_gate: `source-pollution` in `bash scripts/local-ci.sh --fast`
- stage4_secret_scan: PASS (`secret_scan_stage4.log`, pass=1 fail=0)
- stage4_fast_ci: FAIL (`local_ci_fast_stage4.log`, pass=16 fail=1)
- push_performed: no (a red HEAD must not be fast-forwarded onto main)
- readiness_verdict_unaffected: the browser-lane + parity verdict in `SUMMARY.md`
  is still `ready_all_green`; this blocker is about the branch's push mechanics,
  not the verification outcome.

## What failed

`bash scripts/local-ci.sh --fast` reports `pass=16 fail=1`, and the single
failing gate is `source-pollution`, which wraps
`scripts/sanitize_worktree_paths.sh --check`. Log tail (`local_ci_fast_stage4.log`):

```
--- source-pollution (1s) ---
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/head_comparison.txt
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/pages_parity_cloud_prod.command
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/pages_parity_cloud_staging.command
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/first_pass_outcome.md
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass.attempt_1.stderr.log
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass.json
[sanitize] would rewrite docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass_stats.txt
[sanitize] would rewrite infra/api/src/DIRMAP.md
[sanitize] requires manual cleanup infra/api/src/router.rs
[sanitize] would rewrite scripts/lib/DIRMAP.md
[sanitize] would rewrite scripts/tests/lib/DIRMAP.md
[sanitize] would rewrite web/tests/e2e-ui/full/DIRMAP.md
[sanitize] requires manual cleanup web/tests/e2e-ui/full/index_detail_helpers.ts
[sanitize] CHECK: run 'bash scripts/sanitize_worktree_paths.sh --write' to scrub rewritable files

Totals: pass=16 fail=1 skip=0
Result: FAIL
```

## Root cause

Worktree-absolute paths of the form
`/Users/<user>/parallel_development/<worktree>/fjcloud_dev/...` are committed on
this batman branch. They violate the CLAUDE.md hard rule against writing
worktree-absolute paths into tracked files.

The pollution predates Stage 4. It was introduced by Stage 1
(commit `26f99c956` "matt: stage 1 checklist"):

- `git show origin/main:infra/api/src/router.rs | head -1` → `use axum::response::{IntoResponse, Response};` (clean)
- `git show HEAD:infra/api/src/router.rs | head -1` → `//! Stub summary for /Users/.../parallel_development/.../infra/api/src/router.rs.`
- `git log -1 -S 'Stub summary for' -- infra/api/src/router.rs` → `26f99c956`

`origin/main` (`5f32d715639f13c353b6e6e8397aa528a8903b72`) does NOT contain any
of these leaks — the failure does not reproduce on the merge base. Because
`origin/main` is an ancestor of HEAD (ff-merge is possible), fast-forwarding
main to this branch and pushing would carry the Stage 1 pollution onto main.
That is exactly what the `source-pollution` gate exists to prevent, so the
push must not proceed.

### Polluted tracked files

Rewritable by the sanitizer (`--write`):
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/head_comparison.txt
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/pages_parity_cloud_prod.command
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T073756Z/pages_parity_cloud_staging.command
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/first_pass_outcome.md
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass.attempt_1.stderr.log
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass.json
- docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/playwright_first_pass_stats.txt
- infra/api/src/DIRMAP.md
- scripts/lib/DIRMAP.md
- scripts/tests/lib/DIRMAP.md
- web/tests/e2e-ui/full/DIRMAP.md

Flagged "requires manual cleanup" (source/config files the sanitizer will not
auto-rewrite — the worktree path sits in a `//!` / `@module` doc-comment header):
- infra/api/src/router.rs
- web/tests/e2e-ui/full/index_detail_helpers.ts

## Why Stage 4 does not scrub this here

Stage 4 is an **evidence-only** maintenance stage. Its parent-group-3 commit
guard requires the Stage 4 delta to be limited to the evidence directory
`docs/runbooks/evidence/polished-beta-staging-verify/20260708T082333Z/` — "no
product code or unrelated repo files should enter this maintenance commit."
Scrubbing the leaks requires editing product code (`infra/api/src/router.rs`)
and a test helper, which is outside this stage's mandate. Per the Stage 4
checklist, when the `--fast` failure "proves to be a pre-existing blocker
outside this evidence-only stage," the correct action is to stop and record
this blocker rather than push a red HEAD.

## Required fix (follow-up owner / Stage 1 re-run scope)

1. Run `bash scripts/sanitize_worktree_paths.sh --write` to scrub the 11
   rewritable files above.
2. Manually scrub the two source/config leaks — replace the worktree-absolute
   prefix with the repo-relative path in the doc-comment headers of:
   - `infra/api/src/router.rs` (line 1, `//! Stub summary for ...`)
   - `web/tests/e2e-ui/full/index_detail_helpers.ts` (line 2, `* @module Stub summary for ...`)
3. Re-run `bash scripts/local-ci.sh --fast` and confirm `source-pollution`
   passes (`pass=17 fail=0`).
4. Then perform the Stage 4 closeout push (ff-merge main to the batman SHA,
   `bash scripts/git_push_with_sync.sh origin main`).

This is a `repo-owned-prerequisite`: it is fixable inside the repo and must be
resolved before the wave can push. It is filed here (not silently fixed) so the
Stage 1 output-quality regression is visible rather than hidden inside an
evidence-only commit.
