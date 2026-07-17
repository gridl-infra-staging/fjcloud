#!/usr/bin/env bash
# Contract tests for scripts/launch/verify_e2e_deployed_gate.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/verify_e2e_deployed_gate.sh"
TARGET_HELPER="$REPO_ROOT/ops/scripts/lib/deploy_validation.sh"

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
  MOCK_DEV_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  MOCK_SYNC_MANIFEST_JSON='{"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
  MOCK_MIRROR_HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  MOCK_RUN_LIST_JSON='[]'
  MOCK_RUN_VIEW_JSON='{"jobs":[]}'
  MOCK_MANIFEST_API_FAIL="0"

  mkdir -p \
    "$TEST_WORKSPACE/scripts/launch" \
    "$TEST_WORKSPACE/scripts/tests/lib" \
    "$TEST_WORKSPACE/ops/scripts/lib" \
    "$TEST_WORKSPACE/mockbin"

  cp "$SCRIPT_DIR/lib/test_runner.sh" "$TEST_WORKSPACE/scripts/tests/lib/test_runner.sh"
  cp "$SCRIPT_DIR/lib/assertions.sh" "$TEST_WORKSPACE/scripts/tests/lib/assertions.sh"

  if [ -x "$TARGET_SCRIPT" ]; then
    cp "$TARGET_SCRIPT" "$TEST_WORKSPACE/scripts/launch/verify_e2e_deployed_gate.sh"
    chmod +x "$TEST_WORKSPACE/scripts/launch/verify_e2e_deployed_gate.sh"
  fi

  if [ -f "$TARGET_HELPER" ]; then
    cp "$TARGET_HELPER" "$TEST_WORKSPACE/ops/scripts/lib/deploy_validation.sh"
  fi

  cat > "$TEST_WORKSPACE/mockbin/git" <<'EOF_MOCK_GIT'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "fetch" ]; then
  exit 0
fi

if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "origin/main" ]; then
  printf '%s\n' "${MOCK_DEV_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  exit 0
fi

echo "unexpected git call: $*" >&2
exit 97
EOF_MOCK_GIT
  chmod +x "$TEST_WORKSPACE/mockbin/git"

  cat > "$TEST_WORKSPACE/mockbin/gh" <<'EOF_MOCK_GH'
#!/usr/bin/env bash
set -euo pipefail

sub="${1:-}"
shift || true

if [ "$sub" = "api" ]; then
  endpoint="${1:-}"
  shift || true
  if [[ "$endpoint" == repos/*/contents/.debbie/sync_manifest.json ]]; then
    if [ "${MOCK_MANIFEST_API_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    python3 - <<'PY'
import base64
import os
payload = os.environ.get("MOCK_SYNC_MANIFEST_JSON", '{"dev_sha": ""}')
print(base64.b64encode(payload.encode("utf-8")).decode("ascii"))
PY
    exit 0
  fi
  if [[ "$endpoint" == repos/*/commits/main ]]; then
    printf '%s\n' "${MOCK_MIRROR_HEAD:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
    exit 0
  fi
fi

if [ "$sub" = "run" ] && [ "${1:-}" = "list" ]; then
  printf '%s\n' "${MOCK_RUN_LIST_JSON:-[]}"
  exit 0
fi

if [ "$sub" = "run" ] && [ "${1:-}" = "view" ]; then
  printf '%s\n' "${MOCK_RUN_VIEW_JSON:-{\"jobs\":[]}}"
  exit 0
fi

echo "unexpected gh call: $sub $*" >&2
exit 98
EOF_MOCK_GH
  chmod +x "$TEST_WORKSPACE/mockbin/gh"
}

write_staging_manifest_fixture() {
  local dev_sha="$1"
  local staging_root="$TEST_WORKSPACE/staging_mirror"
  mkdir -p "$staging_root/.debbie"
  cat > "$staging_root/.debbie/sync_manifest.json" <<EOF_MANIFEST
{"schema_version":1,"dev_sha":"$dev_sha","dev_repo":"gridl-infra-dev/fjcloud_dev","synced_at":"2026-05-24T00:00:00Z"}
EOF_MANIFEST
  cat > "$TEST_WORKSPACE/.debbie.toml" <<EOF_DEBBIE
[repos.staging]
path = "$staging_root"
EOF_DEBBIE
}

