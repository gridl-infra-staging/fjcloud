#!/usr/bin/env bash
# Contract tests for scripts/launch/multi_tenant_isolation_probe.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../tests/lib/assertions.sh
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

run_contract_case() {
  local mode="$1"
  local expected_exit="$2"
  local out_dir
  out_dir="$(mktemp -d)"
  local output=""
  local exit_code=0
  local output_file
  output_file="$(mktemp)"

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="true"

    case "$mode" in
      pass)
        PROBE_WRITES_ATTEMPTED=120
        PROBE_FAIL_FAST_DURING_WINDOW=10
        PROBE_VISIBLE_IN_SEARCH_AFTER=110
        PROBE_CROSS_TENANT_LEAKS=0
        PROBE_NOISY_NEIGHBOR_VIOLATIONS=0
        PROBE_CREATED_TENANTS="A,C"
        ;;
      silent_drops_fail)
        PROBE_WRITES_ATTEMPTED=120
        PROBE_FAIL_FAST_DURING_WINDOW=10
        PROBE_VISIBLE_IN_SEARCH_AFTER=100
        PROBE_CROSS_TENANT_LEAKS=0
        PROBE_NOISY_NEIGHBOR_VIOLATIONS=0
        PROBE_CREATED_TENANTS="A"
        ;;
      leakage_fail)
        PROBE_WRITES_ATTEMPTED=120
        PROBE_FAIL_FAST_DURING_WINDOW=10
        PROBE_VISIBLE_IN_SEARCH_AFTER=110
        PROBE_CROSS_TENANT_LEAKS=1
        PROBE_NOISY_NEIGHBOR_VIOLATIONS=0
        PROBE_CREATED_TENANTS="B"
        ;;
      noisy_neighbor_fail)
        PROBE_WRITES_ATTEMPTED=120
        PROBE_FAIL_FAST_DURING_WINDOW=10
        PROBE_VISIBLE_IN_SEARCH_AFTER=110
        PROBE_CROSS_TENANT_LEAKS=0
        PROBE_NOISY_NEIGHBOR_VIOLATIONS=2
        PROBE_CREATED_TENANTS=""
        ;;
    esac

    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"

  assert_eq "$exit_code" "$expected_exit" "contract mode $mode should return expected exit"
  assert_contains "$output" '"dry_run":true' "contract mode $mode should emit dry-run summary"
  assert_contains "$output" '"restart_invoked":false' "contract mode $mode should skip restart execution"

  local summary_path="$out_dir/summary.json"
  local cleanup_path="$out_dir/cleanup_manifest.json"
  assert_file_exists "$summary_path" "contract mode $mode should write summary artifact"
  assert_file_exists "$cleanup_path" "contract mode $mode should write cleanup manifest"

  local cleanup_content
  cleanup_content="$(cat "$cleanup_path")"
  if [ "$mode" = "pass" ]; then
    assert_contains "$cleanup_content" '"A"' "pass mode cleanup manifest should include tenant A"
    assert_contains "$cleanup_content" '"C"' "pass mode cleanup manifest should include tenant C"
  fi
}

