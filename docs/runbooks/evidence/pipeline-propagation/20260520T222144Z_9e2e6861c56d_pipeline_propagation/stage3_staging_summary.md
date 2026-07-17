# Stage 3 Staging Publication Summary

- Frozen candidate dev SHA: 9e2e6861c56d4598587538099953086d2604ea93
- Active bundle: docs/runbooks/evidence/pipeline-propagation/20260520T222144Z_9e2e6861c56d_pipeline_propagation
- Staging mirror SHA: f689fb069c8625259e8c212a4d0aadb29d805cf7
- Staging commit subject: stage3: publish active bundle pointer and freeze bundle
- CI run ID: 26197488802
- CI run URL: https://github.com/gridl-infra-staging/fjcloud/actions/runs/26197488802
- CI run status: completed
- CI run conclusion: failure

## Required gates (.github/workflows/ci.yml needs[])
- check-sizes: status=completed conclusion=success
- web-lint: status=completed conclusion=success
- web-test: status=completed conclusion=success
- secret-scan: status=completed conclusion=success
- rust-test: status=completed conclusion=success
- migration-test: status=completed conclusion=success
- rust-lint: status=completed conclusion=success
- deploy-staging: status=completed conclusion=success

## Advisory gate
- playwright: status=completed conclusion=failure (advisory)

## Current verdict
- Stage 3 publication pointer bug is remediated (.current_bundle now points at the active bundle in staging).
- Stage 3 SHA-bound CI proof is complete: required gates (including deploy-staging) passed for the exact pushed staging mirror SHA; advisory playwright remained red.
