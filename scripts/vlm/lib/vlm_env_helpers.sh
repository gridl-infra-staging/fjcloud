#!/usr/bin/env bash
# VLM env helpers — self-contained 5-function closure extracted from
# uff_dev/scripts/lib/deployment_common.sh for the VLM judge's
# read_env_value_trimmed contract.

set -euo pipefail

read_env_value_raw() {
  local env_file="$1"
  local var_name="$2"
  awk -v key="$var_name" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line ~ /^#/ || line == "") {
        next
      }
      if (line ~ /^export[[:space:]]+/) {
        sub(/^export[[:space:]]+/, "", line)
      }
      split(line, pieces, "=")
      current_key = pieces[1]
      gsub(/[[:space:]]+$/, "", current_key)
      if (current_key != key) {
        next
      }
      value = substr(line, index(line, "=") + 1)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "$env_file" 2>/dev/null || true
}

is_runtime_app_env_asset() {
  local env_file="$1"
  case "$(basename "$env_file")" in
    .env.dev|.env.staging|.env.prod)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

resolve_host_only_env_overlay_path() {
  local env_file="$1"

  if ! is_runtime_app_env_asset "$env_file"; then
    return 1
  fi

  case "$(basename "$env_file")" in
    .env.staging)
      printf '%s\n' "${HOSTED_DEPLOY_ENV_FILE:-.env.hosted.staging}"
      ;;
    .env.prod)
      printf '%s\n' "${HOSTED_DEPLOY_ENV_FILE:-.env.hosted.prod}"
      ;;
    *)
      return 1
      ;;
  esac
}

is_host_only_deploy_key() {
  local key_name="$1"
  case "$key_name" in
    SUPABASE_SERVICE_ROLE_KEY|SUPABASE_DB_PASSWORD|FCM_PROJECT_ID|FCM_CLIENT_EMAIL|FCM_PRIVATE_KEY|NOTIFICATION_WEBHOOK_SECRET|MODERATION_REPORT_RECIPIENT_ID|HEALTHCHECKS_NOTIFY_UUID)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

read_env_value() {
  local env_file="$1"
  local var_name="$2"
  local value=""
  local overlay_file=""

  value="$(read_env_value_raw "$env_file" "$var_name")"
  if [[ -n "$value" ]]; then
    printf '%s\n' "$value"
    return 0
  fi

  if ! is_host_only_deploy_key "$var_name"; then
    return 0
  fi

  overlay_file="$(resolve_host_only_env_overlay_path "$env_file" || true)"
  if [[ -z "$overlay_file" || ! -f "$overlay_file" ]]; then
    return 0
  fi

  read_env_value_raw "$overlay_file" "$var_name"
}

read_env_value_trimmed() {
  local value
  value="$(read_env_value "$1" "$2")"
  printf '%s' "${value}" | tr -d '[:space:]'
}
