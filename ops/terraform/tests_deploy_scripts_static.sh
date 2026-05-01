#!/usr/bin/env bash
# Static contract tests for ops/scripts/{deploy,migrate,rollback}.sh
# TDD red phase for Task 3 — Deploy/Migrate/Rollback Runtime Smoke
#
# These tests validate structural correctness of the deploy scripts
# without requiring AWS credentials or live infrastructure.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

deploy_file="ops/scripts/deploy.sh"
migrate_file="ops/scripts/migrate.sh"
rollback_file="ops/scripts/rollback.sh"
cleanup_file="ops/scripts/cleanup_api_server_metering_ghost.sh"

assert_text_contains() {
  local text="$1"
  local pattern="$2"
  local label="$3"
  if printf '%s\n' "$text" | rg -q "$pattern"; then
    pass "$label"
  else
    fail "$label"
  fi
}

echo ""
echo "=== Deploy Scripts Static Tests ==="
echo ""

# ---------------------------------------------------------------------------
# deploy.sh
# ---------------------------------------------------------------------------

echo "--- deploy.sh: file and arg validation ---"
assert_file_exists "$deploy_file" "deploy.sh exists"
assert_file_contains "$deploy_file" 'set -euo pipefail' "deploy.sh uses strict mode"
assert_file_contains "$deploy_file" 'Usage: deploy\.sh <env> <git-sha>' "deploy.sh documents usage"
assert_file_contains "$deploy_file" '"staging" && "\$ENV" != "prod"' "deploy.sh validates env is staging|prod"
assert_file_contains "$deploy_file" '\[0-9a-f\]\{40\}' "deploy.sh validates SHA is 40-char hex"

echo ""
echo "--- deploy.sh: instance discovery ---"
assert_file_contains "$deploy_file" 'aws ec2 describe-instances' "deploy.sh discovers instance via EC2 API"
assert_file_contains "$deploy_file" 'tag:Name,Values=fjcloud-api-' "deploy.sh filters by fjcloud-api Name tag"
assert_file_contains "$deploy_file" 'instance-state-name,Values=running' "deploy.sh filters for running instances only"

echo ""
echo "--- deploy.sh: SSM-based deployment (no SSH) ---"
assert_file_contains "$deploy_file" 'aws ssm send-command' "deploy.sh uses SSM for remote execution"
assert_file_contains "$deploy_file" 'AWS-RunShellScript' "deploy.sh uses RunShellScript document"
assert_file_not_contains "$deploy_file" 'ssh ' "deploy.sh does not use SSH"

echo ""
echo "--- deploy.sh: canary quiet-window control-plane contract ---"
assert_file_contains "$deploy_file" 'SSM_CANARY_QUIET_UNTIL="/fjcloud/\$\{ENV\}/canary_quiet_until"' "deploy.sh defines SSM param path for canary quiet-window"
assert_file_contains "$deploy_file" 'CANARY_QUIET_UNTIL=' "deploy.sh computes a canary quiet-window value"
assert_file_contains "$deploy_file" 'aws ssm put-parameter' "deploy.sh writes canary quiet-window from caller side via SSM put-parameter"
assert_file_contains "$deploy_file" '[[:space:]]--name "\$SSM_CANARY_QUIET_UNTIL"' "deploy.sh targets canary quiet-window key during caller-side SSM write"
assert_file_contains "$deploy_file" 'strftime\("%Y-%m-%dT%H:%M:%SZ"\)' "deploy.sh quiet-window timestamp uses canonical UTC RFC3339 Zulu format"

quiet_write_line=$(rg -n -- '--name "\$SSM_CANARY_QUIET_UNTIL"' "$deploy_file" | head -1 | cut -d: -f1 || true)
send_command_line=$(rg -n 'aws ssm send-command' "$deploy_file" | head -1 | cut -d: -f1 || true)
if [[ -n "$quiet_write_line" && -n "$send_command_line" && "$quiet_write_line" -lt "$send_command_line" ]]; then
  pass "deploy.sh writes canary quiet-window before remote SSM send-command"
else
  fail "deploy.sh writes canary quiet-window before remote SSM send-command"
fi

source_count="$( (rg -n '^[[:space:]]*source \"\$SCRIPT_DIR/lib/' "$deploy_file" || true) | wc -l | tr -d '[:space:]')"
if [[ "$source_count" == "1" ]]; then
  pass "deploy.sh keeps deploy_validation.sh as the only sourced deploy helper owner"
else
  fail "deploy.sh keeps deploy_validation.sh as the only sourced deploy helper owner"
fi

