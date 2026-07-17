#!/usr/bin/env bash
# web-dev.sh — Start the SvelteKit dev server with repo-local auth env loaded.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/web_runtime.sh
source "$SCRIPT_DIR/lib/web_runtime.sh"

log() { echo "[web-dev] $*"; }
die() {
    echo "[web-dev] ERROR: $*" >&2
    exit 1
}

remember_explicit_env() {
    local var_name="$1"
    local flag_name="WEB_DEV_${var_name}_WAS_SET"
    local value_name="WEB_DEV_${var_name}_VALUE"

    if [ "${!var_name+x}" = "x" ]; then
        printf -v "$flag_name" '%s' "1"
        printf -v "$value_name" '%s' "${!var_name}"
    else
        printf -v "$flag_name" '%s' "0"
        printf -v "$value_name" '%s' ""
    fi
}

restore_explicit_env() {
    local var_name="$1"
    local flag_name="WEB_DEV_${var_name}_WAS_SET"
    local value_name="WEB_DEV_${var_name}_VALUE"

    if [ "${!flag_name}" = "1" ]; then
        printf -v "$var_name" '%s' "${!value_name}"
        export "$var_name"
    fi
}

remember_explicit_env "API_BASE_URL"
remember_explicit_env "JWT_SECRET"
remember_explicit_env "ADMIN_KEY"

load_layered_env_files "$REPO_ROOT/.env.local" "$REPO_ROOT/web/.env.local"

restore_explicit_env "API_BASE_URL"
restore_explicit_env "JWT_SECRET"
restore_explicit_env "ADMIN_KEY"

API_BASE_URL="${API_BASE_URL:-http://localhost:3001}"
[ -n "${JWT_SECRET:-}" ] || die "JWT_SECRET is required (set it in .env.local, web/.env.local, or the shell environment)"
[ -n "${ADMIN_KEY:-}" ] || die "ADMIN_KEY is required (set it in .env.local, web/.env.local, or the shell environment)"

export API_BASE_URL
export JWT_SECRET
export ADMIN_KEY

has_web_vite_runtime "$REPO_ROOT" || die "$(web_vite_runtime_missing_message)"

log "Starting web dev server with API_BASE_URL=$API_BASE_URL"
cd "$REPO_ROOT/web"

vite_args=("$@")
has_strict_port_arg=0
for arg in "$@"; do
    case "$arg" in
        --strictPort|--strictPort=*)
            has_strict_port_arg=1
            break
            ;;
    esac
done

# Strict ports prevent wrong-app false greens when the default port is occupied.
if [ "$has_strict_port_arg" -eq 0 ]; then
    vite_args+=(--strictPort)
fi

exec npm run dev -- "${vite_args[@]}"
