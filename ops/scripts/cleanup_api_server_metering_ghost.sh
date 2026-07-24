#!/usr/bin/env bash
# cleanup_api_server_metering_ghost.sh
#
# One-shot operator cleanup for the dormant fj-metering-agent ghost that older
# API-server deploys installed on the control-plane host.
#
# Dry-run for planning on any workstation:
#   bash ops/scripts/cleanup_api_server_metering_ghost.sh --dry-run
#
# Live execution must run on the API server itself after the Stage 3 cleanup
# deploy is live. Example SSM invocation:
#   aws ssm send-command \
#     --region us-east-1 \
#     --instance-ids <api-instance-id> \
#     --document-name AWS-RunShellScript \
#     --comment "cleanup dormant fj-metering-agent ghost on API server" \
#     --parameters "$(python3 - <<'PY'
# import json
# import pathlib
# script_path = pathlib.Path('ops/scripts/cleanup_api_server_metering_ghost.sh')
# commands = [
#   'export EXPECTED_DEPLOYED_SHA=2b4cfaae3ada8e61cd2721966cb3bb55a38fddf0',
#   *script_path.read_text().splitlines(),
# ]
# print(json.dumps({'commands': commands}))
# PY
# )"
#
# Live-mode contract:
# - Verify the host identity through IMDSv2 + ec2:DescribeTags.
# - Verify the deployed cleanup SHA gate through /fjcloud/<env>/last_deploy_sha.
# - Stop/disable/remove the ghost service and stale files.
# - Capture before/after evidence under /tmp/api_server_metering_cleanup_<UTC>.log.

set -euo pipefail

EXPECTED_DEPLOYED_SHA_DEFAULT="2b4cfaae3ada8e61cd2721966cb3bb55a38fddf0"
EXPECTED_DEPLOYED_SHA="${EXPECTED_DEPLOYED_SHA:-$EXPECTED_DEPLOYED_SHA_DEFAULT}"
TARGET_ROOT="${FJCLOUD_API_SERVER_ROOT:-/}"
AWS_BIN="${FJCLOUD_AWS_BIN:-aws}"
CURL_BIN="${FJCLOUD_CURL_BIN:-curl}"
SYSTEMCTL_BIN="${FJCLOUD_SYSTEMCTL_BIN:-systemctl}"
METADATA_BASE_URL="${FJCLOUD_METADATA_BASE_URL:-http://169.254.169.254/latest}"
LOG_DIR="${FJCLOUD_METERING_GHOST_LOG_DIR:-/tmp}"
DRY_RUN=false
LOG_FILE=""
IMDS_TOKEN=""
INSTANCE_ID=""
REGION=""
INSTANCE_NAME_TAG=""
INSTANCE_ENV=""

