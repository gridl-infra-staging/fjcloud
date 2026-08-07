#!/usr/bin/env bash
# probe_ssot_currency_test.sh — contract test for scripts/probe_ssot_currency.sh.
#
# The probe under test answers one question: how many lane merges has
# `origin/main` taken since the newest reconciliation `ROADMAP.md` claims to
# describe. These cases exist because the probe's whole value is that it CAN
# report red; every fail-closed arm below is a case where an earlier
# doc-currency check would have printed a reassuring line instead.
#
# Fixture shape: a bare origin plus a working clone, so `origin/main` is a real
# remote-tracking ref rather than a local alias. Lane merges are real merge
# commits whose subject carries the `batman merge_worktree` marker the probe
# counts, and each fixture also creates non-lane commits so a probe that counted
# every commit instead of every lane merge would report the wrong number.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_ssot_currency.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

configure_git_identity() {
    local repo="$1"
    git -C "$repo" config user.name "SSOT Currency Test"
    git -C "$repo" config user.email "ssot-currency@example.test"
}

commit_file() {
    local repo="$1" filename="$2" content="$3" subject="$4"
    printf '%s\n' "$content" >"$repo/$filename"
    git -C "$repo" add -- "$filename"
    git -C "$repo" commit -m "$subject" >/dev/null
}

# Write a ROADMAP.md whose reconciliation headers name the given SHAs, in the
# same prose shape the live ledger uses. Passing several SHAs is how the
# multi-header cases assert the probe picks the closest one rather than the
# first or last line it happens to match.
write_roadmap() {
    local repo="$1"
    shift
    {
        printf '# Roadmap\n\n'
        local sha
        for sha in "$@"; do
            printf '**RECONCILED 2026-08-06 ~13:00Z against `origin/main` `%s`; this paragraph supersedes older reconciliation headers only where it names the same fact.** Body text.\n' "$sha"
        done
        printf '\n## Active\n\n## Planned\n\n## Archive\n'
    } >"$repo/ROADMAP.md"
    git -C "$repo" add -- ROADMAP.md
    git -C "$repo" commit -m "docs: set reconciliation header" >/dev/null
}

# Create a merge commit carrying batman's marker, so the fixture exercises the
# real subject the probe greps for rather than a stand-in string.
create_lane_merge() {
    local repo="$1" lane="$2"
    git -C "$repo" switch -c "batman/$lane" main >/dev/null 2>&1
    commit_file "$repo" "$lane.txt" "$lane" "lane work for $lane"
    git -C "$repo" switch main >/dev/null 2>&1
    git -C "$repo" merge --no-ff "batman/$lane" \
        -m "batman merge_worktree: merge batman/$lane into main" >/dev/null
}

make_fixture() {
    local fixture_root="$1"
    local origin="$fixture_root/origin.git"
    local repo="$fixture_root/repo"

    git init --bare "$origin" >/dev/null 2>&1
    git init -b main "$repo" >/dev/null 2>&1
    configure_git_identity "$repo"
    git -C "$repo" remote add origin "$origin"
    commit_file "$repo" "seed.txt" "seed" "seed"
    git -C "$repo" push -u origin main >/dev/null 2>&1
    git --git-dir="$origin" symbolic-ref HEAD refs/heads/main
}

# Push main and refresh the remote-tracking ref the probe reads. Fixtures call
# this instead of pushing inline so no case can accidentally measure a stale
# origin/main and pass for the wrong reason.
publish() {
    local repo="$1"
    git -C "$repo" push origin main >/dev/null 2>&1
    git -C "$repo" fetch origin >/dev/null 2>&1
}

run_probe() {
    local repo="$1"
    set +e
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo" bash "$PROBE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e
}

test_current_ledger_passes_and_reports_its_denominator() {
    local fixture_root repo head_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    head_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$head_sha"
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "0" "a ledger reconciled at the current tip passes"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=0" \
        "a current ledger reports a zero denominator rather than staying silent"
    assert_contains "$RUN_OUTPUT" "ledger_sha=$head_sha" \
        "the probe names the SHA it measured against"
    rm -rf "$fixture_root"
}

test_stale_ledger_fails_with_exact_count() {
    local fixture_root repo base_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$base_sha"
    # Six lane merges past the header is the live 2026-08-06 specimen: the
    # ledger was six lane merges behind while carrying five wrong claims.
    local i
    for i in 1 2 3 4 5 6; do
        create_lane_merge "$repo" "later_$i"
    done
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "1" "a ledger six lane merges behind must report red"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=6" \
        "the probe reports the exact lane-merge distance, not a boolean"
    assert_contains "$RUN_OUTPUT" "STALE" "a red verdict is labelled"
    rm -rf "$fixture_root"
}

test_threshold_boundary_is_inclusive() {
    local fixture_root repo base_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$base_sha"
    local i
    for i in 1 2 3 4 5; do
        create_lane_merge "$repo" "later_$i"
    done
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "0" "exactly the threshold is not yet stale"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=5" \
        "the boundary case still reports its exact distance"
    rm -rf "$fixture_root"
}

test_threshold_is_overridable() {
    local fixture_root repo base_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$base_sha"
    create_lane_merge "$repo" "later_1"
    publish "$repo"

    set +e
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo" FJCLOUD_SSOT_CURRENCY_MAX_LANE_MERGES=0 bash "$PROBE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e

    assert_eq "$RUN_EXIT_CODE" "1" "a tightened threshold must be able to turn a passing repo red"
    assert_contains "$RUN_OUTPUT" "threshold=0" "the probe reports the threshold it applied"
    rm -rf "$fixture_root"
}

