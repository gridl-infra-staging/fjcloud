#!/usr/bin/env bash
# check_handover_consumption_test.sh — contract for the unconsumed-handover probe.
#
# The probe exists because the same failure happened twice in four days. A batch's
# feature lanes each write `chatting/<batch>_roadmap_handover_<lane>.md` describing
# the ROADMAP.md rows their work changed, and the batch's terminal reconcile lane
# is supposed to apply them. That reconcile lane is authored last and dispatched
# last, so whatever stops the batch stops the one lane that would have recorded
# what the batch did:
#
#   - aug02_5am: fc{1,2,4} handovers written, consumer aug02_5am_6 never dispatched.
#   - aug02_11am: fs{1,2,3,4,6,7} handovers written, consumer aug02_11am_9 stopped
#     at stage 2 of 3.
#
# Both times the handovers were correct, on time, and invisible. Nothing reported
# that ROADMAP.md was behind the tree.
#
# These cases pin the probe's oracle. Each fixture is a self-contained fake repo
# root, so the suite cannot pass or fail because of the real repo's current state.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/check_handover_consumption.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
    if [ "$1" = "$2" ]; then
        pass "$3"
    else
        fail "$3 (expected='$2' actual='$1')"
    fi
}

assert_contains() {
    case "$1" in
        *"$2"*) pass "$3" ;;
        *) fail "$3 (expected substring '$2' in '$1')" ;;
    esac
}

assert_not_contains() {
    case "$1" in
        *"$2"*) fail "$3 (unexpected substring '$2' found)" ;;
        *) pass "$3" ;;
    esac
}

# Build a throwaway repo root with a ROADMAP.md, an implemented/ directory and a
# chatting/ directory. Callers add handovers and references afterwards.
make_fixture_root() {
    local root
    root="$(mktemp -d)"
    mkdir -p "$root/chatting" "$root/implemented"
    printf '# Roadmap\n\n## Active\n\n## Planned\n\n## Archive\n' >"$root/ROADMAP.md"
    printf '%s' "$root"
}

run_probe() {
    FJCLOUD_DOC_ROOT="$1" bash "$PROBE" 2>&1
}

test_no_handovers_is_clean() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "0" "a repo with no handovers should exit 0"
    assert_contains "$output" "handover_total=0" "empty state should report a zero denominator, not stay silent"
    assert_contains "$output" "unconsumed=0" "empty state should report zero unconsumed"
}

test_handover_referenced_in_roadmap_is_consumed() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs1.md"
    printf 'Applied aug02_11am_roadmap_handover_fs1.md in this reconciliation.\n' >>"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "0" "a handover named in ROADMAP.md should exit 0"
    assert_contains "$output" "handover_total=1" "the denominator must count the handover"
    assert_contains "$output" "consumed=1" "a referenced handover counts as consumed"
    assert_contains "$output" "unconsumed=0" "no handover should remain unconsumed"
}

test_handover_referenced_in_implemented_record_is_consumed() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs7.md"
    # A reconciliation may park long-form detail in implemented/ and leave only a
    # pointer in ROADMAP.md, so implemented/ must count as an application site.
    printf 'Folded aug02_11am_roadmap_handover_fs7.md into this record.\n' \
        >"$root/implemented/2026-08-03_batch_reconciliation.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "0" "a handover named in implemented/ should exit 0"
    assert_contains "$output" "consumed=1" "an implemented/ reference counts as consumed"
}

test_unreferenced_handover_is_reported_and_fails() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs1.md"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs2.md"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs3.md"
    # Only one of the three gets applied, reproducing a partial reconciliation.
    printf 'Applied aug02_11am_roadmap_handover_fs2.md.\n' >>"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "unconsumed handovers must exit non-zero"
    assert_contains "$output" "handover_total=3" "the denominator must count every handover"
    assert_contains "$output" "unconsumed=2" "the count must be exact, not merely non-zero"
    assert_contains "$output" "aug02_11am_roadmap_handover_fs1.md" "the report must name the unconsumed handover"
    assert_contains "$output" "aug02_11am_roadmap_handover_fs3.md" "the report must name every unconsumed handover"
    assert_not_contains "$output" "UNCONSUMED chatting/aug02_11am_roadmap_handover_fs2.md" \
        "the applied handover must not be listed as unconsumed"
}

test_roadmap_corrections_documents_are_covered() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    # The aug02_5am batch used the `_roadmap_corrections_` spelling for the same
    # artifact. A probe that only matched `_roadmap_handover_` would have reported
    # that batch clean while three corrections sat unapplied.
    printf 'corrections body\n' >"$root/chatting/aug02_5am_roadmap_corrections_fc1.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "an unapplied roadmap-corrections document must also fail"
    assert_contains "$output" "aug02_5am_roadmap_corrections_fc1.md" \
        "the corrections spelling must be reported by name"
}

