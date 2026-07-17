#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/ops/scripts/set_flapjack_ami_pointer.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

OLD_AMI="ami-0aaa1111222233334"
NEW_AMI="ami-0bbb1111222233335"
OTHER_AMI="ami-0ccc1111222233336"
WORK_DIR=""
RUN_OUTPUT=""
RUN_EXIT_CODE=0

cleanup() {
  [ -z "$WORK_DIR" ] || rm -rf "$WORK_DIR"
}
trap cleanup EXIT

setup_workspace() {
  cleanup
  WORK_DIR="$(mktemp -d)"
  mkdir -p "$WORK_DIR/bin" "$WORK_DIR/state"
  printf '%s\n' "${INITIAL_STAGING_AMI:-$OLD_AMI}" >"$WORK_DIR/state/staging"
  printf '%s\n' "${INITIAL_PROD_AMI:-$OLD_AMI}" >"$WORK_DIR/state/prod"
  : >"$WORK_DIR/state/get_count"
  : >"$WORK_DIR/aws.log"

  cat >"$WORK_DIR/bin/aws" <<'AWS_EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$AWS_LOG"

argument() {
  local wanted="$1"
  shift
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "$wanted" ]; then printf '%s\n' "$2"; return; fi
    shift
  done
}

json_field() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

obj = json.loads(sys.argv[1])
path = sys.argv[2].split(".")
for part in path:
    obj = obj[part]
print(obj)
PY
}

lock_path() {
  local lock_id="$1" safe_id
  safe_id="$(printf '%s' "$lock_id" | tr -c 'A-Za-z0-9_.-' '_')"
  printf '%s/lock_%s\n' "$AWS_STATE_DIR" "$safe_id"
}

if [ "$1 $2" = "sts get-caller-identity" ]; then
  printf '123456789012\n'
elif [ "$1 $2" = "ec2 describe-images" ]; then
  env_name="${AWS_IMAGE_ENV:-staging}"
  cat <<JSON
{"Images":[{"ImageId":"${AWS_REQUESTED_AMI}","Architecture":"${AWS_IMAGE_ARCH:-arm64}","State":"available","OwnerId":"123456789012","Name":"flapjack-1.2.3-20260715","Tags":[{"Key":"Env","Value":"${env_name}"},{"Key":"managed-by","Value":"packer"},{"Key":"service","Value":"fjcloud"}]}]}
JSON
elif [ "$1 $2" = "ec2 describe-instances" ]; then
  filters="$*"
  if [[ "$filters" == *"fjcloud-api-prod"* ]]; then printf 'i-prod-1\n'; else printf 'i-staging-1\n'; fi
elif [ "$1 $2" = "ssm get-parameter" ]; then
  name="$(argument --name "$@")"
  env_name="${name#/fjcloud/}"
  env_name="${env_name%%/*}"
  get_count="$(cat "$AWS_STATE_DIR/get_count")"
  get_count="${get_count:-0}"
  printf '%s\n' "$((get_count + 1))" >"$AWS_STATE_DIR/get_count"
  if [ -f "$AWS_STATE_DIR/put_seen_$env_name" ] && [ "${AWS_READBACK_SCENARIO:-success}" = "error_after_put" ]; then
    echo "simulated get-parameter readback failure" >&2
    exit 42
  fi
  cat "$AWS_STATE_DIR/$env_name"
elif [ "$1 $2" = "ssm put-parameter" ]; then
  name="$(argument --name "$@")"
  value="$(argument --value "$@")"
  env_name="${name#/fjcloud/}"
  env_name="${env_name%%/*}"
  : >"$AWS_STATE_DIR/put_seen_$env_name"
  case "${AWS_READBACK_SCENARIO:-success}" in
    prior_after_put) ;;
    third_after_put) printf '%s\n' "$OTHER_AMI" >"$AWS_STATE_DIR/$env_name" ;;
    *) printf '%s\n' "$value" >"$AWS_STATE_DIR/$env_name" ;;
  esac
  printf '1\n'
