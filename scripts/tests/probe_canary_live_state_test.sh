#!/usr/bin/env bash
# Tests for scripts/probe_canary_live_state.sh
#
# The probe answers "is the customer-loop canary actually healthy right now?"
# via direct CloudWatch / EventBridge / Lambda-logs queries. This test stubs
# `aws` and `jq` is real. Each test installs a stub-aws that emits fixture
# output for the AWS sub-command requested.
#
# Why this matters: `docs/runbooks/evidence/canary-customer-loop/.current_bundle`
# is a snapshot pointer that ages — bundle capture is event-triggered, not
# continuous, so an old pointer is NOT a "canary stopped" signal. The
# canonical live-state answer lives in CloudWatch. This probe replaces the
# misleading "is the bundle fresh?" check with a real "is the canary
# succeeding right now?" check.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_canary_live_state.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

# Common stub-aws builder. Each test calls this with an associative-style env
# mapping AWS sub-command-shape → fixture-output path. The stub matches on a
# few load-bearing args ("describe-alarms", "get-metric-statistics + Errors",
# "events list-rules", etc.) and emits the matching fixture.
make_stub_aws() {
    local bin_dir="$1"
    cat > "$bin_dir/aws" <<'STUB'
#!/usr/bin/env bash
# Stub aws CLI. Looks up which sub-command was invoked and emits the
# fixture content the test's FIXTURE_DIR points at.
set -euo pipefail
: "${FIXTURE_DIR:?FIXTURE_DIR required for stub aws}"
all_args="$*"

# get-caller-identity is the auth probe; succeed by default.
if [[ "$all_args" == *"sts get-caller-identity"* ]]; then
    echo '{"Account":"213880904778","Arn":"arn:aws:iam::213880904778:user/stub","UserId":"STUB"}'
    exit 0
fi

# events list-rules → schedule state for the canary EventBridge rule(s).
if [[ "$all_args" == *"events list-rules"* ]]; then
    cat "$FIXTURE_DIR/events_list_rules.json"
    exit 0
fi

# cloudwatch describe-alarms → alarms with "canary" in the name.
if [[ "$all_args" == *"cloudwatch describe-alarms"* ]]; then
    cat "$FIXTURE_DIR/describe_alarms.json"
    exit 0
fi

# cloudwatch get-metric-statistics: distinguish Invocations from Errors
# by inspecting --metric-name.
if [[ "$all_args" == *"cloudwatch get-metric-statistics"* ]]; then
    if [[ "$all_args" == *"--metric-name Invocations"* ]]; then
        cat "$FIXTURE_DIR/metric_invocations.json"
        exit 0
    fi
    if [[ "$all_args" == *"--metric-name Errors"* ]]; then
        cat "$FIXTURE_DIR/metric_errors.json"
        exit 0
    fi
fi

# logs describe-log-streams → most-recent stream
if [[ "$all_args" == *"logs describe-log-streams"* ]]; then
    cat "$FIXTURE_DIR/describe_log_streams.json"
    exit 0
fi

# logs get-log-events → per-stream log content. Pick the fixture for the
# requested stream name when present (get_log_events__<stream-suffix>.json),
# else fall back to get_log_events.json. The suffix is the last hex-ish path
# segment of the stream name to keep filename math simple.
if [[ "$all_args" == *"logs get-log-events"* ]]; then
    stream_name=""
    next_is_stream=0
    for arg in "$@"; do
        if [ "$next_is_stream" -eq 1 ]; then
            stream_name="$arg"
            break
        fi
        if [ "$arg" = "--log-stream-name" ]; then
            next_is_stream=1
        fi
    done
    stream_key="${stream_name##*/}"
    stream_key="${stream_key//\[\$LATEST\]/}"
    per_stream_fixture="$FIXTURE_DIR/get_log_events__${stream_key}.json"
    if [ -f "$per_stream_fixture" ]; then
        cat "$per_stream_fixture"
    else
        cat "$FIXTURE_DIR/get_log_events.json"
    fi
    exit 0
fi

echo "stub aws: unhandled args: $all_args" >&2
exit 99
STUB
    chmod +x "$bin_dir/aws"
}

