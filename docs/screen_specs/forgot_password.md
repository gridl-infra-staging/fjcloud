# Forgot Password Screen Spec

## Scope

- Primary route: `/forgot-password`
- Related routes: `/login`, `/reset-password/[token]`
- Audience: unauthenticated users recovering account access
- Priority: P1

## User Goal

Request a password reset email without revealing whether an account exists.

## Target Behavior

The screen shows `Forgot your password?`, explanatory copy, a labeled email field, `Send Reset Link`, and a back-to-login link. Submitting any syntactically acceptable email produces the same confirmation message: `If an account exists with that email, you'll receive a password reset link shortly.`

## Required States

- Loading: submission should keep context until confirmation or validation appears.
- Empty: missing email shows `Email is required`.
- Error: backend failures are hidden from the user to avoid account enumeration.
- Success: confirmation message appears and the user can navigate back to `/login`.

## Controls And Navigation

- `Email` accepts the reset target email.
- `Send Reset Link` submits the request.
- `Back to login` navigates to `/login`.

## Acceptance Criteria

- [ ] Default render includes heading, email field, submit button, and back-to-login link.
- [ ] Submission shows the non-enumerating confirmation message.
- [ ] Confirmation text is identical whether the account exists or not.

## Current Implementation Gaps

Browser-unmocked coverage uses a nonexistent email; explicit browser coverage for an existing-email reset request is not mapped.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`
- Component tests: none mapped
- Server/contract tests: `web/src/routes/forgot-password/forgot-password.server.test.ts`
