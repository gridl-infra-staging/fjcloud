#!/usr/bin/env bash
# rds_restore_drill.sh — operator-only restore rehearsal entrypoint
#
# Usage: rds_restore_drill.sh <env> [options]
#   env: staging | prod
#
# Required options:
#   --source-db-instance-id <id>
#   --target-db-instance-id <id>
#
# Exactly one restore mode is required:
#   --snapshot-id <snapshot-id>
#   --restore-time <RFC3339 timestamp>
#
set -euo pipefail

ENV=""
REGION="us-east-1"
SOURCE_DB_INSTANCE_ID=""
TARGET_DB_INSTANCE_ID=""
SNAPSHOT_ID=""
RESTORE_TIME=""
RESTORE_MODE=""
SOURCE_DB_SUBNET_GROUP_NAME=""
RESTORE_COMMAND=()

usage() {
  cat <<'EOF'
Usage: rds_restore_drill.sh <env> [options]
  env: staging | prod

Required options:
  --source-db-instance-id <id>
  --target-db-instance-id <id>

Exactly one restore mode selector is required:
  --snapshot-id <snapshot-id>
  --restore-time <RFC3339 timestamp>

EOF
}

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  ENV="$1"
  shift

  if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
    echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
    usage
    exit 1
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source-db-instance-id)
        [[ $# -ge 2 ]] || {
          echo "ERROR: --source-db-instance-id requires a value"
          exit 1
        }
        SOURCE_DB_INSTANCE_ID="$2"
        shift 2
        ;;
      --target-db-instance-id)
        [[ $# -ge 2 ]] || {
          echo "ERROR: --target-db-instance-id requires a value"
          exit 1
        }
        TARGET_DB_INSTANCE_ID="$2"
        shift 2
        ;;
      --snapshot-id)
        [[ $# -ge 2 ]] || {
          echo "ERROR: --snapshot-id requires a value"
          exit 1
        }
        SNAPSHOT_ID="$2"
        shift 2
        ;;
      --restore-time)
        [[ $# -ge 2 ]] || {
          echo "ERROR: --restore-time requires a value"
          exit 1
        }
        RESTORE_TIME="$2"
        shift 2
        ;;
      --master-user-password|--master-user-password=*)
        echo "ERROR: --master-user-password is not supported because CLI arguments can leak secrets via process inspection"
        echo "ERROR: rotate credentials or use an AWS-managed secret path instead of passing a password to this script"
        exit 1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR: unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$SOURCE_DB_INSTANCE_ID" || -z "$TARGET_DB_INSTANCE_ID" ]]; then
    echo "ERROR: both --source-db-instance-id and --target-db-instance-id are required"
    usage
    exit 1
  fi
}

validate_restore_mode() {
  local has_snapshot=false
  local has_restore_time=false

  if [[ -n "$SNAPSHOT_ID" ]]; then
    has_snapshot=true
  fi
  if [[ -n "$RESTORE_TIME" ]]; then
    has_restore_time=true
  fi

  if [[ "$has_snapshot" == true && "$has_restore_time" == true ]]; then
    echo "ERROR: provide exactly one restore mode selector (--snapshot-id or --restore-time)"
    exit 1
  fi

  if [[ "$has_snapshot" == false && "$has_restore_time" == false ]]; then
    echo "ERROR: provide exactly one restore mode selector (--snapshot-id or --restore-time)"
    exit 1
  fi

  if [[ "$has_snapshot" == true ]]; then
    RESTORE_MODE="snapshot"
    return
  fi
  RESTORE_MODE="pitr"
}

validate_target_instance() {
  if [[ "$SOURCE_DB_INSTANCE_ID" == "$TARGET_DB_INSTANCE_ID" ]]; then
    echo "ERROR: --source-db-instance-id and --target-db-instance-id must be different"
    exit 1
  fi
}

require_execute_gate() {
  if [[ -n "${RDS_RESTORE_DRILL_EXECUTE:-}" && "${RDS_RESTORE_DRILL_EXECUTE}" != "1" ]]; then
    echo "ERROR: RDS_RESTORE_DRILL_EXECUTE must be unset or set to 1 (RDS_RESTORE_DRILL_EXECUTE=1 enables live execution)"
    exit 1
  fi
}

resolve_source_subnet_group() {
  local describe_payload=""
  local parse_output=""
  local parsed_identifier=""
  local parsed_subnet_group=""
  local describe_exit=0
  local parse_exit=0

  set +e
  describe_payload="$(
    AWS_PAGER="" aws rds describe-db-instances \
      --region "$REGION" \
      --db-instance-identifier "$SOURCE_DB_INSTANCE_ID" \
      --no-cli-pager \
      --output json
  )"
  describe_exit=$?
  set -e

  if [[ "$describe_exit" -ne 0 ]]; then
    echo "ERROR: unable to describe source DB instance '$SOURCE_DB_INSTANCE_ID' while resolving subnet group (exit $describe_exit)"
    exit 1
  fi

  set +e
  parse_output="$(
    python3 - <(printf '%s\n' "$describe_payload") <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
