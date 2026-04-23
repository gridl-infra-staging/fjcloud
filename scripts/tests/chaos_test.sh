#!/usr/bin/env bash
# Aggregate entrypoint for chaos script tests.
# Delegates to focused suites in deterministic order and fails fast.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

main() {
    bash "$SCRIPT_DIR/chaos_kill_region_test.sh"
    bash "$SCRIPT_DIR/chaos_restart_region_test.sh"
    bash "$SCRIPT_DIR/chaos_ha_failover_proof_test.sh"
}

main "$@"
