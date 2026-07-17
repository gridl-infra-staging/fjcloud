# Stage 3 CI Fix Summary

Sources:

- `session_handoffs/stage_03/s20_build_branch-aware-deploy-and-topology-docs.md`
- `session_handoffs/stage_03/s22_clean_review_stage-3-all-pass.md`

Stage 3 authored and reviewed the branch-aware staging web deploy fix.

Implementation commit `87f28407e`:

- Added red-first contract coverage in `scripts/tests/ci_deploy_web_contract_test.sh`.
- Preserved the existing contiguous `--branch=main` deploy assertion.
- Added assertions that `deploy-staging` also runs a contiguous
  `wrangler@4 pages deploy ... --branch=staging --commit-hash="$GITHUB_SHA"` command.
- Added an order assertion that the `--branch=main` deploy happens before the
  `--branch=staging` deploy in the same workflow step.
- Updated `.github/workflows/ci.yml` so the staging mirror builds once, deploys
  `--branch=main` first, then deploys `--branch=staging`, with each loop stamping
  `--commit-hash="$GITHUB_SHA"`.

Topology documentation commit `d16964982`:

- Corrected the `.github/workflows/ci.yml` single-deployer comments to the two-branch
  Cloudflare Pages topology.
- Corrected `docs/runbooks/deploy_surfaces.md`.
- Corrected the contract-test rationale comment while leaving the deploy-prod absence
  assertion intact.

Validation and review proof:

- `bash scripts/tests/ci_deploy_web_contract_test.sh` passed with 29/29 contract tests pass.
- `bash scripts/local-ci.sh --fast` passed in Stage 3.
- Clean review verified all 11 Stage 3 child checklist items and filed no bugs.
