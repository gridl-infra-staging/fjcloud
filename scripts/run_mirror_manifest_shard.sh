#!/usr/bin/env bash
# Run one deterministic shard of the test-reachability manifest on the mirror.
#
# FJCLOUD_MIRROR_SHARD_REPO_ROOT is the sole fixture seam: tests may point all
# three input owners at a temporary repository root. Production callers leave
# it unset.
#
# Stage 5 follow-up: the executor overlap with scripts/local-ci.sh:1186-1430,
# the locally re-declared timeout constants, and the trim_space/array_contains
# helpers below (byte-identical copies also live in scripts/probe_test_reachability.sh,
# scripts/tests/mirror_excluded_tests_contract_test.sh and
# scripts/tests/mirror_manifest_shard_test.sh) should collapse into
# scripts/lib/reachability_runner.sh after the Stage 3 and Stage 4 lanes merge.
# Note for that extraction: callers must guard expansions with the
# "${arr[@]+...}" empty-array idiom, since Bash 3.2 trips set -u on an empty array.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_MIRROR_SHARD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MANIFEST_PATH="$REPO_ROOT/scripts/lib/test_reachability_manifest.sh"
EXCLUSION_REGISTRY="$REPO_ROOT/scripts/tests/mirror_excluded_tests.txt"
SERIAL_REGISTRY="$REPO_ROOT/scripts/tests/serial_only_tests.txt"
MAX_CONCURRENT_SUITES=8
# scripts/local-ci.sh:198-199 owns these values. Their duplication is the
# deliberate Stage 5 deferral named above.
SUITE_TIMEOUT_SECONDS=900
SUITE_TIMEOUT_RC=124

usage() {
    cat >&2 <<'EOF'
Usage: scripts/run_mirror_manifest_shard.sh --shard <1-based-index> --shards <count> [--list]
EOF
}

die() {
    echo "mirror manifest shard: $*" >&2
    exit 2
}

validate_canonical_decimal() {
    local flag_name="$1" value="$2"
    case "$value" in
        *[!0-9]*|'') die "$flag_name must be numeric: $value" ;;
    esac
    case "$value" in
        0|[1-9]*) ;;
        *) die "$flag_name must not contain a leading zero: $value" ;;
    esac
}

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

SHARD_INDEX=""
SHARD_COUNT=""
LIST_ONLY=false

while [ "$#" -gt 0 ]; do
    case "$1" in
        --shard)
            [ "$#" -ge 2 ] || { usage; die "--shard requires a value"; }
            SHARD_INDEX="$2"
            shift 2
            ;;
        --shards)
            [ "$#" -ge 2 ] || { usage; die "--shards requires a value"; }
            SHARD_COUNT="$2"
            shift 2
            ;;
        --list)
            LIST_ONLY=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            die "unknown argument: $1"
            ;;
    esac
done

[ -n "$SHARD_INDEX" ] || { usage; die "missing --shard value"; }
[ -n "$SHARD_COUNT" ] || { usage; die "missing --shards value"; }
validate_canonical_decimal "--shard" "$SHARD_INDEX"
validate_canonical_decimal "--shards" "$SHARD_COUNT"
[ "$SHARD_INDEX" -ge 1 ] || die "--shard is out of range: $SHARD_INDEX"
[ "$SHARD_COUNT" -ge 1 ] || die "--shards must be at least 1: $SHARD_COUNT"
[ "$SHARD_INDEX" -le "$SHARD_COUNT" ] || \
    die "--shard is out of range: $SHARD_INDEX exceeds --shards $SHARD_COUNT"

[ -f "$MANIFEST_PATH" ] || die "manifest missing: scripts/lib/test_reachability_manifest.sh"
[ -f "$EXCLUSION_REGISTRY" ] || die "exclusion registry missing: scripts/tests/mirror_excluded_tests.txt"
[ -f "$SERIAL_REGISTRY" ] || die "serial registry missing: scripts/tests/serial_only_tests.txt"

# shellcheck source=scripts/lib/test_reachability_manifest.sh
source "$MANIFEST_PATH"
[ "${#TEST_REACHABILITY_HERMETIC_TESTS[@]}" -gt 0 ] || die "manifest is empty: $MANIFEST_PATH"

