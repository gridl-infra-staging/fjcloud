---
created: 2026-06-04
updated: 2026-06-04
---

# Detached RC Dispatch Findings

## Purpose

Document the fresh Stage 4 rerun of the canonical paid-beta RC harness with a
machine-checkable launch proof for the exact shell contract.

## Dispatch Evidence

Fresh bundle: `docs/runbooks/evidence/invite-ready-rc/20260604T140537Z/`.

The shell wrote `launch_command_proof.txt` before starting the harness. That
file records:

- repo root:
  `fjcloud_dev`
- bundle:
  `docs/runbooks/evidence/invite-ready-rc/20260604T140537Z`
- canonical credential file:
  `/Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret`
- the exact command block using `set -a`, `source`, `set +a`, and
  `bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc`
- `--artifact-dir` pointed at this bundle and `--credential-env-file` pointed
  at the same canonical credential file
- background PID `62174`, also preserved in `harness_pid.txt`
- `source_rc=0`
- monitor samples of `full_backend_validation.log`
- `harness_exit_code=1`, matching `rc_exit_code.txt`

The harness wrote `summary.json`, `full_backend_validation.log`, per-step
sidecar logs, `rc_exit_code.txt`, and `harness_pid.txt` into this same bundle.

## Wrapper Notes

The launch proof is intentionally separate from the narrative findings so a
clean review can validate the shell shape directly with:

```bash
sed -n '1,220p' docs/runbooks/evidence/invite-ready-rc/20260604T140537Z/launch_command_proof.txt
cat docs/runbooks/evidence/invite-ready-rc/20260604T140537Z/harness_pid.txt
cat docs/runbooks/evidence/invite-ready-rc/20260604T140537Z/rc_exit_code.txt
```

Open questions: none.
