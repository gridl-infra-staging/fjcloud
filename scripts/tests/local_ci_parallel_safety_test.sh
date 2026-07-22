#!/usr/bin/env bash
# Regression coverage for local-ci gates that mutate repository-local state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"
LOCAL_CI_TEXT="$(cat "$LOCAL_CI")"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

first_match_line() {
  local pattern="$1"
  grep -n -m1 -E -- "$pattern" "$LOCAL_CI" | cut -d: -f1 || true
}

assert_line_after() {
  local earlier_line="$1" later_line="$2" msg="$3"
  if [ -n "$earlier_line" ] \
    && [ -n "$later_line" ] \
    && [ "$later_line" -gt "$earlier_line" ]; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

test_bootstrap_env_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule validate-bootstrap-env-local" \
    "bootstrap env gate must not join the parallel gate batch"
}

test_web_test_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule web-test" \
    "web-test must not join the parallel gate batch"
}

test_bootstrap_env_gate_runs_after_parallel_wait() {
  local parallel_wait_line sequential_gate_line
  parallel_wait_line="$(first_match_line '^[[:space:]]*wait$')"
  sequential_gate_line="$(first_match_line 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local')"

  assert_line_after "$parallel_wait_line" "$sequential_gate_line" \
    "bootstrap env gate starts after the parallel batch completes"
}

test_web_test_gate_runs_after_parallel_wait_before_bootstrap_env() {
  local parallel_wait_line web_test_line bootstrap_line
  parallel_wait_line="$(first_match_line '^[[:space:]]*wait$')"
  web_test_line="$(first_match_line 'run_gate web-test gate_web_test')"
  bootstrap_line="$(first_match_line 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local')"

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
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "validate-bootstrap-env-local' \
    "bootstrap env gate remains selectable through --gate"
}

test_web_test_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "web-test' \
    "web-test remains selectable through --gate"
}

test_rust_test_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule rust-test" \
    "rust-test must not join the parallel gate batch"
}

test_rust_test_gate_runs_after_bootstrap_env() {
  local bootstrap_line rust_test_line
  bootstrap_line="$(first_match_line 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local')"
  rust_test_line="$(first_match_line 'run_gate rust-test gate_rust_test')"

  assert_line_after "$bootstrap_line" "$rust_test_line" \
    "rust-test starts after bootstrap env in the sequential lane"
}

test_rust_test_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "rust-test' \
    "rust-test remains selectable through --gate"
}

test_rust_test_full_mode_sequential_path_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'elif [ "$MODE" = "full" ] && [ -z "$SINGLE_GATE" ]; then' \
    "rust-test remains scheduled sequentially in --full mode"
}

test_bootstrap_env_gate_is_not_scheduled_in_parallel
test_web_test_gate_is_not_scheduled_in_parallel
test_bootstrap_env_gate_runs_after_parallel_wait
test_web_test_gate_runs_after_parallel_wait_before_bootstrap_env
test_bootstrap_env_single_gate_mode_remains_supported
test_web_test_single_gate_mode_remains_supported
test_rust_test_gate_is_not_scheduled_in_parallel
test_rust_test_gate_runs_after_bootstrap_env
test_rust_test_single_gate_mode_remains_supported
test_rust_test_full_mode_sequential_path_remains_supported
run_test_summary
