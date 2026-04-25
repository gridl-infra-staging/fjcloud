# Verify Email Screen Spec

## Scope

- Primary route: `/verify-email/[token]`
- Related routes: `/login`, `/signup`
- Audience: users following an email-verification link
- Priority: P1

## User Goal

Confirm account email ownership and proceed to login, or understand that verification failed.

## Target Behavior

The screen resolves the token server-side and shows either `Email Verified` with the API success message or `Verification Failed` with a safe failure message. Both outcomes provide a `Go to Login` link.

## Required States

- Loading: route load should resolve before rendering the result card; no separate spinner is required.
- Empty: missing/invalid token is treated as a failed verification result.
- Error: API/load failures show `Verification Failed` with safe explanatory text.
- Success: verified token shows `Email Verified` and the API-provided success message.

## Controls And Navigation

- `Go to Login` navigates to `/login` in both success and failure states.

## Acceptance Criteria

- [ ] Successful token result shows `Email Verified`.
- [ ] Invalid or expired token result shows `Verification Failed`.
- [ ] Both states include safe explanatory copy and a login CTA.

## Current Implementation Gaps

Successful token verification is covered by server tests; browser-unmocked coverage exercises the invalid-token failure result and login CTA.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`
- Component tests: none mapped
- Server/contract tests: `web/src/routes/verify-email/[token]/verify-email.server.test.ts`