run_non_dry_runtime_wiring_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local output=""
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      if [ "$letter" = "A" ]; then
        ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="true"
      else
        ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      fi
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      local flapjack_url="$1" flapjack_uid="$2"
      local tenant_letter
      tenant_letter="${flapjack_uid#tenant-}"
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '%s|%s\n' "$flapjack_url" "$flapjack_uid" >> "$out_dir/write_calls.log"
      if [ "$flapjack_uid" = "tenant-A" ]; then
        printf '7\n' > "$out_dir/${tenant_letter}_writes_attempted.count"
        printf '90|A|batch|503\n120|A|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
        printf '150|A|query|503\n' >> "$out_dir/probe_owner_search_events.log"
      else
        printf '5\n' > "$out_dir/${tenant_letter}_writes_attempted.count"
        printf '130|B|batch|503\n140|B|batch|503\n250|B|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
        printf '160|B|query|503\n' >> "$out_dir/probe_owner_search_events.log"
      fi
    }
    run_direct_search_loop() {
      local flapjack_url="$1" flapjack_uid="$2"
      local tenant_letter
      tenant_letter="${flapjack_uid#tenant-}"
      printf '%s|%s\n' "$flapjack_url" "$flapjack_uid" >> "$out_dir/search_calls.log"
      if [ "$flapjack_uid" = "tenant-A" ]; then
        printf '5\n' > "$out_dir/${tenant_letter}_visible_in_search_after.count"
      else
        printf '4\n' > "$out_dir/${tenant_letter}_visible_in_search_after.count"
      fi
    }
    probe_owner_query_hit_count() { printf '0'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$#" -ne 2 ]; then
        printf '{"error":"unexpected-arg-count"}\n500'
        return 0
      fi
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      if [ "$method" = "DELETE" ] && [ "$path" = "/admin/tenants/customer-A" ]; then
        printf '{"ok":true}\n204'
        return 0
      fi
      printf '{"error":"unexpected"}\n500'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    PROBE_WRITES_COUNT_PATH="$out_dir/writes_count.txt"
    PROBE_VISIBLE_AFTER_COUNT_PATH="$out_dir/visible_after.txt"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  assert_eq "$exit_code" "0" "non-dry runtime case should exit cleanly"

  local summary_path="$out_dir/summary.json"
  local cleanup_path="$out_dir/cleanup_manifest.json"
  assert_file_exists "$summary_path" "non-dry runtime case should emit summary"
  assert_file_exists "$cleanup_path" "non-dry runtime case should emit cleanup manifest"

  local write_calls search_calls summary_content cleanup_content
  write_calls="$(cat "$out_dir/write_calls.log")"
  search_calls="$(cat "$out_dir/search_calls.log")"
  summary_content="$(cat "$summary_path")"
  cleanup_content="$(cat "$cleanup_path")"

  assert_contains "$write_calls" 'http://node-A.test|tenant-A' "write loop should receive tenant A mapping output"
  assert_contains "$write_calls" 'http://node-B.test|tenant-B' "write loop should receive tenant B mapping output"
  assert_contains "$search_calls" 'http://node-A.test|tenant-A' "search loop should receive tenant A mapping output"
  assert_contains "$search_calls" 'http://node-B.test|tenant-B' "search loop should receive tenant B mapping output"

  assert_contains "$summary_content" '"writes_attempted":3' "non-dry summary should publish restart-window writes_attempted scope used by silent-drop assertions"
  assert_contains "$summary_content" '"writes_attempted_total":12' "non-dry summary should still include full-run writes_attempted_total for diagnostics"
  assert_contains "$summary_content" '"fail_fast_responses_during_window":3' "non-dry summary should aggregate only write-path in-window fail-fast events from owner callback output"
  assert_contains "$summary_content" '"visible_in_search_after":0' "non-dry summary should aggregate callback-backed visible-after count across tenants"
  assert_contains "$summary_content" '"silent_drops":0' "non-dry summary should compute silent drops from aggregated runtime counters"
  assert_contains "$summary_content" '"cross_tenant_leaks":0' "non-dry summary should aggregate cross-tenant leaks from runtime output"
  assert_contains "$summary_content" '"noisy_neighbor_violations":0' "non-dry summary should aggregate noisy-neighbor violations from runtime output"
  assert_contains "$cleanup_content" '"A"' "non-dry cleanup manifest should include tenant A"
  assert_not_contains "$cleanup_content" '"B"' "non-dry cleanup manifest should exclude pre-existing tenant B"
  assert_contains "$output" '"restart_window_start_epoch":100' "non-dry summary should include bounded restart-window start"
  assert_contains "$output" '"restart_window_end_epoch":200' "non-dry summary should include bounded restart-window end"
}

run_non_dry_persists_cleanup_manifest_before_failure_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="true"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() { exit 9; }
    run_direct_search_loop() { printf '0\n' > "$5"; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$#" -ne 2 ]; then
        printf '{"error":"unexpected-arg-count"}\n500'
        return 0
      fi
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="false"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?

  assert_eq "$exit_code" "9" "created-tenant manifest must survive a mid-run failure"
  local cleanup_content
  cleanup_content="$(cat "$out_dir/cleanup_manifest.json")"
  assert_contains "$cleanup_content" '"A"' "mid-run failure should still leave created tenant A in cleanup manifest"
}

