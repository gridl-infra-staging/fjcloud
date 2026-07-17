# Tenant Isolation Proptest Stage 3 Evidence

Verified UTC: 20260709T193214Z
Command-run HEAD: `955a9197a9e6b2eea2d072f90c57634b09b09b36`
Evidence commit note: the original Stage 3 command-run proof was captured at `031ea1099d393fc7e3f94280c5daf8284b3ff88b`; Session 37 repaired the audit gap by rerunning the Stage 3 gates at final landed `HEAD` `955a9197a9e6b2eea2d072f90c57634b09b09b36` and adding the `final_head_*` raw sidecars in this same bundle.

## Classification

Stage 3 confirms the Stage 1/2 classification at the final command-run HEAD: the nightly red was stale harness drift, not runtime tenant-isolation drift. Stage 2 changed only `RouteCase::settings_update()` / `expected_proxy_body` in `infra/api/tests/integration/tenant_isolation_proptest.rs:97-121`. This Stage 3 verification did not reopen runtime owners `update_settings()` in `infra/api/src/routes/indexes/settings.rs:70-101` or `normalize_index_settings_for_engine()` / `update_index_settings()` in `infra/api/src/services/flapjack_proxy/settings.rs:29-96`.

The body diff is the stale-harness point: the old `settings_update` harness expectation omitted `attributesForFaceting`, while the runtime proxy contract mirrors `filterableAttributes` to `attributesForFaceting` before sending settings to Flapjack. Runtime witnesses stayed read-only: `update_settings_proxies_to_flapjack()` in `infra/api/tests/integration/indexes_test.rs:5298-5343`, `update_index_settings_sends_post_with_body()` in `infra/api/tests/integration/flapjack_proxy_domain_methods_test.rs:4-45`, and `classic_settings_put_blocked_for_foreign_tenant()` in `infra/api/tests/integration/cross_tenant_isolation_test.rs:185-197`.

Expected current harness proxy body:

```json
{
  "searchableAttributes": ["title", "body"],
  "filterableAttributes": ["category"],
  "attributesForFaceting": ["category"]
}
```

Field omitted by the old stale expectation:

```json
{"attributesForFaceting": ["category"]}
```

## Commands And Raw Logs

- PASS exit 0: `cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::`
  - Raw log: `tenant_isolation_proptest.stdout.txt`.
  - Result includes `tenant_isolation_proptest_route_family` and `tenant_isolation_proptest_deliberate_leaky_variant_trips_failure_signature` passing at the command-run HEAD.
- PASS exit 0: `cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::tenant_isolation_proptest_deliberate_leaky_variant_trips_failure_signature -- --exact --nocapture`
  - Raw log: `tenant_isolation_deliberate_leaky.stdout.txt`.
  - Output contains the `TENANT_ISOLATION_LEAK_FAILURE_SIGNATURE` value: `bob-foreign-shared-helper-on-alice-index: foreign tenant should be denied`.
  - Output does not contain the old `proxy body mismatch` / `attributesForFaceting` mismatch failure.
- PASS exit 0: `cd infra && cargo clippy -p api`
  - Raw log: `cargo_clippy_api.stdout.txt`.
- PASS exit 0: `bash scripts/local-ci.sh --fast`
  - Raw log: `local_ci_fast.stdout.txt`.
  - The first attempt failed prerequisites only: source-pollution required `bash scripts/sanitize_worktree_paths.sh --write` for `.scrai/codemap_graph_cache.json` and web gates required `web/node_modules`. Captured as `local_ci_fast.failed_prereq.stdout.txt`. After running the sanitizer and `cd web && pnpm install --frozen-lockfile`, the same `local-ci --fast` gate passed with 18 pass, 0 fail, 0 skip.

## Final HEAD Repair

Session 37 reran the Stage 3 gates at `HEAD` `955a9197a9e6b2eea2d072f90c57634b09b09b36` to close the prior audit gap where the active `Command-run HEAD` named transient commit `031ea1099d393fc7e3f94280c5daf8284b3ff88b`.

- PASS exit 0: `cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::`
  - Raw log: `final_head_tenant_isolation_proptest.stdout.txt`.
  - Result includes all six tenant-isolation proptest module tests passing, including `tenant_isolation_proptest_route_family` and `tenant_isolation_proptest_deliberate_leaky_variant_trips_failure_signature`.
- PASS exit 0: `cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::tenant_isolation_proptest_deliberate_leaky_variant_trips_failure_signature -- --exact --nocapture`
  - Raw log: `final_head_tenant_isolation_deliberate_leaky.stdout.txt`.
  - Output contains the intended denial signature: `bob-foreign-shared-helper-on-alice-index: foreign tenant should be denied`.
  - Output does not contain the old `proxy body mismatch` / `attributesForFaceting` mismatch failure.
