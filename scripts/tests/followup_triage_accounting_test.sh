#!/usr/bin/env bash
# Follow-up triage ledger accounting guard and fixture-backed contract tests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$SCRIPT_DIR/followup_triage_accounting_test.sh"
SHARD_TOOL="$DEFAULT_REPO_ROOT/scripts/followup_triage_shard.py"
MAX_SAFE_ENTRY_COUNT=9223372036854775807
readonly MAX_SAFE_ENTRY_COUNT

# This guard is the single owner of feed-structure invariants, so the residual
# marker list intentionally lives here rather than being copied into TRIAGE.md.
STRATUM4_RESIDUAL_MARKERS=(
    "console_prep B3"
    "FJ-7"
    "mirror-leak"
    "serial scheduling row"
)
readonly STRATUM4_RESIDUAL_MARKERS

# The disposition allowlist and its evidence rule live here because this guard
# is the single owner of the ledger row grammar for full-feed and shard runs
# alike. `entries_classified` sums the classified dispositions; the ledger total
# additionally folds in `unclassified`.
LEDGER_CLASSIFIED_DISPOSITIONS=("done" superseded open-rehomed abandon)
LEDGER_DISPOSITIONS=("${LEDGER_CLASSIFIED_DISPOSITIONS[@]}" unclassified)
LEDGER_EVIDENCE_REQUIRED_DISPOSITIONS=("done" superseded abandon)
readonly LEDGER_CLASSIFIED_DISPOSITIONS LEDGER_DISPOSITIONS LEDGER_EVIDENCE_REQUIRED_DISPOSITIONS

parse_open_window_denominator() {
    local ledger_path="$1"
    awk '
        /^- open_window: [0-9]+[[:space:]]*$/ {
            sub(/^- open_window: /, "")
            sub(/[[:space:]]*$/, "")
            print
        }
    ' "$ledger_path"
}

parse_disposition_rows() {
    local ledger_path="$1"
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        # A genuine markdown separator row has every cell made up solely of
        # dashes and alignment colons. Testing the whole row (rather than the
        # first cell alone) keeps a data row with a blank Lane ID from being
        # mistaken for a separator and having its entry count discarded.
        function is_separator_row(cell_count,   i) {
            for (i = 1; i <= cell_count; i++) {
                if (cell[i] == "" || cell[i] ~ /[^-:]/) {
                    return 0
                }
            }
            return cell_count > 0
        }
        function record_required_column(name) {
            required_column_count++
            required_column[required_column_count] = name
            if (required_max_column < column[name]) {
                required_max_column = column[name]
            }
        }
        /^## Disposition ledger[[:space:]]*$/ {
            in_ledger = 1
            next
        }
        in_ledger && /^## / {
            in_ledger = 0
        }
        !in_ledger || $0 !~ /^\|/ {
            next
        }
        {
            delete cell
            field_count = split($0, raw, "|")
            column_count = field_count - 2
            for (i = 1; i <= column_count; i++) {
                cell[i] = trim(raw[i + 1])
            }
            if (!header_seen && cell[1] == "Lane ID") {
                for (i = 1; i <= column_count; i++) {
                    column[cell[i]] = i
                }
                if (!column["Entry count"] || !column["Disposition"] ||
                    !column["Evidence"]) {
                    print "PARSE_ERROR\034ledger header lacks required columns"
                }
                record_required_column("Entry count")
                record_required_column("Disposition")
                record_required_column("Evidence")
                header_seen = 1
                next
            }
            if (!header_seen || is_separator_row(column_count)) {
                next
            }
            if (cell[1] == "") {
                print "PARSE_ERROR\034ledger row at line " NR " lacks a Lane ID"
                next
            }
            if (column_count < required_max_column) {
                for (i = 1; i <= required_column_count; i++) {
                    name = required_column[i]
                    if (column_count < column[name]) {
                        print "PARSE_ERROR\034" cell[1] " lacks required cell \047" name "\047"
                    }
                }
                next
            }
            print cell[column["Entry count"]] "\034" \
                cell[column["Disposition"]] "\034" \
                cell[column["Evidence"]] "\034" cell[1]
        }
        END {
            if (!header_seen) {
                print "PARSE_ERROR\034missing disposition ledger header"
            }
        }
    ' "$ledger_path"
}