run_non_dry_ignores_probe_local_counter_injection_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local output=""
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-injection-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '9\n' > "$5"
      printf '150|A|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
    }
    run_direct_search_loop() { printf '8\n' > "$5"; }
    probe_owner_query_hit_count() { printf '0'; }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    printf '999\n' > "$out_dir/A_fail_fast_during_restart_window.count"
    printf '999\n' > "$out_dir/A_cross_tenant_leaks.count"
    printf '999\n' > "$out_dir/A_noisy_neighbor_violations.count"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  assert_eq "$exit_code" "0" "non-dry injection case should exit cleanly"
  local summary_content
  summary_content="$(cat "$out_dir/summary.json")"

  assert_contains "$summary_content" '"fail_fast_responses_during_window":1' "non-dry injected probe-local fail-fast files must not override owner-derived values"
  assert_contains "$summary_content" '"cross_tenant_leaks":0' "non-dry injected probe-local leak files must not override owner callbacks"
  assert_contains "$summary_content" '"noisy_neighbor_violations":0' "non-dry injected probe-local noisy-neighbor files must not override owner callbacks"
  assert_not_contains "$output" 'runtime counters were not collected' "non-dry owner callbacks should be wired and counted"
}

# Regression: the midpoint tenant's write loop runs backgrounded across the API
# restart window. If that loop exits non-zero (as run_direct_write_loop did when
# it die'd on a transient non-200 during restart), `wait "$write_loop_pid"` under
# `set -e` used to kill the probe before assertion evaluation. The probe must
# instead survive, count the fail-fast events the loop already logged, and reach
# its assertion verdict.
run_non_dry_survives_restart_window_write_loop_error_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local output=""
  local exit_code=0

  set +e
  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-restart-error-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    # The midpoint tenant (B, backgrounded across the restart) logs two in-window
    # 503 fail-fast events and then exits non-zero, exactly as the real loop would
    # if it still die'd on a transient restart-window non-200.
    run_direct_write_loop() {
      local flapjack_uid="$2" count_path="$5"
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '10\n' > "$count_path"
      if [ "$flapjack_uid" = "tenant-B" ]; then
        printf '120|B|batch|503\n140|B|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
        return 1
      fi
    }
    run_direct_search_loop() {
      local flapjack_uid="$2" count_path="$5"
      if [ "$flapjack_uid" = "tenant-B" ]; then
        printf '8\n' > "$count_path"
      else
        printf '10\n' > "$count_path"
      fi
    }
    probe_owner_query_hit_count() { printf '0'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  # NOTE: this case must run the probe subshell as a standalone command, NOT as
  # `( ... ) || exit_code=$?`. The `||` form sets bash's errexit-suppression flag
  # for the whole subshell, which masks the very `set -e`-on-failed-`wait` crash
  # this regression guards against. We disable the OUTER test's errexit around the
  # call (so an unfixed-probe crash does not abort the suite) while the inner probe
  # re-enables `set -e` via its own `source`, keeping errexit genuinely live inside.
  ) >"$output_file" 2>&1
  exit_code=$?
  set -e
  output="$(cat "$output_file")"

  assert_eq "$exit_code" "0" "probe must reach assertion evaluation (exit 0) even when the backgrounded restart-window write loop exits non-zero"
  local summary_path="$out_dir/summary.json"
  assert_file_exists "$summary_path" "probe must emit summary after surviving the restart-window write loop error"
  local summary_content
  summary_content="$(cat "$summary_path")"
  assert_contains "$summary_content" '"restart_invoked":true' "summary should record the restart as invoked"
  assert_contains "$summary_content" '"writes_attempted":2' "summary should publish restart-window writes scope despite the loop error"
  assert_contains "$summary_content" '"writes_attempted_total":30' "summary should still publish full-run writes total for diagnostics despite the loop error"
  assert_contains "$summary_content" '"fail_fast_responses_during_window":2' "fail-fast events logged by the errored restart-window writes must be counted"
  assert_contains "$summary_content" '"silent_drops":0' "no silent drops once fail-fast writes are accounted for"
}

