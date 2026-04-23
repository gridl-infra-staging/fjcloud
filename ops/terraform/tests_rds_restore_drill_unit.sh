#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESTORE_SCRIPT="$ROOT_DIR/ops/scripts/rds_restore_drill.sh"

MOCK_DIR=""
AWS_LOG=""

setup() {
  MOCK_DIR=$(mktemp -d)
  AWS_LOG=$(mktemp)

  cat > "${MOCK_DIR}/aws" <<'AWSMOCK'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${RDS_RESTORE_TEST_AWS_LOG:?}"
printf '%s\n' "$*" >> "$LOG_FILE"

if [[ "$1" == "rds" ]]; then
  exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
AWSMOCK
  chmod +x "${MOCK_DIR}/aws"
}

teardown() {
  rm -rf "$MOCK_DIR" "$AWS_LOG"
}

setup_failing_aws() {
  setup

  cat > "${MOCK_DIR}/aws" <<'AWSMOCK'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${RDS_RESTORE_TEST_AWS_LOG:?}"
printf '%s\n' "$*" >> "$LOG_FILE"
echo "simulated restore failure" >&2
exit 42
AWSMOCK
  chmod +x "${MOCK_DIR}/aws"
}

run_script() {
  local output
  local exit_code=0

  output=$(PATH="${MOCK_DIR}:$PATH" \
    RDS_RESTORE_TEST_AWS_LOG="$AWS_LOG" \
    bash "$RESTORE_SCRIPT" "$@" 2>&1) || exit_code=$?
  echo "$output"
  return "$exit_code"
}

assert_aws_log_contains() {
  local pattern="$1"
  local label="$2"
  if rg -q -- "$pattern" "$AWS_LOG"; then
    pass "$label"
  else
    fail "$label"
  fi
}

assert_aws_log_not_contains() {
  local pattern="$1"
  local label="$2"
  if rg -q -- "$pattern" "$AWS_LOG"; then
    fail "$label"
  else
    pass "$label"
  fi
}

echo ""
echo "=== RDS Restore Drill Behavioral Tests ==="

