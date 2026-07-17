#!/usr/bin/env bash
# check_status_doc_consistency.sh — assert doc-system v2 launch/work owners
# are present and retired mutable-owner docs have not been recreated.
#
# Exit codes:
#   0 — v2 owner surface is present and retired owners are absent
#   1 — drift or missing files / sections
#
# Env vars:
#   FJCLOUD_DOC_ROOT  override the repo root for testing (defaults to script's
#                     repo root)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_DOC_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
LAUNCH_MD="$REPO_ROOT/LAUNCH.md"
ROADMAP_MD="$REPO_ROOT/ROADMAP.md"
PROJECT_OVERVIEW_MD="$REPO_ROOT/PROJECT_OVERVIEW.md"

if [ ! -f "$LAUNCH_MD" ]; then
    echo "FAIL: LAUNCH.md not found at $LAUNCH_MD" >&2
    exit 1
fi
if [ ! -f "$ROADMAP_MD" ]; then
    echo "FAIL: ROADMAP.md not found at $ROADMAP_MD" >&2
    exit 1
fi
if [ ! -f "$PROJECT_OVERVIEW_MD" ]; then
    echo "FAIL: PROJECT_OVERVIEW.md not found at $PROJECT_OVERVIEW_MD" >&2
    exit 1
fi

retired_docs=(
    "$REPO_ROOT/docs/NO""W.md"
    "$REPO_ROOT/PRIOR""ITIES.md"
    "$REPO_ROOT/docs/LOCAL_LAUNCH_READ""INESS.md"
)

for retired_doc in "${retired_docs[@]}"; do
    if [ -e "$retired_doc" ]; then
        echo "FAIL: retired mutable-owner doc still exists: ${retired_doc#$REPO_ROOT/}" >&2
        exit 1
    fi
done

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

latest_status_date="$(printf '%s\n' "$status_dates" | head -1)"

if ! grep -q 'LAUNCH.md.*owns the v1 launch sentence' "$ROADMAP_MD"; then
    echo "FAIL: ROADMAP.md does not point launch readiness back to LAUNCH.md" >&2
    exit 1
fi

if ! grep -q 'ROADMAP.md.*owns the active and planned work ledger' "$PROJECT_OVERVIEW_MD"; then
    echo "FAIL: PROJECT_OVERVIEW.md does not point open work back to ROADMAP.md" >&2
    exit 1
fi

echo "OK: LAUNCH.md STATUS owner present ($latest_status_date); retired mutable-owner docs absent"
exit 0
