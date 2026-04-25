# API Keys Screen Spec

## Scope

- Primary route: `/dashboard/api-keys`
- Related route: `/dashboard`
- Audience: authenticated customers managing management/search API keys
- Priority: P0

## User Goal

Create scoped API keys, copy the one-time secret when created, audit existing keys, and revoke keys.

## Target Behavior

The page shows `API Keys`, a persistent `Create API Key` form, optional error alert, one-time key reveal after creation, and either an empty state or a table of keys with name, prefix, scopes, last used, created date, and revoke action.

## Required States

- Loading: route load should resolve to table or empty state before user action.
- Empty: no keys shows `No API keys. Create one to get started.`
- Error: create/revoke failures show a visible alert.
- Success: created key shows one-time reveal text and appears in the table; revoked key disappears.

## Controls And Navigation

- `Name` input names the key.
- Scope checkboxes use the canonical management scope labels.
- `Create key` submits creation.
- `Revoke` asks for browser confirmation before deleting a key.

## Acceptance Criteria

- [ ] Seeded key appears in the keys table.
- [ ] Create form is visible by default.
- [ ] Creating through UI shows `API key created successfully` and one-time reveal warning.
- [ ] Created key name appears in the table.
- [ ] Revoking a seeded key removes it from the table.

## Current Implementation Gaps

Browser coverage does not assert every scope combination; component/server tests own scope-contract details.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/api-keys.spec.ts`
- Component tests: `web/src/routes/dashboard/api-keys/api-keys.test.ts`; `web/src/routes/dashboard/api-keys/api-keys.server.test.ts`
- Server/contract tests: `web/src/routes/dashboard/api-keys/api-keys.server.test.ts`
