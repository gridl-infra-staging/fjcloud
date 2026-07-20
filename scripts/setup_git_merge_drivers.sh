#!/usr/bin/env bash
# setup_git_merge_drivers.sh — register this repo's custom git merge drivers.
#
# Run once per clone. Idempotent: safe to re-run any time.
#
# WHY THIS IS NEEDED
# ------------------
# .gitattributes declares `**/DIRMAP.md merge=ours`, but a merge driver named in
# .gitattributes does nothing until it is DEFINED in git config — and git config
# is per-clone and cannot be committed. Without this registration, git falls
# back to a normal 3-way merge for DIRMAP.md and CONFLICTS on every divergence
# (empirically confirmed 2026-07-19). This script supplies the missing half.
#
# WHY `ours` / `true`
# -------------------
# DIRMAP.md files are generated summaries. On a merge conflict we simply keep the
# current branch's copy and let the next `matt scrai dirmap` regenerate it from
# source — there is nothing to hand-merge. The `true` command always exits 0
# without touching the file, so git keeps "our" content. This is what stops the
# union-merge row accumulation that this driver replaces.
#
# WORKTREES: git worktrees share the parent clone's config, so running this once
# in the clone (or any of its worktrees) covers all of them.
#
# Env vars:
#   FJCLOUD_REPO_ROOT  override the repo root (defaults to this script's repo).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# `git config` with no --global writes the repo-local config for whichever repo
# owns REPO_ROOT. -C points git at that repo regardless of the current dir.
git -C "$REPO_ROOT" config merge.ours.name "keep our version (generated files regenerated from source)"
git -C "$REPO_ROOT" config merge.ours.driver true

echo "OK: registered merge driver 'ours' (merge.ours.driver=true) for $REPO_ROOT"
