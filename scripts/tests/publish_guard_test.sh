#!/usr/bin/env bash
# Contract tests for scripts/lib/publish_guard.sh and its wiring into
# .debbie/post-sync.sh.
#
# These are behavioural tests against real throwaway git repositories, not
# string matches against the guard's source. Each case builds a dev repo in a
# specific git state, calls the guard, and asserts the decision. A test that
# only grepped the script for "merge-base" would keep passing if the predicate
# were inverted; these do not.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GUARD_LIB="$REPO_ROOT/scripts/lib/publish_guard.sh"
POST_SYNC_HOOK="$REPO_ROOT/.debbie/post-sync.sh"

source "$REPO_ROOT/scripts/tests/lib/assertions.sh"
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"

# The guard's refusal status. Asserting this exact code rather than "non-zero"
# is deliberate: a missing or unsourceable guard exits 127, a bash syntax error
# exits 2, and a plain `return 1` is indistinguishable from any other failure.
# Every one of those would satisfy a `!= 0` assertion and let a refuse-path test
# pass while proving nothing. Pinning 3 means these tests fail if the guard
# stops existing, which is the failure mode they are written to catch.
readonly EXPECTED_REFUSAL_STATUS=3

# Deterministic identity + config so these repos build identically on any host
# and never inherit the operator's global git settings (notably a global
# init.defaultBranch that is not `main`, which would silently skew every case).
git_quiet() {
    git -c user.name=publish-guard-test \
        -c user.email=publish-guard-test@example.invalid \
        -c commit.gpgsign=false \
        -c init.defaultBranch=main \
        "$@" >/dev/null 2>&1
}

# Build a dev repo whose `origin` is a real bare repo on disk, with one commit
# on `main` already pushed. This is the "clean, published" baseline that every
# case below mutates in exactly one way.
new_dev_repo_with_pushed_main() {
    local root
    root="$(mktemp -d)"

    git_quiet init --bare "$root/origin.git"
    git_quiet init "$root/dev"
    git_quiet -C "$root/dev" remote add origin "$root/origin.git"

    # Carry the real guard into the fixture. The post-sync hook sources it from
    # "$DEBBIE_DEV_ROOT/scripts/lib/publish_guard.sh", so a fixture without it
    # would exercise a dev root that cannot exist in practice and would prove
    # nothing about the wiring.
    mkdir -p "$root/dev/scripts/lib"
    cp "$GUARD_LIB" "$root/dev/scripts/lib/publish_guard.sh"

    echo "baseline" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" add file.txt scripts/lib/publish_guard.sh
    git_quiet -C "$root/dev" commit -m "baseline"
    # `-u` so the local repo gains an origin/main remote-tracking ref, which is
    # the ref the guard's ancestry check resolves against.
    git_quiet -C "$root/dev" push -u origin main

    echo "$root"
}

# Run the guard against a dev root, capturing exit status and stderr separately.
# stderr is the guard's operator-facing channel, so cases assert on it directly.
run_guard() {
    local dev_root="$1"
    local stderr_path="$2"
    local exit_code=0

    (
        set +euo pipefail
        # shellcheck source=../lib/publish_guard.sh
        source "$GUARD_LIB"
        assert_dev_head_is_publishable "$dev_root"
    ) >/dev/null 2>"$stderr_path" || exit_code=$?

    return "$exit_code"
}

test_guard_allows_pushed_main() {
    local root
    root="$(new_dev_repo_with_pushed_main)"
    local stderr_path="$root/stderr.txt"

    local exit_code=0
    run_guard "$root/dev" "$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "0" "guard should allow publishing when HEAD is pushed main"

    rm -rf "$root"
}