run_verifier() {
  local extra_args=("$@")
  local script_path="$TEST_WORKSPACE/scripts/launch/verify_e2e_deployed_gate.sh"
  local stdout_file="$TEST_WORKSPACE/stdout.txt"
  local stderr_file="$TEST_WORKSPACE/stderr.txt"

  RUN_EXIT_CODE=0
  (
    cd "$TEST_WORKSPACE"
    env -i \
      HOME="$TEST_WORKSPACE" \
      PATH="$TEST_WORKSPACE/mockbin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin" \
      MOCK_DEV_HEAD="${MOCK_DEV_HEAD:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}" \
      MOCK_SYNC_MANIFEST_JSON="${MOCK_SYNC_MANIFEST_JSON:-{\"dev_sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}}" \
      MOCK_MIRROR_HEAD="${MOCK_MIRROR_HEAD:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}" \
      MOCK_RUN_LIST_JSON="${MOCK_RUN_LIST_JSON:-[]}" \
      MOCK_RUN_VIEW_JSON="${MOCK_RUN_VIEW_JSON:-{\"jobs\":[]}}" \
      VERIFY_E2E_GATE_MIRROR_REPO="gridl-infra-staging/fjcloud" \
      bash "$script_path" "${extra_args[@]}"
  ) >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

  RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
  RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

latest_default_evidence_dir() {
  ls -1dt "$TEST_WORKSPACE"/docs/live-state/lane_evidence/lane_b_post_merge_gate_* 2>/dev/null | head -n 1
}

configure_completed_run_fixture() {
  MOCK_RUN_LIST_JSON='[{"databaseId":42,"conclusion":"failure","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","createdAt":"2026-05-23T00:00:00Z","url":"https://example.test/runs/42"}]'
}

assert_failure_summary_contract() {
  local evidence_dir="$1"
  local expected_reason="$2"
  local expected_message="$3"

  assert_file_exists "$evidence_dir/SUMMARY.FAIL.md" "failure writes SUMMARY.FAIL.md"
  if [ -e "$evidence_dir/SUMMARY.PASS.md" ]; then
    fail "SUMMARY.PASS.md must be absent on failure"
  else
    pass "SUMMARY.PASS.md is absent on failure"
  fi

  local summary
  summary="$(cat "$evidence_dir/SUMMARY.FAIL.md")"
  assert_contains "$summary" "reason: $expected_reason" "failure writes required reason slug"
  assert_contains "$summary" "$expected_message" "failure writes required reason message"
}

test_script_exists_and_executable() {
  if [ -x "$TARGET_SCRIPT" ]; then
    pass "verify_e2e_deployed_gate.sh exists and is executable"
  else
    fail "verify_e2e_deployed_gate.sh must exist and be executable at scripts/launch/verify_e2e_deployed_gate.sh"
  fi
}

test_help_mentions_required_keywords() {
  setup_workspace
  run_verifier --help

  assert_eq "$RUN_EXIT_CODE" "0" "help exits 0"
  assert_contains "$RUN_STDOUT" "Phase B" "help mentions Phase B"
  assert_contains "$RUN_STDOUT" "merge" "help mentions merge"
  assert_contains "$RUN_STDOUT" "main" "help mentions main"
  assert_contains "$RUN_STDOUT" "e2e-deployed" "help mentions e2e-deployed"
  assert_contains "$RUN_STDOUT" "timeout-seconds" "help mentions timeout-seconds"
  assert_contains "$RUN_STDOUT" "expected-dev-sha" "help mentions expected-dev-sha"
}

test_default_evidence_dir_and_job_absent_e2e_contract() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"success"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2

  assert_ne "$RUN_EXIT_CODE" "0" "missing e2e-deployed job exits non-zero"

  local evidence_dir
  evidence_dir="$(latest_default_evidence_dir)"
  assert_ne "$evidence_dir" "" "default evidence directory is created under docs/live-state/lane_evidence/"
  assert_contains "$evidence_dir" "lane_b_post_merge_gate_" "default evidence directory uses required prefix"

  assert_failure_summary_contract "$evidence_dir" "job_absent_e2e_deployed" "e2e-deployed job missing from CI run"
  local summary
  summary="$(cat "$evidence_dir/SUMMARY.FAIL.md")"
  assert_contains "$summary" "deploy-staging=success" "summary includes observed per-job conclusions"
}

test_manifest_timeout_contract() {
  setup_workspace
  MOCK_SYNC_MANIFEST_JSON='{"dev_sha":"1111111111111111111111111111111111111111"}'
  run_verifier --expected-dev-sha "0000000000000000000000000000000000000000" --timeout-seconds 1 --evidence-dir "$TEST_WORKSPACE/explicit-evidence"

  assert_ne "$RUN_EXIT_CODE" "0" "manifest mismatch exits non-zero"
  assert_failure_summary_contract "$TEST_WORKSPACE/explicit-evidence" "manifest_timeout" "expected DEV_HEAD did not appear in mirror sync_manifest within budget"
}

test_job_absent_deploy_contract() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"e2e-deployed","conclusion":"success"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2 --evidence-dir "$TEST_WORKSPACE/job-absent-deploy"

  assert_ne "$RUN_EXIT_CODE" "0" "missing deploy-staging job exits non-zero"
  assert_failure_summary_contract "$TEST_WORKSPACE/job-absent-deploy" "job_absent_deploy_staging" "deploy-staging job absent from CI run"
}

