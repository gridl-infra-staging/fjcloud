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

test_reachability_serial_registry_matches_isolation_state() {
  local serial_only="$REPO_ROOT/scripts/tests/serial_only_tests.txt"
  local serial_text
  serial_text="$(sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$serial_only")"

  for test_path in \
    "scripts/tests/api_dev_test.sh" \
    "scripts/tests/integration_up_test.sh" \
    "scripts/tests/local_demo_test.sh" \
    "scripts/tests/local_dev_migrate_test.sh" \
    "scripts/tests/local_dev_up_test.sh" \
    "scripts/tests/run_aggregation_job_test.sh" \
    "scripts/tests/seed_local_test.sh" \
    "scripts/tests/seed_synthetic_traffic_test.sh" \
    "scripts/tests/web_dev_test.sh"
  do
    if printf '%s\n' "$serial_text" | grep -Fxq "$test_path"; then
      fail "$test_path must not remain in serial_only_tests.txt after duplicate-green isolation"
    else
      pass "$test_path is promoted out of the serial tail after duplicate-green isolation"
    fi
  done
}

test_reachability_suite_runner_records_receipt_timing_row() {
  local stem_body runner_body tmpdir fixture_path result_stem timing_row
  stem_body="$(
    awk '/^reachability_result_stem\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI"
  )"
  runner_body="$(
    awk '/^run_reachability_suite\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI"
  )"
  if [ -z "$stem_body" ] || [ -z "$runner_body" ]; then
    fail "reachability result-stem or suite-runner function not found in local-ci.sh"
    return
  fi

  tmpdir="$(mktemp -d)"
  fixture_path="scripts/tests/fixture_timing_test.sh"
  result_stem="scripts_tests_fixture_timing_test.sh"
  mkdir -p "$tmpdir/scripts/tests" "$tmpdir/results"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "fixture timing output\n"' \
    > "$tmpdir/$fixture_path"
  chmod +x "$tmpdir/$fixture_path"

  REPO_ROOT="$tmpdir"
  now_seconds() { date +%s; }
  eval "$stem_body"
  eval "$runner_body"
  run_reachability_suite "$fixture_path" "$tmpdir/results"

  assert_eq "$(reachability_result_stem "$fixture_path")" "$result_stem" \
    "reachability result paths use one canonical stem mapping"
  assert_eq "$(cat "$tmpdir/results/$result_stem.rc")" "0" \
    "reachability suite runner preserves the fixture return code"
  assert_eq "$(cat "$tmpdir/results/$result_stem.log")" "fixture timing output" \
    "reachability suite runner preserves the fixture log"
  timing_row="$(cat "$tmpdir/results/$result_stem.timing")"
  if [[ "$timing_row" =~ ^[0-9]+$'\t'"$fixture_path"$'\t'0$ ]]; then
    pass "reachability suite runner records elapsed seconds, path, and return code"
  else
    fail "reachability suite runner must record a receipt-ready timing row (actual='$timing_row')"
  fi
  rm -rf "$tmpdir"
}

test_reachability_timing_writer_sorts_complete_population() {
  local writer_body tmpdir expected timing_rows output rc=0
  writer_body="$(
    awk '/^write_reachability_timings\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI"
  )"
  if [ -z "$writer_body" ]; then
    fail "write_reachability_timings function not found in local-ci.sh"
    return
  fi

  tmpdir="$(mktemp -d)"
  printf '2\tscripts/tests/z_test.sh\t0\n' >"$tmpdir/z.timing"
  printf '9\tscripts/tests/b_test.sh\t1\n' >"$tmpdir/b.timing"
  printf '2\tscripts/tests/a_test.sh\t0\n' >"$tmpdir/a.timing"

  eval "$writer_body"
  timing_rows="$(write_reachability_timings "$tmpdir" "$tmpdir/slow_suites.tsv" "3")"

  expected=$'9\tscripts/tests/b_test.sh\t1\n2\tscripts/tests/a_test.sh\t0\n2\tscripts/tests/z_test.sh\t0'
  assert_eq "$timing_rows" "3" \
    "reachability timing writer reports the complete measured population"
  assert_eq "$(cat "$tmpdir/slow_suites.tsv")" "$expected" \
    "reachability timing writer preserves every row and sorts by elapsed seconds then path"
  output="$(
    write_reachability_timings "$tmpdir" "$tmpdir/incomplete.tsv" "4" 2>&1
  )" || rc=$?
  assert_eq "$rc" "1" \
    "reachability timing writer fails when a suite timing row is missing"
  assert_contains "$output" "timing population mismatch: expected 4 actual 3" \
    "missing timing evidence reports exact expected and actual populations"
  rm -rf "$tmpdir"
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

