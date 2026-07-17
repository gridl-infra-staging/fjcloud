# Events Tab Screen Spec

## Scope

- Primary route: `/console/indexes/[name]?tab=events`
- Related routes: `/console/indexes/[name]` (parent tab strip)
- Audience: authenticated customers integrating the Insights SDK and debugging click/conversion/view events live
- Priority: P0

## User Goal

Watch events arrive in real time as the SDK fires them, filter by index/type/status/time, and drill into a single event payload to debug shape, status, and validation errors without leaving the page.

## Target Behavior

The tab opens with a live, auto-polling event table for the current index. The header carries the heading, an event-count badge, a time-range picker (`15m`, `1h`, `24h`, `7d`, `All available`), a free-text Index filter, an auto-poll toggle (default on), and a manual `Refresh` button. Below the header, an event-volume area chart (Total/OK/Error series, adaptive bucket sizing) renders whenever there are events in the current window. Below the chart, the events table renders rows with columns Time / Index / Type / Name / User Token / Status; the Type cell appends `(eventSubtype)` muted when present. Clicking a row opens an inline detail panel to the right with labelled summary rows (Event Name, Type, Subtype, Index, User Token, Status badge, Timestamp), an Object IDs chip group, a Validation Errors list, a raw-JSON `<pre>`, and a `Copy payload` button that copies the JSON and shows a 1.5s `Copied` confirmation. While the time range is not `All available`, the page re-fetches every 5s; polling pauses while the browser tab is hidden and resumes on visibility.

## Numbered Layout

1. **Header row** (`data-testid="events-section"` container)
   1. Heading text `Event Debugger`
   2. Event-count badge (`data-testid="event-count"`) — total events in the current filtered window
   3. Time-range picker (`<select id="filter-date-range">`)
   4. Index filter input (`<input id="filter-index">`)
   5. Status filter (`<select id="filter-status">`)
   6. Event-type filter (`<select id="filter-event-type">`)
   7. Auto-poll toggle (`data-testid="events-autopoll-toggle"`)
   8. Manual `Refresh` button (`data-testid="events-refresh"`)
   9. Live indicator (next-poll countdown chip, only when polling active)
2. **Volume chart panel** (`data-testid="event-volume-chart"`) — area chart with Total / OK / Error series and small Total / OK / Error count badges; hidden in Loading-initial, Load-error, Empty-no-events-yet
3. **Summary counter strip** (Total / OK / Error tiles) — retained from current shipped UI, sits between chart and table
4. **Events table** (`data-testid="events-table"`) — columns Time, Index, Type, Name, User Token, Status; each row has `data-testid="event-row"` and an ordinal-suffixed key
5. **Detail panel** (`data-testid="event-detail"`, conditionally visible)
   1. Header with `Event Detail` title and `Close` button
   2. Labelled summary rows (Event Name, Type, Subtype, Index, User Token, Status badge, Timestamp)
   3. Object IDs chip group
   4. Validation Errors list (or "None")
   5. Raw JSON `<pre>` block
   6. `Copy payload` button (`data-testid="event-copy-payload"`) with transient `Copied` swap

## Required States

- **Loading-initial:** first load before the events response settles — skeleton rows in the table area; header chrome (filters, toggles) is visible and inert.
- **Load-error:** debug endpoint returned non-2xx (e.g. 500) on the initial server load. Distinct error card reading `Unable to load events. The debug endpoint may be unavailable.` with a Retry button. **Must not be confused with Empty-no-events-yet.** Closes audit S1-2.
- **Empty-no-events-yet:** request succeeded, zero events in window. Card reads `No events received yet — events appear here when your application sends analytics events to the Insights API.`
- **Populated-not-polling:** rows render; auto-poll toggle is off; badge by `Refresh` reads `Polling off`.
- **Populated-polling-active:** rows render; auto-poll toggle is on; a small pulse/clock indicator next to `Refresh` shows "Live — next in Ns" or equivalent affordance.
- **Polling-paused-tab-hidden:** auto-poll is on but `document.visibilityState === 'hidden'`; the `setInterval` is cleared. On visibility return, immediate refresh fires and interval re-arms.
- **Detail-selected:** a row is selected; right-side detail panel is visible; selected row is visually highlighted; selection persists across polls when the same event still exists (matched by ordinal-suffixed row key).
- **Detail-payload-copied:** transient state after `Copy payload`; button label swaps to `Copied` with check icon for 1.5s, then reverts.

## Mobile Narrow Contract

Baseline viewport: 390px wide. Header controls stack vertically (time-range, index filter, auto-poll toggle, refresh). Volume chart shrinks to 100% width at 160px height. Events table becomes horizontally scrollable inside its container; Time / Type / Status columns remain visible without scroll. Detail panel reflows below the table (not beside it) when selected.

## Controls And Navigation

- **Time-range picker** (`<select>`, label `Date Range`): `15m`, `1h`, `24h` (default), `7d`, `All available`. Changing it re-anchors the polling window.
- **Index filter** (free-text `<input>`, label `Index`, placeholder `Filter by index...`): client-side filter against `event.index`; threaded into the server fetch as well.
- **Status filter** (`<select>`): `All` / `OK` / `Error`.
- **Event-type filter** (`<select>`): `All` / `click` / `conversion` / `view`.
- **Auto-poll toggle** (`<button>` or switch, `data-testid="events-autopoll-toggle"`): turns the 5s `setInterval` on/off; disabled and forced off when range is `All available`.
- **Refresh button** (`data-testid="events-refresh"`): manual re-fetch regardless of polling state.
- **Event row click**: opens the detail panel; updates `selectedEventRowKey` to the row's ordinal-suffixed key.
- **Detail panel `Close`**: clears selection.
- **Detail panel `Copy payload`** (`data-testid="event-copy-payload"`): writes `JSON.stringify(event, null, 2)` via `navigator.clipboard.writeText`; transient `Copied` feedback.
- **No detail deep-link in this scope**: selection state is inline, not URL-bound.

