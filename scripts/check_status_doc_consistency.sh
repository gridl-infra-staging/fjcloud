#!/usr/bin/env bash
# check_status_doc_consistency.sh — assert NOW.md is not stale relative to
# LAUNCH.md's most recent ## STATUS entry.
#
# Why this exists: the project had a drift class where LAUNCH.md got a fresh
# STATUS append (a B1 verdict, an announce-gate run, a launch-readiness
# refresh) but NOW.md still pointed at the prior stage. Two different docs
# describing the same state — readers picked whichever they hit first and
# got contradicting reads.
#
# The check enforces a one-direction constraint: NOW.md's "Last updated:"
# date must be >= the most recent ### YYYY-MM-DD heading under LAUNCH.md's
# ## STATUS section. If it isn't, NOW.md is stale and an agent reading it
# will be misled.
#
# This is intentionally NOT a content match (NOW.md's text doesn't have to
# parrot LAUNCH.md's verdict label). It's a freshness invariant. The
# substance of what NOW.md says is the operator's choice; this gate only
# ensures the operator (or an agent) actually re-read NOW.md after the
# latest STATUS append.
#
# Exit codes:
#   0 — NOW.md is at least as fresh as the latest STATUS entry
#   1 — drift or missing files / sections
#
# Env vars:
#   FJCLOUD_DOC_ROOT  override the repo root for testing (defaults to script's
#                     repo root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_DOC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
NOW_MD="$REPO_ROOT/docs/NOW.md"
LAUNCH_MD="$REPO_ROOT/LAUNCH.md"

# ============================================================
# Sanity: required files present.
# ============================================================
if [ ! -f "$NOW_MD" ]; then
    echo "FAIL: docs/NOW.md not found at $NOW_MD" >&2
    exit 1
fi
if [ ! -f "$LAUNCH_MD" ]; then
    echo "FAIL: LAUNCH.md not found at $LAUNCH_MD" >&2
    exit 1
fi

# ============================================================
# Extract LAUNCH.md's most recent STATUS-section date.
#
# LAUNCH.md structure assumed:
#   ## STATUS — append at end of each work session
#   ### YYYY-MM-DD (free-form trailing text)
#   ### YYYY-MM-DD (free-form trailing text)
#   ...
#
# "Most recent" is the FIRST ### heading after the ## STATUS marker, because
# the file is maintained newest-on-top per its own header instruction:
# "Most recent on top."
# ============================================================
status_dates="$(awk '
    /^## STATUS/ { in_status = 1; next }
    in_status && /^## / { in_status = 0 }
    in_status && /^### [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
        match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)
        print substr($0, RSTART, RLENGTH)
    }
' "$LAUNCH_MD")"

if [ -z "$status_dates" ]; then
    echo "FAIL: LAUNCH.md has no '## STATUS' section with dated ### entries (or the section is empty)" >&2
    exit 1
fi

# First date in the awk output = most recent STATUS entry's date.
latest_status_date="$(printf '%s\n' "$status_dates" | head -1)"

# ============================================================
# Extract NOW.md's "Last updated:" date.
# Pattern matches: **Last updated:** 2026-05-27 PM (anything)
# or:                Last updated: 2026-05-27
# ============================================================
now_date_line="$(grep -E '\*\*Last updated:\*\*|^Last updated:' "$NOW_MD" || true)"
if [ -z "$now_date_line" ]; then
    echo "FAIL: docs/NOW.md has no 'Last updated:' line" >&2
    exit 1
fi

now_date="$(printf '%s\n' "$now_date_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
if [ -z "$now_date" ]; then
    echo "FAIL: docs/NOW.md 'Last updated:' line does not contain a YYYY-MM-DD date" >&2
    echo "       line was: $now_date_line" >&2
    exit 1
fi

# ============================================================
# String comparison works for ISO 8601 dates because YYYY-MM-DD sorts
# lexicographically the same as chronologically.
# ============================================================
if [ "$now_date" \< "$latest_status_date" ]; then
    echo "FAIL: docs/NOW.md (Last updated: $now_date) is stale relative to" >&2
    echo "      LAUNCH.md most recent STATUS entry ($latest_status_date)." >&2
    echo "" >&2
    echo "Fix: update docs/NOW.md to reflect the current launch state after" >&2
    echo "the LAUNCH.md STATUS entry was appended. The two docs describe" >&2
    echo "the same gate from different angles; NOW.md must not lag." >&2
    exit 1
fi

echo "OK: docs/NOW.md ($now_date) is current with LAUNCH.md STATUS ($latest_status_date)"
exit 0
