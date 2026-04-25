# Landing Screen Spec

## Scope

- Primary route: `/`
- Related routes: `/login`, `/signup`, `/status`
- Audience: unauthenticated prospects
- Priority: P0

## User Goal

Understand what Flapjack Cloud offers, evaluate basic pricing, and start signup or login without needing support.

## Target Behavior

The page renders the Flapjack Cloud brand, a public header with `Log In` and `Sign Up`, a visible public-beta banner that links to `/beta`, the `Managed search API` hero, value propositions, pricing content, free-tier promise text, minimum monthly spend, region pricing when available, an interactive pricing calculator, and footer links to `/terms`, `/privacy`, and `/dpa`.

## Required States

- Loading: server-rendered page should display complete public content on first paint; no client-only spinner is required.
- Empty: if optional region pricing is empty, hide only the region-pricing table while preserving core pricing and calculator content.
- Error: pricing fallback data should still produce readable public pricing content rather than a broken page.
- Success: CTA links navigate to `/signup`; login link navigates to `/login`; calculator returns Flapjack Cloud and competitor comparison rows after valid inputs.

## Controls And Navigation

- Header `Log In` link goes to `/login`.
- Header and body signup CTAs go to `/signup`.
- Documentation link goes to external docs.
- Beta banner link goes to `/beta`.
- Footer legal links go to `/terms`, `/privacy`, and `/dpa`.
- Pricing calculator accepts document/search/write/sort/index inputs and renders comparison results.

## Acceptance Criteria

- [ ] The default screen body renders page-specific content, not only shared navigation.
- [ ] Free-tier promise appears in hero/body/pricing contexts.
- [ ] Pricing calculator verifies exact comparison outcome for representative inputs.
- [ ] Primary auth CTAs navigate to the correct auth pages.
- [ ] Public beta framing and legal links are visible before signup.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: `web/src/routes/landing.test.ts`; `web/src/lib/components/LandingPricingCalculator.test.ts`
- Server/contract tests: pricing data is covered through route/component tests.
