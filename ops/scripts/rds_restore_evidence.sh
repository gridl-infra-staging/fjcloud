#!/usr/bin/env bash
# rds_restore_evidence.sh — wrapper around rds_restore_drill.sh for evidence artifacts.
#
# This script owns:
# - input discovery and wrapper-level execution gating
# - run-scoped artifact generation
# - live-only polling and verification artifact wiring
#
# Restore API command construction remains delegated to rds_restore_drill.sh.
set -euo pipefail

umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DRILL_SCRIPT="$SCRIPT_DIR/rds_restore_drill.sh"
SELECT_HELPER_SCRIPT="$SCRIPT_DIR/lib/rds_restore_selection.py"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/database-backup-recovery.md"

REGION="us-east-1"
DEFAULT_ENV_FILE="/Users/stuart/repos/gridl/fjcloud/.secret/.env.secret"

ENV=""
ARTIFACT_DIR=""
ENV_FILE="$DEFAULT_ENV_FILE"
ENV_FILE_EXPLICIT=false
WRAPPER_EXECUTE=false
EFFECTIVE_DRILL_EXECUTE_GATE=""

SOURCE_DB_INSTANCE_ID=""
TARGET_DB_INSTANCE_ID=""
SNAPSHOT_ID=""
RESTORE_TIME=""
RESTORE_MODE=""

RUN_DIR=""
DISCOVERY_DB_INSTANCES_JSON='{"DBInstances":[]}'
DISCOVERY_DB_SNAPSHOTS_JSON='{"DBSnapshots":[]}'
DISCOVERY_DB_CLUSTERS_JSON='{"DBClusters":[]}'
DISCOVERY_DB_INSTANCE_COUNT="0"
DISCOVERY_DB_SNAPSHOT_COUNT="0"
DISCOVERY_DB_CLUSTER_COUNT="0"
DISCOVERY_AVAILABLE_SNAPSHOT_COUNT="0"
DISCOVERY_SOURCE_SCOPED_SNAPSHOT_COUNT="0"
DISCOVERY_SOURCE_INSTANCE_PRESENT="false"
SOURCE_DB_INSTANCE_STATUS=""
SOURCE_DB_ENDPOINT=""
SOURCE_BACKUP_RETENTION=""
SOURCE_LATEST_RESTORABLE_TIME=""

DISCOVERY_STATUS="ok"
DISCOVERY_REASON=""

RESULT="fail"
STATUS="fail"
REASON=""
RESTORE_COMMAND=""
TARGET_ENDPOINT=""
TARGET_STATUS=""

CLEANUP_LIFECYCLE="manual cleanup required: delete the restored DB instance after verification and evidence capture"

usage() {
  cat <<EOF
Usage: rds_restore_evidence.sh <env> --artifact-dir <dir> [options]
  env: staging | prod

Options:
  --artifact-dir <dir>              Required run artifact root directory
  --env-file <path>                 AWS env file (default: $DEFAULT_ENV_FILE)
  --source-db-instance-id <id>      Optional source DB instance override
  --target-db-instance-id <id>      Optional target DB instance override
  --snapshot-id <id>                Optional snapshot restore selector
  --restore-time <RFC3339>          Optional PITR restore selector
  --execute                         Wrapper live-dispatch gate (requires RDS_RESTORE_DRILL_EXECUTE=1)
  -h, --help                        Show this help
EOF
}

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"
  if [[ -z "$option_value" || "$option_value" == --* ]]; then
    echo "ERROR: $option_name requires a value"
    exit 1
  fi
}

trim_env_value() {
  local value="$1"
  local first_char=""
  local last_char=""

  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"

  if [[ -n "$value" ]]; then
    first_char="${value:0:1}"
    last_char="${value: -1}"
    if { [[ "$first_char" == "'" ]] || [[ "$first_char" == "\"" ]]; } && [[ "$last_char" == "$first_char" ]]; then
      value="${value:1:${#value}-2}"
    fi
  fi

  printf '%s' "$value"
}

is_safe_aws_value() {
  local value="$1"
  if [[ "$value" == *'$('* || "$value" == *'`'* || "$value" == *'${'* ]]; then
    return 1
  fi
  return 0
}