test_invalid_threshold_fails_closed_and_says_so() {
    local fixture_root repo head_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    head_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$head_sha"
    publish "$repo"

    set +e
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo" FJCLOUD_SSOT_CURRENCY_MAX_LANE_MERGES=abc bash "$PROBE" 2>&1)"
    RUN_EXIT_CODE=$?
    set -e

    assert_eq "$RUN_EXIT_CODE" "2" \
        "an unparseable threshold is a caller error, not a licence to use the default"
    # The reason has to reach the operator. An earlier revision resolved the
    # threshold inside a command substitution, so this line was captured into
    # the variable and the run exited 2 in silence.
    assert_contains "$RUN_OUTPUT" "invalid_threshold=abc" \
        "the invalid threshold must be named on stderr/stdout, not swallowed"
    rm -rf "$fixture_root"
}

test_non_lane_commits_are_not_counted() {
    local fixture_root repo base_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$base_sha"
    # Twenty ordinary commits. If the probe counted commits instead of lane
    # merges this repo would read as catastrophically stale; it is not stale at
    # all, because no lane landed.
    local i
    for i in $(seq 1 20); do
        commit_file "$repo" "note_$i.txt" "note $i" "chore: note $i"
    done
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "0" "ordinary commits do not make the ledger stale"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=0" \
        "only batman lane merges count toward staleness"
    rm -rf "$fixture_root"
}

test_missing_header_fails_closed() {
    local fixture_root repo
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    printf '# Roadmap\n\n## Active\n\n## Planned\n\n## Archive\n' >"$repo/ROADMAP.md"
    git -C "$repo" add -- ROADMAP.md
    git -C "$repo" commit -m "docs: roadmap without a reconciliation header" >/dev/null
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "2" \
        "a ledger with no reconciliation header cannot be measured and must not pass"
    assert_contains "$RUN_OUTPUT" "no_reconciliation_header" \
        "the unmeasurable arm names why it could not measure"
    rm -rf "$fixture_root"
}

test_unresolvable_header_sha_fails_closed() {
    local fixture_root repo
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    # A well-formed SHA that is not an object in this repository. Silently
    # skipping it would let a typo read as a clean pass forever.
    write_roadmap "$repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "2" "an unresolvable header SHA must not pass"
    assert_contains "$RUN_OUTPUT" "unresolvable_ledger_sha" \
        "the unmeasurable arm names the SHA it could not resolve"
    rm -rf "$fixture_root"
}

test_closest_resolvable_header_wins_over_an_unresolvable_one() {
    local fixture_root repo base_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    base_sha="$(git -C "$repo" rev-parse HEAD)"
    # One bad SHA beside one good one. The live ledger accumulates headers over
    # months and an old one can name a SHA a pruned clone no longer has; that
    # must degrade to a measurement from the usable header, not to exit 2.
    write_roadmap "$repo" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$base_sha"
    create_lane_merge "$repo" "later_1"
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "one unresolvable header beside a usable one still yields a measurement"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=1" \
        "the measurement comes from the resolvable header"
    assert_contains "$RUN_OUTPUT" "unresolvable_headers=1" \
        "the skipped header is disclosed rather than dropped silently"
    rm -rf "$fixture_root"
}

test_oldest_header_does_not_win_over_the_newest() {
    local fixture_root repo old_sha new_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    old_sha="$(git -C "$repo" rev-parse HEAD)"
    local i
    for i in 1 2 3 4 5 6 7; do
        create_lane_merge "$repo" "mid_$i"
    done
    new_sha="$(git -C "$repo" rev-parse HEAD)"
    # Oldest header first, newest last — the live file's order. A probe that
    # took the first match would report eight and this repo is current.
    write_roadmap "$repo" "$old_sha" "$new_sha"
    publish "$repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "0" "the newest reconciliation is what the ledger currently claims"
    assert_contains "$RUN_OUTPUT" "lane_merges_since=0" \
        "distance is measured from the closest header, not the first one in the file"
    assert_contains "$RUN_OUTPUT" "ledger_sha=$new_sha" "the newest header's SHA is the one reported"
    rm -rf "$fixture_root"
}

test_missing_origin_main_fails_closed() {
    local fixture_root repo head_sha
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    create_lane_merge "$repo" "lane_a"
    head_sha="$(git -C "$repo" rev-parse HEAD)"
    write_roadmap "$repo" "$head_sha"
    publish "$repo"
    # Drop the remote-tracking ref. Measuring against local main instead would
    # report a repo with unpushed lane merges as current.
    git -C "$repo" update-ref -d refs/remotes/origin/main

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "2" "a missing origin/main cannot be measured and must not pass"
    assert_contains "$RUN_OUTPUT" "no_origin_main" "the unmeasurable arm names the missing ref"
    rm -rf "$fixture_root"
}

test_missing_roadmap_fails_closed() {
    local fixture_root repo
    fixture_root="$(mktemp -d)"
    make_fixture "$fixture_root"
    repo="$fixture_root/repo"

    run_probe "$repo"

    assert_eq "$RUN_EXIT_CODE" "2" "a repo with no ROADMAP.md must report an error, not a clean pass"
    assert_contains "$RUN_OUTPUT" "no_roadmap" "the unmeasurable arm names the missing ledger"
    rm -rf "$fixture_root"
}

test_current_ledger_passes_and_reports_its_denominator
test_stale_ledger_fails_with_exact_count
test_threshold_boundary_is_inclusive
test_threshold_is_overridable
test_invalid_threshold_fails_closed_and_says_so
test_non_lane_commits_are_not_counted
test_missing_header_fails_closed
test_unresolvable_header_sha_fails_closed
test_closest_resolvable_header_wins_over_an_unresolvable_one
test_oldest_header_does_not_win_over_the_newest
test_missing_origin_main_fails_closed
test_missing_roadmap_fails_closed

run_test_summary
