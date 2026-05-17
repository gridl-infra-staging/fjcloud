# Prod Alarm Gap Closure Evidence

- Scope: Stage 3 immutable evidence bundle for prod CloudWatch alarm-gap closure.
- Capture timestamp (UTC): 2026-05-16T03:40:00Z
- Environment: prod
- Canonical alarm owners:
  - ops/terraform/monitoring/main.tf
  - ops/terraform/monitoring/outputs.tf

## Expected Alarm Names

- fjcloud-prod-api-root-disk-high
- fjcloud-prod-rds-connections-high
- fjcloud-prod-alb-unhealthy-hosts
- fjcloud-prod-customer-loop-canary-lambda-errors

## Commands Used

- CloudWatch inventory command:
  - aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix fjcloud-prod-
- Terraform evidence command (existing _shared entrypoint):
  - terraform plan -input=false -var='env=prod' -var='ami_id=ami-078228dbe86117d85' -var='cloudflare_zone_id=fafbf95a076d7e8ee984dbd18a62c933' -var='alert_emails=["redacted-alert@example.invalid"]' -target='module.monitoring.aws_cloudwatch_metric_alarm.api_root_disk_high' -target='module.monitoring.aws_cloudwatch_metric_alarm.rds_connections_high' -target='module.monitoring.aws_cloudwatch_metric_alarm.alb_unhealthy_hosts' -target='module.monitoring.aws_cloudwatch_metric_alarm.customer_loop_canary_lambda_errors'
- SNS delivery probe command flow (captured in transcript):
  - aws sqs create-queue ...
  - aws sns subscribe ...
  - aws cloudwatch set-alarm-state --alarm-name fjcloud-prod-customer-loop-canary-lambda-errors --state-value ALARM ...
  - aws sqs receive-message ... (message body contains matching AlarmName)
  - aws cloudwatch set-alarm-state --alarm-name fjcloud-prod-customer-loop-canary-lambda-errors --state-value OK ...

## Artifact Index

- alarms_describe.json
- alarms_describe_table.txt
- alarms_describe_tsv.txt
- tf_init.log
- tf_stage2_alarm_plan.log
- tf_plan_exit_code.txt
- tf_command.txt
- sns_probe_transcript.txt
- sns_probe_receive_message.json
- validate_bundle.sh
- validation_result_red.txt
- validation_result.txt

## Validation Verdict

- validate_bundle.sh verdict: PASS
- Stored result file: validation_result.txt (exit_code=0)
- Validation criteria: all four expected alarm names must be present in captured artifacts.