elif [ "$1 $2" = "dynamodb put-item" ]; then
  item="$(argument --item "$@")"
  lock_id="$(json_field "$item" "LockID.S")"
  owner_token="$(json_field "$item" "OwnerToken.S")"
  lock_file="$(lock_path "$lock_id")"
  if [ -f "$lock_file" ]; then
    echo "An error occurred (ConditionalCheckFailedException) when calling the PutItem operation" >&2
    exit 254
  fi
  printf '%s\n' "$owner_token" >"$lock_file"
  printf 'ok\n'
elif [ "$1 $2" = "dynamodb delete-item" ]; then
  key="$(argument --key "$@")"
  values="$(argument --expression-attribute-values "$@")"
  lock_id="$(json_field "$key" "LockID.S")"
  owner_token="$(json_field "$values" ":owner_token.S")"
  lock_file="$(lock_path "$lock_id")"
  if [ ! -f "$lock_file" ] || [ "$(cat "$lock_file")" != "$owner_token" ]; then
    echo "An error occurred (ConditionalCheckFailedException) when calling the DeleteItem operation" >&2
    exit 254
  fi
  rm -f "$lock_file"
  printf 'ok\n'
elif [ "$1 $2" = "ssm send-command" ]; then
  comment="$(argument --comment "$@")"
  if [[ "$comment" == *"execute"* ]] && [ "${AWS_LOCK_TAMPER_ON_APPLY:-0}" = "1" ]; then
    lock_file="$(lock_path "fjcloud/flapjack-ami-pointer/staging")"
    printf 'different-owner\n' >"$lock_file"
  fi
  case "$comment" in
    *preflight*prod*) printf 'cmd-preflight-prod\n' ;;
    *preflight*) printf 'cmd-preflight-staging\n' ;;
    *fail-closed*) printf 'cmd-stop\n' ;;
    *rollback*) printf 'cmd-rollback\n' ;;
    *) printf 'cmd-apply\n' ;;
  esac
elif [ "$1 $2" = "ssm get-command-invocation" ]; then
  command_id="$(argument --command-id "$@")"
  query="$(argument --query "$@")"
  if [ "$query" = "Status" ]; then
    if { [ "$command_id" = "cmd-apply" ] && [[ "${AWS_REMOTE_SCENARIO:-success}" = *_failure ]]; } || \
       { [ "$command_id" = "cmd-rollback" ] && [ "${AWS_REMOTE_SCENARIO:-success}" = "rollback_failure" ]; }; then
      printf 'Failed\n'
    else
      printf 'Success\n'
    fi
  elif [ "$query" = "StandardOutputContent" ]; then
    case "$command_id" in
      cmd-preflight-*)
        if [ "${AWS_REMOTE_SCENARIO:-success}" = "mixed" ]; then
          printf 'POINTER=%s\nVERSION_JSON={"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$OTHER_AMI"
        else
          env_name="${command_id#cmd-preflight-}"
          printf 'POINTER=%s\nVERSION_JSON={"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$(cat "$AWS_STATE_DIR/$env_name")"
        fi
        ;;
      cmd-rollback) printf 'POINTER=%s\nVERSION_JSON={"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$OLD_AMI" ;;
      *) printf 'POINTER=%s\nVERSION_JSON={"dev_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' "$NEW_AMI" ;;
    esac
  else
    printf 'failure detail\n'
  fi
else
  echo "unexpected aws invocation: $*" >&2
  exit 1
fi
AWS_EOF
  chmod +x "$WORK_DIR/bin/aws"
}

lock_file_for_env() {
  local env_name="$1" safe_id
  safe_id="$(printf '%s' "fjcloud/flapjack-ami-pointer/$env_name" | tr -c 'A-Za-z0-9_.-' '_')"
  printf '%s/state/lock_%s\n' "$WORK_DIR" "$safe_id"
}

hold_lock_for_env() {
  local env_name="$1" owner="$2"
  printf '%s\n' "$owner" >"$(lock_file_for_env "$env_name")"
}

count_aws_log_entries() {
  local pattern="$1"
  grep -c "$pattern" "$WORK_DIR/aws.log" || true
}

