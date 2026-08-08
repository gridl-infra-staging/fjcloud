#!/usr/bin/env bash
# Contract tests for the staging-mirror manifest shard partition.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/run_mirror_manifest_shard.sh"
RUNNER_SHELL=/bin/bash
MANIFEST_PATH="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
EXCLUSION_REGISTRY="$REPO_ROOT/scripts/tests/mirror_excluded_tests.txt"
SERIAL_REGISTRY="$REPO_ROOT/scripts/tests/serial_only_tests.txt"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/lib/test_reachability_manifest.sh
source "$MANIFEST_PATH"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-mirror-shard-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

trim_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

array_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

report_assertion() {
    local label="$1" denominator="$2" failures="$3" message="$4"
    if [ "$denominator" -eq 0 ]; then
        echo "VACUOUS: $label n=0 $message" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif [ "$failures" -eq 0 ]; then
        pass "$label n=$denominator $message"
    else
        fail "$label n=$denominator $message failures=$failures"
    fi
}

load_registry_paths() {
    local registry="$1" kind="$2" line path
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim_space "$line")"
        if [ -z "$line" ] || [[ "$line" = \#* ]]; then
            continue
        fi
        if [ "$kind" = "exclusion" ]; then
            path="${line%% # *}"
        else
            path="${line%%#*}"
        fi
        path="$(trim_space "$path")"
        printf '%s\n' "$path"
    done < "$registry"
}

append_non_comment_content() {
    local path="$1"
    awk '
        {
            text = $0
            sub(/^[[:space:]]*/, "", text)
            if (text ~ /^#/ || text ~ /^\/\//) {
                next
            }
            print $0
        }
    ' "$path" >> "$CONTENT_FILE"
}

EXCLUDED_TESTS=()
while IFS= read -r test_path; do
    EXCLUDED_TESTS+=("$test_path")
done < <(load_registry_paths "$EXCLUSION_REGISTRY" exclusion)

SERIAL_TESTS=()
while IFS= read -r test_path; do
    SERIAL_TESTS+=("$test_path")
done < <(load_registry_paths "$SERIAL_REGISTRY" serial)

RUNNABLE_TESTS=()
RUNNABLE_SERIAL_TESTS=()
for test_path in "${TEST_REACHABILITY_HERMETIC_TESTS[@]}"; do
    if ! array_contains "$test_path" "${EXCLUDED_TESTS[@]}"; then
        RUNNABLE_TESTS+=("$test_path")
        if array_contains "$test_path" "${SERIAL_TESTS[@]}"; then
            RUNNABLE_SERIAL_TESTS+=("$test_path")
        fi
    fi
done

write_expected_runnable() {
    local output_path="$1"
    printf '%s\n' "${RUNNABLE_TESTS[@]}" > "$output_path"
}

collect_partition() {
    local repo_root="$1" shard_count="$2" output_dir="$3"
    local shard_index
    mkdir -p "$output_dir"
    for ((shard_index = 1; shard_index <= shard_count; shard_index++)); do
        FJCLOUD_MIRROR_SHARD_REPO_ROOT="$repo_root" \
            "$RUNNER_SHELL" "$RUNNER" --list --shard "$shard_index" --shards "$shard_count" \
            > "$output_dir/shard_$shard_index.txt" \
            2> "$output_dir/shard_$shard_index.err" || return $?
    done
}

partition_defects() {
    local output_dir="$1" shard_count="$2" expected_path="$3"
    local combined="$output_dir/combined.txt" actual_sorted="$output_dir/actual.sorted"
    local expected_sorted="$output_dir/expected.sorted" duplicate_count missing_count extra_count
    cat "$output_dir"/shard_*.txt > "$combined"
    LC_ALL=C sort "$combined" > "$actual_sorted"
    LC_ALL=C sort "$expected_path" > "$expected_sorted"
    duplicate_count="$(uniq -d "$actual_sorted" | wc -l | tr -d '[:space:]')"
    missing_count="$(comm -23 "$expected_sorted" "$actual_sorted" | tee "$output_dir/missing.txt" | wc -l | tr -d '[:space:]')"
    extra_count="$(comm -13 "$expected_sorted" "$actual_sorted" | tee "$output_dir/extra.txt" | wc -l | tr -d '[:space:]')"
    if [ "$duplicate_count" -ne 0 ] || [ "$missing_count" -ne 0 ] || [ "$extra_count" -ne 0 ]; then
        while IFS= read -r test_path; do
            [ -n "$test_path" ] && echo "missing suite: $test_path" >&2
        done < "$output_dir/missing.txt"
        while IFS= read -r test_path; do
            [ -n "$test_path" ] && echo "unexpected suite: $test_path" >&2
        done < "$output_dir/extra.txt"
        echo "partition defects: duplicates=$duplicate_count missing=$missing_count extra=$extra_count shards=$shard_count" >&2
        return 1
    fi
}

assert_partition() {
    local shard_count="$1" output_dir="$TMP_ROOT/partition_$1" expected="$TMP_ROOT/expected_$1.txt"
    local failures=0 shard_index count min_count=-1 max_count=0 serial_count
    write_expected_runnable "$expected"
    if ! collect_partition "$REPO_ROOT" "$shard_count" "$output_dir"; then
        failures=1
    elif ! partition_defects "$output_dir" "$shard_count" "$expected"; then
        failures=1
    fi
    report_assertion "partition exact and disjoint for $shard_count shards" "${#RUNNABLE_TESTS[@]}" "$failures" "runnable manifest suites appear exactly once"

    failures=0
    for ((shard_index = 1; shard_index <= shard_count; shard_index++)); do
        if ! cmp -s "$output_dir/shard_$shard_index.txt" <(
            FJCLOUD_MIRROR_SHARD_REPO_ROOT="$REPO_ROOT" "$RUNNER_SHELL" "$RUNNER" \
                --list --shard "$shard_index" --shards "$shard_count"
        ); then
            failures=$((failures + 1))
        fi
    done
    report_assertion "deterministic output for $shard_count shards" "$shard_count" "$failures" "second list pass is byte-identical"

    failures=0
    for ((shard_index = 1; shard_index <= shard_count; shard_index++)); do
        count="$(wc -l < "$output_dir/shard_$shard_index.txt" | tr -d '[:space:]')"
        if [ "$min_count" -lt 0 ] || [ "$count" -lt "$min_count" ]; then min_count="$count"; fi
        if [ "$count" -gt "$max_count" ]; then max_count="$count"; fi
    done
    [ $((max_count - min_count)) -le 1 ] || failures=1
    report_assertion "balanced output for $shard_count shards" "$shard_count" "$failures" "largest-minus-smallest suite count is at most one"

    failures=0
    for ((shard_index = 1; shard_index <= shard_count; shard_index++)); do
        serial_count=0
        for test_path in "${RUNNABLE_SERIAL_TESTS[@]}"; do
            if grep -Fxq "$test_path" "$output_dir/shard_$shard_index.txt"; then
                serial_count=$((serial_count + 1))
            fi
        done
        [ "$serial_count" -le 1 ] || failures=$((failures + 1))
    done
    report_assertion "serial placement for $shard_count shards" "$shard_count" "$failures" "each shard has at most one runnable serial suite"
}

copy_fixture() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/scripts/lib" "$fixture_root/scripts/tests"
    cp "$MANIFEST_PATH" "$fixture_root/scripts/lib/test_reachability_manifest.sh"
    cp "$EXCLUSION_REGISTRY" "$fixture_root/scripts/tests/mirror_excluded_tests.txt"
    cp "$SERIAL_REGISTRY" "$fixture_root/scripts/tests/serial_only_tests.txt"
}