echo ""
echo "--- deploy.sh: rollback safety ---"
assert_file_contains "$deploy_file" 'SSM_LAST_SHA="/fjcloud/.*last_deploy_sha"' "deploy.sh defines SSM param path for last deploy SHA"
assert_file_contains "$deploy_file" 'aws ssm get-parameter' "deploy.sh reads previous SHA from SSM"
assert_file_contains "$deploy_file" 'aws ssm put-parameter' "deploy.sh saves current SHA to SSM"

echo ""
echo "--- deploy.sh: on-instance script contract ---"
assert_file_contains "$deploy_file" 'aws s3 cp.*s3://.*\.new' "on-instance: downloads binaries as .new from S3"
assert_file_contains "$deploy_file" 'aws s3 sync.*migrations' "on-instance: syncs migrations from S3"
assert_file_contains "$deploy_file" 'generate_ssm_env\.sh.*\$ENV' "on-instance: refreshes runtime envs from SSM before restart"
assert_file_contains "$deploy_file" '/etc/fjcloud/metering-env' "on-instance: writes metering env contract path"
assert_file_contains "$deploy_file" 'SLACK_WEBHOOK_URL' "on-instance: metering env refresh includes Slack webhook var"
assert_file_contains "$deploy_file" 'DISCORD_WEBHOOK_URL' "on-instance: metering env refresh includes Discord webhook var"
assert_file_contains "$deploy_file" 'migrate\.sh.*\$ENV' "on-instance: runs migrations before binary swap"
assert_file_contains "$deploy_file" 'mv.*\.new.*\$\{BIN_DIR\}' "on-instance: atomic binary swap via mv"
assert_file_contains "$deploy_file" 'systemctl restart fjcloud-api' "on-instance: restarts fjcloud-api service"
assert_file_contains "$deploy_file" 'curl -sf http://127\.0\.0\.1:3001/health' "on-instance: health check on localhost:3001"
assert_file_contains "$deploy_file" '\.old' "on-instance: backs up current binaries as .old"
assert_file_contains "$deploy_file" 'Health check FAILED.*rolling back' "on-instance: rolls back on health check failure"
assert_file_not_contains "$deploy_file" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job fj-metering-agent\)' "on-instance target contract: deploy.sh must not keep fj-metering-agent in API-host BINARIES"
assert_file_not_contains "$deploy_file" 'aws s3 cp.*fj-metering-agent\.service' "on-instance target contract: deploy.sh must not download fj-metering-agent unit on API host"
assert_file_not_contains "$deploy_file" 'install -m 0644.*fj-metering-agent\.service.*\/etc\/systemd\/system\/fj-metering-agent\.service' "on-instance target contract: deploy.sh must not install fj-metering-agent unit on API host"
assert_file_not_contains "$deploy_file" 'systemctl enable fj-metering-agent' "on-instance target contract: deploy.sh must not enable fj-metering-agent on API host"
assert_file_not_contains "$deploy_file" 'systemctl restart fj-metering-agent' "on-instance target contract: deploy.sh must not restart fj-metering-agent on API host"

echo ""
echo "--- deploy.sh: SSM polling and failure handling ---"
assert_file_contains "$deploy_file" 'aws ssm get-command-invocation' "deploy.sh polls SSM command status"
assert_file_contains "$deploy_file" 'Failed|TimedOut|Cancelled' "deploy.sh handles SSM failure states"

# ---------------------------------------------------------------------------
# migrate.sh
# ---------------------------------------------------------------------------

echo ""
echo "--- migrate.sh: file and arg validation ---"
assert_file_exists "$migrate_file" "migrate.sh exists"
assert_file_contains "$migrate_file" 'set -euo pipefail' "migrate.sh uses strict mode"
assert_file_contains "$migrate_file" 'Usage: migrate\.sh <env>' "migrate.sh documents usage"
assert_file_contains "$migrate_file" '"staging" && "\$ENV" != "prod"' "migrate.sh validates env is staging|prod"

echo ""
echo "--- migrate.sh: SSM credential fetch ---"
assert_file_contains "$migrate_file" 'aws ssm get-parameter' "migrate.sh fetches DATABASE_URL from SSM"
assert_file_contains "$migrate_file" 'with-decryption' "migrate.sh decrypts SSM parameter"
assert_file_contains "$migrate_file" '/fjcloud/.*database_url' "migrate.sh uses namespaced SSM path for DB URL"

echo ""
echo "--- migrate.sh: migration execution ---"
assert_file_contains "$migrate_file" 'sqlx migrate run' "migrate.sh runs sqlx migrations"
assert_file_contains "$migrate_file" '/opt/fjcloud/migrations' "migrate.sh uses standard migrations directory"
assert_file_not_contains "$migrate_file" 'DATABASE_URL=.*postgres://' "migrate.sh does not hardcode DATABASE_URL"

