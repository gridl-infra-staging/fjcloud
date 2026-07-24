#!/usr/bin/env bash
# init-cluster.sh — Initialize Garage cluster layout, create S3 credentials + bucket
#
# Runs ONCE after first `systemctl start garage`. Idempotent — safe to re-run.
#
# Usage: init-cluster.sh
#
# Prerequisites:
#   - Garage running (systemctl start garage)
#   - /etc/garage/garage.toml exists with admin_token configured
#   - curl installed

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

GARAGE_BIN="${GARAGE_BIN:-/usr/local/bin/garage}"
GARAGE_CONF="${GARAGE_CONF:-/etc/garage/garage.toml}"
ADMIN_ADDR="${ADMIN_ADDR:-http://127.0.0.1:3903}"

BUCKET_NAME="${BUCKET_NAME:-cold-storage}"
KEY_NAME="${KEY_NAME:-griddle-cold-storage}"
LAYOUT_ZONE="${LAYOUT_ZONE:-dc1}"
LAYOUT_CAPACITY="${LAYOUT_CAPACITY:-1G}"

ENV_FILE="${ENV_FILE:-/etc/garage/env}"
GARAGE_GROUP="${GARAGE_GROUP:-garage}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
ADMIN_HEALTH_ATTEMPTS="${ADMIN_HEALTH_ATTEMPTS:-30}"
ADMIN_HEALTH_INTERVAL_SECS="${ADMIN_HEALTH_INTERVAL_SECS:-1}"

TAG="garage-init"
CONFIG_ADMIN_TOKEN=""
CONFIG_RPC_SECRET=""
CONFIG_META_DIR=""
CONFIG_DATA_DIR=""
CONFIG_ADMIN_ENDPOINT=""
CONFIG_S3_ENDPOINT=""
CONFIG_S3_REGION=""
ACCESS_KEY=""
SECRET_KEY=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    return 1
  fi
}

extract_config_string_value() {
  local key_name="$1"

  sed -n "s/^${key_name}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"/\\1/p" "$GARAGE_CONF" | head -1
}

