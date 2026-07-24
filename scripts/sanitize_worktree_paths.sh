#!/usr/bin/env bash
# Scrub host-specific parallel-development worktree prefixes from tracked files.
# Default/--check lists leaks without mutation; --write removes prefixes in place.
# Postmortem: chats/suggestions/jun11_pm_fjcloud_dev__polished_beta_verify_chicken_egg_and_dirmap_guard_blindspot.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
MODE="--check"
WORKTREE_PATH_PREFIX_PATTERN="/Users/[a-zA-Z_][a-zA-Z0-9._-]*/parallel_development"
DEEP_WORKTREE_PATH_PATTERN="/Users/[a-zA-Z_][a-zA-Z0-9._-]*/parallel_development/[a-zA-Z0-9_]+_dev/[a-zA-Z0-9_]+/[a-zA-Z0-9_]+_dev/"
SHALLOW_WORKTREE_PATH_PATTERN="/Users/[a-zA-Z_][a-zA-Z0-9._-]*/parallel_development/[a-zA-Z0-9_]+_dev/[a-zA-Z0-9_]+/"
WORKTREE_PATH_PATTERN="$WORKTREE_PATH_PREFIX_PATTERN"

usage() {
    cat >&2 <<'EOF'
Usage: scripts/sanitize_worktree_paths.sh [--check|--write]

  --check  List tracked worktree-path leaks and exit non-zero when any exist.
  --write  Remove worktree prefixes from tracked files in place.
EOF
}

parse_args() {
    if [ "$#" -gt 1 ]; then
        usage
        exit 2
    fi

    if [ "$#" -eq 0 ]; then
        return
    fi

    case "$1" in
        --check | --write)
            MODE="$1"
            ;;
        *)
            usage
            exit 2
            ;;
    esac
}

stdin_has_paths() {
    [ -p /dev/stdin ]
}

resolve_repo_member_path() {
    local relative_path="$1"
    python3 - "$REPO_ROOT" "$relative_path" <<'PY'
from pathlib import Path
import sys

repo_root = Path(sys.argv[1]).resolve()
candidate = (repo_root / sys.argv[2]).resolve()
try:
    candidate.relative_to(repo_root)
except ValueError:
    raise SystemExit(1)

print(candidate)
PY
}

is_tracked_repo_path() {
    local relative_path="$1"
    git -C "$REPO_ROOT" ls-files -z --full-name -- "$relative_path" 2>/dev/null | \
        python3 -c 'import sys
target = sys.argv[1]
tracked = [path for path in sys.stdin.buffer.read().decode("utf-8", "surrogateescape").split("\0") if path]
raise SystemExit(0 if target in tracked else 1)' "$relative_path"
}

is_excluded_path() {
    case "$1" in
        decisions/* | docs/decisions/* | infra/pricing-calculator/stage_*_findings.md | chats/suggestions/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

path_contains_leak() {
    local relative_path="$1"
    local absolute_path

    absolute_path="$(resolve_repo_member_path "$relative_path")" || return 1
    is_tracked_repo_path "$relative_path" || return 1

    [ -f "$absolute_path" ] || return 1
    grep -Eq "$WORKTREE_PATH_PATTERN" "$absolute_path"
}

capture_stdin_leak_files() {
    local relative_path

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        is_excluded_path "$relative_path" && continue
        if ! resolve_repo_member_path "$relative_path" >/dev/null; then
            echo "[sanitize] skipped non-repo path $relative_path" >&2
            continue
        fi
        if ! is_tracked_repo_path "$relative_path"; then
            echo "[sanitize] skipped untracked path $relative_path" >&2
            continue
        fi
        if path_contains_leak "$relative_path"; then
            printf '%s\n' "$relative_path"
        fi
    done
}

capture_leak_files() {
    local grep_output
    local grep_status

    if stdin_has_paths; then
        capture_stdin_leak_files
        return 0
    fi

    set +e
    grep_output="$(
        git -C "$REPO_ROOT" grep -lE "$WORKTREE_PATH_PATTERN" -- \
            . \
            ':(exclude)decisions/**' \
            ':(exclude)docs/decisions/**' \
            ':(exclude)infra/pricing-calculator/stage_*_findings.md' \
            ':(exclude)chats/suggestions/**' \
            2>&1
    )"
    grep_status=$?
    set -e

    if [ "$grep_status" -eq 1 ]; then
        return 0
    fi

    if [ "$grep_status" -ne 0 ]; then
        printf '%s\n' "$grep_output" >&2
        exit "$grep_status"
    fi

    printf '%s\n' "$grep_output" | sed '/^$/d'
}

check_for_leaks() {
    local leak_files="$1"
    local relative_path

    if [ -z "$leak_files" ]; then
        echo "[sanitize] no worktree-path leaks to scrub"
        return 0
    fi

    while IFS= read -r relative_path; do
        [ -n "$relative_path" ] || continue
        if is_source_or_config_path "$relative_path"; then
            echo "[sanitize] requires manual cleanup $relative_path" >&2
        else
            echo "[sanitize] would rewrite $relative_path" >&2
        fi
    done <<EOF
$leak_files
EOF
    echo "[sanitize] CHECK: run 'bash scripts/sanitize_worktree_paths.sh --write' to scrub rewritable files" >&2
    return 1
}

is_source_or_config_path() {
    case "$1" in
        chats/* | chatting/* | docs/* | implemented/* | state/*)
            return 1
            ;;
        *.cjs | *.js | *.mjs | *.py | *.rs | *.sh | *.sql | *.svelte | *.toml | *.ts | *.tsx)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

sanitize_file() {
    local relative_path="$1"
    local absolute_path

    absolute_path="$(resolve_repo_member_path "$relative_path")" || {
        echo "[sanitize] skipped non-repo path $relative_path" >&2
        return 1
    }
    if ! is_tracked_repo_path "$relative_path"; then
        echo "[sanitize] skipped untracked path $relative_path" >&2
        return 1
    fi

    if is_source_or_config_path "$relative_path"; then
        return 0
    fi

    sed -i.bak -E \
        -e "s#${DEEP_WORKTREE_PATH_PATTERN}##g" \
        -e "s#${SHALLOW_WORKTREE_PATH_PATTERN}##g" \
        -e "s#${WORKTREE_PATH_PREFIX_PATTERN}#<worktree-root>#g" \
        "$absolute_path"
    rm -f "$absolute_path.bak"
}

write_sanitized_files() {
    local leak_files="$1"
    local scrubbed_count=0
    local relative_path

    if [ -z "$leak_files" ]; then
        echo "[sanitize] no worktree-path leaks to scrub"
        return 0
    fi

    while IFS= read -r relative_path; do
        if [ -n "$relative_path" ]; then
            if is_source_or_config_path "$relative_path"; then
                echo "[sanitize] skipped source/config path $relative_path" >&2
                continue
            fi
            if ! sanitize_file "$relative_path"; then
                continue
            fi
            echo "[sanitize] rewrote $relative_path"
            scrubbed_count=$((scrubbed_count + 1))
        fi
    done <<EOF
$leak_files
EOF
    echo "[sanitize] WRITE: scrubbed $scrubbed_count file(s)"
}

main() {
    local leak_files

    parse_args "$@"
    leak_files="$(capture_leak_files)"

    case "$MODE" in
        --check)
            check_for_leaks "$leak_files"
            ;;
        --write)
            write_sanitized_files "$leak_files"
            ;;
    esac
}

main "$@"
