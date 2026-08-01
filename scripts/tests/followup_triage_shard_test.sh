#!/usr/bin/env bash
# Known-answer contract tests for the deterministic follow-up triage shard owner.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHARD_SCRIPT="$REPO_ROOT/scripts/followup_triage_shard.py"
PINNED_SHA="389915769632758edcbf7efd9e04457d12a61a50"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

make_fixture() {
    local fixture_root="$1"
    mkdir -p "$fixture_root/docs/audits/followup-triage" "$fixture_root/chats/icg"
}

write_ledger() {
    local fixture_root="$1" pin="$2" denominator="$3"
    printf '%s\n' \
        "# Follow-up triage ledger" \
        "" \
        "## Pinned census" \
        "" \
        "- Pinned base SHA: \`$pin\`" \
        "- open_window: $denominator" \
        >"$fixture_root/docs/audits/followup-triage/TRIAGE.md"
}

write_feed() {
    local fixture_root="$1" open_rows="$2"
    printf '%s\n' \
        "## Open" \
        "$open_rows" \
        "" \
        "## Harvested" \
        "" \
        "## Closed" \
        >"$fixture_root/chats/icg/_followups.md"
}

commit_fixture_feed() {
    local fixture_root="$1"
    git -C "$fixture_root" init -q
    git -C "$fixture_root" add chats/icg/_followups.md
    git -C "$fixture_root" \
        -c user.email=fixture@example.invalid \
        -c user.name=Fixture \
        commit -q -m "pin follow-up feed fixture"
    git -C "$fixture_root" rev-parse HEAD
}

append_open_lane_to_working_tree_feed() {
    local fixture_root="$1" lane_id="$2"
    awk -v lane_id="$lane_id" '
        $0 == "## Harvested" && !inserted {
            print "- lane_id: " lane_id
            print "  status: open"
            inserted = 1
        }
        { print }
    ' "$fixture_root/chats/icg/_followups.md" >"$fixture_root/chats/icg/_followups.md.tmp"
    mv "$fixture_root/chats/icg/_followups.md.tmp" "$fixture_root/chats/icg/_followups.md"
}

run_shard() {
    local fixture_root="$1"
    shift
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FJCLOUD_REPO_ROOT="$fixture_root" python3 "$SHARD_SCRIPT" "$@" 2>&1
    )" || RUN_EXIT_CODE=$?
}

write_all_shard_output() {
    local output_path="$1" shard_id
    : >"$output_path"
    for shard_id in 00 01 02 03 04 05 06 07 08 09; do
        FJCLOUD_REPO_ROOT="$REPO_ROOT" \
            python3 "$SHARD_SCRIPT" --shard "$shard_id" >>"$output_path"
    done
}

write_pinned_source_lanes() {
    local output_path="$1"
    git -C "$REPO_ROOT" show "$PINNED_SHA:chats/icg/_followups.md" |
        awk '
            $0 == "## Open" {
                in_open = 1
                next
            }
            /^## / {
                in_open = 0
            }
            in_open && /^- lane_id: / {
                lane_id = $0
                sub(/^- lane_id: /, "", lane_id)
                sub(/::.*/, "", lane_id)
                print lane_id
            }
        ' |
        sort -u >"$output_path"
}

test_real_pinned_coverage_matches_known_answer() {
    local expected
    expected="pin: $PINNED_SHA
open_window: 999
shard 00: lanes=32 records=100
shard 01: lanes=32 records=100
shard 02: lanes=32 records=100
shard 03: lanes=34 records=100
shard 04: lanes=34 records=100
shard 05: lanes=34 records=100
shard 06: lanes=34 records=100
shard 07: lanes=34 records=100
shard 08: lanes=34 records=100
shard 09: lanes=33 records=99
grand_total: lanes=333 records=999
coverage: OK"

    run_shard "$REPO_ROOT" --verify-coverage

    assert_eq "$RUN_EXIT_CODE" "0" "real pinned coverage should pass"
    assert_eq "$RUN_OUTPUT" "$expected" \
        "real pinned coverage must match the hand-calculated known answer"
}

test_real_shards_are_disjoint_and_cover_every_pinned_lane() {
    local tmpdir shard_id shard_records duplicate_lanes
    local record_total=0
    tmpdir="$(mktemp -d)"
    : >"$tmpdir/actual_lanes.txt"

    for shard_id in 00 01 02 03 04 05 06 07 08 09; do
        run_shard "$REPO_ROOT" --shard "$shard_id"
        assert_eq "$RUN_EXIT_CODE" "0" "real shard $shard_id should print"
        shard_records="$(awk '$1 == "records:" { print $2 }' <<<"$RUN_OUTPUT")"
        record_total=$((record_total + shard_records))
        awk 'lanes { print } $0 == "lanes:" { lanes = 1 }' <<<"$RUN_OUTPUT" \
            >>"$tmpdir/actual_lanes.txt"
    done

    duplicate_lanes="$(sort "$tmpdir/actual_lanes.txt" | uniq -d)"
    assert_eq "$duplicate_lanes" "" "real shard lane assignments must be disjoint"
    assert_eq "$record_total" "999" "real shard record totals must cover the denominator"

    write_pinned_source_lanes "$tmpdir/expected_lanes.txt"
    sort -u "$tmpdir/actual_lanes.txt" >"$tmpdir/unique_actual_lanes.txt"
    if diff -u "$tmpdir/expected_lanes.txt" "$tmpdir/unique_actual_lanes.txt"; then
        pass "real shards must cover every pinned source lane exactly once"
    else
        fail "real shards must cover every pinned source lane exactly once"
    fi
    assert_eq "$(wc -l <"$tmpdir/unique_actual_lanes.txt" | tr -d ' ')" "333" \
        "real shards must cover the 333-lane known answer"
    rm -rf "$tmpdir"
}