expect_runner_failure() {
    local label="$1" repo_root="$2" offending="$3"
    shift 3
    local output="$TMP_ROOT/failure_${label//[^[:alnum:]]/_}.txt" rc=0 failures=0
    FJCLOUD_MIRROR_SHARD_REPO_ROOT="$repo_root" "$RUNNER_SHELL" "$RUNNER" "$@" > /dev/null 2> "$output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$offending" "$output" || failures=$((failures + 1))
    report_assertion "$label" 1 "$failures" "runner exits non-zero and stderr names $offending"
}

assert_failure_modes() {
    local fixture="$TMP_ROOT/failure_fixture" unknown="scripts/tests/not_in_manifest_test.sh"
    copy_fixture "$fixture"
    expect_runner_failure "out-of-range shard" "$fixture" "9" --list --shard 9 --shards 8
    expect_runner_failure "non-numeric shard" "$fixture" "nope" --list --shard nope --shards 8
    expect_runner_failure "non-numeric shard count" "$fixture" "many" --list --shard 1 --shards many
    expect_runner_failure "leading-zero shard" "$fixture" "01" --list --shard 01 --shards 8
    expect_runner_failure "leading-zero shard count" "$fixture" "08" --list --shard 1 --shards 08
    expect_runner_failure "insufficient shard count" "$fixture" "${#RUNNABLE_SERIAL_TESTS[@]}" --list --shard 1 --shards 1

    rm "$fixture/scripts/tests/mirror_excluded_tests.txt"
    expect_runner_failure "missing exclusion registry" "$fixture" "mirror_excluded_tests.txt" --list --shard 1 --shards 8
    copy_fixture "$fixture"
    rm "$fixture/scripts/tests/serial_only_tests.txt"
    expect_runner_failure "missing serial registry" "$fixture" "serial_only_tests.txt" --list --shard 1 --shards 8

    copy_fixture "$fixture"
    printf '%s # fixture\n' "$unknown" >> "$fixture/scripts/tests/serial_only_tests.txt"
    expect_runner_failure "serial entry absent from manifest" "$fixture" "$unknown" --list --shard 1 --shards 8
    copy_fixture "$fixture"
    printf '%s # absent/path — fixture\n' "$unknown" >> "$fixture/scripts/tests/mirror_excluded_tests.txt"
    expect_runner_failure "exclusion entry absent from manifest" "$fixture" "$unknown" --list --shard 1 --shards 8
}