run_pointer() {
  RUN_EXIT_CODE=0
  local invocation
  if [ "${RUN_POINTER_DIRECT:-0}" = "1" ]; then
    invocation=("$TARGET_SCRIPT")
  else
    invocation=(bash "$TARGET_SCRIPT")
  fi
  RUN_OUTPUT="$(
    AWS_LOG="$WORK_DIR/aws.log" \
      AWS_STATE_DIR="$WORK_DIR/state" \
      AWS_REQUESTED_AMI="${AWS_REQUESTED_AMI_OVERRIDE:-$NEW_AMI}" \
      AWS_IMAGE_ENV="${AWS_IMAGE_ENV:-staging}" \
      AWS_IMAGE_ARCH="${AWS_IMAGE_ARCH:-arm64}" \
      AWS_REMOTE_SCENARIO="${AWS_REMOTE_SCENARIO:-success}" \
      AWS_READBACK_SCENARIO="${AWS_READBACK_SCENARIO:-success}" \
      AWS_LOCK_TAMPER_ON_APPLY="${AWS_LOCK_TAMPER_ON_APPLY:-0}" \
      OLD_AMI="$OLD_AMI" \
      NEW_AMI="$NEW_AMI" \
      OTHER_AMI="$OTHER_AMI" \
      FJCLOUD_AWS_BIN="$WORK_DIR/bin/aws" \
      FJCLOUD_FLAPJACK_POINTER_POLL_SLEEP_SECONDS=0 \
      "${invocation[@]}" "$@" 2>&1
  )" || RUN_EXIT_CODE=$?
}

test_dry_run_is_environment_scoped_and_write_free() {
  setup_workspace
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI"
  assert_eq "$RUN_EXIT_CODE" "0" "staging dry-run succeeds"
  assert_contains "$RUN_OUTPUT" "/fjcloud/staging/aws_ami_id" "staging dry-run names only staging pointer"
  assert_contains "$RUN_OUTPUT" "Selected API instances: i-staging-1" "staging dry-run names selected API instances"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "dry-run performs zero SSM writes"
  assert_eq "$(cat "$WORK_DIR/state/prod")" "$OLD_AMI" "staging dry-run leaves prod unchanged"
}

test_dry_run_current_value_reports_no_change_without_writes() {
  setup_workspace
  AWS_REQUESTED_AMI_OVERRIDE="$OLD_AMI" run_pointer --env staging --ami-id "$OLD_AMI" --expected-old-ami-id "$OLD_AMI"
  assert_eq "$RUN_EXIT_CODE" "0" "current-value dry-run succeeds"
  assert_contains "$RUN_OUTPUT" "NO_CHANGE" "current-value dry-run reports a no-change plan"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "current-value dry-run performs zero SSM writes"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm send-command" "current-value dry-run performs zero host commands"
}

test_equal_execute_and_rollback_args_are_rejected() {
  setup_workspace
  AWS_REQUESTED_AMI_OVERRIDE="$OLD_AMI" run_pointer --env staging --ami-id "$OLD_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "equal execute args fail"
  assert_contains "$RUN_OUTPUT" "must differ" "equal execute args explain ambiguity"
  AWS_REQUESTED_AMI_OVERRIDE="$OLD_AMI" run_pointer --env staging --ami-id "$OLD_AMI" --expected-old-ami-id "$OLD_AMI" --rollback
  assert_eq "$RUN_EXIT_CODE" "1" "equal rollback args fail"
  assert_contains "$RUN_OUTPUT" "must differ" "equal rollback args explain ambiguity"
}

test_prod_execute_isolated_from_staging() {
  setup_workspace
  AWS_IMAGE_ENV=prod run_pointer --env prod --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "prod execute succeeds"
  assert_eq "$(cat "$WORK_DIR/state/prod")" "$NEW_AMI" "prod pointer advances"
  assert_eq "$(cat "$WORK_DIR/state/staging")" "$OLD_AMI" "prod execute leaves staging unchanged"
}

test_compare_and_swap_mismatch_is_typed() {
  INITIAL_STAGING_AMI="$OTHER_AMI" setup_workspace
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "wrong expected old AMI fails"
  assert_contains "$RUN_OUTPUT" "CAS_MISMATCH" "CAS mismatch has a typed classifier"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "CAS mismatch refuses all writes"
}

