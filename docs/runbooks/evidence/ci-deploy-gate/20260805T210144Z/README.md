# CI deploy-gate closeout receipt — lane `aug05_2pm_1_staging_ci_three_reds_repair`

- **Receipt UTC:** 20260805T210144Z
- **Lane branch / HEAD:** original receipt authored at `batman/aug05_2pm_1_staging_ci_three_reds_repair` @ `b1d5acb7d9311010abdf046ebb0dca4777082f59`; Stage 5 verification rerun on 2026-08-06 used synced lane HEAD `dbdbcd55684ddf1b478407268c145cc8532996a6`.
- **Locality:** AWS EC2 Linux devbox `fjcloud-devbox-fri` (`i-0d0e9aaa87c7a4005`, `c7i.4xlarge`, x86_64, 16 vCPU, Ubuntu 24.04), target `/home/ubuntu/fjcloud_dev`. NOT the operator Mac.
- **Scope:** lane-owned repair proof only. The staging-mirror dispatch is deliberately deferred to the post-merge owner (see `OWED AFTER MERGE`) because `debbie sync <target>` stamps the invoking worktree `HEAD`, and this lane worktree is on `batman/<lane>`, not `origin/main`.

## Pre-fix staging-mirror run

Pre-fix staging-mirror push run **`31029541305`** (`gridl-infra-staging/fjcloud`, headSha `535b92832ae91b7a0dbd5591024b843c034ad7d8`, created 2026-08-05T17:20:14Z, conclusion `failure`) — read read-only via `gh run view` in this lane. Its three failed jobs are exactly this lane's three reds; `deploy-staging` / `deploy-prod` / `e2e-deployed` were `skipped`. Full job/step evidence: [`prefix_staging_run_31029541305.txt`](prefix_staging_run_31029541305.txt).

| Job | Pre-fix conclusion | Failing step / signature |
| --- | --- | --- |
| `rust-test` | failure (exit 101) | step#10 `Run rust tests` → `migration_routes_test::verify::verify_seeded_local_source_red_proof` panics at `verify_support.rs:240` `FJCLOUD_ALGOLIA_SOURCE_BASE_URL … NotPresent`; `1678 passed; 1 failed` |
| `web-test` | failure | step#4 `Run web tests` |
| `local-dev-up-smoke` | failure | step#10 `Run full local demo stack` |
| all other prereqs (`rust-lint`, `migration-test`, `check-sizes`, `secret-scan`, `shell-hygiene`, `web-lint`) | success | — |
| `deploy-staging`, `deploy-prod`, `e2e-deployed` | skipped | blocked by the three reds |

## The three original failures — Linux reproduction, fix, mutation

### 1. rust-test — `verify_seeded_local_source_red_proof` panic
- **Reproduction (Stage 1, Linux + macOS):** with `FJCLOUD_ALGOLIA_SOURCE_BASE_URL`/`FLAPJACK_ADMIN_KEY` unset the test panics `NotPresent` at `verify_support.rs:240` — the exact staging signature. Env-driven, not platform-specific.
- **Fix (`e63cecc04`, `Repair rust-test seeded Flapjack contract`):** `.github/workflows/ci.yml` `rust-test` job now downloads the pinned public musl Flapjack, verifies its SHA256, starts an isolated engine on `127.0.0.1:7700`, exports `FLAPJACK_ADMIN_KEY` + `FJCLOUD_ALGOLIA_SOURCE_BASE_URL`, and always tears down the recorded PID. `scripts/tests/ci_workflow_test.sh` (owned guard) gained 24 assertions pinning that contract. No Rust proof/fixture changed.
- **Owned proof:** `bash scripts/tests/ci_workflow_test.sh` (guard) + focused positive `cargo test -p api --test platform verify_seeded_local_source_red_proof` under the supplied Flapjack env.
- **Repaired job shape passes:** see [`reproof_rust_test.txt`](reproof_rust_test.txt).
- **Mutation:** revert only the ci.yml Flapjack-contract hunk → guard goes red on the 24 pinned assertions → restore → green. See [`mutation_checks.txt`](mutation_checks.txt).

