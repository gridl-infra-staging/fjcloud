# Documents Tab Screen Spec

## Scope

- Primary route: `/dashboard/indexes/[name]` documents tab
- Related route: `/dashboard/indexes/[name]`
- Audience: authenticated customers managing index records
- Priority: P0

## User Goal

Upload batch records, add a single record manually, browse indexed documents, and delete records.

## Target Behavior

The tab shows a `Documents` panel with upload, manual add, browse, and delete workflows. Upload supports JSON or CSV files, previews parsed records, enforces the 100MB limit, and disables upload when parsing fails or no records are parsed.

## Required States

- Loading: browse actions should preserve the documents panel while refreshed data returns.
- Empty: no hits shows a truthful no-document/empty browse state.
- Error: upload, add, browse, and delete failures show visible tab-local error copy.
- Success: upload/add/browse/delete each show visible confirmation text and updated browse results where applicable.

## Controls And Navigation

- `Upload JSON or CSV file` file input parses file contents client-side.
- `Upload Records` submits parsed batch payload.
- `Record JSON` textarea submits one manual document.
- Browse controls query records and page by cursor/hits-per-page.
- Delete controls remove a visible document row.

## Acceptance Criteria

- [ ] Documents tab lazy-mounts only after click.
- [ ] Upload and browse controls are visible in the tab.
- [ ] File parsing preview shows selected format and sample records before upload.
- [ ] Server action success/error feedback is visible in the documents section.

## Current Implementation Gaps

Browser-unmocked coverage currently verifies tab presence and controls; full upload/add/delete browser workflows are not fully mapped.

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/customer-journeys.spec.ts`
- Component tests: `web/src/routes/dashboard/indexes/[name]/tabs/DocumentsTab.test.ts`
- Server/contract tests: `web/src/routes/dashboard/indexes/[name]/detail.server.actions.test.ts`
