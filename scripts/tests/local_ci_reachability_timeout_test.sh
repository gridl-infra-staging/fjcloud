#!/usr/bin/env bash
# RED contract for the per-suite reachability timeout owned by local-ci.sh.
#
# The purpose-built suite never exits. A test-owned watchdog bounds current
# HEAD so this contract fails quickly instead of reproducing the production
# hang indefinitely. The watchdog is scaffolding only: the contract requires
# run_reachability_suite itself to finish before the watchdog fires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

TEST_TMPDIR=""
TEST_TMPDIRS=()
TEST_CHILD_PIDS=()
HARNESS_PID=""
EXPECTED_REACHABILITY_TIMEOUT_RC=124
REACHABILITY_TIMEOUT_SECONDS=1
REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS=500
REACHABILITY_TERM_GRACE_MILLIS=300
REACHABILITY_MARKER_WAIT_MILLIS=1000
REACHABILITY_RESULT_STEM_BODY=""
REACHABILITY_TIMING_BODY=""
REACHABILITY_RUNNER_BODY=""
REACHABILITY_FAILURE_LOOP=""

cleanup() {
    local child_pid
    if [ -n "$HARNESS_PID" ] && kill -0 "$HARNESS_PID" 2>/dev/null; then
        kill -TERM "$HARNESS_PID" 2>/dev/null || true
        wait "$HARNESS_PID" 2>/dev/null || true
    fi
    if [ "${#TEST_CHILD_PIDS[@]}" -gt 0 ]; then
        for child_pid in "${TEST_CHILD_PIDS[@]}"; do
            [ -n "$child_pid" ] || continue
            kill -TERM "$child_pid" 2>/dev/null || true
            kill -KILL "$child_pid" 2>/dev/null || true
            wait "$child_pid" 2>/dev/null || true
        done
    fi
    local tmpdir
    if [ "${#TEST_TMPDIRS[@]}" -gt 0 ]; then
        for tmpdir in "${TEST_TMPDIRS[@]}"; do
            [ -n "$tmpdir" ] && [ -d "$tmpdir" ] && rm -rf "$tmpdir"
        done
    fi
}
trap cleanup EXIT

new_test_tmpdir() {
    TEST_TMPDIR="$(mktemp -d)"
    TEST_TMPDIRS+=("$TEST_TMPDIR")
}

wall_clock_millis() {
    python3 -c 'import time; print(int(time.time() * 1000))'
}

extract_function() {
    local function_name="$1"
    awk -v prefix="${function_name}() {" \
        'index($0, prefix) == 1 { found=1 } found { print } found && /^}$/ { exit }' \
        "$LOCAL_CI"
}

extract_failure_loop() {
    awk '
        $0 == "    for test_path in \"${TEST_REACHABILITY_HERMETIC_TESTS[@]}\"; do" {
            occurrences++
            if (occurrences == 2) capture=1
        }
        capture { print }
        capture && $0 == "    done" { exit }
    ' "$LOCAL_CI"
}

load_reachability_owner_seams() {
    REACHABILITY_RESULT_STEM_BODY="$(extract_function reachability_result_stem)"
    REACHABILITY_TIMING_BODY="$(extract_function write_reachability_timing_row)"
    REACHABILITY_RUNNER_BODY="$(extract_function run_reachability_suite)"
    REACHABILITY_FAILURE_LOOP="$(extract_failure_loop)"
    if [ -z "$REACHABILITY_RESULT_STEM_BODY" ] \
        || [ -z "$REACHABILITY_TIMING_BODY" ] \
        || [ -z "$REACHABILITY_RUNNER_BODY" ] \
        || [ -z "$REACHABILITY_FAILURE_LOOP" ]; then
        fail "reachability timeout owner seams were not extractable from local-ci.sh"
        return 1
    fi
}

render_reachability_failure() (
    local fixture_path="$1"
    results_dir="$2"
    eval "$REACHABILITY_RESULT_STEM_BODY"
    TEST_REACHABILITY_HERMETIC_TESTS=("$fixture_path")
    failed=()
    eval "$REACHABILITY_FAILURE_LOOP"
)