load_aws_env_file() {
  local env_file="$1"
  local required="$2"
  local line=""
  local line_number=0
  local key=""
  local raw_value=""
  local trimmed_value=""

  if [[ ! -r "$env_file" ]]; then
    if [[ "$required" == "true" ]]; then
      echo "ERROR: --env-file must reference a readable env secret file for live execution"
      exit 1
    fi
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line%$'\r'}"

    if [[ "$line" =~ ^[[:space:]]*$ ]] || [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi

    if ! [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "ERROR: unsafe shell syntax in env file '$env_file' at line $line_number"
      exit 1
    fi

    key="${BASH_REMATCH[2]}"
    raw_value="${BASH_REMATCH[3]}"
    trimmed_value="$(trim_env_value "$raw_value")"

    if [[ "$key" == AWS_* ]]; then
      if ! is_safe_aws_value "$trimmed_value"; then
        echo "ERROR: unsafe shell expression detected in env file '$env_file' for key '$key'"
        exit 1
      fi
      printf -v "$key" '%s' "$trimmed_value"
      export "$key"
    fi
  done < "$env_file"

  export AWS_PAGER=""
}

aws_rds_json() {
  local action="$1"
  shift
  AWS_PAGER="" aws rds "$action" "$@" --region "$REGION" --no-cli-pager --output json
}

json_quote() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"
}

redact_rds_endpoint() {
  local value="$1"
  if [[ "$value" =~ ^([A-Za-z0-9-]+)\.[A-Za-z0-9-]+\.([A-Za-z0-9-]+)\.rds\.amazonaws\.com(:[0-9]+)?$ ]]; then
    printf '%s.*.%s.rds.amazonaws.com%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  printf '%s' "$value"
}

