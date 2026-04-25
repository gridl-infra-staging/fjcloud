#!/usr/bin/env bash
# Static content tests for infrastructure runbooks.
# TDD red phase for Task 5 — Backend Runbook Finalization.
#
# These tests assert that each required runbook exists and contains
# the key commands, sections, and procedures documented in the checklist.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

dns_runbook="docs/runbooks/infra-dns-cutover.md"
deploy_runbook="docs/runbooks/infra-deploy-rollback.md"
terraform_runbook="docs/runbooks/infra-terraform-apply.md"
alarm_runbook="docs/runbooks/infra-alarm-triage.md"
bootstrap_doc="ops/BOOTSTRAP.md"
old_deploy_runbook="docs/runbooks/api-deployment.md"
database_recovery_runbook="docs/runbooks/database-backup-recovery.md"
restore_drill_script="ops/scripts/rds_restore_drill.sh"
launch_runbook="docs/runbooks/launch-backend.md"

echo ""
echo "=== Runbook Static Tests ==="
echo ""

# ---------------------------------------------------------------------------
# infra-dns-cutover.md
# ---------------------------------------------------------------------------

echo "--- DNS cutover runbook ---"
assert_file_exists "$dns_runbook" "infra-dns-cutover.md exists"
assert_file_contains "$dns_runbook" 'flapjack\.foo' "dns: references flapjack.foo domain"
assert_file_contains "$dns_runbook" 'Cloudflare' "dns: references Cloudflare"
assert_file_contains "$dns_runbook" 'CLOUDFLARE_API_TOKEN' "dns: documents CLOUDFLARE_API_TOKEN"
assert_file_contains "$dns_runbook" 'CLOUDFLARE_ZONE_ID' "dns: documents CLOUDFLARE_ZONE_ID"
assert_file_contains "$dns_runbook" 'CLOUDFLARE_EDIT_READ_ZONE_DNS_API_TOKEN_FLAPJACK_FOO' "dns: documents flapjack.foo token alias"
assert_file_contains "$dns_runbook" 'CLOUDFLARE_ZONE_ID_FLAPJACK_FOO' "dns: documents flapjack.foo zone-id alias"
assert_file_contains "$dns_runbook" 'api.cloudflare.com/client/v4/zones' "dns: Cloudflare zone API command"
assert_file_contains "$dns_runbook" 'terraform plan' "dns: Terraform plan command"
assert_file_contains "$dns_runbook" 'cloudflare_dns_record' "dns: Terraform Cloudflare DNS resource referenced"
assert_file_contains "$dns_runbook" 'ACM|acm|certificate' "dns: ACM cert validation unblock"
assert_file_contains "$dns_runbook" 'SES|DKIM|_domainkey' "dns: SES/DKIM validation unblock"
assert_file_contains "$dns_runbook" '[Rr]ollback' "dns: rollback path documented"
assert_file_contains "$dns_runbook" 'tests_stage7_runtime_smoke' "dns: runtime smoke validation command"
assert_file_not_contains "$dns_runbook" 'aws_route53_zone|aws route53|awsdns|Porkbun → Route53' "dns: no Route53 public-zone instructions"

echo ""

# ---------------------------------------------------------------------------
# infra-deploy-rollback.md
# ---------------------------------------------------------------------------

echo "--- Deploy/rollback runbook ---"
assert_file_exists "$deploy_runbook" "infra-deploy-rollback.md exists"
assert_file_contains "$deploy_runbook" 'deploy\.sh' "deploy: references deploy.sh"
assert_file_contains "$deploy_runbook" 'rollback\.sh' "deploy: references rollback.sh"
assert_file_contains "$deploy_runbook" 'migrate\.sh' "deploy: references migrate.sh"
assert_file_contains "$deploy_runbook" '/health' "deploy: health check endpoint"
assert_file_contains "$deploy_runbook" 'last_deploy_sha' "deploy: SSM last_deploy_sha param"
assert_file_contains "$deploy_runbook" 'SSM|ssm' "deploy: SSM-based deployment"
assert_file_contains "$deploy_runbook" 'fjcloud-releases' "deploy: S3 releases bucket"
assert_file_contains "$deploy_runbook" 'ssm send-command|send-command' "deploy: SSM send-command usage"
assert_file_contains "$deploy_runbook" 'ssm get-command-invocation|get-command-invocation' "deploy: SSM command status polling"
assert_file_contains "$deploy_runbook" '[Pp]re-deploy' "deploy: pre-deploy checklist"
assert_file_contains "$deploy_runbook" '[Tt]roubleshoot' "deploy: troubleshooting section"
assert_file_contains "$deploy_runbook" 'systemctl' "deploy: service restart via systemctl"

echo ""

# ---------------------------------------------------------------------------
# infra-terraform-apply.md
# ---------------------------------------------------------------------------

