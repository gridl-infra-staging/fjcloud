# Snapshots Screen Spec

## Scope

- Primary route: `/snapshots`
- Related routes: current React entry is `/system` > `Snapshots`; target System cross-link is `system.md`
- Audience: standalone engine operators exporting, importing, backing up, and restoring engine indexes
- Priority: P1 standalone-only ops surface per `docs/design/console_unification_revised_plan.md` Decision R5

## User Goal

Move index data into and out of local tarballs or S3-compatible storage with clear feedback, while understanding when S3 is not configured.

## Target Behavior

Snapshots is a standalone target surface even though React currently exposes `SnapshotsTab` inside `engine/dashboard/src/pages/System.tsx`. It fetches indexes via GET `/1/indexes` relative to the serving origin through `useIndexes` and uses snapshot hooks from `engine/dashboard/src/hooks/useSnapshots.ts`.

The successful page renders:

- Hidden file input `snapshot-file-input` accepting `.tar.gz,.tgz`; after file selection, `onFileSelected` imports into the last chosen index and resets the input value.
- `Local Export / Import` card with each index row showing `<uid>`, formatted document count, formatted bytes, `export-btn-<uid>`, and `import-btn-<uid>`.
- `export-all-btn`, which loops over every loaded index and fires one export mutation per index.
- `S3 Backups` card. Current React infers S3 availability by listing snapshots for the first index, with no retry and a 60-second stale time; it does not call a separate capability probe.
- Unconfigured S3 state `s3-not-configured` with exact instructions:
  - `FLAPJACK_S3_BUCKET=your-bucket-name`
  - `FLAPJACK_S3_REGION=us-east-1`
  - `FLAPJACK_S3_ENDPOINT=https://s3.amazonaws.com  (optional)`
- Configured S3 state with optional `{count} snapshot(s) available for {firstIndex}`, each `s3-index-<uid>` row, `backup-btn-<uid>`, `restore-btn-<uid>`, and `backup-all-s3-btn`.
- `Backup All to S3`, which loops over every loaded index and fires one snapshot mutation per index.

Pending export disables export buttons globally; pending import disables import buttons globally; pending backup disables S3 backup buttons; pending restore disables S3 restore buttons. Toast feedback is source-owned: `Export complete`, `Export failed`, `Import started`, `Import failed`, `Backup started`, `Backup failed`, `Restore started`, and `Restore failed`; failures use destructive toasts.

Snapshot route contracts are owned by `engine/flapjack-http/src/router.rs` and `engine/flapjack-http/src/handlers/snapshot.rs`:

| Method/path | Request | Success response | Error evidence |
| --- | --- | --- | --- |
| GET `/1/indexes/:indexName/export` | none | `application/gzip` attachment with `Content-Disposition: attachment; filename="<index>.tar.gz"` | 404 `{ "message": "Index not found", "status": 404 }`; 500 `{ "message": "Internal server error", "status": 500 }` |
| POST `/1/indexes/:indexName/import` | gzip bytes, UI sends `Content-Type: application/gzip` | `{ "status": "imported" }` | sanitized 500 `{ "message": "Internal server error", "status": 500, "sub_step": string }` for install failures |
| POST `/1/indexes/:indexName/snapshot` | none | `{ "status": "uploaded", "key": string, "size_bytes": number }` | 503 `{ "message": "S3 not configured. Set FLAPJACK_S3_BUCKET and FLAPJACK_S3_REGION.", "status": 503 }`; 404 index not found; 500 internal |
| POST `/1/indexes/:indexName/restore` | optional JSON `{ "key": "snapshots/<same-index>/<file>.tar.gz" }`; current UI sends no body | `{ "status": "restored", "key": string, "size_bytes": number }` | 503 `{ "message": "S3 not configured", "status": 503 }`; 400 invalid/cross-index key; 404 snapshot not found; 500 internal |
| GET `/1/indexes/:indexName/snapshots` | none | `{ "snapshots": [...] }` | 503 `{ "message": "S3 not configured", "status": 503 }`; 500 internal |

## Required States

- Loading: while the index list is loading, render two skeleton blocks.
- Empty: when the index list is absent or empty, render exact copy `No indexes available. Create an index first to use snapshots.`
- Error: there is no separate index-list error branch in the React source; if `useIndexes` returns no usable data, the empty copy renders. Mutation failures produce destructive toasts listed under Target Behavior. S3-list failure renders the unconfigured S3 branch.
- Success: render `snapshots-tab`, local card, S3 card, all index rows, all selectors listed under Target Behavior, pending disables, accepted file types, and success/destructive toasts.

## Mobile Narrow Contract

Baseline viewport: 390px wide. Card headers, all-action buttons, index rows, and per-index action groups stack or wrap so index names, doc/byte copy, and controls remain usable without page-level horizontal overflow. Local and S3 rows may use compact vertical stacking, but every Export, Import, Backup, and Restore control remains reachable.

## Controls And Navigation

- Entry from current React is selecting `Snapshots` inside `/system`; target standalone placement is `/snapshots` with a System cross-link back to `system.md`.
- `Export All` triggers browser downloads for every loaded index by calling GET `/1/indexes/:indexName/export` once per index.
- `Export` triggers one browser download named `<index>.tar.gz`.
- `Import` opens `snapshot-file-input`; selecting a `.tar.gz` or `.tgz` file posts the file to `/1/indexes/:indexName/import` and resets the input.
- `Backup All to S3` posts `/1/indexes/:indexName/snapshot` once per loaded index.
- `Backup` posts one S3 snapshot request.
- `Restore` posts `/1/indexes/:indexName/restore` with no key body in current UI, so the backend restores the latest same-index snapshot.

