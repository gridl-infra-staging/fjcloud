#!/usr/bin/env bash
# Wrap git push with best-effort staging mirror sync on main.
#
# Prod is NOT synced by default: prod promotion is a deliberate, gated step
# owned by scripts/launch/post_wave_a_sync_prod.sh --execute (staging CI must
# be green at staging HEAD first). Set PROD_SYNC=1 to include prod in this
# push's sync anyway. See docs/runbooks/git_push_with_sync.md.

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

warn() {
    echo "WARNING: $*" >&2
}

source "$SCRIPT_DIR/lib/debbie_cli.sh"

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

# Prod stays behind the gated promotion path unless the pusher opts in.
if [[ "${PROD_SYNC:-0}" == "1" ]]; then
    if ! "$debbie_cli" sync prod; then
        warn "debbie sync prod failed; continuing because mirror sync is best-effort."
    fi
else
    echo "NOTE: prod mirror not synced (default). Promote via 'bash scripts/launch/post_wave_a_sync_prod.sh --execute', or rerun with PROD_SYNC=1." >&2
fi
