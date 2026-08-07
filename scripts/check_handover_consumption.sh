#!/usr/bin/env bash
# check_handover_consumption.sh — report ROADMAP handovers that were written but
# never applied to the SSOT.
#
# WHY THIS EXISTS
#
# Feature lanes in a batch each write `chatting/<batch>_roadmap_handover_<lane>.md`
# (older batches spelled it `_roadmap_corrections_`) describing the `ROADMAP.md`
# rows their work changed. The batch's terminal reconcile lane applies them. That
# reconcile lane is authored last and dispatched last, so whatever stops a batch
# stops the one lane that would have recorded what the batch did:
#
#   - aug02_5am  — fc{1,2,4} handovers written; consumer `aug02_5am_6` never dispatched.
#   - aug02_11am — fs{1,2,3,4,6,7} handovers written; consumer `aug02_11am_9` stopped
#                  at stage 2 of 3, leaving all six unapplied for ~14 hours.
#
# Both times the handovers were correct and on time. The gap was that nothing
# reported `ROADMAP.md` being behind the tree, so the next batch planned against a
# ledger that did not describe the current code.
#
# WHY IT IS A REPORT AND NOT A BLOCKING GATE
#
# The obvious design — fail any merge while an unreferenced handover exists —
# is a false gate. A feature lane's own merge carries the handover it just wrote,
# which is by definition not yet applied, so the gate would refuse the very merges
# that are behaving correctly. Instead `scripts/local-ci.sh` surfaces this as a
# SHADOW_WARN, which every lane sees because every lane runs `--fast` before push,
# and which cannot wrongly refuse anyone.
#
# The guard that must be able to fail is this script, and it is:
# `scripts/tests/check_handover_consumption_test.sh` drives it over fixture roots
# covering consumed, unconsumed, both filename spellings, the sibling-reference
# false positive, missing inputs, failed enumeration, and hostile filenames.
#
# ORACLE
#
# A handover is consumed when its basename appears in `ROADMAP.md` or in any
# `implemented/*.md` record. References from other files under `chatting/` do NOT
# count: lane-to-lane chatter is not application to the SSOT, and counting it would
# let a batch satisfy this probe by cross-referencing its own documents.
#
# SECOND CHANNEL: INLINE `## ROADMAP CORRECTION REQUIRED` SECTIONS
#
# The chatting/ population above is only half the story, and by 2026-08 it is the
# half that is falling out of use. Every `aug05` orchestration instructs its lanes
# to "append a `ROADMAP CORRECTION REQUIRED` section to this file" -- the lane's own
# `chats/icg/<lane>.md` checklist -- instead of writing a separate chatting/
# document. This probe was structurally blind to that, so a batch could route its
# entire correction traffic through a channel with no consumption check at all.
#
# Measured on `origin/main` 2026-08-06: three lane checklists carried such a
# section, and this probe reported `handover_total=25 consumed=25 unconsumed=0` --
# a clean bill of health computed over a population that excluded all three.
#
# Their consumed-oracle differs in one way, because the artifacts differ. A
# chatting/ handover is a purpose-built document, so ROADMAP.md cites it by
# basename. A lane checklist is not: ROADMAP.md cites the LANE, by its id
# (`aug05_1pm_1`), never by the checklist's full filename. So the id is the oracle,
# matched with a trailing non-digit boundary so `aug05_1pm_1` cannot be satisfied
# by an unrelated `aug05_1pm_10`.
#
# WHAT THIS STILL CANNOT SEE, STATED SO IT IS NOT MISTAKEN FOR COVERAGE
#
# A lane that was told to write a correction section and merged without writing one
# leaves nothing to enumerate, so no consumption check can catch it. Two merged
# lanes did exactly that on 2026-08-06 (`aug05_12pm_2`, `aug05_12pm_4`). A textual
# "instructed but absent" detector was considered and rejected: the instruction is
# sometimes conditional ("emit ... if the ledger needs a row"), so it would report
# lanes that correctly wrote nothing. That belongs to checklist authoring, not here.
#
# Exit codes:
#   0 — every handover is applied (or there are none)
#   1 — at least one handover is unapplied; each is named on stdout
#   2 — a required input is missing; this is an error, never a clean pass
#
# Env vars:
#   FJCLOUD_DOC_ROOT  override the repo root (used by the contract test)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_DOC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

CHATTING_DIR="$REPO_ROOT/chatting"
CHATS_ICG_DIR="$REPO_ROOT/chats/icg"
ROADMAP_MD="$REPO_ROOT/ROADMAP.md"
IMPLEMENTED_DIR="$REPO_ROOT/implemented"