reader_has_registry_reference() {
    local reader_path="$1"
    CONTENT_FILE="$TMP_ROOT/reader_content.txt"
    : > "$CONTENT_FILE"
    append_non_comment_content "$reader_path"
    grep -Fq 'mirror_excluded_tests.txt' "$CONTENT_FILE"
}

check_reader_safety() {
    local reader_path="$1"
    # Fail closed: an absent or unreadable reader means the scan below verified
    # nothing, and a silent green there is exactly the "no registry reference"
    # answer a moved or renamed local gate would fake.
    if [ ! -r "$reader_path" ]; then
        echo "local gate reader is missing or unreadable: $reader_path" >&2
        return 1
    fi
    if reader_has_registry_reference "$reader_path"; then
        echo "local gate reader references mirror_excluded_tests.txt: $reader_path" >&2
        return 1
    fi
}

resolve_local_gate_reader() {
    printf '%s' "${FJCLOUD_MIRROR_LOCAL_GATE_READER_PATH:-$REPO_ROOT/scripts/local-ci.sh}"
}

assert_local_gate_protection() {
    local local_gate_reader
    local_gate_reader="$(resolve_local_gate_reader)"
    local failures=0 fixture="$TMP_ROOT/local_gate_fixture.sh" red_output="$TMP_ROOT/local_gate_red.txt" rc=0
    local missing_reader="$TMP_ROOT/absent_local_ci.sh" missing_output="$TMP_ROOT/local_gate_missing.txt"
    local resolved_missing=""
    check_reader_safety "$local_gate_reader" || failures=$((failures + 1))
    check_reader_safety "$MANIFEST_PATH" || failures=$((failures + 1))
    report_assertion "local gate excludes mirror registry" 2 "$failures" "local-ci and manifest have no executable registry reference"

    printf '%s\n' 'registry=scripts/tests/mirror_excluded_tests.txt' > "$fixture"
    failures=0
    check_reader_safety "$fixture" 2> "$red_output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq 'mirror_excluded_tests.txt' "$red_output" || failures=$((failures + 1))
    report_assertion "local gate protection regression" 1 "$failures" "fixture registry reference is rejected"

    # A reader path that does not exist means the guard verified nothing, so it
    # must be red rather than silently green. Drives the same parameterized
    # override the production reader path comes from.
    failures=0
    rm -f "$missing_reader"
    resolved_missing="$(FJCLOUD_MIRROR_LOCAL_GATE_READER_PATH="$missing_reader" resolve_local_gate_reader)"
    [ "$resolved_missing" = "$missing_reader" ] || failures=$((failures + 1))
    rc=0
    check_reader_safety "$resolved_missing" 2> "$missing_output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$missing_reader" "$missing_output" || failures=$((failures + 1))
    report_assertion "local gate reader must be readable" 1 "$failures" "an unreadable reader path is red, not green"
}

