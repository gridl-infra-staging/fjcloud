#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
GATE_HEADING="## Merged-union gate"
CAPTURED_TAIL_LINES=80
GATE_OUTPUT_PATH=""

cleanup() {
    if [ -n "$GATE_OUTPUT_PATH" ]; then
        rm -f "$GATE_OUTPUT_PATH"
    fi
}
trap cleanup EXIT

usage() {
    printf 'usage: bash scripts/close_batch_union_gate.sh <closeout-path>\n' >&2
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    return 1
}

canonical_existing_path() {
    local path="$1"
    local directory
    local filename

    [ -f "$path" ] || return 1
    [ ! -L "$path" ] || return 1
    directory="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
    filename="$(basename "$path")"
    printf '%s/%s\n' "$directory" "$filename"
}

canonical_temp_root() {
    local temp_root="${TMPDIR:-/tmp}"
    (cd "$temp_root" 2>/dev/null && pwd -P)
}

is_allowed_closeout_path() {
    local requested_path="$1"
    local canonical_path="$2"
    local temp_root

    if [[ "$requested_path" != /* ]]; then
        case "$requested_path" in
            chatting/*)
                [[ "$canonical_path" == "$REPO_ROOT"/chatting/* ]]
                return
                ;;
            *)
                return 1
                ;;
        esac
    fi

    temp_root="$(canonical_temp_root)" || return 1
    case "$canonical_path" in
        "$temp_root"/*/chatting/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

validate_closeout_path() {
    local requested_path="$1"
    local canonical_path

    canonical_path="$(canonical_existing_path "$requested_path")" ||
        fail "closeout must be an existing regular file: $requested_path" ||
        return 1
    is_allowed_closeout_path "$requested_path" "$canonical_path" ||
        fail "closeout must be repo-relative or temp-root chatting/: $requested_path" ||
        return 1
    [ -w "$canonical_path" ] ||
        fail "closeout is not writable: $requested_path" ||
        return 1
    printf '%s\n' "$canonical_path"
}

refuse_duplicate_section() {
    local closeout_path="$1"
    if grep -Fxq "$GATE_HEADING" "$closeout_path"; then
        fail "closeout already contains $GATE_HEADING"
        return 1
    fi
}

run_fast_gate() {
    local output_path="$1"
    local gate_exit_code

    (
        cd "$REPO_ROOT" &&
            bash scripts/local-ci.sh --fast
    ) > "$output_path" 2>&1
    gate_exit_code=$?
    return "$gate_exit_code"
}

append_gate_section() {
    local closeout_path="$1"
    local gate_output_path="$2"
    local gate_exit_code="$3"

    {
        printf '\n%s\n\n' "$GATE_HEADING"
        printf '%s\n' '- Command: `bash scripts/local-ci.sh --fast`'
        printf -- '- Exit code: `%s`\n\n' "$gate_exit_code"
        printf '%s\n' '### Captured tail' '' '```text'
        tail -n "$CAPTURED_TAIL_LINES" "$gate_output_path"
        printf '\n%s\n' '```'
    } >> "$closeout_path"
}

main() {
    if [ "$#" -ne 1 ]; then
        usage
        return 2
    fi

    local closeout_path
    closeout_path="$(validate_closeout_path "$1")" || return 1
    refuse_duplicate_section "$closeout_path" || return 1

    GATE_OUTPUT_PATH="$(mktemp "${TMPDIR:-/tmp}/fjcloud_merged_union_gate.XXXXXX")" ||
        fail "could not create gate output file" ||
        return 1

    local gate_exit_code=0
    run_fast_gate "$GATE_OUTPUT_PATH" || gate_exit_code=$?
    append_gate_section "$closeout_path" "$GATE_OUTPUT_PATH" "$gate_exit_code" ||
        fail "could not append merged-union gate evidence" ||
        return 1
    return "$gate_exit_code"
}

main "$@"
