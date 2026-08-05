#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"

CARGO_PREFIX="cd infra && cargo test -p api"
VITEST_PREFIX="cd web && npx vitest run"
# Stands in for a Markdown-escaped `\|` while a table row is split into cells.
ESCAPED_PIPE_SENTINEL=$'\x01'
RECORDED_COUNT_PREFIX_REGEX='^[[:space:]]*(\(([0-9]+)[[:space:]]+(tests?|selected[[:space:]]+(tests?|ignored[[:space:]]+DB[[:space:]]+tests?))\))'
RECORDED_COUNT_ANY_REGEX='\([0-9]+[[:space:]]+[^)]*tests?\)'
BASELINE_FILE=""
FOUND_COUNT=0
VERIFIED_COUNT=0
FAILED_COUNT=0

CARGO_CACHE_KEYS=()
CARGO_CACHE_STATUSES=()
CARGO_CACHE_OUTPUTS=()
CARGO_CACHE_INDEX=-1
CARGO_INVENTORY_STATUS=1
CARGO_INVENTORY_OUTPUT=""
CARGO_FILTER=""
CARGO_TARGET_KEY=""
CARGO_TARGET_ARGS=()
CARGO_FEATURE_ARGS=()
VITEST_RELATIVE_PATHS=()
VITEST_RESOLVED_PATHS=()
RECORDED_COUNT=""

usage() {
    cat <<'EOF'
Usage: scripts/security/probe_baseline_integrity.sh --baseline-file FILE

Verify recorded Cargo and Vitest test counts in a security control baseline.
EOF
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 2
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --baseline-file)
                [ "$#" -ge 2 ] || die "--baseline-file requires a path"
                [ -z "$BASELINE_FILE" ] || die "--baseline-file may only be supplied once"
                BASELINE_FILE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done

    [ -n "$BASELINE_FILE" ] || die "--baseline-file is required"
    [ -f "$BASELINE_FILE" ] || die "baseline file not found: $BASELINE_FILE"
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

extract_recorded_count() {
    local adjacent_text="$1"
    local first_match remainder

    RECORDED_COUNT=""
    if [[ ! "$adjacent_text" =~ $RECORDED_COUNT_PREFIX_REGEX ]]; then
        return 1
    fi

    first_match="${BASH_REMATCH[1]}"
    RECORDED_COUNT="${BASH_REMATCH[2]}"
    remainder="${adjacent_text#*"$first_match"}"
    if [[ "$remainder" =~ $RECORDED_COUNT_ANY_REGEX ]]; then
        RECORDED_COUNT=""
        return 1
    fi
}

render_result() {
    local control_name="$1"
    local runner="$2"
    local status="$3"
    local recorded_count="$4"
    local actual_count="$5"

    printf 'RESULT control="%s" runner=%s status=%s recorded=%s actual=%s\n' \
        "$control_name" "$runner" "$status" "$recorded_count" "$actual_count"
}

record_failure() {
    render_result "$1" "$2" "$3" "$4" "$5"
    FAILED_COUNT=$((FAILED_COUNT + 1))
}

record_count_result() {
    local control_name="$1"
    local runner="$2"
    local recorded_count="$3"
    local actual_count="$4"

    if [ "$actual_count" -eq 0 ]; then
        record_failure "$control_name" "$runner" ZERO_SELECTION "$recorded_count" "$actual_count"
    elif [ "$actual_count" -ne "$recorded_count" ]; then
        record_failure "$control_name" "$runner" COUNT_MISMATCH "$recorded_count" "$actual_count"
    else
        render_result "$control_name" "$runner" VERIFIED "$recorded_count" "$actual_count"
        VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
    fi
}

is_safe_cargo_value() {
    # A leading `-` would make the token an option to Cargo rather than the
    # target/filter value this position is meant to carry, so reject it here
    # instead of letting Cargo reinterpret it (mirrors the Vitest path guard).
    [[ "$1" != -* ]] || return 1
    [[ "$1" =~ ^[A-Za-z0-9_.:-]+$ ]]
}