extract_config_section_string_value() {
  local section_name="$1"
  local key_name="$2"

  awk -v section_name="$section_name" -v key_name="$key_name" '
    /^[[:space:]]*\[/ {
      in_section = ($0 ~ "^[[:space:]]*\\[" section_name "\\][[:space:]]*$")
      next
    }
    in_section && $0 ~ "^[[:space:]]*" key_name "[[:space:]]*=" {
      sub("^[[:space:]]*" key_name "[[:space:]]*=[[:space:]]*\"", "", $0)
      sub("\"[[:space:]]*(#.*)?$", "", $0)
      print
      exit
    }
  ' "$GARAGE_CONF"
}

endpoint_from_bind_addr() {
  local bind_addr="$1"
  local host port

  if [[ "$bind_addr" =~ ^0\.0\.0\.0:([0-9]+)$ ]]; then
    host="127.0.0.1"
    port="${BASH_REMATCH[1]}"
  elif [[ "$bind_addr" =~ ^\[::\]:([0-9]+)$ ]]; then
    host="[::1]"
    port="${BASH_REMATCH[1]}"
  elif [[ "$bind_addr" =~ ^\[([0-9A-Fa-f:]+)\]:([0-9]+)$ ]]; then
    host="[${BASH_REMATCH[1]}]"
    port="${BASH_REMATCH[2]}"
  elif [[ "$bind_addr" =~ ^([^:]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    echo "ERROR: Unsupported bind address format: ${bind_addr}"
    return 1
  fi

  printf 'http://%s:%s' "$host" "$port"
}

wait_for_admin_api() {
  local attempt http_code

  for ((attempt = 1; attempt <= ADMIN_HEALTH_ATTEMPTS; attempt++)); do
    http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout "$CURL_TIMEOUT" "${ADMIN_ADDR}/health" 2>/dev/null || echo "000")"
    if [[ "$http_code" == "200" ]]; then
      return 0
    fi

    sleep "$ADMIN_HEALTH_INTERVAL_SECS"
  done

  echo "ERROR: Garage admin API did not become ready at ${ADMIN_ADDR}/health"
  return 1
}

run_garage() {
  "$GARAGE_BIN" -c "$GARAGE_CONF" "$@"
}

run_garage_capture() {
  local output

  if output="$(run_garage "$@" 2>&1)"; then
    printf '%s' "$output"
    return 0
  fi

  printf '%s' "$output"
  return 1
}

layout_version() {
  sed -n 's/^Current cluster layout version:[[:space:]]*//p' <<< "$1" | head -1
}

current_layout_has_node() {
  local layout_output="$1"
  local node_id="$2"

  awk -v node_id="$node_id" '
    /^==== CURRENT CLUSTER LAYOUT ====/{in_current=1; next}
    /^==== / && in_current {in_current=0}
    in_current && $1 == node_id {found=1}
    END { exit found ? 0 : 1 }
  ' <<< "$layout_output"
}

resolve_s3_key_output() {
  local key_output

  if key_output="$(run_garage_capture key info --show-secret "$KEY_NAME")"; then
    printf '%s' "$key_output"
    return 0
  fi

  if [[ "$key_output" == *"0 matching keys"* ]]; then
    run_garage_capture key create "$KEY_NAME"
    return $?
  fi

  if [[ "$key_output" == *"matching keys"* ]]; then
    echo "ERROR: Multiple Garage keys match ${KEY_NAME}. Clean up duplicate keys before rerunning init-cluster.sh."
    return 1
  fi

  echo "ERROR: Could not inspect or create Garage key ${KEY_NAME}"
  echo "$key_output"
  return 1
}

parse_key_field() {
  local field_name="$1"
  local key_output="$2"

  sed -n "s/^${field_name}:[[:space:]]*//p" <<< "$key_output" | head -1
}

validate_preconditions() {
  require_root

  if [[ ! -f "$GARAGE_CONF" ]]; then
    echo "ERROR: Garage config not found at ${GARAGE_CONF}"
    return 1
  fi

  if ! systemctl is-active --quiet garage; then
    echo "ERROR: Garage service is not running. Start with: sudo systemctl start garage"
    return 1
  fi
}

load_contract_config() {
  local admin_bind_addr s3_bind_addr

  CONFIG_ADMIN_TOKEN="$(extract_config_string_value admin_token)"
  CONFIG_RPC_SECRET="$(extract_config_string_value rpc_secret)"
  CONFIG_META_DIR="$(extract_config_string_value metadata_dir)"
  CONFIG_DATA_DIR="$(extract_config_string_value data_dir)"
  admin_bind_addr="$(extract_config_section_string_value admin api_bind_addr)"
  s3_bind_addr="$(extract_config_section_string_value s3_api api_bind_addr)"
  CONFIG_S3_REGION="$(extract_config_section_string_value s3_api s3_region)"

  if [[ -z "$CONFIG_ADMIN_TOKEN" ]]; then
    echo "ERROR: Could not extract admin_token from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$CONFIG_RPC_SECRET" ]]; then
    echo "ERROR: Could not extract rpc_secret from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$CONFIG_META_DIR" ]]; then
    echo "ERROR: Could not extract metadata_dir from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$CONFIG_DATA_DIR" ]]; then
    echo "ERROR: Could not extract data_dir from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$admin_bind_addr" ]]; then
    echo "ERROR: Could not extract [admin].api_bind_addr from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$s3_bind_addr" ]]; then
    echo "ERROR: Could not extract [s3_api].api_bind_addr from ${GARAGE_CONF}"
    return 1
  fi

  if [[ -z "$CONFIG_S3_REGION" ]]; then
    echo "ERROR: Could not extract [s3_api].s3_region from ${GARAGE_CONF}"
    return 1
  fi

  CONFIG_ADMIN_ENDPOINT="$(endpoint_from_bind_addr "$admin_bind_addr")"
  CONFIG_S3_ENDPOINT="$(endpoint_from_bind_addr "$s3_bind_addr")"
  ADMIN_ADDR="$CONFIG_ADMIN_ENDPOINT"
}

configure_cluster_layout() {
  local node_id layout_show current_layout_version next_version

  logger -t "$TAG" "Configuring cluster layout"

  node_id="$(run_garage node id | head -1 | awk '{print $1}')"
  if [[ -z "$node_id" ]]; then
    echo "ERROR: Could not determine Garage node ID"
    return 1
  fi

  layout_show="$(run_garage_capture layout show)"
  current_layout_version="$(layout_version "$layout_show")"
  if [[ ! "$current_layout_version" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Could not determine current cluster layout version"
    return 1
  fi

  if current_layout_has_node "$layout_show" "$node_id"; then
    logger -t "$TAG" "Layout already contains node ${node_id:0:16}..., skipping assign/apply"
  else
    run_garage layout assign "$node_id" -z "$LAYOUT_ZONE" -c "$LAYOUT_CAPACITY" >/dev/null
    next_version=$((current_layout_version + 1))
    run_garage layout apply --version "$next_version" >/dev/null
    logger -t "$TAG" "Layout applied (version ${next_version})"
  fi

  printf '%s' "$node_id"
}

load_s3_credentials() {
  local key_output

  logger -t "$TAG" "Ensuring S3 access key exists: ${KEY_NAME}"

  key_output="$(resolve_s3_key_output)"
  ACCESS_KEY="$(parse_key_field "Key ID" "$key_output")"
  SECRET_KEY="$(parse_key_field "Secret key" "$key_output")"

  if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || "$SECRET_KEY" == "(redacted)" ]]; then
    echo "ERROR: Could not extract usable S3 credentials for key ${KEY_NAME}"
    return 1
  fi

  logger -t "$TAG" "Using key ${KEY_NAME} — Access Key: ${ACCESS_KEY}"
}