echo "--- Terraform apply runbook ---"
assert_file_exists "$terraform_runbook" "infra-terraform-apply.md exists"
assert_file_contains "$terraform_runbook" 'terraform init' "terraform: init command"
assert_file_contains "$terraform_runbook" 'terraform plan' "terraform: plan command"
assert_file_contains "$terraform_runbook" 'terraform apply' "terraform: apply command"
assert_file_contains "$terraform_runbook" 'backend-config' "terraform: backend config flags"
assert_file_contains "$terraform_runbook" 'fjcloud-tfstate' "terraform: S3 state bucket name"
assert_file_contains "$terraform_runbook" 'fjcloud-tflock' "terraform: DynamoDB lock table"
assert_file_contains "$terraform_runbook" 'terraform destroy -target|destroy -target' "terraform: targeted destroy for rollback"
assert_file_contains "$terraform_runbook" 'terraform state' "terraform: state commands for recovery"
assert_file_contains "$terraform_runbook" 'tests_stage7_runtime_smoke' "terraform: runtime smoke script reference"
assert_file_contains "$terraform_runbook" 'staging|prod' "terraform: environment references"
assert_file_contains "$terraform_runbook" '[Rr]ollback' "terraform: rollback procedure documented"

echo ""

# ---------------------------------------------------------------------------
# infra-alarm-triage.md
# ---------------------------------------------------------------------------

echo "--- Alarm triage runbook ---"
assert_file_exists "$alarm_runbook" "infra-alarm-triage.md exists"

# All 6 alarm types with full naming convention
assert_file_contains "$alarm_runbook" 'api-cpu-high' "alarm: api-cpu-high alarm"
assert_file_contains "$alarm_runbook" 'api-status-check-failed' "alarm: api-status-check-failed alarm"
assert_file_contains "$alarm_runbook" 'rds-cpu-high' "alarm: rds-cpu-high alarm"
assert_file_contains "$alarm_runbook" 'rds-free-storage-low' "alarm: rds-free-storage-low alarm"
assert_file_contains "$alarm_runbook" 'alb-5xx-error-rate' "alarm: alb-5xx-error-rate alarm"
assert_file_contains "$alarm_runbook" 'alb-p99-target-response-time' "alarm: alb-p99-target-response-time alarm"

# Naming convention
assert_file_contains "$alarm_runbook" 'fjcloud-.*-' "alarm: fjcloud naming convention"

# Thresholds (from monitoring/main.tf)
assert_file_contains "$alarm_runbook" '80%|80 ?%' "alarm: 80% CPU threshold"
assert_file_contains "$alarm_runbook" '2 ?GiB|2147483648|2 GB' "alarm: 2 GiB storage threshold"
assert_file_contains "$alarm_runbook" '1%|1 ?%' "alarm: 1% 5XX error rate threshold"
assert_file_contains "$alarm_runbook" '2s|2 seconds|> 2' "alarm: 2s p99 response time threshold"

# SNS topic
assert_file_contains "$alarm_runbook" 'SNS|sns' "alarm: SNS topic referenced"
assert_file_contains "$alarm_runbook" 'fjcloud-alerts' "alarm: SNS topic name"

# Investigation steps for each alarm type
assert_file_contains "$alarm_runbook" 'Performance Insights|performance_insights|slow quer' "alarm: RDS slow query investigation"
assert_file_contains "$alarm_runbook" 'StatusCheckFailed|status.check|reachability' "alarm: status check investigation"
assert_file_contains "$alarm_runbook" 'aws cloudwatch describe-alarms' "alarm: uses describe-alarms for investigation"
assert_file_contains "$alarm_runbook" 'aws cloudwatch describe-alarm-history' "alarm: uses describe-alarm-history for investigation"
assert_file_contains "$alarm_runbook" '/aws/rds/instance/fjcloud-<env>/postgresql' "alarm: uses canonical RDS PostgreSQL log group path"
assert_file_contains "$alarm_runbook" 'journalctl -u fjcloud-api' "alarm: uses host journalctl API evidence"
assert_file_not_contains "$alarm_runbook" 'API application logs are centralized in CloudWatch|CloudWatch is the source of truth for API application logs' "alarm: no centralized API log pipeline claim"
assert_file_contains "$alarm_runbook" '[Ee]scalation' "alarm: escalation path"

echo ""

# ---------------------------------------------------------------------------
# launch-backend.md
# ---------------------------------------------------------------------------

echo "--- Launch backend runbook ---"
assert_file_exists "$launch_runbook" "launch-backend.md exists"
assert_file_contains "$launch_runbook" 'bash scripts/validate-stripe\.sh' "launch: stripe validation command documented"
assert_file_contains "$launch_runbook" 'Load `STRIPE_SECRET_KEY` into the current shell or session manager' "launch: stripe secret loaded via environment/session manager guidance"
assert_file_not_contains "$launch_runbook" 'STRIPE_SECRET_KEY=' "launch: no inline Stripe secret assignment example"
assert_file_contains "$launch_runbook" 'bash scripts/validate-metering\.sh' "launch: metering validation command documented"
assert_file_contains "$launch_runbook" 'Load `DATABASE_URL` or `INTEGRATION_DB_URL` into the current shell or session manager' "launch: database credential loaded via environment/session manager guidance"
assert_file_not_contains "$launch_runbook" 'DATABASE_URL=' "launch: no inline database credential assignment example"

