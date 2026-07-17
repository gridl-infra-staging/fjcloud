#!/usr/bin/env bash
# set_algolia_migration_availability.sh — bounded Algolia migration toggle.
#
# Dry-run by default. Live execution updates the canonical SSM parameter,
# regenerates /etc/fjcloud/env on every running fjcloud-api-<env> instance,
# restarts fjcloud-api, and proves each instance individually.

set -euo pipefail

AWS_BIN="${FJCLOUD_AWS_BIN:-aws}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
POLL_ATTEMPTS="${FJCLOUD_ALGOLIA_TOGGLE_POLL_ATTEMPTS:-30}"
POLL_SLEEP_SECONDS="${FJCLOUD_ALGOLIA_TOGGLE_POLL_SLEEP_SECONDS:-2}"

ENVIRONMENT=""
ENABLED=""
EXPECTED_API_DEV_SHA=""
EXPECTED_MIRROR_SHA=""
EXECUTE=0

usage() {
  cat <<'EOF'
Usage: set_algolia_migration_availability.sh --env <staging|prod> --enabled <true|false> --expected-api-dev-sha <sha> --expected-mirror-sha <sha> [--execute]

Options:
  --env                      Target environment: staging or prod.
  --enabled                  Canonical runtime parameter value: true or false.
  --expected-api-dev-sha     Expected /version dev_sha on every selected API instance.
  --expected-mirror-sha      Expected /version mirror_sha on every selected API instance.
  --execute                  Mutate SSM, regenerate env, restart, and prove. Omit for dry-run.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

json_commands() {
  python3 - "$1" <<'PY'
import json
import sys

print(json.dumps({"commands": [sys.argv[1]]}))
PY
}

shell_quote() {
  python3 - "$1" <<'PY'
import shlex
import sys

print(shlex.quote(sys.argv[1]))
PY
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --env)
        [ "${2:-}" != "" ] || die "--env requires a value"
        ENVIRONMENT="$2"
        shift 2
        ;;
      --enabled)
        [ "${2:-}" != "" ] || die "--enabled requires a value"
        ENABLED="$2"
        shift 2
        ;;
      --expected-api-dev-sha)
        [ "${2:-}" != "" ] || die "--expected-api-dev-sha requires a value"
        EXPECTED_API_DEV_SHA="$2"
        shift 2
        ;;
      --expected-mirror-sha)
        [ "${2:-}" != "" ] || die "--expected-mirror-sha requires a value"
        EXPECTED_MIRROR_SHA="$2"
        shift 2
        ;;
      --execute)
        EXECUTE=1
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "unknown argument: $1"
        ;;
    esac
  done
}

validate_args() {
  [ -n "$ENVIRONMENT" ] || die "--env is required"
  [ -n "$ENABLED" ] || die "--enabled is required"
  [ -n "$EXPECTED_API_DEV_SHA" ] || die "--expected-api-dev-sha is required"
  [ -n "$EXPECTED_MIRROR_SHA" ] || die "--expected-mirror-sha is required"

  case "$ENVIRONMENT" in
    staging|prod) ;;
    *) die "--env must be staging or prod" ;;
  esac

  case "$ENABLED" in
    true|false) ;;
    *) die "--enabled must be true or false" ;;
  esac

  [[ "$EXPECTED_API_DEV_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || die "--expected-api-dev-sha must be a 40-character lowercase hexadecimal SHA"
  [[ "$EXPECTED_MIRROR_SHA" =~ ^[0-9a-f]{40}$ ]] \
    || die "--expected-mirror-sha must be a 40-character lowercase hexadecimal SHA"
}

parameter_name() {
  printf '/fjcloud/%s/algolia_migration_enabled\n' "$ENVIRONMENT"
}

discover_instances() {
  local output
  output="$("$AWS_BIN" ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=fjcloud-api-${ENVIRONMENT}" "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text)"

  printf '%s\n' "$output" | tr '\t' '\n' | sed '/^$/d;/^None$/d'
}

send_remote_command() {
  local instance_id="$1"
  local comment="$2"
  local script="$3"
  local parameters command_id

  parameters="$(json_commands "$script")"
  command_id="$("$AWS_BIN" ssm send-command \
    --region "$REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "$parameters" \
    --timeout-seconds 180 \
    --comment "$comment" \
    --query 'Command.CommandId' \
    --output text)"
  printf '%s\n' "$command_id"
}

