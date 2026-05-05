# Stream C plan — VLM verdict triage

**Bundle:** docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run
**Triage date:** 2026-05-04
**Post-classification totals:** 6 In-scope (EMBARRASSING) + 11 Filed-to-ROADMAP (9 HARDENING + 2 MAINT) = 17

## In-scope

All 6 findings are dashboard brand-palette consistency violations rooted in `web/src/routes/dashboard/+layout.svelte`. The authenticated dashboard uses a generic dark/neutral UI palette instead of the diner brand palette (teal #9fd8d2, cream #fff8ea, ink #1f1b18). Single-owner batch fix in `web/src/routes/dashboard/+layout.svelte` (plus any shared dashboard CSS variables).

| # | Route | State | Viewport | Verdict JSON | Rule | Fix sketch |
|---|-------|-------|----------|--------------|------|-----------|
| 1 | /dashboard | loading | desktop | `judgments/auth__dashboard__loading__desktop.json` | P.brand_palette_consistency + M.universal.1 + M.universal.4 | Swap sidebar/canvas/card colors to brand tokens (teal bg, cream cards, ink text) |
| 2 | /dashboard | empty | desktop | `judgments/auth__dashboard__empty__desktop.json` | P.brand_palette_consistency + M.universal.1 + M.universal.4 | Same batch — dashboard layout token swap |
| 3 | /dashboard | empty | mobile_narrow | `judgments/auth__dashboard__empty__mobile_narrow.json` | P.brand_palette_consistency + M.universal.1 + M.universal.4 | Same batch — dashboard layout token swap |
| 4 | /dashboard | error | mobile_narrow | `judgments/auth__dashboard__error__mobile_narrow.json` | P.brand_palette_consistency + M.universal.1 + M.universal.4 | Same batch — dashboard layout token swap |
| 5 | /dashboard | success | desktop | `judgments/auth__dashboard__success__desktop.json` | P.brand_palette_consistency + M.universal.1 + M.universal.4 | Same batch — dashboard layout token swap |
| 6 | /dashboard | success | mobile_narrow | `judgments/auth__dashboard__success__mobile_narrow.json` | P.brand_palette_consistency + M.universal.1 | Same batch — dashboard layout token swap |

**Stage 2 batching:** All 6 share the same root cause (dashboard layout uses generic palette) and the same owner file (`web/src/routes/dashboard/+layout.svelte`). Fix once, verify all 6 tuples pass in a single VLM re-judge run.

### Closure annotations (2026-05-05)

Source: `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/CLOSURE.md`

| # | Disposition | Commit / Waiver | Post-fixes evidence |
|---|---|---|---|
| 1 | **waivered** (verdict=fail) | WAIVED: `WAIVERS.md` row 1 | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__loading__desktop.json` |
| 2 | **closed** (verdict=advisory) | fix commit SHA: `cbbe0f96` | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__empty__desktop.json` |
| 3 | **closed** (verdict=advisory) | fix commit SHA: `cbbe0f96` | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__empty__mobile_narrow.json` |
| 4 | **closed** (verdict=advisory) | fix commit SHA: `cbbe0f96` | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__error__mobile_narrow.json` |
| 5 | **waivered** (verdict=fail) | WAIVED: `WAIVERS.md` row 4 | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__success__desktop.json` |
| 6 | **closed** (verdict=advisory) | fix commit SHA: `cbbe0f96` | `docs/runbooks/evidence/ui-polish/20260505T051119Z_post_fixes/judgments/auth__dashboard__success__mobile_narrow.json` |

Tally: 4 closed + 2 waivered = 6 (all In-scope rows resolved).

## Filed-to-ROADMAP

All rows below are net-new (no existing `(route, state)` match in ROADMAP.md). No rows were skipped by dedup.

### HARDENING (9 rows — 5 original + 4 demoted from EMBARRASSING)

| # | Route | State | Viewport | ROADMAP row text | Tag |
|---|-------|-------|----------|-----------------|-----|
| 1 | /privacy | success | desktop | VLM polish: /privacy desktop missing card border + shadow (M.density.6, M.density.7) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__privacy__success__desktop.json)` |
| 2 | /privacy | success | mobile_narrow | VLM polish: /privacy mobile uses gray background instead of cream canvas (M.universal.1, M.palette.1) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__privacy__success__mobile_narrow.json)` |
| 3 | /dpa | success | mobile_narrow | VLM polish: /dpa mobile uses white background instead of cream, heading not font-black (M.universal.1, M.typography.4) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__dpa__success__mobile_narrow.json)` |
| 4 | /dashboard | loading | mobile_narrow | VLM polish: /dashboard loading mobile uses neutral gray instead of brand palette (M.universal.1, P.brand_palette_consistency) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__loading__mobile_narrow.json)` |
| 5 | /dashboard | error | desktop | VLM polish: /dashboard error desktop dark sidebar conflicts with brand palette (P.brand_palette_consistency) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/auth__dashboard__error__desktop.json)` |
| 6 | /terms | success | desktop | VLM polish: /terms desktop text uses slightly lighter shade than ink #1f1b18 (M.palette.2) — demoted, contrast acceptable | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__terms__success__desktop.json)` |
| 7 | /terms | success | mobile_narrow | VLM polish: /terms mobile link uses slightly lighter rose than #b83f5f (M.palette.10) — demoted, sub-perceptible | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__terms__success__mobile_narrow.json)` |
| 8 | /dpa | success | desktop | VLM polish: /dpa desktop card background white instead of cream #fff8ea (M.palette.3) — demoted, within standard design norms | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/public__dpa__success__desktop.json)` |
| 9 | /admin/customers | loading | mobile_narrow | VLM polish: /admin/customers loading mobile admin-theme diverges from brand palette (P.brand_palette_consistency) — demoted, admin-only surface | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/admin__admin_customers__loading__mobile_narrow.json)` |

### MAINT (2 rows)

| # | Route | State | Viewport | ROADMAP row text | Tag |
|---|-------|-------|----------|-----------------|-----|
| 1 | /admin/customers | success | desktop | VLM polish: /admin/customers table header hierarchy and control spacing could be improved (rule_id=null) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/admin__admin_customers__success__desktop.json)` |
| 2 | /admin/customers | filter_empty | mobile_narrow | VLM polish: /admin/customers filter-empty placeholder shows test data instead of user-friendly text (rule_id=null) | `(VLM-H, docs/runbooks/evidence/ui-polish/20260505T021650Z_first_run/judgments/admin__admin_customers__filter_empty__mobile_narrow.json)` |