## Acceptance Criteria

- [ ] Given the events tab is opened and the debug endpoint returns events, when the page settles, then the table renders one `data-testid="event-row"` per event with Time, Index, Type, Name, User Token, Status columns visible.
- [ ] Given the debug endpoint returns 500 on initial load, when the page settles, then the **Load-error** state is visible with the documented error copy and is distinct from the empty-state copy (no `No events received yet` text present).
- [ ] Given polling is active and a new event arrives at the backend, when ≤6s elapse, then the new row appears in the table without any manual interaction.
- [ ] Given two events have identical timestamp, name, user token, type, and index (intra-millisecond duplicates), when the table renders, then **both** rows are present in the DOM (no Svelte `{#each}` key collision).
- [ ] Given the browser tab is hidden, when `visibilitychange` fires `hidden`, then no further `/debug` requests are issued until the tab becomes visible again; on visibility, one immediate refresh fires and the 5s interval re-arms.
- [ ] Given a row is clicked, when the detail panel opens, then it shows labelled rows for Event Name, Type, Subtype, Index, User Token, Status, Timestamp, plus a `Copy payload` button.
- [ ] Given `Copy payload` is clicked, when the click handler runs, then the clipboard contains the event JSON and the button label shows `Copied` for ~1.5s.
- [ ] Given the time range is set to `All available`, when the picker change settles, then the auto-poll toggle becomes disabled (or visually off) and no polling interval is active.
- [ ] Given the Index filter is typed, when the input value changes, then the table and the volume chart narrow to events matching that index substring.
- [ ] Given an event row has a non-null `eventSubtype`, when the Type cell renders, then `(<subtype>)` is shown muted alongside the type.

## Edge Cases

- **Long event list:** initial fetch caps at 100; if the backend reports more, surface `Showing 100 of N` and offer to widen the time-range bucket.
- **Polling network failure mid-session:** a single failed poll does not flip the page to Load-error; it surfaces a non-modal `Last refresh failed — retrying` chip and keeps the previous rows visible. Three consecutive failures escalate to Load-error.
- **Time-range with no events:** Empty-no-events-yet state shown; volume chart suppressed.
- **Duplicate events across indexes:** row-key derived from full identity tuple (`timestampMs|index|type|subtype|name|token|httpCode|objectIds|validationErrors`) plus an ordinal suffix; two events differing only by index render as distinct rows with the Index column disambiguating.
- **Malformed payload:** if `JSON.stringify` throws on the detail panel, render `<unable to serialize>` in the `<pre>` and disable the copy button.
- **Visibility flapping:** debounce visibility-driven refresh by 200ms to avoid stampede on rapid alt-tab.

## Current Implementation Gaps

Citations from [tab_events.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/tab_events.md) and [CRITICAL_BUGS.md](../audits/feature-parity/20260525T165423Z_fjcloud_vs_engine_dashboard_extension/CRITICAL_BUGS.md):

- **Refresh-only model (P0-1):** `web/src/routes/console/indexes/[name]/tabs/EventsTab.svelte:82` is a `<form method="POST">` with no `setInterval`. No auto-poll, no visibility handling.
- **Silent 500 swallow (S1-2):** `web/src/routes/console/indexes/[name]/+page.server.ts:173` catches debug errors into `null`, indistinguishable from empty.
- **Row-key collision (S3-1):** `EventsTab.svelte:200` uses `${ts}-${name}-${token}`; intra-ms duplicates collide. Port upstream `buildDebugEventRows` ordinal pattern from `flapjack_dev/engine/dashboard/src/pages/eventDebuggerUtils.ts:40`.
- **Missing Index column:** table headers are Time/Type/Name/User/Status/Objects; spec requires Index between Time and Type (`EventsTab.svelte:190`).
- **Missing Index filter input:** filter strip has Status/Type/TimeRange only; no `filter-index` control.
- **Missing volume chart:** counters exist; no time-series AreaChart. Port `buildEventVolumeSeries` from `eventDebuggerUtils.ts:87`.
- **Missing `All available` preset:** `EventsTab.svelte:148-156` lists only `15m/1h/24h/7d`.
- **Missing `eventSubtype` render:** `EventsTab.svelte:210` reads `event.eventType` only; subtype field in `web/src/lib/api/types.ts:667` is never displayed.
- **Missing copy-payload button:** detail panel at `EventsTab.svelte:233-285` lacks clipboard action.
- **Missing labelled detail rows:** detail panel shows Object IDs + Validation Errors + Raw JSON only; no labelled summary block for Name/Type/Index/User Token/Status/Timestamp.
- **Zero Playwright coverage:** `web/tests/e2e-ui/` has no `events.spec.ts` in `full/` or `mocked/`.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/events.spec.ts` (TARGET — does not yet exist; covers auto-poll arrival within 6s, status/type/index filters, row→detail, copy payload, intra-ms duplicate rendering, visibility-pause/resume).
- Browser-mocked tests: `web/tests/e2e-ui/mocked/events.spec.ts` (TARGET — covers Load-error vs Empty distinction by stubbing `**/api/indexes/*/events/debug*` with 500, empty, validation-error responses).
- Component tests: `web/src/routes/console/indexes/[name]/tabs/EventsTab.test.ts` (extend with row-key ordinal-suffix duplicate-selection-preservation case).
- Server/contract tests: `web/src/routes/console/indexes/[name]/+page.server.test.ts` (extend with `eventsLoadError` propagation on 500).
