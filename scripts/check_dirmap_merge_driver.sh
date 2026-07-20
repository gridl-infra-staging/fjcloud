#!/usr/bin/env bash
# check_dirmap_merge_driver.sh — assert the DIRMAP merge driver is fully wired.
#
# The DIRMAP anti-duplication mechanism has TWO halves that must agree:
#   1. .gitattributes declares `**/DIRMAP.md merge=ours`  (committed, shared)
#   2. git config defines  merge.ours.driver             (per-clone, NOT committed)
#
# A clone with only half 1 is strictly worse than plain union merge: git runs a
# normal 3-way merge and CONFLICTS on every divergent DIRMAP.md. This gate makes
# that half-configured state fail loudly instead of surfacing as a surprise
# conflict during someone's merge.
#
# Exit codes:
#   0 — both halves present and consistent
#   1 — declaration missing, or declared-but-not-registered
#
# Env vars:
#   FJCLOUD_REPO_ROOT  override the repo root for testing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
GITATTRIBUTES="$REPO_ROOT/.gitattributes"
SETUP_HINT="scripts/setup_git_merge_drivers.sh"

fail_count=0

# ------------------------------------------------------------
# Half 1: the committed declaration must exist. Guards against a future revert
# of the .gitattributes line, which would silently reopen union-merge.
# ------------------------------------------------------------
if [ ! -f "$GITATTRIBUTES" ] || ! grep -Eq '^\*\*/DIRMAP\.md[[:space:]]+merge=ours$' "$GITATTRIBUTES"; then
    echo "FAIL: .gitattributes must declare '**/DIRMAP.md merge=ours'" >&2
    echo "      Without it, DIRMAP.md files revert to accumulating duplicated rows." >&2
    fail_count=$((fail_count + 1))
fi

# ------------------------------------------------------------
# Half 2: the driver must be registered in this clone's git config.
# ------------------------------------------------------------
driver="$(git -C "$REPO_ROOT" config --get merge.ours.driver 2>/dev/null || true)"
if [ -z "$driver" ]; then
    echo "FAIL: merge driver 'ours' is declared in .gitattributes but not registered in git config." >&2
    echo "      DIRMAP.md merges will CONFLICT until you run: bash $SETUP_HINT" >&2
    fail_count=$((fail_count + 1))
fi

if [ "$fail_count" -gt 0 ]; then
    exit 1
fi

echo "OK: DIRMAP merge driver declared (.gitattributes) and registered (merge.ours.driver=$driver)"
exit 0