# Helper to write the GREEN fixture set into FIXTURE_DIR. Individual tests
# override specific files to simulate red conditions.
write_green_fixtures() {
    local dir="$1"
    cat > "$dir/events_list_rules.json" <<'JSON'
{"Rules":[{"Name":"fjcloud-prod-customer-loop-canary","State":"ENABLED","ScheduleExpression":"rate(15 minutes)"}]}
JSON
    cat > "$dir/describe_alarms.json" <<'JSON'
{"MetricAlarms":[
  {"AlarmName":"fjcloud-prod-customer-loop-canary-lambda-errors","StateValue":"OK","StateReason":"under threshold"},
  {"AlarmName":"fjcloud-prod-customer-loop-canary-not-running","StateValue":"OK","StateReason":"invocations within threshold"}
]}
JSON
    # 96 invocations over 24h = exactly 4/hr (rate(15 minutes)).
    cat > "$dir/metric_invocations.json" <<'JSON'
{"Datapoints":[{"Timestamp":"2026-05-27T13:07:00Z","Sum":96.0,"Unit":"Count"}],"Label":"Invocations"}
JSON
    cat > "$dir/metric_errors.json" <<'JSON'
{"Datapoints":[{"Timestamp":"2026-05-27T13:07:00Z","Sum":0.0,"Unit":"Count"}],"Label":"Errors"}
JSON
    cat > "$dir/describe_log_streams.json" <<'JSON'
{"logStreams":[{"logStreamName":"2026/05/27/[$LATEST]abc123","lastEventTimestamp":1748358420000}]}
JSON
    cat > "$dir/get_log_events.json" <<'JSON'
{"events":[
  {"timestamp":1748358420000,"message":"\t[customer-loop-canary] signup succeeded\n"},
  {"timestamp":1748358421000,"message":"\t[customer-loop-canary] index search succeeded\n"},
  {"timestamp":1748358422000,"message":"\t[customer-loop-canary] customer loop canary completed successfully\n"},
  {"timestamp":1748358423000,"message":"END RequestId: 89edc50e-a33f-4346-9d09-49fb3301f5e7\n"}
]}
JSON
}

