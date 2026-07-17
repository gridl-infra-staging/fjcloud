#!/usr/bin/env bash
# probe_canary_live_state.sh — answer "is the env's canary infrastructure
# healthy right now?" from live AWS state.
#
# Why this exists: the canonical bundle pointer at
# `docs/runbooks/evidence/canary-customer-loop/.current_bundle` was being
# read as a launch-readiness signal, but bundle capture is event-triggered
# (intentional snapshots after a wave merges or a deploy lands), not
# continuous. An aging .current_bundle does NOT mean the canary stopped —
# the canaries run every 15 minutes via EventBridge, observable in
# CloudWatch.
#
# Scope: the env has two canaries (customer-loop and support-email). This
# probe applies deep per-function checks to the **customer-loop** canary
# (the high-signal end-to-end customer-flow probe) and a broad alarm-
# rollup check that picks up **all** env-scoped canary alarms — so a
# support-email-canary alarm in ALARM state also fails this probe. That
# matches B1's gating intent: both canaries are launch-sentence-relevant
# (customer-loop = signup→search; support-email = receive support email).
#
# Per-check scope summary:
#   1. schedule_state    — customer-loop EventBridge rule only
#   2. invocations_24h   — customer-loop Lambda function only
#   3. errors_24h        — customer-loop Lambda function only
#   4. alarms            — ALL env-scoped canary alarms (customer-loop AND
#                          support-email; non-OK on any of them is a fail)
#   5. last_invocation   — customer-loop Lambda log group only
#
# Usage: probe_canary_live_state.sh <env> [--json]
#   env: staging | prod
#   --json: emit machine-readable JSON to stdout (B1 pre-flight uses this)
#           Default mode emits a human-readable summary.
#
# Exit codes:
#   0 — every check passed (canaries are healthy now)
#   1 — one or more checks failed (canaries are degraded or stopped)
#   2 — usage error or AWS auth failure

set -euo pipefail

# ============================================================
# Argument parsing.
# ============================================================
ENV_ARG=""
EMIT_JSON=0
for arg in "$@"; do
    case "$arg" in
        --json) EMIT_JSON=1 ;;
        --help|-h)
            sed -n '4,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        --*) echo "Usage error: unknown flag $arg" >&2; exit 2 ;;
        *)
            if [ -z "$ENV_ARG" ]; then
                ENV_ARG="$arg"
            else
                echo "Usage error: too many positional args" >&2; exit 2
            fi
            ;;
    esac
done

if [ -z "$ENV_ARG" ]; then
    echo "Usage: $(basename "$0") <env> [--json]   (env: staging | prod)" >&2
    exit 2
fi

case "$ENV_ARG" in
    staging|prod) ;;
    *) echo "Usage error: env must be 'staging' or 'prod' (got: $ENV_ARG)" >&2; exit 2 ;;
esac

REGION="${AWS_REGION:-us-east-1}"
RULE_NAME="fjcloud-${ENV_ARG}-customer-loop-canary"
FUNC_NAME="fjcloud-${ENV_ARG}-customer-loop-canary"

# Pass interpolated values to embedded python via env vars so the heredocs
# can use single-quoted <<'PY' and avoid bash interpolation/quoting bugs.
export PROBE_ENV_ARG="$ENV_ARG"
export PROBE_RULE_NAME="$RULE_NAME"

# ============================================================
# Time window: last 24 hours. Computed once, reused for both metric calls so
# the window is consistent (otherwise Invocations and Errors could land on
# slightly different period boundaries).
# ============================================================
# `date -u -v-1d` is BSD/macOS; `date -u -d '1 day ago'` is GNU/Linux.
START_TIME="$(date -u -v-1d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 day ago' +%Y-%m-%dT%H:%M:%SZ)"
END_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ============================================================
# Per-check state. Parallel arrays keep ordering and bash 3.x compatibility
# (macOS default bash is 3.2; assoc-arrays are 4+).
# ============================================================
CHECK_NAMES=()
CHECK_STATUSES=()
CHECK_DETAILS=()
OVERALL_FAIL=0

record_check() {
    local name="$1" status="$2" detail="$3"
    CHECK_NAMES+=("$name")
    CHECK_STATUSES+=("$status")
    CHECK_DETAILS+=("$detail")
    if [ "$status" != "pass" ]; then OVERALL_FAIL=1; fi
}

# ============================================================
# Pre-flight: AWS auth check. Fail fast with exit 2 if we can't authenticate
# at all — the rest of the probe's results would be misleading.
# ============================================================
if ! aws sts get-caller-identity --output json --region "$REGION" >/dev/null 2>&1; then
    echo "Usage error: AWS authentication failed (sts get-caller-identity)" >&2
    exit 2
fi

