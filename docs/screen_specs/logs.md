# Logs Screen Spec

## Scope

- Primary route: `/console/logs`
- Related route: `/console`
- Audience: authenticated customers inspecting client-captured API request history (developer debugger)
- Priority: P0

## User Goal

Inspect recent API request rows, open request + response details for a selected row, reproduce a row as a `curl` command, toggle between compact and detailed views, export the current store contents as JSON or CSV, and clear the log when needed.

## Target Behavior (post Wave-B 3B — parity target)

The page shows `API Logs` with a shared `API Activity Log` panel. The panel copy states that entries were captured in the current browser session only. The panel renders a table with `Method`, `URL`, `Status`, `Duration`, and per-row `Copy as curl` and `Expand` controls. The list is sourced from the browser-only shared log store (sessionStorage), newest-first. Above the table sit a view-mode toggle (`Compact` / `Detailed`) and two export buttons (`Export JSON`, `Export CSV`). Selecting a row reveals request body and response body panels (formatted JSON). `Clear` empties all rows and resets selection.

## Store contract (load-bearing — do not break)

The log store is **browser-only sessionStorage**, populated by `web/src/lib/api-logs/dashboard-instrumentation.ts` and sanitized at capture by `web/src/lib/api-logs/sanitization.ts`. The capture-time sanitized shape is `SanitizedLogEntry`:

```ts
type SanitizedLogEntry = {
  method: string;
  url: string;
  status: number;
  duration: number;
  body?: unknown;
  response?: unknown;
};
```

The store wraps each sanitized entry with two additional fields — a generated `id` and a numeric `timestamp` — and exposes the wrapped shape as `StoredLogEntry` (defined at `web/src/lib/api-logs/store.ts:22-25`):

```ts
type StoredLogEntry = SanitizedLogEntry & {
  id: string;
  timestamp: number;
};
```

**`StoredLogEntry` is the load-bearing shape for the viewer.** Everything downstream of the store — the table rows, the curl-copy builder, the JSON/CSV exporters, the expand-pane reads — consumes `StoredLogEntry`, NOT bare `SanitizedLogEntry`. Helpers added by Wave B 3B (`curl-builder.ts`, `exporters.ts`) MUST type their inputs as `StoredLogEntry[]` / `StoredLogEntry`. The CSV export header row is therefore `id,timestamp,method,url,status,duration,body,response` (wrapping fields first, then the sanitized fields).

There is **no `headers` field** on stored entries — `redactHeaders` drops auth-bearing headers (`Authorization`, `Cookie`, `X-Api-Key`, `Set-Cookie`) before storage, and `sanitizeLogEntry` does not propagate the remaining headers onto the stored entry at all. Migration routes are fully excluded. This is a security invariant — **the spec MUST NOT introduce any feature that requires headers (auth or otherwise) to be persisted in the store**.

## Required States

- Loading: viewer initializes from current sessionStorage store state.
- Empty: no entries shows `No API calls recorded`.
- Error: none rendered by this route-level view; data is store-backed and store hydration is total.
- Success: seeded entries render in newest-first order with selectable request detail.

## Controls And Navigation

- View-mode toggle (`?view=compact|detailed`) switches table density and column set. Compact: method, url (truncated), status, duration. Detailed: same + first ~120 chars of body preview + first ~120 chars of response preview. URL param must merge additively with other search params.
- Per-row `Copy as curl` reconstructs a curl command from the stored entry. Because auth headers were dropped at capture time, the curl command ALWAYS includes `-H 'Authorization: [REDACTED]'` regardless of whether the original captured request was authenticated — an opinionated developer-debugger UX choice that avoids the "looks copy-pasteable but silently 401s" failure mode (almost every real endpoint requires the auth header, so emitting it unconditionally is the helpful default). The UI shows a visible inline disclaimer on copy: `Auth headers redacted at capture. Replace [REDACTED] with your key before running.` This is intentional and non-negotiable per the sanitization invariant — the resulting curl is a developer convenience, not a re-executable artifact.
- Per-row `Expand` opens an inline detail view showing request body (formatted JSON) and response body (formatted JSON), side-by-side on wide viewports, stacked on narrow.
- `Export JSON` / `Export CSV` serialize the entries currently in the store. (The current page has no row-filter mechanism — see Layout Decision below — so "current filter result set" reduces to "everything in the store" unless filters are added.)
- `Clear` empties all rows and hides request detail.