# Regression guard: a non-zero midpoint write-loop exit is only non-fatal when
# the expected restart-window fail-fast evidence is present. If the loop exits
# early without in-window fail-fast events, the probe must fail hard instead of
# downgrading into assertion evaluation with zeroed counters.
run_non_dry_fails_on_unexpected_restart_window_write_loop_error_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local output=""
  local exit_code=0

  set +e
  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-restart-unexpected-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      local flapjack_uid="$2" count_path="$5"
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      if [ "$flapjack_uid" = "tenant-B" ]; then
        return 1
      fi
      printf '10\n' > "$count_path"
    }
    run_direct_search_loop() { printf '10\n' > "$5"; }
    probe_owner_query_hit_count() { printf '0'; }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1
  exit_code=$?
  set -e
  output="$(cat "$output_file")"

  assert_eq "$exit_code" "1" "probe must hard-fail when midpoint restart-window write loop exits non-zero without in-window fail-fast evidence"
  assert_contains "$output" "exited unexpectedly" "probe must report unexpected restart-window write loop failure"
  if [ -f "$out_dir/summary.json" ]; then
    fail "probe must not continue to assertion evaluation on unexpected restart-window write loop failures"
  else
    pass "probe must not continue to assertion evaluation on unexpected restart-window write loop failures"
  fi
}

run_non_dry_window_bounded_fail_fast_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-window-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '9\n' > "$5"
      printf '95|A|batch|503\n140|A|batch|503\n260|A|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
    }
    run_direct_search_loop() { printf '2\n' > "$5"; }
    probe_owner_query_hit_count() { printf '0'; }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="false"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "0" "window-bounded fail-fast case should exit cleanly"

  local summary_content
  summary_content="$(cat "$out_dir/summary.json")"
  assert_contains "$summary_content" '"fail_fast_responses_during_window":1' "window-bounded fail-fast callback should ignore out-of-window failures"
}

run_non_dry_detects_leak_and_noisy_observations_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-leak-noisy-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
      printf '150|A|batch|503\n150|B|batch|503\n' >> "$out_dir/probe_owner_write_events.log"
    }
    run_direct_search_loop() { printf '4\n' > "$5"; }
    probe_owner_query_hit_count() {
      local flapjack_uid="$2"
      if [ "$flapjack_uid" = "tenant-B" ]; then
        printf '1'
      else
        printf '0'
      fi
    }
    probe_owner_health_status_code() {
      local flapjack_url="$1"
      if [ "$flapjack_url" = "http://node-B.test" ]; then
        printf '503'
      else
        printf '200'
      fi
    }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?

  assert_eq "$exit_code" "1" "non-dry assert should fail when owner-reported leak/noisy observations are non-zero"
}

run_restart_invocation_midpoint_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-midpoint-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      printf '%s\n' "${PROBE_RESTART_INVOKED}" >> "$out_dir/restart_state_during_write.log"
      # Keep write work active so contract can assert restart occurs during traffic.
      printf 'write-loop-active\n' > "$out_dir/write_loop_active.flag"
      sleep 1
      printf '%s\n' "${PROBE_RESTART_INVOKED}" >> "$out_dir/restart_state_during_write.log"
      printf '5\n' > "$5"
    }
    run_direct_search_loop() { printf '5\n' > "$5"; }
    admin_call() { printf '{"ok":true}\n200'; }
    probe_restart_api_once_if_requested() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      PROBE_RESTART_INVOKED="true"
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="false"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1

  local restart_states
  restart_states="$(cat "$out_dir/restart_state_during_write.log")"
  assert_contains "$restart_states" 'false' "midpoint restart case should keep restart off for initial probe work"
  assert_contains "$restart_states" 'true' "midpoint restart case should invoke restart while write traffic is still active"
}

