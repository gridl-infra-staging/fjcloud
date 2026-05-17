#!/usr/bin/env bash
# Wrap git push with best-effort mirror sync on main.

set -u -o pipefail

warn() {
    echo "WARNING: $*" >&2
}

resolve_debbie_cli() {
    if command -v debbie >/dev/null 2>&1; then
        command -v debbie
        return 0
    fi

    if [[ -n "${DEBBIE_BIN:-}" && -x "${DEBBIE_BIN}" ]]; then
        echo "${DEBBIE_BIN}"
        return 0
    fi

    return 1
}

git push "$@"
push_exit_code=$?
if [[ "$push_exit_code" -ne 0 ]]; then
    exit "$push_exit_code"
fi

if [[ "${SKIP_DEBBIE_SYNC:-0}" == "1" ]]; then
    exit 0
fi

current_branch=""
if ! current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"; then
    warn "Unable to detect current branch; skipping mirror sync."
    exit 0
fi

if [[ "$current_branch" != "main" ]]; then
    exit 0
fi

debbie_cli=""
if ! debbie_cli="$(resolve_debbie_cli)"; then
    warn "debbie CLI unavailable; skipping mirror sync. Install debbie or set DEBBIE_BIN to the executable path."
    exit 0
fi

if ! "$debbie_cli" sync staging; then
    warn "debbie sync staging failed; continuing because mirror sync is best-effort."
fi

if ! "$debbie_cli" sync prod; then
    warn "debbie sync prod failed; continuing because mirror sync is best-effort."
fi
