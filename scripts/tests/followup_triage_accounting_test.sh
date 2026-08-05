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

# Folds every ledger row into the caller's count_<disposition> accumulators,
# reporting each malformed row. Returns 1 when any row failed validation, which
# tells the caller the disposition census is too damaged to reconcile against.
accumulate_disposition_rows() {
    local ledger_path="$1"
    local entry_count disposition evidence lane_id rows_valid=1

    while IFS=$'\034' read -r entry_count disposition evidence lane_id; do
        [ -n "$entry_count" ] || continue
        validate_and_accumulate_row \
            "$entry_count" "$disposition" "$evidence" "$lane_id" || rows_valid=0
    done < <(parse_disposition_rows "$ledger_path")
    [ "$rows_valid" -eq 1 ]
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

parse_feed_lane_locations() {
    local feed_path="$1"
    awk '
        /^## Open[[:space:]]*$/ {
            section = "Open"
            next
        }
        /^## Harvested[[:space:]]*$/ {
            section = "Harvested"
            next
        }
        /^## Closed[[:space:]]*$/ {
            section = "Closed"
            next
        }
        /^## / {
            section = "Other"
            next
        }
        /^- lane_id:/ {
            lane_id = $0
            sub(/^- lane_id:[[:space:]]*/, "", lane_id)
            print lane_id "\034" section
        }
    ' "$feed_path"
}

