# Error Boundaries Screen Spec

## Scope

- Primary route: shared route-error surfaces for public `web/src/routes/+error.svelte` and dashboard `web/src/routes/dashboard/+error.svelte`
- Related routes: all public and dashboard routes that can route-fail into these boundaries
- Audience: unauthenticated visitors and authenticated customers encountering route errors
- Priority: P0

## User Goal

Understand what failed, recover to a safe destination, and capture a stable support reference without exposing infrastructure internals.

## Target Behavior

Both error boundaries render shared recovery copy from `buildBoundaryCopy()` and include a support-reference block with:

- Visible label exactly `Support reference`.
- Customer-visible identifier matching `web-[a-f0-9]{12}`.
- Support-contact wording that uses `SUPPORT_EMAIL` from `web/src/lib/format.ts` as the single source of truth for the contact address.
- Backend `x-request-id` values are not rendered to customers; when available on an `ApiRequestError`, they are paired with the web support reference in server route-error logs.
- Browser-only uncaught `error` and `unhandledrejection` failures are normalized into sanitized 500-style boundary copy, include one web support reference, emit browser-console maintainer metadata with `backend_correlation: 'absent'`, and submit the same sanitized metadata to the repo-owned `/browser-errors` ingestion route.

## Required States

- Loading: not applicable; route errors render boundary content immediately from route error state.
- Empty: when no safe customer message is present, boundary uses fallback copy from `buildBoundaryCopy()`.
- Error: `isCustomerSafe4xxMessage()` and `buildBoundaryCopy()` continue to hide unsafe infrastructure details for 4xx and suppress raw 5xx internals.
- Success: boundary renders heading, description, CTA routing contract, and one support-reference block per surface.

## Controls And Navigation

- Primary CTA is driven by `buildBoundaryCopy()` (`/` for public 4xx/404, `/dashboard` for dashboard 4xx/404, `/status` for 5xx).
- Secondary status link follows current boundary behavior and must remain unchanged by support-reference work.
- Support contact uses the shared `SUPPORT_EMAIL` source; no second hard-coded mailbox is introduced.

## Acceptance Criteria

- [x] Public and dashboard boundaries each render exactly one `Support reference` label.
- [x] Each boundary renders one customer-visible support reference matching `web-[a-f0-9]{12}`.
- [x] Existing privacy guardrails remain intact: unsafe infrastructure details stay hidden and raw 5xx internals stay suppressed.
- [x] Support-contact copy for both boundaries is sourced from `SUPPORT_EMAIL`.
- [x] Backend `x-request-id` values are preserved by `ApiRequestError` metadata (`web/src/lib/api/client.ts`) and paired with the web support reference in route-error logs (`web/src/hooks.server.ts`).
- [x] Browser-only uncaught errors and unhandled promise rejections are normalized by `web/src/lib/error-boundary/client-runtime.ts` into one sanitized support reference, keep browser-console maintainer metadata with `backend_correlation: 'absent'`, and submit the same sanitized payload to `/browser-errors` via `infra/api/src/routes/browser_error_reporting.rs`.

## Current Implementation Gaps

No known gap remains in the repo-owned browser-runtime reporting seam. Customer-visible support references remain web-generated and `web-` prefixed by design, browser-only runtime failures now submit sanitized metadata to `/browser-errors` while preserving browser-console maintainer diagnostics, and backend `x-request-id` values remain available only to maintainer-visible server route-error logs when the thrown error is an `ApiRequestError` with preserved response metadata.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/public-pages.spec.ts`; `web/tests/e2e-ui/full/dashboard.spec.ts`
- Component tests: `web/src/lib/error-boundary/recovery-copy.test.ts`; `web/src/lib/error-boundary/SupportReferenceBlock.test.ts`; `web/src/lib/error-boundary/client-runtime.test.ts`; `web/src/routes/layout.test.ts`; `web/src/routes/error.test.ts`; `web/src/routes/dashboard/error.test.ts`
- Server/contract tests: `web/src/lib/api/client.test.ts`; `web/src/hooks.server.test.ts`