# default dry-run with snapshot mode
echo ""
echo "--- dry-run default ---"
setup
output=""
exit_code=0
output=$(run_script staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "dry-run exits 0"
else
  fail "dry-run exits 0 (got $exit_code)"
fi
if echo "$output" | rg -q 'Dry run:'; then
  pass "dry-run output announces dry-run mode"
else
  fail "dry-run output announces dry-run mode"
fi
if echo "$output" | rg -q 'RDS_RESTORE_DRILL_EXECUTE=1'; then
  pass "dry-run output documents execute gate"
else
  fail "dry-run output documents execute gate"
fi
if [[ -s "$AWS_LOG" ]]; then
  fail "dry-run does not invoke aws"
else
  pass "dry-run does not invoke aws"
fi
teardown

# invalid env
echo ""
echo "--- invalid env rejected ---"
setup
output=""
exit_code=0
output=$(run_script dev \
  --source-db-instance-id fjcloud-dev-db \
  --target-db-instance-id fjcloud-dev-restore \
  --snapshot-id rds:fjcloud-dev-db-2026-04-22) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "invalid env exits non-zero"
else
  fail "invalid env exits non-zero"
fi
if echo "$output" | rg -qi 'staging|prod'; then
  pass "invalid env output references staging|prod contract"
else
  fail "invalid env output references staging|prod contract"
fi
teardown

# execute without gate rejected
echo ""
echo "--- missing execute gate rejected ---"
setup
output=""
exit_code=0
output=$(PATH="${MOCK_DIR}:$PATH" \
  RDS_RESTORE_TEST_AWS_LOG="$AWS_LOG" \
  RDS_RESTORE_DRILL_EXECUTE=0 \
  bash "$RESTORE_SCRIPT" staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22 2>&1) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "live mode without execute gate exits non-zero"
else
  fail "live mode without execute gate exits non-zero"
fi
if echo "$output" | rg -q 'RDS_RESTORE_DRILL_EXECUTE=1'; then
  pass "missing gate output names execute gate"
else
  fail "missing gate output names execute gate"
fi
teardown

# identical source/target rejected
echo ""
echo "--- equal source/target rejected ---"
setup
output=""
exit_code=0
output=$(run_script staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-db \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "equal source and target exits non-zero"
else
  fail "equal source and target exits non-zero"
fi
if echo "$output" | rg -qi 'must be different'; then
  pass "equal source/target output states distinct target requirement"
else
  fail "equal source/target output states distinct target requirement"
fi
teardown

# ambiguous restore mode rejected
echo ""
echo "--- ambiguous restore mode rejected ---"
setup
output=""
exit_code=0
output=$(run_script staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22 \
  --restore-time 2026-04-22T15:30:00Z) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "ambiguous restore mode exits non-zero"
else
  fail "ambiguous restore mode exits non-zero"
fi
if echo "$output" | rg -qi 'exactly one'; then
  pass "ambiguous mode output enforces exactly-one selector"
else
  fail "ambiguous mode output enforces exactly-one selector"
fi
teardown

# missing restore mode rejected
echo ""
echo "--- missing restore mode rejected ---"
setup
output=""
exit_code=0
output=$(run_script staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "missing restore mode exits non-zero"
else
  fail "missing restore mode exits non-zero"
fi
if echo "$output" | rg -qi 'exactly one'; then
  pass "missing restore mode output enforces exactly-one selector"
else
  fail "missing restore mode output enforces exactly-one selector"
fi
teardown

# secret-bearing CLI args are rejected before any AWS invocation
echo ""
echo "--- secret-bearing CLI args rejected ---"
setup
output=""
exit_code=0
output=$(run_script staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --restore-time 2026-04-22T15:30:00Z \
  --master-user-password supersecret-value) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "secret-bearing CLI arg exits non-zero"
else
  fail "secret-bearing CLI arg exits non-zero"
fi
if echo "$output" | rg -q 'CLI arguments can leak secrets via process inspection'; then
  pass "secret-bearing CLI arg explains argv exposure risk"
else
  fail "secret-bearing CLI arg explains argv exposure risk"
fi
if echo "$output" | rg -q 'supersecret-value'; then
  fail "secret-bearing CLI arg rejection does not echo secret value"
else
  pass "secret-bearing CLI arg rejection does not echo secret value"
fi
if [[ -s "$AWS_LOG" ]]; then
  fail "secret-bearing CLI arg rejection does not invoke aws"
else
  pass "secret-bearing CLI arg rejection does not invoke aws"
fi
teardown

# live snapshot mode dispatches only snapshot API
echo ""
echo "--- live snapshot restore dispatch ---"
setup
output=""
exit_code=0
output=$(PATH="${MOCK_DIR}:$PATH" \
  RDS_RESTORE_TEST_AWS_LOG="$AWS_LOG" \
  RDS_RESTORE_DRILL_EXECUTE=1 \
  bash "$RESTORE_SCRIPT" staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --snapshot-id rds:fjcloud-staging-db-2026-04-22 2>&1) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "live snapshot mode exits 0"
else
  fail "live snapshot mode exits 0 (got $exit_code)"
fi
assert_aws_log_contains 'rds restore-db-instance-from-db-snapshot' "snapshot mode invokes snapshot restore API"
assert_aws_log_not_contains 'rds restore-db-instance-to-point-in-time' "snapshot mode does not invoke PITR API"
teardown

# live PITR mode dispatches only PITR API
echo ""
echo "--- live PITR restore dispatch ---"
setup
output=""
exit_code=0
output=$(PATH="${MOCK_DIR}:$PATH" \
  RDS_RESTORE_TEST_AWS_LOG="$AWS_LOG" \
  RDS_RESTORE_DRILL_EXECUTE=1 \
  bash "$RESTORE_SCRIPT" staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --restore-time 2026-04-22T15:30:00Z 2>&1) || exit_code=$?

if [[ "$exit_code" -eq 0 ]]; then
  pass "live PITR mode exits 0"
else
  fail "live PITR mode exits 0 (got $exit_code)"
fi
assert_aws_log_contains 'rds restore-db-instance-to-point-in-time' "PITR mode invokes point-in-time restore API"
assert_aws_log_not_contains 'rds restore-db-instance-from-db-snapshot' "PITR mode does not invoke snapshot restore API"
teardown

# live restore surfaces contextual failure output
echo ""
echo "--- live restore failure is contextualized ---"
setup_failing_aws
output=""
exit_code=0
output=$(PATH="${MOCK_DIR}:$PATH" \
  RDS_RESTORE_TEST_AWS_LOG="$AWS_LOG" \
  RDS_RESTORE_DRILL_EXECUTE=1 \
  bash "$RESTORE_SCRIPT" staging \
  --source-db-instance-id fjcloud-staging-db \
  --target-db-instance-id fjcloud-staging-restore \
  --restore-time 2026-04-22T15:30:00Z 2>&1) || exit_code=$?

if [[ "$exit_code" -ne 0 ]]; then
  pass "live restore failure exits non-zero"
else
  fail "live restore failure exits non-zero"
fi
if echo "$output" | rg -q 'restore API call failed'; then
  pass "live restore failure output includes contextual restore error"
else
  fail "live restore failure output includes contextual restore error"
fi
if echo "$output" | rg -q 'fjcloud-staging-restore'; then
  pass "live restore failure output names target instance"
else
  fail "live restore failure output names target instance"
fi
assert_aws_log_contains 'rds restore-db-instance-to-point-in-time' "failing live restore still attempts PITR API"
teardown

test_summary "RDS restore drill behavioral checks"