is_safe_nonnegative_integer() {
    local value="$1"
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#value}" -lt "${#MAX_SAFE_ENTRY_COUNT}" ]; then
        return 0
    fi
    # Equal-width digit strings are intentionally compared lexicographically.
    # shellcheck disable=SC2071
    [ "${#value}" -eq "${#MAX_SAFE_ENTRY_COUNT}" ] &&
        [[ "$value" < "$MAX_SAFE_ENTRY_COUNT" || "$value" = "$MAX_SAFE_ENTRY_COUNT" ]]
}

list_contains() {
    local needle="$1" candidate
    shift

    for candidate in "$@"; do
        [ "$candidate" = "$needle" ] && return 0
    done
    return 1
}

disposition_accumulator_name() {
    # Ledger dispositions may contain dashes; shell variable names may not.
    printf 'count_%s' "${1//-/_}"
}

# Folds `addend` into the caller-scoped accumulator variable named by the first
# argument, refusing any addition that would overflow Bash's signed arithmetic.
add_entry_count_into() {
    local accumulator_name="$1" addend="$2" context="$3"
    local accumulated="${!accumulator_name:-0}"

    if ((addend > MAX_SAFE_ENTRY_COUNT - accumulated)); then
        echo "ERROR: $context cumulative entry count exceeds supported width" >&2
        return 1
    fi
    printf -v "$accumulator_name" '%d' "$((accumulated + addend))"
}

# Sums the given dispositions' accumulators into the caller-scoped variable
# named by the first argument.
sum_disposition_counts() {
    local target_name="$1" context="$2"
    local summed_disposition accumulator_name
    shift 2

    printf -v "$target_name" '%d' 0
    for summed_disposition in "$@"; do
        accumulator_name="$(disposition_accumulator_name "$summed_disposition")"
        add_entry_count_into "$target_name" "${!accumulator_name:-0}" "$context" ||
            return 1
    done
}

# Validates one parsed ledger row and folds its entry count into the caller's
# count_<disposition> accumulators. Returns 0 for a clean row, 1 for a parse
# error, and 2 for a row that accumulated but lacks its required evidence.
validate_and_accumulate_row() {
    local entry_count="$1" disposition="$2" evidence="$3" lane_id="$4"

    if [ "$entry_count" = "PARSE_ERROR" ]; then
        echo "ERROR: $disposition" >&2
        return 1
    fi
    if ! [[ "$entry_count" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: $lane_id has invalid entry count '$entry_count'" >&2
        return 1
    fi
    if ! is_safe_nonnegative_integer "$entry_count"; then
        echo "ERROR: $lane_id has unsupported entry count width '$entry_count'" >&2
        return 1
    fi
    if ! list_contains "$disposition" "${LEDGER_DISPOSITIONS[@]}"; then
        echo "ERROR: $lane_id has invalid disposition '$disposition'" >&2
        return 1
    fi
    if ! add_entry_count_into \
        "$(disposition_accumulator_name "$disposition")" "$entry_count" "$lane_id"; then
        return 1
    fi
    if [ -z "$evidence" ] &&
        list_contains "$disposition" "${LEDGER_EVIDENCE_REQUIRED_DISPOSITIONS[@]}"; then
        echo "ERROR: missing evidence for $lane_id ($disposition)" >&2
        return 2
    fi
    return 0
}

parse_feed_census() {
    local feed_path="$1"
    awk '
        /^## Open[[:space:]]*$/ {
            section = "open"
            next
        }
        /^## / {
            section = "other"
            next
        }
        section == "open" && /^- lane_id:/ {
            open_window++
        }
        section != "open" && /^[[:space:]]+status: open[[:space:]]*$/ {
            out_of_window_open++
        }
        END {
            printf "%d %d\n", open_window, out_of_window_open
        }
    ' "$feed_path"
}

