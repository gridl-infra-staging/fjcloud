#!/usr/bin/env bash
# Shared debbie CLI resolver. Sourced by scripts that need to locate
# the debbie binary (git_push_with_sync.sh, post_wave_a_sync_prod.sh).

resolve_debbie_cli() {
    if [[ -n "${DEBBIE_BIN:-}" && -x "${DEBBIE_BIN}" ]]; then
        echo "${DEBBIE_BIN}"
        return 0
    fi

    if command -v debbie >/dev/null 2>&1; then
        command -v debbie
        return 0
    fi

    return 1
}
