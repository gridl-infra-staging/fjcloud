# Pricing Screen Spec

## Scope

- Primary route: `/pricing`
- Related routes: `/`, `/signup`, `/login`, `/beta`, `/status`, `/terms`, `/privacy`, `/dpa`
- Audience: unauthenticated prospects comparing Flapjack Cloud pricing before signup
- Priority: P0

## User Goal

Understand exact Flapjack Cloud public pricing terms (rates, free-tier allowance, minimum spend, free-tier promise, and region multipliers) and continue into signup without reading unrelated landing-only marketing sections.

## Target Behavior

The `/pricing` route is a public unauthenticated screen that reuses the existing marketing pricing owner (`MARKETING_PRICING`) for pricing values and vocabulary already established on `/`. The page centers pricing content: free-tier promise, the `250 MB` allowance, hot/cold storage rows, minimum monthly spend, region multipliers, and signup CTA copy sourced from shared pricing data.

Landing-only framing stays on `/` (for example: broader product feature storytelling, quick-facts panel, and full mixed marketing sections). The `/pricing` route should avoid introducing a parallel pricing copy source or alternate pricing constants.

Stage 4 backend-alignment drift detection must extend this same owner: compare `web/src/lib/pricing.ts::MARKETING_PRICING` against normalized admin rate-card data exposed as `web/src/lib/admin-client.ts::AdminRateCard` via `getTenantRateCard()` and backed by `infra/api/src/routes/admin/rate_cards.rs::get_rate_card()`. Do not introduce a second checked-in pricing snapshot.

## Required States

- Loading: server-rendered first paint with complete static pricing content; no client-only loading state is required.
- Empty: not applicable when pricing data is sourced from the static `MARKETING_PRICING` owner.
- Error: not applicable for Stage 1 contract definition because the pricing owner is static and required in the current public-route seam.
- Success: the page renders exact shared pricing values and routes CTA/policy/status links to existing public routes.

## Controls And Navigation

- Primary pricing CTA uses `MARKETING_PRICING.cta_label` and navigates to `/signup`.
- Public auth navigation remains in the existing public-route system (`/login`, `/signup`).
- Beta and policy/status destinations stay in the current public-route system (`/beta`, `/status`, `/terms`, `/privacy`, `/dpa`).
- External API documentation links (if present on `/pricing`) should use the same destination already used by the landing route.

## Acceptance Criteria

- [ ] `/pricing` is reachable as a public, unauthenticated route and renders page-specific body content on first paint.
- [ ] Pricing rows match shared constants: hot storage `$0.05` per MB-month and cold snapshot storage `$0.02` per GB-month.
- [ ] Minimum paid spend renders from shared cents data (`minimum_spend_cents=1000`) as `$10.00`.
- [ ] Free-tier promise, `250 MB` allowance, and CTA label are sourced from shared pricing data (`Create your free account. No credit card required.`, `250 MB`, and `Get Started Free`).
- [ ] Region multiplier content preserves current shared ordering and values (`US East (Virginia)`, `EU West (Ireland)`, `EU Central (Germany)`, `EU North (Helsinki)`, `US East (Ashburn)`, `US West (Oregon)` with multipliers `1.00x`, `1.00x`, `0.70x`, `0.75x`, `0.80x`, `0.80x`).
- [ ] `/pricing` does not introduce landing-only product-framing sections as required content for pricing comprehension.
- [ ] CTA and public links stay inside the current public-route system and do not introduce new route dependencies.
- [ ] Stage 4 drift detection compares `MARKETING_PRICING` to normalized admin rate-card data (`AdminRateCard` via `getTenantRateCard()` / `get_rate_card()`) without introducing duplicate pricing constants.

## Current Implementation Gaps

Stage 4 backend-alignment drift detection is a planned gap. The current route/browser coverage validates `MARKETING_PRICING` rendering and link behavior but does not yet compare those values to admin rate-card data.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts` (`Pricing page` block validates first-paint pricing body/link expectations, the shared `250 MB` allowance, and rejects landing-only or fallback error framing on `/pricing`).
- Component tests: `web/src/routes/pricing/pricing.test.ts` (route-level `/pricing` body contract, MARKETING_PRICING-consumption assertions including the shared `250 MB` allowance, ordered region multipliers, and landing-only exclusion assertions).
- Server/contract tests: `web/src/lib/pricing.test.ts` (canonical shared pricing constants consumed by public routes).
- Stage 4 extension rule: add backend-alignment assertions by extending the same route/browser owners above, not by introducing a parallel pricing fixture lane or Rust-side pricing parser helper.

## Open Questions

- None for Stage 3 contract lock.
