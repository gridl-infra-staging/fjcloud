#!/usr/bin/env bash
# Regression coverage for local-ci gates that mutate repository-local state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

test_bootstrap_env_gate_is_not_scheduled_in_parallel() {
  local script_text
  script_text="$(cat "$LOCAL_CI")"

  assert_not_contains "$script_text" "schedule validate-bootstrap-env-local" \
    "bootstrap env gate must not join the parallel gate batch"
}

test_web_test_gate_is_not_scheduled_in_parallel() {
  local script_text
  script_text="$(cat "$LOCAL_CI")"

  assert_not_contains "$script_text" "schedule web-test" \
    "web-test must not join the parallel gate batch"
}

test_bootstrap_env_gate_runs_after_parallel_wait() {
  local parallel_wait_line sequential_gate_line
  parallel_wait_line="$(grep -n '^[[:space:]]*wait$' "$LOCAL_CI" | head -1 | cut -d: -f1)"
  sequential_gate_line="$(grep -n 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local' "$LOCAL_CI" | head -1 | cut -d: -f1)"

  if [ -n "$parallel_wait_line" ] \
    && [ -n "$sequential_gate_line" ] \
    && [ "$sequential_gate_line" -gt "$parallel_wait_line" ]; then
    pass "bootstrap env gate starts after the parallel batch completes"
  else
    fail "bootstrap env gate must start after the parallel batch wait"
  fi
}

test_web_test_gate_runs_after_parallel_wait_before_bootstrap_env() {
  local parallel_wait_line web_test_line bootstrap_line
  parallel_wait_line="$(grep -n '^[[:space:]]*wait$' "$LOCAL_CI" | head -1 | cut -d: -f1)"
  web_test_line="$(grep -n 'run_gate web-test gate_web_test' "$LOCAL_CI" | head -1 | cut -d: -f1)"
  bootstrap_line="$(grep -n 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local' "$LOCAL_CI" | head -1 | cut -d: -f1)"

  if [ -n "$parallel_wait_line" ] \
    && [ -n "$web_test_line" ] \
    && [ -n "$bootstrap_line" ] \
    && [ "$web_test_line" -gt "$parallel_wait_line" ] \
    && [ "$web_test_line" -lt "$bootstrap_line" ]; then
    pass "web-test starts after the parallel batch and before bootstrap env"
  else
    fail "web-test must start after the parallel batch wait and before bootstrap env"
  fi
}

test_bootstrap_env_single_gate_mode_remains_supported() {
  local script_text
  script_text="$(cat "$LOCAL_CI")"

  assert_contains "$script_text" 'SINGLE_GATE" = "validate-bootstrap-env-local' \
    "bootstrap env gate remains selectable through --gate"
}

test_web_test_single_gate_mode_remains_supported() {
  local script_text
  script_text="$(cat "$LOCAL_CI")"

  assert_contains "$script_text" 'SINGLE_GATE" = "web-test' \
    "web-test remains selectable through --gate"
}

test_bootstrap_env_gate_is_not_scheduled_in_parallel
test_web_test_gate_is_not_scheduled_in_parallel
test_bootstrap_env_gate_runs_after_parallel_wait
test_web_test_gate_runs_after_parallel_wait_before_bootstrap_env
test_bootstrap_env_single_gate_mode_remains_supported
test_web_test_single_gate_mode_remains_supported
run_test_summary
