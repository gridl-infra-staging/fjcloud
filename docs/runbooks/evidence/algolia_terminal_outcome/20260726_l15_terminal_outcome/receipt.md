# L15 Terminal Outcome Receipt

## Scope

This receipt proves the Fjcloud terminal-only Algolia migration outcome contract at one current tree. It covers the updater-owned contract fixture, Rust wire/status validation, PostgreSQL reconciliation and persistence presence, frontend presentation behavior, and repository hygiene gates.

It does not claim deployment, adjacent parity or privacy lanes, roadmap closeout, raw upstream payload retention, or a second outcome/warning owner.

## Provenance

- Fjcloud tested SHA: `06fcadbd85df93160b2727a718e0d05cb8374a02`
- Flapjack producer SHA: `bf4324175037014b19726a06771802bad6b649a8`
- Fixture owner: `infra/api/tests/fixtures/algolia_migration_engine_contract.json`
- Validation-cache owner: `matt.validation_cache` from the required matt install path
- Cache disposition: all accepted results below were run fresh at the tested Fjcloud SHA; no exact-HEAD cache hit was used as closing evidence.

## Command Evidence

| Command | Fresh/cache | Result |
| --- | --- | --- |
| `FLAPJACK_DEV_DIR=<clean-merged-checkout> bash scripts/update_algolia_migration_engine_contract.sh --check` | Fresh | PASS; output ended `Algolia migration engine contract is current`; Rust contract self-tests reported `1 passed` in each selected test binary. |
| `bash scripts/tests/update_algolia_migration_engine_contract_test.sh` | Fresh | PASS; output ended `PASS update_algolia_migration_engine_contract_test`. |
| `cd infra && cargo test -p api --lib services::algolia_import -- --nocapture` | Fresh | PASS; `48 passed; 0 failed; 0 ignored; 822 filtered out`. |
| `DATABASE_URL=(from repo-local loopback env backup) cd infra && cargo test -p api --lib services::algolia_import::reconciliation_postgres_tests -- --nocapture` | Fresh | PASS; `3 passed; 0 failed; 0 ignored; 867 filtered out`; no `DATABASE_URL not set` skip line in the accepted run. |
| `DATABASE_URL=(from repo-local loopback env backup) cd infra && cargo test -p api --test platform algolia_import_job_domain -- --nocapture` | Fresh | PASS; `146 passed; 0 failed; 0 ignored; 1429 filtered out`; no `DATABASE_URL not set` skip line in the accepted run. |
| `DATABASE_URL=(from repo-local loopback env backup) cd infra && cargo test -p api --test platform migration_066_algolia_terminal_outcome_presence_test -- --nocapture` | Fresh | PASS; `1 passed; 0 failed; 0 ignored; 1574 filtered out`; no `DATABASE_URL not set` skip line in the accepted run. |
| `cd web && npm test -- src/lib/components/migration/job_presentation.test.ts src/lib/components/migration/ImportJobDetail.test.ts` | Fresh | PASS; `2 passed` files and `128 passed` tests, split as `70` presentation tests and `58` detail tests. |
| `bash scripts/local-ci.sh --fast` | Fresh | PASS; `33` pass, `0` fail, `0` skip. |
| `bash scripts/check-sizes.sh` | Fresh | PASS; exited 0 with no stdout/stderr and no separate bundle or artifact-size denominator. |
| `bash scripts/check_evidence_secret_hygiene.sh` before receipt | Fresh | PASS; output `Evidence secret hygiene passed`. |
| `git diff --check` before receipt | Fresh | PASS; exited 0 with no output. |

## Red-Failing Specimens

- Producer schema drift: the updater check fails if the Flapjack contract no longer exposes the pinned successful terminal outcome keys `settingsApplied`, `synonymsImported`, `rulesImported`, and `warnings` in the fixture owner.
- Premature outcomes: `status_tests::outcome_fields_are_rejected_before_successful_terminal_publication` rejects outcome fields on non-success dispositions.
- Missing terminal timestamp: `status_tests::successful_outcome_requires_terminal_at` rejects successful outcome publication without `terminalAt`.
- Partial bundles: `status_tests::partial_settings_synonym_rule_bundles_are_rejected` rejects incomplete settings/synonym/rule outcome bundles.
- Legacy absence versus real zero: `status_tests::legacy_success_without_outcome_remains_accepted_without_synthesis`, `status_tests::successful_terminal_status_accepts_complete_outcome`, and `algolia_import_job_domain::repository_distinguishes_absent_terminal_outcome_from_real_all_zero_outcome` distinguish absent legacy outcome data from a real all-zero success.
- Count rewinds: `observation_tests::status_observation_rejects_identity_phase_and_progress_rewind` rejects progress/count rewind attempts.
- Duplicate terminal reconciliation: `reconciliation_tests::reconcile_once_counts_already_applied_and_rejected_terminal_outcomes` and `reconciliation_postgres_tests::postgres_reconciliation_acknowledges_before_and_after_worker_restart` prove retained terminal facts and ack behavior are idempotent.
- Warning projection: `status_tests::terminal_outcome_warning_bounds_fail_closed`, `observation_tests::status_observation_maps_structured_warnings_to_completed_with_warnings`, and `observation_tests::status_observation_output_excludes_engine_metadata_and_unpinned_outcomes` bound customer-visible warning handling and exclude unpinned producer material.
- UI resume/no-zero behavior: `job_presentation.test.ts` and `ImportJobDetail.test.ts` prove legacy success renders no fabricated zeroes, real all-zero success renders zeroes, warnings remain customer-safe, and `resume=false` still leaves no Resume action.

## Hygiene

This receipt contains no host-absolute worktree paths, secrets, credentials, raw upstream payloads, arbitrary producer-authored warning text, generated/scrai churn, deployment claims, adjacent-lane claims, or `ROADMAP.md` closeout.
