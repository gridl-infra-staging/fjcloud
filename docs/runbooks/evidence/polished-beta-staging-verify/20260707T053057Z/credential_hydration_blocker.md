# Credential Hydration Blocker

Stage 2 stopped before Playwright execution because the required staging credential hydration path could not fetch SSM parameters.

Commands run and sanitized outputs:

```text
$ aws sts get-caller-identity --query 'Account' --output text
aws_identity_rc=254
aws: [ERROR]: An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.
```

```text
$ bash scripts/launch/hydrate_seeder_env_from_ssm.sh staging >/tmp/stdout 2>/tmp/stderr
shim_rc=254
stdout_lines=0
stderr_head=
```

Note: the shim suppresses AWS CLI stderr inside `ssm_value()`, so the direct AWS identity probe above is the diagnostic evidence for the credential failure family.

```text
$ source project-local .secret/stuart-cli_accessKeys.csv as AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY; unset AWS_SESSION_TOKEN; aws sts get-caller-identity --query 'Account' --output text
csv_aws_identity_rc=254
aws: [ERROR]: An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.
```

```text
$ aws configure list-profiles
(no profiles listed)
```

Classification: external-unreachable. The repo-owned hydration code path is present, sourced successfully when `REPO_ROOT` is set, and invokes the canonical SSM shim. The blocker is unavailable/invalid AWS credentials in the operator environment, which cannot be repaired by a code change in this repo without new valid credential material.
