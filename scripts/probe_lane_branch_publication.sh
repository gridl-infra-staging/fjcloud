#!/usr/bin/env bash
# Classify every local batman/* branch by its publication state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

BRANCH_COUNT=0
PUSHED_COUNT=0
LOCAL_AHEAD_COUNT=0
DIVERGED_COUNT=0
NO_REMOTE_BRANCH_COUNT=0
MERGED_COUNT=0
REMOTE_ONLY_AHEAD_COUNT=0

classify_branch() {
    local branch="$1"
    local ahead_of_main local_ahead remote_ahead remote_ref

    ahead_of_main="$(git -C "$REPO_ROOT" rev-list --count "main..$branch")"
    remote_ref="refs/remotes/origin/$branch"
    if git -C "$REPO_ROOT" show-ref --verify --quiet "$remote_ref"; then
        local_ahead="$(git -C "$REPO_ROOT" rev-list --count "origin/$branch..$branch")"
        remote_ahead="$(git -C "$REPO_ROOT" rev-list --count "$branch..origin/$branch")"

        if [ "$remote_ahead" -gt 0 ]; then
            if [ "$local_ahead" -gt 0 ]; then
                printf 'DIVERGED local=%s remote=%s: %s\n' \
                    "$local_ahead" "$remote_ahead" "$branch"
                DIVERGED_COUNT=$((DIVERGED_COUNT + 1))
            else
                printf 'REMOTE_ONLY_AHEAD n=%s: %s\n' "$remote_ahead" "$branch"
                REMOTE_ONLY_AHEAD_COUNT=$((REMOTE_ONLY_AHEAD_COUNT + 1))
            fi
            return
        fi
    elif [ "$ahead_of_main" -gt 0 ]; then
        printf 'NO_REMOTE_BRANCH commits=%s: %s\n' "$ahead_of_main" "$branch"
        NO_REMOTE_BRANCH_COUNT=$((NO_REMOTE_BRANCH_COUNT + 1))
        return
    fi

    if [ "$ahead_of_main" -eq 0 ]; then
        printf 'MERGED: %s\n' "$branch"
        MERGED_COUNT=$((MERGED_COUNT + 1))
        return
    fi

    if [ "$local_ahead" -eq 0 ] && [ "$remote_ahead" -eq 0 ]; then
        printf 'PUSHED: %s\n' "$branch"
        PUSHED_COUNT=$((PUSHED_COUNT + 1))
    elif [ "$local_ahead" -gt 0 ] && [ "$remote_ahead" -eq 0 ]; then
        printf 'LOCAL_AHEAD n=%s: %s\n' "$local_ahead" "$branch"
        LOCAL_AHEAD_COUNT=$((LOCAL_AHEAD_COUNT + 1))
    fi
}

while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    BRANCH_COUNT=$((BRANCH_COUNT + 1))
    classify_branch "$branch"
done < <(
    git -C "$REPO_ROOT" branch --list 'batman/*' --format='%(refname:short)' |
        LC_ALL=C sort
)

printf 'branches=%s PUSHED=%s LOCAL_AHEAD=%s DIVERGED=%s NO_REMOTE_BRANCH=%s MERGED=%s REMOTE_ONLY_AHEAD=%s\n' \
    "$BRANCH_COUNT" "$PUSHED_COUNT" "$LOCAL_AHEAD_COUNT" "$DIVERGED_COUNT" \
    "$NO_REMOTE_BRANCH_COUNT" "$MERGED_COUNT" "$REMOTE_ONLY_AHEAD_COUNT"

if [ "$BRANCH_COUNT" -eq 0 ]; then
    printf 'VACUOUS: no local batman/* branches\n'
    exit 1
fi

if [ "$LOCAL_AHEAD_COUNT" -gt 0 ] ||
    [ "$DIVERGED_COUNT" -gt 0 ] ||
    [ "$NO_REMOTE_BRANCH_COUNT" -gt 0 ] ||
    [ "$REMOTE_ONLY_AHEAD_COUNT" -gt 0 ]; then
    exit 1
fi
