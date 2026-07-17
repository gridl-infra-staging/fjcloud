# Local Load Signoff and Baseline Approval Runbook

## Purpose
This runbook is the single authoritative workflow for Phase 6 local load signoff and local baseline approval.

Machine behavior is defined by these implementation sources of truth:
- `scripts/load/run_load_harness.sh`
- `scripts/load/lib/load_checks.sh`
- `scripts/load/approve-baselines.sh`
- `scripts/tests/load_harness_test.sh`
- `scripts/load/baselines/*.json`

Status capture belongs in `docs/checklists/LOCAL_SIGNOFF_2026-03-24.md`; workflow procedure stays in this runbook.

## Authoritative Local Signoff Path
Use the harness entrypoint for local signoff:

```bash
bash scripts/load/run_load_harness.sh
```

When `LOAD_GATE_LIVE=1`, this executes `run_live_mode()` and then baseline comparison through `run_load_gate()`.
Direct `k6 run` remains supplemental for script-only investigation, but it is not the authoritative local signoff path.

## Load Targets (from LOAD_TARGET_ENDPOINTS)
`LOAD_TARGET_ENDPOINTS` in `scripts/load/lib/load_checks.sh` defines the exact endpoint set:
- `health`
- `search_query`
- `index_create`
- `admin_tenant_list`
- `document_ingestion`

## Prerequisites for Live Signoff
For `LOAD_GATE_LIVE=1`, `ensure_live_env_prereqs()` requires:
- `JWT`
- `INDEX_NAME`
- `ADMIN_KEY`

Optional local setup:
- `LOAD_PREPARE_LOCAL=1` runs `scripts/load/setup-local-prereqs.sh` through `prepare_local_live_env_if_requested()`.

## Harness Execution Contract (`run_live_mode()`)
1. If `k6` is missing: emit structured skip JSON with reason `LOAD_K6_SKIP_TOOL_MISSING` and exit success.
2. If local prep fails: emit `LOAD_LOCAL_PREP_FAILURE` and exit failure.
3. If required live env vars are missing: emit `LOAD_LIVE_ENV_MISSING` and exit failure.
4. Apply the default signoff profile before resolving mode:
   - the authoritative local signoff path uses the `local_fixed` profile by default
   - `local_fixed` sets `LOAD_K6_MODE=fixed` plus local concurrency/duration defaults and the local index-create/list-index threshold overrides used for approved baselines
   - Set `LOAD_K6_MODE=script` (or explicit `LOAD_K6_*` overrides) when you intentionally want script-owned staged execution instead
   - invalid mode emits `LOAD_K6_MODE_INVALID`
5. Resolve mode with `_resolve_k6_mode()`:
   - `fixed` when the profile or explicit env selects fixed mode
   - `script` only when explicitly requested or inherited via explicit env configuration
5. Execute all `LOAD_TARGET_ENDPOINTS` via `run_live_workload_into_dir()`:
   - `script` mode: pass script-owned workload shape to `k6 run`
   - `fixed` mode: append `--vus` and `--duration`
   - non-threshold k6 runtime failure emits `LOAD_K6_RUNTIME_FAILURE`
6. Compare live results with baselines using `run_load_gate()`.

`run_live_workload_into_dir()` also supports resetting local setup between endpoint runs when `LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS=1`.

## Supplemental Direct k6 Runs
Use direct `k6 run` only for script-level troubleshooting or ad-hoc measurement:

```bash
k6 run tests/load/search-query.js
```

This bypasses harness-managed structured gate output and baseline comparison.

## Baseline Comparison Contract (`compare_against_baseline()`)
`compare_against_baseline()` emits structured reason codes and status behavior per endpoint:
- `LOAD_BASELINE_SKIP`: baseline file missing (non-fatal skip)
- `LOAD_BASELINE_PASS`: within allowed regression envelope
- `LOAD_REGRESSION_WARNING`: >20% and <=50% max degradation (non-fatal warning)
- `LOAD_REGRESSION_FAILURE`: error rate >5%, >50% degradation, missing result, or internal comparison error
- `LOAD_K6_THRESHOLD_FAILURE`: result `meta.k6_status` is non-pass (for example `threshold_fail`)

Regression score uses max of latency degradation (`latency_p50_ms`, `latency_p95_ms`, `latency_p99_ms`) and throughput drop (`throughput_rps`).
On already-fast local loopback endpoints, latency drift of `<=50ms` is treated as noise before percentage degradation is applied so explicit k6 SLA passes do not become false regression failures just because the approved baseline was unusually low.

## Approval Workflow (`scripts/load/approve-baselines.sh`)
Run approval with:

```bash
bash scripts/load/approve-baselines.sh
```

Approval defaults:
- `LOAD_PREPARE_LOCAL=1`
- `LOAD_RESET_LOCAL_BETWEEN_ENDPOINTS=1`
- `LOAD_APPROVAL_PROFILE=local_fixed`

Profiles:
- `local_fixed`: sets fixed-mode defaults (`LOAD_K6_MODE=fixed`, local concurrency/duration defaults)
- `staged`: keeps script-owned staged execution unless overridden by explicit `LOAD_K6_*` env vars

Approval refuses to write baselines when any captured result has non-pass `k6_status`.

## Baseline Artifact Contract
Approved baselines are written to `scripts/load/baselines/*.json` and carry `meta.source: "approved_local"`.
Each approved file also includes `approved_at`, `approval_script`, `artifact_dir`, `summary_file`, and preserved k6 metadata (`k6_mode`, `k6_exit_code`, `k6_status`).

As of 2026-03-25, checked-in baselines are approved local artifacts (not seed placeholders).

## Failure Semantics Quick Reference
- Harness precondition/runtime reasons from `run_live_mode()`:
  - `LOAD_K6_SKIP_TOOL_MISSING`
  - `LOAD_LOCAL_PREP_FAILURE`
  - `LOAD_LIVE_ENV_MISSING`
  - `LOAD_K6_MODE_INVALID`
  - `LOAD_K6_RUNTIME_FAILURE`
- Baseline comparison reasons from `compare_against_baseline()`:
  - `LOAD_BASELINE_SKIP`
  - `LOAD_BASELINE_PASS`
  - `LOAD_REGRESSION_WARNING`
  - `LOAD_REGRESSION_FAILURE`
  - `LOAD_K6_THRESHOLD_FAILURE`

Treat these reason codes as the contract for local signoff diagnostics.