test_handover_spelling_without_roadmap_is_covered() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    # Third spelling, found in production 2026-08-03: the aug03_11am batch named
    # its handovers `<batch>_handover_<lane>.md`, dropping `roadmap` entirely.
    # This probe's first version matched only the `roadmap`-infixed spellings and
    # therefore reported 10 of 14 files, calling the repo clean while four of the
    # newest handovers were invisible. Match the `_handover_`/`_corrections_`
    # shape instead of a batch's naming habits.
    printf 'handover body\n' >"$root/chatting/aug03_11am_handover_fj1.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "a handover without the roadmap_ infix must still be counted"
    assert_contains "$output" "handover_total=1" "the denominator must include the shorter spelling"
    assert_contains "$output" "aug03_11am_handover_fj1.md" "the shorter spelling must be named in the report"
}

test_reference_from_another_handover_does_not_count() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    printf 'handover body\n' >"$root/chatting/aug02_11am_roadmap_handover_fs1.md"
    # A sibling handover naming it is lane-to-lane chatter, not application to the
    # SSOT. Counting it would let a batch mark itself consumed by cross-referencing
    # its own documents -- the precise self-satisfying oracle this probe must avoid.
    printf 'See aug02_11am_roadmap_handover_fs1.md for the CSP shape.\n' \
        >"$root/chatting/aug02_11am_roadmap_handover_fs2.md"
    printf 'Applied aug02_11am_roadmap_handover_fs2.md.\n' >>"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "a handover referenced only by a sibling handover is still unconsumed"
    assert_contains "$output" "unconsumed=1" "only the genuinely unapplied handover should count"
    assert_contains "$output" "aug02_11am_roadmap_handover_fs1.md" \
        "the handover referenced only by a sibling must be named"
}

test_missing_chatting_directory_is_not_silently_clean() {
    local root output exit_code=0
    root="$(mktemp -d)"
    printf '# Roadmap\n' >"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    # A probe that treats "directory absent" as "nothing to check" would report
    # healthy on a broken checkout. Required inputs may not skip.
    assert_eq "$exit_code" "2" "a missing chatting/ directory must be an error, not a clean pass"
    assert_contains "$output" "chatting" "the diagnostic must name the missing input"
}

test_handover_enumeration_failure_is_not_silently_clean() {
    local root output exit_code=0 mock_bin
    root="$(make_fixture_root)"
    mock_bin="$root/mock-bin"
    mkdir -p "$mock_bin"
    cat >"$mock_bin/find" <<'SH'
#!/usr/bin/env bash
echo "synthetic find failure" >&2
exit 19
SH
    chmod +x "$mock_bin/find"

    output="$(PATH="$mock_bin:/usr/bin:/bin" run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "2" "a failed handover enumeration must be an error, not a clean pass"
    assert_contains "$output" "unable to enumerate roadmap handovers" \
        "the diagnostic must identify the failed enumeration boundary"
    assert_contains "$output" "synthetic find failure" \
        "the diagnostic must preserve the underlying enumeration error"
}

test_unsafe_handover_filename_fails_without_terminal_injection() {
    local root output exit_code=0 control_sequence malicious_name
    root="$(make_fixture_root)"
    control_sequence="$(printf '\033[31m')"
    malicious_name="aug02_11am_roadmap_handover_${control_sequence}"$'\n'"FORGED.md"
    printf 'handover body\n' >"$root/chatting/$malicious_name"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "2" "an unsafe handover filename must fail closed"
    assert_contains "$output" "unsafe handover filename" \
        "the diagnostic must identify the rejected filename boundary"
    assert_not_contains "$output" "$control_sequence" \
        "the diagnostic must not replay terminal control bytes from a filename"
}

main() {
    echo "=== check_handover_consumption.sh tests ==="
    echo ""

    test_no_handovers_is_clean
    test_handover_referenced_in_roadmap_is_consumed
    test_handover_referenced_in_implemented_record_is_consumed
    test_unreferenced_handover_is_reported_and_fails
    test_roadmap_corrections_documents_are_covered
    test_handover_spelling_without_roadmap_is_covered
    test_reference_from_another_handover_does_not_count
    test_missing_chatting_directory_is_not_silently_clean
    test_handover_enumeration_failure_is_not_silently_clean
    test_unsafe_handover_filename_fails_without_terminal_injection

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