poll_remote_command() {
  local instance_id="$1"
  local command_id="$2"
  local attempt status

  for attempt in $(seq 1 "$POLL_ATTEMPTS"); do
    status="$("$AWS_BIN" ssm get-command-invocation \
      --region "$REGION" \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --query 'Status' \
      --output text 2>/dev/null || echo Pending)"

    case "$status" in
      Success)
        "$AWS_BIN" ssm get-command-invocation \
          --region "$REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query 'StandardOutputContent' \
          --output text
        return 0
        ;;
      Failed|TimedOut|Cancelled|Cancelling)
        "$AWS_BIN" ssm get-command-invocation \
          --region "$REGION" \
          --command-id "$command_id" \
          --instance-id "$instance_id" \
          --query '[StandardOutputContent, StandardErrorContent]' \
          --output text 2>/dev/null || true
        return 1
        ;;
      *)
        sleep "$POLL_SLEEP_SECONDS"
        ;;
    esac
  done

  echo "ERROR: SSM command ${command_id} did not finish for ${instance_id}" >&2
  return 1
}

build_proof_script() {
  cat <<EOF
set -euo pipefail
/opt/fjcloud/scripts/generate_ssm_env.sh "$ENVIRONMENT"
systemctl restart fjcloud-api
env_value="\$(grep '^FJCLOUD_ALGOLIA_MIGRATION_ENABLED=' /etc/fjcloud/env | tail -n1 | cut -d= -f2-)"
version_json="\$(curl -fsS http://127.0.0.1:3001/version)"
printf 'ENV_VALUE=%s\n' "\$env_value"
printf 'VERSION_JSON=%s\n' "\$version_json"
EOF
}

validate_instance_proof() {
  local instance_id="$1"
  local proof_output="$2"

  PROOF_OUTPUT="$proof_output" python3 - "$instance_id" "$ENABLED" "$EXPECTED_API_DEV_SHA" "$EXPECTED_MIRROR_SHA" <<'PY'
import json
import os
import sys

instance_id, expected_enabled, expected_dev_sha, expected_mirror_sha = sys.argv[1:]
fields = {}
for line in os.environ["PROOF_OUTPUT"].splitlines():
    if "=" in line:
        key, value = line.split("=", 1)
        fields[key] = value

missing = [key for key in ("ENV_VALUE", "VERSION_JSON") if key not in fields]
if missing:
    raise SystemExit(f"{instance_id}: proof output missing {','.join(missing)}")

if fields["ENV_VALUE"] != expected_enabled:
    raise SystemExit(f"{instance_id}: env value {fields['ENV_VALUE']} != {expected_enabled}")

version = json.loads(fields["VERSION_JSON"])
if version.get("dev_sha") != expected_dev_sha:
    raise SystemExit(f"{instance_id}: dev_sha mismatch")
if version.get("mirror_sha") != expected_mirror_sha:
    raise SystemExit(f"{instance_id}: mirror_sha mismatch")
PY
}

stop_api_service() {
  local instance_id="$1"
  local command_id
  command_id="$(send_remote_command "$instance_id" "fjcloud fail-closed stop algolia migration toggle" "set -euo pipefail
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

main() {
  parse_args "$@"
  validate_args

  INSTANCE_IDS=()
  while IFS= read -r instance_id; do
    [ -n "$instance_id" ] && INSTANCE_IDS+=("$instance_id")
  done < <(discover_instances)
  [ "${#INSTANCE_IDS[@]}" -gt 0 ] || die "no running fjcloud-api-${ENVIRONMENT} instances found"

  echo "==> Target parameter: $(parameter_name)"
  echo "==> Target instances: ${INSTANCE_IDS[*]}"

  if [ "$EXECUTE" -ne 1 ]; then
    echo "==> Dry-run: would set $(parameter_name)=${ENABLED}"
    echo "==> Dry-run: would regenerate env, restart fjcloud-api, and prove each instance"
    return 0
  fi

  "$AWS_BIN" ssm put-parameter \
    --region "$REGION" \
    --name "$(parameter_name)" \
    --type String \
    --value "$ENABLED" \
    --overwrite >/dev/null

  readback="$("$AWS_BIN" ssm get-parameter \
    --region "$REGION" \
    --name "$(parameter_name)" \
    --query 'Parameter.Value' \
    --output text)"
  [ "$readback" = "$ENABLED" ] || die "SSM readback mismatch for $(parameter_name)"

  proof_failed=0
  for instance_id in "${INSTANCE_IDS[@]}"; do
    echo "==> Proving ${instance_id}"
    command_id="$(send_remote_command "$instance_id" "fjcloud algolia migration availability toggle" "$(build_proof_script)")"
    proof_output="$(poll_remote_command "$instance_id" "$command_id")" || proof_failed=1
    if [ "$proof_failed" -eq 0 ]; then
      validate_instance_proof "$instance_id" "$proof_output" || proof_failed=1
    fi
  done

  if [ "$proof_failed" -ne 0 ]; then
    if [ "$ENABLED" = "false" ]; then
      fail_closed_stop_all
    fi
    die "unable to prove unanimous ${ENVIRONMENT} Algolia migration availability state"
  fi

  echo "==> Algolia migration availability parameter proved on all selected ${ENVIRONMENT} API instances"
  if [ "$ENABLED" = "true" ]; then
    echo "==> Stage 1 remains fail-closed in code; customer availability stays temporarily_unavailable"
  fi
}

main "$@"