### 2. web-test — migration eligibility effect cycle
- **Reproduction (Stage 1/3):** the raw depth-limit trip (`effect_update_depth_exceeded`) is scheduling/locality-specific to the GitHub ubuntu-latest runner; the confirmed latent pointer is the `derived_inert` warnings from `MigrationAdmission.test.ts`. Stage 3 made it deterministically red by tightening the admission scenario with a strictly advancing clock.
- **Fix (`5e2a394c8`, `Fix migration eligibility effect cycle`):** `MigrationCreateFlow.svelte` imports `untrack` and wraps the `eligibilityNowMillis` read inside `updateEligibilityClock` in `untrack(() => …)`, removing the accidental reactive self-dependency while keeping the monotonic guard.
- **Owned proof:** focused `MigrationAdmission.test.ts` (`vitest run`) — infinite-update symptom absent.
- **Result:** see [`reproof_web_test.txt`](reproof_web_test.txt).
- **Mutation:** revert only the `untrack` wrap → the tightened test deterministically fails `effect_update_depth_exceeded` at `updateEligibilityClock` → restore → green. See [`mutation_checks.txt`](mutation_checks.txt).

### 3. local-dev-up-smoke — API database port inheritance
- **Reproduction (Stage 1/4):** on the fast devbox the 90s `/health` window is met in <1s, so the raw red is GitHub-runner-slow-window-specific. Stage 4 reproduced the underlying defect on this devbox with the full CI-shaped path: pre-fix `.local/api.log` recorded `Error: pool timed out while waiting for an open connection` and API unhealthy for 90s, because `local-dev-up.sh` rewrote `DATABASE_URL` to the worktree port inside a child shell that did not survive into `api-dev.sh`, which then used `.env.local`'s stale `:5432`.
- **Fix (`39d958d30`, `Fix local demo API database port inheritance`):** `scripts/local_demo.sh` sources `lib/db_url.sh` + `lib/playwright_port_plan.sh` and calls `playwright_apply_manual_stack_port_defaults` in the parent shell (before `local-dev-up.sh` and `api-dev.sh`) so the rewritten `DATABASE_URL` survives.
- **Owned proof:** `bash scripts/tests/local_demo_test.sh::test_api_start_inherits_rewritten_local_stack_database_url`; plus a full `bash scripts/local_demo.sh` post-fix run showing the API reaches healthy.
- **Result:** see [`reproof_local_dev_up_smoke.txt`](reproof_local_dev_up_smoke.txt).
- **Mutation:** remove only the `playwright_apply_manual_stack_port_defaults` call → `local_demo_test.sh` red → restore → green. See [`mutation_checks.txt`](mutation_checks.txt).

## Final Linux `bash scripts/local-ci.sh --full`

- **Command / locality:** `bash scripts/local-ci.sh --full` on the Linux devbox above, invoked through `/home/ubuntu/run_fullci.sh` at synced lane HEAD `dbdbcd55684ddf1b478407268c145cc8532996a6`. The wrapper supplied `sqlx-cli 0.8.6` and a live Flapjack `1.0.10` on `127.0.0.1:7700` with `FLAPJACK_ADMIN_KEY` + `FJCLOUD_ALGOLIA_SOURCE_BASE_URL` exported. The rerun also exposed devbox-prerequisite defects: the first source sync left `/home/ubuntu/fjcloud_dev/.git` invalid, the standalone `postgres:16` service on `127.0.0.1:5432` was stopped, and several non-deploy-prerequisite local-ci gates require tools or local secret/config state absent from this no-credentials devbox (`cargo-audit`, `terraform`, `sips`, `.secret/.env.secret`, per-clone DIRMAP merge-driver config).
- **Full transcript:** [`local_ci_full_linux.txt`](local_ci_full_linux.txt).
- **Result:** **FAIL** (`LOCAL_CI_EXIT=1`, wall 683s, totals `pass=31 fail=13 skip=1`). This does **not** close the Stage 5 full-gate item. The transcript records `web-test PASS 143s`, but `migration-test SKIP` because Postgres was not reachable at `127.0.0.1:5432`, `rust-test FAIL` with `PoolTimedOut` against the integration DB, and multiple setup/tooling failures tied to the devbox checkout or tool inventory. After diagnosis, the devbox Git metadata was rebuilt from a bundle at `dbdbcd55684ddf1b478407268c145cc8532996a6`, the DIRMAP merge driver was registered, and the `fjci-pg` Postgres service was started; the three original failure owners were then re-proved independently in the linked transcripts above. See the architectural determination below for why a full `--full` exit-0 cannot be produced on this devbox.

