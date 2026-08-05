#!/usr/bin/env bash
# Known-answer tests for scripts/probe_lane_branch_content.sh.
#
# Every case builds a real throwaway git repository and asserts the probe's
# EXACT stdout, not a substring — a classification that silently changes shape
# is a regression, because the counts in this repository's ROADMAP.md branch-debt
# row are quoted from that output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_lane_branch_content.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

# The message defaults to the content but is separately settable, and that is
# load-bearing for create_no_op_branch below: git commits are content-addressed,
# so two commits with the same tree, parent, author and message made inside the
# same second collapse to one SHA. Without distinct messages the "no-op branch"
# fixture silently produced a branch pointing at main's own commit.
commit_file() {
    local repo="$1" filename="$2" content="$3" message="${4:-$3}"
    printf '%s\n' "$content" > "$repo/$filename"
    git -C "$repo" add "$filename"
    git -C "$repo" commit -m "$message" >/dev/null
}

# A bare `main` with one commit. Each branch helper below builds off it.
make_fixture() {
    local repo="$1"
    git init -b main "$repo" >/dev/null 2>&1
    git -C "$repo" config user.name "Branch Content Test"
    git -C "$repo" config user.email "branch-content@example.test"
    commit_file "$repo" "main.txt" "main"
}

# A branch whose every change is already present on main. The classic shape:
# the lane's work was merged, then the branch merged main back into itself, so
# it is still "ahead" by a merge commit that contributes nothing.
create_no_op_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "shared.txt" "shared content" "on the branch"
    git -C "$repo" switch main >/dev/null 2>&1
    # main independently gains the identical content, so the branch adds nothing.
    # The distinct message keeps this a genuinely separate commit — see commit_file.
    commit_file "$repo" "shared.txt" "shared content" "on main"
    git -C "$repo" switch "$branch" >/dev/null 2>&1
    git -C "$repo" merge --no-edit -X ours main >/dev/null 2>&1
    git -C "$repo" switch main >/dev/null 2>&1
}

create_adds_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "salvageable.txt" "real work worth keeping"
    git -C "$repo" switch main >/dev/null 2>&1
}

create_conflicting_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "contested.txt" "branch version"
    git -C "$repo" switch main >/dev/null 2>&1
    commit_file "$repo" "contested.txt" "main version"
}

# Already an ancestor of main: not debt, and must not appear in the census.
create_merged_branch() {
    local repo="$1" branch="$2"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "landed.txt" "landed"
    git -C "$repo" switch main >/dev/null 2>&1
    git -C "$repo" merge --no-edit "$branch" >/dev/null 2>&1
}

run_probe() {
    local repo="$1"
    set +e
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo" bash "$PROBE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

test_reports_exact_classification_and_census() {
    local repo
    repo="$(mktemp -d)/repo"
    make_fixture "$repo"
    create_adds_branch "$repo" "batman/adds"
    create_conflicting_branch "$repo" "batman/conflicts"
    create_merged_branch "$repo" "batman/merged"
    create_no_op_branch "$repo" "batman/no_op"

    run_probe "$repo"

    # Sorted by branch name, so the order below is the contract, not incidental.
    assert_eq "$RUN_OUTPUT" \
"ADDS 1 file changed, 1 insertion(+): batman/adds
CONFLICT: batman/conflicts
NO_OP: batman/no_op
unmerged=3 NO_OP=1 ADDS=1 CONFLICT=1" \
        "each class is named exactly once and an already-merged branch is not counted"
    rm -rf "$(dirname "$repo")"
}

test_no_op_branch_fails_closed() {
    local repo
    repo="$(mktemp -d)/repo"
    make_fixture "$repo"
    create_no_op_branch "$repo" "batman/no_op"

    run_probe "$repo"

    # A NO_OP branch is provably deletable with zero judgement, so leaving one
    # in the corpus is the one condition this probe refuses.
    assert_eq "$RUN_EXIT_CODE" "1" "a provably deletable branch fails the probe closed"
    assert_contains "$RUN_OUTPUT" "NO_OP: batman/no_op" "the deletable branch is named"
    rm -rf "$(dirname "$repo")"
}

test_conflict_and_adds_alone_pass() {
    local repo
    repo="$(mktemp -d)/repo"
    make_fixture "$repo"
    create_adds_branch "$repo" "batman/adds"
    create_conflicting_branch "$repo" "batman/conflicts"

    run_probe "$repo"

    # ADDS and CONFLICT both need human judgement — salvage, rebase, or abandon —
    # so they are reported and must NOT fail the probe, or it would be red forever
    # and stop being read.
    assert_eq "$RUN_EXIT_CODE" "0" "branches needing judgement are reported, not refused"
    assert_contains "$RUN_OUTPUT" "unmerged=2 NO_OP=0 ADDS=1 CONFLICT=1" "census is exact"
    rm -rf "$(dirname "$repo")"
}

test_empty_corpus_is_vacuous() {
    local repo
    repo="$(mktemp -d)/repo"
    make_fixture "$repo"

    run_probe "$repo"

    # Fail closed rather than reporting a clean bill of health for a corpus the
    # probe never actually examined.
    assert_eq "$RUN_EXIT_CODE" "1" "an empty batman branch corpus fails closed"
    assert_eq "$RUN_OUTPUT" \
"unmerged=0 NO_OP=0 ADDS=0 CONFLICT=0
VACUOUS: no unmerged batman/* branches" \
        "empty corpus reports exact zero census and VACUOUS reason"
    rm -rf "$(dirname "$repo")"
}

test_all_merged_corpus_is_vacuous() {
    local repo
    repo="$(mktemp -d)/repo"
    make_fixture "$repo"
    create_merged_branch "$repo" "batman/merged"

    run_probe "$repo"

    # Branches exist but none is unmerged: the census is genuinely zero, and
    # saying so is different from having found nothing to look at.
    assert_eq "$RUN_EXIT_CODE" "1" "a corpus with nothing unmerged fails closed as vacuous"
    assert_contains "$RUN_OUTPUT" "VACUOUS: no unmerged batman/* branches" \
        "vacuity is stated rather than implied by silence"
    rm -rf "$(dirname "$repo")"
}

test_reports_exact_classification_and_census
test_no_op_branch_fails_closed
test_conflict_and_adds_alone_pass
test_empty_corpus_is_vacuous
test_all_merged_corpus_is_vacuous

run_test_summary
