# Stage 1 Cold Customer Rerun Preflight

## Purpose
Stage 1 rebaselines current staging and repo state so Stage 2 CLI and Stage 3 browser reruns reuse fresh evidence instead of the stale June 4 deploy-lag decision tree.

## Out of Scope
- Stage 1 does not execute `scripts/canary/contracts/cold_customer_journey_walkthrough.sh`.
- Stage 1 does not execute `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts`.
- No new probe family.
- No Search Preview shell probe.
- No metrics-probe substitution for F3.
- No edits to `PRIORITIES.md` or `ROADMAP.md`.
- No F9 per-tab coverage expansion.
- No source-code fixes unless a Stage 1 validation command itself reveals an in-scope checklist/evidence defect.

## Repo Context
- Repo path: `fjcloud_dev`
- Current branch before fetch: `batman/jun04_pm_12_cold_customer_rerun_and_f3_closure`
- Evidence root: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun`
- CLI evidence directory for later stages: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/cli`
- Browser evidence directory for later stages: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/browser`

## Grouped Owner Read
Read current owner and prior-evidence files before interpreting probe output with this grouped command:

```bash
cat docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/findings.md docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/preflight.md docs/runbooks/evidence/cold-customer-audit/20260604T172314Z/preflight.md scripts/canary/contracts/cold_customer_journey_walkthrough.sh scripts/tests/cold_customer_journey_walkthrough_test.sh web/playwright.config.contract.ts web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts web/tests/fixtures/search-preview-helpers.ts > docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/grouped_owner_read.txt
```

Grouped read artifact: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/grouped_owner_read.txt`.

## Reuse Owners And Anchors
- `scripts/canary/contracts/cold_customer_journey_walkthrough.sh:192-230` owns CLI env/default prep.
- `scripts/canary/contracts/cold_customer_journey_walkthrough.sh:479-508` owns seeded search retry behavior.
- `scripts/tests/cold_customer_journey_walkthrough_test.sh:26-129` owns locked CLI defaults.
- `web/playwright.config.contract.ts:616-633` owns remote-target opt-in.
- `web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts:310-315` owns first-search success.
- `web/tests/fixtures/search-preview-helpers.ts:300-317` owns the 45-second hit wait helper.

## Git Branch Truth

Command: `git fetch origin main --quiet`

Exit: 0

Command outputs after fetch:

```text
$ git rev-parse HEAD
d86bb89254e9e7b54c068e046238fd1f4ae5a077
$ git rev-parse --abbrev-ref HEAD
batman/jun04_pm_12_cold_customer_rerun_and_f3_closure
$ git status --short
?? docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/
$ git rev-parse origin/main
a197985a7c5e53d2bbe899c873a714a2afbfdb1f
```

## Required Git Ancestry Checks

Command: `git merge-base --is-ancestor e940f08f9 origin/main && echo e940f08f9_on_main`

```text
e940f08f9_on_main
```
Exit semantics: `git merge-base --is-ancestor e940f08f9 origin/main` exited `0`; exit 0 means the commit is an ancestor of `origin/main`, exit 1 means it is not, and other exits indicate an error.

Command: `git merge-base --is-ancestor c5ee1b76f origin/main && echo c5ee1b76f_on_main`

```text
c5ee1b76f_on_main
```
Exit semantics: `git merge-base --is-ancestor c5ee1b76f origin/main` exited `0`; exit 0 means the commit is an ancestor of `origin/main`, exit 1 means it is not, and other exits indicate an error.

## Live Staging `/version`

Command: `set -o pipefail; curl -fsS https://api.staging.flapjack.foo/version | tee "$evidence_root/version.json"`

```json
{"build_time":"2026-06-05T02:48:29Z","dev_sha":"cebdda3a5cbac35e7adb254da739e76cc96f2192","mirror_sha":"88be4aa7c7701462e7f4c6df6d37710c1141f8d2","synced_at":"2026-06-05T02:45:04Z"}
```
Exit: 0

