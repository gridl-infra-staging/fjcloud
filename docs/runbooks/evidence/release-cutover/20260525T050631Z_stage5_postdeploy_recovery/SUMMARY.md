# Stage 5 Post-Deploy Recovery Evidence — 20260525T050631Z

Run after prod converged to fix HEAD `568ef287d`. **Verdict: NOT RECOVERED — create_index 503 reproduced on deployed fix.**

## Gate results

| Gate | Result | Terminus |
|---|---|---|
| Commit convergence | **PASS** | prod `/version` dev_sha = `568ef287ddff…` = dev `main` HEAD. Prod mirror CI run 26382917893 conclusion=success @05:06:08Z. See `commit_convergence.txt`. |
| Prod canary (`customer_loop_synthetic.sh`) | **FAIL** | `create_index` returned HTTP 503 `{"error":"backend temporarily unavailable"}` on the deployed fix. No `customer loop canary completed successfully` marker. See `canary_postDeploy.log`. |
| CloudWatch alarm | NOT RE-PROBED (moot) | Canary gate failed; alarm re-probe deferred — it would not be a valid post-recovery signal while the canary still 503s. |

## Canary runs this session (all against deployed fix `568ef287d`, RC readiness mode)

1. **05:07:23Z** — stale LOCAL `.env.secret` admin key. `create_index` **SUCCEEDED** (full index lifecycle create/write/search/delete passed), then `admin_cleanup` failed HTTP 401.
2. **05:09:11Z** — SSM admin key without hydration sentinel → canary mis-resolved the leading-`/` key as an SSM param path. Bootstrap-only artifact, not a prod signal.
3. **05:09:55Z** — SSM admin key + `CANARY_SSM_HYDRATED=1` (faithful Lambda-bootstrap reproduction). `admin_cleanup` **SUCCEEDED**; `create_index` **FAILED HTTP 503**.

## Verified facts (against the system, not artifacts)

- **admin_cleanup 401 is a confirmed LOCAL-credential artifact, not a prod auth defect.** Deployed prod validates `x-admin-key` against SSM `/fjcloud/prod/admin_key` (sha256 `1fdfd2e6…`). Local `.secret/.env.secret` `ADMIN_KEY` (sha256 `caf3c0eb…`) has drifted from it. The prod cron Lambda canary sources ADMIN_KEY from SSM so it never hits this. Run 3 used the SSM value and admin_cleanup succeeded. **Local-tooling hygiene follow-up:** reconcile `.secret/.env.secret` `ADMIN_KEY` to the SSM value (per secret-rotation-hygiene rule — SSM is SSOT for what deployed API uses).
- **The 503 is intermittent** (run 1 create succeeded; run 3 create failed) — confirming a transient/availability failure mode that the shipped retry budget does not fully cover.

## Concrete failing terminus + next owner seam

- **Failing terminus:** `create_index` → `infra/api/src/routes/indexes/shared_vm.rs::create_shared_vm_index_with_warmup_retry`. The "backend temporarily unavailable" body is produced at `shared_vm.rs:309-310` (loop-exhausted terminal) AND at `shared_vm.rs:305` (`Err(error) => return Err(error.into())`) via `From<ProxyError> for ApiError` at `errors.rs:132-134` (`ProxyError::Unreachable` → `ServiceUnavailable("backend temporarily unavailable")`). Both yield the identical 503 body, so the canary cannot distinguish budget-exhaustion from a final-attempt transient.
- **Why the shipped fix is insufficient:** existing-VM budget is `EXISTING_SHARED_VM_CREATE_RETRY_ATTEMPTS=3` × `EXISTING_SHARED_VM_CREATE_RETRY_INTERVAL=500ms` ≈ 1.5s total. The prod transient evidently outlasts that window at least intermittently.
- **Next owner seam (continuation):** diagnose the live failure mode before bumping numbers — (a) prod shared-VM health (is the selector repeatedly handing out one unhealthy VM with no fallback?), (b) API logs for the 05:09:55Z 503 (`ProxyError::Unreachable` vs `Timeout` vs final-attempt), (c) whether `select_shared_vm_for_new_index` (shared_vm.rs ~120-248) should health-check / fail over to another VM instead of relying solely on a time-based retry. Decide between: widen the existing-VM budget, add VM-health-aware selection/failover, or both. Add the failing-then-passing regression in `infra/api/tests/indexes_test.rs` for whichever mode is confirmed.

## Handoff (Stage 4 gate)

Stage 4 MUST be rerun in a new soak bundle before any GREEN-only `LAUNCH.md`/`docs/NOW.md` flips. **That precondition is NOT met** — the create_index 503 is not eliminated. No NOW/LAUNCH flips. Stage 5 stays OPEN.
