# Prod API CloudWatch Disk Telemetry Coverage Evidence

## Scope
Stage 1 reconciliation evidence for prod API host disk telemetry (`CWAgent` namespace, `disk_used_percent` metric).

## Bootstrap dependency (future launches)
- Canonical owner: `ops/terraform/compute/main.tf` `aws_instance.api.user_data`.
- Load-bearing behavior:
  - Installs `amazon-cloudwatch-agent`.
  - Writes `/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json` with `disk_used_percent` collection for `path=/`.
  - Starts agent via `amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -c file:... -s`.
- `user_data_replace_on_change = false` remains intentional: edits do not mutate existing instances; they apply to fresh launches only.

## IAM dependency
- Canonical owner: `ops/iam/fjcloud-instance-role.tf`.
- Required inline policies on `fjcloud-instance-role`:
  - `fjcloud-cloudwatch-metrics` (allows `cloudwatch:PutMetricData` with namespace including `CWAgent`).
  - `fjcloud-cloudwatch-agent-logs` (allows CloudWatch Logs writes used by agent log shipping).

## Live reconciliation performed in this session
- Prod instance resolved by tag: `Name=fjcloud-api-prod` -> `i-0af0ff2e18725b6ba`.
- SSM command executed to install/configure/start CloudWatch agent on the running host.
- Runtime logs initially showed `AccessDenied` for `PutMetricData`/`PutLogEvents` until role policy convergence.
- Role policies were converged, agent restarted via SSM, and metrics appeared in CloudWatch.

## Post-rotation verification commands (run every replacement)
```bash
REGION=us-east-1
INSTANCE_ID=$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=fjcloud-api-prod" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)

aws ssm describe-instance-information \
  --region "$REGION" \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query "InstanceInformationList[0].{InstanceId:InstanceId,PingStatus:PingStatus,AgentVersion:AgentVersion}" \
  --output json

aws cloudwatch list-metrics \
  --region "$REGION" \
  --namespace CWAgent \
  --metric-name disk_used_percent \
  --dimensions Name=InstanceId,Value="$INSTANCE_ID" \
  --output json
```

## Fresh datapoint assertion command
```bash
bash /tmp/verify_cw_metric.sh
```
Where `/tmp/verify_cw_metric.sh` should query `CWAgent/disk_used_percent` with dimensions:
- `path=/`
- `InstanceId=<resolved instance id>`
- `device=<root device>`
- `fstype=<root fs>`
and fail unless latest timestamp is within the last 10 minutes.

## Acceptance evidence (this run)
- Latest metric timestamp observed: `2026-05-15T22:34:00-04:00`.
- Latest value observed: `7.830800105669917`.
- Freshness gate: `FRESH_WITHIN_10M=true`.