## Acceptance Criteria

- [ ] Given the operator enters Snapshots from System, when the standalone target exists, then the operator lands on `/snapshots` and can return to the System contract in `system.md`.
- [ ] Given indexes are loading, when Snapshots renders, then two skeleton blocks occupy the page body.
- [ ] Given there are no indexes, when Snapshots renders, then it shows `No indexes available. Create an index first to use snapshots.`
- [ ] Given indexes exist, when Snapshots renders, then `snapshots-tab`, `snapshot-file-input`, `Local Export / Import`, `S3 Backups`, `snapshot-index-<uid>`, `export-btn-<uid>`, and `import-btn-<uid>` are present.
- [ ] Given an index row, when it renders, then it shows the index UID, localized document count, and `formatBytes(dataSize)`.
- [ ] Given `Export All` is activated, when indexes are loaded, then the UI fires one export mutation per index and disables export controls while an export is pending.
- [ ] Given `Export` is activated for one row, when GET `/1/indexes/:indexName/export` succeeds, then a browser download named `<index>.tar.gz` is triggered and a toast says `Export complete`.
- [ ] Given `Import` is activated, when the file input opens, then only `.tar.gz` and `.tgz` are accepted; after selection the file posts to `/1/indexes/:indexName/import`, input value resets, and success toast says `Import started`.
- [ ] Given export or import fails, when the mutation settles, then destructive toast copy starts with `Export failed` or `Import failed`.
- [ ] Given S3 listing for the first index fails, when Snapshots renders, then `s3-not-configured` and the three `FLAPJACK_S3_*` instructions are visible.
- [ ] Given S3 listing succeeds with snapshots, when Snapshots renders, then it shows `{count} snapshot(s) available for {firstIndex}` and per-index `s3-index-<uid>`, `backup-btn-<uid>`, and `restore-btn-<uid>` rows.
- [ ] Given `Backup All to S3` is activated, when indexes are loaded, then the UI fires one snapshot mutation per index and disables backup controls while pending.
- [ ] Given `Backup` succeeds or fails, when the mutation settles, then the toast says `Backup started` or destructive `Backup failed`.
- [ ] Given `Restore` succeeds or fails, when the mutation settles, then the toast says `Restore started` or destructive `Restore failed`.
- [ ] Given a 390px viewport, when Local and S3 cards render, then headers, all-action buttons, rows, and per-index controls remain operable without page-level horizontal overflow.

## Visual contract

Name the target visual treatment for this screen without creating a second design system:

- Layout and surface: mirror the source card treatment from `SnapshotsLocalCard`, `SnapshotsS3Card`, and `SnapshotIndexRow`: page-level stack, separate Local and S3 cards, bordered per-index rows, and compact action buttons.
- Typography and color: use fjcloud card, border, muted, primary, and destructive toast tokens from `web/src/app.css`. S3 availability may use icon/color, but copy must state configured or not configured.
- Controls and states: buttons use visible text plus icons, disabled pending states, hidden file input, and destructive toast failures.
- Mobile: cards and row actions stack/wrap at 390px; no page-level horizontal overflow.
- Implementation evidence: `engine/dashboard/src/pages/System.tsx::SnapshotsTab`, `handleImport`, `onFileSelected`, `handleExportAll`, `handleBackupAll`; `engine/dashboard/src/pages/SystemTabSections.tsx::SnapshotsLocalCard`, `SnapshotsS3Card`, `SnapshotIndexRow`; `engine/dashboard/src/hooks/useSnapshots.ts`; `engine/dashboard/src/hooks/useIndexes.ts`; `engine/flapjack-http/src/router.rs`; `engine/flapjack-http/src/handlers/snapshot.rs`.

## Current Implementation Gaps

- The managed fjcloud console does not render this standalone-only surface today.
- React currently couples Snapshots to `/system`; Decision R5 requires standalone placement.
- S3 availability is inferred by listing snapshots for the first index. There is no source-owned capability probe, no retry, and no per-index availability check.
- The current UI restore action sends no `key`, while the backend supports an optional same-index restore key. No target key picker is evidenced.
- `useSnapshots.ts` types `S3Snapshot` as `{ name, size, lastModified }`, but the backend list handler returns a raw `snapshots` array from S3 keys. This response/model mismatch is an implementation gap to resolve during the port.
- Index-list errors currently fall through to the empty copy because `SnapshotsTab` only checks loading and `!indexes || indexes.length === 0`.

## Automated Coverage

- Browser-unmocked tests: no fjcloud implementation coverage exists yet. External React scenario evidence is `engine/dashboard/tests/specs/system.md` scenario `system-4: Snapshots tab`.
- Component tests: no fjcloud component tests exist yet for this standalone-only surface.
- Server/contract tests: external source evidence is `engine/flapjack-http/src/handlers/snapshot.rs` handler tests for export missing index, import success, sanitized import failure, restore-key validation, and export retry behavior; fjcloud does not yet own snapshot route contract tests.