Parsed fields:

```text
dev_sha=cebdda3a5cbac35e7adb254da739e76cc96f2192
mirror_sha=88be4aa7c7701462e7f4c6df6d37710c1141f8d2
synced_at=2026-06-05T02:45:04Z
build_time=2026-06-05T02:48:29Z
```

## Canonical Findings Guard

Command: `findings_before_hash="$(shasum docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/findings.md | awk '{print $1}')"`

- Guarded file: `docs/runbooks/evidence/cold-customer-audit/20260604T084633Z/findings.md`
- findings_before_hash: `35f22b61cfa0ad2e0e253d0f06572f0bfe3e1a8c`

## Local CI Fast Baseline

Validation cache check: `validation_cache.check('/Users/stuart/.matt/projects/fjcloud_dev-6e1bbfd7/jun04_pm_12_cold_customer_rerun_and_f3_closure.md-9bc7203c', 'bash scripts/local-ci.sh --fast', 'd86bb89254e9e7b54c068e046238fd1f4ae5a077', False)`.

Cache result: miss; running the command because only clean-tree current-HEAD PASS entries are valid hits.

Command: `set -o pipefail; bash scripts/local-ci.sh --fast 2>&1 | tee "$evidence_root/local_ci_fast.log"`

Exit: `1`

Log: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/local_ci_fast.log`

Tail summary:

```text

=== Results: 11 passed, 0 failed ===
PASS: [canonical-alias-exact-hit] GITHUB_OUTPUT contains ready=true
FAIL: [canonical-alias-older-commit-skip] GITHUB_OUTPUT missing 'ready=false'; got: ready=true
FAIL: [canonical-alias-older-commit-skip] expected skip warning on stderr; stderr: wait_for_pages_parity: Pages https://cloud.staging.flapjack.foo reached d86bb89254e9e7b54c068e046238fd1f4ae5a077 via canonical_deployment commit 03fcb1dbe741d324aeca6b1393d23ec8b975bbc9 on attempt 1/3
PASS: [latest-differs-canonical-satisfies] GITHUB_OUTPUT contains ready=true
PASS: [canonical-alias-timeout-skip] GITHUB_OUTPUT contains ready=false
PASS: [canonical-alias-timeout-skip] emitted skip warning to stderr
FAIL: [canonical-alias-descendant-hit] GITHUB_OUTPUT missing 'ready=true'; got: ready=false
PASS: [missing-credentials] skip-warns cleanly when Cloudflare auth is absent

=== Results: 5 passed, 3 failed ===

--- script-exec-bits (1s) ---
=== script_exec_bits_test.sh ===