# ---------------------------------------------------------------------------
# rollback.sh
# ---------------------------------------------------------------------------

echo ""
echo "--- rollback.sh: file and arg validation ---"
assert_file_exists "$rollback_file" "rollback.sh exists"
assert_file_contains "$rollback_file" 'set -euo pipefail' "rollback.sh uses strict mode"
assert_file_contains "$rollback_file" 'Usage: rollback\.sh <env> <previous-sha>' "rollback.sh documents usage"
assert_file_contains "$rollback_file" '"staging" && "\$ENV" != "prod"' "rollback.sh validates env is staging|prod"
assert_file_contains "$rollback_file" '\[0-9a-f\]\{40\}' "rollback.sh validates SHA is 40-char hex"

echo ""
echo "--- rollback.sh: instance discovery ---"
assert_file_contains "$rollback_file" 'aws ec2 describe-instances' "rollback.sh discovers instance via EC2 API"
assert_file_contains "$rollback_file" 'tag:Name,Values=fjcloud-api-' "rollback.sh filters by fjcloud-api Name tag"

echo ""
echo "--- rollback.sh: SSM-based execution (no SSH) ---"
assert_file_contains "$rollback_file" 'aws ssm send-command' "rollback.sh uses SSM for remote execution"
assert_file_contains "$rollback_file" 'AWS-RunShellScript' "rollback.sh uses RunShellScript document"
assert_file_not_contains "$rollback_file" 'ssh ' "rollback.sh does not use SSH"

echo ""
echo "--- rollback.sh: no migrations on rollback ---"
# The rollback script itself should NOT call migrate.sh or sqlx.
# Migrations are forward-only — rolling back code without rolling back schema.
assert_file_not_contains "$rollback_file" 'migrate\.sh' "rollback.sh does NOT run migrations (forward-only)"
assert_file_not_contains "$rollback_file" 'sqlx' "rollback.sh does NOT invoke sqlx"

echo ""
echo "--- rollback.sh: on-instance script contract ---"
assert_file_contains "$rollback_file" 'aws s3 cp.*s3://.*\.new' "on-instance: downloads previous binaries from S3"
assert_file_contains "$rollback_file" 'mv.*\.new.*\$\{BIN_DIR\}' "on-instance: atomic binary swap via mv"
assert_file_contains "$rollback_file" 'systemctl restart fjcloud-api' "on-instance: restarts fjcloud-api service"
assert_file_contains "$rollback_file" 'curl -sf http://127\.0\.0\.1:3001/health' "on-instance: health check on localhost:3001"
assert_file_contains "$rollback_file" '\.old' "on-instance: backs up current binaries as .old"
assert_file_contains "$rollback_file" 'Health check FAILED' "on-instance: detects health check failure"
assert_file_not_contains "$rollback_file" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job fj-metering-agent\)' "on-instance target contract: rollback.sh must not keep fj-metering-agent in API-host BINARIES"
assert_file_not_contains "$rollback_file" 'aws s3 cp.*fj-metering-agent\.service' "on-instance target contract: rollback.sh must not download fj-metering-agent unit on API host"
assert_file_not_contains "$rollback_file" 'install -m 0644.*fj-metering-agent\.service.*\/etc\/systemd\/system\/fj-metering-agent\.service' "on-instance target contract: rollback.sh must not install fj-metering-agent unit on API host"
assert_file_not_contains "$rollback_file" 'systemctl enable fj-metering-agent' "on-instance target contract: rollback.sh must not enable fj-metering-agent on API host"
assert_file_not_contains "$rollback_file" 'systemctl restart fj-metering-agent' "on-instance target contract: rollback.sh must not restart fj-metering-agent on API host"

echo ""
echo "--- rollback.sh: SSM polling and SHA update ---"
assert_file_contains "$rollback_file" 'aws ssm get-command-invocation' "rollback.sh polls SSM command status"
assert_file_contains "$rollback_file" 'SSM_LAST_SHA="/fjcloud/.*last_deploy_sha"' "rollback.sh defines SSM param path for last deploy SHA"
assert_file_contains "$rollback_file" 'aws ssm put-parameter' "rollback.sh updates last_deploy_sha on success"
assert_file_contains "$rollback_file" 'Failed|TimedOut|Cancelled' "rollback.sh handles SSM failure states"

# ---------------------------------------------------------------------------
# Cross-script contract checks
# ---------------------------------------------------------------------------

