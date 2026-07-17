# GAP_SPEC: Stage 1 Pages target mismatch

- classification: `deploy-regression`
- failing_leg: `served Pages _app/version.json assertion`
- observed: `wait_for_pages_parity.sh` served `0b069a56a9e73e97b1b9859a8676f938535777d1` from `https://cloud.staging.flapjack.foo/_app/version.json`, but the Stage 1 command waited for dev SHA `c106025d6761b51d05d0b624e2c10aeba9589c8e`.
- smallest_unblocker: Align the Stage 1 Pages assertion target with the canonical Pages provenance model, or change the Pages provenance model in the deploy lane. Existing deploy code stamps Pages with the staging mirror SHA.

Owner files:
- `.github/workflows/ci.yml`
- `web/svelte.config.js`
- `scripts/launch/wait_for_pages_parity.sh`
- `.debbie.toml`
- relevant deploy runbook for Stage 1 staging currency verification

Disposition:
- ships: No Stage 2 browser or RC verification starts from this Stage 1 evidence.
- reverts: No product code or deploy infrastructure was reverted in this stage.
- parks: Product/deploy-infra changes are parked for a separate lane. This stage preserves the raw evidence and stops after classifying non-convergence.

Evidence:
- `pages_parity.stderr.txt`
- `pages_parity.github_output.txt`
- `pages_version_body.json`
- `staging_run_29177317821_jobs.txt`
- `deploy_status_final.json`
- `pages_parity_mirror_diagnostic.stderr.txt`

