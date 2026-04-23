#!/usr/bin/env bash
# Static contract tests for runtime assertions in tests_stage7_runtime_smoke.sh.
# Ensures runtime_fail(), exit codes, CLI args, and script invocations are wired
# and cannot be silently removed.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

runtime_smoke="ops/terraform/tests_stage7_runtime_smoke.sh"

echo ""
echo "=== Stage 7 Runtime Static Contract Tests ==="

echo ""
echo "--- Runtime exit code constants ---"
assert_file_contains "$runtime_smoke" 'EXIT_ACM_NOT_ISSUED=' "EXIT_ACM_NOT_ISSUED constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_ALB_NO_LISTENER=' "EXIT_ALB_NO_LISTENER constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_TG_UNHEALTHY=' "EXIT_TG_UNHEALTHY constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_HEALTH_FAIL=' "EXIT_HEALTH_FAIL constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_DNS_RECORD_MISMATCH=' "EXIT_DNS_RECORD_MISMATCH constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_SES_NOT_VERIFIED=' "EXIT_SES_NOT_VERIFIED constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_DEPLOY_HEALTH_FAIL=' "EXIT_DEPLOY_HEALTH_FAIL constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_MIGRATE_FAIL=' "EXIT_MIGRATE_FAIL constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_MIGRATE_IDEMPOTENCY=' "EXIT_MIGRATE_IDEMPOTENCY constant defined"
assert_file_contains "$runtime_smoke" 'EXIT_ROLLBACK_FAIL=' "EXIT_ROLLBACK_FAIL constant defined"

echo ""
echo "--- Shared runtime failure helper ---"
assert_file_contains "$runtime_smoke" 'runtime_fail()' "runtime_fail helper function defined"
assert_file_contains "$runtime_smoke" 'RUNTIME FAIL' "runtime_fail emits RUNTIME FAIL prefix"

echo ""
echo "--- FJCLOUD_SCRIPTS_DIR override wired ---"
assert_file_contains "$runtime_smoke" 'FJCLOUD_SCRIPTS_DIR' "FJCLOUD_SCRIPTS_DIR env var read"
assert_file_contains "$runtime_smoke" 'SCRIPTS_DIR' "SCRIPTS_DIR variable defined"

echo ""
echo "--- CLI args: --run-rollback and --rollback-sha ---"
assert_file_contains "$runtime_smoke" 'run-rollback' "--run-rollback arg accepted"
assert_file_contains "$runtime_smoke" 'rollback-sha' "--rollback-sha arg accepted"
assert_file_contains "$runtime_smoke" 'ROLLBACK_SHA' "ROLLBACK_SHA variable defined"
assert_file_contains "$runtime_smoke" 'RUN_ROLLBACK' "RUN_ROLLBACK flag defined"

echo ""
echo "--- ACM cert assertion wired ---"
assert_file_contains "$runtime_smoke" 'assert_acm_cert_issued' "assert_acm_cert_issued function defined"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_ACM_NOT_ISSUED"' "ACM failure uses EXIT_ACM_NOT_ISSUED"
assert_file_contains "$runtime_smoke" '"acm_not_issued"' "ACM failure class is acm_not_issued"

echo ""
echo "--- ALB HTTPS listener assertion wired ---"
assert_file_contains "$runtime_smoke" 'assert_alb_https_listener' "assert_alb_https_listener function defined"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_ALB_NO_LISTENER"' "ALB failure uses EXIT_ALB_NO_LISTENER"
assert_file_contains "$runtime_smoke" '"alb_no_listener"' "ALB failure class is alb_no_listener"

echo ""
echo "--- Target group health assertion wired ---"
assert_file_contains "$runtime_smoke" 'assert_target_group_healthy' "assert_target_group_healthy function defined"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_TG_UNHEALTHY"' "TG failure uses EXIT_TG_UNHEALTHY"
assert_file_contains "$runtime_smoke" '"tg_unhealthy"' "TG failure class is tg_unhealthy"
assert_file_contains "$runtime_smoke" 'TG_MAX_RETRIES' "TG retry count is configurable"
assert_file_contains "$runtime_smoke" 'TG_RETRY_INTERVAL' "TG retry interval is configurable"

echo ""
echo "--- Health endpoint check wired ---"
assert_file_contains "$runtime_smoke" 'assert_health_endpoint' "assert_health_endpoint function defined"
assert_file_contains "$runtime_smoke" 'EXIT_HEALTH_FAIL' "Health failure uses EXIT_HEALTH_FAIL"
assert_file_contains "$runtime_smoke" 'health_fail' "Health failure class is health_fail"
assert_file_contains "$runtime_smoke" 'HEALTH_URL' "HEALTH_URL variable defined"
assert_file_contains "$runtime_smoke" 'HEALTH_MAX_RETRIES' "Health retry count is configurable"

