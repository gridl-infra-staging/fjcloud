# Verify Email Screen Spec

## Scope

- Primary route: `/verify-email/[token]`
- Related routes: `/login`, `/signup`
- Audience: users following an email-verification link
- Priority: P1

## User Goal

Confirm account email ownership and proceed to login, or understand that verification failed, with success acting as the post-verification unlock for downstream billing setup.

## Target Behavior

The screen resolves the token server-side and shows either `Email Verified` with the API success message or `Verification Failed` with a safe failure message. Both outcomes provide a `Go to Login` link.

Success state ownership is the backend verify-email contract: `infra/api/src/routes/auth.rs::verify_email` marks the token verified and invokes `run_post_verification_actions()` so Stripe/billing setup can proceed after verification.

## Required States

- Loading: route load should resolve before rendering the result card; no separate spinner is required.
- Empty: missing/invalid token is treated as a failed verification result.
- Error: API/load failures show `Verification Failed` with safe explanatory text.
- Success: verified token shows `Email Verified` and the API-provided success message, representing the post-verification unlock for downstream billing setup.

## Controls And Navigation

- `Go to Login` navigates to `/login` in both success and failure states.

## Acceptance Criteria

- [ ] Successful token result shows `Email Verified`.
- [ ] Invalid or expired token result shows `Verification Failed`.
- [ ] Both states include safe explanatory copy and a login CTA.

## Current Implementation Gaps

Successful token verification is currently covered by server contract tests. Browser-unmocked coverage currently exercises the invalid-token failure result and login CTA (`web/tests/e2e-ui/full/auth.spec.ts`).

Verify-email success in a real browser remains an explicit planned gap to be closed by Stage 6's dedicated signup lane (`chromium:customer-journeys` project contract), not by adding another ad hoc success test in `auth.spec.ts`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`
- Component tests: none mapped
- Server/contract tests: `web/src/routes/verify-email/[token]/verify-email.server.test.ts`
- Stage 6 lane seam (future verify-email success browser owner): `web/playwright.config.contract.ts` (`chromium:customer-journeys`), verified by `web/src/tests/playwright-config-contract.test.ts`

## Open Questions

- None for Stage 3 contract lock.
