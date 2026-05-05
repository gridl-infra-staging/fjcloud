# Stream C closure — post-fixes VLM verdict accounting

**Post-fixes bundle:** `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes`
**First-run baseline:** `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run`
**Closure date:** 2026-05-05
**HEAD at re-judge:** `b6b9e1d7`

## Summary

All 6 originally in-scope `/dashboard` tuples have an internally-consistent disposition. **4 closed** (verdict=`advisory`) and **2 waivered** (verdict=`fail`, both in `WAIVERS.md`). No row has `verdict=fail` without a waiver, so no tuple loops back to Stage 2.

Two tuples that the Stage 2 work documented as waivered (`empty__desktop`, `error__mobile_narrow`) flipped to `advisory` on the post-fixes re-judge. Those waivers (and their ROADMAP HARDENING rows at lines 198 and 199) are now unused — Stage 4 may either drop the rows or rewrite them into voluntary follow-ups.

| Bucket | Count |
|---|---|
| closed (advisory) | 4 |
| waivered (fail + WAIVERS row) | 2 |
| fail (no waiver) | 0 |
| **total** | **6** |

## Closure rows — original 6 in-scope dashboard tuples

Source-of-truth in-scope row order: `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/STREAM_C_PLAN.md` rows 1–6.

| # | Route | State | Viewport | First-run verdict | Post-fixes verdict | Disposition | Post-fixes JSON | First-run JSON | Waiver / ROADMAP |
|---|---|---|---|---|---|---|---|---|---|
| 1 | /dashboard | loading | desktop | fail | **fail** | **waivered** | `judgments/auth__dashboard__loading__desktop.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__desktop.json` | `WAIVERS.md` row 1; `ROADMAP.md` line 197 |
| 2 | /dashboard | empty | desktop | fail | **advisory** | **closed** | `judgments/auth__dashboard__empty__desktop.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__desktop.json` | waiver unused (was `WAIVERS.md` row 2 / `ROADMAP.md` line 198) |
| 3 | /dashboard | empty | mobile_narrow | fail | **advisory** | **closed** | `judgments/auth__dashboard__empty__mobile_narrow.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__empty__mobile_narrow.json` | n/a (no waiver, in-scope EMBARRASSING in first run) |
| 4 | /dashboard | error | mobile_narrow | fail | **advisory** | **closed** | `judgments/auth__dashboard__error__mobile_narrow.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__error__mobile_narrow.json` | waiver unused (was `WAIVERS.md` row 3 / `ROADMAP.md` line 199) |
| 5 | /dashboard | success | desktop | fail | **fail** | **waivered** | `judgments/auth__dashboard__success__desktop.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__desktop.json` | `WAIVERS.md` row 4; `ROADMAP.md` line 200 |
| 6 | /dashboard | success | mobile_narrow | fail | **advisory** | **closed** | `judgments/auth__dashboard__success__mobile_narrow.json` | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__success__mobile_narrow.json` | n/a (no waiver, in-scope EMBARRASSING in first run) |

## Newly surfaced regressions in the post-fixes bundle

The Stage 3 checklist requires calling out any tuple previously all-clear or out-of-scope that now appears under `### BLOCKER` or `### EMBARRASSING`. Diff details:

- `### BLOCKER` bucket: empty in both first-run and post-fixes bundles. No regressions.
- `### EMBARRASSING` bucket — severity-bumped tuples (already filed to `ROADMAP.md` HARDENING in first-run plan, now bumped to EMBARRASSING by the post-fixes judge despite verdict=`pass`):

| Route | State | Viewport | First-run severity | Post-fixes severity | Post-fixes verdict | First-run JSON | Post-fixes JSON |
|---|---|---|---|---|---|---|---|
| /privacy | success | desktop | HARDENING | EMBARRASSING | pass | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__privacy__success__desktop.json` | `judgments/public__privacy__success__desktop.json` |
| /privacy | success | mobile_narrow | HARDENING | EMBARRASSING | pass | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__privacy__success__mobile_narrow.json` | `judgments/public__privacy__success__mobile_narrow.json` |
| /dpa | success | mobile_narrow | HARDENING | EMBARRASSING | pass | `docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__dpa__success__mobile_narrow.json` | `judgments/public__dpa__success__mobile_narrow.json` |

These are not net-new findings — each route+state pair is already filed to `ROADMAP.md` HARDENING (lines 187, 188, 189). The aggregate verdict on each is still `pass`, so they remain non-blocking. The severity bump is from per-violation severity inflation by the judge between runs, not new defects. Stage 4 may treat the existing ROADMAP rows as sufficient or annotate them with the post-fixes pointer.

No tuple that was previously all-clear in the first-run bundle moved into `### BLOCKER` or `### EMBARRASSING`.

## All-clear and uncovered (post-fixes)

Per `STREAM_C_INPUT.md`:

- All-clear lanes: `/admin/customers loading mobile_narrow` (advisory in first-run, all-clear now).
- Uncovered tuples (unchanged from first-run): the 4 admin `empty` and `error` tuples that require server-side mocking (filed in `web/tests/e2e-ui/full/vlm_capture/tuples.ts` as `unproducible_requires_server_side_mocking`).

## Cost ledger

Post-fixes run cost: $0.27 (within the $5.00 cap). Cumulative ledger entry in `cost_log.jsonl`.

## Lint / repo state at closure

- HEAD: `b6b9e1d7` (`style: add DIRMAP.md to prettierignore and fix pre-existing prettier drift`).
- `cd web && npm run lint` passes cleanly.
- The 88-file Prettier drift the previous Stage 3 session flagged was pre-existing repo-wide drift (also present on `main`), not a Stage 2 carryover. It was fixed at `b6b9e1d7` by adding `DIRMAP.md` to `.prettierignore` and formatting the remaining drift.

## Stage routing

- 4 closed + 2 waivered = 6 → no tuple loops back to Stage 2.
- Stage 4 owns annotations to `STREAM_C_PLAN.md`, `docs/NOW.md`, and `ROADMAP.md` (including the unused-waiver lines 198 and 199, the persistent waivered lines 197 and 200, and any post-fixes pointer additions).