assert_nonterminating_suite_is_bounded_and_reported_as_timeout() {
    local scheduling_mode="$1" scheduling_label="$2"
    local term_trap="$3" fixture_label="$4"
    local fixture_path result_stem harness_rc=0 watchdog_fired=0 suite_rc
    local failure_output bound_millis fixture_started_millis observed_end_millis
    local elapsed_millis now_millis harness_started_millis watchdog_deadline_millis

    new_test_tmpdir
    fixture_path="scripts/tests/fixture_${fixture_label}_never_exits_test.sh"
    result_stem="scripts_tests_fixture_${fixture_label}_never_exits_test.sh"
    mkdir -p "$TEST_TMPDIR/scripts/tests" "$TEST_TMPDIR/results"
    cat >"$TEST_TMPDIR/$fixture_path" <<EOF
#!/usr/bin/env bash
$term_trap
python3 -c 'import time; print(int(time.time() * 1000))' > "$TEST_TMPDIR/started"
while :; do sleep 0.05; done
EOF
    chmod +x "$TEST_TMPDIR/$fixture_path"

    bound_millis="$(( REACHABILITY_TIMEOUT_SECONDS * 1000 + REACHABILITY_TERM_GRACE_MILLIS + REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS ))"
    harness_started_millis="$(wall_clock_millis)"
    # This parent-seeded ceiling remains enforceable even if the fixture never
    # writes a usable marker. A valid marker below tightens it to the configured
    # suite bound, excluding harness startup from the elapsed-time contract.
    watchdog_deadline_millis="$(( harness_started_millis + REACHABILITY_MARKER_WAIT_MILLIS + bound_millis ))"
    (
        REPO_ROOT="$TEST_TMPDIR"
        FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS="$REACHABILITY_TIMEOUT_SECONDS"
        export FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS
        now_seconds() { date +%s; }
        eval "$REACHABILITY_RESULT_STEM_BODY"
        eval "$REACHABILITY_TIMING_BODY"
        eval "$REACHABILITY_RUNNER_BODY"
        if [ "$scheduling_mode" = "backgrounded" ]; then
            run_reachability_suite "$fixture_path" "$TEST_TMPDIR/results" &
            wait "$!"
        else
            run_reachability_suite "$fixture_path" "$TEST_TMPDIR/results"
        fi
    ) >"$TEST_TMPDIR/harness.stdout" 2>"$TEST_TMPDIR/harness.stderr" &
    HARNESS_PID="$!"

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -s "$TEST_TMPDIR/started" ] && break
        sleep 0.05
    done
    assert_file_exists "$TEST_TMPDIR/started" \
        "the non-terminating fixture reaches the real suite runner"

    fixture_started_millis="$(cat "$TEST_TMPDIR/started" 2>/dev/null || printf '')"
    if [[ ! "$fixture_started_millis" =~ ^[0-9]+$ ]]; then
        fail "the non-terminating fixture records an epoch millisecond start marker"
        fixture_started_millis="$harness_started_millis"
    else
        pass "the non-terminating fixture records an epoch millisecond start marker"
        watchdog_deadline_millis="$(( fixture_started_millis + bound_millis ))"
    fi

    while kill -0 "$HARNESS_PID" 2>/dev/null; do
        now_millis="$(wall_clock_millis)"
        if [ "$now_millis" -ge "$watchdog_deadline_millis" ]; then
            watchdog_fired=1
            kill -TERM "$HARNESS_PID" 2>/dev/null || true
            sleep 0.1
            kill -KILL "$HARNESS_PID" 2>/dev/null || true
            break
        fi
        sleep 0.05
    done
    wait "$HARNESS_PID" || harness_rc=$?
    observed_end_millis="$(wall_clock_millis)"
    elapsed_millis="$(( observed_end_millis - fixture_started_millis ))"
    HARNESS_PID=""

    if [ "$elapsed_millis" -le "$bound_millis" ]; then
        pass "run_reachability_suite completes within the configured one-second bound plus ${REACHABILITY_TERM_GRACE_MILLIS}ms TERM grace and ${REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS}ms scheduling allowance on the $scheduling_label path"
    else
        fail "run_reachability_suite completes within the configured one-second bound plus ${REACHABILITY_TERM_GRACE_MILLIS}ms TERM grace and ${REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS}ms scheduling allowance on the $scheduling_label path (limit_ms='$bound_millis' actual_ms='$elapsed_millis')"
    fi
    assert_eq "$watchdog_fired" "0" \
        "run_reachability_suite honors the configured one-second bound without test-watchdog intervention on the $scheduling_label path"

    suite_rc="$(cat "$TEST_TMPDIR/results/$result_stem.rc" 2>/dev/null || printf 'missing')"
    assert_eq "$suite_rc" "$EXPECTED_REACHABILITY_TIMEOUT_RC" \
        "timed-out suite writes the reserved timeout receipt code on the $scheduling_label path"

    failure_output="$(render_reachability_failure "$fixture_path" "$TEST_TMPDIR/results" 2>&1)"
    assert_contains "$failure_output" "$fixture_path" \
        "failure output names the exact timed-out suite on the $scheduling_label path"
    assert_contains "$failure_output" "timed out" \
        "failure output classifies expiry as a timeout rather than a generic failure on the $scheduling_label path"

    # Preserve the current-head watchdog outcome in RED output without making
    # a future bounded implementation depend on the harness process exit code.
    echo "reachability timeout specimen ($scheduling_label): configured_timeout_seconds=$REACHABILITY_TIMEOUT_SECONDS allowance_ms=$REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS elapsed_ms=$elapsed_millis watchdog_fired=$watchdog_fired harness_rc=$harness_rc suite_rc=$suite_rc expected_timeout_rc=$EXPECTED_REACHABILITY_TIMEOUT_RC"
}