echo ""

# ---------------------------------------------------------------------------
# BOOTSTRAP.md — updated to reference automation scripts
# ---------------------------------------------------------------------------

echo "--- BOOTSTRAP.md references ---"
assert_file_contains "$bootstrap_doc" 'provision_bootstrap\.sh' "bootstrap: references provision_bootstrap.sh"
assert_file_contains "$bootstrap_doc" 'validate_bootstrap\.sh' "bootstrap: references validate_bootstrap.sh"

echo ""

# ---------------------------------------------------------------------------
# api-deployment.md — deprecation notice
# ---------------------------------------------------------------------------

echo "--- api-deployment.md deprecation ---"
assert_file_exists "$old_deploy_runbook" "api-deployment.md still exists"
assert_file_contains "$old_deploy_runbook" '[Dd]eprecated|DEPRECATED|superseded|SUPERSEDED' "api-deployment.md has deprecation notice"
assert_file_contains "$old_deploy_runbook" 'infra-deploy-rollback' "api-deployment.md points to new runbook"

echo ""

# ---------------------------------------------------------------------------
# database-backup-recovery.md
# ---------------------------------------------------------------------------

echo "--- Database backup/recovery runbook ---"
assert_file_exists "$database_recovery_runbook" "database-backup-recovery.md exists"
assert_file_exists "$restore_drill_script" "rds_restore_drill.sh exists"

assert_file_contains "$database_recovery_runbook" 'bash ops/scripts/rds_restore_drill\.sh staging\|prod' "database recovery: script-first staging|prod command documented"
assert_file_contains "$database_recovery_runbook" '\-\-source-db-instance-id' "database recovery: source DB instance argument documented"
assert_file_contains "$database_recovery_runbook" '\-\-target-db-instance-id' "database recovery: target DB instance argument documented"
assert_file_contains "$database_recovery_runbook" '\-\-snapshot-id' "database recovery: snapshot selector documented"
assert_file_contains "$database_recovery_runbook" '\-\-restore-time' "database recovery: PITR selector documented"
assert_file_contains "$database_recovery_runbook" 'RDS_RESTORE_DRILL_EXECUTE=1' "database recovery: execute gate documented"
assert_file_contains "$database_recovery_runbook" 'docs/env-vars\.md' "database recovery: env var reference documented"
assert_file_contains "$database_recovery_runbook" 'must be different' "database recovery: source and target DB identifiers must differ"
assert_file_contains "$database_recovery_runbook" 'exactly one restore mode selector' "database recovery: exactly-one restore selector documented"
assert_file_contains "$database_recovery_runbook" 'SELECT COUNT\(\*\) AS customers_total FROM customers;' "database recovery: customers sanity query documented (canonical schema)"
assert_file_contains "$database_recovery_runbook" 'SELECT COUNT\(\*\) AS invoices_last_7d FROM invoices WHERE created_at > now\(\) - interval '\''7 days'\'';' "database recovery: invoice recency sanity query documented"
assert_file_contains "$database_recovery_runbook" 'SELECT COUNT\(\*\) AS deployments_running FROM customer_deployments WHERE status = '\''running'\'';' "database recovery: deployment sanity query documented (canonical schema)"
assert_file_contains "$database_recovery_runbook" 'SELECT COUNT\(\*\) AS usage_records_last_1d FROM usage_records WHERE recorded_at > now\(\) - interval '\''1 day'\'';' "database recovery: usage sanity query documented"
assert_file_contains "$database_recovery_runbook" 'docs/runbooks/evidence/database-recovery/' "database recovery: evidence path documented"
assert_file_contains "$database_recovery_runbook" 'must not mutate `/fjcloud/<env>/database_url`' "database recovery: SSM database_url cutover boundary documented"
assert_file_contains "$database_recovery_runbook" 'must not restart services' "database recovery: restart boundary documented"
assert_file_contains "$database_recovery_runbook" 'must not update `DATABASE_URL`' "database recovery: DATABASE_URL boundary documented"

assert_file_contains "$restore_drill_script" 'Dry run: no restore API call dispatched\.' "rds_restore_drill.sh defaults to dry-run"
assert_file_contains "$restore_drill_script" 'RDS_RESTORE_DRILL_EXECUTE=1' "rds_restore_drill.sh execute gate is RDS_RESTORE_DRILL_EXECUTE=1"
assert_file_contains "$restore_drill_script" 'must be different' "rds_restore_drill.sh enforces source/target DB instance difference"
assert_file_contains "$restore_drill_script" 'provide exactly one restore mode selector' "rds_restore_drill.sh enforces exactly-one restore selector"
assert_file_contains "$restore_drill_script" 'handle cutover separately' "rds_restore_drill.sh documents no implicit cutover"

echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

test_summary "Runbook Static Tests"
