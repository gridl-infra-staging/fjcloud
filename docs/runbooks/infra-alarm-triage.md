# CloudWatch Alarm Triage

Investigation procedures for fjcloud CloudWatch alarms. All alarms follow the naming convention `fjcloud-${env}-<alarm-suffix>` and notify via SNS topic `fjcloud-alerts-${env}`.

## Observability Scope

- CloudWatch provides alarm state and alarm history for infrastructure metrics configured in `ops/terraform/monitoring/main.tf`.
- RDS PostgreSQL engine logs are exported to CloudWatch Logs by `enabled_cloudwatch_logs_exports = ["postgresql"]` in `ops/terraform/data/main.tf`; inspect only `/aws/rds/instance/fjcloud-<env>/postgresql` for those database logs.
- Backend service logs are instance-local systemd journals (`ops/systemd/fjcloud-api.service` and `ops/systemd/fj-metering-agent.service`); inspect with `aws ssm start-session --target <instance-id>` and `journalctl`.
- API application logs are not centralized in CloudWatch in this repo.

## Alarm State and History

Start every incident by checking current alarm state and recent alarm transitions:

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "fjcloud-${env}-" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Updated:StateUpdatedTimestamp}' \
  --output table

aws cloudwatch describe-alarm-history \
  --alarm-name "fjcloud-${env}-<alarm-suffix>" \
  --history-item-type StateUpdate \
  --max-items 20
```

## SNS Topic Verification

Verify the SNS topic exists and has subscribers:

```bash
# List topics
aws sns list-topics --query 'Topics[?contains(TopicArn, `fjcloud-alerts`)]'

# Check subscriptions
aws sns list-subscriptions-by-topic \
  --topic-arn "arn:aws:sns:us-east-1:<account-id>:fjcloud-alerts-staging"
```

To add a new email subscriber:

```bash
aws sns subscribe \
  --topic-arn "arn:aws:sns:us-east-1:<account-id>:fjcloud-alerts-staging" \
  --protocol email \
  --notification-endpoint support@flapjack.foo
```

The subscriber must confirm via the confirmation email.

---

## Alarm: `fjcloud-${env}-api-cpu-high`

**Threshold**: CPU > 80% sustained for 10 minutes (2 × 5m periods)
**Metric**: AWS/EC2 CPUUtilization (Average)

### Investigation

1. Check current CPU in CloudWatch console or CLI:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/EC2 \
     --metric-name CPUUtilization \
     --dimensions Name=InstanceId,Value=<instance-id> \
     --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 --statistics Average
   ```

2. SSH/SSM into the instance and identify hot processes:

   ```bash
   aws ssm start-session --target <instance-id>
   top -bn1 | head -20
   ```

3. Check if a recent deploy introduced a CPU regression

### Resolution

- If caused by traffic spike: consider scaling (larger instance type or adding instances)
- If caused by a bug: roll back the offending deploy with `ops/scripts/rollback.sh`
- If caused by runaway process: kill the process and investigate root cause

---

## Alarm: `fjcloud-${env}-api-status-check-failed`

**Threshold**: StatusCheckFailed ≥ 1 for 10 minutes (2 × 5m periods)
**Metric**: AWS/EC2 StatusCheckFailed (Maximum)

### Investigation

1. Check instance reachability from AWS console → EC2 → Instance → Status Checks

2. Check system logs:

   ```bash
   aws ec2 get-console-output --instance-id <instance-id> --output text
   ```

3. Check if the instance is reachable via SSM:
   ```bash
   aws ssm describe-instance-information \
     --filters "Key=InstanceIds,Values=<instance-id>"
   ```

### Resolution

- **Instance status check failed** (OS-level): Stop and start the instance (migrates to new hardware):

  ```bash
  aws ec2 stop-instances --instance-ids <instance-id>
  # Wait for stopped state
  aws ec2 start-instances --instance-ids <instance-id>
  ```

- **System status check failed** (AWS hardware): Same stop/start procedure

- If persistent: terminate and let Terraform recreate via `terraform apply`

---

## Alarm: `fjcloud-${env}-rds-cpu-high`

**Threshold**: CPU > 80% sustained for 10 minutes (2 × 5m periods)
**Metric**: AWS/RDS CPUUtilization (Average)

### Investigation

1. Check Performance Insights for slow queries (AWS Console → RDS → Performance Insights)

2. Check exported PostgreSQL engine logs in the canonical log group:

   ```bash
   aws logs tail "/aws/rds/instance/fjcloud-<env>/postgresql" --since 30m
   ```

3. Check active connections:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/RDS \
     --metric-name DatabaseConnections \
     --dimensions Name=DBInstanceIdentifier,Value=fjcloud-<env> \
     --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 --statistics Average
   ```

4. Check for long-running transactions (connect to DB):
   ```sql
   SELECT pid, now() - pg_stat_activity.query_start AS duration, query
   FROM pg_stat_activity
   WHERE state != 'idle'
   ORDER BY duration DESC
   LIMIT 10;
   ```

### Resolution

- Kill long-running queries: `SELECT pg_terminate_backend(<pid>);`
- If caused by missing index: add the index and deploy
- If sustained load: consider scaling up the RDS instance class

---

## Alarm: `fjcloud-${env}-rds-free-storage-low`

**Threshold**: FreeStorageSpace < 2 GiB (2,147,483,648 bytes) for 10 minutes (2 × 5m periods)
**Metric**: AWS/RDS FreeStorageSpace (Average)

### Investigation

1. Check current free space:

   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/RDS \
     --metric-name FreeStorageSpace \
     --dimensions Name=DBInstanceIdentifier,Value=fjcloud-<env> \
     --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 --statistics Average
   ```

