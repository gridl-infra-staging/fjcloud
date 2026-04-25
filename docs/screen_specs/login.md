# Login Screen Spec

## Scope

- Primary route: `/login`
- Related routes: `/forgot-password`, `/signup`, `/dashboard`
- Audience: returning customers
- Priority: P0

## User Goal

Authenticate with email and password, recover gracefully from failures, and return to the dashboard.

## Target Behavior

The screen shows `Log in to Flapjack Cloud`, labeled email and password fields, a `Log In` button, a forgot-password link, and a signup link. A successful login sets the auth session and redirects to `/dashboard`. Failed login attempts show generic error treatment that does not reveal whether the email exists.

## Required States

- Loading: form submission should keep the user on the login context until redirect or feedback.
- Empty: missing email/password shows field-specific validation.
- Error: wrong password and unknown email show the same generic credential failure and remain on `/login`.
- Success: valid credentials redirect to `/dashboard`.

## Controls And Navigation

- `Email` and `Password` are accessible labeled inputs.
- `Log In` submits the form.
- `Forgot your password?` navigates to `/forgot-password`.
- `Sign up` navigates to `/signup`.
- Session-expired redirects may show the `session-expired-banner`.

## Acceptance Criteria

- [ ] Default render includes heading, both fields, submit, forgot-password link, and signup link.
- [ ] Wrong-password and unknown-email failures are generic and do not echo the attempted email.
- [ ] Valid credentials reach `/dashboard` and show the dashboard heading.
- [ ] Unauthenticated dashboard access redirects to `/login`.
- [ ] Expired sessions redirect to login and show the session-expired banner when the reason parameter is present.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`; `web/tests/e2e-ui/smoke/auth.spec.ts`
- Component tests: `web/src/routes/login/login.test.ts`; `web/src/routes/login/login.server.test.ts`
- Server/contract tests: `web/src/routes/login/login.server.test.ts`
