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

test_structure_check_accepts_generator_quoted_residual_row() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: docs/audits/followup-triage/TRIAGE.md::stage_03_residual_markers
  source_handoff: docs/audits/followup-triage/TRIAGE.md
  ended_at: 2026-07-31
  summary: Stage 3 preserved residual-marker evidence in one Closed resolution row.
  status: closed
  resolution: '\''console_prep B3

    FJ-7

    mirror-leak

    serial scheduling row

    '\'' # generated comment'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "the generator quoted residual row should pass structure checks"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "the exact generator quoted row reports the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_missing_marker_in_quoted_row() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: quoted-missing-marker
  status: closed
  resolution: '\''console_prep B3

    FJ-7

    mirror-leak

    '\'''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a quoted residual row missing one marker must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'serial scheduling row'" \
        "the quoted-row failure names the exact missing marker"
    assert_not_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'console_prep B3'" \
        "quoted-row markers present in the resolution are recognized"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a quoted row missing one marker never reaches the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_requires_quoted_markers_in_one_closed_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: quoted-closed-a
  status: closed
  resolution: '\''console_prep B3

    FJ-7

    mirror-leak

    '\''
- lane_id: quoted-closed-b
  status: closed
  resolution: '\''serial scheduling row

    '\'''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "quoted residual markers split across rows must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: residual markers must share one Closed resolution row" \
        "split quoted rows report the exact same-row diagnostic"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "split quoted rows never reach the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_quoted_marker_text_outside_closed_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  summary: '\''console_prep B3 FJ-7 mirror-leak serial scheduling row'\''
  status: open' '- lane_id: closed-without-residual-markers
  status: closed
  resolution: '\''unrelated closed resolution

    '\'''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "marker text outside a Closed resolution must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: missing residual marker 'console_prep B3'" \
        "text in an Open summary cannot satisfy the Closed resolution contract"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "marker text outside a Closed resolution never reaches success"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_unterminated_quoted_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: unterminated-quoted-resolution
  status: closed
  resolution: '\''console_prep B3

    FJ-7

    mirror-leak

    serial scheduling row
- lane_id: following-closed-row
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a quote left open before the next Closed row must fail closed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: unterminated quoted resolution for Closed lane unterminated-quoted-resolution" \
        "the malformed quoted scalar reports its exact lane"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an unterminated quoted scalar never reaches success"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_text_after_quoted_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: malformed-quoted-resolution
  status: closed
  resolution: '\''console_prep B3 FJ-7 mirror-leak serial scheduling row'\'' trailing-garbage'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "text after a quoted resolution must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: invalid text after quoted resolution for Closed lane malformed-quoted-resolution" \
        "the malformed trailing text reports its owning lane"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "trailing quoted-resolution text never reaches the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_detached_quoted_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '  resolution: '\''detached quoted text

    '\''
- lane_id: valid-closed-row
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a quoted resolution before any Closed lane_id must fail closed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: detached quoted resolution before any Closed lane_id" \
        "the detached quoted scalar reports the exact structural diagnostic"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a detached quoted scalar never reaches success"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_duplicate_quoted_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: duplicate-quoted-resolution
  status: closed
  resolution: '\''console_prep B3

    FJ-7

    mirror-leak

    serial scheduling row

    '\''
  resolution: '\''second resolution

    '\'''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "two quoted resolution fields on one Closed row must fail closed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: ambiguous duplicate resolution for Closed lane duplicate-quoted-resolution" \
        "the duplicate resolution diagnostic names the affected lane"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a duplicate resolution never reaches success"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_literal_then_quoted_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: duplicate-after-literal
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row
  resolution: '\''second resolution

    '\'''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a quoted resolution immediately after a literal must fail closed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: ambiguous duplicate resolution for Closed lane duplicate-after-literal" \
        "a literal-to-quoted duplicate reports the affected lane"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a literal-to-quoted duplicate never reaches success"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_literal_then_literal_resolution() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: duplicate-literals
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row
  resolution: |
    second resolution'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a second literal resolution immediately after a literal must fail closed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: ambiguous duplicate resolution for Closed lane duplicate-literals" \
        "a literal-to-literal duplicate reports the affected lane"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a literal-to-literal duplicate never reaches success"
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
    write_rewrite_outcome "$tmpdir" "0" "1" "$MAX_SAFE_ENTRY_COUNT"
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
        "STRUCTURE_FAIL: feed_open_window=2 expected=1 (unclassified=1 singleton_residual_open=0 historical_post_pin_arrivals=0 post_reconciliation_arrivals=0 readmitted_out_of_window=0)" \
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
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
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
    pin="$(pin_current_feed "$tmpdir" "pin singleton summand fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    # singleton_residual_open=1 must be folded into the expected open window:
    # unclassified(1) + singleton_residual_open(1) + post_pin(0) + readmitted(0) = 2.
    # The residual is owned by name, so the scalar alone cannot reconcile it.
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'
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
        "STRUCTURE_FAIL: feed_open_window=2 expected=1 (unclassified=1 singleton_residual_open=0 historical_post_pin_arrivals=0 post_reconciliation_arrivals=0 readmitted_out_of_window=0)" \
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

