#!/usr/bin/env bash
# Behavioral tests for ops/scripts/live_e2e_ttl_janitor.sh.
# Uses mocked aws CLI responses; no live AWS access required.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JANITOR_SCRIPT="$REPO_ROOT/ops/scripts/live_e2e_ttl_janitor.sh"

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMP=""
MOCK_DIR=""
AWS_LOG=""
DISCOVERY_FILE=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0

fail() {
  echo "FAIL: $*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="$3"
  if [[ "$actual" == "$expected" ]]; then
    pass "$msg"
  else
    fail "$msg (expected='$expected' actual='$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$msg"
  else
    fail "$msg (missing '$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$msg (unexpected '$needle')"
  else
    pass "$msg"
  fi
}

setup() {
  TEST_TMP="$(mktemp -d)"
  MOCK_DIR="$TEST_TMP/mock"
  AWS_LOG="$TEST_TMP/aws.log"
  DISCOVERY_FILE="$TEST_TMP/discovery.tsv"
  mkdir -p "$MOCK_DIR"
  : > "$AWS_LOG"

  cat > "$DISCOVERY_FILE" <<'EOF'
arn:aws:ec2:us-east-1:123456789012:instance/i-expired	run-123	qa	2024-03-01T00:00:00Z	live-e2e
arn:aws:ec2:us-east-1:123456789012:instance/i-future	run-124	qa	2024-03-20T00:00:00Z	live-e2e
EOF

  cat > "$MOCK_DIR/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$AWS_LOG"

if [[ "${1:-}" == "resourcegroupstaggingapi" && "${2:-}" == "get-resources" ]]; then
  cat "$MOCK_DISCOVERY_FILE"
  exit 0
fi

if [[ "${1:-}" == "ec2" && "${2:-}" == "terminate-instances" ]]; then
  exit 0
fi

if [[ "${1:-}" == "rds" && "${2:-}" == "delete-db-instance" ]]; then
  exit 0
fi

echo "mock aws: unexpected command: $*" >&2
exit 1
EOF
  chmod +x "$MOCK_DIR/aws"
}

read_aws_log() {
  if [[ -f "$AWS_LOG" ]]; then
    cat "$AWS_LOG"
  fi
}

teardown() {
  if [[ -n "$TEST_TMP" && -d "$TEST_TMP" ]]; then
    rm -rf "$TEST_TMP"
  fi
  TEST_TMP=""
}

run_janitor() {
  local args="$1"
  local extra_env="${2:-}"
  RUN_OUTPUT=""
  RUN_EXIT_CODE=0

  if [[ -n "$extra_env" ]]; then
    # shellcheck disable=SC2086
    RUN_OUTPUT="$(AWS_LOG="$AWS_LOG" \
      MOCK_DISCOVERY_FILE="$DISCOVERY_FILE" \
      PATH="$MOCK_DIR:$PATH" \
      env "$extra_env" \
      bash "$JANITOR_SCRIPT" $args 2>&1)" || RUN_EXIT_CODE=$?
  else
    # shellcheck disable=SC2086
    RUN_OUTPUT="$(AWS_LOG="$AWS_LOG" \
      MOCK_DISCOVERY_FILE="$DISCOVERY_FILE" \
      PATH="$MOCK_DIR:$PATH" \
      bash "$JANITOR_SCRIPT" $args 2>&1)" || RUN_EXIT_CODE=$?
  fi
}

test_help() {
  setup
  run_janitor "--help"
  assert_eq "$RUN_EXIT_CODE" "0" "janitor --help exits 0"
  assert_contains "$RUN_OUTPUT" "--execute" "janitor --help describes execute gate"
  assert_contains "$RUN_OUTPUT" "FJCLOUD_ALLOW_LIVE_E2E_DELETE=1" "janitor --help describes env gate"
  teardown
}

test_requires_selectors() {
  setup
  run_janitor ""
  assert_eq "$RUN_EXIT_CODE" "1" "janitor fails closed when selectors are missing"
  assert_contains "$RUN_OUTPUT" "at least one selector" "missing selector failure explains required contract"
  teardown
}

test_rejects_missing_option_values() {
  setup
  run_janitor "--owner"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor rejects option flags missing values"
  assert_contains "$RUN_OUTPUT" "--owner requires a value" "missing option value failure is explicit"
  assert_not_contains "$RUN_OUTPUT" "unbound variable" "missing option value avoids raw shell errors"
  teardown
}

test_rejects_flag_as_option_value() {
  setup
  run_janitor "--owner --execute"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor rejects another flag as an option value"
  assert_contains "$RUN_OUTPUT" "--owner requires a value" "flag-as-value failure is explicit"
  assert_not_contains "$(read_aws_log)" "resourcegroupstaggingapi" "invalid option value blocks discovery"
  teardown
}

test_rejects_delimiter_in_selector_value() {
  setup
  run_janitor "--owner qa,prod"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor rejects selector values that could widen tag filters"
  assert_contains "$RUN_OUTPUT" "--owner must not contain commas or whitespace" "delimiter-bearing selector failure is explicit"
  assert_not_contains "$(read_aws_log)" "resourcegroupstaggingapi" "delimiter-bearing selector blocks discovery"
  teardown
}