## Architectural determination — `--full` exit-0 is unsatisfiable on the credentials-free reproduction devbox

2026-08-06 (session s34). Root-cause classification of all 13 `--full` gate FAILs. **None is a regression from this lane's fixes.** The lane diff (`git diff --name-only origin/main...HEAD`) touches only `.github/workflows/ci.yml`, `scripts/local_demo.sh`, `web/src/lib/components/migration/MigrationCreateFlow.svelte` and their tests plus this receipt/chat evidence — **no Rust source, no `Cargo.*`**. The 13 FAILs trace entirely to the devbox being a *credentials-free, git-object-stripped, minimally-provisioned* reproduction box, which is exactly what its owner scripts build it to be:

| Root cause (owner-script evidence) | Failing gates |
| --- | --- |
| **Invalid `.git` — `scripts/devbox/sync_to_devbox.sh:89` `--exclude=.git/objects`.** rsync ships `.git/HEAD`/`refs`/`index` but no object store, so every git-backed gate errors (`fatal: not a git repository / bad object`). This is open bug `devbox-sync-leaves-invalid-git-metadata`. | `mirror-sync-contract`, `dirmap-merge-driver`, `source-pollution`, `script-exec-bits`, `secret-scan` (scans **tracked files** via `_git_tracked_secret_matches`, `scripts/reliability/lib/security_checks.sh:232`), `flapjack-ami-pointer-contract`, and the informational prod-drift probe |
| **Postgres down at `127.0.0.1:5432`** (standalone `postgres:16` service stopped between sync and run). | `rust-test` (`PoolTimedOut`), `migration-test` (SKIP), `local-multinode-migration-contract`, `local-schema-drift-contract`, `test-reachability-contract` |
| **`cargo-audit` not installed** — `provision_devbox.sh:15` provisions "postgres + docker + the flapjack binary and nothing" else; `check_dep_audit` documents `SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING` as a **hard FAIL** when the tool is absent (`security_checks.sh:41-44,350`). | `dep-audit` |
| **`.secret/.env.secret` absent by design** — `sync_to_devbox.sh:67-68` `--exclude=.secret --exclude=.env.secret`. The gate hard-fails `FAIL_NO_SECRETS: ./.secret/.env.secret not found`. | `usage-rollup-freshness-contract` |
| **`rust-lint`** — 60s FAIL; the lane changes no Rust, so this is not a lane regression (devbox toolchain/clippy-config state). | `rust-lint` |

**Why exit-0 is unreachable here, and why that is correct:** getting `--full` to exit 0 would require putting the live-AWS-credential file `.secret/.env.secret` onto the devbox — which its sync deliberately excludes and which this session will **not** do, because the reproduction devbox is credentials-free by security design and copying live IAM keys onto an ephemeral EC2 box is a prohibited, hard-to-reverse action. The `.git`-object and `cargo-audit` gaps are repo-owned (owner: `scripts/devbox/*`) and could be closed, but they are **necessary-but-insufficient**: even with valid `.git` + Postgres + `cargo-audit`, the credentials gate keeps exit code non-zero. `local-ci.sh --full` is a *fully-provisioned developer-machine* gate; the reproduction devbox is not that machine.

**Authoritative substitute (already scheduled):** the fully-provisioned Linux equivalent of `--full` for the nine `deploy-staging` prerequisites is the **staging-mirror CI run** (`ubuntu-24.04-arm`, secrets present), which is correctly deferred to the post-merge owner in `OWED AFTER MERGE`. Of the nine prerequisites, `web-test` / `check-sizes` / `web-lint` are already `PASS` in the transcript above, and `rust-test` / `web-test` (loop) / `local-dev-up-smoke` are independently Linux-reproved + mutation-checked in the linked artifacts. The remaining prerequisite green (`secret-scan`, `migration-test`, `rust-lint`, `shell-hygiene`) is owed to staging CI, not to this credentials-free box.

## OWED AFTER MERGE