normalize_json_file() {
  local path="$1"
  python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

create_run_artifacts() {
  local run_ts=""
  mkdir -p "$ARTIFACT_DIR"
  run_ts="$(date -u +%Y%m%dT%H%M%SZ)"
  RUN_DIR="$ARTIFACT_DIR/rds_restore_evidence_${ENV}_${run_ts}_$$"
  mkdir -m 700 "$RUN_DIR"
}

write_discovery_artifact() {
  cat > "$RUN_DIR/discovery.json" <<EOF
{
  "status": $(json_quote "$DISCOVERY_STATUS"),
  "reason": $(json_quote "$DISCOVERY_REASON"),
  "env": $(json_quote "$ENV"),
  "source_db_instance_id": $(json_quote "$SOURCE_DB_INSTANCE_ID"),
  "target_db_instance_id": $(json_quote "$TARGET_DB_INSTANCE_ID"),
  "restore_mode": $(json_quote "$RESTORE_MODE"),
  "snapshot_id": $(json_quote "$SNAPSHOT_ID"),
  "restore_time": $(json_quote "$RESTORE_TIME"),
  "source_instance_present": $DISCOVERY_SOURCE_INSTANCE_PRESENT,
  "db_instance_count": $DISCOVERY_DB_INSTANCE_COUNT,
  "db_snapshot_count": $DISCOVERY_DB_SNAPSHOT_COUNT,
  "db_cluster_count": $DISCOVERY_DB_CLUSTER_COUNT,
  "available_snapshot_count": $DISCOVERY_AVAILABLE_SNAPSHOT_COUNT,
  "source_scoped_snapshot_count": $DISCOVERY_SOURCE_SCOPED_SNAPSHOT_COUNT,
  "source_db_instance_status": $(json_quote "$SOURCE_DB_INSTANCE_STATUS"),
  "source_db_endpoint": $(json_quote "$(redact_rds_endpoint "$SOURCE_DB_ENDPOINT")"),
  "source_backup_retention_period": $(json_quote "$SOURCE_BACKUP_RETENTION"),
  "source_latest_restorable_time": $(json_quote "$SOURCE_LATEST_RESTORABLE_TIME")
}
EOF
  normalize_json_file "$RUN_DIR/discovery.json"
}

write_restore_request_artifact() {
  cat > "$RUN_DIR/restore_request.json" <<EOF
{
  "env": $(json_quote "$ENV"),
  "region": $(json_quote "$REGION"),
  "wrapper_execute": $( [[ "$WRAPPER_EXECUTE" == true ]] && echo "true" || echo "false" ),
  "drill_execute_gate": $(json_quote "$EFFECTIVE_DRILL_EXECUTE_GATE"),
  "source_db_instance_id": $(json_quote "$SOURCE_DB_INSTANCE_ID"),
  "target_db_instance_id": $(json_quote "$TARGET_DB_INSTANCE_ID"),
  "restore_mode": $(json_quote "$RESTORE_MODE"),
  "snapshot_id": $(json_quote "$SNAPSHOT_ID"),
  "restore_time": $(json_quote "$RESTORE_TIME")
}
EOF
  normalize_json_file "$RUN_DIR/restore_request.json"
}

write_summary_artifact() {
  local reason_field="null"
  if [[ "$STATUS" == "blocked" || "$STATUS" == "fail" ]]; then
    reason_field="$(json_quote "$REASON")"
  fi

  cat > "$RUN_DIR/summary.json" <<EOF
{
  "result": $(json_quote "$RESULT"),
  "status": $(json_quote "$STATUS"),
  "env": $(json_quote "$ENV"),
  "source_db_instance_id": $(json_quote "$SOURCE_DB_INSTANCE_ID"),
  "target_db_instance_id": $(json_quote "$TARGET_DB_INSTANCE_ID"),
  "restore_mode": $(json_quote "$RESTORE_MODE"),
  "restore_command": $(json_quote "$RESTORE_COMMAND"),
  "cleanup_lifecycle": $(json_quote "$CLEANUP_LIFECYCLE"),
  "reason": $reason_field,
  "target_endpoint": $(json_quote "$(redact_rds_endpoint "$TARGET_ENDPOINT")"),
  "target_status": $(json_quote "$TARGET_STATUS")
}
EOF
  normalize_json_file "$RUN_DIR/summary.json"
}

extract_verification_sql_from_runbook() {
  if [[ ! -r "$RUNBOOK_PATH" ]]; then
    return 1
  fi

  awk '
    /<<'\''SQL'\''/ {in_sql=1; next}
    in_sql && /^SQL$/ {exit}
    in_sql {print}
  ' "$RUNBOOK_PATH"
}

write_verification_artifacts() {
  local verification_sql=""
  local verification_notes=""

  if verification_sql="$(extract_verification_sql_from_runbook)"; then
    if [[ -n "$verification_sql" ]]; then
      printf '%s\n' "$verification_sql" > "$RUN_DIR/verification.sql"
    else
      printf '%s\n' "-- BLOCKED: canonical verification SQL block missing in $RUNBOOK_PATH" > "$RUN_DIR/verification.sql"
    fi
  else
    printf '%s\n' "-- BLOCKED: canonical verification source unavailable at $RUNBOOK_PATH" > "$RUN_DIR/verification.sql"
  fi

  {
    echo "env=$ENV"
    echo "status=$STATUS"
    echo "result=$RESULT"
    if [[ -n "$TARGET_STATUS" ]]; then
      echo "target_status=$TARGET_STATUS"
    fi
    if [[ -n "$TARGET_ENDPOINT" ]]; then
      echo "target_endpoint=$(redact_rds_endpoint "$TARGET_ENDPOINT")"
    fi
    if [[ -n "$REASON" ]]; then
      echo "reason=$REASON"
    fi
    echo "runbook_source=$RUNBOOK_PATH"
  } > "$RUN_DIR/verification.txt"
}

parse_args() {
  if [[ $# -lt 1 ]]; then
    usage
    exit 1
  fi

  ENV="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --artifact-dir)
        require_option_value "$1" "${2:-}"
        ARTIFACT_DIR="$2"
        shift 2
        ;;
      --env-file)
        require_option_value "$1" "${2:-}"
        ENV_FILE="$2"
        ENV_FILE_EXPLICIT=true
        shift 2
        ;;
      --source-db-instance-id)
        require_option_value "$1" "${2:-}"
        SOURCE_DB_INSTANCE_ID="$2"
        shift 2
        ;;
      --target-db-instance-id)
        require_option_value "$1" "${2:-}"
        TARGET_DB_INSTANCE_ID="$2"
        shift 2
        ;;
      --snapshot-id)
        require_option_value "$1" "${2:-}"
        SNAPSHOT_ID="$2"
        shift 2
        ;;
      --restore-time)
        require_option_value "$1" "${2:-}"
        RESTORE_TIME="$2"
        shift 2
        ;;
      --execute)
        WRAPPER_EXECUTE=true
        shift
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
}

