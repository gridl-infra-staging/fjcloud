#!/usr/bin/env bash
# Behavioral tests for deploy pre-validation gate in ops/scripts/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SCRIPT="$REPO_ROOT/ops/scripts/deploy.sh"
DEPLOY_TEST_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
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
    fail "$msg (missing substring '$needle')"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    fail "$msg (unexpected substring '$needle')"
  else
    pass "$msg"
  fi
}

make_mock_dir() {
  local mock_dir
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/aws" <<'MOCK_AWS'
#!/usr/bin/env bash
set -euo pipefail

args="$*"
if [[ "$args" == ec2\ describe-instances* ]]; then
  echo "i-test123"
  exit 0
fi

if [[ "$args" == ssm\ get-parameter* ]]; then
  if [[ "$args" == *"--query Parameter.Value"* ]]; then
    echo "1111111111111111111111111111111111111111"
  else
    echo '{}'
  fi
  exit 0
fi

if [[ "$args" == ssm\ put-parameter* ]]; then
  echo '{}'
  exit 0
fi

if [[ "$args" == ssm\ send-command* ]]; then
  echo "cmd-123"
  exit 0
fi

if [[ "$args" == ssm\ get-command-invocation* ]]; then
  if [[ "$args" == *"--query Status"* ]]; then
    echo "Success"
  else
    echo '{}'
  fi
  exit 0
fi

if [[ "$args" == s3* || "$args" == s3api* ]]; then
  echo '{}'
  exit 0
fi

echo '{}'
MOCK_AWS
  chmod +x "$mock_dir/aws"

  cat > "$mock_dir/jq" <<'MOCK_JQ'
#!/usr/bin/env bash
set -euo pipefail
cat
MOCK_JQ
  chmod +x "$mock_dir/jq"

  echo "$mock_dir"
}

run_deploy_with_mock() {
  local ci_status="$1"
  local artifact_status="$2"
  local mock_dir output exit_code

  mock_dir="$(make_mock_dir)"

  output="$(
    DEPLOY_GATE_MODE=mock \
    DEPLOY_GATE_MOCK_CI_STATUS="$ci_status" \
    DEPLOY_GATE_MOCK_ARTIFACT_STATUS="$artifact_status" \
    PATH="$mock_dir:$PATH" \
    bash "$DEPLOY_SCRIPT" staging "$DEPLOY_TEST_SHA" 2>&1
  )" || exit_code=$?

  echo "$output"
  rm -rf "$mock_dir"
  return "${exit_code:-0}"
}

run_predeploy_live_with_region_required_mock() {
  local region="$1"
  local mock_dir output exit_code
  mock_dir="$(mktemp -d)"

  cat > "$mock_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
echo '{"state":"success"}'
MOCK_CURL
  chmod +x "$mock_dir/curl"

  cat > "$mock_dir/jq" <<'MOCK_JQ_LIVE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-r" && "${2:-}" == ".state" ]]; then
  sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  exit 0
fi
cat
MOCK_JQ_LIVE
  chmod +x "$mock_dir/jq"

  cat > "$mock_dir/aws" <<'MOCK_AWS_LIVE'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == s3api\ list-objects-v2* ]]; then
  if [[ "$args" == *"--region us-east-1"* ]]; then
    echo "1"
    exit 0
  fi
  echo "region-missing" >&2
  exit 3
fi
echo "{}"
MOCK_AWS_LIVE
  chmod +x "$mock_dir/aws"

  output="$(
    DEPLOY_GATE_MODE=live \
    DEPLOY_GATE_GITHUB_REPO=org/repo \
    DEPLOY_GATE_GITHUB_TOKEN=test-token \
    PATH="$mock_dir:$PATH" \
    bash -c "source '$REPO_ROOT/ops/scripts/lib/deploy_validation.sh'; predeploy_validate_release staging '$DEPLOY_TEST_SHA' '$region'" 2>&1
  )" || exit_code=$?

  echo "$output"
  rm -rf "$mock_dir"
  return "${exit_code:-0}"
}

test_rejects_when_ci_not_passing() {
  local output exit_code=0
  output="$(run_deploy_with_mock fail exists)" || exit_code=$?

  assert_eq "$exit_code" "1" "deploy rejects when CI status is not passing"
  assert_contains "$output" "CI status" "output identifies CI status prerequisite failure"
  assert_contains "$output" "$DEPLOY_TEST_SHA" "output includes target SHA for CI prerequisite failure"
}

test_rejects_when_artifact_missing() {
  local output exit_code=0
  output="$(run_deploy_with_mock pass missing)" || exit_code=$?

  assert_eq "$exit_code" "1" "deploy rejects when release artifact is missing"
  assert_contains "$output" "artifact" "output identifies artifact prerequisite failure"
  assert_contains "$output" "$DEPLOY_TEST_SHA" "output includes target SHA for artifact prerequisite failure"
}

test_proceeds_when_ci_and_artifact_checks_pass() {
  local output exit_code=0
  output="$(run_deploy_with_mock pass exists)" || exit_code=$?

  assert_eq "$exit_code" "0" "deploy proceeds when CI status passes and artifact exists"
  assert_contains "$output" "Pre-deploy validation passed for SHA ${DEPLOY_TEST_SHA}" "output confirms pre-deploy gate pass"
  assert_contains "$output" "Deploy complete" "output confirms deploy pipeline executed"
  assert_not_contains "$output" "pre-deploy validation failed" "output has no pre-deploy failure when prerequisites pass"
}

test_rejects_when_ci_lookup_errors() {
  local output exit_code=0
  output="$(run_deploy_with_mock error exists)" || exit_code=$?

  assert_eq "$exit_code" "1" "deploy fails closed when CI status lookup errors"
  assert_contains "$output" "CI status lookup error" "output identifies CI lookup failure"
}

test_rejects_when_artifact_lookup_errors() {
  local output exit_code=0
  output="$(run_deploy_with_mock pass error)" || exit_code=$?

  assert_eq "$exit_code" "1" "deploy fails closed when artifact lookup errors"
  assert_contains "$output" "artifact lookup error" "output identifies artifact lookup failure"
}

test_live_predeploy_uses_explicit_region_for_artifact_lookup() {
  local output exit_code=0
  output="$(run_predeploy_live_with_region_required_mock us-east-1)" || exit_code=$?

  assert_eq "$exit_code" "0" "live predeploy validation passes when explicit region is provided"
  assert_contains "$output" "Pre-deploy validation passed" "live predeploy reports success with explicit region"
}

echo ""
echo "=== Deploy Gate Tests ==="
echo ""

test_rejects_when_ci_not_passing
test_rejects_when_artifact_missing
test_proceeds_when_ci_and_artifact_checks_pass
test_rejects_when_ci_lookup_errors
test_rejects_when_artifact_lookup_errors
test_live_predeploy_uses_explicit_region_for_artifact_lookup

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
