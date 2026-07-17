#!/usr/bin/env bash
# compose_project.sh — Resolve COMPOSE_PROJECT_NAME for the local-dev stack.
#
# Why this exists (anchored 2026-05-31): docker compose defaults its project
# name to the basename of the working directory. Multiple fjcloud worktrees
# all named `fjcloud_dev` therefore shared the same default project name —
# meaning a second worktree's `docker compose up` silently clobbered the
# first worktree's containers (postgres data volume included). The fix is
# to derive the project name from the FULL path so each worktree gets a
# distinct, human-readable container namespace.
#
# Sourced by both scripts/local-dev-up.sh and scripts/local-dev-down.sh so
# `docker compose down` tears down the SAME project that `docker compose
# up` started.
#
# Test: scripts/tests/compose_project_test.sh.

# Returns a docker-compose-safe project name derived from the given repo
# root path. Honors an explicit COMPOSE_PROJECT_NAME if the operator has
# set one (e.g. to share a stack across worktrees intentionally).
#
# Output format: `fjcloud_<parent-basename>_<repo-basename>`, lowercased,
# with any character outside `[a-z0-9_-]` replaced by `_`. Docker compose
# requires project names to match `[a-z0-9][a-z0-9_-]*`.
# TODO: Document resolve_compose_project_name.
# TODO: Document resolve_compose_project_name.
# TODO: Document resolve_compose_project_name.
# TODO: Document resolve_compose_project_name.
# TODO: Document resolve_compose_project_name.
# Preserve an explicit operator override; otherwise derive a stable per-worktree name.
# Print only the normalized Compose project name to standard output.
# TODO: Document resolve_compose_project_name.
# TODO: Document resolve_compose_project_name.
resolve_compose_project_name() {
    local repo_root="$1"

    # Operator-provided override takes precedence — this lets ops scripts
    # or CI pin a specific project name without editing the helper.
    if [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
        printf '%s\n' "$COMPOSE_PROJECT_NAME"
        return 0
    fi

    local parent_dir repo_name raw sanitized
    parent_dir="$(basename "$(dirname "$repo_root")")"
    repo_name="$(basename "$repo_root")"
    raw="fjcloud_${parent_dir}_${repo_name}"

    # Lowercase, then collapse any disallowed chars to `_`. Docker compose
    # accepts `[a-z0-9][a-z0-9_-]*`; this sanitizer is conservative enough
    # for any plausible repo path (spaces, parens, dots, mixed case).
    sanitized="$(printf '%s' "$raw" \
        | tr '[:upper:]' '[:lower:]' \
        | tr -c 'a-z0-9_-' '_')"

    # Strip any leading run of `_` so the result starts with [a-z0-9].
    # `tr -c` may have introduced one if `parent_dir` was something like
    # `(test)` — without this, docker would reject the name.
    sanitized="$(printf '%s' "$sanitized" | sed -E 's/^_+//')"

    printf '%s\n' "$sanitized"
}
