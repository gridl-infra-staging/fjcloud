# Runtime Smoke Gap Spec

## Failing command

```bash
bash ops/terraform/tests_stage7_runtime_smoke.sh --env staging --env-file "$(pwd)/.secret/.env.secret"
```

## Exact exit code

`1`

## Owner JSONL

`owner_jsonl_missing`

The owner exited before emitting `==> evidence bundle: ...`, so no owner-created JSONL path was available to copy.

## Missing required proof lines

- `resolved AMI ami-` or `OK: AMI ami-... found`
- `OK: target group has healthy targets`
- `OK: Cloudflare public records match the canonical ALB/Pages split`
- `OK: SES identity and DKIM are verified`
- `OK: https://api.flapjack.foo/health returned 200`

## Public-safe remediation class

Repo-owned runtime-smoke prerequisite: `ops/terraform/tests_stage7_runtime_smoke.sh` attempts SSM AMI fallback before it reads the supplied `--env-file`, so the documented Stage 2 command cannot use `.secret/.env.secret` credentials for AMI resolution in a clean shell. Keep AMI resolution owned by `ops/terraform/tests_stage7_runtime_smoke.sh:139-169`; remediation should move or share the env-file credential loading before SSM lookup without adding a wrapper or alternate runtime-smoke path.
