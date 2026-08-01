#!/usr/bin/env bash
# Contract test for the competitor capability gap audit closeout rows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_PATH="${FJCLOUD_COMPETITOR_GAP_AUDIT_PATH:-$REPO_ROOT/docs/audits/feature-parity/20260730T155204Z_competitor_capability_gaps/SUMMARY.md}"
ROADMAP_PATH="${FJCLOUD_COMPETITOR_GAP_ROADMAP_PATH:-$REPO_ROOT/ROADMAP.md}"
FAILURES=0

pass() {
    printf 'ok: %s\n' "$1"
}

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

require_file() {
    if [ -f "$AUDIT_PATH" ]; then
        pass "audit exists"
    else
        fail "audit file missing: $AUDIT_PATH"
    fi
}

require_roadmap_file() {
    if [ -f "$ROADMAP_PATH" ] && [ -r "$ROADMAP_PATH" ]; then
        pass "ROADMAP exists"
    else
        fail "ROADMAP file missing or unreadable: $ROADMAP_PATH"
    fi
}

require_stage3_summary() {
    local summary
    summary="$(grep -E -- '^Stage 3 summary: `capabilities=[0-9]+ gaps=[0-9]+ blocks-switch=[0-9]+ degrades=[0-9]+ niche=[0-9]+`$' "$AUDIT_PATH" || true)"
    if [ -n "$summary" ]; then
        pass "stage 3 denominator parses"
    else
        fail "Stage 3 summary denominator is missing or malformed"
    fi
}

require_current_scope_contract() {
    local top_level_scope
    top_level_scope="$(
        awk '
            /^## Stage 2 Competitor Capability Evidence$/ {
                exit
            }
            {
                print
            }
        ' "$AUDIT_PATH"
    )"

    if grep -Eq '^PURPOSE: .*Stage 1.*Stage 2.*Stage 3.*Stage 4' <<< "$top_level_scope"; then
        pass "purpose describes the complete multi-stage audit"
    else
        fail "PURPOSE must describe the Stage 1 through Stage 4 audit"
    fi

    if grep -Eiq 'contains no competitor claims|no ranking|no roadmap proposals|describes only Flapjack Cloud' <<< "$top_level_scope"; then
        fail "top-level scope contradicts the audit's competitor, ranking, or roadmap contents"
    else
        pass "top-level scope does not deny later-stage audit contents"
    fi
}

extract_stage_scope_review() {
    awk '
        /^## Stage Scope Review$/ {
            matches++
            in_scope = 1
            next
        }
        in_scope && /^## / {
            in_scope = 0
        }
        in_scope && NF {
            if (scope) {
                scope = scope " "
            }
            scope = scope $0
        }
        END {
            if (matches != 1 || !scope) {
                exit 1
            }
            print scope
        }
    ' "$AUDIT_PATH"
}

require_stage_scope_review() {
    local actual_scope expected_scope
    expected_scope="This document contains the Stage 1 shipped/partial/absent product inventory, Stage 2 competitor evidence, Stage 3 ranked and sized gap analysis, and Stage 4 proposed ROADMAP rows. The audit remains local-only: it does not modify product code, update \`ROADMAP.md\`, perform a deploy or external mutation, or extend the older internal engine-dashboard audits."

    if ! actual_scope="$(extract_stage_scope_review)"; then
        fail "expected exactly one non-empty ## Stage Scope Review section"
    elif [ "$actual_scope" = "$expected_scope" ]; then
        pass "Stage Scope Review describes the Stage 1 through Stage 4 handoff contract"
    else
        fail "Stage Scope Review does not match the current multi-stage handoff contract: $actual_scope"
    fi
}

require_proposed_rows_section() {
    if grep -Fxq -- '## Proposed ROADMAP rows' "$AUDIT_PATH"; then
        pass "proposed roadmap section exists"
    else
        fail "missing ## Proposed ROADMAP rows section"
    fi

    if grep -Fxq -- '```rows:' "$AUDIT_PATH"; then
        pass "rows fence exists"
    else
        fail "missing rows: fence"
    fi
}

extract_rows() {
    awk '
        /^```rows:$/ {
            opening_fences++
            if (opening_fences == 1) {
                in_rows = 1
            }
            next
        }
        in_rows && /^```$/ {
            closing_fences++
            in_rows = 0
            next
        }
        in_rows {
            print
        }
        END {
            if (opening_fences != 1 || closing_fences != 1 || in_rows) {
                exit 1
            }
        }
    ' "$AUDIT_PATH"
}