validate_args() {
  if [[ "$ENV" != "staging" && "$ENV" != "prod" ]]; then
    echo "ERROR: env must be 'staging' or 'prod' (got: ${ENV})"
    usage
    exit 1
  fi

  if [[ -z "$ARTIFACT_DIR" ]]; then
    echo "ERROR: --artifact-dir is required"
    usage
    exit 1
  fi

  if [[ -n "$SOURCE_DB_INSTANCE_ID" && -n "$TARGET_DB_INSTANCE_ID" && "$SOURCE_DB_INSTANCE_ID" == "$TARGET_DB_INSTANCE_ID" ]]; then
    echo "ERROR: --source-db-instance-id and --target-db-instance-id must be different"
    exit 1
  fi

  if [[ -n "$SNAPSHOT_ID" && -n "$RESTORE_TIME" ]]; then
    echo "ERROR: provide exactly one restore mode selector (--snapshot-id or --restore-time)"
    exit 1
  fi

  if [[ ! -x "$DRILL_SCRIPT" ]]; then
    echo "ERROR: expected executable delegate script at $DRILL_SCRIPT"
    exit 1
  fi
}

set_default_source_db_instance() {
  if [[ -z "$SOURCE_DB_INSTANCE_ID" ]]; then
    if [[ "$ENV" == "staging" ]]; then
      SOURCE_DB_INSTANCE_ID="fjcloud-staging"
    else
      SOURCE_DB_INSTANCE_ID="fjcloud-prod"
    fi
  fi
}

collect_discovery_payloads() {
  local action=""
  local payload=""
  local exit_code=0
  local -a actions=(
    "describe-db-instances"
    "describe-db-snapshots"
    "describe-db-clusters"
  )

  for action in "${actions[@]}"; do
    set +e
    payload="$(aws_rds_json "$action")"
    exit_code=$?
    set -e
    if [[ "$exit_code" -ne 0 ]]; then
      DISCOVERY_STATUS="fail"
      DISCOVERY_REASON="aws discovery command failed: $action (exit $exit_code)"
      return 1
    fi

    case "$action" in
      describe-db-instances)
        DISCOVERY_DB_INSTANCES_JSON="$payload"
        ;;
      describe-db-snapshots)
        DISCOVERY_DB_SNAPSHOTS_JSON="$payload"
        ;;
      describe-db-clusters)
        DISCOVERY_DB_CLUSTERS_JSON="$payload"
        ;;
    esac
  done

  return 0
}

select_restore_inputs_from_discovery() {
  local timestamp_compact=""
  local discovery_line=""
  local parse_exit=0

  timestamp_compact="$(date -u +%Y%m%d%H%M%S)"
  if [[ ! -r "$SELECT_HELPER_SCRIPT" ]]; then
    DISCOVERY_STATUS="fail"
    DISCOVERY_REASON="missing selection helper script: $SELECT_HELPER_SCRIPT"
    return 1
  fi

  set +e
  discovery_line="$(
    python3 "$SELECT_HELPER_SCRIPT" \
      <(printf '%s\n' "$DISCOVERY_DB_INSTANCES_JSON") \
      <(printf '%s\n' "$DISCOVERY_DB_SNAPSHOTS_JSON") \
      <(printf '%s\n' "$DISCOVERY_DB_CLUSTERS_JSON") \
      "$SOURCE_DB_INSTANCE_ID" \
      "$TARGET_DB_INSTANCE_ID" \
      "$SNAPSHOT_ID" \
      "$RESTORE_TIME" \
      "$timestamp_compact"
  )"
  parse_exit=$?
  set -e

  if [[ "$parse_exit" -ne 0 || -z "$discovery_line" ]]; then
    DISCOVERY_STATUS="fail"
    DISCOVERY_REASON="failed to parse discovery payloads while selecting restore inputs"
    return 1
  fi

  IFS=$'\037' read -r DISCOVERY_STATUS DISCOVERY_REASON SOURCE_DB_INSTANCE_ID TARGET_DB_INSTANCE_ID RESTORE_MODE SNAPSHOT_ID RESTORE_TIME SOURCE_DB_INSTANCE_STATUS SOURCE_DB_ENDPOINT SOURCE_BACKUP_RETENTION SOURCE_LATEST_RESTORABLE_TIME DISCOVERY_DB_INSTANCE_COUNT DISCOVERY_DB_SNAPSHOT_COUNT DISCOVERY_DB_CLUSTER_COUNT DISCOVERY_AVAILABLE_SNAPSHOT_COUNT DISCOVERY_SOURCE_SCOPED_SNAPSHOT_COUNT DISCOVERY_SOURCE_INSTANCE_PRESENT <<< "$discovery_line"

  return 0
}

