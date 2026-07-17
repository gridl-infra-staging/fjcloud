#!/usr/bin/env bash
# Guarded owner for /fjcloud/<env>/aws_ami_id operational values.
# Dry-run is the default; --execute and --rollback are explicit mutations.
# Live mutation uses a cooperative DynamoDB lock. Direct out-of-band SSM writes
# are unsupported and outside this script's serialization contract.

set -euo pipefail

AWS_BIN="${FJCLOUD_AWS_BIN:-aws}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
POLL_ATTEMPTS="${FJCLOUD_FLAPJACK_POINTER_POLL_ATTEMPTS:-30}"
POLL_SLEEP_SECONDS="${FJCLOUD_FLAPJACK_POINTER_POLL_SLEEP_SECONDS:-2}"
LOCK_TABLE="fjcloud-tflock"

ENVIRONMENT=""
AMI_ID=""
EXPECTED_OLD_AMI_ID=""
MODE="dry-run"
INSTANCE_IDS=()
LOCK_OWNER_TOKEN=""
LOCK_ACQUIRED=0
WRITE_POINTER_STATE=""
WRITE_POINTER_READBACK=""
WRITE_POINTER_ERROR=""

usage() {
  cat <<'EOF'
Usage: set_flapjack_ami_pointer.sh --env <staging|prod> --ami-id <id> --expected-old-ami-id <id> [--execute|--rollback]

Dry-run is the default and performs no SSM writes or host commands.
--execute advances expected-old-ami-id to ami-id.
--rollback restores expected-old-ami-id when ami-id is currently published.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env) ENVIRONMENT="${2:-}"; shift 2 ;;
      --ami-id) AMI_ID="${2:-}"; shift 2 ;;
      --expected-old-ami-id) EXPECTED_OLD_AMI_ID="${2:-}"; shift 2 ;;
      --execute) [ "$MODE" = "dry-run" ] || die "choose only one mutation mode"; MODE="execute"; shift ;;
      --rollback) [ "$MODE" = "dry-run" ] || die "choose only one mutation mode"; MODE="rollback"; shift ;;
      --help|-h) usage; exit 0 ;;
      *) usage >&2; die "unknown argument: $1" ;;
    esac
  done
}

validate_args() {
  case "$ENVIRONMENT" in staging|prod) ;; *) die "--env must be staging or prod" ;; esac
  [[ "$AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || die "--ami-id must use AWS AMI ID format"
  [[ "$EXPECTED_OLD_AMI_ID" =~ ^ami-[0-9a-f]{8,17}$ ]] || die "--expected-old-ami-id must use AWS AMI ID format"
  if [ "$MODE" != "dry-run" ] && [ "$AMI_ID" = "$EXPECTED_OLD_AMI_ID" ]; then
    die "--ami-id and --expected-old-ami-id must differ for --execute or --rollback"
  fi
}

parameter_name() {
  printf '/fjcloud/%s/aws_ami_id\n' "$ENVIRONMENT"
}

lock_id() {
  printf 'fjcloud/flapjack-ami-pointer/%s\n' "$ENVIRONMENT"
}

json_string() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1]))
PY
}

generate_lock_owner_token() {
  python3 - <<'PY'
import secrets

print(secrets.token_hex(16))
PY
}

lock_item_json() {
  local lock_id_value="$1" owner_token="$2"
  printf '{"LockID":{"S":%s},"OwnerToken":{"S":%s},"Purpose":{"S":"flapjack-ami-pointer"}}\n' \
    "$(json_string "$lock_id_value")" \
    "$(json_string "$owner_token")"
}

lock_key_json() {
  local lock_id_value="$1"
  printf '{"LockID":{"S":%s}}\n' "$(json_string "$lock_id_value")"
}

lock_owner_values_json() {
  local owner_token="$1"
  printf '{":owner_token":{"S":%s}}\n' "$(json_string "$owner_token")"
}

release_pointer_lock() {
  local output
  [ "$LOCK_ACQUIRED" -eq 1 ] || return 0
  if output="$("$AWS_BIN" dynamodb delete-item \
    --region "$REGION" \
    --table-name "$LOCK_TABLE" \
    --key "$(lock_key_json "$(lock_id)")" \
    --condition-expression 'OwnerToken = :owner_token' \
    --expression-attribute-values "$(lock_owner_values_json "$LOCK_OWNER_TOKEN")" 2>&1)"; then
    LOCK_ACQUIRED=0
    return 0
  fi

  echo "ERROR: LOCK_RELEASE_FAILED: ${output}" >&2
  return 1
}

