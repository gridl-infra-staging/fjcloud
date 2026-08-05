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
        1) unconsumed+=("$basename_only") ;;
        *)
            echo "ERROR: unable to read handover application sites while checking $basename_only" >&2
            exit 2
            ;;
    esac
done

total=${#handovers[@]}
unconsumed_count=${#unconsumed[@]}

echo "handover_total=${total} consumed=${consumed_count} unconsumed=${unconsumed_count}"

if [ "$unconsumed_count" -eq 0 ]; then
    exit 0
fi

for name in ${unconsumed[@]+"${unconsumed[@]}"}; do
    echo "UNCONSUMED chatting/${name}"
done
echo "Each file above records ROADMAP.md rows a merged lane changed and that ROADMAP.md does not yet reflect."
echo "Apply them to ROADMAP.md (or fold them into an implemented/ record and cite it) rather than re-deriving the facts."
exit 1
