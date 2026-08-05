#!/usr/bin/env bash
# Fixture helpers and ledger-accounting cases sourced by the accounting guard.

make_fixture() {
    local repo_root="$1"
    mkdir -p "$repo_root/docs/audits/followup-triage" "$repo_root/chats/icg"
}

write_ledger() {
    local repo_root="$1" denominator="$2" rows="$3" pinned_sha="${4:-}"
    local pinned_sha_line=""
    if [ -n "$pinned_sha" ]; then
        pinned_sha_line="- Pinned base SHA: \`$pinned_sha\`"
    fi
    printf '%s\n' \
        "# Follow-up triage ledger" \
        "" \
        "## Pinned census" \
        "" \
        "$pinned_sha_line" \
        "- open_window: $denominator" \
        "- out_of_window_open: 0" \
        "" \
        "## Disposition ledger" \
        "" \
        "| Lane ID | Entry count | Source handoff / spot checks | Summary | Disposition | Evidence |" \
        "| --- | ---: | --- | --- | --- | --- |" \
        "$rows" \
        > "$repo_root/docs/audits/followup-triage/TRIAGE.md"
}

write_feed() {
    local repo_root="$1" open_rows="$2" closed_rows="${3:-}"
    printf '%s\n' \
        "## Open" \
        "" \
        '```yaml' \
        "$open_rows" \
        '```' \
        "" \
        "## Harvested" \
        "" \
        '```yaml' \
        '```' \
        "" \
        "## Closed" \
        "" \
        '```yaml' \
        "$closed_rows" \
        '```' \
        > "$repo_root/chats/icg/_followups.md"
}

pin_current_feed() {
    local repo_root="$1" message="$2"
    git -C "$repo_root" init -q
    git -C "$repo_root" add chats/icg/_followups.md
    git -C "$repo_root" \
        -c user.email=fixture@example.invalid \
        -c user.name=Fixture \
        commit -q -m "$message"
    git -C "$repo_root" rev-parse HEAD
}

write_rewrite_outcome() {
    local repo_root="$1" post_pin_arrivals="$2" readmitted_out_of_window="$3"
    local singleton_residual_open="${4:-0}"
    local post_pin_arrival_identities="${5:-}"
    local post_reconciliation_arrival_identities="${6:-}"
    printf '%s\n' \
        "" \
        "## Rewrite outcome" \
        "" \
        "- singleton_residual_open: $singleton_residual_open" \
        "- post_pin_arrivals: $post_pin_arrivals" \
        "- readmitted_out_of_window: $readmitted_out_of_window" \
        >> "$repo_root/docs/audits/followup-triage/TRIAGE.md"
    write_post_pin_arrival_identities "$repo_root" "$post_pin_arrival_identities"
    write_post_reconciliation_arrival_identities \
        "$repo_root" "$post_reconciliation_arrival_identities"
}

write_identity_block() {
    local repo_root="$1" heading="$2" identities="$3"
    printf '%s\n' \
        "" \
        "$heading" \
        "" \
        '```text' \
        >> "$repo_root/docs/audits/followup-triage/TRIAGE.md"
    if [ -n "$identities" ]; then
        printf '%s\n' "$identities" \
            >> "$repo_root/docs/audits/followup-triage/TRIAGE.md"
    fi
    printf '%s\n' '```' >> "$repo_root/docs/audits/followup-triage/TRIAGE.md"
}

# Appends the frozen reconciliation-snapshot post-pin arrivals. The
# `post_pin_arrivals` scalar must match this block's cardinality.
write_post_pin_arrival_identities() {
    local repo_root="$1" identities="$2"
    write_identity_block \
        "$repo_root" "### post_pin_arrivals identities" "$identities"
}

write_post_reconciliation_arrival_identities() {
    local repo_root="$1" identities="$2"
    write_identity_block \
        "$repo_root" "### post_reconciliation_arrival identities" "$identities"
}

# The singleton residual block is optional by absence, so it is written only by
# the cases that hold a pinned singleton under `## Open`. Call it after
# `write_rewrite_outcome`, whose `singleton_residual_open` scalar must match this
# block's cardinality.
write_singleton_residual_identities() {
    local repo_root="$1" identities="$2"
    write_identity_block \
        "$repo_root" "### singleton_residual_open identities" "$identities"
}

run_check() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo_root" bash "$CHECK_SCRIPT" --check-only 2>&1)" \
        || RUN_EXIT_CODE=$?
}