extract_owned_cap_ids() {
    awk '
        /^### Already owned gaps$/ {
            matches++
            in_owned = 1
            next
        }
        in_owned && /^## / {
            in_owned = 0
        }
        in_owned {
            remaining = $0
            while (match(remaining, /CAP-[0-9]+/)) {
                cap_id = substr(remaining, RSTART, RLENGTH)
                if (!seen[cap_id]++) {
                    print cap_id
                }
                remaining = substr(remaining, RSTART + RLENGTH)
            }
        }
        END {
            if (matches != 1) {
                exit 1
            }
        }
    ' "$AUDIT_PATH"
}

extract_owned_roadmap_titles() {
    awk '
        /^### Already owned gaps$/ {
            in_owned = 1
            next
        }
        in_owned && /^## / {
            in_owned = 0
        }
        in_owned && /^- `/ {
            title = substr($0, 4)
            sub(/`.*/, "", title)
            print title
        }
    ' "$AUDIT_PATH"
}

extract_ranked_ownership() {
    local output_kind="$1"
    awk -v output_kind="$output_kind" '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        /^<!-- stage3-ranking:start -->$/ {
            in_ranking = 1
            next
        }
        /^<!-- stage3-ranking:end -->$/ {
            in_ranking = 0
        }
        in_ranking && /^\|/ {
            split($0, cells, "|")
            cap_id = trim(cells[2])
            owner = trim(cells[10])
            gsub(/`/, "", owner)
            if (cap_id == "CAP ID" || cap_id == "---" || owner == "none") {
                next
            }
            value = output_kind == "caps" ? cap_id : owner
            if (!seen[value]++) {
                print value
            }
        }
    ' "$AUDIT_PATH"
}

require_ownership_sources() {
    local cap_ids owned_cap_set ranked_cap_set owned_title_set ranked_title_set title
    if ! cap_ids="$(extract_owned_cap_ids)" || [ -z "$cap_ids" ]; then
        fail "Already owned gaps must name at least one owned CAP ID"
    else
        pass "Already owned gaps provides proposed-row exclusion CAP IDs"
    fi

    owned_cap_set="$(printf '%s\n' "$cap_ids" | sort -u)"
    ranked_cap_set="$(extract_ranked_ownership caps | sort -u)"
    if [ "$owned_cap_set" = "$ranked_cap_set" ]; then
        pass "Already owned CAP IDs match ranked existing-owner CAP IDs"
    else
        fail "Already owned CAP IDs differ from ranked existing-owner CAP IDs"
    fi

    owned_title_set="$(extract_owned_roadmap_titles | sort -u)"
    ranked_title_set="$(extract_ranked_ownership titles | sort -u)"
    if [ "$owned_title_set" = "$ranked_title_set" ]; then
        pass "Already owned ROADMAP titles match ranked existing-owner titles"
    else
        fail "Already owned ROADMAP titles differ from ranked existing-owner titles"
    fi

    while IFS= read -r title; do
        [ -n "$title" ] || continue
        if grep -Fq -- "$title" "$ROADMAP_PATH"; then
            pass "ROADMAP contains quoted owner: $title"
        else
            fail "ROADMAP is missing quoted owner from Already owned gaps: $title"
        fi
    done < <(extract_owned_roadmap_titles)
}

extract_expected_rows() {
    local owned_cap_ids
    owned_cap_ids="$(extract_owned_cap_ids | tr '\n' ' ')"
    awk '
        function trim(value) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            return value
        }
        function priority_for_verdict(verdict) {
            if (verdict == "blocks-switch") {
                return "P1"
            }
            if (verdict == "degrades") {
                return "P2"
            }
            return ""
        }
        function canonical_subsystems(value) {
            gsub(/`/, "", value)
            gsub(/;[[:space:]]*/, ",", value)
            gsub(/[[:space:]]+/, "", value)
            return value
        }
        /^<!-- stage3-ranking:start -->$/ {
            in_ranking = 1
            next
        }
        /^<!-- stage3-ranking:end -->$/ {
            in_ranking = 0
        }
        in_ranking && /^\|/ {
            split($0, cells, "|")
            cap_id = trim(cells[2])
            title = trim(cells[3])
            verdict = trim(cells[6])
            size = trim(cells[8])
            subsystems = canonical_subsystems(trim(cells[9]))
            existing_owner = trim(cells[10])
            if (cap_id == "CAP ID" || cap_id == "---") {
                next
            }
            if (existing_owner != "none" || index(" " owned_cap_ids " ", " " cap_id " ")) {
                next
            }
            if (verdict != "blocks-switch" && verdict != "degrades") {
                next
            }
            priority = priority_for_verdict(verdict)
            print "priority=" priority "; title=\"" title "\"; blocking=" verdict "; size=" size "; subsystems=" subsystems
        }
    ' owned_cap_ids="$owned_cap_ids" "$AUDIT_PATH"
}

