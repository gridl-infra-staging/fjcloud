# Stage 3 Customer-Loop Canary Gap Spec

## Current Evidence

- Evidence root: `docs/runbooks/evidence/ses-inbox-canary-clean-env/20260709T104734Z/canary/`
- Credential gate passed: `aws sts get-caller-identity --region us-east-1` exited 0 for account `213880904778`.
- Direct dry-run command exited 0 but did not prove customer-loop success. It returned before probe work with `[customer-loop-canary] quiet window active; skipping customer loop execution`.
- Readback command `bash scripts/probe_canary_live_state.sh staging --json` exited 1.
- Readback failed checks:
  - `errors_24h`: `Errors sum 24h = 1.0 (canary throwing)`
  - `last_invocation`: `last completed invocation missing 'completed successfully' marker`
- Latest three Lambda streams all completed with the quiet-window skip and no success marker.
- Last-24h log scan found one script-owned failure boundary: `[customer-loop-canary] step 'signup' failed: register returned HTTP 429` at `2026-07-08T19:06:23.644Z`.
- `alarms` passed, so the support-email follow-up was not run.

## Smallest Current Owner To Fix Next

- Primary owner: `scripts/canary/customer_loop_synthetic.sh::main` / signup flow owner.
- Concrete failure to investigate next: the customer-loop canary hit `step 'signup' failed: register returned HTTP 429` in the last 24h window.
- Readback owner to preserve: `scripts/probe_canary_live_state.sh` correctly reports the live state as not green because `errors_24h` is non-zero and the latest completed invocation lacks the terminal `customer loop canary completed successfully` marker.

## Out Of Scope For Stage 3

- Do not enable `--live`.
- Do not add a wrapper around the existing canary.
- Do not change product code in this verification-only stage.