# The feed's three section headings are the coordinate system every location
# check depends on, so a repeated or missing heading is reported before any
# census is trusted.
validate_feed_headings() {
    local feed_path="$1"
    local heading heading_count failures=0

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
    [ "$failures" -eq 0 ]
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

# Emits one `lane_id\034resolution` row per `## Closed` lane that carries a
# resolution, accepting both the `resolution: |` literal block and the
# generator's single-quoted multiline scalar. Malformed quoted scalars fail
# closed with exact `STRUCTURE_FAIL:` diagnostics instead of a silent row.
parse_closed_resolution_rows() {
    local feed_path="$1"
    awk '
        function emit_resolution() {
            if (lane_id != "" && status == "closed" && resolution_seen) {
                print lane_id "\034" resolution
            }
        }
        function reset_lane() {
            lane_id = ""
            status = ""
            resolution = ""
            resolution_seen = 0
            in_literal = 0
        }
        # Closes an unterminated single-quoted scalar at a structural boundary,
        # naming its owning Closed lane. Detached and duplicate scalars already
        # reported their own diagnostic, so they stay silent here.
        function flush_open_quote() {
            if (in_quoted) {
                if (quote_lane != "" && !capture_suppressed) {
                    print "STRUCTURE_FAIL: unterminated quoted resolution for Closed lane " quote_lane
                }
                in_quoted = 0
            }
        }
        # Appends the single-quoted scalar text in `chunk` to qbuf, folding a
        # doubled quote into one literal quote (the YAML escape). Returns 1 when
        # the closing quote is reached, 0 while the scalar stays open.
        function scan_quoted(chunk,   i, c, n) {
            n = length(chunk)
            for (i = 1; i <= n; i++) {
                c = substr(chunk, i, 1)
                if (c == "\047") {
                    if (substr(chunk, i + 1, 1) == "\047") {
                        qbuf = qbuf "\047"
                        i++
                        continue
                    }
                    quoted_tail = substr(chunk, i + 1)
                    if (quoted_tail !~ /^[[:space:]]*(#.*)?$/) {
                        print "STRUCTURE_FAIL: invalid text after quoted resolution for Closed lane " quote_lane
                        capture_suppressed = 1
                    }
                    return 1
                }
                qbuf = qbuf c
            }
            return 0
        }
        function close_quoted_scalar() {
            in_quoted = 0
            if (!capture_suppressed) {
                resolution = qbuf
                resolution_seen = 1
            }
        }
        function start_quoted_resolution(record) {
            capture_suppressed = 0
            if (lane_id == "") {
                print "STRUCTURE_FAIL: detached quoted resolution before any Closed lane_id"
                capture_suppressed = 1
            } else if (resolution_seen) {
                print "STRUCTURE_FAIL: ambiguous duplicate resolution for Closed lane " lane_id
                capture_suppressed = 1
            }
            quote_lane = lane_id
            tail = record
            sub(/^[[:space:]]*resolution:[[:space:]]*\047/, "", tail)
            qbuf = ""
            in_quoted = 1
            if (scan_quoted(tail)) {
                close_quoted_scalar()
            }
        }
        function start_literal_resolution() {
            if (resolution_seen) {
                print "STRUCTURE_FAIL: ambiguous duplicate resolution for Closed lane " lane_id
                literal_suppressed = 1
            } else {
                literal_suppressed = 0
                resolution = ""
                resolution_seen = 1
            }
            in_literal = 1
        }
        /^## Closed[[:space:]]*$/ {
            in_closed = 1
            next
        }
        in_closed && /^## / {
            flush_open_quote()
            emit_resolution()
            reset_lane()
            in_closed = 0
            next
        }
        !in_closed {
            next
        }
        /^- lane_id:/ {
            flush_open_quote()
            emit_resolution()
            reset_lane()
            lane_id = $0
            sub(/^- lane_id:[[:space:]]*/, "", lane_id)
            next
        }
        in_quoted && /^```/ {
            flush_open_quote()
            next
        }
        in_literal && /^  resolution:[[:space:]]*\047/ {
            in_literal = 0
            start_quoted_resolution($0)
            next
        }
        in_literal && /^  resolution:[[:space:]]*\|[[:space:]]*$/ {
            in_literal = 0
            start_literal_resolution()
            next
        }
        !in_quoted && !in_literal && /^[[:space:]]*resolution:[[:space:]]*\047/ {
            start_quoted_resolution($0)
            next
        }
        in_quoted {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            qbuf = qbuf "\035"
            if (scan_quoted(line)) {
                close_quoted_scalar()
            }
            next
        }
        !in_quoted && !in_literal && lane_id != "" && \
            /^[[:space:]]+resolution:[[:space:]]*\|[[:space:]]*$/ {
            start_literal_resolution()
            next
        }
        !in_quoted && lane_id != "" && /^  status:[[:space:]]*closed[[:space:]]*$/ {
            status = "closed"
            next
        }
        in_literal && /^    / {
            line = $0
            sub(/^    /, "", line)
            if (!literal_suppressed) {
                resolution = resolution "\035" line
            }
            next
        }
        in_literal {
            in_literal = 0
        }
        END {
            flush_open_quote()
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
    local marker missing_marker=0 structural_errors

    # A malformed quoted resolution is a structural defect, not a missing
    # marker: surface the parser's exact diagnostic before any marker search so
    # a fully-marked sibling row can never mask an unterminated, detached, or
    # duplicate scalar.
    structural_errors="$(parse_closed_resolution_rows "$feed_path" | grep '^STRUCTURE_FAIL:' || true)"
    if [ -n "$structural_errors" ]; then
        printf '%s\n' "$structural_errors"
        return 1
    fi

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

parse_pinned_base_sha() {
    local ledger_path="$1"
    awk '
        /^- Pinned base SHA: `/ {
            value = $0
            sub(/^- Pinned base SHA: `/, "", value)
            sub(/`.*/, "", value)
            print value
        }
    ' "$ledger_path"
}

validate_pinned_feed_snapshot() {
    local repo_root="$1" ledger_path="$2" feed_path="$3"
    local pinned_sha pinned_sha_count feed_relative
    pinned_sha="$(parse_pinned_base_sha "$ledger_path")"
    pinned_sha_count="$(printf '%s\n' "$pinned_sha" | awk 'NF { count++ } END { print count + 0 }')"
    if [ "$pinned_sha_count" -eq 0 ] &&
        [ "${FJCLOUD_STRUCTURE_FIXTURE_ALLOW_MISSING_PIN:-0}" = "1" ]; then
        return 0
    fi
    if [ "$pinned_sha_count" -ne 1 ] ||
        ! [[ "$pinned_sha" =~ ^[0-9a-fA-F]{40}$ ]]; then
        echo "STRUCTURE_FAIL: TRIAGE.md must contain exactly one 40-hex pinned base SHA"
        return 1
    fi
    feed_relative="${feed_path#"$repo_root"/}"
    if ! git -C "$repo_root" cat-file -e "$pinned_sha:$feed_relative" 2>/dev/null; then
        echo "STRUCTURE_FAIL: pinned feed snapshot is unavailable at base SHA '$pinned_sha'"
        return 1
    fi
}