test_structure_check_subtracts_unclassified_departed_from_open_window() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    # Three pinned records are unclassified in the ledger, but two have since
    # moved to ## Closed, so only one remains under ## Open. The rewrite outcome
    # records the two departed records; the guard must subtract them so
    # feed_open_window(1) == unclassified(3) - departed(2) + 0 + 0 + 0.
    write_ledger "$tmpdir" "3" \
        "| lane-a | 3 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' "- unclassified_departed_open: 2" >> "$ledger_path"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "unclassified records that departed ## Open must be subtracted from the open-window expectation"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a feed reconciled through unclassified_departed_open reports the success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_unclassified_departed_open_in_diagnostic() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    # departed(2) leaves an expected open window of 1, but the feed carries two
    # open records, so the reconciliation must fail and name the departed
    # subtrahend alongside every additive summand.
    write_ledger "$tmpdir" "3" \
        "| lane-a | 3 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' "- unclassified_departed_open: 2" >> "$ledger_path"
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
        "an open window larger than the departed-adjusted expectation must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: feed_open_window=2 expected=1 (unclassified=3 unclassified_departed_open=2 singleton_residual_open=0 historical_post_pin_arrivals=0 post_reconciliation_arrivals=0 readmitted_out_of_window=0)" \
        "the reconciliation names the departed subtrahend beside the additive summands"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a departed-adjusted mismatch never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_malformed_unclassified_departed_open() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    # A present-but-noncanonical departed line must fail closed rather than be
    # silently treated as zero: the field is optional only by absence.
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' "- unclassified_departed_open: 0" >> "$ledger_path"
    # Corrupt the value to a leading-zero form after the fact.
    sed -i.bak 's/^- unclassified_departed_open: 0$/- unclassified_departed_open: 00/' "$ledger_path"
    rm -f "$ledger_path.bak"
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
        "a present-but-malformed unclassified_departed_open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: unclassified_departed_open has noncanonical numeric value '00'" \
        "the structure failure names the malformed departed value"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a malformed departed value never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_departed_count_exceeding_unclassified() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' "- unclassified_departed_open: 2" >> "$ledger_path"
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
        "departed unclassified records cannot exceed the unclassified set"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: unclassified_departed_open=2 exceeds unclassified=1" \
        "additive open-window terms cannot hide an impossible departed subset"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an impossible departed subset never reaches success"
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

# The cases below pin the identity-aware post-pin arrival contract. Historical
# arrival membership is owned by `### post_pin_arrivals identities`; later arrival
# membership is owned by `### post_reconciliation_arrival identities`. The
# open-window expectation must follow those named identities rather than a mutable
# scalar, and every membership defect must name the offending identity instead of
# surfacing only an aggregate count.

test_structure_check_reconciles_honest_post_pin_arrival() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # The scalar still reads the frozen reconciliation count of 1 while an
    # honest second arrival has landed and been named in the later-arrival block.
    # The identities own membership, so the expectation is
    # unclassified(1) + historical(1) + later(1) = 3.
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: post-pin-arrival-b
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "an honest arrival named in the identity block must reconcile without a scalar bump"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an identity-reconciled feed reports the exact success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_missing_post_pin_arrival() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # Both identity blocks are recorded and the scalar still agrees with the
    # historical block, so the sole defect is that `post-pin-arrival-b` never
    # reached the feed.
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an expected post-pin arrival absent from the feed must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' is missing from ## Open" \
        "the structure failure names the missing arrival identity, not just a count"
    assert_not_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' is outside ## Open" \
        "an arrival absent from the whole feed is not reported as merely mislocated"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a missing arrival identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_duplicate_post_pin_arrival() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # `post-pin-arrival-b` is named once but landed twice, so the open window
    # inflates by a record the identity block never authorized.
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: post-pin-arrival-b
  status: open