run_structure() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FJCLOUD_STRUCTURE_FIXTURE_ALLOW_MISSING_PIN=1 \
            FJCLOUD_REPO_ROOT="$repo_root" \
            bash "$CHECK_SCRIPT" --structure-only 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_structure_requiring_pin() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FJCLOUD_REPO_ROOT="$repo_root" \
            bash "$CHECK_SCRIPT" --structure-only 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_repository_verdict_fixture() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FOLLOWUP_TRIAGE_TEST_CHILD=1 \
            FJCLOUD_STRUCTURE_FIXTURE_ALLOW_MISSING_PIN=1 \
            FJCLOUD_REPO_ROOT="$repo_root" \
            bash "$CHECK_SCRIPT" --repo-verdict 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_ledger_only() {
    local ledger_path="$1"
    shift
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FOLLOWUP_TRIAGE_TEST_CHILD=1 \
            bash "$CHECK_SCRIPT" --ledger-only "$ledger_path" "$@" 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_ledger_only_without_path() {
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FOLLOWUP_TRIAGE_TEST_CHILD=1 bash "$CHECK_SCRIPT" --ledger-only 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_verify_pinned_scope() {
    local repo_root="$1"
    shift
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        FOLLOWUP_TRIAGE_TEST_CHILD=1 FJCLOUD_REPO_ROOT="$repo_root" \
            bash "$CHECK_SCRIPT" --verify-pinned-scope "$@" 2>&1
    )" || RUN_EXIT_CODE=$?
}

write_pinned_scope_fixture() {
    local repo_root="$1" rows="$2" pin
    write_feed "$repo_root" '- lane_id: lane-a::first
  status: open
- lane_id: lane-b
  status: open
- lane_id: lane-a::second
  status: open
- lane_id: lane-c
  status: open
- lane_id: lane-a::third
  status: open
- lane_id: lane-b::second
  status: open'
    pin="$(pin_current_feed "$repo_root" "pin scope fixture")"
    write_ledger "$repo_root" "6" "$rows" "$pin"
}

test_readme_validation_command_uses_concrete_shard_path() {
    local readme_path bash_examples
    readme_path="$DEFAULT_REPO_ROOT/docs/audits/followup-triage/shards/README.md"
    bash_examples="$(
        awk '
            /^```bash[[:space:]]*$/ {
                in_bash_example = 1
                next
            }
            in_bash_example && /^```[[:space:]]*$/ {
                in_bash_example = 0
                next
            }
            in_bash_example
        ' "$readme_path"
    )"

    assert_contains "$bash_examples" "shard_01.md" \
        "the README validation command uses a copy-pasteable concrete shard path"
    assert_not_contains "$bash_examples" "<NN>" \
        "the README validation command contains no shell-active shard placeholder"
}

test_ledger_only_exact_weighted_arithmetic_passes() {
    local tmpdir rows ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 2 | handoff-a | summary a | done | src/a.rs:10 |
| lane-b | 1 | handoff-b | summary b | superseded | docs/new_owner.md |
| lane-c | 1 | handoff-c | summary c | open-rehomed | |
| lane-d | 1 | handoff-d | summary d | abandon | retired surface |
| lane-e | 1 | handoff-e | summary e | unclassified | |'
    write_ledger "$tmpdir" "6" "$rows"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "0" "a balanced shard ledger should pass"
    assert_contains "$RUN_OUTPUT" \
        "OK: entries_classified=5 of 6; done=2 superseded=1 open_rehomed=1 abandon=1 unclassified=1 total=6 denominator=6" \
        "ledger-only success reports exact weighted arithmetic"
    rm -rf "$tmpdir"
}

test_ledger_only_short_ledger_fails() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" "a short shard ledger must fail"
    assert_contains "$RUN_OUTPUT" "MISMATCH" \
        "a short shard ledger reports MISMATCH"
    assert_contains "$RUN_OUTPUT" "total=1 denominator=2" \
        "ledger-only mismatch exposes the exact failed equality"
    rm -rf "$tmpdir"
}

test_ledger_only_invalid_disposition_fails() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-b | 1 | handoff-b | summary b | deferred | evidence |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" "an invalid shard disposition must fail"
    assert_contains "$RUN_OUTPUT" "lane-b has invalid disposition 'deferred'" \
        "invalid disposition output names the shard row and value"
    rm -rf "$tmpdir"
}