# Reads the single fenced `text` block under one `###` identity heading. Every
# open-window identity summand (historical arrivals, later arrivals, and pinned
# singleton residuals) is recorded in this one shape, so this parser is the sole
# owner of the block grammar.
parse_identity_block() {
    local ledger_path="$1" heading="$2"
    awk -v heading="$heading" '
        function trim_trailing(value) {
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        function fail(message) {
            print "STRUCTURE_FAIL: " message
            failures++
        }
        trim_trailing($0) == heading {
            heading_count++
            in_section = 1
            next
        }
        in_section && /^### / {
            if (in_text_block) {
                fail("heading \047" heading "\047 has an unterminated fenced text identity block")
            }
            in_section = 0
            in_text_block = 0
            next
        }
        in_section && /^## / {
            if (in_text_block) {
                fail("heading \047" heading "\047 has an unterminated fenced text identity block")
            }
            in_section = 0
            in_text_block = 0
            next
        }
        in_section && in_text_block && /^```[[:space:]]*$/ {
            in_text_block = 0
            next
        }
        in_section && /^```text[[:space:]]*$/ {
            text_block_count++
            if (text_block_count > 1) {
                fail("heading \047" heading "\047 has repeated fenced text identity blocks")
            }
            in_text_block = 1
            next
        }
        in_text_block {
            identity = trim($0)
            if (identity == "") {
                fail("heading \047" heading "\047 contains a blank identity")
                next
            }
            if (seen[identity]++) {
                fail("heading \047" heading "\047 has duplicate identity \047" identity "\047")
                next
            }
            print "IDENTITY\034" identity
            next
        }
        END {
            if (heading_count != 1) {
                fail("heading \047" heading "\047 count=" heading_count " expected=1")
            } else if (text_block_count != 1) {
                fail("heading \047" heading "\047 has fenced text identity block count=" text_block_count " expected=1")
            } else if (in_text_block) {
                fail("heading \047" heading "\047 has an unterminated fenced text identity block")
            }
        }
    ' "$ledger_path"
}

# Writes one identity block's identities to `identities_path`. Malformed blocks
# still yield the identities that parsed cleanly, so a single bad heading never
# silently empties an open-window summand; the parser's diagnostics are printed
# and the non-zero return tells the caller to count a structure failure.
extract_identity_block() {
    local ledger_path="$1" heading="$2" identities_path="$3"
    local block_rows block_failures
    block_rows="$(parse_identity_block "$ledger_path" "$heading")"
    printf '%s\n' "$block_rows" |
        awk -F '\034' '$1 == "IDENTITY" { print $2 }' > "$identities_path"
    block_failures="$(printf '%s\n' "$block_rows" | grep '^STRUCTURE_FAIL:' || true)"
    [ -n "$block_failures" ] || return 0
    printf '%s\n' "$block_failures"
    return 1
}

# Prefixes each non-blank identity line read on stdin with the record kind it is
# classified as, using the \034 delimiter the membership comparison splits on.
# The one canonical owner of the kind-tagging convention.
tag_identities() {
    awk -v record_kind="$1" 'NF { print record_kind "\034" $0 }'
}

# Tags each identity with the record kind it is recorded as, so membership
# diagnostics can say whether a defective identity was expected as a post-pin
# arrival or as a pinned singleton residual.
label_recorded_open_identities() {
    local identities_path="$1" record_kind="$2"
    tag_identities "$record_kind" < "$identities_path"
}

count_lines() {
    wc -l < "$1" | tr -d ' '
}