parse_cargo_command() {
    local command="$1"
    local index=7
    local selector_seen=0
    local features_seen=0
    local filter_seen=0
    local separator_seen=0
    local token
    local -a tokens

    CARGO_FILTER=""
    CARGO_TARGET_KEY=""
    CARGO_TARGET_ARGS=()
    CARGO_FEATURE_ARGS=()
    read -r -a tokens <<< "$command"

    [ "${#tokens[@]}" -ge 8 ] || return 1
    [ "${tokens[0]}" = "cd" ] && [ "${tokens[1]}" = "infra" ] \
        && [ "${tokens[2]}" = "&&" ] && [ "${tokens[3]}" = "cargo" ] \
        && [ "${tokens[4]}" = "test" ] && [ "${tokens[5]}" = "-p" ] \
        && [ "${tokens[6]}" = "api" ] || return 1

    while [ "$index" -lt "${#tokens[@]}" ]; do
        token="${tokens[$index]}"
        case "$token" in
            --lib)
                [ "$selector_seen" -eq 0 ] || return 1
                CARGO_TARGET_ARGS=(--lib)
                CARGO_TARGET_KEY="lib"
                selector_seen=1
                index=$((index + 1))
                ;;
            --test)
                [ "$selector_seen" -eq 0 ] || return 1
                [ $((index + 1)) -lt "${#tokens[@]}" ] || return 1
                is_safe_cargo_value "${tokens[$((index + 1))]}" || return 1
                CARGO_TARGET_ARGS=(--test "${tokens[$((index + 1))]}")
                CARGO_TARGET_KEY="test:${tokens[$((index + 1))]}"
                selector_seen=1
                index=$((index + 2))
                ;;
            --features)
                [ "$features_seen" -eq 0 ] || return 1
                [ $((index + 1)) -lt "${#tokens[@]}" ] || return 1
                [ "${tokens[$((index + 1))]}" = "proptest-tests" ] || return 1
                CARGO_FEATURE_ARGS=(--features proptest-tests)
                features_seen=1
                index=$((index + 2))
                ;;
            --)
                [ "$separator_seen" -eq 0 ] || return 1
                [ $((index + 1)) -lt "${#tokens[@]}" ] || return 1
                case "${tokens[$((index + 1))]}" in
                    --list)
                        [ $((index + 2)) -eq "${#tokens[@]}" ] || return 1
                        ;;
                    --ignored)
                        [ "$filter_seen" -eq 1 ] || return 1
                        [ $((index + 3)) -eq "${#tokens[@]}" ] || return 1
                        [ "${tokens[$((index + 2))]}" = "--nocapture" ] || return 1
                        ;;
                    *)
                        return 1
                        ;;
                esac
                separator_seen=1
                index="${#tokens[@]}"
                ;;
            -*)
                return 1
                ;;
            *)
                [ "$filter_seen" -eq 0 ] || return 1
                is_safe_cargo_value "$token" || return 1
                CARGO_FILTER="$token"
                filter_seen=1
                index=$((index + 1))
                ;;
        esac
    done

    [ "$selector_seen" -eq 1 ] || return 1
    CARGO_TARGET_KEY="api|$CARGO_TARGET_KEY|features:${CARGO_FEATURE_ARGS[*]:-none}"
}

