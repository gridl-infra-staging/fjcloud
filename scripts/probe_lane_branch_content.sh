#!/usr/bin/env bash
# Classify every unmerged batman/* branch by WHAT MERGING IT WOULD ADD to main.
#
# This is deliberately a different question from the one
# scripts/probe_lane_branch_publication.sh answers. That probe asks "is this
# branch pushed?" and its remedy is "push it". This probe asks "does this branch
# still carry work?" and its remedies are delete, salvage, or rebase. Folding
# them into one script would give one command two exit meanings.
#
# Why it exists: the size of the stranded-branch backlog has been re-measured by
# hand repeatedly and produced a different answer each time (10, 17, 30, 17),
# because the usual shortcuts are all wrong. `git branch --list <stem>` stops
# being valid once batman GCs a merged branch. `git log origin/main..<branch>`
# counts a merge-main-into-branch commit as though it were work. `git diff
# main <branch>` reports main's own newer commits as deletions. The only
# question that survives is the counterfactual one, and git answers it directly:
# merge the branch in memory and compare the resulting tree to main's.
#
#   NO_OP    the merge result is byte-identical to main's tree. The branch is
#            provably deletable — no reading, no judgement.
#   ADDS     the merge succeeds and changes the tree. Salvage or merge; the
#            shortstat says how much is at stake.
#   CONFLICT git refuses the merge. Needs a rebase onto current main, or an
#            abandon decision. Never a silent skip.
#
# Exit 1 when a NO_OP branch survives (that is pure debt with a zero-judgement
# remedy) or when the corpus is vacuous. ADDS and CONFLICT are reported at
# exit 0 on purpose: they need a human decision, and a probe that stays red on
# work-in-progress stops being read.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

UNMERGED_COUNT=0
NO_OP_COUNT=0
ADDS_COUNT=0
CONFLICT_COUNT=0

MAIN_TREE="$(git -C "$REPO_ROOT" rev-parse 'main^{tree}')"

classify_branch() {
    local branch="$1" merged_tree

    # `git merge-tree --write-tree` performs the merge entirely in the object
    # database: no worktree, no index, no HEAD movement. That matters here —
    # this repository is a shared clone where moving HEAD strands co-resident
    # workers' in-flight commits.
    if ! merged_tree="$(git -C "$REPO_ROOT" merge-tree --write-tree main "$branch" 2>/dev/null)"; then
        printf 'CONFLICT: %s\n' "$branch"
        CONFLICT_COUNT=$((CONFLICT_COUNT + 1))
        return
    fi

    if [ "$merged_tree" = "$MAIN_TREE" ]; then
        printf 'NO_OP: %s\n' "$branch"
        NO_OP_COUNT=$((NO_OP_COUNT + 1))
        return
    fi

    # `git diff --shortstat <tree> <tree>` needs no worktree either. Trim its
    # leading whitespace so the output shape is stable enough to assert on.
    local shortstat
    shortstat="$(git -C "$REPO_ROOT" diff --shortstat "$MAIN_TREE" "$merged_tree" | sed 's/^ *//')"
    printf 'ADDS %s: %s\n' "$shortstat" "$branch"
    ADDS_COUNT=$((ADDS_COUNT + 1))
}

while IFS= read -r branch; do
    [ -n "$branch" ] || continue
    # Already an ancestor of main: not debt, and counting it would inflate the
    # backlog with branches that are simply awaiting GC.
    if git -C "$REPO_ROOT" merge-base --is-ancestor "$branch" main 2>/dev/null; then
        continue
    fi
    UNMERGED_COUNT=$((UNMERGED_COUNT + 1))
    classify_branch "$branch"
done < <(
    git -C "$REPO_ROOT" branch --list 'batman/*' --format='%(refname:short)' |
        LC_ALL=C sort
)

printf 'unmerged=%s NO_OP=%s ADDS=%s CONFLICT=%s\n' \
    "$UNMERGED_COUNT" "$NO_OP_COUNT" "$ADDS_COUNT" "$CONFLICT_COUNT"

if [ "$UNMERGED_COUNT" -eq 0 ]; then
    # Distinguish "examined the corpus and it is clean" from "found nothing to
    # examine". Only the first is evidence, and this branch is the second.
    printf 'VACUOUS: no unmerged batman/* branches\n'
    exit 1
fi

if [ "$NO_OP_COUNT" -gt 0 ]; then
    exit 1
fi