PASS: test scope covers scripts/local_demo.sh
PASS: scripts/dev_state_audit.sh is executable in the worktree
PASS: scripts/cleanup_dev_orphans.sh is executable in the worktree
FAIL: the following top-level scripts/*.sh files are tracked at the wrong git mode (expected 100755):
  - scripts/playwright_local_stack.sh (git mode 100644)
Fix: `chmod +x <path> && git add <path>` for each, then commit.

=== Results: 3 passed, 1 failed ===

--- web-lint (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm install' first

--- web-test (0s) ---
ERROR: web/node_modules missing — run 'cd web && npm install' first

## Prod deploy drift (informational — does not affect exit code)
Prod deploy drift:
  dev_sha:            cebdda3a5cbac35e7adb254da739e76cc96f2192
  build_time:         2026-06-05T02:48:39Z (6h 39m ago)
  commits_behind:     52
  dev_main_sha:       a197985a7c5e

Totals: pass=10 fail=4 skip=0
Result: FAIL

```

## Local CI Fast Baseline Rerun

Validation cache check: `validation_cache.check('/Users/stuart/.matt/projects/fjcloud_dev-6e1bbfd7/jun04_pm_12_cold_customer_rerun_and_f3_closure.md-9bc7203c', 'bash scripts/local-ci.sh --fast', '9223adc0f118c90a4034a5d27a218a56dc344629', False)`.

Cache result: miss; running the command because only clean-tree current-HEAD PASS entries are valid hits.

Command: `set -o pipefail; bash scripts/local-ci.sh --fast 2>&1 | tee "$evidence_root/local_ci_fast.log"`

Exit: `1`

Log: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/local_ci_fast.log`

Tail summary:

```text
    169|   const response = await POST(event as never);
    170| 
    171|   expect(createApiClientMock).toHaveBeenCalledWith('session-jwt');
       |                               ^
    172|   expect(getIndexMock).toHaveBeenCalledWith('products');
    173|   expect(testSearchMock).not.toHaveBeenCalled();

⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[1/2]⎯

 FAIL  src/routes/api/search/[name]/search.server.test.ts > POST /api/search/[name] > resolves the target endpoint from route params, not request body
AssertionError: expected "vi.fn()" to be called with arguments: [ 'products' ]

Number of calls: 0

 ❯ src/routes/api/search/[name]/search.server.test.ts:208:24
    206|   await POST(event as never);
    207| 
    208|   expect(getIndexMock).toHaveBeenCalledWith('products');
       |                        ^
    209|   expect(globalThis.fetch).toHaveBeenCalledWith(
    210|    'http://vm-shared-f2b9c8a6.flapjack.foo:7700/1/indexes/*/queries',

⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯⎯[2/2]⎯


 Test Files  1 failed | 176 passed (177)
      Tests  2 failed | 2358 passed (2360)
   Start at  05:30:09
   Duration  20.31s (transform 34.48s, setup 14.51s, import 83.11s, tests 89.72s, environment 124.14s)


## Prod deploy drift (informational — does not affect exit code)
Prod deploy drift:
  dev_sha:            cebdda3a5cbac35e7adb254da739e76cc96f2192
  build_time:         2026-06-05T02:48:39Z (6h 43m ago)
  commits_behind:     52
  dev_main_sha:       a197985a7c5e

Totals: pass=13 fail=1 skip=0
Result: FAIL

```

## Local CI Fast Baseline Final Rerun

Validation cache check: `validation_cache.check('/Users/stuart/.matt/projects/fjcloud_dev-6e1bbfd7/jun04_pm_12_cold_customer_rerun_and_f3_closure.md-9bc7203c', 'bash scripts/local-ci.sh --fast', '19a3aa264c9ef8b87fd086ba74443d9949d18e3e', False)`.

Cache result: miss; running the command because only clean-tree current-HEAD PASS entries are valid hits.

Command: `set -o pipefail; bash scripts/local-ci.sh --fast 2>&1 | tee "$evidence_root/local_ci_fast.log"`

Exit: `0`

Log: `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/local_ci_fast.log`

Tail summary:

```text
Running 14 gate(s): check-sizes script-exec-bits port-collision-diagnose compose-project status-doc-consistency secret-scan web-lint web-test index-export-clientside-contract rust-lint migration-test validate-bootstrap-parser validate-bootstrap-env-local publish-scripts-buildx
Mode: fast


=== local-ci summary (wall 37s) ===
GATE                STATUS   SECS  LOG
----                ------   ----  ---
check-sizes         PASS        5  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/check-sizes.log
compose-project     PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/compose-project.log
index-export-clientside-contract  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/index-export-clientside-contract.log
migration-test      PASS        1  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/migration-test.log
port-collision-diagnose  PASS        3  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/port-collision-diagnose.log
publish-scripts-buildx  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/publish-scripts-buildx.log
rust-lint           PASS       22  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/rust-lint.log
script-exec-bits    PASS        2  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/script-exec-bits.log
secret-scan         PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/secret-scan.log
status-doc-consistency  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/status-doc-consistency.log
validate-bootstrap-env-local  PASS        4  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/validate-bootstrap-env-local.log
validate-bootstrap-parser  PASS        0  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/validate-bootstrap-parser.log
web-lint            PASS       36  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-lint.log
web-test            PASS       22  /var/folders/v6/b8qh29l57ql_p7hdw2qhpqkw0000gn/T//local-ci-last-logs/web-test.log