test_real_shard_output_is_byte_stable() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    write_all_shard_output "$tmpdir/first.txt"
    write_all_shard_output "$tmpdir/second.txt"

    if cmp -s "$tmpdir/first.txt" "$tmpdir/second.txt"; then
        pass "all real shard manifests must be byte-stable across runs"
    else
        diff -u "$tmpdir/first.txt" "$tmpdir/second.txt" || true
        fail "all real shard manifests must be byte-stable across runs"
    fi
    rm -rf "$tmpdir"
}

test_pinned_snapshot_ignores_working_tree_feed_changes() {
    local tmpdir pin before_mutation
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: lane-b::part-1
  status: open'
    pin="$(commit_fixture_feed "$tmpdir")"
    write_ledger "$tmpdir" "$pin" "2"

    run_shard "$tmpdir" --verify-coverage
    assert_eq "$RUN_EXIT_CODE" "0" "pinned fixture coverage should pass before mutation"
    before_mutation="$RUN_OUTPUT"

    append_open_lane_to_working_tree_feed "$tmpdir" "lane-z"
    run_shard "$tmpdir" --verify-coverage

    assert_eq "$RUN_EXIT_CODE" "0" "pinned fixture coverage should pass after mutation"
    assert_eq "$RUN_OUTPUT" "$before_mutation" \
        "working-tree feed appends must not affect pinned shard output"
    rm -rf "$tmpdir"
}

test_equal_count_lanes_use_stable_tie_breaks() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-c
  status: open
- lane_id: lane-a
  status: open
- lane_id: lane-b
  status: open'
    pin="$(commit_fixture_feed "$tmpdir")"
    write_ledger "$tmpdir" "$pin" "3"

    run_shard "$tmpdir" --shard 00
    assert_eq "$RUN_EXIT_CODE" "0" "equal-count shard 00 should print"
    assert_eq "$RUN_OUTPUT" $'shard: 00\nrecords: 1\nlanes:\nlane-a' \
        "equal-count lanes must sort ascending before assignment"
    run_shard "$tmpdir" --shard 01
    assert_eq "$RUN_EXIT_CODE" "0" "equal-count shard 01 should print"
    assert_eq "$RUN_OUTPUT" $'shard: 01\nrecords: 1\nlanes:\nlane-b' \
        "least-loaded shard ties must choose the lowest shard index"
    run_shard "$tmpdir" --shard 02
    assert_eq "$RUN_EXIT_CODE" "0" "equal-count shard 02 should print"
    assert_eq "$RUN_OUTPUT" $'shard: 02\nrecords: 1\nlanes:\nlane-c' \
        "stable tie-breaking must continue across shard indexes"
    rm -rf "$tmpdir"
}

test_lane_counts_are_normalized_and_risk_ordered() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-b
  status: open
- lane_id: lane-a::part-1
  status: open
- lane_id: lane-c
  status: open
- lane_id: lane-a::part-2
  status: open'
    pin="$(commit_fixture_feed "$tmpdir")"
    write_ledger "$tmpdir" "$pin" "4"

    run_shard "$tmpdir" --lane-counts

    assert_eq "$RUN_EXIT_CODE" "0" "lane-count map should print"
    assert_eq "$RUN_OUTPUT" $'lane-a\t2\nlane-b\t1\nlane-c\t1' \
        "lane counts must normalize anchors and sort by descending risk then lane ID"
    rm -rf "$tmpdir"
}

test_lane_count_order_matches_shard_assignment_order() {
    # With fewer lanes than shards every shard starts empty, so assign_shards
    # drops the Nth risk-ordered lane into shard N. That makes shard index order
    # an observable copy of the LPT order, which must equal --lane-counts order.
    local tmpdir pin lane_order shard_order shard_id
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-b
  status: open
- lane_id: lane-a::part-1
  status: open
- lane_id: lane-c
  status: open
- lane_id: lane-a::part-2
  status: open
- lane_id: lane-c::part-2
  status: open'
    pin="$(commit_fixture_feed "$tmpdir")"
    write_ledger "$tmpdir" "$pin" "5"

    run_shard "$tmpdir" --lane-counts
    assert_eq "$RUN_EXIT_CODE" "0" "lane-count map should print for the drift guard"
    lane_order="$(printf '%s\n' "$RUN_OUTPUT" | cut -f1)"

    shard_order=""
    for shard_id in 00 01 02; do
        run_shard "$tmpdir" --shard "$shard_id"
        assert_eq "$RUN_EXIT_CODE" "0" "shard $shard_id should print for the drift guard"
        shard_order+="$(printf '%s\n' "$RUN_OUTPUT" | tail -n 1)"$'\n'
    done

    assert_eq "$lane_order" "${shard_order%$'\n'}" \
        "lane-count risk order must stay identical to the shard assignment order"
    rm -rf "$tmpdir"
}

test_real_pinned_coverage_matches_known_answer
test_real_shards_are_disjoint_and_cover_every_pinned_lane
test_real_shard_output_is_byte_stable
test_pinned_snapshot_ignores_working_tree_feed_changes
test_equal_count_lanes_use_stable_tie_breaks
test_lane_counts_are_normalized_and_risk_ordered
test_lane_count_order_matches_shard_assignment_order

run_test_summary