test_nonterminating_suite_is_bounded_and_reported_as_timeout_on_serial_tail_path() {
    assert_nonterminating_suite_is_bounded_and_reported_as_timeout \
        "direct" "serial tail" "trap 'exit 143' TERM INT HUP" "term_cooperative"
}

test_nonterminating_suite_is_bounded_and_reported_as_timeout_on_concurrent_batch_path() {
    assert_nonterminating_suite_is_bounded_and_reported_as_timeout \
        "backgrounded" "concurrent batch" "trap 'exit 143' TERM INT HUP" "term_cooperative"
}

test_term_ignoring_suite_is_bounded_and_reported_as_timeout_on_serial_tail_path() {
    assert_nonterminating_suite_is_bounded_and_reported_as_timeout \
        "direct" "serial tail" "trap ':' TERM INT HUP" "term_ignoring"
}

test_term_ignoring_suite_is_bounded_and_reported_as_timeout_on_concurrent_batch_path() {
    assert_nonterminating_suite_is_bounded_and_reported_as_timeout \
        "backgrounded" "concurrent batch" "trap ':' TERM INT HUP" "term_ignoring"
}

assert_term_cooperative_leader_cannot_leave_term_ignoring_descendant() {
    local scheduling_mode="$1" scheduling_label="$2"
    local fixture_path result_stem harness_rc=0 watchdog_fired=0 suite_rc child_pid=""
    local failure_output bound_millis fixture_started_millis observed_end_millis
    local elapsed_millis now_millis harness_started_millis watchdog_deadline_millis

    new_test_tmpdir
    fixture_path="scripts/tests/fixture_term_cooperative_leader_child_ignores_term_test.sh"
    result_stem="scripts_tests_fixture_term_cooperative_leader_child_ignores_term_test.sh"
    mkdir -p "$TEST_TMPDIR/scripts/tests" "$TEST_TMPDIR/results"
    cat >"$TEST_TMPDIR/$fixture_path" <<EOF
#!/usr/bin/env bash
trap 'exit 143' TERM INT HUP
python3 -c 'import time; print(int(time.time() * 1000))' > "$TEST_TMPDIR/started"
bash -c 'trap ":" TERM INT HUP; echo "\$\$" > "$TEST_TMPDIR/child.pid"; while :; do sleep 0.05; done' &
while :; do sleep 0.05; done
EOF
    chmod +x "$TEST_TMPDIR/$fixture_path"

    bound_millis="$(( REACHABILITY_TIMEOUT_SECONDS * 1000 + REACHABILITY_TERM_GRACE_MILLIS + REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS ))"
    harness_started_millis="$(wall_clock_millis)"
    watchdog_deadline_millis="$(( harness_started_millis + REACHABILITY_MARKER_WAIT_MILLIS + bound_millis ))"
    (
        REPO_ROOT="$TEST_TMPDIR"
        FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS="$REACHABILITY_TIMEOUT_SECONDS"
        export FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS
        now_seconds() { date +%s; }
        eval "$REACHABILITY_RESULT_STEM_BODY"
        eval "$REACHABILITY_TIMING_BODY"
        eval "$REACHABILITY_RUNNER_BODY"
        if [ "$scheduling_mode" = "backgrounded" ]; then
            run_reachability_suite "$fixture_path" "$TEST_TMPDIR/results" &
            wait "$!"
        else
            run_reachability_suite "$fixture_path" "$TEST_TMPDIR/results"
        fi
    ) >"$TEST_TMPDIR/harness.stdout" 2>"$TEST_TMPDIR/harness.stderr" &
    HARNESS_PID="$!"

    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -s "$TEST_TMPDIR/started" ] && [ -s "$TEST_TMPDIR/child.pid" ] && break
        sleep 0.05
    done
    assert_file_exists "$TEST_TMPDIR/started" \
        "the TERM-cooperative leader fixture reaches the real suite runner"
    assert_file_exists "$TEST_TMPDIR/child.pid" \
        "the TERM-cooperative leader fixture starts a TERM-ignoring descendant"

    child_pid="$(cat "$TEST_TMPDIR/child.pid" 2>/dev/null || printf '')"
    if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
        TEST_CHILD_PIDS+=("$child_pid")
        pass "the TERM-ignoring descendant records its exact PID"
    else
        fail "the TERM-ignoring descendant records its exact PID"
    fi

    fixture_started_millis="$(cat "$TEST_TMPDIR/started" 2>/dev/null || printf '')"
    if [[ ! "$fixture_started_millis" =~ ^[0-9]+$ ]]; then
        fail "the TERM-cooperative leader fixture records an epoch millisecond start marker"
        fixture_started_millis="$harness_started_millis"
    else
        pass "the TERM-cooperative leader fixture records an epoch millisecond start marker"
        watchdog_deadline_millis="$(( fixture_started_millis + bound_millis ))"
    fi

    while kill -0 "$HARNESS_PID" 2>/dev/null; do
        now_millis="$(wall_clock_millis)"
        if [ "$now_millis" -ge "$watchdog_deadline_millis" ]; then
            watchdog_fired=1
            kill -TERM "$HARNESS_PID" 2>/dev/null || true
            sleep 0.1
            kill -KILL "$HARNESS_PID" 2>/dev/null || true
            break
        fi
        sleep 0.05
    done
    wait "$HARNESS_PID" || harness_rc=$?
    observed_end_millis="$(wall_clock_millis)"
    elapsed_millis="$(( observed_end_millis - fixture_started_millis ))"
    HARNESS_PID=""

    if [ "$elapsed_millis" -le "$bound_millis" ]; then
        pass "run_reachability_suite finishes within the timeout budget when the leader exits on TERM and the descendant ignores TERM on the $scheduling_label path"
    else
        fail "run_reachability_suite finishes within the timeout budget when the leader exits on TERM and the descendant ignores TERM on the $scheduling_label path (limit_ms='$bound_millis' actual_ms='$elapsed_millis')"
    fi
    assert_eq "$watchdog_fired" "0" \
        "run_reachability_suite does not need test-watchdog intervention when the leader exits on TERM and the descendant ignores TERM on the $scheduling_label path"

    suite_rc="$(cat "$TEST_TMPDIR/results/$result_stem.rc" 2>/dev/null || printf 'missing')"
    assert_eq "$suite_rc" "$EXPECTED_REACHABILITY_TIMEOUT_RC" \
        "leader-exits-first timeout cleanup still writes rc 124 on the $scheduling_label path"

    failure_output="$(render_reachability_failure "$fixture_path" "$TEST_TMPDIR/results" 2>&1)"
    assert_contains "$failure_output" "$fixture_path" \
        "failure output names the leader-exits-first timeout fixture on the $scheduling_label path"
    assert_contains "$failure_output" "timed out" \
        "failure output keeps the leader-exits-first timeout classified as timed out on the $scheduling_label path"

    if [[ "$child_pid" =~ ^[0-9]+$ ]]; then
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            if ! kill -0 "$child_pid" 2>/dev/null; then
                break
            fi
            sleep 0.05
        done
        if kill -0 "$child_pid" 2>/dev/null; then
            fail "timeout cleanup kills the TERM-ignoring descendant after the leader exits on TERM on the $scheduling_label path"
        else
            pass "timeout cleanup kills the TERM-ignoring descendant after the leader exits on TERM on the $scheduling_label path"
        fi
    fi

    echo "reachability timeout leader-exits-first specimen ($scheduling_label): configured_timeout_seconds=$REACHABILITY_TIMEOUT_SECONDS allowance_ms=$REACHABILITY_TIMEOUT_ALLOWANCE_MILLIS elapsed_ms=$elapsed_millis watchdog_fired=$watchdog_fired harness_rc=$harness_rc suite_rc=$suite_rc child_pid=$child_pid"
}

