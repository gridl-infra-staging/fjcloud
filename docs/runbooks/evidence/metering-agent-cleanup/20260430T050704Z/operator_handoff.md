# Stage 4 Operator Handoff (Metering Ghost Cleanup)

Ready-for-operator criteria:
- Cleanup deploy SHA is present and must be verified at runtime from \/fjcloud\/<env>\/last_deploy_sha.
- API-host identity gate is enforced in-script via IMDSv2 + EC2 Name tag pattern fjcloud-api-*.
- Dry-run output has been captured and reviewed before any live invocation.

Evidence files in this directory:
- cleanup_dry_run.log
- tests_deploy_scripts_static.log
- tests_stage5_static.log
- tests_deploy_scripts_static.cache.txt
- tests_stage5_static.cache.txt

Scope guard:
- Live cleanup execution remains out-of-scope for Stage 4; this package documents and validates invocation only.