validate_open_section_statuses() {
    local feed_path="$1"
    awk '
        function emit_lane() {
            if (!lane_seen) {
                return
            }
            if (lane_id == "") {
                print "STRUCTURE_FAIL: Open lane_id must not be empty"
                failures++
            } else if (status_count != 1) {
                printf "STRUCTURE_FAIL: Open lane %s has status count=%d expected=1\n", \
                    lane_id, status_count
                failures++
            } else if (status != "open") {
                printf "STRUCTURE_FAIL: Open lane %s has status \047%s\047 expected \047open\047\n", \
                    lane_id, status
                failures++
            }
        }
        /^## Open[[:space:]]*$/ {
            in_open = 1
            next
        }
        in_open && /^## / {
            emit_lane()
            lane_seen = 0
            lane_id = ""
            status = ""
            status_count = 0
            in_open = 0
            next
        }
        !in_open {
            next
        }
        /^- lane_id:/ {
            emit_lane()
            lane_seen = 1
            lane_id = $0
            sub(/^- lane_id:[[:space:]]*/, "", lane_id)
            status = ""
            status_count = 0
            next
        }
        /^[[:space:]]+status:[[:space:]]*/ {
            if (!lane_seen) {
                print "STRUCTURE_FAIL: Open section has detached status before lane_id"
                failures++
                next
            }
            value = $0
            sub(/^[[:space:]]+status:[[:space:]]*/, "", value)
            sub(/[[:space:]]*$/, "", value)
            status = value
            status_count++
        }
        END {
            emit_lane()
            exit failures > 0 ? 1 : 0
        }
    ' "$feed_path"
}

parse_closed_resolution_rows() {
    local feed_path="$1"
    awk '
        function emit_resolution() {
            if (lane_id != "" && status == "closed" && resolution_seen) {
                print lane_id "\034" resolution
            }
        }
        /^## Closed[[:space:]]*$/ {
            in_closed = 1
            next
        }
        in_closed && /^## / {
            emit_resolution()
            lane_id = ""
            status = ""
            in_closed = 0
        }
        !in_closed {
            next
        }
        /^- lane_id:/ {
            emit_resolution()
            lane_id = $0
            sub(/^- lane_id:[[:space:]]*/, "", lane_id)
            status = ""
            resolution = ""
            resolution_seen = 0
            in_resolution = 0
            next
        }
        lane_id != "" && /^  status:[[:space:]]*closed[[:space:]]*$/ {
            status = "closed"
            next
        }
        lane_id != "" && /^[[:space:]]+resolution:[[:space:]]*\|[[:space:]]*$/ {
            resolution_seen = 1
            in_resolution = 1
            next
        }
        in_resolution && /^    / {
            line = $0
            sub(/^    /, "", line)
            resolution = resolution "\035" line
            next
        }
        in_resolution {
            in_resolution = 0
        }
        END {
            emit_resolution()
        }
    ' "$feed_path"
}

closed_resolution_contains_marker() {
    local feed_path="$1" required_marker="$2"
    local lane_id resolution

    while IFS=$'\034' read -r lane_id resolution; do
        [[ "$resolution" == *"$required_marker"* ]] && return 0
    done < <(parse_closed_resolution_rows "$feed_path")
    return 1
}

closed_resolution_contains_all_residual_markers() {
    local feed_path="$1"
    local lane_id resolution marker contains_all

    while IFS=$'\034' read -r lane_id resolution; do
        contains_all=1
        for marker in "${STRATUM4_RESIDUAL_MARKERS[@]}"; do
            if [[ "$resolution" != *"$marker"* ]]; then
                contains_all=0
                break
            fi
        done
        [ "$contains_all" -eq 1 ] && return 0
    done < <(parse_closed_resolution_rows "$feed_path")
    return 1
}

validate_residual_markers() {
    local feed_path="$1"
    local marker missing_marker=0

    closed_resolution_contains_all_residual_markers "$feed_path" && return 0

    for marker in "${STRATUM4_RESIDUAL_MARKERS[@]}"; do
        if ! closed_resolution_contains_marker "$feed_path" "$marker"; then
            echo "STRUCTURE_FAIL: missing residual marker '$marker'"
            missing_marker=1
        fi
    done
    if [ "$missing_marker" -eq 0 ]; then
        echo "STRUCTURE_FAIL: residual markers must share one Closed resolution row"
    fi
    return 1
}

