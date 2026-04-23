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

build_restore_command() {
  if [[ "$RESTORE_MODE" == "snapshot" ]]; then
    RESTORE_COMMAND=(
      aws rds restore-db-instance-from-db-snapshot
      --region "$REGION"
      --db-instance-identifier "$TARGET_DB_INSTANCE_ID"
      --db-snapshot-identifier "$SNAPSHOT_ID"
    )
  else
    RESTORE_COMMAND=(
      aws rds restore-db-instance-to-point-in-time
      --region "$REGION"
      --source-db-instance-identifier "$SOURCE_DB_INSTANCE_ID"
      --target-db-instance-identifier "$TARGET_DB_INSTANCE_ID"
      --restore-time "$RESTORE_TIME"
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
