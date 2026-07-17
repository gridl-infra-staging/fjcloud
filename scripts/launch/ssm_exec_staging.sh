#!/usr/bin/env bash
# ssm_exec_staging.sh — synchronously run a shell command on the staging
# fjcloud API EC2 instance via AWS SSM RunShellScript.
#
# Usage:
#   scripts/launch/ssm_exec_staging.sh "<shell command...>"
#
# Returns the SSM invocation's StandardOutputContent on stdout and exits
# with the command's status. Used as the operator-side wrapper for any
# "run this on staging" maintenance step (post-deploy verification,
# usage_records spot checks, the staging billing rehearsal launch from
# the EC2 host where DATABASE_URL is reachable, etc.) when an operator
# is driving the work from outside the staging VPC.
#
# IAM requirement: caller must hold ssm:SendCommand and
# ssm:GetCommandInvocation against the target instance. The EC2 instance
# itself must already have AmazonSSMManagedInstanceCore for inbound exec.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENVIRONMENT="${SSM_EXEC_ENVIRONMENT:-staging}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"
INSTANCE_TAG_NAME="fjcloud-api-${ENVIRONMENT}"
TIMEOUT_SECONDS="${SSM_EXEC_TIMEOUT_SECONDS:-300}"
POLL_INTERVAL_SECONDS="${SSM_EXEC_POLL_INTERVAL_SECONDS:-3}"

if [ "$#" -lt 1 ]; then
  echo "Usage: $0 \"<shell command...>\"" >&2
  exit 64
fi

COMMAND="$1"

instance_id="$(aws ec2 describe-instances \
  --region "$REGION" \
  --filters "Name=tag:Name,Values=${INSTANCE_TAG_NAME}" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" \
  --output text 2>/dev/null)"

if [ -z "$instance_id" ] || [ "$instance_id" = "None" ]; then
  echo "ERROR: no running instance with tag Name=${INSTANCE_TAG_NAME} in ${REGION}" >&2
  exit 1
fi

# Tell SSM to run the command. We pass the command as a single string so
# it gets shell-interpreted on the instance side; quoting in $COMMAND is
# the caller's responsibility.
command_id="$(aws ssm send-command \
  --region "$REGION" \
  --instance-ids "$instance_id" \
  --document-name "AWS-RunShellScript" \
  --comment "ssm_exec_staging.sh wrapper" \
  --parameters "commands=[\"${COMMAND//\"/\\\"}\"]" \
  --query "Command.CommandId" \
  --output text 2>/dev/null)"

if [ -z "$command_id" ] || [ "$command_id" = "None" ]; then
  echo "ERROR: aws ssm send-command did not return a CommandId" >&2
  exit 1
fi

deadline=$(( $(date +%s) + TIMEOUT_SECONDS ))

while true; do
  invocation_json="$(aws ssm get-command-invocation \
    --region "$REGION" \
    --instance-id "$instance_id" \
    --command-id "$command_id" \
    --output json 2>/dev/null || true)"

  status="$(printf '%s' "$invocation_json" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
    print(payload.get("Status", ""))
except Exception:
    pass
')"

  case "$status" in
    Success|Failed|Cancelled|TimedOut)
      stdout="$(printf '%s' "$invocation_json" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(payload.get("StandardOutputContent", ""), end="")
')"
      stderr="$(printf '%s' "$invocation_json" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
print(payload.get("StandardErrorContent", ""), end="")
')"
      printf '%s' "$stdout"
      if [ -n "$stderr" ]; then
        printf '%s' "$stderr" >&2
      fi
      [ "$status" = "Success" ] && exit 0
      exit 1
      ;;
  esac

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "ERROR: ssm_exec_staging.sh timed out after ${TIMEOUT_SECONDS}s waiting for command_id=${command_id}" >&2
    exit 124
  fi

  sleep "$POLL_INTERVAL_SECONDS"
done
