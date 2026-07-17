# Owner Notes

AMI resolution remains owned by `ops/terraform/tests_stage7_runtime_smoke.sh:163-193`
(line numbers reflect the credential-loading reorder in commit dcf5e18b9).

Credential loading was moved before AMI resolution in commit dcf5e18b9 to fix
the env-file-ignored-for-ami-ssm bug where SSM fallback ran without credentials.