test_job_failure_deploy_contract() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"failure"},{"name":"e2e-deployed","conclusion":"success"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2 --evidence-dir "$TEST_WORKSPACE/job-failure-deploy"

  assert_ne "$RUN_EXIT_CODE" "0" "failed deploy-staging job exits non-zero"
  assert_failure_summary_contract "$TEST_WORKSPACE/job-failure-deploy" "job_failure_deploy_staging" "deploy-staging job not success: failure"
}

test_job_failure_e2e_contract() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"success"},{"name":"e2e-deployed","conclusion":"cancelled"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2 --evidence-dir "$TEST_WORKSPACE/job-failure-e2e"

  assert_ne "$RUN_EXIT_CODE" "0" "failed e2e-deployed job exits non-zero"
  assert_failure_summary_contract "$TEST_WORKSPACE/job-failure-e2e" "job_failure_e2e_deployed" "e2e-deployed job not success: cancelled"
}

test_success_summary_exclusive_contract() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"success"},{"name":"e2e-deployed","conclusion":"success"}]}'
  mkdir -p "$TEST_WORKSPACE/pass-exclusivity"
  printf 'stale failure\n' > "$TEST_WORKSPACE/pass-exclusivity/SUMMARY.FAIL.md"

  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2 --evidence-dir "$TEST_WORKSPACE/pass-exclusivity"

  assert_eq "$RUN_EXIT_CODE" "0" "all-success jobs exit zero"
  assert_file_exists "$TEST_WORKSPACE/pass-exclusivity/SUMMARY.PASS.md" "pass verdict writes SUMMARY.PASS.md"
  if [ -e "$TEST_WORKSPACE/pass-exclusivity/SUMMARY.FAIL.md" ]; then
    fail "SUMMARY.FAIL.md must be absent on pass"
  else
    pass "SUMMARY.FAIL.md is absent on pass"
  fi
}

test_manifest_timeout_does_not_fallback_to_mirror_ci_verdict() {
  setup_workspace
  configure_completed_run_fixture
  MOCK_SYNC_MANIFEST_JSON='{"dev_sha":"1111111111111111111111111111111111111111"}'
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"success"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 1 --evidence-dir "$TEST_WORKSPACE/no-fallback-timeout"

  assert_ne "$RUN_EXIT_CODE" "0" "manifest mismatch timeout exits non-zero"
  assert_failure_summary_contract "$TEST_WORKSPACE/no-fallback-timeout" "manifest_timeout" "expected DEV_HEAD did not appear in mirror sync_manifest within budget"

  local summary
  summary="$(cat "$TEST_WORKSPACE/no-fallback-timeout/SUMMARY.FAIL.md")"
  assert_not_contains "$summary" "reason: job_absent_e2e_deployed" "manifest mismatch must not fall back to mirror-head CI verdict"
}

test_local_staging_manifest_is_preferred_over_remote_manifest() {
  setup_workspace
  configure_completed_run_fixture
  write_staging_manifest_fixture "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  MOCK_SYNC_MANIFEST_JSON='{"dev_sha":"1111111111111111111111111111111111111111"}'
  MOCK_RUN_VIEW_JSON='{"jobs":[{"name":"deploy-staging","conclusion":"success"}]}'
  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --timeout-seconds 2 --evidence-dir "$TEST_WORKSPACE/local-manifest-preferred"

  assert_ne "$RUN_EXIT_CODE" "0" "missing e2e-deployed job exits non-zero when local manifest is synced"
  assert_failure_summary_contract "$TEST_WORKSPACE/local-manifest-preferred" "job_absent_e2e_deployed" "e2e-deployed job missing from CI run"
}

test_evidence_dir_outside_repo_is_rejected() {
  setup_workspace
  local outside_dir
  outside_dir="$(mktemp -d)"

  run_verifier --expected-dev-sha "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" --evidence-dir "$outside_dir/outside-evidence"

  assert_eq "$RUN_EXIT_CODE" "2" "verifier rejects evidence dirs outside repo root"
  assert_contains "$RUN_STDERR" "evidence dir must stay within repo root" "verifier explains repo-owned evidence-dir requirement"

  rm -rf "$outside_dir"
}

run_all_tests() {
  test_script_exists_and_executable
  test_help_mentions_required_keywords
  test_default_evidence_dir_and_job_absent_e2e_contract
  test_manifest_timeout_contract
  test_job_absent_deploy_contract
  test_job_failure_deploy_contract
  test_job_failure_e2e_contract
  test_success_summary_exclusive_contract
  test_manifest_timeout_does_not_fallback_to_mirror_ci_verdict
  test_local_staging_manifest_is_preferred_over_remote_manifest
  test_evidence_dir_outside_repo_is_rejected
}

run_all_tests
run_test_summary
