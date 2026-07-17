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

- `indexes?: string[]` — index names stored on the key as management metadata (empty / absent = all indexes). **STORED ONLY — enforcement in follow-up lane.** Current request-time authorization remains scope-only.
- `restrict_sources?: string[]` — IP CIDRs or origin patterns. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT add a request-IP CIDR check; a key with `restrict_sources` set still accepts requests from unlisted IPs until the enforcement lane lands.
- `expires_at?: string | null` — ISO-8601 timestamp. `null` / absent = no expiry. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT reject requests whose key has `expires_at` in the past; the row renders with a dimmed `Expired` badge as a UI cue, but the server still authorizes the request until the enforcement lane lands.
- `max_hits_per_query?: number | null` — per-query hit cap. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT clamp or 400-reject queries that exceed the cap.
- `max_queries_per_ip_per_hour?: number | null` — per-IP rate cap. Optional. **STORED ONLY — enforcement in follow-up lane.** Wave B 3A persists this value end-to-end but does NOT rate-limit by `(api_key_id, client_ip, hour_bucket)`.

These five fields are added end-to-end in this wave (`infra/api/src/routes/api_keys.rs` DTO/handlers and repo persistence through `web/src/lib/api/types.ts`, `web/src/lib/api/client.ts`, and `web/src/routes/console/api-keys/+page.svelte`) so the UI and API contract stay in parity.

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

- The current page (`web/src/routes/console/api-keys/+page.svelte`) uses shared `EditorDialog` for create and typed `ConfirmDialog` for revoke; keep those shared primitives live and do not reintroduce an inline create form or `window.confirm`.
- `copyToClipboard` is centralized in `web/src/lib/clipboard.ts`; continue consuming that shared helper rather than adding per-route copy implementations.
- New search params on the page must additively merge with the existing query string (e.g. `goto(\`?${new URLSearchParams({...current, index: name})}\`)` — never clobber).

## Visual contract

The API Keys page uses the shipped console page header: a flex-wrapped `mb-6` title row, `text-2xl font-bold text-flapjack-ink` heading, and rose/plum primary `Create API Key` action. Success and error feedback are card-like callouts: errors use `border-flapjack-rose/35 bg-flapjack-rose/10 text-flapjack-plum`; created-key success uses `border-flapjack-mint/60 bg-flapjack-mint/25`, muted ink copy, a white rounded code reveal block, and a bordered secondary copy action.

The per-index filter is a compact labeled select with `border-flapjack-ink/30 bg-white text-flapjack-ink` and rose focus states. Empty and filtered-empty states use white `rounded-lg` cards with `p-6 text-center shadow`. The table is a white `rounded-lg`/`shadow` surface with cream header row, uppercase muted ink column labels, divided body rows, mono key prefixes, rose expired badges, cream scope chips, mint index chips, and bordered Copy/Revoke row actions.

`api-keys-create-dialog` is the route-owned `EditorDialog` instance and should visually inherit the shared dialog contract rather than invent local modal styling. At 390px, the header controls wrap, the filter remains reachable, chip groups wrap inside cells, and horizontal table overflow is contained by the table surface. Implementation evidence: `web/src/routes/console/api-keys/+page.svelte` owns the shipped page header, callouts, filter, table, chips, row actions, and `testId="api-keys-create-dialog"` usage.

## Current Implementation Gaps

The shipped page now renders the Wave B 3A self-service UI: per-index filter, lifecycle fields, copy-with-feedback, `EditorDialog` create flow, and typed `ConfirmDialog` revoke flow. Remaining gap: the lifecycle fields are stored/displayed metadata only until the follow-up enforcement lane lands; request-path authorization still remains scope-based as documented below.

## Enforcement Boundaries (runtime owner anchors)

- `infra/api/src/auth/api_key.rs` (`ApiKeyAuth::require_scope`) enforces scope membership.
- `infra/api/src/routes/discovery.rs` (`discover`) consumes scope-authenticated key context.
- Wave B 3A does not add index-membership request gates in these owners; `indexes` remains stored metadata in this wave.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/api-keys.spec.ts` (single full-route owner; extend this file instead of creating parallel API-keys E2E specs)
- Component tests: `web/src/routes/console/api-keys/api-keys.test.ts`; `web/src/routes/console/api-keys/api-keys.server.test.ts`
- Server/contract tests: `web/src/routes/console/api-keys/api-keys.server.test.ts`