release_pointer_lock_or_die() {
  release_pointer_lock || die "LOCK_RELEASE_FAILED: cooperative pointer lock was not released"
}

cleanup_pointer_lock() {
  release_pointer_lock >/dev/null || true
}

acquire_pointer_lock() {
  local output
  LOCK_OWNER_TOKEN="$(generate_lock_owner_token)"
  if output="$("$AWS_BIN" dynamodb put-item \
    --region "$REGION" \
    --table-name "$LOCK_TABLE" \
    --item "$(lock_item_json "$(lock_id)" "$LOCK_OWNER_TOKEN")" \
    --condition-expression 'attribute_not_exists(LockID)' 2>&1)"; then
    LOCK_ACQUIRED=1
    trap cleanup_pointer_lock EXIT INT TERM
    return 0
  fi

  if [[ "$output" == *"ConditionalCheckFailedException"* ]]; then
    die "LOCK_HELD: Flapjack AMI pointer lock is already held for ${ENVIRONMENT}"
  fi
  die "LOCK_ACQUIRE_FAILED: ${output}"
}

current_pointer() {
  "$AWS_BIN" ssm get-parameter \
    --region "$REGION" \
    --name "$(parameter_name)" \
    --query 'Parameter.Value' \
    --output text
}

validate_ami_identity() {
  local requested_ami_id="$1" account_id image_json
  account_id="$("$AWS_BIN" sts get-caller-identity --query Account --output text)"
  image_json="$("$AWS_BIN" ec2 describe-images --region "$REGION" --image-ids "$requested_ami_id" --output json)"

  AMI_JSON="$image_json" python3 - "$ENVIRONMENT" "$account_id" <<'PY' || \
    die "AMI_VALIDATION_FAILED: AMI identity, environment, architecture, or manifest tags are invalid"
import json
import os
import sys

environment, account_id = sys.argv[1:]
images = json.loads(os.environ["AMI_JSON"]).get("Images", [])
if len(images) != 1:
    raise SystemExit("expected exactly one image")
image = images[0]
tags = {tag["Key"]: tag["Value"] for tag in image.get("Tags", [])}
required = {
    "Architecture": "arm64",
    "State": "available",
    "OwnerId": account_id,
}
for key, expected in required.items():
    if image.get(key) != expected:
        raise SystemExit(f"{key} mismatch")
if not image.get("Name", "").startswith("flapjack-"):
    raise SystemExit("image name is not a Flapjack build")
if tags.get("Env") != environment or tags.get("managed-by") != "packer" or tags.get("service") != "fjcloud":
    raise SystemExit("manifest identity tags mismatch")
PY
}

discover_instances() {
  "$AWS_BIN" ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=fjcloud-api-${ENVIRONMENT}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | tr '\t' '\n' | sed '/^$/d;/^None$/d'
}

json_commands() {
  python3 - "$1" <<'PY'
import json
import sys
print(json.dumps({"commands": [sys.argv[1]]}))
PY
}

send_remote_command() {
  local instance_id="$1" comment="$2" script="$3"
  "$AWS_BIN" ssm send-command \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --parameters "$(json_commands "$script")" \
    --timeout-seconds 180 \
    --comment "$comment" \
    --query 'Command.CommandId' \
    --output text
}

poll_remote_command() {
  local instance_id="$1" command_id="$2" status
  for _ in $(seq 1 "$POLL_ATTEMPTS"); do
    status="$("$AWS_BIN" ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$instance_id" --query Status --output text 2>/dev/null || echo Pending)"
    case "$status" in
      Success)
        "$AWS_BIN" ssm get-command-invocation --region "$REGION" --command-id "$command_id" --instance-id "$instance_id" --query StandardOutputContent --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled|Cancelling) return 1 ;;
      *) sleep "$POLL_SLEEP_SECONDS" ;;
    esac
  done
  return 1
}

inspection_script() {
  cat <<'EOF'
set -euo pipefail
pointer="$(grep '^AWS_AMI_ID=' /etc/fjcloud/env | tail -n1 | cut -d= -f2-)"
version_json="$(curl -fsS http://127.0.0.1:3001/version)"
printf 'POINTER=%s\nVERSION_JSON=%s\n' "$pointer" "$version_json"
EOF
}