2. Check exported PostgreSQL engine logs for vacuum/checkpoint/storage pressure signals:

   ```bash
   aws logs tail "/aws/rds/instance/fjcloud-<env>/postgresql" --since 30m
   ```

3. Check table sizes (connect to DB):

   ```sql
   SELECT schemaname, tablename,
          pg_size_pretty(pg_total_relation_size(schemaname || '.' || tablename)) AS total_size
   FROM pg_tables
   WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
   ORDER BY pg_total_relation_size(schemaname || '.' || tablename) DESC
   LIMIT 20;
   ```

4. Check bloat and vacuum status:
   ```sql
   SELECT relname, n_dead_tup, last_vacuum, last_autovacuum
   FROM pg_stat_user_tables
   ORDER BY n_dead_tup DESC
   LIMIT 10;
   ```

### Resolution

- Run manual vacuum if autovacuum is behind: `VACUUM ANALYZE <table>;`
- If data growth is legitimate: increase allocated storage via Terraform (`db_allocated_storage` variable) and `terraform apply`
- Delete old/unused data if applicable

---

## Alarm: `fjcloud-${env}-alb-5xx-error-rate`

**Threshold**: 5XX errors > 1% of total requests over 5 minutes (1 × 5m period)
**Metric**: Math expression `(HTTPCode_ELB_5XX_Count / RequestCount) * 100`

### Investigation

1. Confirm alarm state/history, then check API application logs on the host journal:

   ```bash
   aws cloudwatch describe-alarm-history \
     --alarm-name "fjcloud-${env}-alb-5xx-error-rate" \
     --history-item-type StateUpdate \
     --max-items 20
   aws ssm start-session --target <instance-id>
   journalctl -u fjcloud-api --since "30 minutes ago" --no-pager | grep -i error
   ```

2. Check ALB target health:

   ```bash
   aws elbv2 describe-target-health \
     --target-group-arn <target-group-arn>
   ```

3. Check if a recent deploy introduced the errors:

   ```bash
   aws ssm get-parameter --name "/fjcloud/<env>/last_deploy_sha" --query 'Parameter.Value' --output text
   ```

4. Check CloudWatch for the 5XX breakdown:
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/ApplicationELB \
     --metric-name HTTPCode_ELB_5XX_Count \
     --dimensions Name=LoadBalancer,Value=<alb-arn-suffix> \
     --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 --statistics Sum
   ```

### Resolution

- If caused by a bad deploy: rollback with `ops/scripts/rollback.sh`
- If target is unhealthy: check the instance and restart the service (`systemctl restart fjcloud-api`)
- If DB-related: check RDS alarms and DB connectivity

---

## Alarm: `fjcloud-${env}-alb-p99-target-response-time`

**Threshold**: P99 response time > 2s over 5 minutes (1 × 5m period)
**Metric**: AWS/ApplicationELB TargetResponseTime (p99)

### Investigation

1. Confirm alarm state/history, then identify slow endpoints from host API logs:

   ```bash
   aws cloudwatch describe-alarm-history \
     --alarm-name "fjcloud-${env}-alb-p99-target-response-time" \
     --history-item-type StateUpdate \
     --max-items 20
   aws ssm start-session --target <instance-id>
   journalctl -u fjcloud-api --since "30 minutes ago" --no-pager | grep -E 'duration.*[0-9]{4,}ms'
   ```

2. Check DB query times — slow queries are the most common cause:

   ```sql
   SELECT query, calls, mean_exec_time, total_exec_time
   FROM pg_stat_statements
   ORDER BY mean_exec_time DESC
   LIMIT 10;
   ```

3. Check connection pool saturation:
   ```bash
   aws cloudwatch get-metric-statistics \
     --namespace AWS/RDS \
     --metric-name DatabaseConnections \
     --dimensions Name=DBInstanceIdentifier,Value=fjcloud-<env> \
     --start-time $(date -u -v-1H +%Y-%m-%dT%H:%M:%S) \
     --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
     --period 300 --statistics Average
   ```

### Resolution

- If caused by slow queries: add missing indexes, optimize queries
- If caused by connection pool exhaustion: increase pool size in app config
- If caused by a bad deploy: rollback with `ops/scripts/rollback.sh`

---

## Escalation

If an alarm cannot be resolved within 30 minutes:

1. Check all related alarms — multiple firing alarms may indicate a systemic issue
2. Check AWS Health Dashboard for regional issues
3. Escalate to the team lead with:
   - Which alarm(s) fired
   - When they started
   - What investigation steps were taken
   - Current system state (instance running? DB accessible? ALB healthy?)