extract_closeout_paragraph() {
    awk '
        /^Proposed-row count:/ {
            matches++
            if (matches > 1) {
                exit 1
            }
            paragraph = $0
            in_paragraph = 1
            next
        }
        in_paragraph && /^$/ {
            print paragraph
            printed = 1
            in_paragraph = 0
            next
        }
        in_paragraph {
            paragraph = paragraph " " $0
        }
        END {
            if (matches != 1) {
                exit 1
            }
            if (!printed) {
                print paragraph
            }
        }
    ' "$AUDIT_PATH"
}

extract_row_title() {
    local row="$1"
    local title_pattern='title="([^"]+)"'
    if [[ "$row" =~ $title_pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    fi
}

validate_closeout_handoff() {
    local actual_row_count="$1"
    local first_row="$2"
    local closeout expected_first_title
    local closeout_pattern='^Proposed-row count: ([0-9]+)\. If only one batch can be picked first, run the batch for "([^"]+)" first because .+\.$'

    if ! closeout="$(extract_closeout_paragraph)"; then
        fail "expected exactly one Proposed-row count closeout paragraph"
        return
    fi
    if [[ ! "$closeout" =~ $closeout_pattern ]]; then
        fail "Proposed-row count closeout paragraph is malformed: $closeout"
        return
    fi

    if [ "${BASH_REMATCH[1]}" -eq "$actual_row_count" ]; then
        pass "Proposed-row count matches rows fence"
    else
        fail "Proposed-row count is ${BASH_REMATCH[1]} but rows fence contains $actual_row_count"
    fi

    expected_first_title="$(extract_row_title "$first_row")"
    if [ "${BASH_REMATCH[2]}" = "$expected_first_title" ]; then
        pass "named first batch matches the first proposed row"
    else
        fail "named first batch does not match the first proposed row: named=${BASH_REMATCH[2]} expected=$expected_first_title"
    fi
}

validate_rows() {
    local row rows row_number=0 nonempty_rows=0
    local -a actual_rows=() expected_rows=()
    local row_pattern='^priority=[^[:space:];]+; title="[^"]+"; blocking=(blocks-switch|degrades); size=(S|M|L); subsystems=[^[:space:];,]+(,[^[:space:];,]+)*$'
    if ! rows="$(extract_rows)"; then
        fail "rows: block must have exactly one opening and one closing fence"
        return
    fi

    while IFS= read -r row || [ -n "$row" ]; do
        row_number=$((row_number + 1))
        if [ -z "$row" ]; then
            continue
        fi
        nonempty_rows=$((nonempty_rows + 1))
        actual_rows+=("$row")
        if [[ "$row" =~ $row_pattern ]]; then
            pass "row $row_number matches canonical format"
        else
            fail "row $row_number has invalid format: $row"
        fi
    done <<< "$rows"

    if [ "$nonempty_rows" -gt 0 ]; then
        pass "rows fence contains $nonempty_rows proposed rows"
    else
        fail "rows fence contains zero proposed rows"
    fi

    while IFS= read -r row || [ -n "$row" ]; do
        if [ -n "$row" ]; then
            expected_rows+=("$row")
        fi
    done < <(extract_expected_rows)

    if [ "${#actual_rows[@]}" -ne "${#expected_rows[@]}" ]; then
        fail "rows fence contains ${#actual_rows[@]} proposed rows but Stage 3 expects ${#expected_rows[@]}"
    else
        pass "rows fence cardinality matches Stage 3 expected rows"
    fi

    local max_rows=${#actual_rows[@]}
    if [ "${#expected_rows[@]}" -gt "$max_rows" ]; then
        max_rows=${#expected_rows[@]}
    fi

    local index actual expected
    for ((index = 0; index < max_rows; index++)); do
        actual="${actual_rows[$index]:-<missing>}"
        expected="${expected_rows[$index]:-<none expected>}"
        if [ "$actual" = "$expected" ]; then
            pass "row $((index + 1)) matches Stage 3 expected row"
        else
            fail "row $((index + 1)) does not match Stage 3 expected row: actual=$actual expected=$expected"
        fi
    done

    if [ "${#actual_rows[@]}" -gt 0 ]; then
        validate_closeout_handoff "${#actual_rows[@]}" "${actual_rows[0]}"
    fi
}

require_file
if [ -f "$AUDIT_PATH" ]; then
    require_roadmap_file
    require_stage3_summary
    require_current_scope_contract
    require_stage_scope_review
    require_proposed_rows_section
    if [ -f "$ROADMAP_PATH" ] && [ -r "$ROADMAP_PATH" ]; then
        require_ownership_sources
        validate_rows
    fi
fi

if [ "$FAILURES" -gt 0 ]; then
    exit 1
fi