- lane_id: post-pin-arrival-b
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a post-pin arrival identity repeated under ## Open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' appears 2 times under ## Open expected=1" \
        "the structure failure names the duplicated arrival identity and both counts"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a duplicated arrival identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_post_pin_arrival_outside_open() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # `post-pin-arrival-b` is still named as an arrival but the generator has moved
    # it under ## Closed. Its `status: closed` keeps the out-of-window open census
    # at zero, so the only defect left is the mislocated arrival identity.
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: post-pin-arrival-b
  status: closed
  resolution: |
    moved out of the open window
- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a post-pin arrival identity that left ## Open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' is outside ## Open" \
        "the structure failure names the mislocated arrival identity"
    assert_not_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' is missing from ## Open" \
        "an arrival still present elsewhere in the feed is not reported as absent"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a mislocated arrival identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_post_pin_arrival_cross_section_duplicate() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: post-pin-arrival-b
  status: open' '- lane_id: post-pin-arrival-b
  status: closed
  resolution: |
    stale duplicate closed row
- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a recorded arrival identity duplicated outside ## Open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'post-pin-arrival-b' appears under ## Open and outside ## Open" \
        "the structure failure names the cross-section duplicate arrival identity"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a cross-section duplicated arrival identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_unrecorded_extra_post_pin_arrival() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "1" "0" "0" 'post-pin-arrival-a' ''
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: unrecorded-arrival-b
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an extra feed arrival absent from both identity blocks must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'unrecorded-arrival-b' is present under ## Open but is not recorded" \
        "the structure failure names the unrecorded extra feed identity"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an unrecorded extra arrival never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_arrival_overlapping_known_non_arrival() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "1" "0" "0" 'lane-a' ''
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' "- unclassified_departed_open: 1" >> "$ledger_path"
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
        "an unclassified Open row cannot also be recorded as an arrival"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'lane-a' overlaps known non-arrival classification" \
        "the structure failure names the identity counted under incompatible owners"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an overlapping arrival identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_identity_repeated_across_recorded_blocks() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "1" \
        'post-pin-arrival-a' \
        'post-pin-arrival-a'
    write_singleton_residual_identities "$tmpdir" 'post-pin-arrival-a'
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a recorded identity cannot be repeated across open-window identity blocks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: identity 'post-pin-arrival-a' is recorded as post_pin_arrival and singleton_residual" \
        "the structure failure names the repeated identity and incompatible recorded owners"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: identity 'post-pin-arrival-a' is recorded more than once as post_pin_arrival" \
        "the structure failure also names a duplicate repeated across arrival blocks"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a cross-block repeated identity never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_identity_block_fence_missing_before_heading() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome \
        "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a' \
        'post-pin-arrival-b'
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    perl -0pi -e 's/post-pin-arrival-a\n```\n\n### post_reconciliation_arrival identities/post-pin-arrival-a\n### post_reconciliation_arrival identities/' "$ledger_path"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: post-pin-arrival-b
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an identity block missing its closing fence before the next heading must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: heading '### post_pin_arrivals identities' has an unterminated fenced text identity block" \
        "the structure failure reports the unterminated identity block"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a malformed identity block never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_rejects_identity_heading_repeated_with_trailing_whitespace() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "1" "0" "0" 'post-pin-arrival-a' ''
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"
    printf '%s\n' \
        "" \
        "### post_pin_arrivals identities   " \
        "" \
        '```text' \
        'post-pin-arrival-b' \
        '```' \
        >> "$ledger_path"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a repeated identity heading with trailing whitespace must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: heading '### post_pin_arrivals identities' count=2 expected=1" \
        "the repeated heading diagnostic treats trailing whitespace as insignificant"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a repeated identity heading never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

# The cases below pin the singleton residual as an identity-owned summand. A
# residual that is only a scalar cannot be told apart from an unrecorded arrival,
# so the scalar must be backed by named identities and the guard must never
# exempt an Open record by its position in the feed.

