# Documents Tab Screen Spec

## Scope

- Primary route: `/console/indexes/[name]` documents tab
- Related route: `/console/indexes/[name]`
- Audience: authenticated customers managing index records
- Priority: P0

## User Goal

Upload batch records and add a single record manually.

## Target Behavior

The tab shows a `Documents` panel with upload and manual-add workflows. Upload supports JSON or CSV files, previews parsed records, enforces the 100MB limit, and disables upload when parsing fails or no records are parsed. Search, browse, and per-record deletion belong to [search.md](search.md).

## Required States

- Loading: parsing/upload/add actions should preserve the documents panel while work is in flight.
- Empty: no selected file or empty manual JSON shows truthful helper copy without implying that browse belongs here.
- Error: upload, parse, and manual-add failures show visible tab-local error copy.
- Success: upload and manual-add each show visible confirmation text and refresh the index metadata where applicable.

## Controls And Navigation

- `Upload JSON or CSV file` file input parses file contents client-side.
- `Upload Records` submits parsed batch payload.
- `Record JSON` textarea submits one manual document.
- Browse and deletion controls are intentionally absent; users search, browse, and remove records from the Search tab.

## Acceptance Criteria

- [ ] Documents tab lazy-mounts only after click.
- [ ] Upload and manual-add controls are visible in the tab.
- [ ] File parsing preview shows selected format and sample records before upload.
- [ ] Server action success/error feedback is visible in the documents section.
- [ ] Search, browse, and record deletion controls are absent from the Documents tab and documented in [search.md](search.md).

## Current Implementation Gaps

Browser-unmocked coverage currently verifies tab presence and controls; full upload/add browser workflows are not fully mapped. Search and record deletion coverage belongs to [search.md](search.md).

## Automated Coverage

- Browser-unmocked tests: `web/tests/e2e-ui/full/index-detail.spec.ts`; `web/tests/e2e-ui/full/customer-journeys.spec.ts`
- Component tests: `web/src/routes/console/indexes/[name]/tabs/DocumentsTab.test.ts`
- Server/contract tests: `web/src/routes/console/indexes/[name]/detail.server.actions.test.ts`
