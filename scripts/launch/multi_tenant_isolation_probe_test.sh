#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_path_exists() {
  local path="$1"
  local message="$2"
  [ -e "$path" ] || fail "$message (missing: $path)"
}

assert_path_not_exists() {
  local path="$1"
  local message="$2"
  [ ! -e "$path" ] || fail "$message (unexpected: $path)"
}

run_failed_assertion_suffix_case() {
  local tmp_dir out_base legacy_green_dir expected_nongreen_dir
  tmp_dir="$(mktemp -d)"
  out_base="$tmp_dir/20260529T000000Z"
  legacy_green_dir="${out_base}_GREEN"
  expected_nongreen_dir="${out_base}_NONGREEN"

  local exit_code=0
  (
    MULTI_TENANT_ISOLATION_PROBE_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/multi_tenant_isolation_probe.sh" >/dev/null 2>&1
    PROBE_ENV="staging"
    PROBE_TENANTS_CSV="A,B,C"
    PROBE_DURATION_MINUTES="30"
    PROBE_RESTART_API_ONCE="false"
    PROBE_ASSERT_MODE="true"
    PROBE_DRY_RUN="true"
    PROBE_OUTPUT_BASE_DIR="$legacy_green_dir"
    PROBE_CROSS_TENANT_LEAKS=1
    probe_run
  ) >/dev/null 2>&1 || exit_code=$?

  [ "$exit_code" -eq 1 ] || fail "forced assertion failure must exit 1"
  assert_path_exists "$expected_nongreen_dir" "failed run must emit _NONGREEN bundle"
  assert_path_not_exists "$legacy_green_dir" "failed run must not leave/create _GREEN bundle"
}

run_failed_assertion_suffix_case

echo "PASS: multi_tenant_isolation_probe_test"
