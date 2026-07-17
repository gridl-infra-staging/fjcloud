# Commands

Bundle: docs/runbooks/evidence/ses-coverage-a1/20260712T185310Z_db_visibility_diagnosis

## Credential loading

- unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; set -a; source /Users/stuart/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret; set +a

## Commands run

- date -u +%Y%m%dT%H%M%SZ
- bash scripts/probe_live_state.sh
- Parsed live-state output bundle from probe stdout: docs/live-state/20260712T185310Z
- cp docs/live-state/20260712T185310Z/staging_rds.txt docs/runbooks/evidence/ses-coverage-a1/20260712T185310Z_db_visibility_diagnosis/staging_rds.txt
- aws ec2 describe-instances --region us-east-1 --filters Name=tag:Name,Values=fjcloud-api-staging Name=instance-state-name,Values=running --output json
- aws ssm describe-instance-information --region us-east-1 --filters Key=InstanceIds,Values=<instance-id> --output json
- aws ssm send-command/get-command-invocation per running staging API instance, running a remote redaction script for /etc/fjcloud/env, systemctl show Environment, and /proc/<MainPID>/environ
- aws ssm get-parameter --region us-east-1 --name /fjcloud/staging/database_url --with-decryption --query Parameter.Value --output text | python3 redacted fingerprint parser
- FAILED local wrapper attempt for canonical SSM/control SQL capture: shell quoting broke before useful execution
- aws ssm get-parameter --region us-east-1 --name /fjcloud/staging/database_url --with-decryption --query Parameter.Value --output text | python3 redacted fingerprint parser
- aws ec2 describe-instances --region us-east-1 --filters Name=tag:Name,Values=fjcloud-api-staging Name=instance-state-name,Values=running --query Reservations[0].Instances[0].InstanceId --output text
- source scripts/lib/clickthrough_probe_common.sh; probe_sql_single_value control endpoint SELECT
- API_URL=https://api.staging.flapjack.foo curl POST /auth/register with generated throwaway @test.flapjack.foo email and generated password (password not logged)
- source scripts/lib/clickthrough_probe_common.sh; probe_sql_single_value customer visibility by id and email; sleep 2; repeat
- CORRECTED email visibility SQL after invalid COUNT(*) + ORDER BY: SELECT id FROM customers WHERE email = <probe_email> ORDER BY created_at DESC LIMIT 1; repeated after 2 seconds
- source scripts/lib/clickthrough_probe_common.sh; probe_sql_single_value exact verify-email and reset-token WHERE/result expressions against registered control row