run_probe_teardown_case() {
  local out_dir
  out_dir="$(mktemp -d)"

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      if [ "$letter" = "A" ]; then
        ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="true"
      else
        ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      fi
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '/tmp/probe-contract-teardown-%s.json' "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() { printf '4\n' > "$5"; }
    run_direct_search_loop() { printf '4\n' > "$5"; }
    admin_call() {
      local method="$1" path="$2"
      printf '%s %s\n' "$method" "$path" >> "$out_dir/admin_calls.log"
      if [ "$method" = "DELETE" ] && [ "$path" = "/admin/tenants/customer-A" ]; then
        printf '{"ok":true}\n204'
        return 0
      fi
      printf '{"ok":true}\n200'
      return 0
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="false"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >/dev/null 2>&1

  local admin_calls
  admin_calls="$(cat "$out_dir/admin_calls.log")"
  assert_contains "$admin_calls" 'DELETE /admin/tenants/customer-A' "probe teardown should delete created tenant A"
  assert_not_contains "$admin_calls" 'DELETE /admin/tenants/customer-B' "probe teardown should not delete pre-existing tenant B"
}

run_non_dry_requires_all_mappings_before_peer_counters_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      printf '%s\n' "$letter" >> "$out_dir/ensure_order.log"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() { printf '4\n' > "$5"; }
    run_direct_search_loop() { printf '4\n' > "$5"; }
    probe_owner_cross_tenant_leak_count() {
      # Fail closed if peer mappings were not all provisioned before counter evaluation.
      if [ ! -f "$(tenant_mapping_path A)" ] || [ ! -f "$(tenant_mapping_path B)" ] || [ ! -f "$(tenant_mapping_path C)" ]; then
        return 9
      fi
      printf '0'
    }
    probe_owner_noisy_neighbor_violation_count() {
      if [ ! -f "$(tenant_mapping_path A)" ] || [ ! -f "$(tenant_mapping_path B)" ] || [ ! -f "$(tenant_mapping_path C)" ]; then
        return 9
      fi
      printf '0'
    }
    probe_owner_visible_in_search_after_count() { printf '4'; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?

  assert_eq "$exit_code" "0" "non-dry assert should pass only when peer counters run after all tenant mappings are provisioned"
}

run_non_dry_fails_when_peer_query_probe_fails_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0
  local output=""

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() { printf '4\n' > "$5"; }
    run_direct_search_loop() { printf '4\n' > "$5"; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_query_hit_count() {
      printf 'query-probe-failure'
      return 0
    }
    probe_owner_health_status_code() { printf '200'; }
    admin_call() {
      local method="$1" path="$2"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="true"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"

  assert_eq "$exit_code" "1" "non-dry assert must fail when peer query isolation probe cannot produce numeric hit counts"
  assert_contains "$output" 'runtime counters were not collected' "peer query probe failure should fail closed via runtime-counter guard"
}

run_non_dry_consumes_startup_cleanup_manifest_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"

  cat > "$out_dir/cleanup_manifest.json" <<JSON
{"created_tenants_this_run":["A"],"source":"probe_manifest"}
JSON
  cat > "$out_dir/A.mapping.json" <<JSON
{"customer_id":"customer-A","flapjack_url":"http://node-A.test","flapjack_uid":"tenant-A"}
JSON

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1

    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1"
      local mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() { printf '4\n' > "$5"; }
    run_direct_search_loop() { printf '4\n' > "$5"; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() {
      local method="$1" path="$2"
      printf '%s %s\n' "$method" "$path" >> "$out_dir/admin_calls.log"
      if [ "$method" = "GET" ] && [ "$path" = "/admin/tenants" ]; then
        printf '{"ok":true}\n200'
        return 0
      fi
      if [ "$method" = "DELETE" ] && [ "$path" = "/admin/tenants/customer-A" ]; then
        printf '{"ok":true}\n204'
        return 0
      fi
      printf '{"ok":true}\n204'
      return 0
    }

    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="false"
    PROBE_OUTPUT_DIR="$out_dir"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1

  local admin_calls
  admin_calls="$(cat "$out_dir/admin_calls.log")"
  assert_contains "$admin_calls" 'DELETE /admin/tenants/customer-A' "startup should consume prior cleanup manifest and delete stranded tenant A before new provisioning"
}

run_non_dry_uses_visibility_callback_not_search_count_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1" mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
    }
    run_direct_search_loop() { printf '99\n' > "$5"; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_visible_in_search_after_count() { printf '2'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() { printf '{"ok":true}\n200'; }
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="false"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "0" "visibility callback case should complete successfully"

  local summary_content
  summary_content="$(cat "$out_dir/summary.json")"
  assert_contains "$summary_content" '"visible_in_search_after":2' "non-dry summary must use visibility callback value instead of raw search-loop attempts"
  assert_contains "$summary_content" '"silent_drops":3' "silent-drops must derive from callback-backed visible count (5 - (0 + 2) = 3)"
}

run_non_dry_leak_counter_rejects_loose_fulltext_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1" mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
    }
    run_direct_search_loop() { printf '5\n' > "$5"; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_visible_in_search_after_count() { printf '5'; }
    probe_owner_query_hit_count() {
      local _url="$1" _uid="$2" query_term="$3"
      if [[ "$query_term" == Document\ * ]]; then
        printf '1'
      else
        printf '0'
      fi
    }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() { printf '{"ok":true}\n200'; }
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="false"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "0" "leak counter exact-id case should complete successfully"

  local summary_content
  summary_content="$(cat "$out_dir/summary.json")"
  assert_contains "$summary_content" '"cross_tenant_leaks":0' "leak counter must avoid loose full-text query terms that produce false positives"
}

run_non_dry_empty_restart_window_visible_count_is_zero_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1" mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
      printf '120|A|doc-100000|503\n' >> "$out_dir/probe_owner_write_events.log"
    }
    run_direct_search_loop() { printf '99\n' > "$5"; }
    probe_owner_fail_fast_during_restart_window_count() { printf '1'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() { printf '{"ok":true}\n200'; }
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="false"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "0" "empty-window visibility case should complete successfully"

  local summary_content
  summary_content="$(cat "$out_dir/summary.json")"
  assert_contains "$summary_content" '"writes_attempted":5' "summary writes_attempted should stay on restart-window scope even without successful writes"
  assert_contains "$summary_content" '"visible_in_search_after":0' "callback should report zero visible writes when no restart-window writes succeeded"
  assert_contains "$summary_content" '"silent_drops":4' "silent-drops should use zero-visible callback result instead of fallback search-loop count"
}

