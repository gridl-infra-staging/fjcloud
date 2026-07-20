#!/usr/bin/env bash
# check_package_manager_consistency.sh — assert web/ uses exactly one package
# manager, and that it is npm.
#
# This gate is the canonical owner of the "one package manager" invariant.
# It exists because the repo genuinely forked (captured 2026-07-19):
#   - CI installs with `npm ci` in 5 places (.github/workflows/ci.yml:142,
#     235, 266, 491, 563) and never invokes pnpm anywhere.
#   - ~8 contract tests assert the literal string `npm ci`.
#   - Yet web/ also tracked pnpm-lock.yaml, and scripts/local-ci.sh told
#     developers to run `pnpm install` — three lines above a comment reading
#     "local devs already have node_modules from `npm install`".
#   - The working tree carried BOTH install markers (node_modules/.package-lock.json
#     from npm AND node_modules/.modules.yaml from pnpm), i.e. a hybrid install.
# That split-brain already caused real drift: commit ba6b0ce07f exists only to
# re-sync package-lock.json's devalue 5.6.3 -> 5.8.1 to "mirror npm ci".
#
# Why a script and not just the `packageManager` field in package.json:
# Corepack — the thing that would enforce that field — was unbundled from
# Node.js 25+ and is NOT installed on this machine (verified 2026-07-19, and
# this repo runs Node v26). The field is therefore documentation only. This
# executable gate is the enforcement.
#
# Exit codes:
#   0 — web/ declares exactly one package manager and it is npm
#   1 — drift detected
#
# Env vars:
#   FJCLOUD_REPO_ROOT  override the repo root for testing (defaults to the
#                      script's repo root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
WEB_DIR="$REPO_ROOT/web"
REQUIRED_LOCKFILE="package-lock.json"

# Closed set of lockfiles belonging to package managers this repo does NOT use.
# Enumerated rather than globbed so a new manager's lockfile is a deliberate
# decision to add here, not a silent pass.
COMPETING_LOCKFILES=(
    "pnpm-lock.yaml"
    "yarn.lock"
    "bun.lockb"
)

fail_count=0

# ------------------------------------------------------------
# 1. The npm lockfile must exist — CI runs `npm ci`, which hard-fails
#    without it. A missing lockfile is a broken build, not a style issue.
# ------------------------------------------------------------
if [ ! -f "$WEB_DIR/$REQUIRED_LOCKFILE" ]; then
    echo "FAIL: web/$REQUIRED_LOCKFILE is missing; CI runs 'npm ci' which requires it" >&2
    fail_count=$((fail_count + 1))
fi

# ------------------------------------------------------------
# 2. No competing lockfile may exist. Two lockfiles mean two resolvable
#    dependency graphs; whichever tool runs last silently wins.
# ------------------------------------------------------------
for lockfile in "${COMPETING_LOCKFILES[@]}"; do
    if [ -f "$WEB_DIR/$lockfile" ]; then
        echo "FAIL: web/$lockfile present; this repo standardized on npm (CI uses 'npm ci')" >&2
        echo "      Remove it: git rm web/$lockfile" >&2
        fail_count=$((fail_count + 1))
    fi
done

# ------------------------------------------------------------
# 3. If package.json declares a packageManager, it must name npm.
#    Absent is tolerated (Corepack is not installed, so the field is
#    advisory) — but a field naming a DIFFERENT manager is an active
#    contradiction of the lockfile contract above, so it fails.
# ------------------------------------------------------------
PACKAGE_JSON="$WEB_DIR/package.json"
if [ -f "$PACKAGE_JSON" ]; then
    declared_manager="$(sed -nE 's/.*"packageManager"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$PACKAGE_JSON" | head -1)"
    case "$declared_manager" in
        "")
            : ;;                # absent — advisory only, see comment above
        npm@*|npm)
            : ;;                # correct declaration
        *)
            echo "FAIL: web/package.json packageManager is '$declared_manager'; expected npm@<version>" >&2
            fail_count=$((fail_count + 1))
            ;;
    esac
fi

if [ "$fail_count" -gt 0 ]; then
    echo "" >&2
    echo "web/ failed $fail_count package-manager consistency invariant(s)." >&2
    exit 1
fi

echo "OK: web/ declares exactly one package manager (npm)"
exit 0