test_lock_held_blocks_competing_writer_without_side_effects() {
  setup_workspace
  hold_lock_for_env staging writer-a
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "competing writer fails while lock is held"
  assert_contains "$RUN_OUTPUT" "LOCK_HELD" "competing writer reports typed lock-held classifier"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "lock-held writer performs zero pointer writes"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm send-command" "lock-held writer performs zero host commands"
  assert_eq "$(cat "$(lock_file_for_env staging)")" "writer-a" "lock-held writer does not release another owner"
}

test_writer_acquires_after_release_and_rereads_pointer_before_compare() {
  setup_workspace
  hold_lock_for_env staging writer-a
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  rm -f "$(lock_file_for_env staging)"
  : >"$WORK_DIR/aws.log"
  printf '%s\n' "$OTHER_AMI" >"$WORK_DIR/state/staging"
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "writer rechecks pointer after acquiring released lock"
  assert_contains "$RUN_OUTPUT" "CAS_MISMATCH" "post-lock reread drives the compare result"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "dynamodb put-item" "writer acquired the cooperative lock"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "ssm get-parameter" "writer reread SSM after lock acquisition"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "post-lock CAS mismatch performs zero pointer writes"
}

test_abandoned_lock_fails_closed_without_auto_steal() {
  setup_workspace
  hold_lock_for_env staging abandoned-owner
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "abandoned lock refuses execution"
  assert_contains "$RUN_OUTPUT" "LOCK_HELD" "abandoned lock uses the same lock-held classifier"
  assert_eq "$(cat "$(lock_file_for_env staging)")" "abandoned-owner" "abandoned lock is not stolen or deleted"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "abandoned lock performs zero pointer writes"
}

test_conditional_release_cannot_delete_another_owner_lock() {
  setup_workspace
  AWS_LOCK_TAMPER_ON_APPLY=1 run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "owner-token release failure fails the operation"
  assert_contains "$RUN_OUTPUT" "LOCK_RELEASE_FAILED" "release failure is typed"
  assert_eq "$(cat "$(lock_file_for_env staging)")" "different-owner" "conditional release leaves another owner lock intact"
}

test_readback_error_after_put_is_typed_and_stops_before_apply() {
  setup_workspace
  AWS_READBACK_SCENARIO=error_after_put run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "readback error fails execute"
  assert_contains "$RUN_OUTPUT" "SSM_READBACK_UNCERTAIN" "readback error has a typed classifier"
  assert_eq "$(count_aws_log_entries "ssm put-parameter")" "1" "readback error performs exactly one pointer write attempt"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "flapjack pointer execute" "readback error stops before apply host reconciliation"
}

test_third_value_readback_never_overwrites_and_stops_api() {
  setup_workspace
  AWS_READBACK_SCENARIO=third_after_put run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "third-value readback fails execute"
  assert_contains "$RUN_OUTPUT" "SSM_OWNERSHIP_VIOLATION" "third-value readback has a typed classifier"
  assert_eq "$(cat "$WORK_DIR/state/staging")" "$OTHER_AMI" "third-value readback is never overwritten"
  assert_eq "$(count_aws_log_entries "ssm put-parameter")" "1" "third-value readback performs exactly one pointer write attempt"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "fail-closed stop staging" "third-value readback stops selected API hosts"
}

test_restart_failure_rolls_back() {
  setup_workspace
  AWS_REMOTE_SCENARIO=restart_failure run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "restart failure fails execute"
  assert_eq "$(cat "$WORK_DIR/state/staging")" "$OLD_AMI" "restart failure restores prior pointer"
  assert_contains "$RUN_OUTPUT" "ROLLBACK_COMPLETE" "failed execute reports completed rollback"
}

