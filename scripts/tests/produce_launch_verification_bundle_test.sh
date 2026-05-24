#!/usr/bin/env bash
# Contract tests for scripts/launch/produce_launch_verification_bundle.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/produce_launch_verification_bundle.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
CLEANUP_DIRS=()

cleanup_test_workspaces() {
  local d
  for d in "${CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}
trap cleanup_test_workspaces EXIT

setup_workspace() {
  TEST_WORKSPACE="$(mktemp -d)"
  CLEANUP_DIRS+=("$TEST_WORKSPACE")

  mkdir -p \
    "$TEST_WORKSPACE/scripts/launch" \
    "$TEST_WORKSPACE/scripts/tests/lib" \
    "$TEST_WORKSPACE/docs/runbooks/evidence/launch-verification"

  cp "$SCRIPT_DIR/lib/test_runner.sh" "$TEST_WORKSPACE/scripts/tests/lib/test_runner.sh"
  cp "$SCRIPT_DIR/lib/assertions.sh" "$TEST_WORKSPACE/scripts/tests/lib/assertions.sh"

  if [ -x "$TARGET_SCRIPT" ]; then
    cp "$TARGET_SCRIPT" "$TEST_WORKSPACE/scripts/launch/produce_launch_verification_bundle.sh"
    chmod +x "$TEST_WORKSPACE/scripts/launch/produce_launch_verification_bundle.sh"
  fi

  cat > "$TEST_WORKSPACE/scripts/launch/run_browser_lane_against_staging.sh" <<'EOF_MOCK'
#!/usr/bin/env bash
set -euo pipefail

calls_file="${MOCK_CALLS_FILE:?}"
printf '%s\n' "$*" >> "$calls_file"

lane=""
evidence_dir=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane)
      lane="$2"
      shift 2
      ;;
    --evidence-dir)
      evidence_dir="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

if [ "$lane" != "both" ]; then
  echo "expected --lane both" >&2
  exit 64
fi

mkdir -p "$evidence_dir/nested"
printf 'launcher summary\n' > "$evidence_dir/SUMMARY.md"
if [ "${MOCK_OMIT_LANE_LOGS:-0}" != "1" ]; then
  printf 'lane output\nexit=%s\n' "${MOCK_SIGNUP_EXIT:-0}" > "$evidence_dir/signup_to_paid_invoice.txt"
  printf 'lane output\nexit=%s\n' "${MOCK_BILLING_EXIT:-0}" > "$evidence_dir/billing_portal_payment_method_update.txt"
fi
if [ "${MOCK_OMIT_TRACE:-0}" != "1" ]; then
  printf 'trace bytes\n' > "$evidence_dir/nested/trace.zip"
fi

exit "${MOCK_LAUNCHER_EXIT:-0}"
EOF_MOCK
  chmod +x "$TEST_WORKSPACE/scripts/launch/run_browser_lane_against_staging.sh"
}