reconcile_script() {
  cat <<EOF
set -euo pipefail
/opt/fjcloud/scripts/generate_ssm_env.sh "$ENVIRONMENT"
systemctl restart fjcloud-api
$(inspection_script)
EOF
}

validate_instance_proof() {
  local instance_id="$1" proof_output="$2" expected_pointer="$3"
  PROOF_OUTPUT="$proof_output" python3 - "$instance_id" "$expected_pointer" <<'PY'
import json
import os
import re
import sys

instance_id, expected_pointer = sys.argv[1:]
fields = dict(line.split("=", 1) for line in os.environ["PROOF_OUTPUT"].splitlines() if "=" in line)
if fields.get("POINTER") != expected_pointer:
    raise SystemExit(f"{instance_id}: pointer mismatch")
version = json.loads(fields.get("VERSION_JSON", "{}"))
if not re.fullmatch(r"[0-9a-f]{40}", str(version.get("dev_sha", ""))):
    raise SystemExit(f"{instance_id}: served /version dev_sha is invalid")
PY
}

prove_instances() {
  local phase="$1" expected="$2" script="$3" instance_id command_id output
  for instance_id in "${INSTANCE_IDS[@]}"; do
    command_id="$(send_remote_command "$instance_id" "fjcloud flapjack pointer ${phase} ${ENVIRONMENT}" "$script")"
    output="$(poll_remote_command "$instance_id" "$command_id")" || return 1
    validate_instance_proof "$instance_id" "$output" "$expected" || return 1
  done
}

write_pointer() {
  local value="$1" prior_value="$2" output readback
  WRITE_POINTER_STATE=""
  WRITE_POINTER_READBACK=""
  WRITE_POINTER_ERROR=""

  if ! output="$("$AWS_BIN" ssm put-parameter --region "$REGION" --name "$(parameter_name)" --type String --value "$value" --overwrite 2>&1)"; then
    WRITE_POINTER_STATE="SSM_WRITE_FAILED"
    WRITE_POINTER_ERROR="$output"
    return 0
  fi

  if ! readback="$(current_pointer 2>&1)"; then
    WRITE_POINTER_STATE="SSM_READBACK_UNCERTAIN"
    WRITE_POINTER_ERROR="$readback"
    return 0
  fi

  WRITE_POINTER_READBACK="$readback"
  if [ "$readback" = "$value" ]; then
    WRITE_POINTER_STATE="SSM_WRITE_PROVED"
  elif [ "$readback" = "$prior_value" ]; then
    WRITE_POINTER_STATE="SSM_READBACK_PRIOR"
  else
    WRITE_POINTER_STATE="SSM_OWNERSHIP_VIOLATION"
  fi
}

require_proved_pointer_write() {
  local desired_value="$1" prior_value="$2" fail_closed_on_unproved="$3"
  write_pointer "$desired_value" "$prior_value"
  case "$WRITE_POINTER_STATE" in
    SSM_WRITE_PROVED) return 0 ;;
    SSM_WRITE_FAILED)
      [ "$fail_closed_on_unproved" -eq 0 ] || fail_closed_stop_all
      die "SSM_WRITE_FAILED: pointer write was not accepted: ${WRITE_POINTER_ERROR}"
      ;;
    SSM_READBACK_UNCERTAIN)
      [ "$fail_closed_on_unproved" -eq 0 ] || fail_closed_stop_all
      die "SSM_READBACK_UNCERTAIN: pointer write accepted but readback failed: ${WRITE_POINTER_ERROR}"
      ;;
    SSM_READBACK_PRIOR)
      [ "$fail_closed_on_unproved" -eq 0 ] || fail_closed_stop_all
      die "SSM_WRITE_NOT_PROVED: pointer readback remained at prior value ${prior_value}"
      ;;
    SSM_OWNERSHIP_VIOLATION)
      fail_closed_stop_all
      die "SSM_OWNERSHIP_VIOLATION: pointer readback changed to unsupported value ${WRITE_POINTER_READBACK}"
      ;;
    *) die "SSM_WRITE_STATE_UNKNOWN: ${WRITE_POINTER_STATE}" ;;
  esac
}

stop_api_service() {
  local instance_id="$1" command_id
  command_id="$(send_remote_command "$instance_id" "fjcloud flapjack pointer fail-closed stop ${ENVIRONMENT}" "set -euo pipefail
systemctl stop fjcloud-api")"
  poll_remote_command "$instance_id" "$command_id" >/dev/null
}