find_cached_cargo_inventory() {
    local cache_key="$1"
    local index

    CARGO_CACHE_INDEX=-1
    for ((index = 0; index < ${#CARGO_CACHE_KEYS[@]}; index++)); do
        if [ "${CARGO_CACHE_KEYS[$index]}" = "$cache_key" ]; then
            CARGO_CACHE_INDEX="$index"
            return 0
        fi
    done
    return 1
}

load_cargo_inventory() {
    local cache_key="$CARGO_TARGET_KEY"
    local inventory_output inventory_status cache_index

    if find_cached_cargo_inventory "$cache_key"; then
        CARGO_INVENTORY_STATUS="${CARGO_CACHE_STATUSES[$CARGO_CACHE_INDEX]}"
        CARGO_INVENTORY_OUTPUT="${CARGO_CACHE_OUTPUTS[$CARGO_CACHE_INDEX]}"
        return
    fi

    if inventory_output="$(
        cd "$REPO_ROOT/infra" \
            && cargo test -p api "${CARGO_TARGET_ARGS[@]}" \
                ${CARGO_FEATURE_ARGS[@]+"${CARGO_FEATURE_ARGS[@]}"} -- --list 2>&1
    )"; then
        inventory_status=0
    else
        inventory_status=$?
    fi

    cache_index="${#CARGO_CACHE_KEYS[@]}"
    CARGO_CACHE_KEYS[$cache_index]="$cache_key"
    CARGO_CACHE_STATUSES[$cache_index]="$inventory_status"
    CARGO_CACHE_OUTPUTS[$cache_index]="$inventory_output"
    CARGO_INVENTORY_STATUS="$inventory_status"
    CARGO_INVENTORY_OUTPUT="$inventory_output"
}

count_selected_cargo_tests() {
    local inventory="$1"
    local filter="$2"
    local line test_name
    local selected_count=0

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == *": test" ]] || continue
        test_name="${line%: test}"
        if [ -z "$filter" ] || [[ "$test_name" == *"$filter"* ]]; then
            selected_count=$((selected_count + 1))
        fi
    done <<< "$inventory"
    printf '%s\n' "$selected_count"
}

process_cargo_invocation() {
    local control_name="$1"
    local command="$2"
    local recorded_count="$3"
    local actual_count

    if ! parse_cargo_command "$command"; then
        record_failure "$control_name" CARGO UNPARSEABLE "$recorded_count" NA
        return
    fi

    load_cargo_inventory
    if [ "$CARGO_INVENTORY_STATUS" -ne 0 ]; then
        record_failure "$control_name" CARGO RUNNER_ERROR "$recorded_count" NA
        return
    fi

    actual_count="$(count_selected_cargo_tests "$CARGO_INVENTORY_OUTPUT" "$CARGO_FILTER")"
    record_count_result "$control_name" CARGO "$recorded_count" "$actual_count"
}

is_safe_vitest_path() {
    [[ "$1" != -* ]] || return 1
    [[ "$1" =~ ^[A-Za-z0-9_./-]+$ ]] || return 1
    case "$1" in
        *.test.js|*.test.jsx|*.test.ts|*.test.tsx|*.spec.js|*.spec.jsx|*.spec.ts|*.spec.tsx) ;;
        *) return 1 ;;
    esac
}

parse_vitest_paths() {
    local command="$1"
    local index
    local -a tokens

    VITEST_RELATIVE_PATHS=()
    read -r -a tokens <<< "$command"
    [ "${#tokens[@]}" -ge 7 ] || return 1
    [ "${tokens[0]}" = "cd" ] && [ "${tokens[1]}" = "web" ] \
        && [ "${tokens[2]}" = "&&" ] && [ "${tokens[3]}" = "npx" ] \
        && [ "${tokens[4]}" = "vitest" ] && [ "${tokens[5]}" = "run" ] \
        || return 1

    for ((index = 6; index < ${#tokens[@]}; index++)); do
        is_safe_vitest_path "${tokens[$index]}" || return 1
        VITEST_RELATIVE_PATHS+=("${tokens[$index]}")
    done
}

resolve_vitest_file() {
    local relative_path="$1"
    local candidate="$REPO_ROOT/web/$relative_path"
    local resolved_path

    [ -f "$candidate" ] || return 1
    resolved_path="$(
        python3 - "$candidate" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
    )" || return 1
    case "$resolved_path" in
        "$REPO_ROOT/web/"*) printf '%s\n' "$resolved_path" ;;
        *) return 1 ;;
    esac
}

resolve_vitest_paths() {
    local relative_path resolved_path

    VITEST_RESOLVED_PATHS=()
    for relative_path in "${VITEST_RELATIVE_PATHS[@]}"; do
        resolved_path="$(resolve_vitest_file "$relative_path")" || return 1
        VITEST_RESOLVED_PATHS+=("$resolved_path")
    done
}

parse_vitest_total() {
    local output="$1"
    local line parsed_total=""

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" == *Tests* ]] && [[ "$line" =~ \(([0-9]+)\) ]]; then
            parsed_total="${BASH_REMATCH[1]}"
        fi
    done <<< "$output"
    [ -n "$parsed_total" ] || return 1
    printf '%s\n' "$parsed_total"
}