test_guard_refuses_unmerged_lane_branch() {
    local root
    root="$(new_dev_repo_with_pushed_main)"
    local stderr_path="$root/stderr.txt"

    # The exact shape that published unmerged code on 2026-08-05: a matt lane
    # worktree pinned to its own batman/<lane> branch, carrying a commit that
    # has never reached origin/main.
    git_quiet -C "$root/dev" checkout -b batman/example_lane
    echo "lane-only change" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" commit -am "lane-only commit"

    local exit_code=0
    run_guard "$root/dev" "$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "$EXPECTED_REFUSAL_STATUS" \
        "guard should refuse publishing from an unmerged lane branch"

    local stderr_text
    stderr_text="$(cat "$stderr_path")"
    assert_contains "$stderr_text" "batman/example_lane" \
        "refusal should name the branch so the caller knows which ref was rejected"

    rm -rf "$root"
}

test_guard_refuses_main_that_is_not_pushed() {
    local root
    root="$(new_dev_repo_with_pushed_main)"
    local stderr_path="$root/stderr.txt"

    # Being on `main` is not sufficient. An unpushed commit is unreachable from
    # origin/main, so the dev_sha debbie stamps into the mirror manifest would
    # point at a commit no one else can resolve. Pushed matters as much as
    # merged.
    echo "local only" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" commit -am "unpushed commit on main"

    local exit_code=0
    run_guard "$root/dev" "$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "$EXPECTED_REFUSAL_STATUS" \
        "guard should refuse publishing from main when HEAD is not pushed"

    rm -rf "$root"
}

test_guard_allows_detached_head_at_pushed_sha() {
    local root
    root="$(new_dev_repo_with_pushed_main)"
    local stderr_path="$root/stderr.txt"

    # This is the documented deploy-from-a-lane recipe: a throwaway worktree
    # checked out at a pushed origin/main SHA has a detached HEAD. The guard
    # must allow it, otherwise the one correct way for a lane to publish would
    # be rejected and the rule would have no executable escape.
    local pushed_sha
    pushed_sha="$(git -C "$root/dev" rev-parse origin/main)"
    git_quiet -C "$root/dev" checkout --detach "$pushed_sha"

    local exit_code=0
    run_guard "$root/dev" "$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "0" \
        "guard should allow a detached HEAD sitting on a pushed origin/main SHA"

    rm -rf "$root"
}

test_guard_refuses_when_origin_main_is_absent() {
    local root
    root="$(mktemp -d)"
    local stderr_path="$root/stderr.txt"

    # No remote at all: the guard cannot establish that HEAD is published.
    # Indeterminate must not read as healthy, so this refuses rather than
    # falling through to an allow.
    git_quiet init "$root/dev"
    echo "orphan" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" add file.txt
    git_quiet -C "$root/dev" commit -m "orphan commit"

    local exit_code=0
    run_guard "$root/dev" "$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "$EXPECTED_REFUSAL_STATUS" \
        "guard should refuse when origin/main cannot be resolved"

    rm -rf "$root"
}

test_guard_escape_hatch_allows_but_warns_loudly() {
    local root
    root="$(new_dev_repo_with_pushed_main)"
    local stderr_path="$root/stderr.txt"

    git_quiet -C "$root/dev" checkout -b batman/example_lane
    echo "lane-only change" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" commit -am "lane-only commit"

    local exit_code=0
    (
        set +euo pipefail
        # shellcheck source=../lib/publish_guard.sh
        source "$GUARD_LIB"
        FJCLOUD_ALLOW_UNMERGED_PUBLISH=1 assert_dev_head_is_publishable "$root/dev"
    ) >/dev/null 2>"$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "0" \
        "explicit FJCLOUD_ALLOW_UNMERGED_PUBLISH=1 should permit an otherwise-refused publish"

    # An escape hatch that is silent is a hole. It has to announce itself on
    # stderr, and it has to name the SHA it let through.
    local stderr_text
    stderr_text="$(cat "$stderr_path")"
    assert_contains "$stderr_text" "FJCLOUD_ALLOW_UNMERGED_PUBLISH" \
        "bypass should name the override that permitted it"

    local head_sha
    head_sha="$(git -C "$root/dev" rev-parse HEAD)"
    assert_contains "$stderr_text" "$head_sha" \
        "bypass warning should name the exact SHA it published"

    rm -rf "$root"
}

