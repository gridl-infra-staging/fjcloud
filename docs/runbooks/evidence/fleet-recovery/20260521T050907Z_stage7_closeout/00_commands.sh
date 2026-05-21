#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../../../.." && pwd)"
cd "$REPO_ROOT"

EVID_DIR="$(cd "$(dirname "$0")" && pwd)"

run_with_timeout() {
  local timeout_seconds="$1"
  shift

  "$@" &
  local cmd_pid=$!
  local elapsed=0

  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$cmd_pid" 2>/dev/null || true
      wait "$cmd_pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$cmd_pid"
}

export FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
source "$REPO_ROOT/scripts/lib/env.sh"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
load_env_file "$FJCLOUD_SECRET_FILE"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION

run_with_timeout 1800 bash "$REPO_ROOT/scripts/validate_full_vm_lifecycle_prod.sh" run-a \
  > "$EVID_DIR/prod_run_a.txt" 2>&1

run_with_timeout 600 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" prod customer-loop \
  > "$EVID_DIR/prod_customer_loop_invoke.txt" 2>&1

run_with_timeout 600 bash "$REPO_ROOT/scripts/canary/contracts/lambda_canary_invoke_contract.sh" prod support-email \
  > "$EVID_DIR/prod_support_email_invoke.txt" 2>&1

run_with_timeout 600 bash "$EVID_DIR/10_verify_state.sh" \
  > "$EVID_DIR/prod_monitoring_verify.txt" 2>&1
