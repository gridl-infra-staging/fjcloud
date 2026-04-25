# Signup Screen Spec

## Scope

- Primary route: `/signup`
- Related routes: `/login`, `/dashboard`
- Audience: unauthenticated prospects creating an account
- Priority: P0

## User Goal

Create a new customer account with a name, email, password, and confirmation, then enter the customer dashboard.

## Target Behavior

The screen shows `Create your account`, the current free-tier promise, labeled fields for name, email, password, and confirm password, an explicit public-beta acknowledgement with links to `/beta`, `/terms`, and `/privacy`, a `Sign Up` submit button, and a login link for existing users. Successful signup creates the account, sets the auth session, and redirects to `/dashboard`.

## Required States

- Loading: form submission should preserve visible field context until navigation or validation feedback appears.
- Empty: empty required fields show field-specific validation and keep the user on `/signup`.
- Error: weak passwords, mismatched confirmation, invalid email, missing beta acknowledgement, and duplicate-email/API failures show safe visible feedback without exposing whether an email already exists.
- Success: valid signup redirects to `/dashboard`.

## Controls And Navigation

- `Name`, `Email`, `Password`, and `Confirm Password` are accessible labeled inputs.
- Public-beta acknowledgement checkbox confirms beta terms before account creation.
- Beta acknowledgement links open `/beta`, `/terms`, and `/privacy`.
- `Sign Up` submits the form.
- `Log in` navigates to `/login`.

## Acceptance Criteria

- [ ] Default render includes all required fields and the free-tier promise.
- [ ] Passwords shorter than 8 characters show `Password must be at least 8 characters`.
- [ ] Mismatched passwords show visible validation and remain on `/signup`.
- [ ] Duplicate email uses generic form failure text and does not reveal the email or existence state.
- [ ] Signup cannot be completed until the beta acknowledgement is checked.
- [ ] Successful signup reaches the dashboard.

## Current Implementation Gaps

Browser-unmocked coverage focuses on validation and duplicate handling; full fresh-signup success is owned by the customer journey/local signoff path.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`; `web/tests/e2e-ui/full/public-pages.spec.ts`; `web/tests/e2e-ui/full/customer-journeys.spec.ts`
- Component tests: `web/src/routes/signup/signup.test.ts`; `web/src/routes/signup/signup.server.test.ts`
- Server/contract tests: `web/src/routes/signup/signup.server.test.ts`
