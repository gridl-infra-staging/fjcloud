#!/usr/bin/env bash
# Regression coverage for local-ci gates that mutate repository-local state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"
LOCAL_CI_TEXT="$(cat "$LOCAL_CI")"
LOCAL_DEV_MIGRATE_TEST="$REPO_ROOT/scripts/tests/local_dev_migrate_test.sh"
LOCAL_DEV_MIGRATE_TEST_TEXT="$(cat "$LOCAL_DEV_MIGRATE_TEST")"

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

test_bootstrap_env_gate_is_scheduled_in_parallel() {
  assert_contains "$LOCAL_CI_TEXT" "schedule validate-bootstrap-env-local" \
    "bootstrap env gate joins the parallel gate batch"
}

test_web_test_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule web-test" \
    "web-test must not join the parallel gate batch"
}

test_rust_lint_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule rust-lint" \
    "rust-lint checkout-isolation checks must not overlap the parallel gate batch"
}

test_reachability_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule test-reachability-contract" \
    "test-reachability-contract must not join the parallel gate batch"
}

test_rc_wrapper_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule rc-wrapper-contract" \
    "rc-wrapper-contract must not overlap gates that mutate repo-local .local state"
}

test_local_schema_drift_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule local-schema-drift-contract" \
    "local-schema-drift-contract must not overlap gates that mutate repo-local .local state"
}

test_bootstrap_env_gate_has_parallel_dispatch_arm() {
  assert_contains "$LOCAL_CI_TEXT" 'validate-bootstrap-env-local) run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local ;;' \
    "bootstrap env gate dispatches through the parallel scheduler"
}

test_bootstrap_env_sequential_workaround_is_removed() {
  assert_not_contains "$LOCAL_CI_TEXT" "RUN_BOOTSTRAP_ENV_LOCAL_SEQUENTIAL" \
    "bootstrap env temporary sequential flag is removed"
  assert_not_contains "$LOCAL_CI_TEXT" "validate-bootstrap-env-local (sequential)" \
    "bootstrap env temporary sequential label is removed"
}

test_bootstrap_env_gate_has_one_run_path() {
  local run_path_count
  run_path_count="$(grep -c 'run_gate validate-bootstrap-env-local gate_validate_bootstrap_env_local' "$LOCAL_CI" || true)"

  if [ "$run_path_count" -eq 1 ]; then
    pass "bootstrap env gate has exactly one run path"
  else
    fail "bootstrap env gate must have exactly one run path (found $run_path_count)"
  fi
}

test_local_schema_drift_test_does_not_replace_shared_runtime_tree() {
  assert_not_contains "$LOCAL_DEV_MIGRATE_TEST_TEXT" \
    'backup_repo_path "$REPO_ROOT/.local"' \
    "local schema drift tests must not replace the shared .local runtime tree"
}

test_web_test_gate_runs_after_parallel_wait() {
  local parallel_wait_line web_test_line
  parallel_wait_line="$(first_match_line '^[[:space:]]*wait$')"
  web_test_line="$(first_match_line 'run_gate web-test gate_web_test')"

  assert_line_after "$parallel_wait_line" "$web_test_line" \
    "web-test starts after the parallel batch"
}

test_reachability_gate_runs_after_parallel_wait() {
  local parallel_wait_line reachability_line
  parallel_wait_line="$(first_match_line '^[[:space:]]*wait$')"
  reachability_line="$(first_match_line 'run_gate test-reachability-contract gate_test_reachability_contract')"

  assert_line_after "$parallel_wait_line" "$reachability_line" \
    "test-reachability-contract starts after the parallel batch"
}

test_rc_wrapper_gate_runs_after_parallel_wait() {
  local parallel_wait_line rc_wrapper_line
  parallel_wait_line="$(first_match_line '^[[:space:]]*wait$')"
  rc_wrapper_line="$(first_match_line 'run_gate rc-wrapper-contract gate_rc_wrapper_contract')"

  assert_line_after "$parallel_wait_line" "$rc_wrapper_line" \
    "rc-wrapper-contract starts after the parallel batch"
}

