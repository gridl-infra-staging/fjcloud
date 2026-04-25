# Search Preview Tab Screen Spec

## Scope

- Primary route: `/dashboard/indexes/[name]` search preview tab
- Related route: `/dashboard/indexes/[name]`
- Audience: authenticated customers testing live search behavior
- Priority: P0

## User Goal

Generate a temporary preview key and run real searches against the selected index from the dashboard.

## Target Behavior

The tab shows `Search Preview`. Cold/restoring indexes show unavailable copy. Indexes without endpoint show provisioning copy. Active indexes with endpoint show `Generate Preview Key`; after key generation the InstantSearch widget mounts for the current index.

## Required States

- Loading: provisioning/readiness waits should show endpoint-unavailable or readiness copy rather than a blank panel.
- Empty: no preview key shows explanatory copy plus `Generate Preview Key`.
- Error: preview-key failures show visible text inside the search preview section.
- Success: generated key mounts `InstantSearch` with search box and hits area.

## Controls And Navigation

- `Generate Preview Key` submits a server action for a temporary key.
- InstantSearch search box accepts queries and displays live hits.

## Acceptance Criteria

- [ ] Search Preview tab is discoverable on the detail page.
- [ ] Active ready indexes wait through provisioning and show `Generate Preview Key`.
- [ ] Clicking `Generate Preview Key` mounts the InstantSearch search box.
- [ ] Searchable seeded data returns the expected hit text in the hits area.
- [ ] Cold/restoring/provisioning states never show a misleading active search box.

## Current Implementation Gaps

Hard-to-reproduce unavailable states may eventually need browser-mocked coverage; do not add a mocked suite unless the state cannot be produced deterministically with fixtures.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/search-preview.spec.ts`; `web/tests/e2e-ui/full/indexes.spec.ts`; `web/tests/e2e-ui/full/isolation.spec.ts`
- Component tests: `web/src/routes/dashboard/indexes/[name]/tabs/SearchPreviewTab.test.ts`; `web/src/routes/dashboard/indexes/[name]/detail-search-preview.test.ts`
- Server/contract tests: `web/src/routes/dashboard/indexes/[name]/detail.server.actions.test.ts`; `web/src/tests/search-preview-helpers.test.ts`