test_term_cooperative_leader_cannot_leave_term_ignoring_descendant_on_serial_tail_path() {
    assert_term_cooperative_leader_cannot_leave_term_ignoring_descendant \
        "direct" "serial tail"
}

test_term_cooperative_leader_cannot_leave_term_ignoring_descendant_on_concurrent_batch_path() {
    assert_term_cooperative_leader_cannot_leave_term_ignoring_descendant \
        "backgrounded" "concurrent batch"
}

test_ordinary_suite_failure_preserves_original_receipt_code() {
    local fixture_path result_stem suite_rc failure_output

    new_test_tmpdir
    fixture_path="scripts/tests/fixture_exits_42_test.sh"
    result_stem="scripts_tests_fixture_exits_42_test.sh"
    mkdir -p "$TEST_TMPDIR/scripts/tests" "$TEST_TMPDIR/results"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'echo ordinary failure specimen' \
        'exit 42' \
        >"$TEST_TMPDIR/$fixture_path"
    chmod +x "$TEST_TMPDIR/$fixture_path"

    (
        REPO_ROOT="$TEST_TMPDIR"
        FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS="$REACHABILITY_TIMEOUT_SECONDS"
        export FJCLOUD_REACHABILITY_SUITE_TIMEOUT_SECONDS
        now_seconds() { date +%s; }
        eval "$REACHABILITY_RESULT_STEM_BODY"
        eval "$REACHABILITY_TIMING_BODY"
        eval "$REACHABILITY_RUNNER_BODY"
        run_reachability_suite "$fixture_path" "$TEST_TMPDIR/results"
    )

    suite_rc="$(cat "$TEST_TMPDIR/results/$result_stem.rc" 2>/dev/null || printf 'missing')"
    assert_eq "$suite_rc" "42" \
        "ordinary failing suites preserve their original receipt code"
    assert_ne "$suite_rc" "$EXPECTED_REACHABILITY_TIMEOUT_RC" \
        "ordinary failing suites are distinguishable from timeout receipts"

    failure_output="$(render_reachability_failure "$fixture_path" "$TEST_TMPDIR/results" 2>&1)"
    assert_contains "$failure_output" "$fixture_path (exit 42)" \
        "ordinary failure output names the original suite exit code"
    assert_not_contains "$failure_output" "timed out" \
        "ordinary failure output is not classified as a timeout"
}

if load_reachability_owner_seams; then
    test_nonterminating_suite_is_bounded_and_reported_as_timeout_on_serial_tail_path
    test_nonterminating_suite_is_bounded_and_reported_as_timeout_on_concurrent_batch_path
    test_term_ignoring_suite_is_bounded_and_reported_as_timeout_on_serial_tail_path
    test_term_ignoring_suite_is_bounded_and_reported_as_timeout_on_concurrent_batch_path
    test_term_cooperative_leader_cannot_leave_term_ignoring_descendant_on_serial_tail_path
    test_term_cooperative_leader_cannot_leave_term_ignoring_descendant_on_concurrent_batch_path
    test_ordinary_suite_failure_preserves_original_receipt_code
fi
run_test_summary
