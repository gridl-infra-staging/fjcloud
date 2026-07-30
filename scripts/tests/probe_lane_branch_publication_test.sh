#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_lane_branch_publication.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

configure_git_identity() {
    local repo="$1"
    git -C "$repo" config user.name "Lane Probe Test"
    git -C "$repo" config user.email "lane-probe@example.test"
}

commit_file() {
    local repo="$1" filename="$2" content="$3"
    printf '%s\n' "$content" > "$repo/$filename"
    git -C "$repo" add "$filename"
    git -C "$repo" commit -m "$content" >/dev/null
}

make_fixture() {
    local fixture_root="$1"
    local origin="$fixture_root/origin.git"
    local repo="$fixture_root/repo"

    git init --bare "$origin" >/dev/null 2>&1
    git init -b main "$repo" >/dev/null 2>&1
    configure_git_identity "$repo"
    git -C "$repo" remote add origin "$origin"
    commit_file "$repo" "main.txt" "main"
    git -C "$repo" push -u origin main >/dev/null 2>&1
    git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
}

create_pushed_branch() {
    local repo="$1" branch="${2:-batman/pushed}"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "pushed.txt" "$branch"
    git -C "$repo" push -u origin "$branch" >/dev/null 2>&1
}

create_local_ahead_branch() {
    local repo="$1" branch="${2:-batman/local_ahead}"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "shared.txt" "$branch shared"
    git -C "$repo" push -u origin "$branch" >/dev/null 2>&1
    commit_file "$repo" "local.txt" "$branch local"
}

create_diverged_branch() {
    local fixture_root="$1" branch="${2:-batman/diverged}"
    local repo="$fixture_root/repo"
    local peer="$fixture_root/peer"

    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "diverged_shared.txt" "$branch shared"
    git -C "$repo" push -u origin "$branch" >/dev/null 2>&1
    git clone "$fixture_root/origin.git" "$peer" >/dev/null 2>&1
    configure_git_identity "$peer"
    git -C "$peer" switch "$branch" >/dev/null 2>&1
    commit_file "$peer" "remote.txt" "$branch remote"
    git -C "$peer" push origin "$branch" >/dev/null 2>&1
    commit_file "$repo" "diverged_local.txt" "$branch local"
    git -C "$repo" fetch origin >/dev/null 2>&1
}

create_no_remote_branch() {
    local repo="$1" branch="${2:-batman/no_remote_branch}"
    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "no_remote.txt" "$branch"
}

create_merged_branch() {
    local repo="$1" branch="${2:-batman/merged}"
    git -C "$repo" branch "$branch" main
}

create_remote_only_ahead_branch() {
    local fixture_root="$1" branch="${2:-batman/remote_only_ahead}"
    local repo="$fixture_root/repo"
    local peer="$fixture_root/peer"

    git -C "$repo" branch "$branch" main
    git clone "$fixture_root/origin.git" "$peer" >/dev/null 2>&1
    configure_git_identity "$peer"
    git -C "$peer" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$peer" "remote_only.txt" "$branch remote"
    git -C "$peer" push origin "$branch" >/dev/null 2>&1
    git -C "$repo" fetch origin >/dev/null 2>&1
}

create_reachable_diverged_branch() {
    local fixture_root="$1" branch="${2:-batman/reachable_diverged}"
    local repo="$fixture_root/repo"
    local peer="$fixture_root/peer"

    git -C "$repo" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$repo" "reachable_local.txt" "$branch local"
    git -C "$repo" switch main >/dev/null 2>&1
    git -C "$repo" merge --ff-only "$branch" >/dev/null 2>&1

    git clone "$fixture_root/origin.git" "$peer" >/dev/null 2>&1
    configure_git_identity "$peer"
    git -C "$peer" switch -c "$branch" main >/dev/null 2>&1
    commit_file "$peer" "reachable_remote.txt" "$branch remote"
    git -C "$peer" push origin "$branch" >/dev/null 2>&1
    git -C "$repo" fetch origin >/dev/null 2>&1
}

run_probe() {
    local repo="$1"
    set +e
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo" bash "$PROBE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

test_reports_exact_classifications_and_census() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    create_pushed_branch "$fixture_root/repo"
    create_local_ahead_branch "$fixture_root/repo"
    create_diverged_branch "$fixture_root"
    create_no_remote_branch "$fixture_root/repo"
    create_merged_branch "$fixture_root/repo"

    run_probe "$fixture_root/repo"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a census containing unpublished branches fails"
    assert_eq "$RUN_OUTPUT" \
"DIVERGED local=1 remote=1: batman/diverged
LOCAL_AHEAD n=1: batman/local_ahead
MERGED: batman/merged
NO_REMOTE_BRANCH commits=1: batman/no_remote_branch
PUSHED: batman/pushed
branches=5 PUSHED=1 LOCAL_AHEAD=1 DIVERGED=1 NO_REMOTE_BRANCH=1 MERGED=1 REMOTE_ONLY_AHEAD=0" \
        "every branch and the hand-calculated census are deterministic and exact"
    rm -rf "$fixture_root"
}

