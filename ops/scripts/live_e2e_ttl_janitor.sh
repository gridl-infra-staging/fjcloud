#!/usr/bin/env bash
# live_e2e_ttl_janitor.sh — fail-closed TTL cleanup for disposable live-E2E resources.

set -euo pipefail

readonly REQUIRED_TAG_TEST_RUN_ID="test_run_id"
readonly REQUIRED_TAG_OWNER="owner"
readonly REQUIRED_TAG_TTL_EXPIRES_AT="ttl_expires_at"
readonly REQUIRED_TAG_ENVIRONMENT="environment"
readonly DEFAULT_ENVIRONMENT_SELECTOR="live-e2e"
readonly DEFAULT_MAX_EXPIRED_AGE_SECONDS=1209600
readonly ALLOWED_RESOURCE_TYPES=("ec2:instance" "rds:db")

EXECUTE_MODE=false
ENVIRONMENT_SELECTOR="$DEFAULT_ENVIRONMENT_SELECTOR"
OWNER_SELECTOR=""
TEST_RUN_ID_SELECTOR=""
NOW_EPOCH_OVERRIDE=""
MAX_EXPIRED_AGE_SECONDS="$DEFAULT_MAX_EXPIRED_AGE_SECONDS"

usage() {
  cat <<'USAGE'
Usage: live_e2e_ttl_janitor.sh [options]

Non-destructive by default. Deletes require both:
  1) --execute
  2) FJCLOUD_ALLOW_LIVE_E2E_DELETE=1

Options:
  --environment <value>              Required environment tag selector (default: live-e2e; no commas/whitespace)
  --owner <value>                    Optional owner tag selector (single tag value; no commas/whitespace)
  --test-run-id <value>              Optional test_run_id selector (single tag value; no commas/whitespace)
  --execute                          Perform deletion (requires FJCLOUD_ALLOW_LIVE_E2E_DELETE=1)
  --max-expired-age-seconds <value>  Max age of expired ttl_expires_at before fail-closed (default: 1209600)
  --now-epoch <value>                Test-only current epoch override
  -h, --help                         Show this help
USAGE
}

log_info() {
  echo "INFO: $*"
}

log_error() {
  echo "ERROR: $*" >&2
}

fail() {
  log_error "$*"
  exit 1
}

require_option_value() {
  local option_name="$1"
  local option_value="${2:-}"

  if [[ -z "$option_value" || "$option_value" == --* ]]; then
    fail "${option_name} requires a value"
  fi
}

validate_selector_value() {
  local option_name="$1"
  local option_value="$2"

  if [[ "$option_value" =~ [[:space:],] ]]; then
    fail "${option_name} must not contain commas or whitespace"
  fi
}

aws_cli() {
  aws "$@"
}

is_missing_tag_value() {
  local value="$1"
  [[ -z "$value" || "$value" == "None" || "$value" == "null" ]]
}

parse_ttl_epoch() {
  local raw_value="$1"
  python3 - "$raw_value" <<'PY'
import datetime
import sys

raw = sys.argv[1]
try:
    normalized = raw.replace("Z", "+00:00")
    dt = datetime.datetime.fromisoformat(normalized)
except ValueError:
    sys.exit(1)

if dt.tzinfo is None:
    dt = dt.replace(tzinfo=datetime.timezone.utc)

print(int(dt.timestamp()))
PY
}

current_epoch() {
  if [[ -n "$NOW_EPOCH_OVERRIDE" ]]; then
    echo "$NOW_EPOCH_OVERRIDE"
    return
  fi
  date -u +%s
}

resource_type_from_arn() {
  local arn="$1"
  case "$arn" in
    arn:aws*:ec2:*:instance/*) echo "ec2:instance" ;;
    arn:aws*:rds:*:db:*) echo "rds:db" ;;
    *) return 1 ;;
  esac
}

delete_resource() {
  local resource_arn="$1"
  local resource_type="$2"
  case "$resource_type" in
    ec2:instance)
      local instance_id="${resource_arn##*/}"
      aws_cli ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
      ;;
    rds:db)
      local db_identifier="${resource_arn##*:db:}"
      aws_cli rds delete-db-instance --db-instance-identifier "$db_identifier" --skip-final-snapshot >/dev/null
      ;;
    *)
      fail "unsupported allowlisted resource type '$resource_type' for ARN '$resource_arn'"
      ;;
  esac
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --environment)
        require_option_value "$1" "${2:-}"
        validate_selector_value "$1" "$2"
        ENVIRONMENT_SELECTOR="$2"
        shift 2
        ;;
      --owner)
        require_option_value "$1" "${2:-}"
        validate_selector_value "$1" "$2"
        OWNER_SELECTOR="$2"
        shift 2
        ;;
      --test-run-id)
        require_option_value "$1" "${2:-}"
        validate_selector_value "$1" "$2"
        TEST_RUN_ID_SELECTOR="$2"
        shift 2
        ;;
      --execute)
        EXECUTE_MODE=true
        shift
        ;;
      --max-expired-age-seconds)
        require_option_value "$1" "${2:-}"
        MAX_EXPIRED_AGE_SECONDS="$2"
        shift 2
        ;;
      --now-epoch)
        require_option_value "$1" "${2:-}"
        NOW_EPOCH_OVERRIDE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

validate_selectors() {
  if [[ -z "$ENVIRONMENT_SELECTOR" ]]; then
    fail "environment selector is required"
  fi

  if [[ -z "$OWNER_SELECTOR" && -z "$TEST_RUN_ID_SELECTOR" ]]; then
    fail "at least one selector is required: --owner or --test-run-id"
  fi
}