assert_dropped_suite_guard() {
    local fixture="$TMP_ROOT/dropped_fixture" output_dir="$TMP_ROOT/dropped_partition"
    local expected="$TMP_ROOT/dropped_expected.txt" dropped="${RUNNABLE_TESTS[0]}" red_output="$TMP_ROOT/dropped_red.txt"
    local rc=0 failures=0
    copy_fixture "$fixture"
    awk -v dropped="$dropped" 'index($0, "\"" dropped "\"") == 0 { print }' \
        "$MANIFEST_PATH" > "$fixture/scripts/lib/test_reachability_manifest.sh"
    write_expected_runnable "$expected"
    collect_partition "$fixture" 8 "$output_dir"
    partition_defects "$output_dir" 8 "$expected" 2> "$red_output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$dropped" "$red_output" || failures=$((failures + 1))
    report_assertion "dropped-suite regression" "${#RUNNABLE_TESTS[@]}" "$failures" "red proof names $dropped"
}

assert_execution_reports_non_serial_failure_without_serial_tail() {
    local fixture="$TMP_ROOT/execution_fixture" output="$TMP_ROOT/execution_failure.err"
    local failing_suite="scripts/tests/failing_non_serial_test.sh"
    local serial_suite="scripts/tests/passing_serial_test.sh"
    local excluded_suite="scripts/tests/excluded_fixture_test.sh"
    local rc=0 failures=0
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$failing_suite"
    "$serial_suite"
    "$excluded_suite"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded_suite" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s # fixture serial suite\n' "$serial_suite" > "$fixture/scripts/tests/serial_only_tests.txt"
    cat > "$fixture/$failing_suite" <<'EOF'
#!/usr/bin/env bash
echo "intentional non-serial failure" >&2
exit 7
EOF
    cat > "$fixture/$serial_suite" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$failing_suite" "$fixture/$serial_suite"

    FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" "$RUNNER_SHELL" "$RUNNER" \
        --shard 2 --shards 2 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$failing_suite" "$output" || failures=$((failures + 1))
    grep -Fq "exit 7" "$output" || failures=$((failures + 1))
    report_assertion "execution failure without serial tail" 1 "$failures" "failing non-serial suite is reported on a shard with no serial suite"
}