process_vitest_invocation() {
    local control_name="$1"
    local command="$2"
    local recorded_count="$3"
    local runner_output actual_count

    if ! parse_vitest_paths "$command"; then
        record_failure "$control_name" VITEST UNPARSEABLE "$recorded_count" NA
        return
    fi
    if ! resolve_vitest_paths; then
        record_failure "$control_name" VITEST RUNNER_ERROR "$recorded_count" NA
        return
    fi
    # The baseline records the familiar `npx vitest` spelling, but the probe
    # must never let npx fetch an unpinned package when dependencies are
    # missing. Fail closed and require the repository-installed Vitest.
    if ! runner_output="$(
        cd "$REPO_ROOT/web" \
            && npx --no-install vitest run "${VITEST_RESOLVED_PATHS[@]}" 2>&1
    )"; then
        record_failure "$control_name" VITEST RUNNER_ERROR "$recorded_count" NA
        return
    fi
    if ! actual_count="$(parse_vitest_total "$runner_output")"; then
        record_failure "$control_name" VITEST RUNNER_ERROR "$recorded_count" NA
        return
    fi

    record_count_result "$control_name" VITEST "$recorded_count" "$actual_count"
}

process_recognized_invocation() {
    local control_name="$1"
    local command="$2"
    local adjacent_text="$3"
    local runner

    case "$command" in
        "$CARGO_PREFIX"*) runner=CARGO ;;
        "$VITEST_PREFIX"*) runner=VITEST ;;
        *) return ;;
    esac

    FOUND_COUNT=$((FOUND_COUNT + 1))
    if ! extract_recorded_count "$adjacent_text"; then
        record_failure "$control_name" "$runner" UNPARSEABLE UNKNOWN NA
        return
    fi

    if [ "$runner" = CARGO ]; then
        process_cargo_invocation "$control_name" "$command" "$RECORDED_COUNT"
    else
        process_vitest_invocation "$control_name" "$command" "$RECORDED_COUNT"
    fi
}

process_verify_cell() {
    local control_name="$1"
    local remaining="$2"
    local command adjacent_text

    while [[ "$remaining" == *\`* ]]; do
        remaining="${remaining#*\`}"
        [[ "$remaining" == *\`* ]] || break
        command="${remaining%%\`*}"
        remaining="${remaining#*\`}"
        adjacent_text="${remaining%%\`*}"
        process_recognized_invocation "$control_name" "$command" "$adjacent_text"
    done
}

restore_escaped_pipes() {
    printf '%s\n' "${1//$ESCAPED_PIPE_SENTINEL/\\|}"
}

process_baseline() {
    local line delimiter_only_line ignored control_name status owner verify trailing

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" == \|* ]] || continue
        # Markdown requires a literal pipe inside a table cell to be written
        # `\|`, so splitting on every `|` truncates such a cell and silently
        # drops any runner command after it — the exact silent-skip this probe
        # exists to prevent. Hide the escaped form behind a sentinel that
        # cannot occur in a text file, split on the real delimiters, then put
        # it back before scanning the cell.
        delimiter_only_line="${line//\\|/$ESCAPED_PIPE_SENTINEL}"
        IFS='|' read -r ignored control_name status owner verify trailing \
            <<< "$delimiter_only_line"
        control_name="$(trim_whitespace "$(restore_escaped_pipes "$control_name")")"
        process_verify_cell "$control_name" "$(restore_escaped_pipes "$verify")"
    done < "$BASELINE_FILE"
}

render_summary() {
    printf 'SUMMARY found=%s verified=%s failed=%s\n' \
        "$FOUND_COUNT" "$VERIFIED_COUNT" "$FAILED_COUNT"
    if [ "$FOUND_COUNT" -eq 0 ]; then
        printf 'VERDICT: VACUOUS\n'
        return 1
    fi
    if [ "$FAILED_COUNT" -ne 0 ] || [ "$VERIFIED_COUNT" -ne "$FOUND_COUNT" ]; then
        printf 'VERDICT: FAIL\n'
        return 1
    fi
    printf 'VERDICT: PASS\n'
}

parse_arguments "$@"
process_baseline
render_summary
