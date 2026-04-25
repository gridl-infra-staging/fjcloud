# Settings Screen Spec

## Scope

- Primary route: `/dashboard/settings`
- Related routes: `/login`, `/signup`
- Audience: authenticated customers managing account identity and credentials
- Priority: P0

## User Goal

Update profile name, verify displayed account email, change password, and delete a throwaway or unwanted account with explicit confirmation.

## Target Behavior

The page shows `Settings`, a profile form with editable name and read-only email/verification badge, a change-password form, success/error feedback, and a delete-account danger zone gated behind password plus explicit confirmation checkbox.

## Required States

- Loading: route load should render profile data before user action.
- Empty: required profile/password/delete fields prevent submission or show field/action errors.
- Error: wrong current password, mismatched new passwords, and delete-account failures show visible alerts while preserving context.
- Success: profile and password changes show visible success status; account deletion redirects to `/login`.

## Controls And Navigation

- `Name` with `Save profile` updates customer profile.
- `Current password`, `New password`, and `Confirm new password` with `Change password` update credentials.
- `Delete account` opens the danger-zone confirmation form.
- Delete submit is disabled until password and permanent-action checkbox are both provided.

## Acceptance Criteria

- [ ] Default render shows profile section, email text, and change-password section.
- [ ] Profile update shows `Profile updated successfully`.
- [ ] Wrong current password shows an alert.
- [ ] Mismatched new passwords show an alert.
- [ ] Password change lifecycle proves old password fails and new password succeeds.
- [ ] Delete-account danger zone deletes a disposable account and redirects to login.

## Current Implementation Gaps

None known for the mapped launch-critical behavior.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/settings.spec.ts`
- Component tests: `web/src/routes/dashboard/settings/settings.test.ts`; `web/src/routes/dashboard/settings/settings.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/settings/settings.server.test.ts`