test_local_schema_drift_gate_runs_after_rc_wrapper() {
  local rc_wrapper_line local_schema_line
  rc_wrapper_line="$(first_match_line 'run_gate rc-wrapper-contract gate_rc_wrapper_contract')"
  local_schema_line="$(first_match_line 'run_gate local-schema-drift-contract gate_local_schema_drift_contract')"

  assert_line_after "$rc_wrapper_line" "$local_schema_line" \
    "local-schema-drift-contract starts after rc-wrapper-contract"
}

test_bootstrap_env_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'validate-bootstrap-env-local' \
    "bootstrap env gate remains selectable through --gate"
}

test_web_test_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "web-test' \
    "web-test remains selectable through --gate"
}

test_rust_lint_gate_runs_after_parallel_wait_and_before_web_test() {
  local rust_lint_line web_test_line preceding_wait_line
  rust_lint_line="$(first_match_line '^[[:space:]]*run_gate rust-lint gate_rust_lint$')"
  web_test_line="$(first_match_line '^[[:space:]]*run_gate web-test gate_web_test$')"
  preceding_wait_line="$(
    grep -n -E '^[[:space:]]*wait$' "$LOCAL_CI" \
      | awk -F: -v target="$rust_lint_line" '$1 < target { line=$1 } END { print line }'
  )"

  assert_line_after "$preceding_wait_line" "$rust_lint_line" \
    "rust-lint starts after the parallel batch drains"
  assert_line_after "$rust_lint_line" "$web_test_line" \
    "rust-lint completes before the existing sequential web-test lane"
}

test_rust_lint_gate_has_one_run_path() {
  local run_path_count
  run_path_count="$(grep -c 'run_gate rust-lint gate_rust_lint' "$LOCAL_CI" || true)"

  if [ "$run_path_count" -eq 1 ]; then
    pass "rust-lint has exactly one run path"
  else
    fail "rust-lint must have exactly one run path (found $run_path_count)"
  fi
}

test_rust_lint_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "rust-lint' \
    "rust-lint remains selectable through --gate"
}

test_rc_wrapper_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "rc-wrapper-contract' \
    "rc-wrapper-contract remains selectable through --gate"
}

test_local_schema_drift_gate_has_one_run_path() {
  local run_path_count
  run_path_count="$(grep -c 'run_gate local-schema-drift-contract gate_local_schema_drift_contract' "$LOCAL_CI" || true)"

  if [ "$run_path_count" -eq 1 ]; then
    pass "local schema drift gate has exactly one run path"
  else
    fail "local schema drift gate must have exactly one run path (found $run_path_count)"
  fi
}

test_local_schema_drift_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "local-schema-drift-contract' \
    "local schema drift gate remains selectable through --gate"
}

test_reachability_gate_runs_after_parallel_wait_and_before_schema_drift() {
  local reachability_line local_schema_drift_line preceding_wait_line
  reachability_line="$(first_match_line '^[[:space:]]*run_gate test-reachability-contract gate_test_reachability_contract$')"
  local_schema_drift_line="$(first_match_line '^[[:space:]]*run_gate local-schema-drift-contract gate_local_schema_drift_contract$')"
  preceding_wait_line="$(
    grep -n -E '^[[:space:]]*wait$' "$LOCAL_CI" \
      | awk -F: -v target="$reachability_line" '$1 < target { line=$1 } END { print line }'
  )"

  assert_line_after "$preceding_wait_line" "$reachability_line" \
    "reachability gate starts after the parallel batch drains"
  assert_line_after "$reachability_line" "$local_schema_drift_line" \
    "reachability gate completes before local schema drift"
}

test_reachability_gate_has_one_run_path() {
  local run_path_count
  run_path_count="$(grep -c 'run_gate test-reachability-contract gate_test_reachability_contract' "$LOCAL_CI" || true)"

  if [ "$run_path_count" -eq 1 ]; then
    pass "reachability gate has exactly one run path"
  else
    fail "reachability gate must have exactly one run path (found $run_path_count)"
  fi
}

