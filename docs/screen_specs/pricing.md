# Pricing Screen Spec

## Scope

- Primary route: `/pricing`
- Related routes: `/`, `/login`, `/beta`, `/status`, `/terms`, `/privacy`, `/dpa`
- Audience: unauthenticated prospects comparing Flapjack Cloud pricing
- Priority: P0

## User Goal

Understand current public pricing terms (rates, four-cap free-tier promise, Paid-plan upgrade framing, and region multipliers) without reading unrelated landing-only marketing sections.

## Target Behavior

The `/pricing` route is a public unauthenticated screen that reuses the existing marketing pricing owner (`MARKETING_PRICING`) for copy and displayed values already established on `/`. Canonical plan semantics live in `docs/design/pricing_contract.md`; this route spec should reference that owner rather than restating billing-floor rules. The page centers pricing content: free-tier promise, the `250 MB` allowance, hot/cold storage rows, Paid-plan minimum framing, and region multipliers. Public signup discovery is withdrawn per `decisions/2026-05-23_beta_signup_gate.md`, so the shared pricing CTA label remains a data owner and direct `/signup` stays reachable, but the CTA does not render on `/pricing`.

Landing-only framing stays on `/` (for example: broader product feature storytelling, quick-facts panel, and full mixed marketing sections). The `/pricing` route should avoid introducing a parallel pricing copy source or alternate pricing constants.

The landing calculator on `/` must disclose comparison publishability from the pricing API response. When `/api/pricing/compare` returns `withheld_providers`, the calculator renders the pricing comparison withheld-providers affordance near the results table with each API-supplied display name and reason. When the array is empty, the affordance is absent. Estimate rows keep a single pricing-source concept: published rows show verified source dates, while legacy fallback payloads with `unverified` remain labeled as modeled pricing.

Stage 4 backend-alignment drift detection must extend this same owner: compare `web/src/lib/pricing.ts::MARKETING_PRICING` against normalized admin rate-card data exposed as `web/src/lib/admin-client.ts::AdminRateCard` via `getTenantRateCard()` and backed by `infra/api/src/routes/admin/rate_cards.rs::get_rate_card()`. Do not introduce a second checked-in pricing snapshot.

## Required States

- Loading: server-rendered first paint with complete static pricing content; no client-only loading state is required.
- Empty: not applicable when pricing data is sourced from the static `MARKETING_PRICING` owner.
- Error: not applicable for Stage 1 contract definition because the pricing owner is static and required in the current public-route seam.
- Success: the page renders exact shared pricing values, omits signup discovery CTAs, and routes policy/status links to existing public routes.
- Landing comparison success: calculator results render estimates, generated time, and a withheld-provider sentence only when the API returns one or more withheld providers.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). Pricing cards, free-tier promise, hot/cold rows, Paid-plan minimum framing, region multipliers, and public-route links stack without overlap or horizontal scrolling, while preserving the absence of signup discovery CTAs.

## Controls And Navigation

- Primary pricing CTA is absent while signup discovery is withdrawn.
- Public auth navigation exposes `/login` without a `/signup` discovery link.
- Beta and policy/status destinations stay in the current public-route system (`/beta`, `/status`, `/terms`, `/privacy`, `/dpa`).
- External API documentation links (if present on `/pricing`) should use the same destination already used by the landing route.

## Acceptance Criteria

- [ ] `/pricing` is reachable as a public, unauthenticated route and renders page-specific body content on first paint.
- [ ] Pricing rows match shared constants: hot storage `$0.05` per MB-month and cold snapshot storage `$0.02` per GB-month.
- [x] Paid-plan minimum framing renders from `shared_minimum_spend_cents` (`1500` cents, shown as `$15`) and does not claim a Free-plan billing floor.
- [ ] Free-tier promise and `250 MB` allowance are sourced from shared pricing data (`Free up to 3 indices, 100,000 records, 250 MB storage, and 50,000 searches/month. No credit card required.` and `250 MB`).
- [ ] Region multiplier content preserves current shared ordering and values (`US East (Virginia)`, `EU West (Ireland)`, `EU Central (Germany)`, `EU North (Helsinki)`, `US East (Ashburn)`, `US West (Oregon)` with multipliers `1.00x`, `1.00x`, `0.70x`, `0.75x`, `0.80x`, `0.80x`).
- [ ] `/pricing` does not introduce landing-only product-framing sections as required content for pricing comprehension.
- [ ] Signup CTAs are absent and public links stay inside the current public-route system without introducing new route dependencies.
- [ ] The `/` pricing calculator preserves API-supplied `withheld_providers`, renders each display name and reason when non-empty, and omits the affordance for an empty list.
- [ ] Pricing comparison rows use one customer-facing source/status concept: verified source dates for published rows, modeled pricing only for legacy/fallback unverified payloads.
- [ ] Stage 4 drift detection compares `MARKETING_PRICING` to normalized admin rate-card data (`AdminRateCard` via `getTenantRateCard()` / `get_rate_card()`) without introducing duplicate pricing constants.

## Current Implementation Gaps

Stage 4 backend-alignment drift detection is a planned gap. The current route/browser coverage validates `MARKETING_PRICING` rendering and link behavior but does not yet compare those values to admin rate-card data.
JSDOM axe coverage now proves the route component in `web/src/routes/pricing/pricing.test.ts`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts` (`Pricing page` block validates first-paint pricing body/link expectations, the shared `250 MB` allowance, and rejects landing-only or fallback error framing on `/pricing`).
- Browser interaction tests: `web/tests/e2e-ui/full/public-pages.spec.ts` (`Landing page` block posts the landing calculator workload through a mocked public proxy response and asserts the withheld-provider affordance renders API-supplied names/reasons).
- Component tests: `web/src/lib/components/LandingPricingCalculator.test.ts` (calculator response parsing, withheld-provider non-empty and empty states, pricing-source header/row copy, and legacy Griddle-to-Flapjack row normalization).
- Component tests: `web/src/routes/pricing/pricing.test.ts` (route-level `/pricing` body contract, MARKETING_PRICING-consumption assertions including the shared `250 MB` allowance, ordered region multipliers, and landing-only exclusion assertions).
- Server/contract tests: `web/src/lib/pricing.test.ts` (canonical shared pricing constants consumed by public routes).
- Stage 4 extension rule: add backend-alignment assertions by extending the same route/browser owners above, not by introducing a parallel pricing fixture lane or Rust-side pricing parser helper.

## Open Questions

- None for Stage 3 contract lock.