assert_failure_marker_survives_long_tail() {
    local fixture="$TMP_ROOT/failure_marker_fixture" output="$TMP_ROOT/failure_marker.err"
    local failing_suite="scripts/tests/failing_with_long_tail_test.sh"
    local serial_suite="scripts/tests/failure_marker_serial_test.sh"
    local excluded_suite="scripts/tests/failure_marker_excluded_test.sh"
    local rc=0 failures=0
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$failing_suite"
    "$serial_suite"
    "$excluded_suite"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded_suite" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s # fixture serial suite\n' "$serial_suite" > "$fixture/scripts/tests/serial_only_tests.txt"
    cat > "$fixture/$failing_suite" <<'EOF'
#!/usr/bin/env bash
echo "FAIL: buried assertion that must reach the CI log" >&2
for i in $(seq 1 40); do
    echo "PASS: trailing success $i"
done
exit 1
EOF
    cat > "$fixture/$serial_suite" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$failing_suite" "$fixture/$serial_suite"

    FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" "$RUNNER_SHELL" "$RUNNER" \
        --shard 1 --shards 1 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$failing_suite" "$output" || failures=$((failures + 1))
    grep -Fq "FAIL: buried assertion that must reach the CI log" "$output" || failures=$((failures + 1))
    report_assertion "failure marker survives long tail" 1 "$failures" "runner emits FAIL lines even when they fall outside the stderr tail"
}

assert_execution_count_summary_reaches_log() {
    local fixture="$TMP_ROOT/execution_count_fixture" output="$TMP_ROOT/execution_count.err"
    local suite_one="scripts/tests/execution_count_one_test.sh"
    local suite_two="scripts/tests/execution_count_two_test.sh"
    local excluded_suite="scripts/tests/execution_count_excluded_test.sh"
    local rc=0 failures=0
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$suite_one"
    "$suite_two"
    "$excluded_suite"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded_suite" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s\n' '# no serial suites in this fixture' > "$fixture/scripts/tests/serial_only_tests.txt"
    cat > "$fixture/$suite_one" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$fixture/$suite_two" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$suite_one" "$fixture/$suite_two"

    FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" "$RUNNER_SHELL" "$RUNNER" \
        --shard 1 --shards 1 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -eq 0 ] || failures=$((failures + 1))
    grep -Fq "mirror manifest shard: executed 2 suite(s) in shard 1/1" "$output" || failures=$((failures + 1))
    report_assertion "execution count summary reaches log" 1 "$failures" "successful shard logs expose executed suite count for mirror proof"
}

assert_execution_scrubs_ambient_environment() {
    local fixture="$TMP_ROOT/hermetic_environment_fixture"
    local output="$TMP_ROOT/hermetic_environment.err"
    local suite="scripts/tests/hermetic_environment_test.sh"
    local serial_suite="scripts/tests/hermetic_environment_serial_test.sh"
    local excluded_suite="scripts/tests/hermetic_environment_excluded_test.sh"
    local rc=0 failures=0
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$suite"
    "$serial_suite"
    "$excluded_suite"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded_suite" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s # fixture serial suite\n' "$serial_suite" > "$fixture/scripts/tests/serial_only_tests.txt"
    cat > "$fixture/$suite" <<'EOF'
#!/usr/bin/env bash
for poisoned_name in DATABASE_URL AWS_ACCESS_KEY_ID FJCLOUD_API_URL FJCLOUD_FEATURE_FLAG; do
    if [ -n "$(printenv "$poisoned_name" 2>/dev/null)" ]; then
        echo "inherited poisoned variable: $poisoned_name" >&2
        exit 19
    fi
done
exit 0
EOF
    cat > "$fixture/$serial_suite" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$suite" "$fixture/$serial_suite"

    DATABASE_URL=poisoned \
        AWS_ACCESS_KEY_ID=poisoned \
        FJCLOUD_API_URL=poisoned \
        FJCLOUD_FEATURE_FLAG=poisoned \
        FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" \
        "$RUNNER_SHELL" "$RUNNER" --shard 1 --shards 1 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -eq 0 ] || failures=$((failures + 1))
    if grep -Fq "inherited poisoned variable" "$output"; then
        failures=$((failures + 1))
    fi
    report_assertion "execution environment is hermetic" 4 "$failures" "database, credential, service, and feature-flag poison is absent from suites"
}

