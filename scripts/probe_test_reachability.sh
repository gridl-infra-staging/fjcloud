#!/usr/bin/env bash
# Audit whether every top-level scripts/tests/*_test.sh file is reachable from
# a repository execution root or has an explicit manual/quarantine owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# shellcheck source=scripts/lib/registry_owner.sh
source "$SCRIPT_DIR/lib/registry_owner.sh"
TEST_DIR="$REPO_ROOT/scripts/tests"
MANUAL_REGISTRY="$TEST_DIR/manual_only_tests.txt"
QUARANTINE_REGISTRY="$TEST_DIR/quarantined_tests.txt"

CORPUS=()
ROOTS=()
REACHABLE=()
MANUAL_PATHS=()
MANUAL_REASONS=()
QUARANTINE_PATHS=()
QUARANTINE_REASONS=()
UNACCOUNTED=()
DEFECT_COUNT=0

WORK_DIR="$(mktemp -d)"
CONTENT_FILE="$WORK_DIR/reachable_content.txt"
trap 'rm -rf "$WORK_DIR"' EXIT
: > "$CONTENT_FILE"

array_contains() {
    local needle="$1"
    shift
    local item
    # Callers pass array expansions guarded with the "${arr[@]+...}" idiom so an
    # empty array contributes zero args here (bash 3.2 trips set -u otherwise).
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

trim_space() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

discover_corpus() {
    local path
    if [ ! -d "$TEST_DIR" ]; then
        return
    fi
    while IFS= read -r path; do
        CORPUS+=("scripts/tests/$(basename "$path")")
    done < <(find "$TEST_DIR" -maxdepth 1 -type f -name '*_test.sh' -print | LC_ALL=C sort)
}

discover_roots() {
    local path
    while IFS= read -r path; do
        ROOTS+=("$path")
    done < <(
        {
            if [ -d "$REPO_ROOT/scripts" ]; then
                find "$REPO_ROOT/scripts" \
                    -path "$TEST_DIR" -prune -o \
                    -type f \( -name '*.sh' -o -name '*.py' -o -name '*.mjs' \) -print
            fi
            if [ -d "$REPO_ROOT/.github" ]; then
                find "$REPO_ROOT/.github" -type f -print
            fi
            if [ -f "$REPO_ROOT/Makefile" ]; then
                printf '%s\n' "$REPO_ROOT/Makefile"
            fi
        } | LC_ALL=C sort -u
    )
}

append_non_comment_content() {
    local path="$1"
    # The repository's executable roots use shell/Python '#' comments and
    # JavaScript '//' comments. Comment-only mentions are documentation, not
    # execution edges, so neither form is allowed to manufacture reachability.
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

is_corpus_path() {
    array_contains "$1" ${CORPUS[@]+"${CORPUS[@]}"}
}

load_registry() {
    local registry_path="$1" kind="$2"
    local line trimmed rel_path reason line_number=0

    if [ ! -f "$registry_path" ]; then
        printf 'ERROR: %s registry file missing: %s\n' "$kind" "${registry_path#"$REPO_ROOT/"}"
        DEFECT_COUNT=$((DEFECT_COUNT + 1))
        return
    fi

    while IFS= read -r line || [ -n "$line" ]; do
        line_number=$((line_number + 1))
        trimmed="$(trim_space "$line")"
        if [ -z "$trimmed" ] || [[ "$trimmed" = \#* ]]; then
            continue
        fi

        if [[ "$trimmed" =~ ^(scripts/tests/[^[:space:]#]+)[[:space:]]+#[[:space:]]*(.*)$ ]]; then
            rel_path="${BASH_REMATCH[1]}"
            reason="$(trim_space "${BASH_REMATCH[2]}")"
        elif [[ "$trimmed" =~ ^(scripts/tests/[^[:space:]#]+) ]]; then
            rel_path="${BASH_REMATCH[1]}"
            reason=""
        else
            printf 'ERROR: malformed %s registry row %s:%s: %s\n' \
                "$kind" "${registry_path#"$REPO_ROOT/"}" "$line_number" "$trimmed"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
            continue
        fi

        if [ -z "$reason" ]; then
            printf 'ERROR: %s reason is required: %s\n' "$kind" "$rel_path"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
            continue
        fi
        if ! is_corpus_path "$rel_path"; then
            printf 'ERROR: %s entry references missing test: %s\n' "$kind" "$rel_path"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
            continue
        fi
        if [ "$kind" = "quarantine" ] && ! registry_reason_has_owner "$REPO_ROOT" "$reason"; then
            printf 'ERROR: quarantine owner is required: %s # %s\n' "$rel_path" "$reason"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
            continue
        fi

        if [ "$kind" = "allowlist" ]; then
            if ! array_contains "$rel_path" ${MANUAL_PATHS[@]+"${MANUAL_PATHS[@]}"}; then
                MANUAL_PATHS+=("$rel_path")
                MANUAL_REASONS+=("$reason")
            fi
        elif ! array_contains "$rel_path" ${QUARANTINE_PATHS[@]+"${QUARANTINE_PATHS[@]}"}; then
            QUARANTINE_PATHS+=("$rel_path")
            QUARANTINE_REASONS+=("$reason")
        fi
    done < "$registry_path"
}

compute_reachability() {
    local path rel_path basename changed=1

    for path in ${ROOTS[@]+"${ROOTS[@]}"}; do
        append_non_comment_content "$path"
    done

    # Fixed-point closure is required because a root can invoke test A while
    # test A is the only place that invokes test B. The repository uses literal
    # shell-test filenames in these invocations, verified 2026-07-27, so a
    # bounded filename text match is sufficient without introducing a parser.
    # Newly reached test content is appended exactly once; each pass discovers
    # every corpus filename exposed by the closure accumulated so far.
    while [ "$changed" -eq 1 ]; do
        changed=0
        for rel_path in ${CORPUS[@]+"${CORPUS[@]}"}; do
            if array_contains "$rel_path" ${REACHABLE[@]+"${REACHABLE[@]}"}; then
                continue
            fi
            basename="${rel_path##*/}"
            if grep -Fq -- "$basename" "$CONTENT_FILE"; then
                REACHABLE+=("$rel_path")
                append_non_comment_content "$REPO_ROOT/$rel_path"
                changed=1
            fi
        done
    done
}

classify_unaccounted() {
    local rel_path
    for rel_path in ${CORPUS[@]+"${CORPUS[@]}"}; do
        if array_contains "$rel_path" ${REACHABLE[@]+"${REACHABLE[@]}"} ||
            array_contains "$rel_path" ${MANUAL_PATHS[@]+"${MANUAL_PATHS[@]}"} ||
            array_contains "$rel_path" ${QUARANTINE_PATHS[@]+"${QUARANTINE_PATHS[@]}"}; then
            continue
        fi
        UNACCOUNTED+=("$rel_path")
    done
}

validate_classification_boundaries() {
    local rel_path

    for rel_path in ${REACHABLE[@]+"${REACHABLE[@]}"}; do
        if array_contains "$rel_path" ${MANUAL_PATHS[@]+"${MANUAL_PATHS[@]}"}; then
            printf 'ERROR: reachable test cannot also be manual-only: %s\n' "$rel_path"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
        fi
        if array_contains "$rel_path" ${QUARANTINE_PATHS[@]+"${QUARANTINE_PATHS[@]}"}; then
            printf 'ERROR: reachable test cannot also be quarantined: %s\n' "$rel_path"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
        fi
    done

    for rel_path in ${MANUAL_PATHS[@]+"${MANUAL_PATHS[@]}"}; do
        if array_contains "$rel_path" ${QUARANTINE_PATHS[@]+"${QUARANTINE_PATHS[@]}"}; then
            printf 'ERROR: manual-only test cannot also be quarantined: %s\n' "$rel_path"
            DEFECT_COUNT=$((DEFECT_COUNT + 1))
        fi
    done
}

print_report() {
    local index rel_path

    for rel_path in ${REACHABLE[@]+"${REACHABLE[@]}"}; do
        printf 'REACHABLE: %s\n' "$rel_path"
    done
    for ((index = 0; index < ${#MANUAL_PATHS[@]}; index++)); do
        printf 'ALLOWLISTED: %s # %s\n' "${MANUAL_PATHS[$index]}" "${MANUAL_REASONS[$index]}"
    done
    if [ "${#QUARANTINE_PATHS[@]}" -eq 0 ]; then
        printf 'QUARANTINED: none\n'
    else
        for ((index = 0; index < ${#QUARANTINE_PATHS[@]}; index++)); do
            printf 'QUARANTINED: %s # %s\n' \
                "${QUARANTINE_PATHS[$index]}" "${QUARANTINE_REASONS[$index]}"
        done
    fi
    for rel_path in ${UNACCOUNTED[@]+"${UNACCOUNTED[@]}"}; do
        printf 'ERROR: not reachable: %s\n' "$rel_path"
    done

    printf 'corpus=%s reachable=%s allowlisted=%s quarantined=%s unaccounted=%s\n' \
        "${#CORPUS[@]}" "${#REACHABLE[@]}" "${#MANUAL_PATHS[@]}" \
        "${#QUARANTINE_PATHS[@]}" "${#UNACCOUNTED[@]}"
}

discover_corpus
discover_roots
load_registry "$MANUAL_REGISTRY" "allowlist"
load_registry "$QUARANTINE_REGISTRY" "quarantine"
compute_reachability
classify_unaccounted
validate_classification_boundaries
print_report

if [ "${#CORPUS[@]}" -eq 0 ]; then
    printf 'VACUOUS: corpus contains no scripts/tests/*_test.sh files\n'
    exit 1
fi
if [ "$DEFECT_COUNT" -gt 0 ] || [ "${#UNACCOUNTED[@]}" -gt 0 ]; then
    exit 1
fi

printf 'OK: every corpus test is reachable or explicitly classified\n'