- PASS exit 0: `cd infra && cargo clippy -p api`
  - Raw log: `final_head_cargo_clippy_api.stdout.txt`.
- PASS exit 0: `bash scripts/local-ci.sh --fast`
  - Raw log: `final_head_local_ci_fast.stdout.txt`.
  - Summary: 18 pass, 0 fail, 0 skip.

## Regression Replay Artifact

Copied snapshot: `tenant_isolation_proptest_regression_artifact.txt`.

Replay proof details from `infra/api/tests/proptest-regressions/tenant_isolation_proptest.txt:1-17`:

- Regression artifact path: `tests/proptest-regressions/tenant_isolation_proptest.txt`.
- Proof markers: `LEAK_PROOF_SHARED_GATE_BYPASS`, `LEAK_PROOF_FAILURE_SIGNATURE`, `REPLAY_PROOF_SAVED_CASE_FIRST`, `REPLAY_PROOF_COMMAND`.
- Replay command marker: `cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest_route_family -- --nocapture`.
- Committed saved seed: `fb8c5f90c4f59e9301787d55bd01317b574391ffd0ff1ee70d0e7b252bf98385`.
- Reruns did not append fresh temporary `cc ... settings_update` lines; the committed regression artifact stayed clean.

## Stage 4 Input

This bundle is the handoff input for Stage 4 nightly verification. At final command-run HEAD `955a9197a9e6b2eea2d072f90c57634b09b09b36`, both named tenant-isolation tests passed, the deliberate-leaky path still trips the intended denial signature, `cargo clippy -p api` passed, and `bash scripts/local-ci.sh --fast` passed.

## Stage 4 Post-Landing Nightly Verdict

Nightly owner: `.github/workflows/nightly.yml:39-64`. Baseline owner references: `ROADMAP.md:56,73` and the 2026-07-09 failing staging run `29012587136`.

Landing and sync boundary:

- Landed dev merge commit: `2aea45e06eeb590aa47c742e3be970c01c25792d`.
- Stage 3 final local proof commit recorded above: `955a9197a9e6b2eea2d072f90c57634b09b09b36`.
- Staging mirror sync commit containing the fix: `a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1`, created 2026-07-09T19:35:40Z.
- Mirror file proof: `infra/api/tests/integration/tenant_isolation_proptest.rs` at staging `a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1` contains the corrected `expected_proxy_body` with `attributesForFaceting`.

Run history sidecar: `nightly_post_landing_run_list.json`.

- Selected first qualifying post-sync `nightly.yml` run: databaseId `29044920073`, created 2026-07-09T19:36:03Z, URL `https://github.com/gridl-infra-staging/fjcloud/actions/runs/29044920073`, event `workflow_dispatch`, `headSha` `a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1`.
- Immediately previous inspected nightly entry: databaseId `29012587136`, created 2026-07-09T10:44:29Z, URL `https://github.com/gridl-infra-staging/fjcloud/actions/runs/29012587136`, event `workflow_dispatch`, `headSha` `8f6aa59f2b2a5fd29816ae1ca23e1f288a91a5ac`, conclusion `failure`.
- Why the selected entry qualifies: it is the first visible `nightly.yml` run created after the 2026-07-09T19:35:40Z staging sync to `a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1`.
- Why earlier entries do not qualify: the immediately previous run `29012587136` and earlier visible runs predate the staging sync and point at mirror commits that still had the stale tenant-isolation harness expectation.

Job-level proof sidecar: `nightly_post_landing_run_view.json`.

The saved `gh run view` projection records:

```json
{
  "url": "https://github.com/gridl-infra-staging/fjcloud/actions/runs/29044920073",
  "headSha": "a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1",
  "workflowConclusion": "success",
  "tenantIsolationJob": {
    "name": "tenant-isolation-proptest",
    "conclusion": "success"
  }
}
```

Final Stage 4 verdict: PASS. The tenant-isolation lane is closed because the corrected local Stage 3 proof is in this bundle, the fix was landed and synced to staging mirror commit `a2f013b50d9e331aaa9e59c7f9c46042d1f93ab1`, and the first post-sync `nightly.yml` run reports `tenantIsolationJob.name == "tenant-isolation-proptest"` with `tenantIsolationJob.conclusion == "success"`.

## Portability Note

Raw sidecar logs preserve command text, pass/fail output, durations, and exit codes. Ephemeral worktree path prefixes in cargo compile-location lines were scrubbed to repo-relative paths before commit so the evidence bundle remains portable and passes the source-pollution gate.