validate_execute_gate() {
  if [[ "$EXECUTE_MODE" == true && "${FJCLOUD_ALLOW_LIVE_E2E_DELETE:-0}" != "1" ]]; then
    fail "--execute requires FJCLOUD_ALLOW_LIVE_E2E_DELETE=1"
  fi
}

discover_tagged_resources() {
  local -a discovery_cmd
  discovery_cmd=(
    resourcegroupstaggingapi get-resources
    --tag-filters "Key=${REQUIRED_TAG_ENVIRONMENT},Values=${ENVIRONMENT_SELECTOR}"
  )

  if [[ -n "$OWNER_SELECTOR" ]]; then
    discovery_cmd+=(--tag-filters "Key=${REQUIRED_TAG_OWNER},Values=${OWNER_SELECTOR}")
  fi

  if [[ -n "$TEST_RUN_ID_SELECTOR" ]]; then
    discovery_cmd+=(--tag-filters "Key=${REQUIRED_TAG_TEST_RUN_ID},Values=${TEST_RUN_ID_SELECTOR}")
  fi

  discovery_cmd+=(--resource-type-filters "${ALLOWED_RESOURCE_TYPES[@]}")
  discovery_cmd+=(
    --query
    "ResourceTagMappingList[].[ResourceARN,Tags[?Key==\`${REQUIRED_TAG_TEST_RUN_ID}\`]|[0].Value,Tags[?Key==\`${REQUIRED_TAG_OWNER}\`]|[0].Value,Tags[?Key==\`${REQUIRED_TAG_TTL_EXPIRES_AT}\`]|[0].Value,Tags[?Key==\`${REQUIRED_TAG_ENVIRONMENT}\`]|[0].Value]"
    --output
    text
  )

  aws_cli "${discovery_cmd[@]}"
}

main() {
  parse_args "$@"
  validate_selectors
  validate_execute_gate

  local now_epoch
  now_epoch="$(current_epoch)"
  if ! [[ "$now_epoch" =~ ^[0-9]+$ ]]; then
    fail "invalid current epoch value"
  fi

  if ! [[ "$MAX_EXPIRED_AGE_SECONDS" =~ ^[0-9]+$ ]]; then
    fail "max expired age must be a positive integer"
  fi

  local mode_label="DRY-RUN"
  if [[ "$EXECUTE_MODE" == true ]]; then
    mode_label="EXECUTE"
  fi

  log_info "mode=${mode_label} environment=${ENVIRONMENT_SELECTOR}"
  log_info "resource type allowlist=${ALLOWED_RESOURCE_TYPES[*]}"

  local total_seen=0
  local expired_seen=0
  local deleted_count=0
  local contract_errors=0
  local discovery_output=""

  discovery_output="$(discover_tagged_resources)"
  while IFS=$'\t' read -r resource_arn test_run_id owner ttl_expires_at environment; do
    [[ -z "$resource_arn" ]] && continue
    total_seen=$((total_seen + 1))

    if is_missing_tag_value "$test_run_id" || is_missing_tag_value "$owner" || is_missing_tag_value "$ttl_expires_at" || is_missing_tag_value "$environment"; then
      log_error "resource '$resource_arn' missing required tags (${REQUIRED_TAG_TEST_RUN_ID}, ${REQUIRED_TAG_OWNER}, ${REQUIRED_TAG_TTL_EXPIRES_AT}, ${REQUIRED_TAG_ENVIRONMENT})"
      contract_errors=$((contract_errors + 1))
      continue
    fi

    if [[ "$environment" != "$ENVIRONMENT_SELECTOR" ]]; then
      log_error "resource '$resource_arn' has environment '$environment' outside selected '$ENVIRONMENT_SELECTOR'"
      contract_errors=$((contract_errors + 1))
      continue
    fi

    local resource_type=""
    if ! resource_type="$(resource_type_from_arn "$resource_arn")"; then
      log_error "resource '$resource_arn' is outside allowlisted resource types"
      contract_errors=$((contract_errors + 1))
      continue
    fi

    local ttl_epoch=""
    if ! ttl_epoch="$(parse_ttl_epoch "$ttl_expires_at")"; then
      log_error "resource '$resource_arn' has unparseable ttl_expires_at '$ttl_expires_at'"
      contract_errors=$((contract_errors + 1))
      continue
    fi

    if [[ "$ttl_epoch" -gt "$now_epoch" ]]; then
      continue
    fi

    local expired_age_seconds=$((now_epoch - ttl_epoch))
    if [[ "$expired_age_seconds" -gt "$MAX_EXPIRED_AGE_SECONDS" ]]; then
      log_error "resource '$resource_arn' ttl_expires_at '$ttl_expires_at' is outside contract window"
      contract_errors=$((contract_errors + 1))
      continue
    fi

    expired_seen=$((expired_seen + 1))
    if [[ "$EXECUTE_MODE" == true ]]; then
      delete_resource "$resource_arn" "$resource_type"
      deleted_count=$((deleted_count + 1))
      log_info "EXECUTE deleted resource='$resource_arn' ttl_expires_at='$ttl_expires_at'"
    else
      log_info "DRY-RUN would delete resource='$resource_arn' ttl_expires_at='$ttl_expires_at'"
    fi
  done <<< "$discovery_output"

  if [[ "$contract_errors" -gt 0 ]]; then
    fail "contract validation failed for ${contract_errors} resource(s)"
  fi

  log_info "summary mode=${mode_label} total_seen=${total_seen} expired_seen=${expired_seen} deleted_count=${deleted_count}"
}

main "$@"
