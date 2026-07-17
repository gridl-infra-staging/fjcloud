# Parity verdict — 20260706T202049Z

- classification: parity_unconvergeable
- ready: false
- head_sha: cfc14f0114cd9f1a6fcf3fe612d7488c3840e777
- failing_env: staging
- trigger: parity timeout (40 polls exhausted at 20-min cap; staging CI still in flight)
- final_staging_gap: 10
- final_prod_gap: 0
- final_staging_dev_sha: 44435bed4729f4040e1285cf3122187e4b3e77ea
- final_prod_dev_sha: cfc14f0114cd9f1a6fcf3fe612d7488c3840e777
- deploy_status_attempts_used: 40
- remaining_attempts: 0
- evidence_bundle: docs/runbooks/evidence/polished-beta-staging-verify/20260706T202049Z/

## Summary

Both debbie syncs succeeded on first attempt (staging + prod pushed at 20:21:15Z / 20:21:20Z UTC).
Prod converged at iter=39/40 (~19.5 min after baseline snapshot). Staging did not converge in
the 20-min window — its post-sync CI run was still `in_progress` at 20m35s when the poll cap
hit, so the live API's mirror_sha remained at the pre-sync value (4fd2559c1…) and gap held at 10.

## Replay

```
bash scripts/deploy_status.sh --json
```