EXCLUDED_TESTS=()
while IFS= read -r line || [ -n "$line" ]; do
    line="$(trim_space "$line")"
    if [ -z "$line" ] || [[ "$line" = \#* ]]; then
        continue
    fi
    test_path="$(trim_space "${line%% # *}")"
    array_contains "$test_path" "${TEST_REACHABILITY_HERMETIC_TESTS[@]}" || \
        die "exclusion registry entry absent from manifest: $test_path"
    EXCLUDED_TESTS+=("$test_path")
done < "$EXCLUSION_REGISTRY"

SERIAL_TESTS=()
while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(trim_space "$line")"
    [ -n "$line" ] || continue
    array_contains "$line" "${TEST_REACHABILITY_HERMETIC_TESTS[@]}" || \
        die "serial registry entry absent from manifest: $line"
    SERIAL_TESTS+=("$line")
done < "$SERIAL_REGISTRY"

RUNNABLE_SERIAL_TESTS=()
RUNNABLE_NON_SERIAL_TESTS=()
for test_path in "${TEST_REACHABILITY_HERMETIC_TESTS[@]}"; do
    if array_contains "$test_path" ${EXCLUDED_TESTS[@]+"${EXCLUDED_TESTS[@]}"}; then
        continue
    fi
    if array_contains "$test_path" ${SERIAL_TESTS[@]+"${SERIAL_TESTS[@]}"}; then
        RUNNABLE_SERIAL_TESTS+=("$test_path")
    else
        RUNNABLE_NON_SERIAL_TESTS+=("$test_path")
    fi
done

[ "$SHARD_COUNT" -ge "${#RUNNABLE_SERIAL_TESTS[@]}" ] || \
    die "--shards $SHARD_COUNT is below runnable serial suite count ${#RUNNABLE_SERIAL_TESTS[@]}"

SHARD_LOADS=()
for ((shard = 1; shard <= SHARD_COUNT; shard++)); do
    SHARD_LOADS[shard]=0
done

SERIAL_ASSIGNMENTS=()
shard=1
for test_path in ${RUNNABLE_SERIAL_TESTS[@]+"${RUNNABLE_SERIAL_TESTS[@]}"}; do
    SERIAL_ASSIGNMENTS+=("$shard|$test_path")
    SHARD_LOADS[shard]=$((SHARD_LOADS[shard] + 1))
    shard=$((shard + 1))
done

NON_SERIAL_ASSIGNMENTS=()
for test_path in ${RUNNABLE_NON_SERIAL_TESTS[@]+"${RUNNABLE_NON_SERIAL_TESTS[@]}"}; do
    least_loaded_shard=1
    for ((shard = 2; shard <= SHARD_COUNT; shard++)); do
        if [ "${SHARD_LOADS[shard]}" -lt "${SHARD_LOADS[least_loaded_shard]}" ]; then
            least_loaded_shard="$shard"
        fi
    done
    NON_SERIAL_ASSIGNMENTS+=("$least_loaded_shard|$test_path")
    SHARD_LOADS[least_loaded_shard]=$((SHARD_LOADS[least_loaded_shard] + 1))
done

SHARD_NON_SERIAL_TESTS=()
for assignment in ${NON_SERIAL_ASSIGNMENTS[@]+"${NON_SERIAL_ASSIGNMENTS[@]}"}; do
    if [ "${assignment%%|*}" = "$SHARD_INDEX" ]; then
        SHARD_NON_SERIAL_TESTS+=("${assignment#*|}")
    fi
done

SHARD_SERIAL_TESTS=()
for assignment in ${SERIAL_ASSIGNMENTS[@]+"${SERIAL_ASSIGNMENTS[@]}"}; do
    if [ "${assignment%%|*}" = "$SHARD_INDEX" ]; then
        SHARD_SERIAL_TESTS+=("${assignment#*|}")
    fi
done

if [ "$LIST_ONLY" = true ]; then
    if [ "${#SHARD_NON_SERIAL_TESTS[@]}" -gt 0 ]; then
        printf '%s\n' "${SHARD_NON_SERIAL_TESTS[@]}"
    fi
    if [ "${#SHARD_SERIAL_TESTS[@]}" -gt 0 ]; then
        printf '%s\n' "${SHARD_SERIAL_TESTS[@]}"
    fi
    exit 0
fi

RESULTS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-mirror-shard-results.XXXXXX")"

cleanup_results() {
    local rc="$?"
    rm -rf "$RESULTS_DIR"
    exit "$rc"
}

trap cleanup_results EXIT

terminate_suite_after_grace() {
    local pid="$1"
    kill -TERM -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    sleep 1
    kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
}

result_stem() {
    printf '%s' "$1" | tr '/.' '__'
}

run_suite() {
    local test_path="$1" stem suite_pid watchdog_pid rc=0 timeout_marker monitor_was_on=0
    stem="$(result_stem "$test_path")"
    timeout_marker="$RESULTS_DIR/$stem.timeout"
    case "$-" in *m*) monitor_was_on=1 ;; esac
    if [ "$monitor_was_on" -eq 0 ]; then set -m; fi
    # Keep hermetic suites isolated from caller-owned databases, credentials,
    # service URLs, and feature flags. This is the same minimal process
    # boundary owned by scripts/local-ci.sh::run_reachability_suite.
    env -i \
        PATH="$PATH" \
        HOME="${HOME:-}" \
        TMPDIR="${TMPDIR:-/tmp}" \
        USER="${USER:-}" \
        LOGNAME="${LOGNAME:-${USER:-}}" \
        SHELL="${SHELL:-/bin/bash}" \
        TERM="${TERM:-}" \
        LANG="${LANG:-C}" \
        LC_ALL="${LC_ALL:-}" \
        /bin/bash "$REPO_ROOT/$test_path" \
        </dev/null >"$RESULTS_DIR/$stem.log" 2>&1 &
    suite_pid="$!"
    (
        sleep "$SUITE_TIMEOUT_SECONDS"
        if kill -0 "$suite_pid" 2>/dev/null; then
            : > "$timeout_marker"
            terminate_suite_after_grace "$suite_pid"
        fi
    ) &
    watchdog_pid="$!"
    wait "$suite_pid" || rc=$?
    # Kill the watchdog's whole process group, not just its shell PID: the
    # backgrounded watchdog is a `sleep` in a subshell, and under job control
    # (set -m above) it leads its own group. A scalar `kill "$watchdog_pid"`
    # reaps the subshell but orphans the live `sleep` child until the full
    # timeout expires. Group-kill matches scripts/local-ci.sh:1270.
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    if [ -f "$timeout_marker" ]; then rc="$SUITE_TIMEOUT_RC"; fi
    if [ "$monitor_was_on" -eq 0 ]; then set +m; fi
    printf '%s\n' "$rc" > "$RESULTS_DIR/$stem.rc"
}

if [ "${#SHARD_NON_SERIAL_TESTS[@]}" -gt 0 ]; then
    for test_path in "${SHARD_NON_SERIAL_TESTS[@]}"; do
        while [ "$(jobs -pr | wc -l | tr -d '[:space:]')" -ge "$MAX_CONCURRENT_SUITES" ]; do
            sleep 0.1
        done
        run_suite "$test_path" &
    done
fi
wait || true

if [ "${#SHARD_SERIAL_TESTS[@]}" -gt 0 ]; then
    for test_path in "${SHARD_SERIAL_TESTS[@]}"; do
        run_suite "$test_path"
    done
fi

FAILURES=0
SHARD_EXECUTED_SUITE_COUNT=$((${#SHARD_NON_SERIAL_TESTS[@]} + ${#SHARD_SERIAL_TESTS[@]}))
report_suite_result() {
    local test_path="$1" stem rc
    stem="$(result_stem "$test_path")"
    rc="$(cat "$RESULTS_DIR/$stem.rc" 2>/dev/null || printf '1')"
    if [ "$rc" -ne 0 ]; then
        FAILURES=$((FAILURES + 1))
        if [ "$rc" -eq "$SUITE_TIMEOUT_RC" ]; then
            echo "mirror manifest shard: failing suite: $test_path (timed out, exit $rc)" >&2
        else
            echo "mirror manifest shard: failing suite: $test_path (exit $rc)" >&2
        fi
        if grep -E '^(FAIL|ERROR):' "$RESULTS_DIR/$stem.log" >&2; then
            :
        fi
        tail -n 30 "$RESULTS_DIR/$stem.log" >&2 || true
    fi
}

if [ "${#SHARD_NON_SERIAL_TESTS[@]}" -gt 0 ]; then
    for test_path in "${SHARD_NON_SERIAL_TESTS[@]}"; do
        report_suite_result "$test_path"
    done
fi

if [ "${#SHARD_SERIAL_TESTS[@]}" -gt 0 ]; then
    for test_path in "${SHARD_SERIAL_TESTS[@]}"; do
        report_suite_result "$test_path"
    done
fi

if [ "$FAILURES" -ne 0 ]; then
    echo "mirror manifest shard: $FAILURES suite(s) failed in shard $SHARD_INDEX/$SHARD_COUNT" >&2
    exit 1
fi

echo "mirror manifest shard: executed $SHARD_EXECUTED_SUITE_COUNT suite(s) in shard $SHARD_INDEX/$SHARD_COUNT" >&2
