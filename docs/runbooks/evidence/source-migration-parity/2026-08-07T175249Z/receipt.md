# Source Migration Provider Parity Receipt

Date: 2026-08-07T17:52:49Z

Supersedes: `docs/runbooks/evidence/source-migration-parity/2026-08-07T165941Z/receipt.md`

Validated code state:

- Commit: `67f8944aec34cc11acb3286242272771f23db7d4`
- Tree: `4b27126212ee0e5eb45707baae146adcbad9d4c0`
- Engine PIN: Flapjack `1.0.11`

Version: Flapjack `1.0.11`

Command:

```sh
cd web && DATABASE_URL=postgres://griddle:griddle_local@127.0.0.1:17820/fjcloud_dev LOCAL_DB_PORT=17820 npm run test:e2e -- --grep "source migration provider parity" --reporter=list
```

Locality:

- Ran against the worktree-local Playwright database port (`127.0.0.1:17820`).
- Provider methods stayed qualified: Meilisearch and Typesense are `local-container`; Algolia is `live-probe`.

Result: 4 passed (8.3m)

```text
4 passed (8.3m)
```

Observed warning-locator evidence:

- The Meilisearch row passed with `minimumWarningLocators: 1` bound to `comparableWarningTuples(shape, contract.warningCodePattern)`.
- A locator-bound mutation to `minimumWarningLocators: 2` still passed for the Meilisearch row, proving the compared Meilisearch set carries more than one rendered locator.
- A locator-bound mutation to `minimumWarningLocators: 999` failed at `web/tests/e2e-ui/full/source_migration_provider_parity.spec.ts:266` with `Received: 9`, proving the locator-bound guard fails when the compared set lacks the required rendered locators.

Mutation/control evidence from this remediation:

- RED browser gate, locator bound: temporary `minimumWarningLocators: 999` failed the Meilisearch row at the compared-set locator guard (`Expected: >= 999`, `Received: 9`).
- RED browser gate, exact counts: temporary `previewCountsText` mutation rendered an expected `11 source index · 3 records`; the Meilisearch row failed at `migration-preview-counts` `toHaveText` because the page rendered `1 source index · 3 records`.
- GREEN browser gate: restored code passed the full provider parity gate (`4 passed (8.3m)`).

Static validation:

- `cd web && npm run lint:e2e` -> `0 errors, 123 pre-existing warnings`