test_structure_check_requires_singleton_residual_identity_cardinality() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    # The scalar claims one held-back singleton but names none, so the arithmetic
    # still totals unclassified(1) + singleton(1) = 2 against a 2-record window.
    # Only the identity contract can catch the unowned record.
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

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a singleton residual scalar without named identities must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: singleton_residual_open=1 must equal singleton residual identity count=0" \
        "the structure failure reports both the scalar and the identity cardinality"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'singleton-residual-a' is present under ## Open but is not recorded" \
        "an unowned Open record is reported even when the totals happen to balance"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an unnamed singleton residual never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_reports_missing_singleton_residual_identity() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: singleton-residual-a
  status: open'
    pin="$(pin_current_feed "$tmpdir" "pin missing singleton fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    # The named residual has left ## Open, so the scalar overstates the window by
    # one record and the diagnostic must name the residual rather than an arrival.
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'
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
        "a named singleton residual absent from ## Open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: singleton_residual identity 'singleton-residual-a' is missing from ## Open" \
        "the structure failure names the absent residual identity and its record kind"
    assert_not_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'singleton-residual-a' is missing from ## Open" \
        "a singleton residual is never misreported as a post-pin arrival"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an absent singleton residual never reaches the structure success verdict"
    rm -rf "$tmpdir"
}

test_structure_check_accepts_pinned_open_singleton_residual_identity() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
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
    pin="$(pin_current_feed "$tmpdir" "pin singleton fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "a pinned Open singleton residual recorded by identity must pass structure checks"
    assert_eq "$RUN_OUTPUT" "STRUCTURE_OK" \
        "the pinned singleton residual fixture reports the exact success verdict"
    rm -rf "$tmpdir"
}

# Both orderings carry the same four ## Open records: the ledger's unclassified
# lane, the named singleton residual, the named historical arrival, and one
# unrecorded arrival. The unrecorded identity is the only legitimate defect, and
# the verdict must be identical in both orderings.
assert_singleton_residual_never_absorbs_unrecorded_arrival() {
    local open_rows="$1" ordering="$2"
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: singleton-residual-a
  status: open'
    pin="$(pin_current_feed "$tmpdir" "pin singleton ordering fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "1" "0" "1" 'post-pin-arrival-a' ''
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'
    write_feed "$tmpdir" "$open_rows" '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an unrecorded arrival must fail alongside a named singleton residual ($ordering)"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'unrecorded-arrival-b' is present under ## Open but is not recorded" \
        "the unrecorded arrival identity is the one reported ($ordering)"
    assert_not_contains "$RUN_OUTPUT" "'singleton-residual-a'" \
        "the named singleton residual is never reported as the defect ($ordering)"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a singleton residual never absorbs an unrecorded arrival ($ordering)"
    rm -rf "$tmpdir"
}

test_structure_check_keeps_unrecorded_arrival_out_of_singleton_allowance() {
    assert_singleton_residual_never_absorbs_unrecorded_arrival '- lane_id: lane-a
  status: open
- lane_id: singleton-residual-a
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: unrecorded-arrival-b
  status: open' "recorded identities first"
}

test_structure_check_diagnosis_survives_open_row_reordering() {
    assert_singleton_residual_never_absorbs_unrecorded_arrival '- lane_id: unrecorded-arrival-b
  status: open
- lane_id: post-pin-arrival-a
  status: open
- lane_id: singleton-residual-a
  status: open
- lane_id: lane-a
  status: open' "unrecorded arrival first"
}

# The pinned-open allowance is deliberately narrow: it only exempts a
# `singleton_residual`. A `post_pin_arrival` recorded for an identity that was
# already under `## Open` at the pinned base SHA must still be rejected as an
# overlap. The open-window arithmetic balances exactly here
# (unclassified(1) + historical(1) = 2 = feed_open_window), so the overlap check
# is the sole detector — deleting `kind == "singleton_residual"` from
# `singleton_from_pinned_open` reddens this case with `STRUCTURE_OK`.
test_structure_check_rejects_post_pin_arrival_overlapping_pinned_open() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: pinned-open-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    pin="$(pin_current_feed "$tmpdir" "pin post-pin arrival overlap fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "1" "0" "0" 'pinned-open-a' ''

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a post-pin arrival already pinned-open must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'pinned-open-a' overlaps known non-arrival classification" \
        "the pinned-open overlap names the identity claimed as a post-pin arrival"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a pinned-open identity claimed as an arrival never reaches structure success"
    rm -rf "$tmpdir"
}

