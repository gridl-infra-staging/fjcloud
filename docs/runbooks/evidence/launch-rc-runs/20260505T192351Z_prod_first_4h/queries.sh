#!/usr/bin/env bash
# queries.sh — single 30-minute monitoring tick for the launch-window first-4h
# bundle. Reuses the checked-in owner seams identified in the Stage 6 checklist.
#
# Owners reused (do not invent parallel paths):
#   docs/checklists/PAID_BETA_LAUNCH_CHECKLIST.md  — cadence
#   docs/runbooks/launch-backend.md                — runtime commands
#   scripts/launch/ssm_exec_staging.sh             — staging-host exec seam
#   scripts/canary/customer_loop_synthetic.sh      — recurring customer-loop probe
#   scripts/lib/metering_checks.sh::check_rollup_current — DB rollup freshness
#   scripts/validate-metering.sh                   — metering pipeline JSON
#   scripts/probe_alert_delivery.sh                — page-path probe
#   infra/api/src/routes/admin/webhook_events.rs::get_webhook_event — Stripe persistence inspection
#
# Each invocation appends one JSONL record to poll.jsonl with pass/fail per
# check. Critical-fail checks also append to pages.jsonl. Stage 7 reads those.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../../.." && pwd)"
BUNDLE_DIR="$SCRIPT_DIR"
POLL_FILE="$BUNDLE_DIR/poll.jsonl"
PAGES_FILE="$BUNDLE_DIR/pages.jsonl"
TICK_LOG="$BUNDLE_DIR/tick.log"

cd "$REPO_ROOT"

TICK_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TICK_NONCE="$$-$RANDOM"

json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

record_check() {
  # name, passed (true|false), detail
  local name="$1" passed="$2" detail="$3"
  local d
  d="$(printf '%s' "$detail" | json_escape)"
  printf '{"ts":"%s","tick":"%s","check":"%s","passed":%s,"detail":%s}\n' \
    "$TICK_TS" "$TICK_NONCE" "$name" "$passed" "$d" >>"$POLL_FILE"
  if [ "$passed" != "true" ]; then
    printf '{"ts":"%s","tick":"%s","check":"%s","detail":%s}\n' \
      "$TICK_TS" "$TICK_NONCE" "$name" "$d" >>"$PAGES_FILE"
  fi
}

run_check() {
  # name, command...
  local name="$1"; shift
  local out rc
  out="$( ("$@") 2>&1 )"; rc=$?
  if [ $rc -eq 0 ]; then
    record_check "$name" true "rc=0 $(printf '%s' "$out" | head -c 400)"
  else
    record_check "$name" false "rc=$rc $(printf '%s' "$out" | head -c 600)"
  fi
}

{
  echo "==== TICK $TICK_TS ($TICK_NONCE) ===="

  # 1. CloudWatch alarm state — paid-beta checklist owner
  run_check cloudwatch_alarms bash -c '
    aws cloudwatch describe-alarms \
      --region us-east-1 \
      --state-value ALARM \
      --query "MetricAlarms[?starts_with(AlarmName, \`fjcloud\`) || starts_with(AlarmName, \`fj-\`)].AlarmName" \
      --output text | tr -s "[:space:]" " " | sed "s/^ //;s/ $//" \
      | (read -r names; if [ -z "$names" ]; then echo "no fjcloud alarms in ALARM state"; exit 0; else echo "ALARM: $names"; exit 1; fi)
  '

  # 2. API error scan on staging host (launch-backend.md Step 4 owner)
  run_check api_errors_30m bash -c '
    bash scripts/launch/ssm_exec_staging.sh \
      "sudo journalctl -u fjcloud-api --since '"'"'30 minutes ago'"'"' | grep -E '"'"'\"level\":\"ERROR\"|\"level\":\"WARN\"'"'"' | grep -v request_logging | wc -l" \
      | (read -r n; n="${n:-0}"; if [ "$n" -lt 10 ]; then echo "errors=$n (<10)"; exit 0; else echo "errors=$n (>=10) — investigate"; exit 1; fi)
  '

  # 3. Metering agent error scan on staging host
  run_check metering_errors_30m bash -c '
    bash scripts/launch/ssm_exec_staging.sh \
      "sudo journalctl -u fj-metering-agent --since '"'"'30 minutes ago'"'"' 2>/dev/null | grep -E '"'"'\"level\":\"ERROR\"'"'"' | wc -l" \
      | (read -r n; n="${n:-0}"; if [ "$n" -lt 5 ]; then echo "errors=$n (<5)"; exit 0; else echo "errors=$n (>=5) — investigate"; exit 1; fi)
  '

  # 4. Rollup freshness — matches scripts/lib/metering_checks.sh::check_rollup_current
  #    contract (column `aggregated_at`, owner uses 48h window). DATABASE_URL is
  #    sourced from the staging API systemd EnvironmentFile.
  run_check rollup_current bash "$BUNDLE_DIR/probe_rollup.sh"

  # 5. Customer-loop canary — default mode (NOT --live; live runs are charge-creating)
  run_check customer_loop_canary bash -c '
    bash scripts/canary/customer_loop_synthetic.sh 2>&1 | tail -1
  '

  # 6. Page-path liveness — direct webhook reachability (no fjcloud-api dep)
  run_check page_path_reachable bash -c '
    DISCORD_WEBHOOK_URL="$(aws ssm get-parameter --name /fjcloud/staging/discord_webhook_url --with-decryption --region us-east-1 --query Parameter.Value --output text 2>/dev/null)" \
    ENVIRONMENT=staging \
    bash scripts/probe_alert_delivery.sh 2>&1 | tail -1
  '

  echo "==== END TICK $TICK_TS ===="
} >>"$TICK_LOG" 2>&1
