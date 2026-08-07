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
    # chats/icg is a required input for the same reason chatting/ is: the probe
    # now also measures `## ROADMAP CORRECTION REQUIRED` sections written inside
    # lane checklists there, and a root without that directory has an unmeasured
    # denominator rather than a clean one.
    mkdir -p "$root/chatting" "$root/implemented" "$root/chats/icg"
    printf '# Roadmap\n\n## Active\n\n## Planned\n\n## Archive\n' >"$root/ROADMAP.md"
    printf '%s' "$root"
}

# Write a lane checklist that carries an inline `## ROADMAP CORRECTION REQUIRED`
# section -- the newer handover shape every aug05 batch uses instead of a
# separate chatting/ document.
write_lane_with_correction() {
    local root="$1" filename="$2"
    printf '# lane\n\n## ROADMAP CORRECTION REQUIRED\n\nRow title, verbatim: **"some row"**\n' \
        >"$root/chats/icg/$filename"
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

# ---------------------------------------------------------------------------
# Inline `## ROADMAP CORRECTION REQUIRED` sections (chats/icg/<lane>.md).
#
# Every aug05 batch instructs its lanes to append this section to their OWN
# checklist instead of writing a separate chatting/ handover, so the chatting/
# enumeration above is structurally blind to the channel currently in use.
# Measured 2026-08-06 on origin/main: three lane files carried such a section and
# the probe reported handover_total over the chatting/ population alone.
# ---------------------------------------------------------------------------

test_inline_roadmap_correction_named_in_roadmap_is_consumed() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    write_lane_with_correction "$root" "aug05_1pm_1_source_index_picker.md"
    # ROADMAP.md cites lanes by their id, not by the full checklist basename, so
    # the id is the oracle. This is the shape a real reconciliation writes.
    printf 'Narrowed by `aug05_1pm_1` (merge `60dcd3159`).\n' >>"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "0" "an inline correction whose lane id is in ROADMAP.md should exit 0"
    assert_contains "$output" "inline_corrections=1" "the report must expose the inline-correction denominator"
    assert_contains "$output" "consumed=1" "a lane id named in ROADMAP.md counts as consumed"
    assert_contains "$output" "unconsumed=0" "nothing should remain unconsumed"
}

test_inline_roadmap_correction_absent_from_roadmap_is_reported() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    write_lane_with_correction "$root" "aug05_12pm_2_pricing_registry_verification.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "an unapplied inline correction must exit non-zero"
    assert_contains "$output" "inline_corrections=1" "the denominator must count the inline correction"
    assert_contains "$output" "unconsumed=1" "the count must be exact, not merely non-zero"
    assert_contains "$output" "UNCONSUMED chats/icg/aug05_12pm_2_pricing_registry_verification.md" \
        "the report must name the unconsumed lane file by its real path"
}

test_lane_file_without_correction_heading_is_not_counted() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    # chats/icg holds ~800 ordinary checklists. Counting them would drown the
    # signal, so only files carrying the heading enter the denominator.
    printf '# lane\n\nAppend a `ROADMAP CORRECTION REQUIRED` section to this file.\n' \
        >"$root/chats/icg/aug05_9am_1_ordinary_lane.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "0" "a lane that merely mentions the phrase must not be counted"
    assert_contains "$output" "inline_corrections=0" "only a real heading enters the denominator"
}

test_inline_correction_reference_from_sibling_lane_does_not_count() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    write_lane_with_correction "$root" "aug05_12pm_2_pricing_registry_verification.md"
    # Lane-to-lane chatter is not application to the SSOT -- same rule the
    # chatting/ population already enforces. An orchestration naming its own
    # roster must not be able to satisfy this probe.
    printf 'roster: aug05_12pm_2 pricing lane\n' >"$root/chats/icg/aug05_12pm_0_orchestration.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "a sibling lane reference must not count as consumption"
    assert_contains "$output" "unconsumed=1" "the correction is still unapplied"
}

test_inline_correction_lane_id_match_respects_digit_boundary() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    write_lane_with_correction "$root" "aug05_1pm_1_picker.md"
    # `aug05_1pm_1` is a literal prefix of `aug05_1pm_10`. A substring oracle
    # would call this consumed and silently lose the correction.
    printf 'Applied `aug05_1pm_10` this pass.\n' >>"$root/ROADMAP.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "1" "a longer sibling id must not consume the shorter one"
    assert_contains "$output" "unconsumed=1" "the shorter lane id is still unapplied"
}

test_inline_correction_with_underivable_lane_id_fails_closed() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    # No numeric lane index, so no id can be derived. The probe must say so
    # rather than report a denominator it did not actually measure.
    write_lane_with_correction "$root" "notalaneid.md"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "2" "an underivable lane id must fail closed"
    assert_contains "$output" "lane id" "the diagnostic must name the derivation boundary"
}

test_missing_chats_icg_directory_is_not_silently_clean() {
    local root output exit_code=0
    root="$(make_fixture_root)"
    rm -rf "$root/chats"

    output="$(run_probe "$root")" || exit_code=$?
    rm -rf "$root"

    assert_eq "$exit_code" "2" "a missing chats/icg must fail closed, not report zero"
    assert_contains "$output" "chats/icg" "the diagnostic must name the missing input"
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
    test_inline_roadmap_correction_named_in_roadmap_is_consumed
    test_inline_roadmap_correction_absent_from_roadmap_is_reported
    test_lane_file_without_correction_heading_is_not_counted
    test_inline_correction_reference_from_sibling_lane_does_not_count
    test_inline_correction_lane_id_match_respects_digit_boundary
    test_inline_correction_with_underivable_lane_id_fails_closed
    test_missing_chats_icg_directory_is_not_silently_clean

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
