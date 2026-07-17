# Login Screen Spec

## Scope

- Primary route: `/login`
- Related routes: `/forgot-password`, `/signup`, `/console`
- Audience: returning customers
- Priority: P0

## User Goal

Authenticate with email and password, recover gracefully from failures, and return to the dashboard.

## Target Behavior

The screen uses the shared `bg-flapjack-mint text-flapjack-ink` auth canvas and shows `Log in to Flapjack Cloud`, labeled email and password fields, a `Log In` button, and a forgot-password link. Public signup discovery is withdrawn from the login screen per `decisions/2026-05-23_beta_signup_gate.md` while direct `/signup` access remains reachable. A successful login sets the auth session and redirects to `/console`. Failed login attempts show generic error treatment that does not reveal whether the email exists.

## Required States

- Loading: form submission should keep the user on the login context until redirect or feedback.
- Empty: missing email/password shows field-specific validation.
- Error: wrong password and unknown email show the same generic credential failure and remain on `/login`.
- Success: valid credentials redirect to `/console`.

## Controls And Navigation

- `Email` and `Password` are accessible labeled inputs.
- `Log In` submits the form.
- `Forgot your password?` navigates to `/forgot-password`.
- No signup discovery link renders on `/login`.
- Session-expired redirects may show the `session-expired-banner`.

## Acceptance Criteria

- [ ] Default render includes heading, both fields, submit, and forgot-password link, with no signup discovery link.
- [ ] Wrong-password and unknown-email failures are generic and do not echo the attempted email.
- [ ] Valid credentials reach `/console` and show the dashboard heading.
- [ ] Unauthenticated dashboard access redirects to `/login`.
- [ ] Expired sessions redirect to login and show the session-expired banner when the reason parameter is present.

## Visual contract

The login screen uses the shipped auth canvas: a full-height centered `bg-flapjack-mint text-flapjack-ink` layout with a white `max-w-md` card, `rounded-lg` corners, `p-8` spacing, and `shadow` depth. The heading is `text-2xl font-bold text-flapjack-ink`; labels use `text-sm font-medium text-flapjack-ink/80`; helper/link copy uses muted ink and rose/plum link states.

Inputs use the shipped rounded border treatment: `border-flapjack-ink/30`, `px-3 py-2`, `focus:border-flapjack-rose`, and `focus:ring-flapjack-rose`. The primary submit is full-width `bg-flapjack-rose text-white hover:bg-flapjack-plum` with the cream focus offset. The session-expired warning uses `border-flapjack-yellow/50 bg-flapjack-yellow/20 text-flapjack-ink/80`; credential and field errors use `bg-flapjack-rose/10` or `text-flapjack-plum`.

At 390px, the auth card remains one column, fills available width within the page padding, keeps both fields and the primary action readable, and preserves the OAuth divider plus forgot-password link below the form. Implementation evidence: `web/src/routes/login/+page.svelte` owns the shipped layout/classes; `web/src/app.css` owns the Flapjack palette tokens.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`; `web/tests/e2e-ui/smoke/auth.spec.ts`
- Component tests: `web/src/routes/login/login.test.ts`; `web/src/routes/login/login.server.test.ts`
- Server/contract tests: `web/src/routes/login/login.server.test.ts`
