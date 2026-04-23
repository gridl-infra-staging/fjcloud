#!/usr/bin/env bash
# Shared Flapjack binary discovery helpers for local/integration/chaos scripts.
#
# Callers must define REPO_ROOT before sourcing this file.
#
# Contract:
# - Candidate repository order is fixed and bounded.
# - Directory candidates come from FLAPJACK_DEV_DIR (explicit), then
#   FLAPJACK_DEV_DIR_CANDIDATES (if set), then default repo-relative candidates.
# - Binary preference is fixed:
#   target/debug/flapjack
#   target/debug/flapjack-http
#   target/release/flapjack
#   target/release/flapjack-http
# - Restart-critical callers may fall back to PATH (`flapjack`, then
#   `flapjack-http`) only after directory candidates fail.

default_flapjack_dev_dir_candidates() {
    printf '%s\n' \
        "$REPO_ROOT/../flapjack_dev" \
        "$REPO_ROOT/../flapjack_dev/engine" \
        "$REPO_ROOT/../../gridl-dev/flapjack_dev/engine" \
        "$REPO_ROOT/../../gridl-dev/flapjack_dev"
}

configured_flapjack_dev_dir_candidates() {
    if [ -n "${FLAPJACK_DEV_DIR:-}" ]; then
        printf '%s\n' "$FLAPJACK_DEV_DIR"
    fi

    local candidate
    if [ -n "${FLAPJACK_DEV_DIR_CANDIDATES:-}" ]; then
        for candidate in $FLAPJACK_DEV_DIR_CANDIDATES; do
            printf '%s\n' "$candidate"
        done
        return 0
    fi

    default_flapjack_dev_dir_candidates
}

resolve_default_flapjack_dev_dir() {
    if [ -n "${FLAPJACK_DEV_DIR:-}" ]; then
        printf '%s\n' "$FLAPJACK_DEV_DIR"
        return 0
    fi

    local candidate
    while IFS= read -r candidate; do
        [ -d "$candidate" ] || continue
        printf '%s\n' "$candidate"
        return 0
    done < <(configured_flapjack_dev_dir_candidates)

    # Preserve the historical adjacent-checkout fallback for warning/error text.
    printf '%s\n' "$REPO_ROOT/../flapjack_dev"
}

find_flapjack_binary() {
    local flapjack_dev_dir="${1:-${FLAPJACK_DEV_DIR:-}}"
    [ -d "$flapjack_dev_dir" ] || return 1

    local root candidate relative_path
    for relative_path in \
        "target/debug/flapjack" \
        "target/debug/flapjack-http" \
        "target/release/flapjack" \
        "target/release/flapjack-http"
    do
        for root in "$flapjack_dev_dir" "$flapjack_dev_dir/engine"; do
            candidate="$root/$relative_path"
            [ -x "$candidate" ] || continue
            printf '%s\n' "$candidate"
            return 0
        done
    done

    return 1
}

find_restart_ready_flapjack_binary() {
    local flapjack_dev_dir="${1:-${FLAPJACK_DEV_DIR:-}}"
    local resolved_binary=""

    if [ -n "$flapjack_dev_dir" ]; then
        resolved_binary="$(find_flapjack_binary "$flapjack_dev_dir" || true)"
        if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
            printf '%s\n' "$resolved_binary"
            return 0
        fi
    fi

    local candidate_dir
    while IFS= read -r candidate_dir; do
        [ -n "$candidate_dir" ] || continue
        [ "$candidate_dir" = "$flapjack_dev_dir" ] && continue
        resolved_binary="$(find_flapjack_binary "$candidate_dir" || true)"
        if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
            printf '%s\n' "$resolved_binary"
            return 0
        fi
    done < <(configured_flapjack_dev_dir_candidates)

    if [ -n "$resolved_binary" ] && [ -x "$resolved_binary" ]; then
        printf '%s\n' "$resolved_binary"
        return 0
    fi

    if command -v flapjack >/dev/null 2>&1; then
        command -v flapjack
        return 0
    fi
    if command -v flapjack-http >/dev/null 2>&1; then
        command -v flapjack-http
        return 0
    fi

    return 1
}
