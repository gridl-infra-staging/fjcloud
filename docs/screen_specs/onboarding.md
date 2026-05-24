# Onboarding Screen Spec

## Scope

- Primary route: `/console/onboarding`
- Related routes: `/console`, `/console/indexes`, `/console/billing/setup`
- Audience: authenticated customers setting up their first index
- Priority: P0

## User Goal

Create the first search index, wait through provisioning, receive one-time credentials, and know the next step.

## Target Behavior

The screen shows `Get Started` and a step-based wizard. Step 1 chooses region and index name. Step 2 handles region/index preparation with polling, timeout recovery, and support contact. Step 3 exposes endpoint/API key credentials once and provides quickstart code. Completed users are told onboarding is already done. Free-plan onboarding status includes `free_tier_limits` from the API (`max_searches_per_month`, `max_records`, `max_storage_mb`, `max_indexes`), and Shared-plan onboarding uses payment-method gating when required.

## Required States

- Loading: preparing and credential generation states show visible spinner/progress copy.
- Empty: missing setup status shows `Unable to load setup status` and a dashboard fallback.
- Error: invalid names, backend action failures, and credential generation failures show visible inline feedback.
- Success: valid creation advances to credentials UI or completed state.

## Controls And Navigation

- Region picker selects a deployment region.
- `Index name` validates required, length, edge characters, allowed characters, and reserved names.
- `Continue` starts index creation.
- `Keep waiting` resumes timed-out polling.
- `Set up billing` links to `/console/billing/setup` for shared-plan users without payment method.
- Credential copy buttons copy endpoint/API key when browser clipboard is available.
- `Go to Console` returns to `/console`.

## Acceptance Criteria

- [ ] Fresh dashboard users see an onboarding banner with `Continue setup`.
- [ ] Step 1 renders region options, default index name, and validation errors.
- [ ] Invalid/empty index names disable `Continue`.
- [ ] Valid index creation advances to a credentials step with `Get Credentials`.
- [ ] Billing-gated shared-plan users see the billing setup gate instead of the wizard, while free-plan users receive `free_tier_limits.max_storage_mb`-based quota context.

## Current Implementation Gaps

Browser-unmocked coverage proves step 1 and creation-to-credentials readiness; clipboard-copy behavior is not mapped as browser coverage.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/onboarding.spec.ts`; `web/tests/e2e-ui/full/customer-journeys.spec.ts`
- Component tests: `web/src/routes/console/onboarding/onboarding.test.ts`; `web/src/routes/console/onboarding/onboarding.server.test.ts`
- Server/contract tests: `web/src/routes/console/onboarding/onboarding.server.test.ts`