run_non_dry_invalid_visibility_callback_rejects_assert_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1" mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
    }
    run_direct_search_loop() { printf '5\n' > "$5"; }
    probe_owner_writes_attempted_during_restart_window_count() { printf '5'; }
    probe_owner_visible_in_search_after_count() { return 9; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() { printf '{"ok":true}\n200'; }
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "1" "invalid visibility callback must fail assert mode instead of passing on search-count fallback"
  assert_contains "$(cat "$output_file")" 'runtime counters were not collected' "invalid visibility callback must mark runtime counters incomplete"
}

run_non_dry_invalid_restart_window_writes_callback_rejects_assert_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_OUTPUT_DIR="$out_dir"
    ensure_customer_and_tenant() {
      local letter="$1" mapping_path
      mapping_path="$(tenant_mapping_path "$letter")"
      ENSURE_CUSTOMER_AND_TENANT_CREATED_THIS_CALL="false"
      cat > "$mapping_path" <<JSON
{"customer_id":"customer-${letter}","flapjack_url":"http://node-${letter}.test","flapjack_uid":"tenant-${letter}"}
JSON
    }
    tenant_mapping_path() { printf '%s/%s.mapping.json' "$out_dir" "$1"; }
    node_api_key_for_url() { printf 'node-key-%s' "$1"; }
    run_direct_write_loop() {
      PROBE_RESTART_WINDOW_START_EPOCH=100
      PROBE_RESTART_WINDOW_END_EPOCH=200
      printf '5\n' > "$5"
    }
    run_direct_search_loop() { printf '5\n' > "$5"; }
    probe_owner_writes_attempted_during_restart_window_count() { return 9; }
    probe_owner_visible_in_search_after_count() { printf '5'; }
    probe_owner_fail_fast_during_restart_window_count() { printf '0'; }
    probe_owner_cross_tenant_leak_count() { printf '0'; }
    probe_owner_noisy_neighbor_violation_count() { printf '0'; }
    admin_call() { printf '{"ok":true}\n200'; }
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="true"
    PROBE_ASSERT_MODE="true"
    PROBE_DRY_RUN="false"
    probe_run
  ) >"$output_file" 2>&1 || exit_code=$?
  assert_eq "$exit_code" "1" "invalid restart-window write-scope callback must fail assert mode instead of passing on total-write fallback"
  assert_contains "$(cat "$output_file")" 'runtime counters were not collected' "invalid restart-window write-scope callback must mark runtime counters incomplete"
}