instances = payload.get("DBInstances", [])
if not instances:
    print("\t")
    raise SystemExit(0)

instance = instances[0]
identifier = str(instance.get("DBInstanceIdentifier", ""))
subnet_group = (instance.get("DBSubnetGroup") or {}).get("DBSubnetGroupName", "")
print(f"{identifier}\t{subnet_group}")
PY
  )"
  parse_exit=$?
  set -e

  if [[ "$parse_exit" -ne 0 ]]; then
    echo "ERROR: failed to parse source DB instance subnet-group payload for '$SOURCE_DB_INSTANCE_ID'"
    exit 1
  fi

  IFS=$'\t' read -r parsed_identifier parsed_subnet_group <<< "$parse_output"
  if [[ -z "$parsed_identifier" ]]; then
    echo "ERROR: describe-db-instances payload did not include requested source identifier '$SOURCE_DB_INSTANCE_ID'"
    exit 1
  fi

  if [[ "$parsed_identifier" != "$SOURCE_DB_INSTANCE_ID" ]]; then
    echo "ERROR: describe-db-instances payload did not include requested source identifier '$SOURCE_DB_INSTANCE_ID' (got '$parsed_identifier')"
    exit 1
  fi

  if [[ -z "$parsed_subnet_group" ]]; then
    echo "ERROR: source DB instance '$SOURCE_DB_INSTANCE_ID' has no DBSubnetGroupName; refusing restore without explicit subnet placement"
    exit 1
  fi

  SOURCE_DB_SUBNET_GROUP_NAME="$parsed_subnet_group"
}

build_restore_command() {
  resolve_source_subnet_group
  if [[ "$RESTORE_MODE" == "snapshot" ]]; then
    RESTORE_COMMAND=(
      aws rds restore-db-instance-from-db-snapshot
      --region "$REGION"
      --db-instance-identifier "$TARGET_DB_INSTANCE_ID"
      --db-snapshot-identifier "$SNAPSHOT_ID"
      --db-subnet-group-name "$SOURCE_DB_SUBNET_GROUP_NAME"
    )
  else
    RESTORE_COMMAND=(
      aws rds restore-db-instance-to-point-in-time
      --region "$REGION"
      --source-db-instance-identifier "$SOURCE_DB_INSTANCE_ID"
      --target-db-instance-identifier "$TARGET_DB_INSTANCE_ID"
      --restore-time "$RESTORE_TIME"
      --db-subnet-group-name "$SOURCE_DB_SUBNET_GROUP_NAME"
    )
  fi

}

redact_command() {
  local token=""
  local redact_next=false
  local redacted=()

  for token in "$@"; do
    if [[ "$redact_next" == true ]]; then
      redacted+=("REDACTED")
      redact_next=false
      continue
    fi

    case "$token" in
      --password|--secret-access-key|--aws-secret-access-key|--token)
        redacted+=("$token")
        redact_next=true
        ;;
      *)
        redacted+=("$token")
        ;;
    esac
  done

  printf '%q ' "${redacted[@]}"
}

run_restore_command() {
  local printed_command
  printed_command="$(redact_command "${RESTORE_COMMAND[@]}")"

  echo "Source DB instance: ${SOURCE_DB_INSTANCE_ID}"
  echo "Target DB instance: ${TARGET_DB_INSTANCE_ID}"
  echo "Region: ${REGION}"

  if [[ "${RDS_RESTORE_DRILL_EXECUTE:-}" != "1" ]]; then
    echo "Dry run: no restore API call dispatched."
    echo "Command: ${printed_command}"
    echo "Set RDS_RESTORE_DRILL_EXECUTE=1 to run this restore API call."
    return
  fi

  echo "Executing restore API call:"
  echo "Command: ${printed_command}"
  if ! "${RESTORE_COMMAND[@]}"; then
    echo "ERROR: restore API call failed for restore mode '${RESTORE_MODE}' targeting '${TARGET_DB_INSTANCE_ID}'."
    echo "Failed command: ${printed_command}"
    exit 1
  fi
  echo "Restore request submitted. Monitor RDS restore progress and handle cutover separately."
}

main() {
  parse_args "$@"
  validate_restore_mode
  validate_target_instance
  require_execute_gate
  build_restore_command
  run_restore_command
}

main "$@"