discover_restore_inputs() {
  set_default_source_db_instance
  if ! collect_discovery_payloads; then
    return 0
  fi
  if ! select_restore_inputs_from_discovery; then
    return 0
  fi
  return 0
}

poll_target_available() {
  local timeout_seconds=1800
  local interval_seconds=15
  local start_epoch=0
  local now_epoch=0
  local describe_payload=""
  local describe_exit=0
  local parsed_target=""
  local parse_exit=0

  start_epoch="$(date -u +%s)"
  while true; do
    set +e
    describe_payload="$(aws_rds_json describe-db-instances --db-instance-identifier "$TARGET_DB_INSTANCE_ID" 2>&1)"
    describe_exit=$?
    set -e
    if [[ "$describe_exit" -ne 0 ]]; then
      REASON="aws poll describe-db-instances failed for target '$TARGET_DB_INSTANCE_ID' (exit $describe_exit)"
      TARGET_STATUS="poll-error"
      TARGET_ENDPOINT=""
      return 1
    fi

    set +e
    parsed_target="$(
      python3 - <(printf '%s\n' "$describe_payload") <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as payload_fh:
    payload = json.load(payload_fh)
instances = payload.get("DBInstances", [])
if not instances:
    print("\t")
    raise SystemExit(0)

instance = instances[0]
status = str(instance.get("DBInstanceStatus", ""))
endpoint = str((instance.get("Endpoint") or {}).get("Address", ""))
print(f"{status}\t{endpoint}")
PY
    )"
    parse_exit=$?
    set -e
    if [[ "$parse_exit" -ne 0 ]]; then
      REASON="failed to parse poll describe-db-instances payload for target '$TARGET_DB_INSTANCE_ID'"
      TARGET_STATUS="poll-error"
      TARGET_ENDPOINT=""
      return 1
    fi

    IFS=$'\t' read -r TARGET_STATUS TARGET_ENDPOINT <<< "$parsed_target"
    if [[ -z "$TARGET_STATUS" ]]; then
      REASON="poll describe-db-instances returned no DBInstances for target '$TARGET_DB_INSTANCE_ID'"
      TARGET_STATUS="poll-error"
      TARGET_ENDPOINT=""
      return 1
    fi

    if [[ "$TARGET_STATUS" == "available" ]]; then
      return 0
    fi

    if [[ "$TARGET_STATUS" == "failed" || "$TARGET_STATUS" == "incompatible-restore" ]]; then
      REASON="target restore entered terminal status '$TARGET_STATUS'"
      return 1
    fi

    now_epoch="$(date -u +%s)"
    if (( now_epoch - start_epoch >= timeout_seconds )); then
      REASON="target did not become available within ${timeout_seconds}s"
      return 1
    fi

    sleep "$interval_seconds"
  done
}

