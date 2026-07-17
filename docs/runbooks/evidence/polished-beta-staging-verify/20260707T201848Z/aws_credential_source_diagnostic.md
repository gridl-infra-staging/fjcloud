# AWS credential source diagnostic

- ambient_default_status: `InvalidClientTokenId` (see credential_hydration_shim_diagnostic.md)
- repo_secret_file: `.secret/.env.secret`
- cleared_ambient_aws_vars_before_source: yes
- sts_exit_code: `0`
- sts_account: `213880904778`
- sanitized_sts_output:

```text
{
    "Account": "213880904778",
    "Arn": "arn:aws:iam::213880904778:user/<redacted>
}
```