# The pinned-open allowance also excludes a residual that carries any hard
# non-arrival classification. A `singleton_residual` that is both pinned-open and
# a disposition-ledger row must be rejected as an overlap. Deleting the
# `ledger_disposition|pinned_out_of_window_open` exclusion
# from `singleton_from_pinned_open` removes exactly this overlap diagnostic,
# reddening the assertion below.
test_structure_check_rejects_singleton_residual_overlapping_ledger_unclassified() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
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
    pin="$(pin_current_feed "$tmpdir" "pin singleton ledger overlap fixture")"
    # `singleton-residual-a` is both a pinned-open feed record and an
    # `unclassified` disposition row, so it carries the `ledger_disposition`
    # disposition classification the pinned-open allowance must refuse.
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |
| singleton-residual-a | 1 | handoff-s | summary s | unclassified | |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a pinned-open singleton residual that is also an unclassified row must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: singleton_residual identity 'singleton-residual-a' overlaps known non-arrival classification" \
        "the ledger-unclassified overlap names the residual claimed as pinned-open"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a residual overlapping a hard classification never reaches structure success"
    rm -rf "$tmpdir"
}

# Every disposition row owns its lane identity, including terminal rows that do
# not contribute to the open-window census. This fixture balances exactly at
# unclassified(1) + singleton_residual(1) = feed_open_window(2), so only the
# identity-overlap check can reject laundering the `done` lane as a singleton.
test_structure_check_rejects_pinned_singleton_overlapping_done_disposition() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
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
    pin="$(pin_current_feed "$tmpdir" "pin done disposition overlap fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |
| singleton-residual-a | 1 | handoff-s | summary s | done | proof.md |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'singleton-residual-a'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a pinned-open singleton residual owned by a done disposition must fail"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: singleton_residual identity 'singleton-residual-a' overlaps known non-arrival classification" \
        "the done-disposition overlap names the claimed singleton residual"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a done identity laundered as a singleton never reaches structure success"
    rm -rf "$tmpdir"
}

# Terminal dispositions are identity owners for overlap detection, but that does
# not authorize their rows to appear unrecorded under ## Open. Here the terminal
# row replaces an absent unclassified row, so both aggregate counts equal two;
# identity membership must be the sole detector.
test_structure_check_rejects_unrecorded_terminal_open_cancellation() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "3" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |
| missing-unclassified-a | 1 | handoff-m | summary m | unclassified | |
| terminal-open-a | 1 | handoff-t | summary t | done | proof.md |"
    write_rewrite_outcome "$tmpdir" "0" "0" "0"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: terminal-open-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a terminal row cannot replace an absent unclassified Open row"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'terminal-open-a' is present under ## Open but is not recorded" \
        "the balanced cancellation names the unauthorized terminal Open row"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "balanced arithmetic cannot hide an unauthorized terminal Open identity"
    rm -rf "$tmpdir"
}

# A terminal row that was already under ## Open at the pinned base SHA is still
# owned by the disposition ledger. The pinned-open owner proves provenance, not
# authorization for an unrecorded current Open row.
test_structure_check_rejects_unrecorded_pinned_terminal_open() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: terminal-open-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    pin="$(pin_current_feed "$tmpdir" "pin terminal open fixture")"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |
| terminal-open-a | 1 | handoff-t | summary t | done | proof.md |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "0" "0" "0"

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a pinned-open terminal row cannot remain under ## Open unrecorded"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: post_pin_arrival identity 'terminal-open-a' is present under ## Open but is not recorded" \
        "the pinned terminal Open row is diagnosed by identity"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a pinned terminal Open identity never reaches structure success"
    rm -rf "$tmpdir"
}

# A singleton residual is residue from the pinned Open set, not a label for a
# later arrival. The current feed has two rows and the arithmetic balances at
# unclassified(1) + singleton_residual(1), so pinned-origin membership is the
# sole distinction between this defect and a legitimate residual.
test_structure_check_rejects_post_pin_arrival_recorded_as_singleton() {
    local tmpdir pin
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    pin="$(pin_current_feed \
        "$tmpdir" "pin feed before singleton laundering fixture")"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "$pin"
    write_rewrite_outcome "$tmpdir" "0" "0" "1"
    write_singleton_residual_identities "$tmpdir" 'post-pin-arrival-a'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a post-pin arrival cannot be recorded as a singleton residual"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: singleton_residual identity 'post-pin-arrival-a' was not under ## Open at pinned base SHA" \
        "the pinned-origin failure names the arrival laundered as a singleton"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a post-pin arrival claimed as a singleton never reaches structure success"
    rm -rf "$tmpdir"
}