# ============================================================
# Check 1 — EventBridge rule state. Must be ENABLED. If the rule was
# disabled (terraform drift, manual operator pause, accidental apply), the
# canary stops running silently — this is exactly what happened in the
# 2026-05-17 fleet rot incident.
# ============================================================
rules_json="$(aws events list-rules --region "$REGION" --name-prefix "$RULE_NAME" --output json 2>/dev/null || echo '{}')"
# Embedded python reads the JSON payload via env var (RULES_JSON) instead of
# stdin — heredocs redirect stdin to themselves, so the upstream `aws | python`
# pipe pattern silently feeds python an empty stdin. Env-var inputs sidestep
# that whole class of bug.
schedule_state="$(RULES_JSON="$rules_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("RULES_JSON") or "{}")
rule_name = os.environ["PROBE_RULE_NAME"]
rules = data.get("Rules", [])
match = next((r for r in rules if r.get("Name") == rule_name), None)
print(match["State"] if match else "MISSING")
PY
)"
if [ "$schedule_state" = "ENABLED" ]; then
    record_check "schedule_state" "pass" "EventBridge rule $RULE_NAME ENABLED"
else
    record_check "schedule_state" "fail" "EventBridge rule $RULE_NAME state=$schedule_state (expected ENABLED)"
fi

# ============================================================
# Check 2 — Lambda Invocations sum over last 24h. At rate(15 minutes) the
# expected count is ~96. We accept anything > 0 as "running" — if it's
# wildly low (say 5/96) that's a different signal (Lambda errors are caught
# in check 3, throttling shows up there too). Zero invocations means the
# canary literally didn't fire; EventBridge rule may be ENABLED but the
# target wiring or IAM permission is broken.
# ============================================================
inv_json="$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Invocations \
    --dimensions "Name=FunctionName,Value=$FUNC_NAME" \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --period 86400 --statistics Sum --region "$REGION" --output json 2>/dev/null || echo '{}')"
inv_sum="$(INV_JSON="$inv_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("INV_JSON") or "{}")
points = data.get("Datapoints", [])
print(sum(p.get("Sum", 0) for p in points) if points else 0)
PY
)"
# Floating-point safe comparison via python (bash arithmetic is integer-only;
# Sum is a float in the CloudWatch JSON).
if python3 -c "import sys; sys.exit(0 if float('$inv_sum') > 0 else 1)" 2>/dev/null; then
    record_check "invocations_24h" "pass" "Invocations sum 24h = $inv_sum (canary firing)"
else
    record_check "invocations_24h" "fail" "Invocations sum 24h = $inv_sum (canary appears not running)"
fi

# ============================================================
# Check 3 — Lambda Errors sum over last 24h. Zero is required. Any non-zero
# means the canary's process exited with a Lambda-level error (uncaught
# exception, exit code, timeout) — these are surface-level failures that
# would page via the lambda-errors alarm anyway, but probing here catches
# the case where someone silenced the alarm without fixing the underlying
# problem.
# ============================================================
err_json="$(aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda --metric-name Errors \
    --dimensions "Name=FunctionName,Value=$FUNC_NAME" \
    --start-time "$START_TIME" --end-time "$END_TIME" \
    --period 86400 --statistics Sum --region "$REGION" --output json 2>/dev/null || echo '{}')"
err_sum="$(ERR_JSON="$err_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("ERR_JSON") or "{}")
points = data.get("Datapoints", [])
print(sum(p.get("Sum", 0) for p in points) if points else 0)
PY
)"
if [ "$(python3 -c "print(float('$err_sum'))")" = "0.0" ]; then
    record_check "errors_24h" "pass" "Errors sum 24h = 0"
else
    record_check "errors_24h" "fail" "Errors sum 24h = $err_sum (canary throwing)"
fi

# ============================================================
# Check 4 — Any canary-related CloudWatch alarm in ALARM state. Probes all
# alarms whose name contains "canary" AND the current env (so unrelated
# infra alarms or cross-env alarms don't get mixed in); picks up both the
# lambda-errors alarm and the not-running liveness alarm (added 2026-05-20
# after the fleet-rot incident proved Errors-only alarming is blind to a
# stopped canary).
# ============================================================
alarms_json="$(aws cloudwatch describe-alarms --region "$REGION" --output json 2>/dev/null || echo '{}')"
non_ok_alarms="$(ALARMS_JSON="$alarms_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("ALARMS_JSON") or "{}")
env_arg = os.environ["PROBE_ENV_ARG"]
non_ok = []
for a in data.get("MetricAlarms", []):
    name = a.get("AlarmName", "")
    # Scope: only consider alarms tagged to this env AND containing "canary".
    if env_arg in name and "canary" in name:
        state = a.get("StateValue", "UNKNOWN")
        if state != "OK":
            non_ok.append(f"{name}={state}")
print(";".join(non_ok))
PY
)"
if [ -z "$non_ok_alarms" ]; then
    record_check "alarms" "pass" "all canary alarms OK"
else
    record_check "alarms" "fail" "non-OK alarms: $non_ok_alarms"
fi