test_parallel_cap_sanitizer_clamps_invalid_values() {
  local body
  body="$(awk '/^sanitize_parallel_cap\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  if [ -z "$body" ]; then
    fail "sanitize_parallel_cap function not found in local-ci.sh"
    return
  fi
  eval "$body"

  assert_eq "$(sanitize_parallel_cap "5" "8")" "5" \
    "parallel cap sanitizer preserves valid numeric caps"
  assert_eq "$(sanitize_parallel_cap "0" "8")" "1" \
    "parallel cap sanitizer clamps zero to one worker"
  assert_eq "$(sanitize_parallel_cap "bogus" "8")" "8" \
    "parallel cap sanitizer falls back when the cap is non-numeric"
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

test_throttle_parallel_honors_explicit_cap() {
  local body
  body="$(awk '/^throttle_parallel\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  if [ -z "$body" ]; then
    fail "throttle_parallel function not found in local-ci.sh"
    return
  fi
  eval "$body"

  local MAX_PARALLEL=8
  ( sleep 0.6 ) & ( sleep 0.6 ) & ( sleep 0.6 ) & ( sleep 0.1 ) &
  throttle_parallel 2
  local running
  running="$(jobs -pr | wc -l | tr -d '[:space:]')"
  wait

  if [ "$running" -lt 2 ]; then
    pass "throttle_parallel accepts the reachability scheduler's explicit cap"
  else
    fail "throttle_parallel ignored its explicit cap ($running >= 2)"
  fi
}

test_throttle_parallel_sanitizes_invalid_explicit_cap() {
  local sanitize_body throttle_body
  sanitize_body="$(awk '/^sanitize_parallel_cap\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  throttle_body="$(awk '/^throttle_parallel\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  if [ -z "$sanitize_body" ] || [ -z "$throttle_body" ]; then
    fail "parallel cap sanitizer or throttle_parallel function not found in local-ci.sh"
    return
  fi
  eval "$sanitize_body"
  eval "$throttle_body"

  local MAX_PARALLEL=2
  ( sleep 0.6 ) & ( sleep 0.6 ) & ( sleep 0.6 ) & ( sleep 0.1 ) &
  throttle_parallel bogus
  local running
  running="$(jobs -pr | wc -l | tr -d '[:space:]')"
  wait

  if [ "$running" -lt "$MAX_PARALLEL" ]; then
    pass "throttle_parallel falls back to MAX_PARALLEL when an explicit cap is invalid"
  else
    fail "throttle_parallel ignored MAX_PARALLEL after an invalid explicit cap ($running >= $MAX_PARALLEL)"
  fi
}

test_reachability_scheduler_refills_open_slots() {
  local body throttle_line launch_line
  body="$(awk '/^gate_test_reachability_contract\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$LOCAL_CI")"
  throttle_line="$(
    printf '%s\n' "$body" \
      | grep -n -m1 -F 'throttle_parallel "$max_jobs"' \
      | cut -d: -f1 || true
  )"
  launch_line="$(
    printf '%s\n' "$body" \
      | grep -n -m1 -F 'run_reachability_suite "$test_path" "$results_dir" &' \
      | cut -d: -f1 || true
  )"

  assert_line_after "$throttle_line" "$launch_line" \
    "reachability scheduler refills an open slot before launching each suite"
  assert_not_contains "$body" 'if [ "$jobs" -ge "$max_jobs" ]; then' \
    "reachability scheduler has no eight-suite barrier batch"
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

# --- Fast-lock mutual exclusion (Stage 2) --------------------------------
# Whole-suite `--fast` is guarded by the clone-scoped lock in
# scripts/lib/local_ci_fast_lock.sh. `--gate <name>` and `--summary-only`
# dispatch no whole-suite run, so they must stay lock-free. The lock must be
# acquired before ANY gate is dispatched, so a second concurrent `--fast`
# refuses up front instead of racing gate bodies against the first run.

test_fast_lock_helper_is_sourced() {
  assert_contains "$LOCAL_CI_TEXT" 'source "$REPO_ROOT/scripts/lib/local_ci_fast_lock.sh"' \
    "local-ci sources the fast-lock helper"
}

test_fast_lock_contention_exit_is_documented() {
  assert_contains "$LOCAL_CI_TEXT" \
    "#   75   Another whole-suite --fast run holds this clone's fast lock." \
    "local-ci help documents the reserved fast-lock contention exit"
}

