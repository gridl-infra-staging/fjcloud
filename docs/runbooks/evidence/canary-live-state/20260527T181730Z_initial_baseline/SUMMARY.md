# Canary live-state baseline — 20260527T181730Z

Initial capture demonstrating the new evidence-bundle pattern for the
canary live-state probe. See [`docs/runbooks/evidence/canary-customer-loop/README.md`](../../canary-customer-loop/README.md)
for the bundle-vs-live-state distinction.

## Verdict

Both prod and staging customer-loop canaries are GREEN per
`scripts/probe_canary_live_state.sh`:
- EventBridge schedules ENABLED on both envs
- Invocations sum 24h = 96 on both (rate(15 minutes) * 24h = exactly 96)
- Errors sum 24h = 0 on both
- All canary alarms in OK state
- Last invocation logs contain "completed successfully" marker

## Files

- `prod.json` — probe JSON output for prod env
- `staging.json` — probe JSON output for staging env

(Probe stderr is `*.log`-gitignored, empty on green runs anyway.)

## Reproduce

```bash
set -a; source .secret/.env.secret; set +a
bash scripts/probe_canary_live_state.sh prod --json
bash scripts/probe_canary_live_state.sh staging --json
```
