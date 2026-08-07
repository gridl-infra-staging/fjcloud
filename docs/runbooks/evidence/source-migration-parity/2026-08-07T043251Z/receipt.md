# Source Migration Provider Parity Receipt

PURPOSE: Certify the source-migration provider parity gate against the released Stage 2 Flapjack engine selected for this fjcloud integration lane.

## Engine

- Version: `1.0.11`
- Commit: `6e9bec7bc5aded32580a0d680066c086f10ab3bd`
- Build-info revision: `6e9bec7bc5aded32580a0d680066c086f10ab3bd`
- Build-info dirty: `false`
- Ancestry proof: `git -C <flapjack checkout> merge-base --is-ancestor 6e9bec7bc5aded32580a0d680066c086f10ab3bd origin/main` exited `0`.
- Resolver proof: `FLAPJACK_DEV_DIR` was unset; `scripts/lib/flapjack_binary.sh` resolved an isolated detached Stage 2 Flapjack worktree through `FLAPJACK_DEV_DIR_CANDIDATES` and reported `flapjack 1.0.11`.

This receipt does not use the deleted `2026-08-05-stage3` phantom engine. The stale hash is intentionally not repeated in this committed receipt so the Stage 3 literal-grep guard remains clean outside the lane plan.

## Parity Gate

Command:

```bash
cd web && npm run test:e2e -- --grep "source migration provider parity" --reporter=list
```

Evidence: `docs/runbooks/evidence/source-migration-parity/2026-08-07T043251Z/parity_gate.log`

Result: `Running 4 tests using 1 worker`; `4 passed (6.7m)`.

## Mutation Controls

Re-run controls:

- `meilisearch imported denominator`: injected expected text `4 imported ...` while the UI rendered `Documents: 3 imported ...`; red transcript retained at `docs/runbooks/evidence/source-migration-parity/2026-08-07T043251Z/meilisearch_imported_denominator_red.log`; restored-green transcript retained at `docs/runbooks/evidence/source-migration-parity/2026-08-07T043251Z/meilisearch_imported_denominator_green.log` with `Running 2 tests` and `2 passed`.
- `typesense imported denominator`: injected expected text `4 imported ...` while the UI rendered `Documents: 3 imported ...`; red transcript retained at `docs/runbooks/evidence/source-migration-parity/2026-08-07T043251Z/typesense_imported_denominator_red.log`; restored-green transcript retained at `docs/runbooks/evidence/source-migration-parity/2026-08-07T043251Z/typesense_imported_denominator_green.log` with `Running 2 tests` and `2 passed`.

Controls not re-run as standalone mutations: `source_changed noop`, `destination absence guard`, and `canary browser artifact`. They remain covered by the full parity lifecycle transcript but are not claimed as fresh red/green mutation controls in this receipt.

## Supporting Validation

- `cd infra && cargo test -p api --test platform migration_routes_test::create_contract::source_revision -- --nocapture`: `7 passed; 0 failed; 0 ignored`.
- `cargo test -p api --test platform migration_routes_test::discovery::neutral_contract::typesense_discovery_attaches_content_revision_when_updated_at_is_null -- --exact --nocapture`: `1 passed`.
- `cargo check -p api`: passed.
- `npm run test -- src/lib/components/migration/migration_create_client.test.ts src/lib/api/client_migration_neutral.test.ts`: `2 passed`, `55 passed`.
- `npm run check`: `0 ERRORS 0 WARNINGS`.
