#!/usr/bin/env bash
# EC2 firewalld port-coverage contract. Asserts that every running
# fjcloud-api-* EC2 has 3001/tcp and 3002/tcp open in firewalld.
#
# Catches the bug class where firewalld config drifts from the AMI bake state.
# The fjcloud-api binary listens on 3001 (public API) and 3002 (internal S3
# API). If either is blocked, the ALB target-group health-check fails.
set -euo pipefail

# --self-test mode: run the probe twice in-memory against a captured fixture
# of `firewall-cmd --list-ports` output. First call with the real ports,
# second with a fake-required port (9999/tcp) that is NOT in the fixture.
# Asserts the first PASSes and the second FAILs. This is the canary-of-the-
# canary: proves the probe can actually report a failure.
if [[ "${1:-}" == "--self-test" ]]; then
  fixture="3001/tcp 3002/tcp 22/tcp"
  match() { local p="$1"; echo "$fixture" | grep -qE "(^| )${p}( |$)"; }
  match "3001/tcp" && match "3002/tcp" || { echo "self-test FAIL: real-port match returned false negative"; exit 1; }
  if match "9999/tcp"; then
    echo "self-test FAIL: fake-port matched the fixture -- probe regex is too loose"
    exit 1
  fi
  echo "self-test PASS: probe correctly accepts 3001/3002 and rejects 9999"
  exit 0
fi

REGION="us-east-1"
REQUIRED_PORTS=(3001/tcp 3002/tcp)
fail=0

# Discover all running fjcloud-api-* instances across envs.
INSTANCES=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=fjcloud-api-*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value]' \
  --output text --region "$REGION")

if [[ -z "$INSTANCES" ]]; then
  echo "FAIL: no running fjcloud-api-* instances found"
  exit 1
fi

while IFS=$'\t' read -r instance_id name; do
  [[ -z "$instance_id" ]] && continue
  echo "==Probing $name ($instance_id)..."
  cmd_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name AWS-RunShellScript \
    --region "$REGION" \
    --parameters 'commands=["sudo firewall-cmd --list-ports"]' \
    --query Command.CommandId --output text)
  for _ in $(seq 1 20); do
    status=$(aws ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance_id" --region "$REGION" \
      --query Status --output text 2>/dev/null || echo "Pending")
    [[ "$status" == "Success" ]] && break
    [[ "$status" =~ ^(Failed|Cancelled|TimedOut)$ ]] && { echo "FAIL: SSM cmd $cmd_id $status"; fail=1; continue 2; }
    sleep 2
  done
  open_ports=$(aws ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" --region "$REGION" \
    --query StandardOutputContent --output text)
  for port in "${REQUIRED_PORTS[@]}"; do
    if echo "$open_ports" | grep -qE "(^| )${port}( |$)"; then
      echo "  PASS: $name has $port open"
    else
      echo "  FAIL: $name missing $port (firewall-cmd --list-ports: $open_ports)"
      echo "        Remediate: aws ssm send-command --instance-ids $instance_id --document-name AWS-RunShellScript --parameters 'commands=[\"sudo firewall-cmd --permanent --add-port=$port && sudo firewall-cmd --reload\"]'"
      fail=1
    fi
  done
done <<< "$INSTANCES"

exit $fail
