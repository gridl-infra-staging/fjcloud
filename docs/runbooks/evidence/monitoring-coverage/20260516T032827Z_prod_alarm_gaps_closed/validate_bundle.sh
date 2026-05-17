#!/usr/bin/env bash
set -euo pipefail

bundle_dir="$(cd "$(dirname "$0")" && pwd)"

required_alarms=(
  "fjcloud-prod-api-root-disk-high"
  "fjcloud-prod-rds-connections-high"
  "fjcloud-prod-alb-unhealthy-hosts"
  "fjcloud-prod-customer-loop-canary-lambda-errors"
)

artifacts=(
  "$bundle_dir/alarms_describe.json"
  "$bundle_dir/alarms_describe_table.txt"
  "$bundle_dir/tf_stage2_alarm_plan.log"
  "$bundle_dir/sns_probe_transcript.txt"
)

missing=0
for alarm_name in "${required_alarms[@]}"; do
  if ! grep -F -R -- "$alarm_name" "${artifacts[@]}" >/dev/null 2>&1; then
    echo "MISSING_ALARM: $alarm_name"
    missing=1
  fi
done

if [[ $missing -ne 0 ]]; then
  echo "VALIDATION: FAIL"
  exit 1
fi

echo "VALIDATION: PASS"