parse_rewrite_outcome_value() {
    local ledger_path="$1" key="$2"
    awk -v key="$key" '
        /^## Rewrite outcome[[:space:]]*$/ {
            in_outcome = 1
            next
        }
        in_outcome && /^## / {
            in_outcome = 0
        }
        in_outcome && $0 ~ ("^- " key ": [0-9]+[[:space:]]*$") {
            sub("^- " key ": ", "")
            sub(/[[:space:]]*$/, "")
            print
        }
    ' "$ledger_path"
}

validate_rewrite_outcome_value() {
    local key="$1" value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "STRUCTURE_FAIL: TRIAGE.md must contain exactly one numeric $key line under ## Rewrite outcome"
        return 1
    fi
    if [[ "$value" =~ ^0[0-9]+$ ]]; then
        echo "STRUCTURE_FAIL: $key has noncanonical numeric value '$value'"
        return 1
    fi
    if ! is_safe_nonnegative_integer "$value"; then
        echo "STRUCTURE_FAIL: $key has unsupported entry count width '$value'"
        return 1
    fi
}

add_structure_open_window_count() {
    local target_name="$1" addend="$2" context="$3"
    local accumulated="${!target_name:-0}"

    if ((addend > MAX_SAFE_ENTRY_COUNT - accumulated)); then
        echo "STRUCTURE_FAIL: $context exceeds supported width"
        return 1
    fi
    printf -v "$target_name" '%d' "$((accumulated + addend))"
}

run_ledger_accounting_check() {
    local ledger_path="$1" feed_census="${2:-}"
    local denominator row_status
    local count_done=0 count_superseded=0 count_open_rehomed=0
    local count_abandon=0 count_unclassified=0
    local parse_errors=0 missing_evidence=0
    local entry_count disposition evidence lane_id

    if [ ! -f "$ledger_path" ]; then
        echo "ERROR: ledger input missing: $ledger_path" >&2
        return 1
    fi

    denominator="$(parse_open_window_denominator "$ledger_path")"
    if ! is_safe_nonnegative_integer "$denominator"; then
        echo "ERROR: ledger must contain exactly one numeric open_window denominator" >&2
        return 1
    fi

    while IFS=$'\034' read -r entry_count disposition evidence lane_id; do
        [ -n "$entry_count" ] || continue
        row_status=0
        validate_and_accumulate_row \
            "$entry_count" "$disposition" "$evidence" "$lane_id" || row_status=$?
        case "$row_status" in
            1) parse_errors=$((parse_errors + 1)) ;;
            2) missing_evidence=$((missing_evidence + 1)) ;;
        esac
    done < <(parse_disposition_rows "$ledger_path")

    local entries_classified=0 total=0 arithmetic
    if ! sum_disposition_counts entries_classified "classified total" \
        "${LEDGER_CLASSIFIED_DISPOSITIONS[@]}"; then
        parse_errors=$((parse_errors + 1))
        entries_classified=0
    fi
    if ! sum_disposition_counts total "ledger total" "${LEDGER_DISPOSITIONS[@]}"; then
        parse_errors=$((parse_errors + 1))
        total=0
    fi
    arithmetic="done=$count_done superseded=$count_superseded open_rehomed=$count_open_rehomed abandon=$count_abandon unclassified=$count_unclassified total=$total denominator=$denominator"
    if [ -n "$feed_census" ]; then
        feed_census="; $feed_census"
    fi

    if [ "$parse_errors" -gt 0 ] || [ "$missing_evidence" -gt 0 ]; then
        echo "INVALID: entries_classified=$entries_classified of $denominator; $arithmetic$feed_census"
        return 1
    fi
    if [ "$denominator" -eq 0 ] && [ "$total" -eq 0 ]; then
        echo "VACUOUS: entries_classified=0 of 0; $arithmetic$feed_census"
        return 1
    fi
    if [ "$total" -ne "$denominator" ]; then
        echo "MISMATCH: entries_classified=$entries_classified of $denominator; $arithmetic$feed_census"
        return 1
    fi

    echo "OK: entries_classified=$entries_classified of $denominator; $arithmetic$feed_census"
}