test_each_unsafe_class_fails_closed() {
    local classification expected_output fixture_root

    for classification in LOCAL_AHEAD DIVERGED NO_REMOTE_BRANCH; do
        fixture_root="$(mktemp -d)"
        make_fixture "$fixture_root"
        case "$classification" in
            LOCAL_AHEAD)
                create_local_ahead_branch "$fixture_root/repo" "batman/unsafe"
                expected_output="LOCAL_AHEAD n=1: batman/unsafe
branches=1 PUSHED=0 LOCAL_AHEAD=1 DIVERGED=0 NO_REMOTE_BRANCH=0 MERGED=0 REMOTE_ONLY_AHEAD=0"
                ;;
            DIVERGED)
                create_diverged_branch "$fixture_root" "batman/unsafe"
                expected_output="DIVERGED local=1 remote=1: batman/unsafe
branches=1 PUSHED=0 LOCAL_AHEAD=0 DIVERGED=1 NO_REMOTE_BRANCH=0 MERGED=0 REMOTE_ONLY_AHEAD=0"
                ;;
            NO_REMOTE_BRANCH)
                create_no_remote_branch "$fixture_root/repo" "batman/unsafe"
                expected_output="NO_REMOTE_BRANCH commits=1: batman/unsafe
branches=1 PUSHED=0 LOCAL_AHEAD=0 DIVERGED=0 NO_REMOTE_BRANCH=1 MERGED=0 REMOTE_ONLY_AHEAD=0"
                ;;
        esac

        run_probe "$fixture_root/repo"

        assert_eq "$RUN_EXIT_CODE" "1" \
            "$classification returns the exact non-zero enforcement exit"
        assert_eq "$RUN_OUTPUT" "$expected_output" \
            "$classification reports the exact branch line and hand-calculated census"
        rm -rf "$fixture_root"
    done
}

test_safe_classes_pass() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    create_pushed_branch "$fixture_root/repo"
    create_merged_branch "$fixture_root/repo"

    run_probe "$fixture_root/repo"

    assert_eq "$RUN_EXIT_CODE" "0" "fully published and merged branches pass"
    assert_eq "$RUN_OUTPUT" \
"MERGED: batman/merged
PUSHED: batman/pushed
branches=2 PUSHED=1 LOCAL_AHEAD=0 DIVERGED=0 NO_REMOTE_BRANCH=0 MERGED=1 REMOTE_ONLY_AHEAD=0" \
        "safe census reports exact branch and class counts"
    rm -rf "$fixture_root"
}

test_remote_only_ahead_fails_closed_before_merged() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    create_remote_only_ahead_branch "$fixture_root"

    run_probe "$fixture_root/repo"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "remote-only-ahead branches fail closed"
    assert_eq "$RUN_OUTPUT" \
"REMOTE_ONLY_AHEAD n=1: batman/remote_only_ahead
branches=1 PUSHED=0 LOCAL_AHEAD=0 DIVERGED=0 NO_REMOTE_BRANCH=0 MERGED=0 REMOTE_ONLY_AHEAD=1" \
        "remote-only-ahead is not hidden by the MERGED short-circuit and is counted"
    rm -rf "$fixture_root"
}

test_reachable_diverged_fails_closed_before_merged() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    create_reachable_diverged_branch "$fixture_root"

    run_probe "$fixture_root/repo"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "reachable divergent branches fail closed"
    assert_eq "$RUN_OUTPUT" \
"DIVERGED local=1 remote=1: batman/reachable_diverged
branches=1 PUSHED=0 LOCAL_AHEAD=0 DIVERGED=1 NO_REMOTE_BRANCH=0 MERGED=0 REMOTE_ONLY_AHEAD=0" \
        "remote divergence is not hidden when the local tip is reachable from main"
    rm -rf "$fixture_root"
}

test_empty_corpus_is_vacuous() {
    local fixture_root
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"

    run_probe "$fixture_root/repo"

    assert_eq "$RUN_EXIT_CODE" "1" "an empty batman branch corpus fails closed"
    assert_eq "$RUN_OUTPUT" \
"branches=0 PUSHED=0 LOCAL_AHEAD=0 DIVERGED=0 NO_REMOTE_BRANCH=0 MERGED=0 REMOTE_ONLY_AHEAD=0
VACUOUS: no local batman/* branches" \
        "empty corpus reports exact zero census and VACUOUS reason"
    rm -rf "$fixture_root"
}

test_reports_exact_classifications_and_census
test_each_unsafe_class_fails_closed
test_safe_classes_pass
test_remote_only_ahead_fails_closed_before_merged
test_reachable_diverged_fails_closed_before_merged
test_empty_corpus_is_vacuous

run_test_summary