fail_closed_stop_all() {
  local instance_id
  echo "==> Fail-closed: stopping fjcloud-api on selected ${ENVIRONMENT} instances" >&2
  for instance_id in "${INSTANCE_IDS[@]}"; do
    stop_api_service "$instance_id" || echo "ERROR: failed to stop fjcloud-api on ${instance_id}" >&2
  done
}

rollback_after_failure() {
  echo "==> Execute proof failed; restoring ${EXPECTED_OLD_AMI_ID}" >&2
  require_proved_pointer_write "$EXPECTED_OLD_AMI_ID" "$AMI_ID" 1
  if prove_instances rollback "$EXPECTED_OLD_AMI_ID" "$(reconcile_script)"; then
    echo "ROLLBACK_COMPLETE: pointer and API hosts restored" >&2
  else
    fail_closed_stop_all
    die "ROLLBACK_FAILED: pointer restored but host reconciliation was not proved"
  fi
}

load_instances() {
  local instance_id
  while IFS= read -r instance_id; do
    [ -z "$instance_id" ] || INSTANCE_IDS+=("$instance_id")
  done < <(discover_instances)
  [ "${#INSTANCE_IDS[@]}" -gt 0 ] || die "no running fjcloud-api-${ENVIRONMENT} instances found"
}

main() {
  local current desired identity_ami_id preflight_expected
  parse_args "$@"
  validate_args
  if [ "$MODE" != "dry-run" ]; then
    acquire_pointer_lock
  fi
  identity_ami_id="$AMI_ID"
  if [ "$MODE" = "rollback" ]; then
    identity_ami_id="$EXPECTED_OLD_AMI_ID"
  fi
  validate_ami_identity "$identity_ami_id"
  load_instances
  current="$(current_pointer)"

  echo "==> Target parameter: $(parameter_name)"
  echo "==> Selected API instances: ${INSTANCE_IDS[*]}"
  echo "==> Current pointer: ${current}; requested pointer: ${AMI_ID}; mode: ${MODE}"
  if [ "$MODE" = "dry-run" ]; then
    [ "$current" = "$EXPECTED_OLD_AMI_ID" ] || die "CAS_MISMATCH: current pointer does not equal --expected-old-ami-id"
    if [ "$current" = "$AMI_ID" ]; then
      echo "NO_CHANGE: current pointer already matches requested AMI; no SSM writes or host commands planned"
      return 0
    fi
    echo "PLAN: would update $(parameter_name) from ${EXPECTED_OLD_AMI_ID} to ${AMI_ID}, regenerate env, restart fjcloud-api, and prove served /version SHA"
    echo "==> Dry-run: validation passed; no SSM writes or host commands performed"
    return 0
  fi

  if [ "$MODE" = "execute" ]; then
    [ "$current" != "$AMI_ID" ] || { echo "NO_OP: requested AMI is already published"; release_pointer_lock_or_die; return 0; }
    [ "$current" = "$EXPECTED_OLD_AMI_ID" ] || die "CAS_MISMATCH: current pointer is neither expected old nor requested AMI"
    desired="$AMI_ID"
    preflight_expected="$EXPECTED_OLD_AMI_ID"
  else
    [ "$current" != "$EXPECTED_OLD_AMI_ID" ] || { echo "NO_OP: rollback target is already published"; release_pointer_lock_or_die; return 0; }
    [ "$current" = "$AMI_ID" ] || die "CAS_MISMATCH: rollback requires the requested AMI to be current"
    desired="$EXPECTED_OLD_AMI_ID"
    preflight_expected="$AMI_ID"
  fi

  prove_instances preflight "$preflight_expected" "$(inspection_script)" \
    || die "MIXED_STATE: API host pointers do not unanimously match canonical SSM state"
  require_proved_pointer_write "$desired" "$preflight_expected" 0

  if prove_instances "$MODE" "$desired" "$(reconcile_script)"; then
    echo "==> Pointer ${desired} and served /version SHA proved on all ${ENVIRONMENT} API instances"
    release_pointer_lock_or_die
    return 0
  fi

  if [ "$MODE" = "execute" ]; then
    rollback_after_failure
    die "EXECUTE_FAILED: requested pointer could not be proved; rollback completed"
  fi
  fail_closed_stop_all
  die "ROLLBACK_FAILED: rollback pointer was written but host reconciliation was not proved"
}

main "$@"
