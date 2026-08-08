# Source Migration Provider Parity Receipt

Date: 2026-08-07T16:59:41Z

Command:

```sh
cd web && npm run test:e2e -- --grep "source migration provider parity" --reporter=list
```

Locality:

- Ran against this worktree's isolated Playwright database port (`LOCAL_DB_PORT=17820`) because the default repo env pointed at a shared `5432` database from another worktree with a partial migration-073 state.
- Provider methods stayed qualified: Meilisearch and Typesense are `local-container`; Algolia is `live-probe`.

Result:

```text
4 passed (5.6m)
```

Mutation/control evidence from this remediation:

- RED fixture unit: adding `minimumWarningLocators` expectations failed until `SourceMigrationPreviewExpectation` owned the field (`2 failed, 12 passed`).
- RED fixture unit: adding preview `warningCodePattern` expectations failed until the fixture owned the preview-specific code vocabulary (`2 failed, 12 passed`).
- RED browser gate: row-aligned tuple comparison failed when Meilisearch preview carried five `ProductNotMigrated/path $` rows not retained post-import, proving the tuple guard can fail for a real warning-set defect.

Static validation:

- `cd web && npm run test -- tests/fixtures/source_migration_provider_parity.test.ts` -> `14 passed`
- `cd web && npm run lint:e2e` -> `0 errors, 123 pre-existing warnings`
- `cd web && npm run check` -> `1770 files, 0 errors, 0 warnings`