The following cannot be produced correctly from this lane worktree and are **not yet recorded**; they are owed by the post-merge supervisor owner after `origin/main` carries these fixes:

- the **post-fix staging-mirror run id**;
- the **nine `deploy-staging` prerequisite job conclusions** on that run;
- the **`deploy-staging` conclusion** (it must actually run, not skip);
- downstream **`e2e-deployed`** conclusion;
- live **`GET https://api.staging.flapjack.foo/version` ancestry proof** (returned `dev_sha` is an ancestor of `main`);
- **`bash scripts/probe_mirror_ci_currency.sh`** output.

**Instruction to the post-merge owner:** run `debbie sync staging` **only** from a worktree whose `HEAD` is the pushed `origin/main` SHA (never from a `batman/<lane>` worktree — the sync stamps `git rev-parse HEAD` of the invoking root). Then match the staging run's `headSha` to that pushed SHA before trusting any `gh run view` conclusion for it.

**If `deploy-staging` later runs and fails:** classify it as a **new finding beyond this lane's three original reds**. It will be the first time `deploy-staging` has executed since 2026-07-30, so a failure there is not a regression of this lane's repair.

## ROADMAP CORRECTION REQUIRED

_(Recorded here only; `ROADMAP.md` is intentionally NOT edited by this lane.)_

The current `ROADMAP.md` **Active → Platform Ledger** P0 row titled **“The staging mirror CI deploy gate has been red since 2026-08-01, so nothing has deployed since 2026-07-30”** (OPEN, new 2026-08-05) needs a correction and a discharge note:

- **Its account of *why* the gate is red is now stale.** That row (written 2026-08-05 ~06:00Z) attributes the red to the `rust-test` job timing out `exit code 124` on a hang in `admin_vms_test::decommission_endpoint_reports_blockers_when_reference_publication_wins` / `…_wins_concurrent_reference_publication_after_inventory_lock`. The **newest** staging-mirror push run, `31029541305` (2026-08-05T17:20Z, headSha `535b928`), fails `rust-test` with a **different** signature — **exit 101**, `verify_seeded_local_source_red_proof` panic (`FJCLOUD_ALGOLIA_SOURCE_BASE_URL … NotPresent`) — with the `auth_admin` binary reporting `346 passed; 0 failed`, i.e. the decommission hang did **not** recur. The active blocker in the newest run is this lane's three reds (rust-test seeded-source panic **+** web-test **+** local-dev-up-smoke), not the exit-124 decommission hang.
- **Exit clauses this lane discharged:** the P0 row's four exit clauses are (1) the two named decommission tests green / defect fixed at owner, (2) one staging-mirror push run completes with `deploy-staging` succeeding, (3) live `/version` returns a `dev_sha` ancestral to `main`, (4) a repo-owned probe fails when the newest staging-mirror run did not conclude `success`. **This lane discharges none of the four literally.** It repairs the three reds that actually block the newest staging-mirror run `31029541305`, which is the necessary precondition for clause (2): `deploy-staging` cannot run until `rust-test` + `web-test` + `local-dev-up-smoke` pass. Clauses (2)/(3)/(4) are owed post-merge (see `OWED AFTER MERGE`); clause (1) is a separate defect this lane did not touch, and the newest run's evidence shows that test class currently passing.

## `debbie sync staging` ledger

- **Intentional dispatch from this lane worktree: NONE.** This lane did not run `debbie sync staging`.
- **Prior accidental lane-stamped dispatch (session s23, review):** on 2026-08-05T20:20:01Z a review-session shell backtick expanded ``debbie sync staging`` before it was interrupted. Impact: `/Users/stuart/repos/gridl-infra-staging/fjcloud/.debbie/sync_manifest.json` stamped `dev_sha=b1d5acb7d9311010abdf046ebb0dca4777082f59` (this lane's `batman/<lane>` HEAD, **not** `origin/main`), `synced_at=2026-08-05T20:20:01Z`; the staging mirror local `main` HEAD stayed `535b92832…` and the mirror is only **locally dirty** — **no push occurred and no staging-mirror CI run was triggered** by it. This is **not valid staging proof**: it stamps a lane SHA and never reached the remote. The separate shared staging-mirror repo was intentionally left untouched (cleanup could destroy unrelated co-resident work).
