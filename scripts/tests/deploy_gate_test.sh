#!/usr/bin/env bash
# Behavioral tests for deploy pre-validation gate in ops/scripts/deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPLOY_SCRIPT="$REPO_ROOT/ops/scripts/deploy.sh"
DEPLOY_TEST_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

PASS_COUNT=0
FAIL_COUNT=0
DEPLOY_TEST_AWS_CALL_LOG=""
DEPLOY_TEST_CURL_CALL_LOG=""

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
if [[ -n "${MOCK_AWS_CALL_LOG:-}" ]]; then
  printf '%s\n' "$args" >> "$MOCK_AWS_CALL_LOG"
fi
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
  local mock_dir output exit_code aws_call_log_file

  mock_dir="$(make_mock_dir)"
  aws_call_log_file="$mock_dir/aws_calls.log"
  : > "$aws_call_log_file"

  output="$(
    DEPLOY_GATE_MODE=mock \
    DEPLOY_GATE_MOCK_CI_STATUS="$ci_status" \
    DEPLOY_GATE_MOCK_ARTIFACT_STATUS="$artifact_status" \
    MOCK_AWS_CALL_LOG="$aws_call_log_file" \
    PATH="$mock_dir:$PATH" \
    bash "$DEPLOY_SCRIPT" staging "$DEPLOY_TEST_SHA" 2>&1
  )" || exit_code=$?

  DEPLOY_TEST_AWS_CALL_LOG="$(cat "$aws_call_log_file")"
  echo "$output"
  rm -rf "$mock_dir"
  return "${exit_code:-0}"
}

run_predeploy_live_with_mock() {
  local region="$1"
  local artifact_status="$2"
  local auth_mode="$3"
  local mock_dir output exit_code aws_call_log_file curl_call_log_file
  mock_dir="$(mktemp -d)"
  aws_call_log_file="$mock_dir/aws_calls.log"
  curl_call_log_file="$mock_dir/curl_calls.log"
  : > "$aws_call_log_file"
  : > "$curl_call_log_file"

  cat > "$mock_dir/curl" <<'MOCK_CURL'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${MOCK_CURL_CALL_LOG:-}" ]]; then
  printf '%s\n' "$*" >> "$MOCK_CURL_CALL_LOG"
fi
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
  if [[ -n "${MOCK_AWS_CALL_LOG:-}" ]]; then
    printf '%s\n' "$args" >> "$MOCK_AWS_CALL_LOG"
  fi
  case "${MOCK_ARTIFACT_STATUS:-exists}" in
    exists)
      echo "1"
      exit 0
      ;;
    missing)
      echo "0"
      exit 0
      ;;
    error)
      echo "lookup-error" >&2
      exit 3
      ;;
  esac
fi
echo "{}"
MOCK_AWS_LIVE
  chmod +x "$mock_dir/aws"

  if [[ "$auth_mode" == "deploy_gate_env" ]]; then
    output="$(
      DEPLOY_GATE_MODE=live \
      DEPLOY_GATE_GITHUB_REPO=org/deploy-repo \
      DEPLOY_GATE_GITHUB_TOKEN=deploy-token \
      GITHUB_REPOSITORY=org/fallback-repo \
      GITHUB_TOKEN=fallback-token \
      MOCK_ARTIFACT_STATUS="$artifact_status" \
      MOCK_AWS_CALL_LOG="$aws_call_log_file" \
      MOCK_CURL_CALL_LOG="$curl_call_log_file" \
      PATH="$mock_dir:$PATH" \
      bash -c "source '$REPO_ROOT/ops/scripts/lib/deploy_validation.sh'; predeploy_validate_release staging '$DEPLOY_TEST_SHA' '$region'" 2>&1
    )" || exit_code=$?
  else
    output="$(
      DEPLOY_GATE_MODE=live \
      DEPLOY_GATE_GITHUB_REPO= \
      DEPLOY_GATE_GITHUB_TOKEN= \
      GITHUB_REPOSITORY=org/fallback-repo \
      GITHUB_TOKEN=fallback-token \
      MOCK_ARTIFACT_STATUS="$artifact_status" \
      MOCK_AWS_CALL_LOG="$aws_call_log_file" \
      MOCK_CURL_CALL_LOG="$curl_call_log_file" \
      PATH="$mock_dir:$PATH" \
      bash -c "source '$REPO_ROOT/ops/scripts/lib/deploy_validation.sh'; predeploy_validate_release staging '$DEPLOY_TEST_SHA' '$region'" 2>&1
    )" || exit_code=$?
  fi

  DEPLOY_TEST_AWS_CALL_LOG="$(cat "$aws_call_log_file")"
  DEPLOY_TEST_CURL_CALL_LOG="$(cat "$curl_call_log_file")"
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