## Prod deploy drift (informational — does not affect exit code)
Prod deploy drift:
  dev_sha:            cebdda3a5cbac35e7adb254da739e76cc96f2192
  build_time:         2026-06-05T02:48:39Z (6h 45m ago)
  commits_behind:     52
  dev_main_sha:       a197985a7c5e

Totals: pass=14 fail=0 skip=0
Result: PASS

```

## Validation Defects Fixed During Baseline

The first baseline run failed on repo-owned fast-gate defects rather than staging reachability:

- `scripts/playwright_local_stack.sh` was tracked at git mode `100644`, while `scripts/tests/script_exec_bits_test.sh:35-64` requires top-level `scripts/*.sh` files to be tracked at `100755`. Fixed in commit `9223adc0f`.
- `scripts/tests/e2e_deployed_pages_parity_probe_test.sh:220-238` expected the inverse of `scripts/launch/wait_for_pages_parity.sh:200-204`, which says browser parity is satisfied by the target commit or a locally provable ancestor. Fixed in commit `9223adc0f`.
- `web/src/routes/api/search/[name]/search.server.test.ts:137-214` still expected mismatched batch `indexName` requests to proceed, while `web/src/routes/api/search/[name]/+server.ts:167-168` rejects body index names that differ from the route param. Fixed in commit `19a3aa264`.
- `web/node_modules` was missing for local web gates; `cd web && npm install` restored the local dependency tree. No package files changed.

Focused validation run before the final baseline:

```text
$ cd web && npm test -- src/routes/api/search/[name]/search.server.test.ts
src/routes/api/search/[name]/search.server.test.ts: 15 tests passed
```

## Final Repo State After Baseline Fixes

These facts were captured after the final green baseline so later stages do not treat the initial branch-truth snapshot as the final branch state.

```text
$ git rev-parse HEAD
19a3aa264c9ef8b87fd086ba74443d9949d18e3e
$ git rev-parse --abbrev-ref HEAD
batman/jun04_pm_12_cold_customer_rerun_and_f3_closure
$ git status --short
?? docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/
$ git rev-parse @{u}
19a3aa264c9ef8b87fd086ba74443d9949d18e3e
```

Live staging remains the `/version` identity captured above; this branch HEAD is local repo state for the preflight fixes and is not itself a staging deploy proof.

## Stage 2 And Stage 3 Handoff Commands

Reuse this evidence root exactly; do not create a second root for the rerun.

Stage 2 CLI command:

```bash
evidence_root="docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun"
bash scripts/canary/contracts/cold_customer_journey_walkthrough.sh --env staging --env-file /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret --evidence-dir "$evidence_root/cli"
```

Stage 3 browser setup command:

```bash
evidence_root="docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun"
source <(bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging)
PLAYWRIGHT_TARGET_REMOTE=1 \
BASE_URL=https://cloud.staging.flapjack.foo \
API_URL=https://api.staging.flapjack.foo \
API_BASE_URL=https://api.staging.flapjack.foo \
E2E_ADMIN_KEY="$ADMIN_KEY" \
EVIDENCE_ROOT="$evidence_root/browser" \
npx playwright test -c web/playwright.config.contract.ts web/tests/e2e-ui/full/cold_customer_algolia_refugee_journey.spec.ts
```

## Open Questions

None for Stage 1. Stage 2 and Stage 3 should interpret their reruns against the live staging `/version` JSON captured in `docs/runbooks/evidence/cold-customer-audit/20260605T092601Z_rerun/version.json`, not against stale June 4 prose.
