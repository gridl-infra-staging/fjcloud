# Stage 1 Summary - 20260709T105032Z Current-Main Rerun

## Bundle Of Record
This bundle records the Stage 1 verification-only rerun attempt for current
`main` under
`docs/runbooks/evidence/staging-billing-rehearsal/20260709T105032Z_current_main/`.

The live reset and billing mutation were not run. The deploy-currency gate failed
before staging mutation was allowed.

## Owner Scripts Reviewed
- `scripts/staging_billing_rehearsal.sh`
- `scripts/lib/staging_billing_rehearsal_flow.sh::run_rehearsal_flow`
- `scripts/lib/staging_billing_rehearsal_impl.sh::{run_preflight_owner,capture_health_artifact,emit_summary_and_exit}`
- `scripts/lib/staging_billing_rehearsal_reset.sh::{validate_test_tenant_allowlist,run_reset_flow}`

## Reference Contract
Reference bundle:
`docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/`

The known-good pass contract was rerun:

```bash
jq -e '.result == "passed" and .classification == "rehearsal_completed"' docs/runbooks/evidence/staging-billing-rehearsal/20260428T055058Z_paid_lifecycle_clean/summary.json
```

Result: passed, with output captured in `reference_summary_jq.txt`.

## Deploy-Currency Gate
Command:

```bash
bash scripts/deploy_status.sh --json --env staging
```

Captured outputs:
- `deploy_status.stdout.json`
- `deploy_status.stderr.txt`

Observed machine-readable fields:
- `dev_main_sha`: `eca06b5cd02d76c7183e0de9b375d118d77208cc`
- `envs.staging.dev_sha`: `d028c82f895700b88b7ce0e327c06fa740c09d2d`
- `envs.staging.commits_behind_main`: `1`

Gate command:

```bash
jq -e '.envs.staging.dev_sha == .dev_main_sha and .envs.staging.commits_behind_main == "0"' docs/runbooks/evidence/staging-billing-rehearsal/20260709T105032Z_current_main/deploy_status.stdout.json
```

Result: failed with exit 1; output captured in `deploy_currency_gate_jq.txt`.

## Read-Only Live-State Baseline
Command:

```bash
bash scripts/probe_live_state.sh
```

Captured outputs:
- `probe_live_state.stdout.txt`
- `probe_live_state.stderr.txt`
- `probe_live_state_summary_path.txt`
- `pre_mutation_live_state_SUMMARY.md`

Probe result: exit 0. The generated snapshot was
`docs/live-state/20260709T105204Z/SUMMARY.md`.

## Reset/Live Verdict
Reset command: not run.

Live command: not run.

Reason: the Stage 1 checklist requires proceeding only when
`.envs.staging.dev_sha == .dev_main_sha` and
`.envs.staging.commits_behind_main == "0"`. Staging was one commit behind
`origin/main`, so this verification attempt is red at the deploy-currency gate.
