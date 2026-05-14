# Staging Access Runbook

Operational reference for working against the fjcloud staging environment from outside the VPC.
**Verify volatile facts (deployed SHA, instance IDs) against live sources — this doc describes the expected state, not guaranteed current state.**

---

## AWS Credentials

Credentials live at `.secret/stuart-cli_accessKeys.csv`. Load them before any `aws` CLI call:

```bash
eval "$(awk -F',' 'NR==2 {
    print "export AWS_ACCESS_KEY_ID=" $1
    print "export AWS_SECRET_ACCESS_KEY=" $2
}' .secret/stuart-cli_accessKeys.csv)"
export AWS_DEFAULT_REGION=us-east-1
```

Verify: `aws sts get-caller-identity`

---

## Deployed Topology

**Verify before trusting** — deployment state changes; this is a snapshot.

| Service | URL / location | Notes |
|---|---|---|
| Staging API | `https://api.flapjack.foo` | Health: `GET /health` → 200 |
| Staging frontend | `https://cloud.flapjack.foo` | CF Pages; may be dark |
| Prod stack | not yet deployed | verify: `curl -s https://api.flapjack.foo/health` (prod URL TBD) |
| EC2 (staging API host) | tag `Name=fjcloud-api-staging` | `us-east-1`; RDS is VPC-private |
| RDS | VPC-private | not reachable from developer machine; use SSM (see below) |

Live EC2 check:
```bash
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=fjcloud-api-staging" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[*].Instances[*].[InstanceId,PublicIpAddress,State.Name]' \
  --output table
```

Deployed binary version:
```bash
curl -s https://api.flapjack.foo/health | python3 -m json.tool
```

---

## API Access

Base URL: `https://api.flapjack.foo`

```bash
# Health check
curl -s https://api.flapjack.foo/health

# Authenticated request (requires a valid token)
curl -s -H "Authorization: Bearer $TOKEN" https://api.flapjack.foo/account
```

---

## Database Access (RDS via SSM)

RDS is in the VPC and not reachable directly. Use `scripts/lib/staging_db.sh` to run SQL:

```bash
# Set credentials first (see AWS Credentials section above), then:
export DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url
export DATABASE_URL="$(aws ssm get-parameter \
  --name "$DATABASE_URL_SSM_PARAM" \
  --with-decryption --query Parameter.Value --output text)"
source scripts/lib/staging_db.sh
staging_db_run_sql "$DATABASE_URL" "SELECT COUNT(*) FROM customers"
```

Note: `DATABASE_URL_SSM_PARAM` must be exported before sourcing `staging_db.sh` is called so `staging_db_env_tag` can derive the environment (staging vs prod). `AWS_DEFAULT_REGION` is captured at source time.

Or use `scripts/launch/ssm_exec_staging.sh` for arbitrary shell commands on the EC2 host (where `DATABASE_URL` is loaded from `/etc/fjcloud/env`):

```bash
# Run any shell command on the staging EC2 instance
scripts/launch/ssm_exec_staging.sh "psql \$DATABASE_URL -c 'SELECT COUNT(*) FROM customers'"

# With environment loaded from the instance's env file
scripts/launch/ssm_exec_staging.sh "source /etc/fjcloud/env && psql \$DATABASE_URL -c 'SELECT 1'"
```

IAM requirement: `ssm:SendCommand` + `ssm:GetCommandInvocation`. The EC2 instance must have `AmazonSSMManagedInstanceCore`.

---

## Log Tailing

```bash
# Tail the API service logs from the staging instance
scripts/launch/ssm_exec_staging.sh "journalctl -u fjcloud-api -n 100 --no-pager"

# Follow in real-time (exits after 300s — ssm_exec_staging.sh default timeout)
scripts/launch/ssm_exec_staging.sh "journalctl -u fjcloud-api -f --no-pager"
```

---

## SSM Parameter Paths

| Parameter | Contents |
|---|---|
| `/fjcloud/staging/database_url` | Full postgres:// URL with credentials |
| `/fjcloud/prod/database_url` | Not yet created (prod not deployed) |

Fetch any parameter:
```bash
aws ssm get-parameter --name /fjcloud/staging/database_url \
  --with-decryption --query Parameter.Value --output text
```

---

## Seeding Operator Accounts

```bash
API_URL=https://api.flapjack.foo \
DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url \
AWS_DEFAULT_REGION=us-east-1 \
  bash scripts/seed_operator_accounts.sh
```

Script is idempotent — safe to re-run. It will skip accounts that already exist and can login.
