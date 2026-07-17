# Index Detail

## Task

Inspect one index and open the management area needed for the next index task.

## Layout

1. Breadcrumbs and index-name heading.
2. Header actions: `API Activity Log`, customer-facing status badge with icon and help
   tooltip, and destructive `Delete Index` action.
3. API activity panel directly below the heading when expanded.
4. Tab list: Overview, Search, Settings, Documents, Dictionaries, Synonyms,
   Personalization, Recommendations, Chat, Suggestions, Analytics, Metrics, Merchandising,
   Experiments, Events, and Security Sources.
5. Active tab panel. Overview is the default; Search is second.

## State contract

### Loading

- The route resolves the index before rendering the detail shell; no partially populated
  heading or invented status is shown.

### Error

- A route failure uses the application error boundary. Tab-action failures remain visible
  inside their owning tab with a recovery action when retry is possible.

### Available

- A successful live engine-stats read shows a green icon and `Available`.
- The status tooltip explains that the index is reachable and ready for requests.

### Status unresolved

- Before runtime health is known, show a neutral icon and `Checking status`, never `Unknown`.
- The tooltip explains that the dashboard has not confirmed runtime health yet.

### API activity collapsed

- `API Activity Log` has `aria-expanded="false"` and a rose hover/focus treatment.
- No activity panel occupies space below the header.

### API activity expanded

- The same button has `aria-expanded="true"` and the activity panel appears immediately
  below the heading so the result of the action is visible.

### Post-create arrival

- Create completion uses the canonical detail URL without a one-time query marker.
- No `Index ready` banner or `Open Search` button renders. Search remains directly available
  as the second tab; transient completion feedback uses shared toasts.

## Navigation

- Route: `/console/indexes/[name]`; `?tab=<id>` owns the selected tab.
- Entry: index-name link from `Indexes`, create completion, or a deep link.
- Browser back/forward restores selected-tab URL state and already visited lazy panels.
- Delete asks for confirmation and redirects to `/console/indexes` after success.
- Search deep links use `?tab=search`; no legacy Search slug is accepted by this spec.

## Acceptance Criteria

- Given a seeded index, when detail loads, then its exact name, region, status, and Overview
  content render in the page body.
- Given a reachable shared index with stale unknown deployment metadata, when live stats
  succeed, then the badge says `Available` rather than `Unknown`.
- Given status is unresolved, then the badge says `Checking status` and its question-mark
  tooltip explains the state without relying on color alone.
- Given API activity is collapsed, when the customer activates `API Activity Log`, then the
  button reports expanded state and the activity panel appears directly below the heading.
- Given create succeeds, then the canonical detail URL has no one-time query marker and no
  redundant `Index ready` banner or `Open Search` button renders.
- Given a non-default tab has not been selected, it is not mounted; after selection it is
  visible and remains mounted across tab navigation.
- Given desktop or narrow navigation, Search is the second tab and its canonical URL is
  `/console/indexes/[name]?tab=search`.

## Edge cases

- Empty tab-specific resources show truthful empty states rather than generic failures.
- A failed status read retains `Checking status` and explains it; it does not imply the index
  is healthy or broken.
- At narrow widths, tab navigation remains operable and does not hide or rename Search.

## Current Implementation Gaps

None verified. The target behavior is implemented and mapped to the automated owners below.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/indexes.spec.ts`; `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/isolation.spec.ts`
- Component tests: `web/src/routes/console/indexes/[name]/detail.test.ts`; the existing detail Search URL-state component test; `web/src/routes/console/indexes/[name]/detail.server.load.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.load.test.ts`; `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`