test_ledger_only_done_without_evidence_fails() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-c | 1 | handoff-c | summary c | done | |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" "a done shard row without evidence must fail"
    assert_contains "$RUN_OUTPUT" "missing evidence for lane-c (done)" \
        "missing evidence output names the done shard row"
    rm -rf "$tmpdir"
}

test_ledger_only_missing_trailing_evidence_cell_fails() {
    local tmpdir rows ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 1 | handoff-a | summary a | done | src/a.rs:10 |
| lane-b | 1 | handoff-b | summary b | done |'
    write_ledger "$tmpdir" "2" "$rows"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "a row missing a trailing Evidence cell must fail"
    assert_contains "$RUN_OUTPUT" "lane-b lacks required cell 'Evidence'" \
        "short-row output names the malformed row and missing column"
    assert_not_contains "$RUN_OUTPUT" "OK" \
        "a malformed short row never inherits prior evidence and passes"
    rm -rf "$tmpdir"
}

test_ledger_only_blank_lane_id_row_is_rejected() {
    local tmpdir rows ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    # The named row alone already balances the denominator, so a blank-Lane-ID
    # row that is silently dropped as a table separator would produce a false OK
    # while discarding its entry count.
    rows='| lane-a | 1 | handoff-a | summary a | unclassified | |
|  | 2 | handoff-b | summary b | unclassified | |'
    write_ledger "$tmpdir" "1" "$rows"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" "a ledger row with a blank Lane ID must fail"
    assert_contains "$RUN_OUTPUT" "lacks a Lane ID" \
        "a blank Lane ID cell is reported as a parse error, not skipped"
    assert_not_contains "$RUN_OUTPUT" "OK" \
        "a discarded blank-Lane-ID row never yields a passing verdict"
    rm -rf "$tmpdir"
}

test_ledger_only_cumulative_entry_count_overflow_fails() {
    local tmpdir rows ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows="| lane-max-a | $MAX_SAFE_ENTRY_COUNT | handoff-a | summary a | unclassified | |
| lane-max-b | $MAX_SAFE_ENTRY_COUNT | handoff-b | summary b | unclassified | |"
    write_ledger "$tmpdir" "$MAX_SAFE_ENTRY_COUNT" "$rows"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "individually safe entry counts that overflow when summed must fail"
    assert_contains "$RUN_OUTPUT" \
        "lane-max-b cumulative entry count exceeds supported width" \
        "cumulative overflow output names the row that broke the running total"
    assert_not_contains "$RUN_OUTPUT" "OK" \
        "a cumulative overflow never wraps into a success verdict"
    rm -rf "$tmpdir"
}

test_ledger_only_max_safe_entry_count_passes() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "$MAX_SAFE_ENTRY_COUNT" \
        "| lane-max | $MAX_SAFE_ENTRY_COUNT | handoff-max | summary max | unclassified | |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "the largest safe integer entry count should pass"
    assert_contains "$RUN_OUTPUT" "total=$MAX_SAFE_ENTRY_COUNT denominator=$MAX_SAFE_ENTRY_COUNT" \
        "max safe count output preserves exact arithmetic"
    rm -rf "$tmpdir"
}

test_ledger_only_oversized_entry_count_fails() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-huge | 92233720368547758070 | handoff-huge | summary huge | unclassified | |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "an oversized digit-only entry count must fail before arithmetic"
    assert_contains "$RUN_OUTPUT" \
        "lane-huge has unsupported entry count width '92233720368547758070'" \
        "oversized count output names the malformed row and value"
    assert_not_contains "$RUN_OUTPUT" "OK" \
        "an oversized entry count never overflows into a success verdict"
    rm -rf "$tmpdir"
}

test_ledger_only_empty_ledger_is_vacuous() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "0" ""
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only "$ledger_path"

    assert_eq "$RUN_EXIT_CODE" "1" "an empty shard ledger must fail"
    assert_contains "$RUN_OUTPUT" "VACUOUS" \
        "an empty shard ledger reports VACUOUS"
    assert_not_contains "$RUN_OUTPUT" "OK" \
        "an empty shard ledger never reports OK"
    rm -rf "$tmpdir"
}