assert_empty_registries_are_bash_32_safe() {
    local fixture="$TMP_ROOT/empty_registries_fixture"
    local suite="scripts/tests/empty_registries_test.sh"
    local output="$TMP_ROOT/empty_registries.out"
    local error="$TMP_ROOT/empty_registries.err"
    local rc=0 failures=0
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=("$suite")
EOF
    printf '%s\n' '# no mirror exclusions in this fixture' > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s\n' '# no serial suites in this fixture' > "$fixture/scripts/tests/serial_only_tests.txt"

    FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" "$RUNNER_SHELL" "$RUNNER" \
        --list --shard 1 --shards 1 > "$output" 2> "$error" || rc=$?
    [ "$rc" -eq 0 ] || failures=$((failures + 1))
    [ "$(cat "$output")" = "$suite" ] || failures=$((failures + 1))
    report_assertion "empty registries are Bash 3.2-safe" 2 "$failures" "comment-only registries list the sole manifest suite without an unbound-array abort"
}

assert_watchdog_child_reaped() {
    # A completed suite must not leave its timeout watchdog's `sleep` child
    # alive. A `sleep` shim earlier on PATH records the PID of the watchdog's
    # 900-second sleep; after the runner returns that PID must be gone. This
    # fails red against a scalar `kill "$watchdog_pid"` that reaps the watchdog
    # shell but orphans its sleep child.
    local fixture="$TMP_ROOT/watchdog_fixture" bindir="$TMP_ROOT/watchdog_bin"
    local pid_file="$TMP_ROOT/watchdog_sleep.pid" output="$TMP_ROOT/watchdog_run.err"
    local suite="scripts/tests/watchdog_slow_pass_test.sh"
    local serial="scripts/tests/watchdog_serial_pass_test.sh"
    local excluded="scripts/tests/watchdog_excluded_test.sh"
    local rc=0 failures=0 orphan_pid=""
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests" "$bindir"
    # A runnable serial suite and an excluded suite keep both registries and the
    # runnable-serial population non-vacuous (their live contract). The
    # non-serial suite runs first, so its watchdog is the recorded PID.
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$suite"
    "$serial"
    "$excluded"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s # fixture serial suite\n' "$serial" > "$fixture/scripts/tests/serial_only_tests.txt"
    cat > "$fixture/$suite" <<'EOF'
#!/usr/bin/env bash
sleep 0.5
exit 0
EOF
    cat > "$fixture/$serial" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$suite" "$fixture/$serial"
    # The shim records the first 900-second watchdog sleep, then bounds every
    # watchdog sleep so a broken runner cannot leak past the assertion window.
    # A live recorded PID after the runner returns proves the leak.
    cat > "$bindir/sleep" <<EOF
#!/bin/bash
if [ "\$1" = "900" ]; then
    if [ ! -f "$pid_file" ]; then printf '%s\\n' "\$\$" > "$pid_file"; fi
    exec /bin/sleep 30
fi
exec /bin/sleep "\$@"
EOF
    chmod +x "$bindir/sleep"

    rm -f "$pid_file"
    PATH="$bindir:$PATH" FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" \
        "$RUNNER_SHELL" "$RUNNER" --shard 1 --shards 1 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -eq 0 ] || failures=$((failures + 1))
    if [ -s "$pid_file" ]; then
        orphan_pid="$(cat "$pid_file")"
        if kill -0 "$orphan_pid" 2>/dev/null; then
            echo "watchdog sleep child $orphan_pid still alive after runner returned" >&2
            failures=$((failures + 1))
            kill -KILL "$orphan_pid" 2>/dev/null || true
        fi
    else
        echo "watchdog sleep child PID was never recorded" >&2
        failures=$((failures + 1))
    fi
    report_assertion "watchdog child reaped" 1 "$failures" "the timeout watchdog's sleep child is gone after a completed suite"
}

