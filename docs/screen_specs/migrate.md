# Migrate Screen Spec

## Scope

- Primary route: `/console/migrate`
- Audience: authenticated customers with existing bookmarks or direct links
- Priority: P0

## User Goal

Understand that customer-facing Algolia imports are temporarily unavailable without being offered a working credential, source-index, or import workflow.

## Target Behavior

`/console/migrate` remains an authenticated console route. The page loads the shared API availability contract from `GET /migration/algolia/availability` and renders a read-only explanation state.

The page tells customers that new Algolia imports are paused while the importer is replaced. It must not render Algolia App ID or API key fields, source-index controls, target-index controls, browse-index controls, overwrite controls, form actions, or import CTAs.

Console navigation must not advertise migration as a usable action while the route remains reachable for authenticated direct visits.

## Required States

- Unavailable: render `Migrate from Algolia`, the typed unavailable message, copy that new Algolia imports are temporarily turned off, and support contact guidance.
- Session expired: use the shared dashboard session-expiry handling from the page load owner.

## Acceptance Criteria

- [ ] Authenticated direct visits to `/console/migrate` render the unavailable explanation page.
- [ ] The page has no list, migrate, credential, source-index, target-index, overwrite, or import controls.
- [ ] Console navigation does not include a `Migrate` link while the importer is unavailable.
- [ ] The route-level server load fetches the authenticated availability contract through the shared API client instead of encoding page-local availability constants.

## Current Implementation Gaps

- None known for the fail-closed unavailable state. Re-opening customer-facing import actions requires a new screen spec and automated coverage before exposing controls.

## Automated Coverage

- Browser proof: `web/tests/e2e-ui/full/migration-recovery.spec.ts` covers authenticated direct access, unavailable copy, and absence of working migration controls.
- Component proof: `web/src/routes/console/migrate/migrate.test.ts` covers the unavailable page and absence of form controls.
- Server/contract proof: `web/src/routes/console/migrate/migrate.server.test.ts` covers the shared availability load and absence of form actions.
- API client proof: `web/src/lib/api/client-migration.test.ts` covers `GET /migration/algolia/availability`.
