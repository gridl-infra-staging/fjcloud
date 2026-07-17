# UI Postmortems Rulebook

## Purpose And Scope

This document is the single source of truth for UI failure-prevention rules learned from real fjcloud incidents.

Scope constraints:

- Include incident-backed rules only.
- Use stable rule IDs (`P.<slug>`) and fixed severity labels so downstream automation can parse without heuristics.
- Keep page-specific legal and UX contract details in their existing owner files; this document records cross-incident prevention rules and evidence links.

## Rule Schema

Every rule must follow this exact block shape:

- Heading: `### Rule: <title>`
- ID line: `**ID:** P.<slug>`
- Severity line: `**Severity:** BLOCKER|EMBARRASSING|HARDENING|MAINT`
- Compact incident record fields:
  - `Incident date/context`
  - `What broke`
  - `Customer impact`
  - `Durable rule`
  - `Evidence refs`

## Incident-Backed Rules

### Rule: Brand palette consistency across public and logged-in surfaces

**ID:** P.brand_palette_consistency
**Severity:** EMBARRASSING

- Incident date/context: 2026-05-03 launch-readiness adversarial review and follow-up findings.
- What broke: Logged-in routes and supporting pages drifted into a generic palette/visual system while public routes used a distinct brand treatment, creating a product identity split.
- Customer impact: Customers experience a visible brand discontinuity immediately after signup/login, reducing trust and perceived product quality even when functionality still works.
- Durable rule: Public and authenticated UI surfaces must share one coherent brand palette and visual language; regressions are defined as cross-surface visual divergence, not as failure to match a newly invented palette policy.
- Evidence refs:
  - `chats/stuart/may3_lrr_stuff.md`
  - `chats/stuart/LRR.md`

### Rule: Legal posture single source at any point in time

**ID:** P.legal_posture_single_source
**Severity:** BLOCKER

- Incident date/context: 2026-04-29 through 2026-05-03 legal-surface decision and contract hardening cycle.
- What broke: Decision-history text and route-level legal contracts reflected conflicting legal posture states (draft vs finalized/launch posture), creating ambiguity about what customers are agreeing to.
- Customer impact: Conflicting legal posture creates contractual uncertainty at billing/signup boundaries and can invalidate customer-facing trust claims.
- Durable rule: Exactly one canonical legal posture may be active at a time; the authoritative page-level contract remains in legal-page test contracts and route tests, while this rulebook only records the cross-incident prevention rule and links back to those owners.
- Evidence refs:
  - `docs/decisions/2026-04-29_beta_terms_decision.md`
  - `web/src/routes/terms/terms.test.ts`
  - `web/src/routes/privacy/privacy.test.ts`
  - `web/src/routes/dpa/dpa.test.ts`
  - `web/tests/fixtures/legal_page_contract.ts`

### Rule: Transactional emails must include a text/plain alternative

**ID:** P.email_plain_text_part
**Severity:** HARDENING

- Incident date/context: 2026-05-03 customer-blocker review plus Stage 2 transactional-email contract work.
- What broke: System emails were observed as HTML-only in customer-facing flows.
- Customer impact: HTML-only messages degrade deliverability, accessibility, and fallback readability for customers and support operators.
- Durable rule: All system transactional emails must include a `text/plain` alternative part alongside HTML content.
- Evidence refs:
  - `chats/stuart/may3_lrr_stuff.md`
  - `chats/icg/may3_pm_2_customer_blockers_web.md`

## Explicit Out Of Scope For Stage 3

- No new manifesto rules.
- No CI or VLM-script wiring.
- No screen-spec edits.
- No severity-algorithm implementation.
