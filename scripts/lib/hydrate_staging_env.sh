#!/usr/bin/env bash
# hydrate_staging_env.sh — shared helpers to hydrate staging-targeted
# environment variables from SSM.
#
# Single canonical owner for the three hydration primitives. Sourced by:
#   - scripts/launch/run_browser_lane_against_staging.sh
#   - scripts/verify/rerun_failing_lanes.sh
#
# Callers must define REPO_ROOT before sourcing so the SSM shim script
# path resolves consistently.
#
# Exported functions:
#   is_allowed_hydrated_key     — allowlist gate for hydrated env keys.
#   validate_hydrated_export_line — reject anything other than a well-formed
#                                   `export KEY=VALUE` line for an allowed key.
#   hydrate_env_from_ssm         — invoke the SSM shim for a target env,
#                                   validate every emitted line, then source it
#                                   into the current shell.
#   hydrate_staging_env_from_ssm — compatibility wrapper for staging callers.

is_allowed_hydrated_key() {
  case "$1" in
    ADMIN_KEY|DATABASE_URL|API_URL|FLAPJACK_URL|STRIPE_SECRET_KEY|SES_FROM_ADDRESS|SES_REGION|STRIPE_WEBHOOK_SECRET|STAGING_API_URL|STAGING_STRIPE_WEBHOOK_URL|STAGING_CLOUD_URL)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_hydrated_export_line() {
  local line="$1"
  local payload key raw_value

  case "$line" in
    export\ *=*)
      payload="${line#export }"
      key="${payload%%=*}"
      raw_value="${payload#*=}"
      ;;
    *)
      return 1
      ;;
  esac

  is_allowed_hydrated_key "$key" || return 1
  [ -n "$raw_value" ] || return 1

  case "$raw_value" in
    *$'\n'*|*$'\r'*)
      return 1
      ;;
    \$\'*\')
      [[ "$raw_value" =~ ^\$\'([^\'\\]|\\.)*\'$ ]] || return 1
      ;;
    *)
      [[ "$raw_value" =~ ^([^[:space:];\&\|<>\`\"\'\$]|\'[^\']*\'|\\.)+$ ]] || return 1
      ;;
  esac
}

hydrate_env_from_ssm() {
  local environment="${1:-staging}"
  case "$environment" in
    staging|prod)
      ;;
    *)
      echo "ERROR: unsupported SSM hydration environment '$environment'" >&2
      return 1
      ;;
  esac

  local hydrate_output source_status
  hydrate_output="$(mktemp "${TMPDIR:-/tmp}/fjcloud_stage_hydrate.XXXXXX")"

  if ! bash "$REPO_ROOT/scripts/launch/hydrate_seeder_env_from_ssm.sh" "$environment" > "$hydrate_output"; then
    rm -f "$hydrate_output"
    return 1
  fi

  while IFS= read -r line; do
    if ! validate_hydrated_export_line "$line"; then
      rm -f "$hydrate_output"
      echo "ERROR: hydrate_seeder_env_from_ssm.sh emitted an unexpected export line" >&2
      return 1
    fi
  done < "$hydrate_output"

  # shellcheck disable=SC1090
  source "$hydrate_output"
  source_status=$?
  rm -f "$hydrate_output"
  return "$source_status"
}

hydrate_staging_env_from_ssm() {
  hydrate_env_from_ssm staging
}