test_ledger_only_requires_exactly_one_path() {
    local tmpdir ledger_path
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    ledger_path="$tmpdir/docs/audits/followup-triage/TRIAGE.md"

    run_ledger_only_without_path
    assert_eq "$RUN_EXIT_CODE" "2" "ledger-only without a path is a usage error"
    assert_contains "$RUN_OUTPUT" "ERROR: --ledger-only requires exactly one path" \
        "missing ledger-only path reports a clear error"

    run_ledger_only "$ledger_path" "$ledger_path"
    assert_eq "$RUN_EXIT_CODE" "2" "ledger-only with extra paths is a usage error"
    assert_contains "$RUN_OUTPUT" "ERROR: --ledger-only requires exactly one path" \
        "extra ledger-only path reports a clear error"
    rm -rf "$tmpdir"
}

test_exact_weighted_arithmetic_passes() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 2 | handoff-a | summary a | done | src/a.rs:10 |
| lane-b | 1 | handoff-b | summary b | superseded | docs/new_owner.md |
| lane-c | 1 | handoff-c | summary c | open-rehomed | ROADMAP.md:20 |
| lane-d | 1 | handoff-d | summary d | abandon | retired surface |
| lane-e | 1 | handoff-e | summary e | unclassified | |'
    write_ledger "$tmpdir" "6" "$rows"
    write_feed "$tmpdir" '- lane_id: lane-e
  status: open'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "weighted disposition arithmetic should pass"
    assert_contains "$RUN_OUTPUT" \
        "done=2 superseded=1 open_rehomed=1 abandon=1 unclassified=1 total=6 denominator=6" \
        "success reports exact weighted arithmetic with normalized open_rehomed"
    assert_contains "$RUN_OUTPUT" "entries_classified=5 of 6" \
        "success reports classified entries against the pinned denominator"
    rm -rf "$tmpdir"
}

test_arithmetic_mismatch_fails() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "2" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open
- lane_id: lane-b
  status: open'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "an undercount must fail accounting"
    assert_contains "$RUN_OUTPUT" "MISMATCH" "an undercount reports an arithmetic mismatch"
    assert_contains "$RUN_OUTPUT" "total=1 denominator=2" \
        "mismatch output exposes the exact failed equality"
    rm -rf "$tmpdir"
}

test_required_evidence_is_enforced() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 1 | handoff-a | summary a | done | |
| lane-b | 1 | handoff-b | summary b | superseded | |
| lane-c | 1 | handoff-c | summary c | abandon | |
| lane-d | 1 | handoff-d | summary d | unclassified | |'
    write_ledger "$tmpdir" "4" "$rows"
    write_feed "$tmpdir" '- lane_id: lane-d
  status: open'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "missing evidence for closed dispositions must fail"
    assert_contains "$RUN_OUTPUT" "lane-a (done)" "missing done evidence names its row"
    assert_contains "$RUN_OUTPUT" "lane-b (superseded)" \
        "missing superseded evidence names its row"
    assert_contains "$RUN_OUTPUT" "lane-c (abandon)" \
        "missing abandon evidence names its row"
    assert_not_contains "$RUN_OUTPUT" "lane-d (unclassified)" \
        "unclassified rows may keep evidence empty"
    rm -rf "$tmpdir"
}

test_zero_denominator_is_vacuous() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "0" ""
    write_feed "$tmpdir" ""

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "zero denominator must fail"
    assert_contains "$RUN_OUTPUT" "VACUOUS" "zero denominator reports VACUOUS"
    assert_contains "$RUN_OUTPUT" "entries_classified=0 of 0" \
        "vacuous output states the exact zero-of-zero condition"
    assert_not_contains "$RUN_OUTPUT" "OK" "zero denominator never reports OK"
    rm -rf "$tmpdir"
}

test_feed_parser_is_heading_bounded() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_ledger "$tmpdir" "1" \
        "| lane-a | 1 | handoff-a | summary a | unclassified | |"
    write_feed "$tmpdir" '- lane_id: lane-a
  status: open' '- lane_id: lane-z
  status: open'

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "heading-bounded feed fixture should account cleanly"
    assert_contains "$RUN_OUTPUT" "feed_open_window=1" \
        "feed parser counts only lane IDs inside Open"
    assert_contains "$RUN_OUTPUT" "feed_out_of_window_open=1" \
        "feed parser reports open records outside Open separately"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_accepts_exact_lane_map() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 3 | handoff-a | summary a | unclassified | gap a |
