# Index Detail Screen Spec

## Scope

- Primary route: `/dashboard/indexes/[name]`
- Related specs: `documents.md`, `search_preview.md`
- Audience: authenticated customers managing one search index
- Priority: P0

## User Goal

Inspect one index, switch among management tabs, update index-owned resources, and delete the index when needed.

## Target Behavior

The detail page shows the index name as heading, index status metadata, delete action, and a tab list. Overview is mounted by default; other tab panels lazy-mount only after first visit while preserving page context.

## Required States

- Loading: route load should render heading and overview metadata after seeded index data resolves.
- Empty: tab-specific empty states show truthful messages, such as no rules, no synonyms, or no documents.
- Error: tab action failures show visible tab-local error copy.
- Success: tab actions show visible success feedback and keep the user on the same index detail context unless deletion redirects to the indexes list.

## Controls And Navigation

- Tab buttons expose Overview, Settings, Documents, Dictionaries, Rules, Synonyms, Personalization, Recommendations, Chat, Suggestions, Analytics, Merchandising, Experiments, Events, Security Sources, and Search Preview.
- Delete action asks for browser confirmation and redirects to `/dashboard/indexes` after successful deletion.
- API log panel can be toggled without hiding the active tab context.

## Acceptance Criteria

- [ ] Seeded detail route renders the index name heading.
- [ ] Non-default tabs are not mounted before click and become visible after click.
- [ ] Settings tab exposes `Settings JSON` and `Save Settings`.
- [ ] Documents, dictionaries, rules, synonyms, and chat tabs show their expected controls or empty states.
- [ ] Detail route reflects the selected runtime region for seeded indexes.

## Current Implementation Gaps

This spec summarizes the shared detail shell; deeper tab behavior belongs in dedicated tab specs as those specs are created.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/indexes.spec.ts`; `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/isolation.spec.ts`
- Component tests: `web/src/routes/dashboard/indexes/[name]/detail.test.ts`; `web/src/routes/dashboard/indexes/[name]/detail.server.load.test.ts`
- Server/contract tests: `web/src/routes/dashboard/indexes/[name]/detail.server.load.test.ts`; `web/src/routes/dashboard/indexes/[name]/detail.server.actions.test.ts`