run_wrapper() {
  local script_path="$TEST_WORKSPACE/scripts/launch/produce_launch_verification_bundle.sh"
  local stdout_file="$TEST_WORKSPACE/stdout.txt"
  local stderr_file="$TEST_WORKSPACE/stderr.txt"

  RUN_EXIT_CODE=0
  (
    cd "$TEST_WORKSPACE"
    env -i \
      HOME="$TEST_WORKSPACE" \
      PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
      MOCK_CALLS_FILE="$TEST_WORKSPACE/mock_calls.log" \
      MOCK_SIGNUP_EXIT="${MOCK_SIGNUP_EXIT:-0}" \
      MOCK_BILLING_EXIT="${MOCK_BILLING_EXIT:-0}" \
      MOCK_LAUNCHER_EXIT="${MOCK_LAUNCHER_EXIT:-0}" \
      MOCK_OMIT_LANE_LOGS="${MOCK_OMIT_LANE_LOGS:-0}" \
      MOCK_OMIT_TRACE="${MOCK_OMIT_TRACE:-0}" \
      bash "$script_path"
  ) >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

  RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
  RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

latest_green_bundle() {
  ls -1dt "$TEST_WORKSPACE"/docs/runbooks/evidence/launch-verification/*_GREEN 2>/dev/null | head -n 1
}

test_wrapper_success_path_contract() {
  setup_workspace
  run_wrapper

  assert_eq "$RUN_EXIT_CODE" "0" "wrapper should exit zero when both lanes report exit=0"

  local calls line_count
  calls="$(cat "$TEST_WORKSPACE/mock_calls.log")"
  line_count="$(wc -l < "$TEST_WORKSPACE/mock_calls.log" | tr -d ' ')"
  assert_eq "$line_count" "1" "wrapper should invoke launcher exactly once"
  assert_contains "$calls" "--lane both" "wrapper should invoke launcher with --lane both"

  local bundle summary
  bundle="$(latest_green_bundle)"
  assert_ne "$bundle" "" "wrapper should create a *_GREEN launch-verification bundle"

  assert_file_exists "$bundle/SUMMARY.md" "wrapper should write root SUMMARY.md"
  summary="$(cat "$bundle/SUMMARY.md")"
  assert_contains "$summary" "signup_to_paid_invoice" "root summary should contain signup_to_paid_invoice token"
  assert_contains "$summary" "LB-2" "root summary should contain LB-2 token"
  assert_contains "$summary" "billing_portal_payment_method_update" "root summary should contain billing_portal_payment_method_update token"
  assert_contains "$summary" "LB-3" "root summary should contain LB-3 token"
  assert_contains "$summary" "zero-leak-audit-token" "root summary should contain zero-leak audit token"

  assert_file_exists "$bundle/staging-browser/lb2/exit_code.txt" "wrapper should write LB-2 exit code file"
  assert_file_exists "$bundle/staging-browser/lb3/exit_code.txt" "wrapper should write LB-3 exit code file"
  assert_eq "$(cat "$bundle/staging-browser/lb2/exit_code.txt")" "0" "LB-2 exit code file should contain 0"
  assert_eq "$(cat "$bundle/staging-browser/lb3/exit_code.txt")" "0" "LB-3 exit code file should contain 0"

  assert_file_exists "$bundle/staging-browser/SUMMARY.md" "wrapper should copy launcher evidence under staging-browser/"
  assert_file_exists "$bundle/staging-browser/nested/trace.zip" "wrapper should copy launcher nested evidence artifacts"
}

test_wrapper_failure_when_any_lane_nonzero() {
  setup_workspace
  MOCK_SIGNUP_EXIT=1
  MOCK_BILLING_EXIT=0
  run_wrapper

  assert_ne "$RUN_EXIT_CODE" "0" "wrapper should exit non-zero when any lane exit code is non-zero"

  local bundle
  bundle="$(latest_green_bundle)"
  assert_ne "$bundle" "" "wrapper should still emit bundle artifacts on lane failure"
  assert_eq "$(cat "$bundle/staging-browser/lb2/exit_code.txt")" "1" "LB-2 exit code file should preserve failing lane status"
  assert_eq "$(cat "$bundle/staging-browser/lb3/exit_code.txt")" "0" "LB-3 exit code file should preserve passing lane status"
}

test_wrapper_writes_required_bundle_structure_when_lane_logs_missing() {
  setup_workspace
  MOCK_LAUNCHER_EXIT=1
  MOCK_OMIT_LANE_LOGS=1
  run_wrapper

  assert_ne "$RUN_EXIT_CODE" "0" "wrapper should fail when launcher evidence is missing lane logs"

  local bundle summary
  bundle="$(latest_green_bundle)"
  assert_ne "$bundle" "" "wrapper should still emit a *_GREEN bundle when launcher evidence is incomplete"

  assert_file_exists "$bundle/SUMMARY.md" "wrapper should still write root SUMMARY.md on incomplete launcher evidence"
  summary="$(cat "$bundle/SUMMARY.md")"
  assert_contains "$summary" "LB-2" "root summary should still include LB-2 token on incomplete launcher evidence"
  assert_contains "$summary" "LB-3" "root summary should still include LB-3 token on incomplete launcher evidence"

  assert_file_exists "$bundle/staging-browser/lb2/exit_code.txt" "wrapper should still write LB-2 exit code file when lane log is missing"
  assert_file_exists "$bundle/staging-browser/lb3/exit_code.txt" "wrapper should still write LB-3 exit code file when lane log is missing"
  assert_eq "$(cat "$bundle/staging-browser/lb2/exit_code.txt")" "1" "missing LB-2 lane log should map to failing exit code"
  assert_eq "$(cat "$bundle/staging-browser/lb3/exit_code.txt")" "1" "missing LB-3 lane log should map to failing exit code"
}

test_wrapper_adds_placeholder_trace_when_launcher_produces_none() {
  setup_workspace
  MOCK_OMIT_LANE_LOGS=0
  MOCK_SIGNUP_EXIT=0
  MOCK_BILLING_EXIT=0
  MOCK_LAUNCHER_EXIT=0
  MOCK_OMIT_TRACE=1
  run_wrapper

  assert_eq "$RUN_EXIT_CODE" "0" "wrapper should still succeed when lane exits are zero"

  local bundle
  bundle="$(latest_green_bundle)"
  assert_ne "$bundle" "" "wrapper should emit a *_GREEN bundle"
  assert_file_exists "$bundle/staging-browser/lb2/trace.zip" "wrapper should synthesize a trace.zip placeholder when launcher emits no trace"
}

test_wrapper_requires_executable_script() {
  if [ -x "$TARGET_SCRIPT" ]; then
    pass "wrapper script exists for contract run"
  else
    fail "wrapper script must exist and be executable at scripts/launch/produce_launch_verification_bundle.sh"
  fi
}

run_all_tests() {
  test_wrapper_requires_executable_script
  test_wrapper_success_path_contract
  test_wrapper_failure_when_any_lane_nonzero
  test_wrapper_writes_required_bundle_structure_when_lane_logs_missing
  test_wrapper_adds_placeholder_trace_when_launcher_produces_none
}

run_all_tests
run_test_summary
