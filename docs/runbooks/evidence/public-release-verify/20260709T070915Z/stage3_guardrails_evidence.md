# Stage 3 Guardrails Evidence

## Bundle

`docs/runbooks/evidence/public-release-verify/20260709T070915Z`

## Deploy-currency drift alarm

- Run id: `29004150671`
- Evidence: `deploy_currency_dispatch_run.json`
- Dispatch log: `stage3_deploy_currency_dispatch.log`
- Schedule proof: `deploy_currency_schedule.txt`
- Conclusion: green.

Gate evidence:

- `.event == "workflow_dispatch"`
- `.headSha == d6cc42182bcd8c0f32335b8520e5a576e36cc1dd`
- `.conclusion == "success"`
- `deploy-currency` job conclusion is `success`
- Schedule proof contains hourly cron `23 * * * *`

## Nightly pricing freshness

- Run id: `29004197632`
- Evidence: `nightly_dispatch_run.json`
- Rerun evidence after red gate: `nightly_dispatch_run_rerun.json`
- Jobs API evidence: `nightly_dispatch_jobs_api.json`
- Failed log capture: `nightly_dispatch_failed_logs.txt`
- Dispatch log: `stage3_nightly_dispatch.log`
- Conclusion: red with Stage 3 defect stub.

Gate evidence:

- `.event == "workflow_dispatch"`
- `.headSha == d6cc42182bcd8c0f32335b8520e5a576e36cc1dd`
- `.conclusion == "failure"`
- `pricing-freshness` job conclusion is `cancelled`

Stage 3 stub:

- `chats/icg/stubs/jul06_pm_5_guardrail_pricing_freshness_defect.md`

## Secret-name proof

- Evidence: `stage3_staging_secrets.txt`
- Command log: `stage3_secret_and_closure.log`
- Conclusion: green. `DISCORD_WEBHOOK_URL` is present in the staging mirror secret-name list. Secret values were not printed or fetched.

## Stage 1 and Stage 2 context stubs

These remain context for closeout and are not reasons to skip Stage 3 guardrail probes:

- `chats/icg/stubs/jul06_pm_5_pages_or_public_browser_deploy_defect.md`
- `chats/icg/stubs/jul06_pm_5_pipeline_regression.md`
- `chats/icg/stubs/jul06_pm_5_public_signup_surface_deploy_defect.md`