usage() {
  cat <<'EOF'
Usage: cleanup_api_server_metering_ghost.sh [--dry-run]

Options:
  --dry-run   Print the full cleanup plan without touching host state.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

log_line() {
  local line="$1"
  echo "$line"
  if [[ -n "$LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$LOG_FILE"
  fi
}

target_path() {
  local absolute_path="$1"
  if [[ "$TARGET_ROOT" == "/" ]]; then
    printf '%s\n' "$absolute_path"
  else
    printf '%s%s\n' "$TARGET_ROOT" "$absolute_path"
  fi
}

print_dry_run_action() {
  local label="$1"
  local status="$2"
  local detail="$3"
  log_line "[dry-run] ${label} [${status}] ${detail}"
}

capture_optional_command() {
  local label="$1"
  shift
  local output=""
  local rc=0

  if output="$("$@" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  log_line "==> ${label} (rc=${rc})"
  if [[ -n "$output" ]]; then
    while IFS= read -r line; do
      log_line "$line"
    done <<<"$output"
  fi
}

file_status_for_dry_run() {
  local path="$1"
  if [[ -e "$path" ]]; then
    printf 'would-change'
  else
    printf 'no-op'
  fi
}

require_commands() {
  local cmd=""
  for cmd in "$AWS_BIN" "$CURL_BIN" "$SYSTEMCTL_BIN"; do
    command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"
  done
}

fetch_imds_token() {
  "$CURL_BIN" -fsS -X PUT "${METADATA_BASE_URL}/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60"
}

imds_get() {
  local path="$1"
  "$CURL_BIN" -fsS -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
    "${METADATA_BASE_URL}/${path}"
}

verify_host_identity() {
  IMDS_TOKEN="$(fetch_imds_token)" || die "unable to fetch IMDSv2 token"
  INSTANCE_ID="$(imds_get meta-data/instance-id)" || die "unable to read instance-id from IMDS"
  REGION="$(imds_get meta-data/placement/region)" || die "unable to read region from IMDS"

  local describe_tags_output=""
  if ! describe_tags_output="$("$AWS_BIN" ec2 describe-tags \
    --region "$REGION" \
    --filters "Name=resource-id,Values=${INSTANCE_ID}" "Name=key,Values=Name" \
    --query 'Tags[0].Value' \
    --output text 2>&1)"; then
    die "failed to read the EC2 Name tag via ec2:DescribeTags; live run requires ec2:DescribeTags on the instance role. AWS output: ${describe_tags_output}"
  fi

  INSTANCE_NAME_TAG="$(printf '%s' "$describe_tags_output" | tr -d '\r')"
  [[ -n "$INSTANCE_NAME_TAG" && "$INSTANCE_NAME_TAG" != "None" ]] || die "EC2 Name tag lookup returned no value for instance ${INSTANCE_ID}"
  [[ "$INSTANCE_NAME_TAG" == fjcloud-api-* ]] || die "refusing to run on non-API host Name tag: ${INSTANCE_NAME_TAG}"

  INSTANCE_ENV="${INSTANCE_NAME_TAG#fjcloud-api-}"
  [[ -n "$INSTANCE_ENV" && "$INSTANCE_ENV" != "$INSTANCE_NAME_TAG" ]] || die "unable to derive env from Name tag ${INSTANCE_NAME_TAG}"

  log_line "==> Verified host identity: instance_id=${INSTANCE_ID} region=${REGION} name_tag=${INSTANCE_NAME_TAG}"
}

verify_deployed_sha_gate() {
  local deployed_sha=""
  if ! deployed_sha="$("$AWS_BIN" ssm get-parameter \
    --region "$REGION" \
    --name "/fjcloud/${INSTANCE_ENV}/last_deploy_sha" \
    --query 'Parameter.Value' \
    --output text 2>&1)"; then
    die "failed to read /fjcloud/${INSTANCE_ENV}/last_deploy_sha; cannot prove the cleanup deploy is live. AWS output: ${deployed_sha}"
  fi

  deployed_sha="$(printf '%s' "$deployed_sha" | tr -d '\r')"
  [[ "$deployed_sha" =~ ^[0-9a-f]{40}$ ]] || die "unexpected last_deploy_sha value for ${INSTANCE_ENV}: ${deployed_sha}"

  if [[ "$deployed_sha" != "$EXPECTED_DEPLOYED_SHA" ]]; then
    die "deployed SHA gate failed: expected ${EXPECTED_DEPLOYED_SHA}, found ${deployed_sha}. Re-run only after the cleanup deploy is live, or set EXPECTED_DEPLOYED_SHA to a verified post-cleanup SHA."
  fi

  log_line "==> Verified deployed SHA gate: /fjcloud/${INSTANCE_ENV}/last_deploy_sha=${deployed_sha}"
}

maybe_stop_service() {
  if "$SYSTEMCTL_BIN" is-active --quiet fj-metering-agent.service; then
    log_line "==> stop fj-metering-agent.service [active]"
    "$SYSTEMCTL_BIN" stop fj-metering-agent.service
  else
    log_line "==> stop fj-metering-agent.service [no-op]"
  fi
}

maybe_disable_service() {
  if "$SYSTEMCTL_BIN" is-enabled --quiet fj-metering-agent.service; then
    log_line "==> disable fj-metering-agent.service [active]"
    "$SYSTEMCTL_BIN" disable fj-metering-agent.service
  else
    log_line "==> disable fj-metering-agent.service [no-op]"
  fi
}

remove_file_if_present() {
  local label="$1"
  local path="$2"
  if [[ -e "$path" ]]; then
    log_line "==> ${label} [active] ${path}"
    rm -f "$path"
    return 0
  else
    log_line "==> ${label} [no-op] ${path}"
    return 1
  fi
}

reload_systemd() {
  log_line "==> systemctl daemon-reload [active]"
  "$SYSTEMCTL_BIN" daemon-reload
}

print_dry_run_plan() {
  local unit_path metering_env_path binary_path old_binary_path unit_status daemon_reload_status daemon_reload_detail
  unit_path="$(target_path /etc/systemd/system/fj-metering-agent.service)"
  metering_env_path="$(target_path /etc/fjcloud/metering-env)"
  binary_path="$(target_path /usr/local/bin/fj-metering-agent)"
  old_binary_path="$(target_path /usr/local/bin/fj-metering-agent.old)"
  unit_status="$(file_status_for_dry_run "$unit_path")"
  daemon_reload_status="no-op"
  daemon_reload_detail="skip when service-unit cleanup is no-op"
  if [[ "$unit_status" == "would-change" ]]; then
    daemon_reload_status="planned"
    daemon_reload_detail="run only when service-unit removal is active"
  fi

  log_line "cleanup_api_server_metering_ghost.sh dry-run mode"
  log_line "target root: ${TARGET_ROOT}"
  log_line "expected Name tag pattern: fjcloud-api-<env>"
  log_line "verify deployed SHA source: /fjcloud/<env>/last_deploy_sha"
  log_line "expected deployed SHA floor: ${EXPECTED_DEPLOYED_SHA}"
  log_line "live run requires ec2:DescribeTags on the instance role"
  log_line "live evidence log path prefix: /tmp/api_server_metering_cleanup_<UTC>.log"

  print_dry_run_action "verify API-server host identity via IMDSv2 + ec2:DescribeTags" "planned" "expected Name tag pattern: fjcloud-api-<env>"
  print_dry_run_action "verify deployed SHA gate" "planned" "source=/fjcloud/<env>/last_deploy_sha expected=${EXPECTED_DEPLOYED_SHA}"
  print_dry_run_action "stop fj-metering-agent.service" "planned" "systemctl stop when active"
  print_dry_run_action "disable fj-metering-agent.service" "planned" "systemctl disable when enabled"
  print_dry_run_action "remove service unit" "$unit_status" "$unit_path"
  print_dry_run_action "systemctl daemon-reload" "$daemon_reload_status" "$daemon_reload_detail"
  print_dry_run_action "remove metering env file" "$(file_status_for_dry_run "$metering_env_path")" "$metering_env_path"
  print_dry_run_action "remove metering binary" "$(file_status_for_dry_run "$binary_path")" "$binary_path"
  print_dry_run_action "remove metering backup binary" "$(file_status_for_dry_run "$old_binary_path")" "$old_binary_path"

  log_line "dry-run does not create an evidence log"
  log_line "planned cleanup complete"
  log_line "re-run without --dry-run on the API server after the cleanup deploy is live"
}

run_live_cleanup() {
  local timestamp unit_path metering_env_path binary_path old_binary_path
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  LOG_FILE="${LOG_DIR}/api_server_metering_cleanup_${timestamp}.log"

  unit_path="$(target_path /etc/systemd/system/fj-metering-agent.service)"
  metering_env_path="$(target_path /etc/fjcloud/metering-env)"
  binary_path="$(target_path /usr/local/bin/fj-metering-agent)"
  old_binary_path="$(target_path /usr/local/bin/fj-metering-agent.old)"

  : > "$LOG_FILE"
  log_line "cleanup_api_server_metering_ghost.sh live mode"
  log_line "target root: ${TARGET_ROOT}"
  log_line "expected deployed SHA floor: ${EXPECTED_DEPLOYED_SHA}"
  log_line "evidence log: ${LOG_FILE}"

  verify_host_identity
  verify_deployed_sha_gate

  capture_optional_command "before: systemctl status fj-metering-agent.service" "$SYSTEMCTL_BIN" status fj-metering-agent.service --no-pager --full
  capture_optional_command "before: file listing" ls -l "$unit_path" "$metering_env_path" "$binary_path" "$old_binary_path"

  maybe_stop_service
  maybe_disable_service
  if remove_file_if_present "remove service unit" "$unit_path"; then
    reload_systemd
  else
    log_line "==> systemctl daemon-reload [no-op] service unit already absent"
  fi
  remove_file_if_present "remove metering env file" "$metering_env_path"
  remove_file_if_present "remove metering binary" "$binary_path"
  remove_file_if_present "remove metering backup binary" "$old_binary_path"

  capture_optional_command "after: systemctl status fj-metering-agent.service" "$SYSTEMCTL_BIN" status fj-metering-agent.service --no-pager --full
  capture_optional_command "after: file listing" ls -l "$unit_path" "$metering_env_path" "$binary_path" "$old_binary_path"

  log_line "cleanup complete"
  log_line "evidence saved to ${LOG_FILE}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$DRY_RUN" == "true" ]]; then
  print_dry_run_plan
  exit 0
fi

require_commands
run_live_cleanup