## Demotions/promotions

### Demotions (EMBARRASSING → HARDENING): 4

| Finding | Original | New | Rationale |
|---------|----------|-----|-----------|
| /terms success desktop (M.palette.2) | EMBARRASSING | HARDENING | VLM itself notes "contrast remains acceptable." The shade difference is sub-perceptible without color-picker instrumentation. No reasonable launch reviewer would reject signup over this. |
| /terms success mobile_narrow (M.palette.10) | EMBARRASSING | HARDENING | "Slightly lighter rose" on a single support email link. Sub-perceptible color delta that does not affect brand coherence at signup-decision time. |
| /dpa success desktop (M.palette.3) | EMBARRASSING | HARDENING | White card on cream background is a standard design pattern. DPA is a legal compliance page — users visit it to read content, not to evaluate brand quality. Does not embarrass the product. |
| /admin/customers loading mobile_narrow (P.brand_palette_consistency) | EMBARRASSING | HARDENING | Admin interface is operator-only — no prospective customer ever sees it. Brand-palette consistency rule was designed for customer-facing surfaces. Dark admin theme is an intentional UX distinction, not an omission. |

### Promotions (HARDENING → EMBARRASSING): none

/privacy mobile_narrow was considered for promotion (wrong background on a public page), but privacy pages are read for content, not visual quality — the gray-vs-cream difference would not cause a signup reviewer to reject the product.
