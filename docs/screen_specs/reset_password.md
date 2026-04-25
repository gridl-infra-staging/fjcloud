# Reset Password Screen Spec

## Scope

- Primary route: `/reset-password/[token]`
- Related routes: `/forgot-password`, `/login`
- Audience: unauthenticated users with a password-reset token
- Priority: P1

## User Goal

Set a new password from a reset-token link and return to login.

## Target Behavior

The screen shows `Reset your password`, labeled `New Password` and `Confirm New Password` fields, and a `Reset Password` button. Successful reset replaces the form with a success alert and a `Log in` link.

## Required States

- Loading: submission should keep the reset context until success or validation feedback appears.
- Empty: missing password shows `Password is required`.
- Error: password shorter than 8 characters, mismatched confirmation, expired token, or invalid token shows visible feedback and keeps the form available where appropriate.
- Success: `Your password has been reset successfully.` appears and the `Log in` link navigates to `/login`.

## Controls And Navigation

- `New Password` and `Confirm New Password` are accessible labeled password inputs.
- `Reset Password` submits the form.
- `Log in` appears only after success.

## Acceptance Criteria

- [ ] Default render includes heading, both password fields, and submit button.
- [ ] Weak or missing password shows field-specific feedback.
- [ ] Mismatched confirmation shows visible feedback.
- [ ] Successful reset shows the success alert and login CTA.

## Current Implementation Gaps

Successful reset still depends on a valid email token and is covered by server tests rather than browser-unmocked tests.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/auth.spec.ts`
- Component tests: none mapped
- Server/contract tests: `web/src/routes/reset-password/[token]/reset-password.server.test.ts`
