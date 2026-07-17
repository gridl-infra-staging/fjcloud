#!/usr/bin/env bash
# Live prod contract probe: does /fjcloud/prod/admin_key satisfy
# DELETE /admin/tenants/00000000-0000-0000-0000-000000000000 on api.flapjack.foo?

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/live_prod_reject_probe_lib.sh"

ADMIN_KEY_PARAMETER="/fjcloud/prod/admin_key"
ADMIN_CLEANUP_URL="https://api.flapjack.foo/admin/tenants/00000000-0000-0000-0000-000000000000"

skip_with_hint() {
  printf 'SKIP: %s\n' "$1"
}

aws_auth_is_available() {
  if aws sts get-caller-identity >/dev/null 2>&1; then
    return 0
  fi

  skip_with_hint "aws sts get-caller-identity failed; configure AWS auth and retry (for example: aws sso login --profile <profile>)"
  return 1
}

resolve_admin_key_from_ssm() {
  local resolved_value

  if ! resolved_value="$(
    aws ssm get-parameter \
      --name "$ADMIN_KEY_PARAMETER" \
      --with-decryption \
      --query 'Parameter.Value' \
      --output text 2>/dev/null
  )"; then
    skip_with_hint "unable to resolve $ADMIN_KEY_PARAMETER; verify ssm:GetParameter access and parameter availability"
    return 1
  fi

  if [[ -z "$resolved_value" || "$resolved_value" == "None" ]]; then
    skip_with_hint "resolved empty value for $ADMIN_KEY_PARAMETER; verify parameter value in SSM"
    return 1
  fi

  RESOLVED_ADMIN_KEY="$resolved_value"
  return 0
}

main() {
  local response_path status_code
  local RESOLVED_ADMIN_KEY=""

  if ! aws_auth_is_available; then
    exit 0
  fi

  if ! resolve_admin_key_from_ssm; then
    exit 0
  fi

  response_path="$(live_prod_response_path "customer_loop_admin_cleanup_live_contract")"
  capture_live_prod_response "$response_path" \
    -X DELETE "$ADMIN_CLEANUP_URL" \
    -H "x-admin-key: ${RESOLVED_ADMIN_KEY}"

  status_code="$(extract_status_code "$response_path")"
  case "$status_code" in
    204|404)
      printf 'PASS: admin_cleanup live contract observed HTTP %s\n' "$status_code"
      ;;
    401)
      printf 'FAIL: admin_cleanup live contract observed HTTP 401 (possible ADMIN_KEY drift)\n' >&2
      exit 1
      ;;
    *)
      printf 'FAIL: expected HTTP 204, 404, or 401; observed HTTP %s\n' "$status_code" >&2
      exit 1
      ;;
  esac
}

main "$@"