# Reads every open-window identity block into `workdir`, leaving one file per
# block for the cardinality checks plus a `recorded_open_identities` file that
# tags each identity with the record kind membership diagnostics should name.
# Returns 1 when any block is malformed.
collect_recorded_open_identities() {
    local ledger_path="$1" workdir="$2"
    local blocks_valid=1

    extract_identity_block "$ledger_path" "### post_pin_arrivals identities" \
        "$workdir/historical_arrivals" || blocks_valid=0
    extract_identity_block "$ledger_path" \
        "### post_reconciliation_arrival identities" \
        "$workdir/post_reconciliation_arrivals" || blocks_valid=0
    # The singleton residual block is optional by absence, matching a ledger that
    # holds no pinned singleton under `## Open`. It is not optional by content:
    # the scalar must equal this block's cardinality, so a nonzero
    # `singleton_residual_open` cannot stand without named identities.
    : > "$workdir/singleton_residuals"
    if grep -q '^### singleton_residual_open identities[[:space:]]*$' \
        "$ledger_path"; then
        extract_identity_block "$ledger_path" \
            "### singleton_residual_open identities" \
            "$workdir/singleton_residuals" || blocks_valid=0
    fi
    {
        label_recorded_open_identities \
            "$workdir/historical_arrivals" post_pin_arrival
        label_recorded_open_identities \
            "$workdir/post_reconciliation_arrivals" post_pin_arrival
        label_recorded_open_identities \
            "$workdir/singleton_residuals" singleton_residual
    } > "$workdir/recorded_open_identities"
    [ "$blocks_valid" -eq 1 ]
}

parse_disposition_ledger_identities() {
    local ledger_path="$1" disposition_filter="${2:-}"
    local entry_count disposition evidence lane_id
    while IFS=$'\034' read -r entry_count disposition evidence lane_id; do
        [ -n "$entry_count" ] || continue
        if [ "$entry_count" != "PARSE_ERROR" ] &&
            { [ -z "$disposition_filter" ] ||
                [ "$disposition" = "$disposition_filter" ]; }; then
            printf '%s\n' "$lane_id"
        fi
    done < <(parse_disposition_rows "$ledger_path")
}

parse_pinned_out_of_window_open_identities() {
    local repo_root="$1" ledger_path="$2" feed_path="$3"
    local pinned_sha feed_relative
    pinned_sha="$(parse_pinned_base_sha "$ledger_path")"
    [ -n "$pinned_sha" ] || return 0
    feed_relative="${feed_path#"$repo_root"/}"
    git -C "$repo_root" show "$pinned_sha:$feed_relative" 2>/dev/null |
        awk '
            /^## Open[[:space:]]*$/ {
                section = "open"
                next
            }
            /^## / {
                section = "other"
                next
            }
            /^- lane_id:/ {
                lane_id = $0
                sub(/^- lane_id:[[:space:]]*/, "", lane_id)
            }
            section != "open" && /^[[:space:]]+status: open[[:space:]]*$/ {
                print lane_id
            }
        '
}

parse_pinned_open_identities() {
    local repo_root="$1" ledger_path="$2" feed_path="$3"
    local pinned_sha feed_relative
    pinned_sha="$(parse_pinned_base_sha "$ledger_path")"
    [ -n "$pinned_sha" ] || return 0
    feed_relative="${feed_path#"$repo_root"/}"
    git -C "$repo_root" show "$pinned_sha:$feed_relative" 2>/dev/null |
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
                lane_id = $0
                sub(/^- lane_id:[[:space:]]*/, "", lane_id)
                print lane_id
            }
        '
}

# Known non-arrival owners include every disposition-ledger identity and every
# record the feed carried at the pinned base SHA. The membership comparison uses
# these typed owners both to recognize existing Open rows and to prevent a
# recorded arrival or singleton from claiming an already-owned identity.
collect_known_open_non_arrival_identities() {
    local repo_root="$1" ledger_path="$2" feed_path="$3"

    parse_disposition_ledger_identities "$ledger_path" |
        tag_identities ledger_disposition
    parse_disposition_ledger_identities "$ledger_path" unclassified |
        tag_identities ledger_unclassified
    parse_pinned_open_identities "$repo_root" "$ledger_path" "$feed_path" |
        tag_identities pinned_open
    parse_pinned_out_of_window_open_identities \
        "$repo_root" "$ledger_path" "$feed_path" |
        tag_identities pinned_out_of_window_open
}

