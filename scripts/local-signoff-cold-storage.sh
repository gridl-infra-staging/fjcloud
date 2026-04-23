#!/usr/bin/env bash
# local-signoff-cold-storage.sh — Thin env bridge + cargo test delegate for
# cold-storage integration signoff.
#
# Resolves strict local stack defaults, validates cold-storage prerequisites,
# delegates to the authoritative Rust integration test, and emits JSON +
# operator-readable evidence.
#
# Usage:
#   ./scripts/local-signoff-cold-storage.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"

# Local aliases for shared validation helpers.
append_step() { validation_append_step "$@"; }
emit_result() { validation_emit_result "$@"; }

log() { echo "[cold-storage-signoff] $*"; }
die() { echo "[cold-storage-signoff] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Env resolution — single source of truth for strict-local-to-integration
# env mapping (API base, Flapjack base, DB URL derivation).
# ---------------------------------------------------------------------------

resolve_strict_local_defaults() {
    export INTEGRATION_API_BASE="${INTEGRATION_API_BASE:-http://localhost:3001}"
    export INTEGRATION_FLAPJACK_BASE="${INTEGRATION_FLAPJACK_BASE:-http://127.0.0.1:7700}"

    # Derive INTEGRATION_DB_URL from DATABASE_URL when only the latter is set.
    if [ -z "${INTEGRATION_DB_URL:-}" ] && [ -n "${DATABASE_URL:-}" ]; then
        export INTEGRATION_DB_URL="$DATABASE_URL"
    fi
}

# ---------------------------------------------------------------------------
# Preflight — validate cold-storage inputs and API reachability.
# ---------------------------------------------------------------------------

require_cold_storage_env() {
    [ -n "${COLD_STORAGE_ENDPOINT:-}" ] || die "Required: COLD_STORAGE_ENDPOINT"
    [ -n "${COLD_STORAGE_BUCKET:-}" ]   || die "Required: COLD_STORAGE_BUCKET"
    [ -n "${COLD_STORAGE_REGION:-}" ]   || die "Required: COLD_STORAGE_REGION"
    [ -n "${COLD_STORAGE_ACCESS_KEY:-}" ] || die "Required: COLD_STORAGE_ACCESS_KEY"
    [ -n "${COLD_STORAGE_SECRET_KEY:-}" ] || die "Required: COLD_STORAGE_SECRET_KEY"

    if [ -z "${INTEGRATION_DB_URL:-}" ]; then
        die "Required: INTEGRATION_DB_URL (or set DATABASE_URL for automatic derivation)"
    fi

    if ! curl -sf "$INTEGRATION_API_BASE/health" >/dev/null 2>&1; then
        die "API health check failed at $INTEGRATION_API_BASE/health"
    fi
}

# ---------------------------------------------------------------------------
# Artifact directory
# ---------------------------------------------------------------------------

ARTIFACT_DIR=""

init_artifact_dir() {
    ARTIFACT_DIR="${TMPDIR:-/tmp}/fjcloud-cold-storage-signoff"
    mkdir -p "$ARTIFACT_DIR"
    log "Artifact directory: $ARTIFACT_DIR"
}

# ---------------------------------------------------------------------------
# Evidence writing
# ---------------------------------------------------------------------------

write_run_artifacts() {
    local passed="$1"
    local timestamp
    timestamp="$(date -u +%Y-%m-%d_%H%M%S)"
    local json_file="$ARTIFACT_DIR/cold_storage_signoff_${timestamp}.json"
    local txt_file="$ARTIFACT_DIR/cold_storage_signoff_${timestamp}.txt"

    emit_result "$passed" > "$json_file"

    {
        echo "Cold Storage Signoff — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Result: $([ "$passed" = "true" ] && echo "PASSED" || echo "FAILED")"
        echo "Evidence: $json_file"
        echo ""
        echo "Steps:"
        python3 -c '
import json, sys
data = json.loads(sys.argv[1])
for s in data.get("steps", []):
    mark = "PASS" if s["passed"] else "FAIL"
    print("  [{}] {}: {}".format(mark, s["name"], s["detail"]))
' "$(cat "$json_file")" 2>/dev/null || echo "  (could not parse steps)"
    } > "$txt_file"

    log "JSON evidence: $json_file" >&2
    log "Operator summary: $txt_file" >&2
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    log "Starting cold-storage signoff..."

    resolve_strict_local_defaults
    require_cold_storage_env

    init_artifact_dir

    # Export integration flags and all resolved vars for cargo.
    export INTEGRATION=1
    export BACKEND_LIVE_GATE=1
    export COLD_STORAGE_ENDPOINT
    export COLD_STORAGE_BUCKET
    export COLD_STORAGE_REGION
    export COLD_STORAGE_ACCESS_KEY
    export COLD_STORAGE_SECRET_KEY
    export AWS_EC2_METADATA_DISABLED="${AWS_EC2_METADATA_DISABLED:-true}"

    append_step "preflight" true "Cold-storage environment verified"

    # Delegate to the authoritative Rust integration test.
    local cargo_exit=0
    cd "$REPO_ROOT/infra"
    set +e
    cargo test -p api --test integration_cold_tier_test \
        cold_tier_full_lifecycle_s3_round_trip -- --test-threads=1
    cargo_exit=$?
    set -e

    local passed="false"
    if [ "$cargo_exit" -eq 0 ]; then
        passed="true"
        append_step "cargo_test" true "cold_tier_full_lifecycle_s3_round_trip passed"
    else
        append_step "cargo_test" false "cold_tier_full_lifecycle_s3_round_trip failed (exit $cargo_exit)"
    fi

    write_run_artifacts "$passed"

    exit "$cargo_exit"
}

main