echo ""
echo "--- Cloudflare public record assertion wired ---"
assert_file_contains "$runtime_smoke" 'assert_cloudflare_public_records' "assert_cloudflare_public_records function defined"
assert_file_contains "$runtime_smoke" 'EXIT_DNS_RECORD_MISMATCH' "Cloudflare DNS record failure uses EXIT_DNS_RECORD_MISMATCH"
assert_file_contains "$runtime_smoke" 'dns_record_mismatch' "Cloudflare DNS record failure class is dns_record_mismatch"
assert_file_contains "$runtime_smoke" 'dns_records\?type=CNAME' "Cloudflare DNS records API queried"

echo ""
echo "--- SES identity assertion wired ---"
assert_file_contains "$runtime_smoke" 'assert_ses_identity_verified' "assert_ses_identity_verified function defined"
assert_file_contains "$runtime_smoke" 'aws sesv2 get-email-identity' "SES identity is queried"
assert_file_contains "$runtime_smoke" 'EXIT_SES_NOT_VERIFIED' "SES failure uses EXIT_SES_NOT_VERIFIED"
assert_file_contains "$runtime_smoke" 'ses_not_verified' "SES failure class is ses_not_verified"

echo ""
echo "--- Deploy pipeline wired ---"
assert_file_contains "$runtime_smoke" 'RUN_DEPLOY.*true' "RUN_DEPLOY flag gated"
assert_file_contains "$runtime_smoke" 'SCRIPTS_DIR.*deploy\.sh' "Deploy uses SCRIPTS_DIR"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_DEPLOY_HEALTH_FAIL"' "Deploy failure uses EXIT_DEPLOY_HEALTH_FAIL"
assert_file_contains "$runtime_smoke" '"deploy_health_fail"' "Deploy failure class is deploy_health_fail"

echo ""
echo "--- Migrate pipeline wired with idempotency ---"
assert_file_contains "$runtime_smoke" 'RUN_MIGRATE.*true' "RUN_MIGRATE flag gated"
assert_file_contains "$runtime_smoke" 'SCRIPTS_DIR.*migrate\.sh' "Migrate uses SCRIPTS_DIR"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_MIGRATE_FAIL"' "Migrate failure uses EXIT_MIGRATE_FAIL"
assert_file_contains "$runtime_smoke" '"migrate_fail"' "Migrate failure class is migrate_fail"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_MIGRATE_IDEMPOTENCY"' "Migrate idempotency uses EXIT_MIGRATE_IDEMPOTENCY"
assert_file_contains "$runtime_smoke" '"migrate_idempotency"' "Migrate idempotency class is migrate_idempotency"

echo ""
echo "--- Rollback pipeline wired ---"
assert_file_contains "$runtime_smoke" 'RUN_ROLLBACK.*true' "RUN_ROLLBACK flag gated"
assert_file_contains "$runtime_smoke" 'SCRIPTS_DIR.*rollback\.sh' "Rollback uses SCRIPTS_DIR"
assert_file_contains "$runtime_smoke" 'runtime_fail "\$EXIT_ROLLBACK_FAIL"' "Rollback failure uses EXIT_ROLLBACK_FAIL"
assert_file_contains "$runtime_smoke" '"rollback_fail"' "Rollback failure class is rollback_fail"

echo ""
echo "--- Runtime checks run after terraform init ---"

check_runs_after_terraform() {
  local pattern="$1"
  local label="$2"
  local check_line tf_line
  check_line=$(rg -n "$pattern" "$runtime_smoke" | head -1 | cut -d: -f1 || true)
  tf_line=$(rg -n 'terraform init' "$runtime_smoke" | head -1 | cut -d: -f1 || true)
  if [[ -n "$check_line" && -n "$tf_line" ]] && (( check_line > tf_line )); then
    pass "$label"
  else
    fail "$label (check at line ${check_line:-?}, terraform init at line ${tf_line:-?})"
  fi
}

check_runs_after_terraform 'assert_acm_cert_issued' "ACM check runs after terraform init"
check_runs_after_terraform 'assert_alb_https_listener' "ALB check runs after terraform init"
check_runs_after_terraform 'assert_target_group_healthy' "TG health check runs after terraform init"
check_runs_after_terraform 'assert_cloudflare_public_records' "Cloudflare DNS record check runs after terraform init"
check_runs_after_terraform 'assert_ses_identity_verified' "SES identity check runs after terraform init"
check_runs_after_terraform 'assert_health_endpoint' "Health endpoint check runs after terraform init"

test_summary "Stage 7 runtime static contract"