echo ""
echo "--- Cross-script contracts ---"
# All three scripts should use the same region
assert_file_contains "$deploy_file" 'REGION="us-east-1"' "deploy.sh targets us-east-1"
assert_file_contains "$rollback_file" 'REGION="us-east-1"' "rollback.sh targets us-east-1"
assert_file_contains "$migrate_file" 'us-east-1' "migrate.sh targets us-east-1"

# Deploy and rollback should use the same S3 bucket naming
assert_file_contains "$deploy_file" 'S3_BUCKET="fjcloud-releases-\$\{ENV\}"' "deploy.sh uses env-scoped S3 bucket"
assert_file_contains "$rollback_file" 'S3_BUCKET="fjcloud-releases-\$\{ENV\}"' "rollback.sh uses same env-scoped S3 bucket"

# Deploy and rollback should use the same SSM param path
assert_file_contains "$deploy_file" 'SSM_LAST_SHA="/fjcloud/\$\{ENV\}/last_deploy_sha"' "deploy.sh uses standard SSM param path"
assert_file_contains "$rollback_file" 'SSM_LAST_SHA="/fjcloud/\$\{ENV\}/last_deploy_sha"' "rollback.sh uses same SSM param path"

# Both deploy and rollback should handle the same set of API-host binaries.
assert_file_contains "$deploy_file" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job\)' "deploy.sh target contract: manages exactly two API-host binaries"
assert_file_contains "$rollback_file" 'BINARIES=\(fjcloud-api fjcloud-aggregation-job\)' "rollback.sh target contract: manages exactly two API-host binaries"
assert_file_not_contains "$deploy_file" 'fjcloud-api fjcloud-aggregation-job fj-metering-agent' "deploy.sh target contract: must not include fj-metering-agent in API-host binary set"
assert_file_not_contains "$rollback_file" 'fjcloud-api fjcloud-aggregation-job fj-metering-agent' "rollback.sh target contract: must not include fj-metering-agent in API-host binary set"

echo ""
echo "--- cleanup_api_server_metering_ghost.sh: dry-run cleanup contract ---"
assert_file_exists "$cleanup_file" "cleanup_api_server_metering_ghost.sh exists"
assert_file_contains "$cleanup_file" 'set -euo pipefail' "cleanup script uses strict mode"
assert_file_contains "$cleanup_file" 'verify_host_identity\(\)' "cleanup script defines verify_host_identity owner"
assert_file_contains "$cleanup_file" 'verify_deployed_sha_gate\(\)' "cleanup script defines verify_deployed_sha_gate owner"
assert_file_contains "$cleanup_file" 'print_dry_run_plan\(\)' "cleanup script defines print_dry_run_plan owner"
assert_file_contains "$cleanup_file" 'run_live_cleanup\(\)' "cleanup script defines run_live_cleanup owner"
dry_run_output="$(bash "$cleanup_file" --dry-run)"
assert_text_contains "$dry_run_output" '\[dry-run\] verify API-server host identity via IMDSv2 \+ ec2:DescribeTags \[planned\]' "cleanup dry-run surfaces host identity gate step"
assert_text_contains "$dry_run_output" '\[dry-run\] verify deployed SHA gate \[planned\] source=/fjcloud/<env>/last_deploy_sha expected=' "cleanup dry-run surfaces SHA gate step"
assert_text_contains "$dry_run_output" '\[dry-run\] stop fj-metering-agent\.service \[planned\] systemctl stop when active' "cleanup dry-run surfaces stop action"
assert_text_contains "$dry_run_output" '\[dry-run\] disable fj-metering-agent\.service \[planned\] systemctl disable when enabled' "cleanup dry-run surfaces disable action"
assert_text_contains "$dry_run_output" '\[dry-run\] remove service unit \[(would-change|no-op)\]' "cleanup dry-run surfaces service-unit removal action"
assert_text_contains "$dry_run_output" '\[dry-run\] systemctl daemon-reload \[(planned|no-op)\] (run only when service-unit removal is active|skip when service-unit cleanup is no-op)' "cleanup dry-run surfaces daemon-reload sequencing tied to unit cleanup"
assert_text_contains "$dry_run_output" '\[dry-run\] remove metering env file \[(would-change|no-op)\]' "cleanup dry-run surfaces metering-env removal action"
assert_text_contains "$dry_run_output" '\[dry-run\] remove metering binary \[(would-change|no-op)\]' "cleanup dry-run surfaces metering binary removal action"
assert_text_contains "$dry_run_output" '\[dry-run\] remove metering backup binary \[(would-change|no-op)\]' "cleanup dry-run surfaces metering backup removal action"

test_summary "Deploy scripts static checks"
