#!/usr/bin/env bash
# Feed-structure cases sourced by the accounting guard.

test_structure_check_accepts_reconciled_feed() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "a reconciled feed should pass structure checks"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a reconciled feed reports the exact success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_missing_marker() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "a missing residual marker must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'serial scheduling row'" \
        "the exact missing marker is reported"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_invalid_nonunclassified_disposition() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-invalid | 1 | handoff-a | summary a | deferred | evidence |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" "" '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "structure checks must reject invalid non-unclassified dispositions"
    assert_contains "$RUN_OUTPUT" \
        "lane-invalid has invalid disposition 'deferred'" \
        "the structure failure names the invalid ledger row and disposition"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an invalid disposition never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_missing_required_evidence() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-done | 1 | handoff-a | summary a | done | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" "" '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "structure checks must reject closed dispositions without evidence"
    assert_contains "$RUN_OUTPUT" "missing evidence for lane-done (done)" \
        "the structure failure names the ledger row missing required evidence"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "missing evidence never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_requires_markers_in_one_closed_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
- lane_id: closed-b
  status: closed
  resolution: |
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "unrelated feed text must not satisfy the rewritten residual-row contract"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: residual markers must share one Closed resolution row" \
        "markers split across unrelated Closed rows are rejected"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a whole-file substring match never yields a structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_residual_resolution_without_closed_status() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: malformed-residual
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a residual resolution without closed status must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'console_prep B3'" \
        "a malformed row cannot satisfy the residual marker contract"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a malformed residual row never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_oversized_rewrite_outcome_value() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "18446744073709551616" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an oversized rewrite outcome value must fail before Bash arithmetic"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrivals has unsupported entry count width '18446744073709551616'" \
        "the structure failure names the oversized rewrite outcome key and value"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an oversized rewrite outcome never wraps into a structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_rewrite_outcome_sum_overflow() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "$MAX_SAFE_ENTRY_COUNT" "1"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "rewrite outcome additions that overflow the supported width must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: rewrite outcome open-window sum exceeds supported width" \
        "the structure failure reports cumulative rewrite outcome overflow"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "rewrite outcome overflow never wraps into a structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_open_row_missing_status() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "every Open row must carry an explicit status"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: Open lane lane-a has status count=0 expected=1" \
        "the structure failure names the Open row missing status"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an Open row without status never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_open_row_closed_status() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: closed' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an Open row with a closed status must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: Open lane lane-a has status 'closed' expected 'open'" \
        "the structure failure names the contradictory Open row status"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a contradictory Open row never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_empty_open_lane_id() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id:' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an Open row with an empty lane_id must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: Open lane_id must not be empty" \
        "the structure failure identifies the empty Open lane_id"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an empty Open lane_id never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_leading_zero_rewrite_outcome_value() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "08" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a noncanonical rewrite outcome value must fail before Bash arithmetic"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrivals has noncanonical numeric value '08'" \
        "the structure failure names the leading-zero rewrite outcome value"
    assert_not_contains "$RUN_OUTPUT" "value too great for base" \
        "leading-zero input never leaks a raw Bash octal error"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a leading-zero rewrite outcome never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_out_of_window_open() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: open
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_repository_verdict_fixture "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "the repository verdict must fail for an open record outside the Open section"
    assert_contains "$RUN_OUTPUT" \
        "feed_out_of_window_open=1
STRUCTURE_FAIL: feed_out_of_window_open=1 expected=0" \
        "the repository verdict reports both accounting and the exact structure failure"
    rm -rf "$tmpdir"
}