# Arrival membership is defined relative to the pinned feed, so an unreadable
# pin cannot be treated as an empty baseline. This fixture otherwise balances
# exactly and used to reach STRUCTURE_OK after git-show failures were discarded.
test_structure_check_rejects_unreadable_pinned_feed() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: post-pin-arrival-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |" \
        "0000000000000000000000000000000000000000"
    write_rewrite_outcome "$tmpdir" "1" "0" "0" \
        'post-pin-arrival-a'

    run_structure "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an unreadable pinned feed must fail structure checks"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: pinned feed snapshot is unavailable at base SHA '0000000000000000000000000000000000000000'" \
        "the unavailable pinned snapshot diagnostic names the configured SHA"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "an unreadable pinned feed never reaches structure success"
    rm -rf "$tmpdir"
}

test_structure_check_requires_pinned_feed() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: closed-a
  status: closed
  resolution: |
    console_prep B3
    FJ-7
    mirror-leak
    serial scheduling row'
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_rewrite_outcome "$tmpdir" "0" "0" "0"

    run_structure_requiring_pin "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "the repository structure contract requires a pinned feed"
    assert_contains "$RUN_OUTPUT" \
        "STRUCTURE_FAIL: TRIAGE.md must contain exactly one 40-hex pinned base SHA" \
        "a missing pinned feed has a specific structural diagnostic"
    assert_not_contains "$RUN_OUTPUT" "STRUCTURE_OK" \
        "a missing pinned feed never reaches structure success"
    rm -rf "$tmpdir"
}

test_structure_check_accepts_reconciled_feed
test_structure_check_reports_missing_marker
test_structure_check_accepts_generator_quoted_residual_row
test_structure_check_reports_missing_marker_in_quoted_row
test_structure_check_requires_quoted_markers_in_one_closed_resolution
test_structure_check_rejects_quoted_marker_text_outside_closed_resolution
test_structure_check_rejects_unterminated_quoted_resolution
test_structure_check_rejects_text_after_quoted_resolution
test_structure_check_rejects_detached_quoted_resolution
test_structure_check_rejects_duplicate_quoted_resolution
test_structure_check_rejects_literal_then_quoted_resolution
test_structure_check_rejects_literal_then_literal_resolution
test_structure_check_counts_singleton_residual_open_in_open_window
test_structure_check_reports_singleton_residual_open_mismatch
test_structure_check_requires_singleton_residual_open_line
test_structure_check_subtracts_unclassified_departed_from_open_window
test_structure_check_reports_unclassified_departed_open_in_diagnostic
test_structure_check_rejects_malformed_unclassified_departed_open
test_structure_check_rejects_departed_count_exceeding_unclassified
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
test_structure_check_reconciles_honest_post_pin_arrival
test_structure_check_reports_missing_post_pin_arrival
test_structure_check_reports_duplicate_post_pin_arrival
test_structure_check_reports_post_pin_arrival_outside_open
test_structure_check_reports_post_pin_arrival_cross_section_duplicate
test_structure_check_reports_unrecorded_extra_post_pin_arrival
test_structure_check_rejects_arrival_overlapping_known_non_arrival
test_structure_check_rejects_identity_repeated_across_recorded_blocks
test_structure_check_rejects_identity_block_fence_missing_before_heading
test_structure_check_rejects_identity_heading_repeated_with_trailing_whitespace
test_structure_check_requires_singleton_residual_identity_cardinality
test_structure_check_reports_missing_singleton_residual_identity
test_structure_check_accepts_pinned_open_singleton_residual_identity
test_structure_check_rejects_post_pin_arrival_overlapping_pinned_open
test_structure_check_rejects_singleton_residual_overlapping_ledger_unclassified
test_structure_check_rejects_pinned_singleton_overlapping_done_disposition
test_structure_check_rejects_unrecorded_terminal_open_cancellation
test_structure_check_rejects_unrecorded_pinned_terminal_open
test_structure_check_rejects_post_pin_arrival_recorded_as_singleton
test_structure_check_rejects_unreadable_pinned_feed
test_structure_check_requires_pinned_feed
test_structure_check_keeps_unrecorded_arrival_out_of_singleton_allowance
test_structure_check_diagnosis_survives_open_row_reordering