| lane-b | 2 | handoff-b | summary b | unclassified | gap b |'
    write_pinned_scope_fixture "$tmpdir" "$rows"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "0" "an exact pinned scope should pass"
    assert_contains "$RUN_OUTPUT" \
        "PINNED_SCOPE_OK: minimum_count=2 lanes=2 records=5" \
        "scope success reports the exact threshold, lane count, and weighted records"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_missing_lane() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_pinned_scope_fixture "$tmpdir" \
        "| lane-a | 3 | handoff-a | summary a | unclassified | gap a |"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "a missing pinned lane must fail"
    assert_contains "$RUN_OUTPUT" "MISSING: lane-b" \
        "missing-lane output names the absent pinned lane"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_extra_lane() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 3 | handoff-a | summary a | unclassified | gap a |
| lane-b | 2 | handoff-b | summary b | unclassified | gap b |
| lane-z | 1 | handoff-z | summary z | unclassified | gap z |'
    write_pinned_scope_fixture "$tmpdir" "$rows"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "an unknown ledger lane must fail"
    assert_contains "$RUN_OUTPUT" "EXTRA: lane-z is absent from the pinned map" \
        "extra-lane output names the unknown ledger lane"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_duplicate_lane() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 3 | handoff-a | summary a | unclassified | gap a |
| lane-a | 3 | handoff-a-2 | summary a2 | unclassified | gap a2 |
| lane-b | 2 | handoff-b | summary b | unclassified | gap b |'
    write_pinned_scope_fixture "$tmpdir" "$rows"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "a duplicate ledger lane must fail"
    assert_contains "$RUN_OUTPUT" "DUPLICATE: lane-a" \
        "duplicate-lane output names the repeated ledger lane"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_below_threshold_lane() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 3 | handoff-a | summary a | unclassified | gap a |
| lane-b | 2 | handoff-b | summary b | unclassified | gap b |
| lane-c | 1 | handoff-c | summary c | unclassified | gap c |'
    write_pinned_scope_fixture "$tmpdir" "$rows"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "a below-threshold pinned lane must fail"
    assert_contains "$RUN_OUTPUT" \
        "BELOW_THRESHOLD: lane-c pinned_count=1 minimum_count=2" \
        "below-threshold output names the lane and both counts"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_miscounted_lane() {
    local tmpdir rows
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    rows='| lane-a | 2 | handoff-a | summary a | unclassified | gap a |
| lane-b | 2 | handoff-b | summary b | unclassified | gap b |'
    write_pinned_scope_fixture "$tmpdir" "$rows"

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "a miscounted pinned lane must fail"
    assert_contains "$RUN_OUTPUT" \
        "MISCOUNTED: lane-a entry_count=2 pinned_count=3" \
        "miscount output names the lane and both counts"
    rm -rf "$tmpdir"
}

test_verify_pinned_scope_rejects_vacuous_ledger() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir"
    write_pinned_scope_fixture "$tmpdir" ""

    run_verify_pinned_scope "$tmpdir" 2 2 5

    assert_eq "$RUN_EXIT_CODE" "1" "a vacuous pinned scope must fail"
    assert_contains "$RUN_OUTPUT" "VACUOUS: disposition ledger has no rows" \
        "vacuous output explicitly rejects the zero-row result"
    rm -rf "$tmpdir"
}

test_readme_validation_command_uses_concrete_shard_path
test_ledger_only_exact_weighted_arithmetic_passes
test_ledger_only_short_ledger_fails
test_ledger_only_invalid_disposition_fails
test_ledger_only_done_without_evidence_fails
test_ledger_only_missing_trailing_evidence_cell_fails
test_ledger_only_blank_lane_id_row_is_rejected
test_ledger_only_cumulative_entry_count_overflow_fails
test_ledger_only_max_safe_entry_count_passes
test_ledger_only_oversized_entry_count_fails
test_ledger_only_empty_ledger_is_vacuous
test_ledger_only_requires_exactly_one_path
test_exact_weighted_arithmetic_passes
test_arithmetic_mismatch_fails
test_required_evidence_is_enforced
test_zero_denominator_is_vacuous
test_feed_parser_is_heading_bounded
test_verify_pinned_scope_accepts_exact_lane_map
test_verify_pinned_scope_rejects_missing_lane
test_verify_pinned_scope_rejects_extra_lane
test_verify_pinned_scope_rejects_duplicate_lane
test_verify_pinned_scope_rejects_below_threshold_lane
test_verify_pinned_scope_rejects_miscounted_lane
test_verify_pinned_scope_rejects_vacuous_ledger