run_accounting_check() {
    local repo_root="$1"
    local ledger_path="$repo_root/docs/audits/followup-triage/TRIAGE.md"
    local feed_path="$repo_root/chats/icg/_followups.md"
    local feed_open_window feed_out_of_window_open

    if [ ! -f "$ledger_path" ] || [ ! -f "$feed_path" ]; then
        echo "ERROR: accounting inputs missing under repo root $repo_root" >&2
        return 1
    fi

    read -r feed_open_window feed_out_of_window_open < <(parse_feed_census "$feed_path")
    run_ledger_accounting_check "$ledger_path" \
        "feed_open_window=$feed_open_window feed_out_of_window_open=$feed_out_of_window_open"
}

compare_pinned_scope() {
    local lane_map_path="$1" disposition_rows_path="$2"
    local minimum_count="$3" expected_lanes="$4" expected_records="$5"

    awk -F '\t' \
        -v minimum_count="$minimum_count" \
        -v expected_lanes_arg="$expected_lanes" \
        -v expected_records_arg="$expected_records" '
        FNR == NR {
            if (NF != 2 || $1 == "" || $2 !~ /^[1-9][0-9]*$/) {
                print "MAP_ERROR: malformed pinned lane-count row"
                failures++
                next
            }
            pinned_count[$1] = $2
            pinned_order[++pinned_lane_total] = $1
            if ($2 >= minimum_count) {
                expected[$1] = 1
                computed_lanes++
                computed_records += $2
            }
            next
        }
        FNR != NR {
            split($0, row, "\034")
            entry_count = row[1]
            lane_id = row[4]
            if (entry_count == "PARSE_ERROR") {
                print "INVALID: " row[2]
                failures++
                next
            }
            disposition_rows++
            if (seen[lane_id]++) {
                print "DUPLICATE: " lane_id
                failures++
                next
            }
            if (!(lane_id in pinned_count)) {
                print "EXTRA: " lane_id " is absent from the pinned map"
                failures++
                next
            }
            if (pinned_count[lane_id] < minimum_count) {
                print "BELOW_THRESHOLD: " lane_id \
                    " pinned_count=" pinned_count[lane_id] \
                    " minimum_count=" minimum_count
                failures++
                next
            }
            if (entry_count != pinned_count[lane_id]) {
                print "MISCOUNTED: " lane_id \
                    " entry_count=" entry_count \
                    " pinned_count=" pinned_count[lane_id]
                failures++
            }
        }
        END {
            if (disposition_rows == 0) {
                print "VACUOUS: disposition ledger has no rows"
                failures++
            }
            for (lane_index = 1; lane_index <= pinned_lane_total; lane_index++) {
                lane_id = pinned_order[lane_index]
                if ((lane_id in expected) && !(lane_id in seen)) {
                    print "MISSING: " lane_id
                    failures++
                }
            }
            if (computed_lanes != expected_lanes_arg ||
                computed_records != expected_records_arg) {
                print "EXPECTED_MISMATCH: pinned map has lanes=" computed_lanes \
                    " records=" computed_records \
                    " expected_lanes=" expected_lanes_arg \
                    " expected_records=" expected_records_arg
                failures++
            }
            if (failures == 0) {
                print "PINNED_SCOPE_OK: minimum_count=" minimum_count \
                    " lanes=" computed_lanes " records=" computed_records
            }
            exit failures > 0 ? 1 : 0
        }
    ' "$lane_map_path" "$disposition_rows_path"
}