ENUMERATION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud-handover-enumeration.XXXXXX")" || {
    echo "ERROR: unable to create handover enumeration workspace" >&2
    exit 2
}
# Invoked indirectly by the EXIT trap below.
# shellcheck disable=SC2329
cleanup_enumeration_dir() {
    rm -rf "$ENUMERATION_DIR"
}
trap cleanup_enumeration_dir EXIT

enumerate_paths_to_file() {
    local boundary_name="$1"
    local output_file="$2"
    local error_file="$ENUMERATION_DIR/find.stderr"
    local error_text=""
    shift 2
    if ! find "$@" -print0 >"$output_file" 2>"$error_file"; then
        # Keep ordinary diagnostics useful while preventing a hostile path in a
        # find error from injecting control bytes or extra log lines.
        error_text="$(tr '\n\r' '  ' <"$error_file" | LC_ALL=C tr -cd '\40-\176')"
        echo "ERROR: unable to enumerate $boundary_name: $error_text" >&2
        return 2
    fi
}

# Required inputs may not skip. A checkout missing chatting/ or ROADMAP.md cannot
# be described as having zero unconsumed handovers, so say so and exit 2 rather
# than reporting a denominator this probe never actually measured.
if [ ! -d "$CHATTING_DIR" ]; then
    echo "ERROR: required input missing: chatting/ directory not found at $CHATTING_DIR" >&2
    exit 2
fi
if [ ! -f "$ROADMAP_MD" ]; then
    echo "ERROR: required input missing: ROADMAP.md not found at $ROADMAP_MD" >&2
    exit 2
fi
# Same rule as chatting/ above: a checkout without chats/icg/ has an unmeasured
# inline-correction denominator, which must never be reported as a clean zero.
if [ ! -d "$CHATS_ICG_DIR" ]; then
    echo "ERROR: required input missing: chats/icg directory not found at $CHATS_ICG_DIR" >&2
    exit 2
fi

# Match on the `_handover_` / `_corrections_` shape, NOT on any batch's prose
# habits. Three spellings already exist in chatting/:
#   aug02_5am_roadmap_corrections_fc1.md
#   aug02_11am_roadmap_handover_fs1.md
#   aug03_11am_handover_fj1.md          <- no `roadmap` infix at all
# This probe's first version required the `roadmap` infix and so enumerated 10 of
# 14 files, reporting the repo clean while four of the newest handovers were
# invisible to it. A denominator that silently drops the newest artifacts is
# worse than no probe: it turns an unknown into a false assurance, which is the
# exact failure this probe exists to prevent. A future batch inventing a fourth
# spelling must keep this shape or extend this pattern.
handovers=()
handover_paths_file="$ENUMERATION_DIR/handovers"
if ! enumerate_paths_to_file "roadmap handovers" "$handover_paths_file" \
    "$CHATTING_DIR" -maxdepth 1 -type f \
    \( -name '*_handover_*.md' -o -name '*_corrections_*.md' \); then
    exit 2
fi
while IFS= read -r -d '' path; do
    basename_only="$(basename "$path")"
    case "$basename_only" in
        ''|*[!A-Za-z0-9_.-]*)
            echo "ERROR: unsafe handover filename rejected" >&2
            exit 2
            ;;
    esac
    handovers+=("$path")
done <"$handover_paths_file"

# Application sites: the SSOT itself, plus the implemented/ records a
# reconciliation may park long-form detail in while leaving a pointer in the row.
application_sites=("$ROADMAP_MD")
if [ -d "$IMPLEMENTED_DIR" ]; then
    implemented_paths_file="$ENUMERATION_DIR/implemented"
    if ! enumerate_paths_to_file "implemented records" "$implemented_paths_file" \
        "$IMPLEMENTED_DIR" -maxdepth 1 -type f -name '*.md'; then
        exit 2
    fi
    while IFS= read -r -d '' path; do
        application_sites+=("$path")
    done <"$implemented_paths_file"
fi

# Inline corrections: lane checklists under chats/icg/ that carry a written
# `## ROADMAP CORRECTION REQUIRED` heading. The heading must be a real heading --
# every orchestration also *instructs* lanes to append one, and chats/icg holds
# roughly 800 files, so a prose match would swamp the denominator with lanes that
# have nothing to apply.
inline_paths=()
inline_lane_ids=()
inline_candidates_file="$ENUMERATION_DIR/inline_candidates"
if ! enumerate_paths_to_file "inline roadmap corrections" "$inline_candidates_file" \
    "$CHATS_ICG_DIR" -maxdepth 1 -type f -name '*.md'; then
    exit 2