run_flag_parse_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output=""

  output="$(
  {
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    probe_parse_args --env staging --tenants A,B,C --duration-minutes 30 --restart-api-once --assert --out "$out_dir" --dry-run
    printf 'ENV=%s\nTENANTS=%s\nDURATION=%s\nRESTART=%s\nASSERT=%s\nOUT=%s\nDRY=%s\n' \
      "$PROBE_ENV" "$PROBE_TENANTS_CSV" "$PROBE_DURATION_MINUTES" "$PROBE_RESTART_API_ONCE" "$PROBE_ASSERT_MODE" "$PROBE_OUTPUT_DIR" "$PROBE_DRY_RUN"
  } 2>&1)"

  assert_contains "$output" 'ENV=staging' "flag parse should set --env"
  assert_contains "$output" 'TENANTS=A,B,C' "flag parse should set --tenants"
  assert_contains "$output" 'DURATION=30' "flag parse should set --duration-minutes"
  assert_contains "$output" 'RESTART=true' "flag parse should set --restart-api-once"
  assert_contains "$output" 'ASSERT=true' "flag parse should set --assert"
  assert_contains "$output" "OUT=$out_dir" "flag parse should set --out"
  assert_contains "$output" 'DRY=true' "flag parse should set --dry-run"
}

run_flag_parse_rejects_non_staging_env_case() {
  local out_dir
  out_dir="$(mktemp -d)"
  local output_file
  output_file="$(mktemp)"
  local exit_code=0

  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    probe_parse_args --env prod --tenants A --duration-minutes 30 --out "$out_dir" --dry-run
  ) >"$output_file" 2>&1 || exit_code=$?

  assert_eq "$exit_code" "1" "flag parse should reject non-staging env targets for the staging probe entrypoint"
  assert_contains "$(cat "$output_file")" '--env must be staging for this probe entrypoint' "flag parse should explain the staging-only env restriction"
}

echo "=== multi-tenant isolation probe contract ==="
run_flag_parse_case
run_flag_parse_rejects_non_staging_env_case
run_contract_case pass 0
run_contract_case silent_drops_fail 1
run_contract_case leakage_fail 1
run_contract_case noisy_neighbor_fail 1
run_non_dry_runtime_wiring_case
run_non_dry_persists_cleanup_manifest_before_failure_case
run_non_dry_ignores_probe_local_counter_injection_case
run_non_dry_survives_restart_window_write_loop_error_case
run_non_dry_fails_on_unexpected_restart_window_write_loop_error_case
run_non_dry_window_bounded_fail_fast_case
run_non_dry_detects_leak_and_noisy_observations_case
run_restart_invocation_midpoint_case
run_probe_teardown_case
run_non_dry_requires_all_mappings_before_peer_counters_case
run_non_dry_fails_when_peer_query_probe_fails_case
run_non_dry_consumes_startup_cleanup_manifest_case
run_non_dry_uses_visibility_callback_not_search_count_case
run_non_dry_leak_counter_rejects_loose_fulltext_case
run_non_dry_empty_restart_window_visible_count_is_zero_case
run_non_dry_invalid_visibility_callback_rejects_assert_case
run_non_dry_invalid_restart_window_writes_callback_rejects_assert_case

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ]