run_verify_pinned_scope() {
    local repo_root="$1" minimum_count="$2" expected_lanes="$3" expected_records="$4"
    local ledger_path="$repo_root/docs/audits/followup-triage/TRIAGE.md"
    local tmpdir comparison_status=0

    if ! [[ "$minimum_count" =~ ^[1-9][0-9]*$ ]] ||
        ! is_safe_nonnegative_integer "$minimum_count" ||
        ! [[ "$expected_lanes" =~ ^[1-9][0-9]*$ ]] ||
        ! is_safe_nonnegative_integer "$expected_lanes" ||
        ! [[ "$expected_records" =~ ^[1-9][0-9]*$ ]] ||
        ! is_safe_nonnegative_integer "$expected_records"; then
        echo "ERROR: pinned-scope arguments must be positive supported integers" >&2
        return 2
    fi
    if [ ! -f "$ledger_path" ]; then
        echo "ERROR: ledger input missing: $ledger_path" >&2
        return 1
    fi

    tmpdir="$(mktemp -d)"
    if ! FJCLOUD_REPO_ROOT="$repo_root" python3 "$SHARD_TOOL" --lane-counts \
        >"$tmpdir/lane_counts.tsv" 2>"$tmpdir/shard_error.txt"; then
        cat "$tmpdir/shard_error.txt" >&2
        rm -rf "$tmpdir"
        return 1
    fi
    parse_disposition_rows "$ledger_path" >"$tmpdir/disposition_rows.txt"
    compare_pinned_scope \
        "$tmpdir/lane_counts.tsv" "$tmpdir/disposition_rows.txt" \
        "$minimum_count" "$expected_lanes" "$expected_records" ||
        comparison_status=$?
    rm -rf "$tmpdir"
    return "$comparison_status"
}

run_structure_check() {
    local repo_root="$1"
    local ledger_path="$repo_root/docs/audits/followup-triage/TRIAGE.md"
    local feed_path="$repo_root/chats/icg/_followups.md"
    local failures=0 feed_open_window feed_out_of_window_open
    local heading heading_count row_status
    local entry_count disposition evidence lane_id
    local count_done=0 count_superseded=0 count_open_rehomed=0
    local count_abandon=0 count_unclassified=0 disposition_rows_valid=1
    local singleton_residual_open post_pin_arrivals readmitted_out_of_window
    local expected_open_window
    if [ ! -f "$ledger_path" ] || [ ! -f "$feed_path" ]; then
        echo "STRUCTURE_FAIL: structure inputs missing under repo root $repo_root"
        return 1
    fi
    for heading in Open Harvested Closed; do
        heading_count="$(
            awk -v heading="## $heading" \
                '$0 ~ ("^" heading "[[:space:]]*$") { count++ }
                 END { print count + 0 }' "$feed_path"
        )"
        if [ "$heading_count" -ne 1 ]; then
            echo "STRUCTURE_FAIL: heading '## $heading' count=$heading_count expected=1"
            failures=$((failures + 1))
        fi
    done
    read -r feed_open_window feed_out_of_window_open < <(parse_feed_census "$feed_path")
    if ! validate_open_section_statuses "$feed_path"; then
        failures=$((failures + 1))
    fi
    if [ "$feed_out_of_window_open" -ne 0 ]; then
        echo "STRUCTURE_FAIL: feed_out_of_window_open=$feed_out_of_window_open expected=0"
        failures=$((failures + 1))
    fi
    if ! validate_residual_markers "$feed_path"; then
        failures=$((failures + 1))
    fi
    while IFS=$'\034' read -r entry_count disposition evidence lane_id; do
        [ -n "$entry_count" ] || continue
        row_status=0
        validate_and_accumulate_row \
            "$entry_count" "$disposition" "$evidence" "$lane_id" || row_status=$?
        if [ "$row_status" -ne 0 ]; then
            failures=$((failures + 1))
            disposition_rows_valid=0
        fi
    done < <(parse_disposition_rows "$ledger_path")
    singleton_residual_open="$(
        parse_rewrite_outcome_value "$ledger_path" "singleton_residual_open"
    )"
    if ! validate_rewrite_outcome_value \
        "singleton_residual_open" "$singleton_residual_open"; then
        failures=$((failures + 1))
    fi
    post_pin_arrivals="$(parse_rewrite_outcome_value "$ledger_path" "post_pin_arrivals")"
    if ! validate_rewrite_outcome_value "post_pin_arrivals" "$post_pin_arrivals"; then
        failures=$((failures + 1))
    fi
    readmitted_out_of_window="$(
        parse_rewrite_outcome_value "$ledger_path" "readmitted_out_of_window"
    )"
    if ! validate_rewrite_outcome_value \
        "readmitted_out_of_window" "$readmitted_out_of_window"; then
        failures=$((failures + 1))
    fi
    if [ "$disposition_rows_valid" -eq 1 ] &&
        is_safe_nonnegative_integer "$singleton_residual_open" &&
        is_safe_nonnegative_integer "$post_pin_arrivals" &&
        is_safe_nonnegative_integer "$readmitted_out_of_window"; then
        expected_open_window=0
        if ! add_structure_open_window_count \
            expected_open_window "$count_unclassified" \
            "rewrite outcome open-window sum" ||
            ! add_structure_open_window_count \
                expected_open_window "$singleton_residual_open" \
                "rewrite outcome open-window sum" ||
            ! add_structure_open_window_count \
                expected_open_window "$post_pin_arrivals" \
                "rewrite outcome open-window sum" ||
            ! add_structure_open_window_count \
                expected_open_window "$readmitted_out_of_window" \
                "rewrite outcome open-window sum"; then
            failures=$((failures + 1))
        elif [ "$feed_open_window" -ne "$expected_open_window" ]; then
            echo "STRUCTURE_FAIL: feed_open_window=$feed_open_window expected=$expected_open_window (unclassified=$count_unclassified singleton_residual_open=$singleton_residual_open post_pin_arrivals=$post_pin_arrivals readmitted_out_of_window=$readmitted_out_of_window)"
            failures=$((failures + 1))
        fi
    fi
    if [ "$failures" -gt 0 ]; then
        return 1
    fi
    echo "STRUCTURE_OK"
}

