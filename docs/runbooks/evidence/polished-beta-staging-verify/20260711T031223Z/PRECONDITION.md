# Stage 1 Precondition

Stage 2 may proceed: yes

## Evidence

- Checkout target provenance: target_dev_sha.txt
- Deployable SHA drift explanation: target_drift_explanation.md
- Staging mirror CI run: staging_ci_run.json
- Pages parity: pages_parity.log
- Pricing HTML: staging_pricing.html
- Deploy status: deploy_status_staging.json
- API version: staging_version.json

## Result

- Staging CI conclusion: success
- Staging mirror SHA: bd4fdada14a87295cd52393aca6f531978498249
- Deploy-status dev main SHA: 873f39ef4a375e69f81fcb021f0297fd75381708
- API /version dev_sha: 873f39ef4a375e69f81fcb021f0297fd75381708
- API /version mirror_sha: bd4fdada14a87295cd52393aca6f531978498249
- Pages marker: PRECOND_STAGING_SERVED_OK

The deployment is current for dev main. target_dev_sha.txt records the executing checkout HEAD, which is a stage/checklist branch commit, not the deployable dev main SHA; see target_drift_explanation.md.