test_reachability_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "test-reachability-contract' \
    "reachability gate remains selectable through --gate"
}

test_reachability_checkout_env_mutators_are_serial_only() {
  local serial_only="$REPO_ROOT/scripts/tests/serial_only_tests.txt"
  local serial_text
  serial_text="$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$serial_only")"

  for test_path in \
    "scripts/tests/api_dev_test.sh" \
    "scripts/tests/integration_up_test.sh" \
    "scripts/tests/local_demo_test.sh" \
    "scripts/tests/local_dev_migrate_test.sh" \
    "scripts/tests/run_aggregation_job_test.sh" \
    "scripts/tests/seed_local_test.sh" \
    "scripts/tests/web_dev_test.sh"
  do
    if printf '%s\n' "$serial_text" | grep -Fxq "$test_path"; then
      pass "$test_path is serialized away from concurrent .env.local mutators"
    else
      fail "$test_path must be listed in serial_only_tests.txt"
    fi
  done
}

test_rust_test_gate_is_not_scheduled_in_parallel() {
  assert_not_contains "$LOCAL_CI_TEXT" "schedule rust-test" \
    "rust-test must not join the parallel gate batch"
}

test_rust_test_gate_runs_after_web_test() {
  local web_test_line rust_test_line
  web_test_line="$(first_match_line 'run_gate web-test gate_web_test')"
  rust_test_line="$(first_match_line 'run_gate rust-test gate_rust_test')"

  assert_line_after "$web_test_line" "$rust_test_line" \
    "rust-test starts after web-test in the sequential lane"
}

test_rust_test_single_gate_mode_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'SINGLE_GATE" = "rust-test' \
    "rust-test remains selectable through --gate"
}

test_rust_test_full_mode_sequential_path_remains_supported() {
  assert_contains "$LOCAL_CI_TEXT" 'elif [ "$MODE" = "full" ] && [ -z "$SINGLE_GATE" ]; then' \
    "rust-test remains scheduled sequentially in --full mode"
}

# --- Bounded-parallelism regressions -------------------------------------
# The parallel dispatch loop must cap concurrent gate fan-out. Without a cap,
# ~30 gate bodies fork cargo/clippy/npm at once and a shared host exhausts its
# per-uid process table, so gates die with `fork: Resource temporarily
# unavailable` / `spawn EAGAIN` — a false FAIL. (Diagnosed 2026-07-23.)

test_max_parallel_cap_is_configurable() {
  assert_contains "$LOCAL_CI_TEXT" 'LOCAL_CI_MAX_PARALLEL' \
    "concurrency cap is overridable via LOCAL_CI_MAX_PARALLEL"
  assert_contains "$LOCAL_CI_TEXT" 'MAX_PARALLEL=' \
    "concurrency cap resolves a MAX_PARALLEL value"
}

test_dispatch_loop_throttles_before_launching_gates() {
  # throttle_parallel must be called inside the gate dispatch loop, before the
  # gate case-dispatch, so no gate is backgrounded once the cap is reached.
  local loop_line throttle_call_line case_line
  loop_line="$(first_match_line 'for gate in "\$\{SCHEDULED_GATES\[@\]\}"; do')"
  throttle_call_line="$(grep -n -E '^[[:space:]]*throttle_parallel$' "$LOCAL_CI" | cut -d: -f1 | head -1 || true)"
  case_line="$(first_match_line '^[[:space:]]*case "\$gate" in')"

  assert_line_after "$loop_line" "$throttle_call_line" \
    "throttle_parallel is called inside the dispatch loop"
  assert_line_after "$throttle_call_line" "$case_line" \
    "throttle_parallel runs before the per-gate case-dispatch"
}

test_throttle_uses_bash32_safe_idiom() {
  # macOS ships bash 3.2, which has no `wait -n`. The throttle must poll
  # running jobs instead.
  local body
  body="$(awk '/^throttle_parallel\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"

  assert_contains "$body" 'jobs -pr' \
    "throttle polls running jobs via jobs -pr"
  assert_not_contains "$body" 'wait -n' \
    "throttle avoids wait -n (unsupported on bash 3.2)"
}

