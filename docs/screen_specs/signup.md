# Signup Screen Spec

## Scope

- Primary route: `/signup`
- Related routes: `/login`, `/console`
- Audience: unauthenticated prospects creating an account
- Priority: P0

## User Goal

Create a new customer account with a name, email, password, and confirmation, then enter the customer dashboard while email verification remains the gate for downstream billing setup.

## Target Behavior

The screen shows `Create your account`, the current four-cap free-tier promise, labeled fields for name, email, password, and confirm password, a `Sign Up` submit button, and a login link for existing users. Successful signup creates the account, sets the auth session, and redirects to `/console` immediately.

Backend ownership for post-signup billing setup is explicit: `infra/api/src/routes/auth.rs::register` stores verification state via `setup_email_verification()`, and Stripe/billing side effects are deferred to `run_post_verification_actions()`, which is triggered by `verify_email()` (or the dev-only `SKIP_EMAIL_VERIFICATION` auto-verify path). Plan semantics and minimum rules are canonically owned by `docs/design/pricing_contract.md`.

## Required States

- Loading: form submission should preserve visible field context until navigation or validation feedback appears.
- Empty: empty required fields show field-specific validation and keep the user on `/signup`.
- Error: weak passwords, mismatched confirmation, invalid email, and duplicate-email/API failures show safe visible feedback without exposing whether an email already exists.
- Success: valid signup redirects to `/console`; email verification remains the gate that unlocks downstream Stripe/billing setup.

### OAuth control states

`OAuthButtons.svelte` renders one control per provider (`google`, `github`) and
resolves availability once on mount from `GET {apiBaseUrl}/auth/oauth/_status`.
Three states, and the third is deliberate:

- **Available** (`{provider: {enabled: true}}`): renders an enabled `<a>` with
  `data-testid="oauth-button-<provider>"` and
  `href="{apiBaseUrl}/auth/oauth/<provider>/start"`, accessible name
  `Continue with Google` / `Continue with GitHub`.
- **Unavailable** (`{provider: {enabled: false}}`): renders a `disabled`
  `<button>` keeping the same `data-testid`, plus explanatory copy at
  `data-testid="oauth-unavailable-<provider>"` reading
  `<Provider> sign-in is unavailable in this environment.` The control still
  renders — it is never removed from the DOM.
- **Unknown** — the initial state, and the state kept when the status fetch
  throws, returns non-OK, returns unparseable JSON, or returns a payload in
  which any provider entry is missing or its `enabled` is not a boolean:
  renders exactly as **Available**. The parse is all-or-nothing, so a payload
  naming one provider `enabled: false` while omitting the other leaves **both**
  controls enabled. This is fail-open by design — a transient status failure
  must not hide a provider that still works — and it is asserted by the
  `preserves enabled links without helper copy for %s` cases in
  `web/src/lib/components/OAuthButtons.test.ts`. Do not "fix" it to render
  disabled.

## Mobile Narrow Contract

Baseline viewport: 390px wide (iPhone 14). The account fields, free-tier promise, validation messages, submit button, OAuth controls, login link, and support contact remain readable and tappable in one column without implying billing setup is complete before email verification.

## Controls And Navigation

- `Name`, `Email`, `Password`, and `Confirm Password` are accessible labeled inputs.
- `Sign Up` submits the form.
- `Log in` navigates to `/login`.

## Acceptance Criteria

- [ ] Default render includes all required fields and the free-tier promise.
- [ ] Passwords shorter than 15 Unicode code points show `Password must be at least 15 characters`.
- [ ] Mismatched passwords show visible validation and remain on `/signup`.
- [ ] Duplicate email uses generic form failure text and does not reveal the email or existence state.
- [ ] Successful signup reaches `/console` immediately.
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