test_writes_canary_quiet_window_before_send_command() {
  local output exit_code=0
  local quiet_line send_command_line quiet_call quiet_value output_file
  output_file="$(mktemp)"
  run_deploy_with_mock pass exists > "$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  rm -f "$output_file"

  assert_eq "$exit_code" "0" "deploy succeeds when checking canary quiet-window write contract"
  assert_contains "$output" "Pre-deploy validation passed for SHA ${DEPLOY_TEST_SHA}" "pre-deploy validation succeeds before quiet-window write contract assertions"

  quiet_line="$(
    printf '%s\n' "$DEPLOY_TEST_AWS_CALL_LOG" \
      | rg -n 'ssm put-parameter.*--name /fjcloud/staging/canary_quiet_until.*--overwrite' \
      | head -1 | cut -d: -f1 || true
  )"
  send_command_line="$(
    printf '%s\n' "$DEPLOY_TEST_AWS_CALL_LOG" \
      | rg -n 'ssm send-command' \
      | head -1 | cut -d: -f1 || true
  )"
  quiet_call="$(
    printf '%s\n' "$DEPLOY_TEST_AWS_CALL_LOG" \
      | rg 'ssm put-parameter.*--name /fjcloud/staging/canary_quiet_until' \
      | head -1 || true
  )"
  quiet_value="$(sed -n 's/.*--value \([^ ]*\).*/\1/p' <<< "$quiet_call")"

  if [[ -n "$quiet_line" ]]; then
    pass "deploy writes /fjcloud/staging/canary_quiet_until via caller-side aws ssm put-parameter"
  else
    fail "deploy writes /fjcloud/staging/canary_quiet_until via caller-side aws ssm put-parameter"
  fi

  if [[ -n "$quiet_line" && -n "$send_command_line" && "$quiet_line" -lt "$send_command_line" ]]; then
    pass "deploy writes canary_quiet_until before aws ssm send-command"
  else
    fail "deploy writes canary_quiet_until before aws ssm send-command"
  fi

  if [[ "$quiet_value" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    pass "deploy writes canary_quiet_until in canonical UTC RFC3339 Zulu format"
  else
    fail "deploy writes canary_quiet_until in canonical UTC RFC3339 Zulu format"
  fi
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
  local output_file
  output_file="$(mktemp)"
  run_predeploy_live_with_mock us-east-1 exists deploy_gate_env > "$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  rm -f "$output_file"

  assert_eq "$exit_code" "0" "live predeploy validation passes when explicit region is provided"
  assert_contains "$output" "Pre-deploy validation passed" "live predeploy reports success with explicit region"
  assert_contains "$DEPLOY_TEST_AWS_CALL_LOG" 's3api list-objects-v2 --region us-east-1 --bucket fjcloud-releases-staging --prefix staging/' "live artifact lookup uses explicit region and staging bucket/prefix path"
}

test_live_ci_lookup_uses_deploy_gate_token_and_repo() {
  local output exit_code=0
  local output_file
  output_file="$(mktemp)"
  run_predeploy_live_with_mock us-east-1 exists deploy_gate_env > "$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  rm -f "$output_file"

  assert_eq "$exit_code" "0" "live predeploy passes when deploy-gate GitHub auth env vars are set"
  assert_contains "$DEPLOY_TEST_CURL_CALL_LOG" "Authorization: Bearer deploy-token" "live CI status lookup uses DEPLOY_GATE_GITHUB_TOKEN"
  assert_contains "$DEPLOY_TEST_CURL_CALL_LOG" "https://api.github.com/repos/org/deploy-repo/commits/${DEPLOY_TEST_SHA}/status" "live CI status lookup uses DEPLOY_GATE_GITHUB_REPO"
  assert_not_contains "$DEPLOY_TEST_CURL_CALL_LOG" "Authorization: Bearer fallback-token" "live CI status lookup does not use fallback token when deploy-gate token is set"
  assert_contains "$output" "Pre-deploy validation passed for SHA ${DEPLOY_TEST_SHA}" "live predeploy passes with deploy-gate GitHub auth env vars"
}

test_live_ci_lookup_falls_back_to_github_token_and_repository() {
  local output exit_code=0
  local output_file
  output_file="$(mktemp)"
  run_predeploy_live_with_mock us-east-1 exists github_env > "$output_file" 2>&1 || exit_code=$?
  output="$(cat "$output_file")"
  rm -f "$output_file"

  assert_eq "$exit_code" "0" "live predeploy passes when fallback GitHub env vars are used"
  assert_contains "$DEPLOY_TEST_CURL_CALL_LOG" "Authorization: Bearer fallback-token" "live CI status lookup falls back to GITHUB_TOKEN"
  assert_contains "$DEPLOY_TEST_CURL_CALL_LOG" "https://api.github.com/repos/org/fallback-repo/commits/${DEPLOY_TEST_SHA}/status" "live CI status lookup falls back to GITHUB_REPOSITORY"
  assert_contains "$output" "Pre-deploy validation passed for SHA ${DEPLOY_TEST_SHA}" "live predeploy passes with fallback GitHub env vars"
}

test_live_predeploy_reports_sha_when_artifact_lookup_errors() {
  local output exit_code=0
  output="$(run_predeploy_live_with_mock us-east-1 error deploy_gate_env)" || exit_code=$?

  assert_eq "$exit_code" "1" "live predeploy fails closed when artifact lookup errors"
  assert_contains "$output" "release artifact lookup error for SHA ${DEPLOY_TEST_SHA}" "live artifact lookup error output is SHA-specific"
  assert_contains "$output" "pre-deploy validation failed for SHA ${DEPLOY_TEST_SHA}: artifact lookup error" "live predeploy summary preserves SHA-specific artifact lookup error"
}

test_live_predeploy_reports_sha_when_artifacts_missing() {
  local output exit_code=0
  output="$(run_predeploy_live_with_mock us-east-1 missing deploy_gate_env)" || exit_code=$?

  assert_eq "$exit_code" "1" "live predeploy fails closed when artifact path has no objects"
  assert_contains "$output" "release artifact check failed for SHA ${DEPLOY_TEST_SHA}" "live artifact missing output is SHA-specific"
  assert_contains "$output" "no objects at s3://fjcloud-releases-staging/staging/${DEPLOY_TEST_SHA}/" "live artifact missing output includes staging SHA S3 path"
  assert_contains "$output" "pre-deploy validation failed for SHA ${DEPLOY_TEST_SHA}: artifact missing" "live predeploy summary preserves SHA-specific missing-artifact failure"
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
test_live_ci_lookup_uses_deploy_gate_token_and_repo
test_live_ci_lookup_falls_back_to_github_token_and_repository
test_live_predeploy_reports_sha_when_artifact_lookup_errors
test_live_predeploy_reports_sha_when_artifacts_missing
test_writes_canary_quiet_window_before_send_command

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
