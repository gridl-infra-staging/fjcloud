#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/ops/scripts/set_algolia_migration_availability.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

SHA_A="1111111111111111111111111111111111111111"
SHA_B="2222222222222222222222222222222222222222"

WORK_DIR=""
RUN_STDOUT=""
RUN_EXIT_CODE=0

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin"
  : > "$WORK_DIR/aws.log"
  : > "$WORK_DIR/state.env"

  cat > "$WORK_DIR/bin/aws" <<'AWS_EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >> "$AWS_LOG"

if [ "${1:-}" = "ec2" ] && [ "${2:-}" = "describe-instances" ]; then
  case "${AWS_INSTANCE_SCENARIO:-single}" in
    none) printf 'None\n' ;;
    multi) printf 'i-api-1\ti-api-2\n' ;;
    *) printf 'i-api-1\n' ;;
  esac
  exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "put-parameter" ]; then
  name=""
  value=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --name) name="$2"; shift 2 ;;
      --value) value="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf 'PARAM_NAME=%s\nPARAM_VALUE=%s\n' "$name" "$value" > "$AWS_STATE"
  printf 'ok\n'
  exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-parameter" ]; then
  if [ -f "$AWS_STATE" ]; then
    # shellcheck disable=SC1090
    . "$AWS_STATE"
  fi
  printf '%s\n' "${PARAM_VALUE:-false}"
  exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "send-command" ]; then
  instance=""
  comment=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --instance-ids) instance="$2"; shift 2 ;;
      --comment) comment="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  printf '%s|%s\n' "$instance" "$comment" >> "$AWS_SEND_LOG"
  if [[ "$comment" == *"fail-closed stop"* ]]; then
    printf 'cmd-stop-%s\n' "$instance"
  else
    printf 'cmd-proof-%s\n' "$instance"
  fi
  exit 0
fi

if [ "${1:-}" = "ssm" ] && [ "${2:-}" = "get-command-invocation" ]; then
  command_id=""
  query=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command-id) command_id="$2"; shift 2 ;;
      --query) query="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$query" in
    Status)
      printf 'Success\n'
      ;;
    StandardOutputContent)
      if [[ "$command_id" == cmd-stop-* ]]; then
        printf 'stopped\n'
      elif [ "${AWS_PROOF_SCENARIO:-success}" = "bad_env" ]; then
        printf 'ENV_VALUE=true\nVERSION_JSON={"dev_sha":"%s","mirror_sha":"%s"}\nAVAILABILITY_JSON={"available":false,"reason":"temporarily_unavailable","message":"closed"}\n' "$EXPECTED_API_DEV_SHA" "$EXPECTED_MIRROR_SHA"
      else
        printf 'ENV_VALUE=%s\nVERSION_JSON={"dev_sha":"%s","mirror_sha":"%s"}\nAVAILABILITY_JSON={"available":false,"reason":"temporarily_unavailable","message":"closed"}\n' "$EXPECTED_ENABLED" "$EXPECTED_API_DEV_SHA" "$EXPECTED_MIRROR_SHA"
      fi
      ;;
    *)
      printf 'ok\n'
      ;;
  esac
  exit 0
fi

echo "unexpected aws invocation: $*" >&2
exit 1
AWS_EOF
  chmod +x "$WORK_DIR/bin/aws"
}