run_repository_verdict() {
    local repo_root="$1"
    local accounting_exit_code=0 structure_exit_code=0
    local accounting_output structure_output

    accounting_output="$(run_accounting_check "$repo_root")" ||
        accounting_exit_code=$?
    structure_output="$(run_structure_check "$repo_root")" ||
        structure_exit_code=$?
    printf '%s\n' "$accounting_output" "$structure_output"

    [ "$accounting_exit_code" -eq 0 ] && [ "$structure_exit_code" -eq 0 ]
}

case "${1:-}" in
    --ledger-only)
        if [ "$#" -ne 2 ]; then
            echo "ERROR: --ledger-only requires exactly one path" >&2
            echo "Usage: $CHECK_SCRIPT --ledger-only <path>" >&2
            exit 2
        fi
        run_ledger_accounting_check "$2"
        exit $?
        ;;
    --verify-pinned-scope)
        if [ "$#" -ne 4 ]; then
            echo "ERROR: --verify-pinned-scope requires minimum-count, expected-lanes, and expected-records" >&2
            echo "Usage: $CHECK_SCRIPT --verify-pinned-scope <minimum-count> <expected-lanes> <expected-records>" >&2
            exit 2
        fi
        run_verify_pinned_scope \
            "${FJCLOUD_REPO_ROOT:-$DEFAULT_REPO_ROOT}" "$2" "$3" "$4"
        exit $?
        ;;
    --check-only)
        run_accounting_check "${FJCLOUD_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
        exit $?
        ;;
    --structure-only)
        run_structure_check "${FJCLOUD_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
        exit $?
        ;;
    --repo-verdict)
        run_repository_verdict "${FJCLOUD_REPO_ROOT:-$DEFAULT_REPO_ROOT}"
        exit $?
        ;;
esac

if [ "${FOLLOWUP_TRIAGE_TEST_CHILD:-0}" = "1" ]; then
    echo "ERROR: requested accounting-guard mode did not dispatch" >&2
    exit 99
fi

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

source "$SCRIPT_DIR/followup_triage_accounting_ledger_cases.sh"
source "$SCRIPT_DIR/followup_triage_accounting_structure_cases.sh"

run_test_summary