test_throttle_parallel_actually_caps_concurrency() {
  # Behavioral guard: extract the real throttle_parallel body from the script
  # and prove it blocks until running jobs drop below the cap. If the cap is
  # removed (loop deleted), this returns with all jobs still running and fails.
  local body
  body="$(awk '/^throttle_parallel\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  if [ -z "$body" ]; then
    fail "throttle_parallel function not found in local-ci.sh"
    return
  fi
  eval "$body"

  local MAX_PARALLEL=2
  ( sleep 0.6 ) & ( sleep 0.6 ) & ( sleep 0.1 ) & ( sleep 0.1 ) &
  throttle_parallel
  local running
  running="$(jobs -pr | wc -l | tr -d '[:space:]')"
  wait

  if [ "$running" -lt "$MAX_PARALLEL" ]; then
    pass "throttle_parallel blocks until running gates < cap ($running < $MAX_PARALLEL)"
  else
    fail "throttle_parallel did not cap concurrency ($running >= $MAX_PARALLEL)"
  fi
}

test_exit_cleanup_waits_before_persisting_logs() {
  local cleanup_line wait_line move_line
  cleanup_line="$(first_match_line '^cleanup_local_ci_logs\(\) \{')"
  wait_line="$(grep -n -E '^[[:space:]]*wait[[:space:]]+2>/dev/null[[:space:]]*\|\|[[:space:]]*true$' "$LOCAL_CI" | cut -d: -f1 | head -1 || true)"
  move_line="$(first_match_line 'mv "\$LOG_DIR" "\$KEEP_LOG_DIR"')"

  assert_line_after "$cleanup_line" "$wait_line" \
    "cleanup_local_ci_logs waits for background gate writers"
  assert_line_after "$wait_line" "$move_line" \
    "cleanup waits before moving the temp log directory"
  assert_contains "$LOCAL_CI_TEXT" "trap cleanup_local_ci_logs EXIT" \
    "EXIT trap uses the cleanup function"
}

test_bootstrap_env_gate_is_scheduled_in_parallel
test_web_test_gate_is_not_scheduled_in_parallel
test_rust_lint_gate_is_not_scheduled_in_parallel
test_reachability_gate_is_not_scheduled_in_parallel
test_rc_wrapper_gate_is_not_scheduled_in_parallel
test_local_schema_drift_gate_is_not_scheduled_in_parallel
test_bootstrap_env_gate_has_parallel_dispatch_arm
test_bootstrap_env_sequential_workaround_is_removed
test_bootstrap_env_gate_has_one_run_path
test_local_schema_drift_test_does_not_replace_shared_runtime_tree
test_web_test_gate_runs_after_parallel_wait
test_reachability_gate_runs_after_parallel_wait
test_rc_wrapper_gate_runs_after_parallel_wait
test_local_schema_drift_gate_runs_after_rc_wrapper
test_bootstrap_env_single_gate_mode_remains_supported
test_web_test_single_gate_mode_remains_supported
test_rust_lint_gate_runs_after_parallel_wait_and_before_web_test
test_rust_lint_gate_has_one_run_path
test_rust_lint_single_gate_mode_remains_supported
test_rc_wrapper_single_gate_mode_remains_supported
test_local_schema_drift_gate_has_one_run_path
test_local_schema_drift_single_gate_mode_remains_supported
test_reachability_gate_runs_after_parallel_wait_and_before_schema_drift
test_reachability_gate_has_one_run_path
test_reachability_single_gate_mode_remains_supported
test_reachability_checkout_env_mutators_are_serial_only
test_rust_test_gate_is_not_scheduled_in_parallel
test_rust_test_gate_runs_after_web_test
test_rust_test_single_gate_mode_remains_supported
test_rust_test_full_mode_sequential_path_remains_supported
test_max_parallel_cap_is_configurable
test_dispatch_loop_throttles_before_launching_gates
test_throttle_uses_bash32_safe_idiom
test_throttle_parallel_actually_caps_concurrency
test_exit_cleanup_waits_before_persisting_logs
run_test_summary