## Layout Decision — filters: not in scope for Wave B 3B

Wave B 3B does NOT add per-method / per-status / search filters. The view-mode toggle from Stage 3 is the only filter-adjacent feature. The `Export` buttons therefore export the entire store contents.

If a future lane adds row filters, the `Export` semantics must be re-evaluated.

## Acceptance Criteria

- [ ] Route heading renders `API Logs`.
- [ ] Shared viewer heading renders `API Activity Log` and explains that entries were captured in this browser session only.
- [ ] Empty store state renders `No API calls recorded`.
- [ ] Populated store state renders table headers and newest-first rows with method/url/status/duration values.
- [ ] Per-row `Copy as curl` writes a curl command of the form `curl -X <METHOD> '<URL>' -H 'Authorization: [REDACTED]' -d '<body-json>'` to clipboard. Assert exact-match payload against hand-calculated string for a seeded entry; assert UI shows the redaction disclaimer.
- [ ] Per-row `Expand` reveals request body + response body panels with JSON formatted (indented).
- [ ] View-mode toggle writes URL `?view=compact|detailed`, persists on reload, and additively merges with other query params.
- [ ] `Export JSON` triggers a download whose parsed contents equal — entry-for-entry, field-for-field — a hand-calculated expected array for a seeded store.
- [ ] `Export CSV` triggers a download whose parsed contents equal a hand-calculated expected CSV (header row + N data rows), with correctly-escaped values for entries containing quote, comma, or newline.
- [ ] `Clear` removes rows and hides request detail.

## Implementation Pattern Requirements

- Current owner: `web/src/lib/api-logs/ApiLogViewer.svelte` (98 lines today). The new features push this toward the 400-line warning / 600-line hard cap (per CLAUDE.md size thresholds). Pre-empt by extracting per-feature subcomponents into `web/src/lib/api-logs/`:
  - `CurlCopyButton.svelte` (Stage 1)
  - `LogEntryDetail.svelte` (Stage 2)
  - `ViewModeToggle.svelte` (Stage 3)
  - `ExportButtons.svelte` (Stage 4)
- The curl-builder is a pure helper — place at `web/src/lib/api-logs/curl-builder.ts` with hand-calculated unit tests (no smoke tests; assert exact curl strings for representative inputs).
- The exporters are pure helpers — place at `web/src/lib/api-logs/exporters.ts` with hand-calculated unit tests (CSV escaping included).
- Inline comments LIBERALLY (CLAUDE.md "Code Quality") on anything not self-evident, especially the redaction-on-curl rationale and the store-contract dependencies.

## Current Implementation Gaps

The current 98-line viewer renders the minimal surface (table + select row + Clear). Wave B 3B adds curl-copy, expand-with-body-and-response, view-mode toggle, and Export JSON/CSV to reach upstream developer-debugger parity.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/console.spec.ts` (existing — current minimal coverage)
- New full-flow tests: `web/tests/e2e-ui/full/logs_curl_copy.spec.ts`, `web/tests/e2e-ui/full/logs_expand.spec.ts`, `web/tests/e2e-ui/full/logs_view_mode.spec.ts`, `web/tests/e2e-ui/full/logs_export.spec.ts`
- Component tests: `web/src/routes/console/logs/logs.test.ts`, `web/src/lib/api-logs/curl-builder.test.ts`, `web/src/lib/api-logs/exporters.test.ts`
- Server/contract tests: none (route behavior is client store/UI only).
