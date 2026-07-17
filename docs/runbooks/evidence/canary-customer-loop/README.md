# Canary customer-loop evidence — bundle dir semantics

**Important:** this directory's `.current_bundle` pointer is NOT a live-health
signal. It's an intentional-snapshot pointer. Reading an aging
`.current_bundle` and concluding "the canary stopped" is a category error.

## Two distinct concerns, two distinct sources of truth

| Concern | Where it lives | When to read it |
|---|---|---|
| **Live canary health right now** | CloudWatch alarms + Lambda Invocations/Errors metrics + recent log streams, queried by [`scripts/probe_canary_live_state.sh`](../../../../scripts/probe_canary_live_state.sh) | Before any launch decision; in B1 pre-flight; whenever the operator needs current-state confidence. |
| **Captured snapshot evidence** | This directory's timestamped subdirectories; `.current_bundle` pointer | When B1 or a wave-merge lane wants to commit a frozen-in-time record of "the canary was demonstrably healthy at SHA X" alongside other launch-rc evidence. |

The two concerns separate cleanly because:

- Live state changes every 15 minutes (the canary's invocation cadence).
  Committing every successful run to the repo would write ~96 bundles/day.
  Bundles are intentionally rare.
- Live state can change adversely between bundle captures — a fresh
  `.current_bundle` from an hour ago does not prove the canary is healthy
  right now. Only a live CloudWatch query can prove that.

## How to verify canary health right now

```bash
set -a; source .secret/.env.secret; set +a   # AWS_* creds
bash scripts/probe_canary_live_state.sh prod         # human-readable
bash scripts/probe_canary_live_state.sh prod --json  # B1 pre-flight format
```

The probe asserts five conditions and exits 0 only if all pass:

1. EventBridge rule is ENABLED (not paused by drift)
2. Lambda Invocations sum over last 24h > 0 (canary is firing)
3. Lambda Errors sum over last 24h == 0 (canary is succeeding at the runtime level)
4. All CloudWatch alarms with "canary" in their name are in OK state
5. Last invocation's log stream contains the canary's "completed successfully" marker

These five together cover the failure modes that have actually bitten this
project: terraform drift disabling the schedule (fleet-rot 2026-05-17),
silent app-layer regressions where Lambda exits 0 but the canary's
assertions never ran, and alarm suppression masking ongoing errors.

## When to capture a bundle to this directory

Capture a fresh `<TS>_<context>` bundle here when:

- B1 runs a final launch gate and needs a frozen evidence record alongside
  the orchestrator's `summary.json`.
- A wave merges that touched the canary code path or its IAM/lifecycle
  surface, and the operator wants a "before vs. after" comparison.
- The operator manually drives the canary outside the EventBridge schedule
  (e.g. via the synchronous Lambda-invoke contract) to validate a freshly
  published image.

Do NOT capture bundles for every routine successful run — the EventBridge
schedule + CloudWatch + this probe already constitute the continuous signal.

## What `.current_bundle` means here

The `.current_bundle` pointer references the most recent intentional
snapshot. It is informational, not authoritative. If you find it pointing
at a bundle from weeks ago, that simply means no wave has needed to capture
a fresh one — it does NOT mean the canary stopped. To answer "is the canary
running?" run the probe above.

If a wave's evidence needs a fresh snapshot bundle, update
`.current_bundle` as part of that wave's commit. Otherwise leave it alone.