# Run the probe with the stub aws on PATH and the green fixtures, then
# capture stdout/stderr/exit-code for assertions.
run_probe() {
    local env_arg="$1" extra_flags="${2:-}"
    local tmpdir bin_dir fixture_dir
    tmpdir="$(mktemp -d)"
    bin_dir="$tmpdir/bin"
    fixture_dir="$tmpdir/fixtures"
    mkdir -p "$bin_dir" "$fixture_dir"
    make_stub_aws "$bin_dir"
    write_green_fixtures "$fixture_dir"
    # Per-test override hook: callers may write extra fixture files after this
    # function returns by exporting FIXTURE_DIR_OVERRIDE before calling.
    if [ -n "${FIXTURE_DIR_OVERRIDE:-}" ]; then
        cp -r "$FIXTURE_DIR_OVERRIDE"/* "$fixture_dir/"
    fi
    LAST_TMPDIR="$tmpdir"
    LAST_FIXTURE_DIR="$fixture_dir"
    RUN_STDOUT="$(FIXTURE_DIR="$fixture_dir" PATH="$bin_dir:$PATH" \
        bash "$PROBE_SCRIPT" "$env_arg" $extra_flags 2>"$tmpdir/stderr" )" || RUN_EXIT_CODE=$?
    RUN_EXIT_CODE="${RUN_EXIT_CODE:-0}"
    RUN_STDERR="$(cat "$tmpdir/stderr")"
}

# ============================================================
# Test 1 — Usage error on missing env arg.
# ============================================================
test_usage_error_on_missing_env() {
    set +e
    RUN_STDOUT="$(bash "$PROBE_SCRIPT" 2>&1)"
    local code=$?
    set -e
    assert_eq "$code" "2" "missing env arg should exit 2"
    assert_contains "$RUN_STDOUT" "Usage" "missing env should print Usage"
}

# ============================================================
# Test 2 — Usage error on invalid env value.
# ============================================================
test_usage_error_on_invalid_env() {
    set +e
    RUN_STDOUT="$(bash "$PROBE_SCRIPT" production 2>&1)"
    local code=$?
    set -e
    assert_eq "$code" "2" "invalid env should exit 2"
    assert_contains "$RUN_STDOUT" "staging" "invalid env should suggest valid choices"
}

# ============================================================
# Test 3 — All-green path exits 0 and reports each check passing.
# ============================================================
test_green_path_exits_0_with_pass_lines() {
    RUN_EXIT_CODE=0
    run_probe "prod"
    assert_eq "$RUN_EXIT_CODE" "0" "all-green should exit 0"
    assert_contains "$RUN_STDOUT" "schedule_state" "summary should name schedule_state check"
    assert_contains "$RUN_STDOUT" "invocations_24h" "summary should name invocations_24h check"
    assert_contains "$RUN_STDOUT" "errors_24h" "summary should name errors_24h check"
    assert_contains "$RUN_STDOUT" "alarms" "summary should name alarms check"
    assert_contains "$RUN_STDOUT" "last_invocation" "summary should name last_invocation check"
    # Pass markers per row.
    assert_contains "$RUN_STDOUT" "PASS" "green path should print PASS markers"
    assert_not_contains "$RUN_STDOUT" "FAIL" "green path must not print FAIL markers"
}

# ============================================================
# Test 4 — EventBridge schedule DISABLED must FAIL.
# ============================================================
test_disabled_schedule_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/events_list_rules.json" <<'JSON'
{"Rules":[{"Name":"fjcloud-prod-customer-loop-canary","State":"DISABLED","ScheduleExpression":"rate(15 minutes)"}]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "disabled schedule should exit 1"
    assert_contains "$RUN_STDOUT" "schedule_state" "summary should still name schedule_state"
    assert_contains "$RUN_STDOUT" "DISABLED" "failure should surface DISABLED literal"
}

# ============================================================
# Test 5 — Non-zero Errors metric must FAIL.
# ============================================================
test_nonzero_errors_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/metric_errors.json" <<'JSON'
{"Datapoints":[{"Timestamp":"2026-05-27T13:07:00Z","Sum":3.0,"Unit":"Count"}],"Label":"Errors"}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "non-zero errors should exit 1"
    assert_contains "$RUN_STDOUT" "errors_24h" "summary should name errors_24h"
    # We don't pin exact format, but the count must surface for triage.
    assert_contains "$RUN_STDOUT" "3" "failure should surface the error count"
}

# ============================================================
# Test 6 — Zero Invocations means canary stopped running.
# ============================================================
test_zero_invocations_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/metric_invocations.json" <<'JSON'
{"Datapoints":[],"Label":"Invocations"}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "zero invocations should exit 1"
    assert_contains "$RUN_STDOUT" "invocations_24h" "summary should name invocations_24h"
}

# ============================================================
# Test 7 — Any alarm in ALARM state must FAIL.
# ============================================================
test_alarm_state_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/describe_alarms.json" <<'JSON'
{"MetricAlarms":[
  {"AlarmName":"fjcloud-prod-customer-loop-canary-lambda-errors","StateValue":"ALARM","StateReason":"errors above threshold"},
  {"AlarmName":"fjcloud-prod-customer-loop-canary-not-running","StateValue":"OK","StateReason":"OK"}
]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "alarm-state alarm should exit 1"
    assert_contains "$RUN_STDOUT" "fjcloud-prod-customer-loop-canary-lambda-errors" "failed alarm name should surface"
}

# ============================================================
# Test 8 — Last log without "completed successfully" must FAIL.
# Catches the case where Lambda is running but the canary's app-layer
# assertion path is silently broken (no exit-1, just no success marker).
# ============================================================
test_missing_success_marker_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/get_log_events.json" <<'JSON'
{"events":[
  {"timestamp":1748358420000,"message":"\t[customer-loop-canary] signup succeeded\n"},
  {"timestamp":1748358421000,"message":"\t[customer-loop-canary] index create failed: 503\n"},
  {"timestamp":1748358422000,"message":"END RequestId: 89edc50e-a33f-4346-9d09-49fb3301f5e7\n"}
]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "missing success marker should exit 1"
    assert_contains "$RUN_STDOUT" "last_invocation" "summary should name last_invocation"
}

# ============================================================
# Test 9 — --json flag emits machine-readable JSON the B1 pre-flight can parse.
# ============================================================
test_json_mode_emits_valid_json() {
    RUN_EXIT_CODE=0
    run_probe "prod" "--json"
    assert_eq "$RUN_EXIT_CODE" "0" "json mode green should exit 0"
    # python jq-equivalent: confirm 5 checks present and ready=true
    if ! python3 - "$RUN_STDOUT" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("env") == "prod", "env missing or wrong"
assert obj.get("ready") is True, "ready != true on green path"
checks = obj.get("checks", {})
for required in ("schedule_state", "invocations_24h", "errors_24h", "alarms", "last_invocation"):
    assert required in checks, f"missing check {required}"
    assert checks[required]["status"] == "pass", f"{required} not pass: {checks[required]}"
PY
    then
        fail "json output failed schema check"
    else
        pass "json output has required schema"
    fi
}

# ============================================================
# Test 10 — --json mode on red path emits ready=false plus per-check detail.
# ============================================================
test_json_mode_red_path_emits_ready_false() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/metric_errors.json" <<'JSON'
{"Datapoints":[{"Timestamp":"2026-05-27T13:07:00Z","Sum":2.0,"Unit":"Count"}],"Label":"Errors"}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod" "--json"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "json mode red should exit 1"
    if ! python3 - "$RUN_STDOUT" <<'PY'
import json, sys
obj = json.loads(sys.argv[1])
assert obj.get("ready") is False, f"ready expected false, got {obj.get('ready')}"
assert obj["checks"]["errors_24h"]["status"] == "fail", "errors_24h should be fail"
assert obj["checks"]["schedule_state"]["status"] == "pass", "schedule_state should be pass"
PY
    then
        fail "json red output failed schema check"
    else
        pass "json red output has correct shape"
    fi
}

# ============================================================
# Test 11 — support-email-canary alarm in ALARM state also fails the probe.
# This is the documented broad-alarm-scope behavior: per the probe's header,
# alarm check 4 rolls up ALL env-scoped canary alarms, not just customer-loop.
# That's the intentional B1-gating posture because the launch sentence
# includes "receive support email", so a support-email canary failure is
# also launch-blocking. Anchored 2026-05-27 after self-audit caught the
# implicit-scope gap.
# ============================================================
test_support_email_alarm_fails_too() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/describe_alarms.json" <<'JSON'
{"MetricAlarms":[
  {"AlarmName":"fjcloud-prod-customer-loop-canary-lambda-errors","StateValue":"OK","StateReason":"OK"},
  {"AlarmName":"fjcloud-prod-customer-loop-canary-not-running","StateValue":"OK","StateReason":"OK"},
  {"AlarmName":"fjcloud-prod-support-email-canary-not-running","StateValue":"ALARM","StateReason":"no invocations in window"}
]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "support-email canary alarm in ALARM state must also fail the probe"
    assert_contains "$RUN_STDOUT" "support-email-canary" "failure should name the failing support-email alarm"
}

# ============================================================
# Test 12 — Probe fires mid-invocation: latest stream has START but no END
# (canary still running). Fix: probe falls back to prior completed stream
# and passes if THAT one logged success. Without this, the probe produces
# a ~2.4% false-negative window (probe runtime ~22s, schedule rate 15min).
# Anchored 2026-05-27 after second-self-audit caught the false-negative.
# ============================================================
test_mid_invocation_falls_back_to_prior_stream() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/describe_log_streams.json" <<'JSON'
{"logStreams":[
  {"logStreamName":"2026/05/28/[$LATEST]inprogress789","lastEventTimestamp":1748359999000},
  {"logStreamName":"2026/05/28/[$LATEST]prior456","lastEventTimestamp":1748358423000}
]}
JSON
    cat > "$fix_override/get_log_events__inprogress789.json" <<'JSON'
{"events":[
  {"timestamp":1748359998000,"message":"START RequestId: 99edc50e-... Version: $LATEST\n"},
  {"timestamp":1748359999000,"message":"\t[customer-loop-canary] signup succeeded\n"}
]}
JSON
    cat > "$fix_override/get_log_events__prior456.json" <<'JSON'
{"events":[
  {"timestamp":1748358420000,"message":"\t[customer-loop-canary] signup succeeded\n"},
  {"timestamp":1748358422000,"message":"\t[customer-loop-canary] customer loop canary completed successfully\n"},
  {"timestamp":1748358423000,"message":"END RequestId: 89edc50e-a33f-4346-9d09-49fb3301f5e7\n"}
]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "0" "mid-invocation probe should pass via fallback to prior completed stream"
    assert_contains "$RUN_STDOUT" "PASS] last_invocation" "last_invocation should be PASS via fallback"
}

# ============================================================
# Test 13 — Both visible streams are mid-invocation (no END marker anywhere).
# Edge case: no completed invocation in the two-stream window. Probe fails
# rather than silently passing on the most-recent in-progress stream.
# ============================================================
test_no_completed_run_in_window_fails() {
    local fix_override; fix_override="$(mktemp -d)"
    cat > "$fix_override/describe_log_streams.json" <<'JSON'
{"logStreams":[
  {"logStreamName":"2026/05/28/[$LATEST]inprogress789","lastEventTimestamp":1748359999000},
  {"logStreamName":"2026/05/28/[$LATEST]alsoinprogress","lastEventTimestamp":1748359990000}
]}
JSON
    cat > "$fix_override/get_log_events__inprogress789.json" <<'JSON'
{"events":[
  {"timestamp":1748359998000,"message":"START RequestId: 99edc50e-... Version: $LATEST\n"}
]}
JSON
    cat > "$fix_override/get_log_events__alsoinprogress.json" <<'JSON'
{"events":[
  {"timestamp":1748359989000,"message":"START RequestId: 88edc50e-... Version: $LATEST\n"}
]}
JSON
    FIXTURE_DIR_OVERRIDE="$fix_override" RUN_EXIT_CODE=0
    run_probe "prod"
    unset FIXTURE_DIR_OVERRIDE
    assert_eq "$RUN_EXIT_CODE" "1" "no completed run in window should fail"
    assert_contains "$RUN_STDOUT" "no completed invocation" "failure message should name the no-completed-run condition"
}

test_usage_error_on_missing_env
test_usage_error_on_invalid_env
test_green_path_exits_0_with_pass_lines
test_disabled_schedule_fails
test_nonzero_errors_fails
test_zero_invocations_fails
test_alarm_state_fails
test_missing_success_marker_fails
test_json_mode_emits_valid_json
test_json_mode_red_path_emits_ready_false
test_support_email_alarm_fails_too
test_mid_invocation_falls_back_to_prior_stream
test_no_completed_run_in_window_fails

run_test_summary
