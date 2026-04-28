# Signup Screen Spec

## Scope

- Primary route: `/signup`
- Related routes: `/login`, `/dashboard`
- Audience: unauthenticated prospects creating an account
- Priority: P0

## User Goal

Create a new customer account with a name, email, password, and confirmation, then enter the customer dashboard while email verification remains the gate for downstream billing setup.

## Target Behavior

The screen shows `Create your account`, the current free-tier promise, labeled fields for name, email, password, and confirm password, an explicit public-beta acknowledgement with links to `/beta`, `/terms`, and `/privacy`, a `Sign Up` submit button, and a login link for existing users. Successful signup creates the account, sets the auth session, and redirects to `/dashboard` immediately.

Backend ownership for post-signup billing setup is explicit: `infra/api/src/routes/auth.rs::register` stores verification state via `setup_email_verification()`, and Stripe/billing side effects are deferred to `run_post_verification_actions()`, which is triggered by `verify_email()` (or the dev-only `SKIP_EMAIL_VERIFICATION` auto-verify path).

## Required States

- Loading: form submission should preserve visible field context until navigation or validation feedback appears.
- Empty: empty required fields show field-specific validation and keep the user on `/signup`.
- Error: weak passwords, mismatched confirmation, invalid email, missing beta acknowledgement, and duplicate-email/API failures show safe visible feedback without exposing whether an email already exists.
- Success: valid signup redirects to `/dashboard`; email verification remains the gate that unlocks downstream Stripe/billing setup.

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
- [ ] Successful signup reaches `/dashboard` immediately.
- [ ] Signup success contract explicitly keeps Stripe/billing setup behind email verification (`/auth/verify-email`) instead of treating redirect as billing-ready.

## Current Implementation Gaps

Browser-unmocked coverage today focuses on signup validation and duplicate handling. `web/tests/e2e-ui/full/auth.spec.ts` also owns the current invalid-token verify-email browser proof.

Successful fresh-signup plus verify-email-success browser proof remains an explicit planned gap for Stage 6's dedicated signup lane. That lane is owned by the `chromium:customer-journeys` project contract seam in `web/playwright.config.contract.ts` and its dependency/storage-state assertions in `web/src/tests/playwright-config-contract.test.ts`, not by adding an ad hoc success path into `auth.spec.ts`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`; `web/tests/e2e-ui/full/public-pages.spec.ts`
- Component tests: `web/src/routes/signup/signup.test.ts`; `web/src/routes/signup/signup.server.test.ts`
- Server/contract tests: `web/src/routes/signup/signup.server.test.ts`
- Stage 6 lane seam (project contract owner for future signup success browser proof): `web/playwright.config.contract.ts` (`chromium:customer-journeys`), verified by `web/src/tests/playwright-config-contract.test.ts`

## Open Questions

- None for Stage 3 contract lock.
