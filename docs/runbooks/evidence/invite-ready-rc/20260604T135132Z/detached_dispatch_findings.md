---
created: 2026-06-04
updated: 2026-06-04
---

# Detached RC Dispatch Findings

## Purpose

Document the Stage 4 rerun of the canonical paid-beta RC harness using the
required detached/background shell shape.

## Sources

- `scripts/launch/run_full_backend_validation.sh` owns the paid-beta RC harness
  and writes the authoritative `summary.json`.
- `scripts/launch/post_deploy_evidence_capture.sh:130-338` is the persisted
  wrapper-layout precedent for keeping the harness summary and logs together.
- `LAUNCH.md:31-49` owns the allowed paid-beta verdict labels.
- `docs/launch_verification_matrix.md:29-41,82-92` owns aggregate section-state
  mapping.

## Dispatch Evidence

Fresh bundle: `docs/runbooks/evidence/invite-ready-rc/20260604T135132Z/`.

The harness was launched from a persistent bash shell as a background job. The
captured shell PID was `46873`, written to `harness_pid.txt`. The process wrote
`full_backend_validation.log`, per-step sidecar logs, harness-owned
`summary.json`, and `rc_exit_code.txt` into the same bundle.

The command shape used the canonical lane secret source in-process and passed
the same credential file through the harness owner flag:

```bash
set -a
source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret
set +a
bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc \
  --artifact-dir="docs/runbooks/evidence/invite-ready-rc/20260604T135132Z" \
  --credential-env-file=/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret \
  > "docs/runbooks/evidence/invite-ready-rc/20260604T135132Z/full_backend_validation.log" 2>&1
printf '%s\n' "$?" > "docs/runbooks/evidence/invite-ready-rc/20260604T135132Z/rc_exit_code.txt"
```

`rc_exit_code.txt` is `1`, matching the harness `ready=false` result.

## Wrapper Notes

Two earlier wrapper probes exited before the harness started because this tool
runner reaped background descendants when the parent non-interactive shell
exited. They produced empty logs and no `summary.json`; those failed wrapper
probes were not used for verdict classification. The completed bundle above was
run from a live bash PTY so the background child could survive until exit.

## Open Questions

Open questions: none.
