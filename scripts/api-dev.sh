#!/usr/bin/env bash
# api-dev.sh — Start the API with repo-local env files exported.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"

if [ -f "$REPO_ROOT/.env.local" ]; then
    load_env_file "$REPO_ROOT/.env.local"
fi
export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
# Local Flapjack does not expose the internal replication API used by the
# production orchestrator. Keep the task effectively dormant unless a developer
# explicitly opts into testing replication behavior with a shorter interval.
export REPLICATION_CYCLE_INTERVAL_SECS="${REPLICATION_CYCLE_INTERVAL_SECS:-999999}"

cd "$REPO_ROOT"
exec cargo run --manifest-path infra/Cargo.toml -p api "$@"