run_drill() {
  local -a drill_args
  local drill_output=""
  local drill_exit=0
  local delegate_path="$PATH"

  # Test harnesses can run with a reduced PATH; ensure common ripgrep install
  # locations remain reachable for delegated drill wrappers that use rg.
  if [[ -x "/opt/homebrew/bin/rg" && ":$delegate_path:" != *":/opt/homebrew/bin:"* ]]; then
    delegate_path="/opt/homebrew/bin:$delegate_path"
  fi
  if [[ -x "/usr/local/bin/rg" && ":$delegate_path:" != *":/usr/local/bin:"* ]]; then
    delegate_path="/usr/local/bin:$delegate_path"
  fi

  drill_args=(
    "$ENV"
    --source-db-instance-id "$SOURCE_DB_INSTANCE_ID"
    --target-db-instance-id "$TARGET_DB_INSTANCE_ID"
  )

  if [[ "$RESTORE_MODE" == "snapshot" ]]; then
    drill_args+=(--snapshot-id "$SNAPSHOT_ID")
  else
    drill_args+=(--restore-time "$RESTORE_TIME")
  fi

  set +e
  if [[ "$WRAPPER_EXECUTE" == true ]]; then
    drill_output="$(PATH="$delegate_path" "$DRILL_SCRIPT" "${drill_args[@]}" 2>&1)"
    drill_exit=$?
  else
    drill_output="$(PATH="$delegate_path" env -u RDS_RESTORE_DRILL_EXECUTE "$DRILL_SCRIPT" "${drill_args[@]}" 2>&1)"
    drill_exit=$?
  fi
  set -e

  printf '%s\n' "$drill_output"

  RESTORE_COMMAND="$(printf '%s\n' "$drill_output" | awk -F'Command: ' '/^Command: / {cmd=$2} END {print cmd}')"

  if [[ "$drill_exit" -ne 0 ]]; then
    RESULT="fail"
    STATUS="fail"
    REASON="delegated restore drill failed"
    return 1
  fi

  if [[ "$WRAPPER_EXECUTE" == true ]]; then
    if ! poll_target_available; then
      RESULT="fail"
      STATUS="fail"
      [[ -n "$REASON" ]] || REASON="failed while polling target restore state"
      return 1
    fi
    RESULT="pass"
    STATUS="success"
    return 0
  fi

  RESULT="pass"
  STATUS="dry-run"
  TARGET_STATUS="dry-run"
  return 0
}

main() {
  parse_args "$@"
  validate_args

  if [[ "$WRAPPER_EXECUTE" == true ]]; then
    if [[ "$ENV_FILE_EXPLICIT" == true ]]; then
      load_aws_env_file "$ENV_FILE" true
      if [[ "${RDS_RESTORE_DRILL_EXECUTE:-}" != "1" ]]; then
        echo "ERROR: live dispatch requires wrapper --execute and RDS_RESTORE_DRILL_EXECUTE=1"
        exit 1
      fi
    else
      if [[ "${RDS_RESTORE_DRILL_EXECUTE:-}" != "1" ]]; then
        echo "ERROR: live dispatch requires wrapper --execute and RDS_RESTORE_DRILL_EXECUTE=1"
        exit 1
      fi
      load_aws_env_file "$ENV_FILE" true
    fi
    EFFECTIVE_DRILL_EXECUTE_GATE="1"
  else
    load_aws_env_file "$ENV_FILE" false
    EFFECTIVE_DRILL_EXECUTE_GATE=""
  fi

  create_run_artifacts
  discover_restore_inputs
  write_discovery_artifact
  write_restore_request_artifact

  if [[ "$DISCOVERY_STATUS" == "blocked" ]]; then
    RESULT="blocked"
    STATUS="blocked"
    REASON="$DISCOVERY_REASON"
    write_summary_artifact
    write_verification_artifacts
    echo "Restore evidence blocked: $DISCOVERY_REASON"
    exit 0
  fi

  if [[ "$DISCOVERY_STATUS" == "fail" ]]; then
    RESULT="fail"
    STATUS="fail"
    REASON="$DISCOVERY_REASON"
    write_summary_artifact
    write_verification_artifacts
    echo "ERROR: $DISCOVERY_REASON"
    exit 1
  fi

  if ! run_drill; then
    write_summary_artifact
    write_verification_artifacts
    exit 1
  fi

  write_summary_artifact
  write_verification_artifacts
  exit 0
}

main "$@"