write_known_open_non_arrival_identities() {
    local repo_root="$1" ledger_path="$2" feed_path="$3" output_path="$4"
    if ! validate_pinned_feed_snapshot "$repo_root" "$ledger_path" "$feed_path"; then
        : > "$output_path"
        return 1
    fi
    collect_known_open_non_arrival_identities \
        "$repo_root" "$ledger_path" "$feed_path" > "$output_path"
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

# Reads one `## Rewrite outcome` scalar into the caller-scoped variable named by
# `target_name`, printing the validator's diagnostic and returning 1 when the
# line is absent or noncanonical.
read_rewrite_outcome_scalar() {
    local ledger_path="$1" key="$2" target_name="$3"
    local value
    value="$(parse_rewrite_outcome_value "$ledger_path" "$key")"
    printf -v "$target_name" '%s' "$value"
    validate_rewrite_outcome_value "$key" "$value"
}

# Same, for a scalar that is optional by absence only: an omitted line reads as
# 0, while a present line must still be canonical.
read_optional_rewrite_outcome_scalar() {
    local ledger_path="$1" key="$2" target_name="$3"
    if ! grep -qE "^- $key:" "$ledger_path"; then
        printf -v "$target_name" '%d' 0
        return 0
    fi
    read_rewrite_outcome_scalar "$ledger_path" "$key" "$target_name"
}

structure_summands_are_safe() {
    local summand
    for summand in "$@"; do
        is_safe_nonnegative_integer "$summand" || return 1
    done
}

# A reconciliation scalar must equal the cardinality of the identity block that
# owns it, so a total can never drift away from the records it claims to count.
# A scalar that failed its own validator is left to that diagnostic.
validate_summand_cardinality() {
    local key="$1" scalar="$2" identity_count="$3" description="$4"

    if ! structure_summands_are_safe "$scalar" ||
        [ "$scalar" -eq "$identity_count" ]; then
        return 0
    fi
    echo "STRUCTURE_FAIL: $key=$scalar must equal $description=$identity_count"
    return 1
}

# Totals the open-window summands into the caller-scoped variable named by the
# first argument, refusing any addition that would overflow Bash arithmetic.
sum_structure_open_window() {
    local target_name="$1" summand accumulated=0
    shift

    for summand in "$@"; do
        if ((summand > MAX_SAFE_ENTRY_COUNT - accumulated)); then
            echo "STRUCTURE_FAIL: rewrite outcome open-window sum exceeds supported width"
            return 1
        fi
        accumulated=$((accumulated + summand))
    done
    printf -v "$target_name" '%d' "$accumulated"
}

# Names every open-window summand so a reconciliation failure is diagnosable
# without re-deriving the ledger by hand. `unclassified_departed_open` is shown
# only when it is subtracting something.
format_open_window_summands() {
    local unclassified="$1" departed="$2" singleton_residual="$3"
    local historical_arrivals="$4" later_arrivals="$5" readmitted="$6"
    local departed_note=""

    if [ "$departed" -gt 0 ]; then
        departed_note=" unclassified_departed_open=$departed"
    fi
    printf 'unclassified=%s%s singleton_residual_open=%s historical_post_pin_arrivals=%s post_reconciliation_arrivals=%s readmitted_out_of_window=%s' \
        "$unclassified" "$departed_note" "$singleton_residual" \
        "$historical_arrivals" "$later_arrivals" "$readmitted"
}

# Every open-window record beyond the pinned `unclassified` census must be owned
# by name: recorded identities must sit exactly once under `## Open`, and every
# `## Open` identity must be either recorded here or already known from the
# pinned ledger. There is no positional allowance, so which identity is reported
# never depends on feed row order.
compare_recorded_open_identity_membership() {
    local recorded_identities_path="$1" feed_locations_path="$2"
    local known_open_identities_path="$3"
    awk -F '\034' \
        -v recorded_path="$recorded_identities_path" \
        -v feed_path="$feed_locations_path" \
        -v known_path="$known_open_identities_path" '
        FILENAME == recorded_path {
            if ($2 != "") {
                if ($2 in recorded_kind) {
                    if (recorded_kind[$2] == $1) {
                        print "STRUCTURE_FAIL: identity \047" $2 \
                            "\047 is recorded more than once as " $1
                    } else {
                        print "STRUCTURE_FAIL: identity \047" $2 \
                            "\047 is recorded as " recorded_kind[$2] " and " $1
                    }
                    failures++
                    next
                }
                recorded_kind[$2] = $1
                recorded_order[++recorded_count] = $2
            }
            next
        }
        FILENAME == known_path {
            if ($2 != "") {
                known[$2] = known[$2] " " $1
            }
            next
        }
        FILENAME == feed_path {
            lane_id = $1
            location = $2
            feed_count[lane_id]++
            if (location == "Open") {
                open_count[lane_id]++
                if (!open_order_seen[lane_id]++) {
                    open_order[++open_order_count] = lane_id
                }
            } else {
                outside_open_count[lane_id]++
            }
            next
        }
        END {
            for (i = 1; i <= recorded_count; i++) {
                identity = recorded_order[i]
                kind = recorded_kind[identity]
                is_known = identity in known
                is_pinned_open = is_known && \
                    known[identity] ~ /(^| )pinned_open( |$)/
                singleton_from_pinned_open = kind == "singleton_residual" && \
                    is_pinned_open && \
                    known[identity] !~ /(^| )(ledger_disposition|pinned_out_of_window_open)( |$)/
                if (kind == "singleton_residual" && !is_pinned_open) {
                    print "STRUCTURE_FAIL: singleton_residual identity \047" identity \
                        "\047 was not under ## Open at pinned base SHA"
                    failures++
                }
                if (is_known && !singleton_from_pinned_open) {
                    print "STRUCTURE_FAIL: " kind " identity \047" identity \
                        "\047 overlaps known non-arrival classification"
                    failures++
                }
                if (open_count[identity] == 0) {
                    if (feed_count[identity] > 0) {
                        print "STRUCTURE_FAIL: " kind " identity \047" identity "\047 is outside ## Open"
                    } else {
                        print "STRUCTURE_FAIL: " kind " identity \047" identity "\047 is missing from ## Open"
                    }
                    failures++
                } else if (open_count[identity] != 1) {
                    print "STRUCTURE_FAIL: " kind " identity \047" identity "\047 appears " open_count[identity] " times under ## Open expected=1"
                    failures++
                } else if (outside_open_count[identity] > 0) {
                    print "STRUCTURE_FAIL: " kind " identity \047" identity \
                        "\047 appears under ## Open and outside ## Open"
                    failures++
                }
            }
            for (i = 1; i <= open_order_count; i++) {
                identity = open_order[i]
                pinned_open_authorized = known[identity] ~ \
                    /(^| )pinned_open( |$)/ && \
                    known[identity] !~ /(^| )ledger_disposition( |$)/
                known_open_member = known[identity] ~ \
                    /(^| )(ledger_unclassified|pinned_out_of_window_open)( |$)/ || \
                    pinned_open_authorized
                if (!(identity in recorded_kind) && !known_open_member) {
                    print "STRUCTURE_FAIL: post_pin_arrival identity \047" identity "\047 is present under ## Open but is not recorded"
                    failures++
                }
            }
            exit failures > 0 ? 1 : 0
        }
    ' "$recorded_identities_path" "$known_open_identities_path" "$feed_locations_path"
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
    local count_done=0 count_superseded=0 count_open_rehomed=0
    local count_abandon=0 count_unclassified=0 disposition_rows_valid=1
    local singleton_residual_open post_pin_arrivals readmitted_out_of_window
    local historical_arrival_count post_reconciliation_arrival_count
    local singleton_residual_identity_count unclassified_departed_open
    local expected_open_window structure_tmpdir
    if [ ! -f "$ledger_path" ] || [ ! -f "$feed_path" ]; then
        echo "STRUCTURE_FAIL: structure inputs missing under repo root $repo_root"
        return 1
    fi
    structure_tmpdir="$(mktemp -d)"
    validate_feed_headings "$feed_path" || failures=$((failures + 1))
    read -r feed_open_window feed_out_of_window_open < <(parse_feed_census "$feed_path")
    validate_open_section_statuses "$feed_path" || failures=$((failures + 1))
    if [ "$feed_out_of_window_open" -ne 0 ]; then
        echo "STRUCTURE_FAIL: feed_out_of_window_open=$feed_out_of_window_open expected=0"
        failures=$((failures + 1))
    fi
    validate_residual_markers "$feed_path" || failures=$((failures + 1))
    if ! accumulate_disposition_rows "$ledger_path"; then
        failures=$((failures + 1))
        disposition_rows_valid=0
    fi
    read_rewrite_outcome_scalar "$ledger_path" singleton_residual_open \
        singleton_residual_open || failures=$((failures + 1))
    read_rewrite_outcome_scalar "$ledger_path" post_pin_arrivals \
        post_pin_arrivals || failures=$((failures + 1))
    read_rewrite_outcome_scalar "$ledger_path" readmitted_out_of_window \
        readmitted_out_of_window || failures=$((failures + 1))
    # `unclassified_departed_open` records pinned records the ledger still marks
    # `unclassified` that have since left `## Open` (the generator placed them in
    # `## Closed`, Harvested, or absent). Its subtraction keeps the open-window
    # identity honest without rewriting the disposition ledger's 999 census.
    read_optional_rewrite_outcome_scalar "$ledger_path" \
        unclassified_departed_open unclassified_departed_open ||
        failures=$((failures + 1))
    collect_recorded_open_identities "$ledger_path" "$structure_tmpdir" ||
        failures=$((failures + 1))
    historical_arrival_count="$(count_lines "$structure_tmpdir/historical_arrivals")"
    post_reconciliation_arrival_count="$(
        count_lines "$structure_tmpdir/post_reconciliation_arrivals"
    )"
    singleton_residual_identity_count="$(
        count_lines "$structure_tmpdir/singleton_residuals"
    )"
    validate_summand_cardinality post_pin_arrivals "$post_pin_arrivals" \
        "$historical_arrival_count" "historical identity count" ||
        failures=$((failures + 1))
    validate_summand_cardinality singleton_residual_open \
        "$singleton_residual_open" "$singleton_residual_identity_count" \
        "singleton residual identity count" || failures=$((failures + 1))
    parse_feed_lane_locations "$feed_path" > "$structure_tmpdir/feed_locations"
    write_known_open_non_arrival_identities \
        "$repo_root" "$ledger_path" "$feed_path" \
        "$structure_tmpdir/known_open_non_arrivals" || failures=$((failures + 1))
    compare_recorded_open_identity_membership \
        "$structure_tmpdir/recorded_open_identities" \
        "$structure_tmpdir/feed_locations" \
        "$structure_tmpdir/known_open_non_arrivals" ||
        failures=$((failures + 1))
    if [ "$disposition_rows_valid" -eq 1 ] &&
        structure_summands_are_safe "$singleton_residual_open" \
            "$post_pin_arrivals" "$readmitted_out_of_window" \
            "$unclassified_departed_open"; then
        if [ "$unclassified_departed_open" -gt "$count_unclassified" ]; then
            echo "STRUCTURE_FAIL: unclassified_departed_open=$unclassified_departed_open exceeds unclassified=$count_unclassified"
            failures=$((failures + 1))
        elif ! sum_structure_open_window expected_open_window \
            "$count_unclassified" "$singleton_residual_open" \
            "$historical_arrival_count" "$post_reconciliation_arrival_count" \
            "$readmitted_out_of_window"; then
            failures=$((failures + 1))
        else
            expected_open_window=$((expected_open_window - unclassified_departed_open))
            if [ "$feed_open_window" -ne "$expected_open_window" ]; then
                echo "STRUCTURE_FAIL: feed_open_window=$feed_open_window expected=$expected_open_window ($(
                    format_open_window_summands "$count_unclassified" \
                        "$unclassified_departed_open" "$singleton_residual_open" \
                        "$historical_arrival_count" \
                        "$post_reconciliation_arrival_count" \
                        "$readmitted_out_of_window"
                ))"
                failures=$((failures + 1))
            fi
        fi
    fi
    rm -rf "$structure_tmpdir"
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