configure_bucket_access() {
  ensure_bucket_exists
  run_garage bucket allow "$BUCKET_NAME" --read --write --key "$ACCESS_KEY" >/dev/null
  logger -t "$TAG" "Bucket ${BUCKET_NAME} ready with key ${ACCESS_KEY}"
}

ensure_bucket_exists() {
  if run_garage bucket info "$BUCKET_NAME" &>/dev/null; then
    logger -t "$TAG" "Bucket ${BUCKET_NAME} already exists"
    return 0
  fi

  run_garage bucket create "$BUCKET_NAME" >/dev/null
  logger -t "$TAG" "Bucket ${BUCKET_NAME} created"
}

write_env_file() {
  local access_key="$1"
  local secret_key="$2"
  local admin_token="$3"
  local rpc_secret="$4"
  local meta_dir="$5"
  local data_dir="$6"
  local env_dir tmp_env

  logger -t "$TAG" "Writing environment file to ${ENV_FILE}"

  env_dir="$(dirname "$ENV_FILE")"
  mkdir -p "$env_dir"

  tmp_env="$(mktemp "${env_dir}/$(basename "$ENV_FILE").tmp.XXXXXX")"
  trap 'rm -f "$tmp_env"' RETURN

  cat > "$tmp_env" <<ENVEOF
# Garage infrastructure credentials — generated by init-cluster.sh
# Source this file or point EnvironmentFile= at it.

GARAGE_META_DIR=${meta_dir}
GARAGE_DATA_DIR=${data_dir}
GARAGE_RPC_SECRET=${rpc_secret}
GARAGE_ADMIN_ENDPOINT=${CONFIG_ADMIN_ENDPOINT}
GARAGE_ADMIN_TOKEN=${admin_token}
GARAGE_S3_ENDPOINT=${CONFIG_S3_ENDPOINT}
GARAGE_S3_REGION=${CONFIG_S3_REGION}
GARAGE_S3_BUCKET=${BUCKET_NAME}
GARAGE_S3_ACCESS_KEY=${access_key}
GARAGE_S3_SECRET_KEY=${secret_key}
ENVEOF

  chown root:"${GARAGE_GROUP}" "$tmp_env"
  chmod 0640 "$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
  trap - RETURN
}

print_summary() {
  local node_id="$1"

  echo ""
  echo "Garage cluster initialized successfully."
  echo ""
  echo "  Node ID:    ${node_id:0:16}..."
  echo "  Bucket:     ${BUCKET_NAME}"
  echo "  Key:        ${KEY_NAME}"
  echo "  Access Key: ${ACCESS_KEY}"
  echo "  Env file:   ${ENV_FILE}"
  echo ""
  echo "Next steps:"
  echo "  1. Verify:  sudo ops/garage/scripts/health-check.sh"
  echo "  2. Bridge:  set COLD_STORAGE_ENDPOINT=\$GARAGE_S3_ENDPOINT in app config"
  echo ""
}

main() {
  local node_id

  # ---------------------------------------------------------------------------
  # 1. Preflight checks
  # ---------------------------------------------------------------------------

  logger -t "$TAG" "Starting Garage cluster initialization"

  validate_preconditions
  load_contract_config
  wait_for_admin_api

  # ---------------------------------------------------------------------------
  # 2. Get node ID and assign layout
  # ---------------------------------------------------------------------------

  node_id="$(configure_cluster_layout)"

  # ---------------------------------------------------------------------------
  # 3. Create or reuse S3 access key
  # ---------------------------------------------------------------------------

  load_s3_credentials

  # ---------------------------------------------------------------------------
  # 4. Create bucket and grant permissions
  # ---------------------------------------------------------------------------

  configure_bucket_access

  # ---------------------------------------------------------------------------
  # 5. Write environment file for application consumption
  # ---------------------------------------------------------------------------

  write_env_file "$ACCESS_KEY" "$SECRET_KEY" "$CONFIG_ADMIN_TOKEN" "$CONFIG_RPC_SECRET" "$CONFIG_META_DIR" "$CONFIG_DATA_DIR"
  logger -t "$TAG" "Environment file written to ${ENV_FILE}"

  # ---------------------------------------------------------------------------
  # 6. Summary
  # ---------------------------------------------------------------------------

  print_summary "$node_id"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
