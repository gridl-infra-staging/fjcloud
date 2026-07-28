# Landing Screen Spec

## Scope

- Primary route: `/`
- Related routes: `/login`, `/status`
- Audience: unauthenticated prospects
- Priority: P0

## User Goal

Understand what Flapjack Cloud offers, evaluate basic pricing, and reach login without needing support.

## Target Behavior

The page renders the Flapjack Cloud brand, a public header with `Log In`, a visible public-beta banner that links to `/beta`, the `Managed search API` hero, value propositions, pricing content, the four-cap free-tier promise text, Shared-plan minimum framing, region pricing when available, an interactive pricing calculator, and footer links to `/terms`, `/privacy`, `/dpa`, external docs, and the public community discussion hub. Public signup discovery is withdrawn per `decisions/2026-05-23_beta_signup_gate.md` while the direct `/signup` route remains reachable.

## Required States

- Loading: server-rendered page should display complete public content on first paint; no client-only spinner is required.
- Empty: if optional region pricing is empty, hide only the region-pricing table while preserving core pricing and calculator content.
- Error: pricing fallback data should still produce readable public pricing content rather than a broken page.
- Success: login link navigates to `/login`; public signup CTAs are absent; calculator returns Flapjack Cloud and competitor comparison rows after valid inputs.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). The public header, beta banner, hero promise, core pricing/free-tier copy, calculator controls, and legal footer links remain readable and usable in one column without horizontal scrolling or signup discovery CTAs.

## Controls And Navigation

- Header `Log In` link goes to `/login`.
- Public signup CTAs are absent; direct `/signup` reachability is covered by the signup route.
- Documentation link goes to external docs.
- Beta banner link goes to `/beta`.
- Footer legal links go to `/terms`, `/privacy`, and `/dpa`.
- `SiteFooter.svelte` exposes footer `Docs` and `Community` links, with canonical destinations owned by `web/src/lib/format.ts`.
- Pricing calculator accepts document/search/write/sort/index inputs and renders comparison results.

## Acceptance Criteria

- [ ] The default screen body renders page-specific content, not only shared navigation.
- [ ] Free-tier promise appears in hero/body/pricing contexts.
- [ ] Pricing calculator verifies exact comparison outcome for representative inputs.
- [ ] Primary public auth navigation goes to login only.
- [ ] Public beta framing and legal links are visible without signup discovery CTAs.
- [ ] Public footer exposes Docs and Community links from `SiteFooter.svelte` using the shared support-routing destination owner.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`; `web/tests/e2e-ui/full/support-routing.spec.ts`
- Component tests: `web/src/routes/layout.test.ts`; `web/src/lib/components/LandingPricingCalculator.test.ts`
- Server/contract tests: `web/src/routes/page.server.test.ts` pins unauthenticated root pricing data and dynamic SSR.
