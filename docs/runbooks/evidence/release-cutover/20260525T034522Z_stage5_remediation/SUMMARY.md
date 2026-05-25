# Stage 5 Remediation Summary

- Bundle: `docs/runbooks/evidence/release-cutover/20260525T034522Z_stage5_remediation/`
- Captured (UTC): 2026-05-25T03:45:22Z
- Verdict: **NOT-RECOVERED-YET** (fix built + pushed; prod not yet converged, recovery probes deferred to post-deploy)

## Code remediation (committed + pushed on branch `batman/may21_12pm_6_release_cutover`)

- `27bbabb6` — `test(api): deflake admin_rate_limit_sets_retry_after_header`
- `694e4b8d` — `fix(api): retry transient proxy failures on existing shared VMs during index create`

### Root cause of the soak NOT-GREEN (`create_index` 503)

`infra/api/src/routes/indexes/shared_vm.rs::create_shared_vm_index_with_warmup_retry`
hardcoded `attempts = 1` for existing (non-just-provisioned) shared VMs and gated
both transient-error retry arms on `just_provisioned`. A single transient
`ProxyError::Unreachable`/`Timeout` on an already-active VM therefore fell straight
to `Err(error) => return` → `ServiceUnavailable("backend temporarily unavailable")`
→ HTTP 503. That is the exact failure terminus recorded in
`../20260525T025913Z_soak/SUMMARY.md` (item 2).

### Fix

Existing active VMs now get a small fast-retry budget
(`EXISTING_SHARED_VM_CREATE_RETRY_ATTEMPTS = 3`, `..._INTERVAL = 500ms`), distinct
from the cold-boot warmup window (20 × 3s). Both paths retry the same transient
errors; only the budget differs. A persistent outage (budget exhausted) still
surfaces a 503. Regression tests in `infra/api/tests/indexes_test.rs`:
- `create_existing_shared_vm_retries_transient_unreachable_then_succeeds` (transient → 201, 2 requests; red against old code)
- `create_existing_shared_vm_persistent_unreachable_returns_503_after_retries` (budget exhausted → 503, 3 requests; reconciled from the old buggy `..._without_retry` test that locked in the defect)

Targeted validation: `cargo test -p api --test indexes_test create_` → 33 passed / 0 failed;
full `indexes_test` → 142 passed / 0 failed; `cargo fmt --check` clean; `cargo clippy -p api --tests` no new warnings.

### Deploy-pipeline unblock (prerequisite, discovered via pre-flight)

Staging mirror CI run `26376378644` (sha `cf45002e`) was **failing** on `rust-test`
(`admin_rate_limit_sets_retry_after_header` got 200 not 429), which **skipped**
`deploy-staging`/`deploy-prod` — every dev→staging→prod push was dead-ending and
never reaching prod. Root cause: that test keyed the admin rate limit on the
`x-forwarded-for` IP (trusted only when `TRUST_PROXY_HEADERS_FOR_RATE_LIMIT` is set)
but was the lone rate-limit test not holding `security_env_lock()`; a concurrent
lock-holding test's `EnvVarGuard` flipped that process-global env between the test's
two requests, scattering them into different rate-limit buckets. Fixed by acquiring
the shared env lock like its siblings. `security_test` binary: 5/5 consecutive full
runs green.

## Recovery gates (per Stage 5 maintenance parent)

| Gate | Status | Evidence |
|---|---|---|
| Commit convergence (prod `dev_sha` == fix HEAD `27bbabb6`) | **FAIL** | `commit_convergence.txt` — prod `dev_sha=34063abb`; fix is on the feature branch, not merged to `main` / synced / deployed. |
| Prod customer-loop canary exit 0 + success marker | **DEFERRED** (gated on convergence) | `canary_baseline_preDeploy.log` — baseline against **un-fixed** prod, NOT recovery proof. |
| CloudWatch `fjcloud-prod-customer-loop-canary-lambda-errors` not in ALARM | **OK now, but not proof** | `alarm_probe.txt` — alarm `OK` (cleared 2026-05-25T03:43:38-04:00, i.e. the transient passed); defect still live in deployed prod. |

### Concrete failing terminus + next owner seam

- **Failing terminus:** commit convergence — `https://api.flapjack.foo/version` reports
  `dev_sha=34063abb`, not the fix HEAD `27bbabb6`. The fix is committed and pushed on
  `batman/may21_12pm_6_release_cutover` but has not reached `main` → debbie sync →
  mirror CI → prod deploy.
- **Next owner seam (deploy):** merge `batman/may21_12pm_6_release_cutover` to `main`
  (orchestrator/clean-review-owned), let debbie sync to `gridl-infra-staging/fjcloud`
  and `gridl-infra-prod/fjcloud`, confirm mirror CI is green now that `rust-test` is
  deflaked, then re-run convergence + canary + alarm gates against prod.

### Notes on the baseline canary

The pre-deploy baseline canary (`canary_baseline_preDeploy.log`) shows `create_index`
**succeeding** (the soak's transient 503 was not occurring at probe time, matching the
alarm being `OK`). It then failed at the later `admin_cleanup` step with HTTP 401 — a
**local admin-credential** artifact of running the script from a workstation against
prod, not the Stage 5 create_index defect and not a prod-side failure. The production
cron canary runs as a Lambda with SSM-sourced admin creds and is unaffected. A
synthetic test customer (`6fcc1b54-6460-4a1a-a9ae-ed3d239211ca`) may be left partially
cleaned by this one-off run; the cron canary's own cleanup handles such rows.

## Handoff

Stage 4 must be **re-run in a fresh soak bundle** (not this remediation bundle) once the
fix is deployed and prod has converged, before any GREEN-only `LAUNCH.md` / `docs/NOW.md`
flips. No NOW/LAUNCH edits were made in this stage.