# ============================================================
# Check 5 — Most recent COMPLETED invocation logged the canary's
# end-of-run success marker. This catches the case where Lambda's
# Errors metric is 0 (the process exited cleanly with code 0) but
# the canary's app-layer assertions all silently no-op'd. The
# success marker comes from infra/api code path in
# scripts/canary/customer_loop_synthetic.sh — search for "completed
# successfully" in that script if this assertion needs updating.
#
# Scans the last 2 log streams (each = one Lambda invocation) and
# passes if EITHER contains both an END marker (run completed) and
# the success marker. Looking at two streams covers the case where
# the probe fires mid-invocation: the latest stream lacks END (run
# in progress) but the prior stream completed successfully.
# ============================================================
streams_json="$(aws logs describe-log-streams \
    --log-group-name "/aws/lambda/$FUNC_NAME" \
    --order-by LastEventTime --descending --limit 2 \
    --region "$REGION" --output json 2>/dev/null || echo '{}')"
stream_names="$(STREAMS_JSON="$streams_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("STREAMS_JSON") or "{}")
streams = data.get("logStreams", [])
for s in streams:
    print(s.get("logStreamName", ""))
PY
)"
if [ -z "$stream_names" ]; then
    record_check "last_invocation" "fail" "no recent log streams found"
else
    success_in_completed_run="no"
    while IFS= read -r stream_name; do
        [ -z "$stream_name" ] && continue
        logs_json="$(aws logs get-log-events \
            --log-group-name "/aws/lambda/$FUNC_NAME" \
            --log-stream-name "$stream_name" --limit 100 \
            --region "$REGION" --output json 2>/dev/null || echo '{}')"
        result="$(LOGS_JSON="$logs_json" python3 <<'PY'
import json, os
data = json.loads(os.environ.get("LOGS_JSON") or "{}")
msgs = [e.get("message", "") for e in data.get("events", [])]
ended = any(m.startswith("END RequestId:") for m in msgs)
success = any("completed successfully" in m for m in msgs)
if ended and success:
    print("ok")
elif ended and not success:
    print("ended_no_success")
else:
    print("in_progress")
PY
)"
        if [ "$result" = "ok" ]; then
            success_in_completed_run="yes"
            break
        elif [ "$result" = "ended_no_success" ]; then
            success_in_completed_run="ended_no_success"
            break
        fi
    done <<< "$stream_names"
    if [ "$success_in_completed_run" = "yes" ]; then
        record_check "last_invocation" "pass" "last completed invocation logged success marker"
    elif [ "$success_in_completed_run" = "ended_no_success" ]; then
        record_check "last_invocation" "fail" "last completed invocation missing 'completed successfully' marker"
    else
        record_check "last_invocation" "fail" "no completed invocation found in last 2 streams"
    fi
fi

# ============================================================
# Emit output in the requested format.
# ============================================================
if [ "$EMIT_JSON" = "1" ]; then
    # Single-shot python build of the JSON so the structure is unambiguous.
    # Pass the parallel arrays via env vars (newline-separated) to keep the
    # bash-to-python handoff simple.
    NAMES_NL="$(printf '%s\n' "${CHECK_NAMES[@]}")"
    STATUSES_NL="$(printf '%s\n' "${CHECK_STATUSES[@]}")"
    DETAILS_NL="$(printf '%s\n' "${CHECK_DETAILS[@]}")"
    READY_VAL="true"; if [ "$OVERALL_FAIL" = "1" ]; then READY_VAL="false"; fi
    NAMES_NL="$NAMES_NL" STATUSES_NL="$STATUSES_NL" DETAILS_NL="$DETAILS_NL" \
        READY_VAL="$READY_VAL" ENV_ARG="$ENV_ARG" \
        python3 <<'PY'
import json, os
env = os.environ["ENV_ARG"]
names = os.environ["NAMES_NL"].splitlines()
statuses = os.environ["STATUSES_NL"].splitlines()
details = os.environ["DETAILS_NL"].splitlines()
ready = os.environ["READY_VAL"] == "true"
checks = {n: {"status": s, "detail": d} for n, s, d in zip(names, statuses, details)}
print(json.dumps({"env": env, "ready": ready, "checks": checks}, indent=2))
PY
else
    # Human-readable: one line per check, then a one-line overall verdict.
    echo "Canary live-state for env=$ENV_ARG (function=$FUNC_NAME)"
    for i in "${!CHECK_NAMES[@]}"; do
        marker="PASS"
        if [ "${CHECK_STATUSES[$i]}" != "pass" ]; then marker="FAIL"; fi
        echo "  [$marker] ${CHECK_NAMES[$i]}: ${CHECK_DETAILS[$i]}"
    done
    if [ "$OVERALL_FAIL" = "0" ]; then
        echo "VERDICT: canary GREEN"
    else
        echo "VERDICT: canary DEGRADED"
    fi
fi

exit "$OVERALL_FAIL"
