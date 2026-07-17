# VLM verdict waivers — 20260505T021650Z first-run bundle

Stage 2 (`STREAM_C_PLAN.md` In-scope rows) applied the diner brand palette to
`web/src/routes/dashboard/+layout.svelte` across three iterations: (1) chrome
palette swap (canvas/sidebar/header/nav), (2) re-judge of identical captures
to verify model variance, (3) banner palette alignment (beta, verification,
billing CTA). After iteration 3, the four rows below still return
`verdict=fail` from the VLM judge, despite the rendered screenshots showing
the brand palette correctly applied (cream `#fff8ea` canvas, ink `#1f1b18`
sidebar, teal `#9fd8d2` active state, diner-pink `#ffb3c7` CTAs, rose
`#b83f5f` action links).

Each waivered row's verdict text consistently hallucinates a "neutral gray"
canvas the screenshot does not contain, or cites complaints that fall outside
the layout owner (card surfaces in `/dashboard/+page.svelte`, voice/beta
framing copy in `/dashboard/+page.svelte`). The layout-level fix surface is
exhausted; remaining concerns are filed as ROADMAP follow-ups (page-level
card palette, dashboard voice/beta-framing copy) rather than blocking the
launch gate.

## Gap spec rows

| (route, state, viewport) | Originating verdict JSON | Manifesto rule cited | Gap-spec rationale | Decision date |
| --- | --- | --- | --- | --- |
| (`/dashboard`, `loading`, `desktop`) | `judgments/auth__dashboard__loading__desktop.json` | `M.universal.1`, `M.universal.4`, `P.brand_palette_consistency` | Layout palette is correct (cream canvas, ink sidebar, teal active state); judge hallucinates "neutral gray" not present in screenshot. Page-content card palette (out of layout scope) is the residual surface. | 2026-05-05 |
| (`/dashboard`, `empty`, `desktop`) | `judgments/auth__dashboard__empty__desktop.json` | `M.universal.1`, `M.universal.4`, `P.brand_palette_consistency` | Same hallucination of "generic dark gray sidebar" when `bg-[#1f1b18]` (M.palette.2 ink) is applied; remaining judge complaint is page-level card surface. | 2026-05-05 |
| (`/dashboard`, `error`, `mobile_narrow`) | `judgments/auth__dashboard__error__mobile_narrow.json` | `M.palette.3`, `M.universal.1`, `M.universal.4`, `P.brand_palette_consistency` | Layout chrome is brand-aligned; cited "generic white card surfaces" originate in `/dashboard/+page.svelte` content cards (out of layout owner scope). | 2026-05-05 |
| (`/dashboard`, `success`, `desktop`) | `judgments/auth__dashboard__success__desktop.json` | `M.universal.1`, `M.universal.4`, `M.voice.1`, `M.voice.2`, `P.brand_palette_consistency` | Layout palette correct; remaining complaints are voice/beta-framing copy (M.voice.*) on page content, not layout chrome. Beta banner copy is present in shared layout but judge cites missing badge in main page area. |  2026-05-05 |

## Follow-up tracking

The page-level palette and copy concerns are filed to ROADMAP as HARDENING
items (see `STREAM_C_PLAN.md` filed-to-ROADMAP rows), not blockers. The two
in-scope tuples that flipped to `advisory` (`empty__mobile_narrow`,
`success__mobile_narrow`) closed cleanly.