fi
while IFS= read -r -d '' path; do
    basename_only="$(basename "$path")"
    case "$basename_only" in
        ''|*[!A-Za-z0-9_.-]*)
            echo "ERROR: unsafe lane checklist filename rejected" >&2
            exit 2
            ;;
    esac
    grep_status=0
    grep -qE '^## ROADMAP CORRECTION REQUIRED[[:space:]]*$' "$path" || grep_status=$?
    case "$grep_status" in
        0) ;;
        1) continue ;;
        *)
            echo "ERROR: unable to read lane checklist ${basename_only}" >&2
            exit 2
            ;;
    esac

    # Derive the lane id: leading underscore-separated tokens up to and including
    # the first all-digit token (`aug05_12pm_2_pricing_registry.md` -> `aug05_12pm_2`).
    # ROADMAP.md cites lanes this way; it never cites the full checklist filename.
    stem="${basename_only%.md}"
    lane_id=""
    remainder="$stem"
    while [ -n "$remainder" ]; do
        token="${remainder%%_*}"
        if [ -z "$lane_id" ]; then
            lane_id="$token"
        else
            lane_id="${lane_id}_${token}"
        fi
        case "$token" in
            ''|*[!0-9]*) ;;
            *) break ;;
        esac
        if [ "$remainder" = "${remainder#*_}" ]; then
            # No separator left and the final token was not all digits.
            lane_id=""
            break
        fi
        remainder="${remainder#*_}"
    done
    case "${lane_id##*_}" in
        ''|*[!0-9]*) lane_id="" ;;
    esac
    if [ -z "$lane_id" ]; then
        # Fail closed. Guessing an id here would silently drop a real correction.
        echo "ERROR: unable to derive a lane id from chats/icg/${basename_only}" >&2
        exit 2
    fi

    inline_paths+=("chats/icg/${basename_only}")
    inline_lane_ids+=("$lane_id")
done <"$inline_candidates_file"

unconsumed=()
consumed_count=0

# bash 3.2 (the macOS system bash this repo runs on) treats "${arr[@]}" on an
# empty array as an unbound variable under `set -u`, so guard the loop rather
# than the expansion. Zero handovers is a real, reportable state -- not an error.
for handover in ${handovers[@]+"${handovers[@]}"}; do
    basename_only="$(basename "$handover")"
    # Fixed-string, whole-basename match. The basename carries the batch and lane,
    # so a substring match cannot collide across batches.
    reference_status=0
    grep -qFl -- "$basename_only" "${application_sites[@]}" 2>/dev/null || reference_status=$?
    case "$reference_status" in
        0) consumed_count=$((consumed_count + 1)) ;;
        1) unconsumed+=("chatting/${basename_only}") ;;
        *)
            echo "ERROR: unable to read handover application sites while checking $basename_only" >&2
            exit 2
            ;;
    esac
done

# Same application sites as the chatting/ population: the SSOT and the
# implemented/ records it points at. A sibling lane naming this lane id does NOT
# count -- chats/icg is deliberately absent from application_sites, so an
# orchestration listing its own roster cannot satisfy this probe.
inline_index=0
for inline_path in ${inline_paths[@]+"${inline_paths[@]}"}; do
    lane_id="${inline_lane_ids[$inline_index]}"
    inline_index=$((inline_index + 1))
    # Trailing non-digit-or-end boundary: without it `aug05_1pm_1` would be
    # satisfied by an unrelated `aug05_1pm_10` and the correction would vanish.
    reference_status=0
    grep -qE -- "${lane_id}([^0-9]|\$)" "${application_sites[@]}" 2>/dev/null || reference_status=$?
    case "$reference_status" in
        0) consumed_count=$((consumed_count + 1)) ;;
        1) unconsumed+=("$inline_path") ;;
        *)
            echo "ERROR: unable to read application sites while checking ${inline_path}" >&2
            exit 2
            ;;
    esac
done

inline_total=${#inline_paths[@]}
total=$(( ${#handovers[@]} + inline_total ))
unconsumed_count=${#unconsumed[@]}

echo "handover_total=${total} consumed=${consumed_count} unconsumed=${unconsumed_count}"
echo "inline_corrections=${inline_total}"

if [ "$unconsumed_count" -eq 0 ]; then
    exit 0
fi

for name in ${unconsumed[@]+"${unconsumed[@]}"}; do
    echo "UNCONSUMED ${name}"
done
echo "Each file above declares ROADMAP.md rows its lane changed, and ROADMAP.md does not yet reflect them."
echo "A lane still in flight is expected here; a merged one is a correction the SSOT has silently lost."
echo "Apply them to ROADMAP.md (or fold them into an implemented/ record and cite it) rather than re-deriving the facts."
exit 1
