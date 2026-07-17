<!-- [scrai:start] -->
## lib

| File | Summary |
| --- | --- |
| deploy_validation.sh | Shared pre-deployment validation adapter for deploy gate checks. |
| generate_ssm_env.sh | generate_ssm_env.sh — Read SSM parameters and write runtime env files.

Single source of truth for the SSM-param-name -> env-var-name mapping.
Called on-instance before service restart to populate the EnvironmentFile
contracts referenced by systemd units:
  - /etc/fjcloud/env            (fjcloud-api, fjcloud-aggregation-job)
  - /etc/fjcloud/metering-env   (fj-metering-agent)

Usage: generate_ssm_env.sh <env>
  env: staging | prod

Requires: aws CLI with IAM role that can ssm:GetParametersByPath + kms:Decrypt. |
| rds_restore_selection.py | Stub summary for rds_restore_selection.py. |
<!-- [scrai:end] -->