test_dry_run_default() {
  setup
  run_janitor "--owner qa --now-epoch 1710000000"
  assert_eq "$RUN_EXIT_CODE" "0" "dry-run mode succeeds with selector"
  assert_contains "$RUN_OUTPUT" "DRY-RUN" "dry-run mode is explicit in output"
  assert_contains "$RUN_OUTPUT" "i-expired" "dry-run lists expired resources"
  assert_not_contains "$(read_aws_log)" "terminate-instances" "dry-run does not issue delete command"
  teardown
}

test_execute_requires_env_gate() {
  setup
  run_janitor "--owner qa --execute --now-epoch 1710000000"
  assert_eq "$RUN_EXIT_CODE" "1" "execute mode fails without env gate"
  assert_contains "$RUN_OUTPUT" "FJCLOUD_ALLOW_LIVE_E2E_DELETE=1" "execute gate failure references explicit env value"
  assert_not_contains "$(read_aws_log)" "terminate-instances" "missing env gate blocks delete calls"
  teardown
}

test_execute_with_gate_deletes_only_expired() {
  setup
  run_janitor "--owner qa --execute --now-epoch 1710000000" "FJCLOUD_ALLOW_LIVE_E2E_DELETE=1"
  assert_eq "$RUN_EXIT_CODE" "0" "execute mode succeeds when both gates are set"
  assert_contains "$(read_aws_log)" "terminate-instances --instance-ids i-expired" "expired EC2 resource is deleted"
  assert_not_contains "$(read_aws_log)" "i-future" "non-expired resources are not deleted"
  teardown
}

test_rejects_missing_ttl() {
  setup
  cat > "$DISCOVERY_FILE" <<'EOF'
arn:aws:ec2:us-east-1:123456789012:instance/i-no-ttl	run-200	qa		live-e2e
EOF
  run_janitor "--owner qa --now-epoch 1710000000"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor fails on resources missing ttl_expires_at"
  assert_contains "$RUN_OUTPUT" "missing required tags" "missing tag failure is explicit"
  teardown
}

test_rejects_unparsable_ttl() {
  setup
  cat > "$DISCOVERY_FILE" <<'EOF'
arn:aws:ec2:us-east-1:123456789012:instance/i-bad-ttl	run-201	qa	not-a-timestamp	live-e2e
EOF
  run_janitor "--owner qa --now-epoch 1710000000"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor fails on unparsable ttl_expires_at"
  assert_contains "$RUN_OUTPUT" "unparseable ttl_expires_at" "TTL parse failure is explicit"
  teardown
}

test_rejects_expired_outside_contract_window() {
  setup
  cat > "$DISCOVERY_FILE" <<'EOF'
arn:aws:ec2:us-east-1:123456789012:instance/i-too-old	run-202	qa	2020-01-01T00:00:00Z	live-e2e
EOF
  run_janitor "--owner qa --now-epoch 1710000000"
  assert_eq "$RUN_EXIT_CODE" "1" "janitor fails when ttl_expires_at is outside contract window"
  assert_contains "$RUN_OUTPUT" "outside contract window" "outside-window failure is explicit"
  teardown
}

test_discovery_uses_tagging_api_and_tag_filters() {
  setup
  run_janitor "--owner qa --test-run-id run-123 --now-epoch 1710000000"
  local aws_calls
  aws_calls="$(read_aws_log)"
  assert_contains "$aws_calls" "resourcegroupstaggingapi get-resources" "janitor uses tagging API discovery"
  assert_contains "$aws_calls" "Key=environment,Values=live-e2e" "janitor applies environment filter"
  assert_contains "$aws_calls" "Key=owner,Values=qa" "janitor applies owner selector filter"
  assert_contains "$aws_calls" "Key=test_run_id,Values=run-123" "janitor applies test_run_id selector filter"
  assert_contains "$aws_calls" "ec2:instance" "janitor discovery uses resource-type allowlist"
  teardown
}

test_refuses_secret_echo_in_errors() {
  setup
  cat > "$DISCOVERY_FILE" <<'EOF'
arn:aws:ec2:us-east-1:123456789012:instance/i-bad-ttl	run-203	qa	not-a-timestamp	live-e2e
EOF
  run_janitor "--owner qa --now-epoch 1710000000" "AWS_SECRET_ACCESS_KEY=very-secret-value"
  assert_eq "$RUN_EXIT_CODE" "1" "invalid ttl still fails with secret env present"
  assert_not_contains "$RUN_OUTPUT" "very-secret-value" "janitor does not echo secret-looking env values"
  teardown
}

test_help
test_requires_selectors
test_rejects_missing_option_values
test_rejects_flag_as_option_value
test_rejects_delimiter_in_selector_value
test_dry_run_default
test_execute_requires_env_gate
test_execute_with_gate_deletes_only_expired
test_rejects_missing_ttl
test_rejects_unparsable_ttl
test_rejects_expired_outside_contract_window
test_discovery_uses_tagging_api_and_tag_filters
test_refuses_secret_echo_in_errors

echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