run_toggle() {
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    AWS_LOG="$WORK_DIR/aws.log" \
    AWS_SEND_LOG="$WORK_DIR/send.log" \
    AWS_STATE="$WORK_DIR/state.env" \
    AWS_DEFAULT_REGION="us-east-1" \
    ALGOLIA_MIGRATION_PROBE_TOKEN="tenant-token" \
    EXPECTED_ENABLED="${EXPECTED_ENABLED:-false}" \
    EXPECTED_API_DEV_SHA="$SHA_A" \
    EXPECTED_MIRROR_SHA="$SHA_B" \
    FJCLOUD_ALGOLIA_TOGGLE_POLL_SLEEP_SECONDS=0 \
    bash "$TARGET_SCRIPT" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_rejects_invalid_env() {
  setup_workspace
  run_toggle --env dev --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B"
  assert_eq "$RUN_EXIT_CODE" "1" "invalid env should fail"
  assert_contains "$RUN_STDOUT" "--env must be staging or prod" "invalid env explains allowed values"
}

test_rejects_invalid_boolean() {
  setup_workspace
  run_toggle --env staging --enabled yes --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B"
  assert_eq "$RUN_EXIT_CODE" "1" "invalid boolean should fail"
  assert_contains "$RUN_STDOUT" "--enabled must be true or false" "invalid boolean explains allowed values"
}

test_rejects_missing_args() {
  setup_workspace
  run_toggle --env staging --enabled false --expected-api-dev-sha "$SHA_A"
  assert_eq "$RUN_EXIT_CODE" "1" "missing mirror SHA should fail"
  assert_contains "$RUN_STDOUT" "--expected-mirror-sha is required" "missing arg is named"
}

test_rejects_non_40_hex_sha() {
  setup_workspace
  run_toggle --env staging --enabled false --expected-api-dev-sha ABC --expected-mirror-sha "$SHA_B"
  assert_eq "$RUN_EXIT_CODE" "1" "bad SHA should fail"
  assert_contains "$RUN_STDOUT" "40-character lowercase hexadecimal SHA" "bad SHA explains format"
}

test_dry_run_does_not_write() {
  setup_workspace
  EXPECTED_ENABLED=false run_toggle --env staging --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B"
  assert_eq "$RUN_EXIT_CODE" "0" "dry-run should succeed"
  assert_contains "$RUN_STDOUT" "Dry-run: would set /fjcloud/staging/algolia_migration_enabled=false" "dry-run names planned parameter write"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "dry-run should not put parameter"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm send-command" "dry-run should not send SSM command"
}

test_execute_writes_and_proves_true_without_opening_migration() {
  setup_workspace
  EXPECTED_ENABLED=true run_toggle --env staging --enabled true --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "execute true should prove successfully"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "execute writes canonical SSM parameter"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "--name /fjcloud/staging/algolia_migration_enabled" "execute writes the canonical parameter name"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "--value true" "execute writes requested true value"
  assert_contains "$RUN_STDOUT" "Stage 1 remains fail-closed" "enabled true output does not claim migration is open"
  assert_contains "$(cat "$WORK_DIR/aws.log")" 'for attempt in $(seq 1 60)' "execute waits for API readiness after restart"
}

test_execute_is_idempotent() {
  setup_workspace
  EXPECTED_ENABLED=false run_toggle --env prod --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "first execute false should succeed"
  EXPECTED_ENABLED=false run_toggle --env prod --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "second execute false should also succeed"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "--overwrite" "execute uses overwrite for idempotent reruns"
}

test_false_execute_stops_api_when_disabled_state_unproved() {
  setup_workspace
  AWS_PROOF_SCENARIO=bad_env EXPECTED_ENABLED=false run_toggle --env staging --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "unproved disabled state should fail"
  assert_contains "$RUN_STDOUT" "Fail-closed: stopping fjcloud-api" "unproved disabled state triggers fail-closed stop"
  assert_contains "$(cat "$WORK_DIR/send.log")" "fail-closed stop" "fail-closed path sends stop command"
}

test_execute_proves_each_selected_instance() {
  setup_workspace
  AWS_INSTANCE_SCENARIO=multi EXPECTED_ENABLED=false run_toggle --env staging --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "multi-instance execute should succeed"
  assert_contains "$(cat "$WORK_DIR/send.log")" "i-api-1|fjcloud algolia migration availability toggle" "first instance is proved"
  assert_contains "$(cat "$WORK_DIR/send.log")" "i-api-2|fjcloud algolia migration availability toggle" "second instance is proved"
}

test_execute_does_not_transport_probe_token() {
  setup_workspace
  RUN_EXIT_CODE=0
  RUN_STDOUT="$(
    PATH="$WORK_DIR/bin:$PATH" \
    AWS_LOG="$WORK_DIR/aws.log" \
    AWS_SEND_LOG="$WORK_DIR/send.log" \
    AWS_STATE="$WORK_DIR/state.env" \
    AWS_DEFAULT_REGION="us-east-1" \
    EXPECTED_ENABLED=false \
    EXPECTED_API_DEV_SHA="$SHA_A" \
    EXPECTED_MIRROR_SHA="$SHA_B" \
    FJCLOUD_ALGOLIA_TOGGLE_POLL_SLEEP_SECONDS=0 \
    bash "$TARGET_SCRIPT" --env staging --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B" --execute 2>&1
  )" || RUN_EXIT_CODE=$?
  assert_eq "$RUN_EXIT_CODE" "0" "execute should not require a token transported through SSM"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "tenant-token" "execute does not put bearer tokens in AWS command history"
}

test_rejects_no_running_instances() {
  setup_workspace
  AWS_INSTANCE_SCENARIO=none EXPECTED_ENABLED=false run_toggle --env staging --enabled false --expected-api-dev-sha "$SHA_A" --expected-mirror-sha "$SHA_B"
  assert_eq "$RUN_EXIT_CODE" "1" "no running instance should fail"
  assert_contains "$RUN_STDOUT" "no running fjcloud-api-staging instances found" "no-instance error names target"
}

test_script_is_executable() {
  if [ -x "$TARGET_SCRIPT" ]; then
    pass "toggle script is executable"
  else
    fail "toggle script is executable"
  fi
}

test_rejects_invalid_env
test_rejects_invalid_boolean
test_rejects_missing_args
test_rejects_non_40_hex_sha
test_dry_run_does_not_write
test_execute_writes_and_proves_true_without_opening_migration
test_execute_is_idempotent
test_false_execute_stops_api_when_disabled_state_unproved
test_execute_proves_each_selected_instance
test_execute_does_not_transport_probe_token
test_rejects_no_running_instances
test_script_is_executable

run_test_summary