assert_watchdog_kills_hung_suite() {
    # The timeout watchdog's fire path: a suite that never exits must be killed
    # with its whole process group, remapped to SUITE_TIMEOUT_RC, and named on
    # stderr. A `sleep` shim earlier on PATH collapses the runner's 900-second
    # wait to two seconds so the real timeout code runs inside the test; the
    # runner keeps its own constants and gains no test-only seam.
    local fixture="$TMP_ROOT/timeout_fixture" bindir="$TMP_ROOT/timeout_bin"
    local child_pid_file="$TMP_ROOT/timeout_child.pid" output="$TMP_ROOT/timeout_run.err"
    local suite="scripts/tests/watchdog_hang_test.sh"
    local serial="scripts/tests/watchdog_timeout_serial_test.sh"
    local excluded="scripts/tests/watchdog_timeout_excluded_test.sh"
    local rc=0 failures=0 child_pid=""
    mkdir -p "$fixture/scripts/lib" "$fixture/scripts/tests" "$bindir"
    cat > "$fixture/scripts/lib/test_reachability_manifest.sh" <<EOF
#!/usr/bin/env bash
TEST_REACHABILITY_HERMETIC_TESTS=(
    "$suite"
    "$serial"
    "$excluded"
)
EOF
    printf '%s # absent/from/mirror — fixture exclusion\n' "$excluded" > "$fixture/scripts/tests/mirror_excluded_tests.txt"
    printf '%s # fixture serial suite\n' "$serial" > "$fixture/scripts/tests/serial_only_tests.txt"
    # The hung suite spawns a long-lived grandchild and records its PID: only a
    # process-group kill reaps it, so a scalar kill of the suite leaves it alive.
    cat > "$fixture/$suite" <<EOF
#!/usr/bin/env bash
/bin/sleep 120 &
printf '%s\n' "\$!" > "$child_pid_file"
wait
EOF
    cat > "$fixture/$serial" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$fixture/$suite" "$fixture/$serial"
    cat > "$bindir/sleep" <<'EOF'
#!/bin/bash
if [ "$1" = "900" ]; then
    exec /bin/sleep 2
fi
exec /bin/sleep "$@"
EOF
    chmod +x "$bindir/sleep"

    rm -f "$child_pid_file"
    PATH="$bindir:$PATH" FJCLOUD_MIRROR_SHARD_REPO_ROOT="$fixture" \
        "$RUNNER_SHELL" "$RUNNER" --shard 1 --shards 1 > /dev/null 2> "$output" || rc=$?
    [ "$rc" -ne 0 ] || failures=$((failures + 1))
    grep -Fq "$suite" "$output" || failures=$((failures + 1))
    grep -Fq "(timed out, exit 124)" "$output" || failures=$((failures + 1))
    if [ -s "$child_pid_file" ]; then
        child_pid="$(cat "$child_pid_file")"
        if kill -0 "$child_pid" 2>/dev/null; then
            echo "hung suite descendant $child_pid survived the timeout kill" >&2
            failures=$((failures + 1))
            kill -KILL "$child_pid" 2>/dev/null || true
        fi
    else
        echo "hung suite descendant PID was never recorded" >&2
        failures=$((failures + 1))
    fi
    report_assertion "watchdog kills hung suite" 1 "$failures" "a suite past the timeout is reported as exit 124 and leaves no descendant"
}

echo "=== mirror manifest shard contract tests ==="

if [ ! -x "$RUNNER" ]; then
    report_assertion "runner exists and is executable" 1 1 "scripts/run_mirror_manifest_shard.sh is required"
    run_test_summary
fi

report_assertion "live runnable manifest" "${#RUNNABLE_TESTS[@]}" 0 "manifest minus exclusions is non-vacuous"
report_assertion "live runnable serial registry" "${#RUNNABLE_SERIAL_TESTS[@]}" 0 "serial placement population is non-vacuous"
assert_partition 8
assert_partition 6
assert_failure_modes
assert_local_gate_protection
assert_dropped_suite_guard
assert_execution_reports_non_serial_failure_without_serial_tail
assert_failure_marker_survives_long_tail
assert_execution_count_summary_reaches_log
assert_execution_scrubs_ambient_environment
assert_empty_registries_are_bash_32_safe
assert_watchdog_child_reaped
assert_watchdog_kills_hung_suite

run_test_summary