test_unproved_rollback_stops_api_fail_closed() {
  setup_workspace
  AWS_REMOTE_SCENARIO=rollback_failure run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "unproved rollback fails execute"
  assert_eq "$(cat "$WORK_DIR/state/staging")" "$OLD_AMI" "unproved rollback still restores canonical pointer"
  assert_contains "$RUN_OUTPUT" "Fail-closed: stopping fjcloud-api" "unproved rollback enters fail-closed mode"
  assert_contains "$(cat "$WORK_DIR/aws.log")" "fail-closed stop staging" "unproved rollback sends a stop command"
}

test_rollback_and_rerun_are_idempotent() {
  INITIAL_STAGING_AMI="$NEW_AMI" setup_workspace
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --rollback
  assert_eq "$RUN_EXIT_CODE" "0" "rollback restores old AMI"
  assert_eq "$(cat "$WORK_DIR/state/staging")" "$OLD_AMI" "rollback writes expected old AMI"
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --rollback
  assert_eq "$RUN_EXIT_CODE" "0" "second rollback is a no-op"
  assert_contains "$RUN_OUTPUT" "NO_OP" "idempotent rollback reports no-op"
}

test_execute_rerun_is_no_op() {
  INITIAL_STAGING_AMI="$NEW_AMI" setup_workspace
  run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "0" "execute rerun succeeds"
  assert_contains "$RUN_OUTPUT" "NO_OP" "execute rerun reports no-op"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "execute rerun performs zero writes"
}

test_mixed_instance_state_fails_before_write() {
  setup_workspace
  AWS_REMOTE_SCENARIO=mixed run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "mixed host state fails closed"
  assert_contains "$RUN_OUTPUT" "MIXED_STATE" "mixed host state has a typed classifier"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "mixed host state refuses mutation"
}

test_rollback_invalid_restore_target_fails_before_write_or_host_command() {
  INITIAL_STAGING_AMI="$NEW_AMI" setup_workspace
  AWS_IMAGE_ENV=prod run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --rollback
  assert_eq "$RUN_EXIT_CODE" "1" "rollback rejects invalid restore target"
  assert_contains "$RUN_OUTPUT" "AMI_VALIDATION_FAILED" "rollback restore target validation is typed"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "invalid rollback target performs zero pointer writes"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm send-command" "invalid rollback target performs zero host commands"
}

test_wrong_architecture_fails_before_write() {
  setup_workspace
  AWS_IMAGE_ARCH=x86_64 run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI" --execute
  assert_eq "$RUN_EXIT_CODE" "1" "wrong AMI architecture fails"
  assert_contains "$RUN_OUTPUT" "AMI_VALIDATION_FAILED" "AMI validation failure is typed"
  assert_not_contains "$(cat "$WORK_DIR/aws.log")" "ssm put-parameter" "invalid AMI refuses mutation"
}

test_script_is_executable_and_direct_invocation_works() {
  setup_workspace
  RUN_POINTER_DIRECT=1 run_pointer --env staging --ami-id "$NEW_AMI" --expected-old-ami-id "$OLD_AMI"
  assert_eq "$RUN_EXIT_CODE" "0" "direct executable dry-run succeeds"
  assert_contains "$RUN_OUTPUT" "Dry-run: validation passed" "direct executable invocation uses the script entrypoint"
}

test_dry_run_is_environment_scoped_and_write_free
test_dry_run_current_value_reports_no_change_without_writes
test_equal_execute_and_rollback_args_are_rejected
test_prod_execute_isolated_from_staging
test_compare_and_swap_mismatch_is_typed
test_lock_held_blocks_competing_writer_without_side_effects
test_writer_acquires_after_release_and_rereads_pointer_before_compare
test_abandoned_lock_fails_closed_without_auto_steal
test_conditional_release_cannot_delete_another_owner_lock
test_readback_error_after_put_is_typed_and_stops_before_apply
test_third_value_readback_never_overwrites_and_stops_api
test_restart_failure_rolls_back
test_unproved_rollback_stops_api_fail_closed
test_rollback_and_rerun_are_idempotent
test_execute_rerun_is_no_op
test_mixed_instance_state_fails_before_write
test_rollback_invalid_restore_target_fails_before_write_or_host_command
test_wrong_architecture_fails_before_write
test_script_is_executable_and_direct_invocation_works

run_test_summary