test_structure_check_reports_open_reconciliation_mismatch() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: lane-b
  status: open' '- lane_id: closed-a
  status: open
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an unreconciled Open section must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: feed_open_window=2 expected=1 (unclassified=1 singleton_residual_open=0 post_pin_arrivals=0 readmitted_out_of_window=0)" \
        "the exact open-window reconciliation is reported"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: feed_out_of_window_open=1 expected=0" \
        "later reconciliation reporting does not suppress the out-of-window failure"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'serial scheduling row'" \
        "later reconciliation reporting does not suppress the missing-marker failure"
    rm -rf "$tmpdir"
}
test_structure_check_counts_singleton_residual_open_in_open_window() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # singleton_residual_open=1 must be folded into the expected open window:
    # unclassified(1) + singleton_residual_open(1) + post_pin(0) + readmitted(0) = 2.
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: singleton-residual-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "singleton_residual_open must reconcile the extra Open record"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a feed reconciled through singleton_residual_open reports the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_singleton_residual_open_mismatch() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # feed carries two Open records but the ledger claims zero singleton residual,
    # so the reconciliation must fail and name every summand including the residual.
    write_rewrite_outcome "$tmpdir" "0" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: lane-b
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an unreconciled Open section must fail when singleton residual is understated"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: feed_open_window=2 expected=1 (unclassified=1 singleton_residual_open=0 post_pin_arrivals=0 readmitted_out_of_window=0)" \
        "the reconciliation names the singleton residual summand"
    rm -rf "$tmpdir"
}

test_structure_check_requires_singleton_residual_open_line() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # A rewrite-outcome block missing the singleton_residual_open line must be
    # rejected: the residual field is a required accounting summand, not optional.
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' \
        "" \
        "## Rewrite outcome" \
        "" \
        "- post_pin_arrivals: 0" \
        "- readmitted_out_of_window: 0" \
        >> "$ledger_path"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a rewrite outcome without singleton_residual_open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: TRIAGE.md must contain exactly one numeric singleton_residual_open line under ## Rewrite outcome" \
        "the structure failure names the missing singleton residual line"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a missing singleton residual line never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_singleton_successor_keeps_unclassified_records_open() {
    local successor_path successor_text successor_work
    successor_path="$DEFAULT_REPO_ROOT/chats/icg/jul30_pm_9_followup_singleton_drain.md"
    successor_text="$(<"$successor_path")"
    successor_work="$(
        awk '
            /^\*\*The work\.\*\*/ { in_work = 1 }
            in_work && /^\*\*Out of scope for this stage\.\*\*/ { exit }
            in_work { print }
        ' "$successor_path"
    )"

    assert_contains "$successor_work" \
        'Move each `done`, `superseded`, `open-rehomed`, or `abandon` record out of `## Open`' \
        "the successor moves only terminal dispositions out of Open"
    assert_contains "$successor_work" \
        'Keep every `unclassified` singleton record under' \
        "the successor explicitly preserves unclassified singleton records in Open"
    assert_contains "$successor_work" \
        'once for every singleton row added to the ledger' \
        "the successor transfers every represented singleton out of the residual summand"
    assert_contains "$successor_text" \
        'followup_triage_accounting_test.sh --repo-verdict' \
        "the successor validates the live repository in addition to fixture self-tests"
}

test_structure_check_accepts_reconciled_feed
test_structure_check_reports_missing_marker
test_structure_check_counts_singleton_residual_open_in_open_window
test_structure_check_reports_singleton_residual_open_mismatch
test_structure_check_requires_singleton_residual_open_line
test_singleton_successor_keeps_unclassified_records_open
test_structure_check_rejects_invalid_nonunclassified_disposition
test_structure_check_rejects_missing_required_evidence
test_structure_check_requires_markers_in_one_closed_resolution
test_structure_check_rejects_residual_resolution_without_closed_status
test_structure_check_rejects_oversized_rewrite_outcome_value
test_structure_check_rejects_rewrite_outcome_sum_overflow
test_structure_check_rejects_open_row_missing_status
test_structure_check_rejects_open_row_closed_status
test_structure_check_rejects_empty_open_lane_id
test_structure_check_rejects_leading_zero_rewrite_outcome_value
test_structure_check_reports_out_of_window_open
test_structure_check_reports_open_reconciliation_mismatch
