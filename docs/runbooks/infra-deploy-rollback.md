# Deploy, Migrate, and Rollback via SSM

Full SSM-based deploy lifecycle for fjcloud. All remote execution uses AWS Systems Manager — no SSH keys required.

Scripts: `ops/scripts/deploy.sh`, `ops/scripts/migrate.sh`, `ops/scripts/rollback.sh`

## Pre-deploy Checklist

Before deploying, verify:

- [ ] Release artifacts are uploaded to S3: `s3://fjcloud-releases-<env>/<env>/<sha>/`
  - `fjcloud-api`, `fjcloud-aggregation-job`, `fj-metering-agent` binaries
  - `migrations/` directory with SQL files
  - `scripts/migrate.sh`
- [ ] EC2 instance is running: `aws ec2 describe-instances --filters "Name=tag:Name,Values=fjcloud-api-<env>" "Name=instance-state-name,Values=running"`
- [ ] SSM agent is healthy: `aws ssm describe-instance-information --filters "Key=InstanceIds,Values=<instance-id>"`
- [ ] SSM parameter `/fjcloud/<env>/database_url` exists (for migrations)
- [ ] Previous deploy SHA is recorded: `aws ssm get-parameter --name "/fjcloud/<env>/last_deploy_sha"`

## Deploy

### Usage

```bash
ops/scripts/deploy.sh <env> <git-sha>
```

Example:

```bash
ops/scripts/deploy.sh staging abc123def456789012345678901234567890abcd
```

### What deploy.sh does

1. Discovers the EC2 instance by `Name=fjcloud-api-<env>` tag
2. Reads the current `last_deploy_sha` from SSM for rollback safety
3. Sends an SSM `send-command` (`AWS-RunShellScript`) to the instance:
   - Downloads binaries from `s3://fjcloud-releases-<env>/` as `.new` files
   - Syncs migrations from S3
   - Runs `migrate.sh <env>` (fail fast before binary swap)
   - Backs up current binaries as `.old`
   - Atomic binary swap via `mv`
   - Runs `systemctl restart fjcloud-api`
   - Health check: `curl -sf http://127.0.0.1:3001/health`
   - On health check failure: rolls back from `.old` backups
4. Polls SSM via `get-command-invocation` until success or failure
5. On success: updates `/fjcloud/<env>/last_deploy_sha` in SSM via `put-parameter`

### Expected output

```
==> Discovering instance for fjcloud-api-staging...
    Instance: i-0abc123def456
==> Reading previous deploy SHA from SSM...
    Previous SHA: (none)
==> Sending deploy command via SSM...
    Command ID: cmd-0abc123def456
==> Polling SSM command status...
    Status: InProgress
    Status: Success
==> Deploy successful! Updating last_deploy_sha...
    SHA abc123def456789012345678901234567890abcd recorded
```

## Migrate

Migrations run automatically during deploy. For manual execution (on the EC2 instance):

```bash
ops/scripts/migrate.sh <env>
```

The script:
1. Fetches `DATABASE_URL` from SSM (`/fjcloud/<env>/database_url`) with `--with-decryption`
2. Runs `sqlx migrate run` against the migrations directory
3. Is idempotent — safe to re-run

## Rollback

### Usage

```bash
ops/scripts/rollback.sh <env> <previous-sha>
```

Example — roll back to the SHA recorded before the failed deploy:

```bash
# Check what the previous SHA was
aws ssm get-parameter --name "/fjcloud/staging/last_deploy_sha" --query 'Parameter.Value' --output text

# Roll back
ops/scripts/rollback.sh staging <previous-sha>
```

### What rollback.sh does

1. Downloads binaries for `<previous-sha>` from `s3://fjcloud-releases-<env>/`
2. Sends SSM `send-command` to swap binaries and restart services
3. Does **not** run migrations (never roll back migrations)
4. Health checks after restart
5. Updates `last_deploy_sha` in SSM on success

### Expected output

```
==> Discovering instance for fjcloud-api-staging...
    Instance: i-0abc123def456
==> Sending rollback command via SSM...
    Command ID: cmd-0abc123def456
==> Polling SSM command status...
    Status: Success
==> Rollback successful! Updating last_deploy_sha...
```

## One-Shot API Host Cleanup for Legacy Metering Artifacts

Owner script: `ops/scripts/cleanup_api_server_metering_ghost.sh`

This cleanup is intentionally separate from `deploy.sh` and `rollback.sh`. Run it only after confirming the Stage 3 cleanup deploy SHA is live in `/fjcloud/<env>/last_deploy_sha`.

1. Mandatory first step: dry-run only.

```bash
bash ops/scripts/cleanup_api_server_metering_ghost.sh --dry-run
```

2. SSM live invocation (operator-run after dry-run review).

```bash
aws ssm send-command \
  --region us-east-1 \
  --instance-ids <api-instance-id> \
  --document-name AWS-RunShellScript \
  --comment "cleanup dormant fj-metering-agent ghost on API server" \
  --parameters "$(python3 - <<'PY'
import json
import pathlib
script_path = pathlib.Path('ops/scripts/cleanup_api_server_metering_ghost.sh')
commands = [
  'export EXPECTED_DEPLOYED_SHA=<verified-stage3-deploy-sha>',
  *script_path.read_text().splitlines(),
]
print(json.dumps({'commands': commands}))
PY
)"
```

3. Required override: set `EXPECTED_DEPLOYED_SHA` to the verified deployed SHA for the cleanup release before any live run.
4. Scope note: live cleanup execution is out-of-scope for this stage; this stage only defines and validates the operator invocation contract.

## Verifying Deploy Success

After deploy or rollback:

```bash
# Health check
curl -sf https://api.flapjack.foo/health

# Verify recorded SHA
aws ssm get-parameter \
  --name "/fjcloud/<env>/last_deploy_sha" \
  --query 'Parameter.Value' --output text
```

## Troubleshooting Failed Deploys

### Check SSM command output

```bash
# Get the command output (stdout + stderr)
aws ssm get-command-invocation \
  --command-id <command-id> \
  --instance-id <instance-id> \
  --query '[StandardOutputContent, StandardErrorContent]' \
  --output text
```

### Check on-instance logs

If SSM shows the command succeeded but the service is unhealthy:

```bash
# Via SSM session (interactive)
aws ssm start-session --target <instance-id>

# Check service status
systemctl status fjcloud-api

# Check application logs
journalctl -u fjcloud-api --since "10 minutes ago" --no-pager

# Check if binaries exist
ls -la /usr/local/bin/fjcloud-* /usr/local/bin/fj-*
```

### Common failure modes

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| SSM command `Failed` | Script error on instance | Check SSM stdout/stderr |
| SSM command `TimedOut` | Instance hung or slow network | Check instance CPU/memory, retry |
| Health check failed, auto-rolled back | App crash on startup | Check `journalctl -u fjcloud-api`, fix app bug |
| Migration failed | Bad SQL or DB connectivity | Check DB connectivity, fix migration, re-deploy |
| "Instance not found" | Wrong env or instance stopped | Verify instance is running with correct Name tag |
