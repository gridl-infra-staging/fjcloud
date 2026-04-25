# Admin Login Screen Spec

## Scope

- Primary route: `/admin/login`
- Related route: `/admin/fleet`
- Audience: operators with the admin key
- Priority: P0

## User Goal

Authenticate to the admin console using the configured admin key.

## Target Behavior

The screen shows `Admin Login`, explanatory copy, a labeled `Admin Key` password field, and `Log In`. Valid key redirects to `/admin/fleet`; invalid or missing key shows visible feedback and remains on the login screen.

## Required States

- Loading: form stays visible until redirect or validation feedback.
- Empty: missing key shows field-specific validation.
- Error: wrong key shows a visible generic admin-login error.
- Success: valid key reaches the fleet overview.

## Controls And Navigation

- `Admin Key` accepts the secret key.
- `Log In` submits the form.

## Acceptance Criteria

- [ ] Default render includes heading, admin key input, and submit button.
- [ ] Wrong key shows an alert.
- [ ] Unauthenticated admin routes redirect to `/admin/login`.
- [ ] Valid key reaches `/admin/fleet`.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/admin/fleet.spec.ts`
- Component tests: none mapped
- Server/contract tests: `web/src/routes/admin/login/admin-login.server.test.ts`