test_fast_lock_acquisition_is_gated_to_whole_suite_fast() {
  assert_contains "$LOCAL_CI_TEXT" \
    '[ "$MODE" = "fast" ] && [ -z "$SINGLE_GATE" ] && [ "$SUMMARY_ONLY" -eq 0 ]' \
    "fast-lock acquisition is gated on MODE=fast + empty SINGLE_GATE + SUMMARY_ONLY=0"
  assert_contains "$LOCAL_CI_TEXT" 'acquire_fast_lock' \
    "local-ci acquires the fast lock"
}

test_fast_lock_single_gate_path_stays_unlocked() {
  # The acquisition guard requires an EMPTY SINGLE_GATE, so `--gate <name>`
  # can never enter the acquisition branch.
  assert_contains "$LOCAL_CI_TEXT" '[ -z "$SINGLE_GATE" ]' \
    "--gate runs stay lock-free (guard requires empty SINGLE_GATE)"
}

test_fast_lock_summary_only_path_stays_unlocked() {
  # `--summary-only` sets SUMMARY_ONLY=1; the guard requires SUMMARY_ONLY=0.
  assert_contains "$LOCAL_CI_TEXT" '[ "$SUMMARY_ONLY" -eq 0 ]' \
    "--summary-only runs stay lock-free (guard requires SUMMARY_ONLY=0)"
}

test_fast_lock_acquired_before_first_gate_dispatch() {
  local acquire_line first_dispatch_line
  acquire_line="$(grep -n -m1 -E '^[[:space:]]*acquire_fast_lock' "$LOCAL_CI" | cut -d: -f1 || true)"
  first_dispatch_line="$(grep -n -m1 -E 'run_gate [a-z][a-z0-9-]* gate_' "$LOCAL_CI" | cut -d: -f1 || true)"

  assert_line_after "$acquire_line" "$first_dispatch_line" \
    "fast lock is acquired before the first run_gate dispatch"
}

test_fast_lock_release_precedes_log_persistence_in_cleanup() {
  local release_line wait_line move_line
  release_line="$(grep -n -m1 -E '^[[:space:]]*release_fast_lock$' "$LOCAL_CI" | cut -d: -f1 || true)"
  wait_line="$(grep -n -E '^[[:space:]]*wait[[:space:]]+2>/dev/null[[:space:]]*\|\|[[:space:]]*true$' "$LOCAL_CI" | cut -d: -f1 | head -1 || true)"
  move_line="$(first_match_line 'mv "\$LOG_DIR" "\$KEEP_LOG_DIR"')"

  # The lock must outlive every background gate job: draining them (wait) has to
  # happen BEFORE release, or an interrupted --fast frees the lock while its
  # gates still run and a second --fast overlaps them.
  assert_line_after "$wait_line" "$release_line" \
    "cleanup drains background gate writers before releasing the fast lock"
  assert_line_after "$release_line" "$move_line" \
    "fast lock is released before logs are persisted"
  assert_contains "$LOCAL_CI_TEXT" 'FAST_LOCK_HELD' \
    "release is gated on whether this run acquired the lock"
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
test_reachability_serial_registry_matches_isolation_state
test_reachability_suite_runner_records_receipt_timing_row
test_reachability_timing_writer_sorts_complete_population
test_rust_test_gate_is_not_scheduled_in_parallel
test_rust_test_gate_runs_after_web_test
test_rust_test_single_gate_mode_remains_supported
test_rust_test_full_mode_sequential_path_remains_supported
test_max_parallel_cap_is_configurable
test_parallel_cap_sanitizer_clamps_invalid_values
test_dispatch_loop_throttles_before_launching_gates
test_throttle_uses_bash32_safe_idiom
test_throttle_parallel_actually_caps_concurrency
test_throttle_parallel_honors_explicit_cap
test_throttle_parallel_sanitizes_invalid_explicit_cap
test_reachability_scheduler_refills_open_slots
test_exit_cleanup_waits_before_persisting_logs
test_fast_lock_helper_is_sourced
test_fast_lock_contention_exit_is_documented
test_fast_lock_acquisition_is_gated_to_whole_suite_fast
test_fast_lock_single_gate_path_stays_unlocked
test_fast_lock_summary_only_path_stays_unlocked
test_fast_lock_acquired_before_first_gate_dispatch
test_fast_lock_release_precedes_log_persistence_in_cleanup
run_test_summary