test_post_sync_hook_refuses_before_publishing() {
    local root
    root="$(new_dev_repo_with_pushed_main)"

    git_quiet -C "$root/dev" checkout -b batman/example_lane
    echo "lane-only change" > "$root/dev/file.txt"
    git_quiet -C "$root/dev" commit -am "lane-only commit"

    # A stand-in mirror clone. If the guard is wired first, the hook exits
    # before scrai-strip, the openapi regeneration and the commit+push, so this
    # test never touches cargo or the network and stays fast.
    local target_root="$root/mirror"
    git_quiet init "$target_root"
    echo "mirror baseline" > "$target_root/file.txt"
    git_quiet -C "$target_root" add file.txt
    git_quiet -C "$target_root" commit -m "mirror baseline"

    local commits_before
    commits_before="$(git -C "$target_root" rev-list --count HEAD)"

    local stderr_path="$root/hook-stderr.txt"
    local exit_code=0
    DEBBIE_TARGET="staging" \
    DEBBIE_TARGET_ROOT="$target_root" \
    DEBBIE_DEV_ROOT="$root/dev" \
        bash "$POST_SYNC_HOOK" >/dev/null 2>"$stderr_path" || exit_code=$?

    assert_eq "$exit_code" "$EXPECTED_REFUSAL_STATUS" \
        "post-sync hook should propagate the guard's refusal status"

    local stderr_text
    stderr_text="$(cat "$stderr_path")"
    assert_contains "$stderr_text" "batman/example_lane" \
        "hook failure should surface the guard's refusal, not an unrelated error"

    # The load-bearing assertion: publication did not happen. The guard is
    # worthless if it fails after the mirror commit has already been made.
    local commits_after
    commits_after="$(git -C "$target_root" rev-list --count HEAD)"
    assert_eq "$commits_after" "$commits_before" \
        "refused sync must not create a mirror commit"

    rm -rf "$root"
}

test_refused_sync_leaves_no_leftovers_for_a_later_sync_to_publish() {
    local root
    root="$(new_dev_repo_with_pushed_main)"

    git_quiet -C "$root/dev" checkout -b batman/example_lane
    git_quiet -C "$root/dev" commit --allow-empty -m "lane-only commit"

    local target_root="$root/mirror"
    git_quiet init "$target_root"
    echo "published content" > "$target_root/tracked.txt"
    git_quiet -C "$target_root" add tracked.txt
    git_quiet -C "$target_root" commit -m "mirror baseline"

    # Stand in for what debbie has already done by the time the hook runs: it
    # has copied the dev tree over the mirror working tree. A refused sync must
    # not leave these behind, because the mirror's own publish step is
    # `git add -A` and debbie's prune only considers TRACKED paths — so an
    # untracked leftover from a refused sync would be committed and published
    # by the next legitimate sync.
    echo "lane-only content" > "$target_root/tracked.txt"
    echo "file that exists only on the lane branch" > "$target_root/lane_only.txt"

    local exit_code=0
    DEBBIE_TARGET="staging" \
    DEBBIE_TARGET_ROOT="$target_root" \
    DEBBIE_DEV_ROOT="$root/dev" \
        bash "$POST_SYNC_HOOK" >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "$EXPECTED_REFUSAL_STATUS" \
        "refused sync should still exit with the guard's refusal status"

    local dirty
    dirty="$(git -C "$target_root" status --porcelain --untracked-files=all)"
    assert_eq "$dirty" "" \
        "refused sync must leave the mirror clean, so no leftover reaches a later sync's git add -A"

    local restored
    restored="$(cat "$target_root/tracked.txt")"
    assert_eq "$restored" "published content" \
        "refused sync must restore tracked mirror content to its last published state"

    rm -rf "$root"
}

echo "=== publish guard contract tests ==="
test_guard_allows_pushed_main
test_guard_refuses_unmerged_lane_branch
test_guard_refuses_main_that_is_not_pushed
test_guard_allows_detached_head_at_pushed_sha
test_guard_refuses_when_origin_main_is_absent
test_guard_escape_hatch_allows_but_warns_loudly
test_post_sync_hook_refuses_before_publishing
test_refused_sync_leaves_no_leftovers_for_a_later_sync_to_publish
run_test_summary
