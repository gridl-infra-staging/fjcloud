# API Keys Screen Spec

## Scope

- Primary route: `/console/api-keys`
- Related route: `/console`
- Audience: authenticated customers managing management/search API keys
- Priority: P0

## User Goal

Create scoped API keys with full lifecycle controls (per-index scoping, source restrictions, expiry, rate caps), copy the one-time secret when created, audit existing keys, filter by index association, and revoke keys with confirmation.

## Target Behavior (post Wave-B 3A — parity target)

The page shows `API Keys`, a `Create API Key` button (opens EditorDialog — replaces the previous always-visible inline form), an optional error alert, one-time key reveal after creation, a per-index filter dropdown above the table, and either an empty state or a table of keys with name, prefix, scopes (ACL), associated indexes, restricted sources, expires-at, rate caps, last used, created date, copy-with-feedback action, and revoke action.

Revoking a key opens a typed `ConfirmDialog` (the user must type the key name to confirm) — replaces the previous `window.confirm` browser dialog.

## State contract (key fields surfaced in UI — additive over current `ApiKeyListItem`)

The list-item type currently exposes: `id`, `name`, `key_prefix`, `scopes`, `last_used_at`, `created_at`.

Wave B parity additions (additive only — preserve existing fields):

- `indexes?: string[]` — index names this key is scoped to (empty / absent = all indexes). **Enforced** at request time (scope check is pre-existing behavior).
- `restrict_sources?: string[]` — IP CIDRs or origin patterns. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT add a request-IP CIDR check; a key with `restrict_sources` set still accepts requests from unlisted IPs until the enforcement lane lands.
- `expires_at?: string | null` — ISO-8601 timestamp. `null` / absent = no expiry. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT reject requests whose key has `expires_at` in the past; the row renders with a dimmed `Expired` badge as a UI cue, but the server still authorizes the request until the enforcement lane lands.
- `max_hits_per_query?: number | null` — per-query hit cap. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT clamp or 400-reject queries that exceed the cap.
- `max_queries_per_ip_per_hour?: number | null` — per-IP rate cap. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT rate-limit by `(api_key_id, client_ip, hour_bucket)`.

These five fields must be **added end-to-end (Rust `api_keys.rs` → TypeScript `web/src/lib/api/types.ts` → `web/src/lib/api/client.ts` → page)** before any UI work proceeds. As of 2026-05-25 grep confirms zero occurrences of these names in the codebase, so the lane is **cross-layer**, not frontend-only.

**Security framing — read before relying on these fields as a boundary.** The four stored-only fields above are advisory in the Wave B 3A state. Until the follow-up enforcement lane lands, an operator MUST NOT tell customers "your key is restricted to IP X" or "your key expired so the request was rejected" — both statements would be false. The UI surfaces the values for self-service configuration so customers' settings are captured, and the storage round-trip is validated; the actual request-path enforcement is tracked in `docs/post_launch_followups.md` (`API Keys lifecycle-field enforcement`) and is a hard prerequisite before any production customer relies on these fields as a security boundary.

## Required States

- Loading: route load resolves to table or empty state before user action.
- Empty: no keys shows `No API keys. Create one to get started.`
- Filtered-empty: filter narrows result set to zero — shows `No API keys match this filter.`
- Error: create/revoke failures show a visible alert (`role="alert"`).
- Success: created key shows one-time reveal text and appears in the table; revoked key disappears.
- Expired (row state): a key whose `expires_at` is in the past renders with a dimmed row + `Expired` badge.

## Controls And Navigation

- `Create API Key` button opens **EditorDialog** (Wave A primitive 1B) with fields: `name` (text), `description` (text), `indexes` (multiselect — populated from the customer's indexes list), `acl` (multiselect — canonical management scope labels), `restrict_sources` (array-of-text input), `expires_at` (datetime input — optional), `max_hits_per_query` (number — optional), `max_queries_per_ip_per_hour` (number — optional).
- `Index filter` dropdown above the table — shows all distinct indexes referenced by existing keys plus an `All indexes` option. Selection writes URL `?index=<name>` (must merge additively with any other search params).
- Per-row `Copy` button copies the key prefix (or the one-time full key right after creation) to clipboard and toggles button text to `Copied!` for ~2s via a shared helper.
- Per-row `Revoke` opens **ConfirmDialog** (Wave A primitive 1A) in **typed** mode: user must type the key's `name` to confirm. The previous `window.confirm` path is removed in this lane.

## Acceptance Criteria

- [ ] Seeded key appears in the keys table with all new fields rendered (indexes, restrict_sources count, expires_at as relative time, rate-cap numbers when set).
- [ ] `Create API Key` button is visible by default (replaces the previous always-rendered inline form).
- [ ] Clicking `Create API Key` opens EditorDialog with all eight inputs (name, description, indexes, acl, restrict_sources, expires_at, max_hits_per_query, max_queries_per_ip_per_hour).
- [ ] Submitting the dialog with valid fields shows `API key created successfully`, the one-time reveal warning, and the row appears in the table with the correct field rendering.
- [ ] Per-index filter dropdown narrows the table to rows whose `indexes` array contains the selected index; `All indexes` restores the full list. URL `?index=<name>` round-trips correctly with other existing params preserved.
- [ ] Clicking per-row `Copy` writes the expected text to clipboard and the button text becomes `Copied!` for ~2s then reverts.
- [ ] Clicking per-row `Revoke` opens ConfirmDialog typed mode; typing the key name and confirming fires the revoke action and the row disappears.

## Implementation Pattern Requirements

- The current page (`web/src/routes/console/api-keys/+page.svelte`) uses `window.confirm` for delete and renders an always-visible inline create form. Both are explicitly replaced this lane — do not leave either path live.
- `copyToClipboard` is duplicated at `web/src/routes/console/onboarding/+page.svelte:164` and `web/src/routes/console/indexes/[name]/tabs/OverviewTab.svelte:52`. Extract once to `web/src/lib/clipboard.ts` (CLAUDE.md "Single source of truth" / "Reuse before adding") and consume from all three sites this lane.
- New search params on the page must additively merge with the existing query string (e.g. `goto(\`?${new URLSearchParams({...current, index: name})}\`)` — never clobber).

## Current Implementation Gaps

The current page covers only ~30% of upstream parity: no per-index filter, no lifecycle fields (restrict_sources / expires_at / rate caps), no copy-with-feedback, inline create form (not dialog), browser-confirm delete (not typed ConfirmDialog). Wave B Lane 3A closes those gaps end-to-end (Rust schema → TS types/client → Svelte UI).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/api-keys.spec.ts` (extend with new full-flow tests this lane)
- New full-flow tests: `web/tests/e2e-ui/full/api_keys_create.spec.ts`, `web/tests/e2e-ui/full/api_keys_revoke_typed.spec.ts`, `web/tests/e2e-ui/full/api_keys_filter.spec.ts`, `web/tests/e2e-ui/full/api_keys_copy.spec.ts`
- Component tests: `web/src/routes/console/api-keys/api-keys.test.ts`; `web/src/routes/console/api-keys/api-keys.server.test.ts`
- Server/contract tests: `web/src/routes/console/api-keys/api-keys.server.test.ts`
- Rust schema/route tests for the new fields: extend `infra/api/tests/api_keys_*` coverage (test names per the schema additions)
