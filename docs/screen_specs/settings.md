# Settings Screen Spec

## Scope

- Primary route: `/console/account`
- Related routes: `/console/settings` (alias), `/login`, `/signup`
- Excludes: `/console/indexes/[name]?tab=settings` is owned by `index_settings.md`
- Audience: authenticated customers managing account identity and credentials
- Priority: P0

## User Goal

Update profile name, verify displayed account email, change password, export customer-safe account data, and delete a throwaway or unwanted account with explicit confirmation.

## Target Behavior

`/console/account` is the single customer-facing owner for account management. It shows `Account`, a profile form with editable name and read-only email/verification badge, a change-password form, an account-data export action, success/error feedback, and a delete-account danger zone gated behind password plus explicit confirmation checkbox. `/console/settings` is a compatibility route that renders only “Settings moved” guidance back to `/console/account`.

## Required States

- Loading: route load should render profile data before user action.
- Empty: required profile/password/delete fields prevent submission or show field/action errors.
- Error: wrong current password, mismatched new passwords, and delete-account failures show visible alerts while preserving context.
- Success: profile and password changes show visible success status; account deletion redirects to `/login`.

## Controls And Navigation

- `Name` with `Save profile` updates customer profile.
- `Current password`, `New password`, and `Confirm new password` with `Change password` update credentials.
- `Export account data` returns a customer-safe JSON export from the existing account-export endpoint.
- `Delete account` opens the danger-zone confirmation form.
- Delete submit is disabled until password and permanent-action checkbox are both provided.
- `/console/settings` shows only a link to `/console/account`; it does not duplicate account-management forms.

## Acceptance Criteria

- [ ] `/console/account` default render shows profile, email text, password, export, and delete-account sections.
- [ ] Profile update shows `Profile updated successfully`.
- [ ] Wrong current password shows an alert.
- [ ] Mismatched new passwords show an alert.
- [ ] Password change lifecycle proves old password fails and new password succeeds.
- [ ] Account export returns a downloadable customer-safe JSON payload without leaving the page.
- [ ] Delete-account danger zone deletes a disposable account and redirects to login.
- [ ] `/console/settings` renders only compatibility guidance to `/console/account`.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/account.spec.ts`
- Component tests: `web/src/routes/console/account/account.test.ts`; `web/src/routes/console/settings/settings.test.ts`
- Server/contract tests: `web/src/routes/console/account/account.server.test.ts`; `web/src/routes/console/settings/settings.server.test.ts`
