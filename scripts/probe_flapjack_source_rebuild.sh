#!/usr/bin/env bash
# Probe that a selected Flapjack checkout mutation forces a helper-owned rebuild
# and changes behavior served by the rebuilt binary without a version bump.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/flapjack_binary.sh
source "$SCRIPT_DIR/lib/flapjack_binary.sh"

log() { echo "[probe-flapjack-source-rebuild] $*"; }
die() { echo "[probe-flapjack-source-rebuild] ERROR: $*" >&2; exit 1; }

FLAPJACK_DEV_DIR="$(resolve_default_flapjack_dev_dir)"
SOURCE_ROOT="$(flapjack_source_root "$FLAPJACK_DEV_DIR" || true)"
[ -n "$SOURCE_ROOT" ] || die "FLAPJACK_DEV_DIR does not point at a source-backed Flapjack checkout: $FLAPJACK_DEV_DIR"

PROBE_SOURCE_FILE="$SOURCE_ROOT/flapjack-http/src/handlers/health.rs"
[ -f "$PROBE_SOURCE_FILE" ] || die "probe source file not found: $PROBE_SOURCE_FILE"

BACKUP_FILE="$(mktemp)"
MUTATED_FILE="$(mktemp)"
SERVER_LOG="$(mktemp)"
PROBE_DATA_DIR="$(mktemp -d)"
SERVER_PID=""
cp "$PROBE_SOURCE_FILE" "$BACKUP_FILE"
cleanup() {
    if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    cp "$BACKUP_FILE" "$PROBE_SOURCE_FILE" 2>/dev/null || true
    rm -f "$BACKUP_FILE" "$MUTATED_FILE" "$SERVER_LOG"
    rm -rf "$PROBE_DATA_DIR"
}
trap cleanup EXIT

BEFORE_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR")"
BEFORE_RECEIPT="$(flapjack_receipt_path_for_source "$SOURCE_ROOT")"
BEFORE_SHA="$(flapjack_binary_sha256 "$BEFORE_BIN")"
BEFORE_DIGEST="$(flapjack_receipt_value "$BEFORE_RECEIPT" "source_digest" || true)"
PROBE_STATUS="fjcloud-source-rebuild-$(date -u +%Y%m%dT%H%M%SZ)-$$"

awk -v probe_status="$PROBE_STATUS" '
    !replaced && sub(/"status": "ok"/, "\"status\": \"" probe_status "\"") { replaced = 1 }
    { print }
    END { if (!replaced) exit 1 }
' "$PROBE_SOURCE_FILE" > "$MUTATED_FILE" \
    || die "could not install the temporary served-behavior mutation"
mv "$MUTATED_FILE" "$PROBE_SOURCE_FILE"

AFTER_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR")"
AFTER_RECEIPT="$(flapjack_receipt_path_for_source "$SOURCE_ROOT")"
AFTER_SHA="$(flapjack_binary_sha256 "$AFTER_BIN")"
AFTER_DIGEST="$(flapjack_receipt_value "$AFTER_RECEIPT" "source_digest" || true)"

[ "$AFTER_BIN" = "$BEFORE_BIN" ] || die "resolver changed binary path unexpectedly: before=$BEFORE_BIN after=$AFTER_BIN"
[ -n "$AFTER_DIGEST" ] || die "resolver did not write source_digest receipt evidence"
[ "$AFTER_DIGEST" != "$BEFORE_DIGEST" ] || die "source mutation did not update the helper receipt digest"

NO_COLOR=1 "$AFTER_BIN" --auto-port --no-auth --data-dir "$PROBE_DATA_DIR" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
PROBE_URL=""
HEALTH_JSON=""
for _ in $(seq 1 80); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        die "rebuilt Flapjack exited before serving /health; log=$SERVER_LOG"
    fi
    PROBE_URL="$(grep -Eo 'http://127\.0\.0\.1:[0-9]+' "$SERVER_LOG" | head -1 || true)"
    if [ -n "$PROBE_URL" ]; then
        HEALTH_JSON="$(curl -fsS "$PROBE_URL/health" 2>/dev/null || true)"
        [ -n "$HEALTH_JSON" ] && break
    fi
    sleep 0.25
done
[ -n "$HEALTH_JSON" ] || die "rebuilt Flapjack did not serve /health; log=$SERVER_LOG"
STATUS_MATCH_COUNT="$(printf '%s' "$HEALTH_JSON" | awk -v marker="$PROBE_STATUS" '
    { count += gsub(marker, "") }
    END { print count + 0 }
')"
[ "$STATUS_MATCH_COUNT" = "1" ] \
    || die "rebuilt /health did not serve the exact probe status once: count=$STATUS_MATCH_COUNT body=$HEALTH_JSON"
printf '%s' "$HEALTH_JSON" | grep -Eq '"version":"1\.0\.10"' \
    || die "probe changed the pinned runtime version unexpectedly: body=$HEALTH_JSON"

kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

cp "$BACKUP_FILE" "$PROBE_SOURCE_FILE"
RESTORED_BIN="$(find_flapjack_binary "$FLAPJACK_DEV_DIR")"
RESTORED_RECEIPT="$(flapjack_receipt_path_for_source "$SOURCE_ROOT")"
RESTORED_DIGEST="$(flapjack_receipt_value "$RESTORED_RECEIPT" "source_digest" || true)"
[ "$RESTORED_BIN" = "$BEFORE_BIN" ] || die "restore rebuild changed binary path unexpectedly: before=$BEFORE_BIN restored=$RESTORED_BIN"
[ "$RESTORED_DIGEST" = "$BEFORE_DIGEST" ] || die "restore rebuild did not return receipt digest to the pre-probe source state"

log "source_root=$SOURCE_ROOT"
log "binary=$AFTER_BIN"
log "receipt=$AFTER_RECEIPT"
log "binary_sha_before=$BEFORE_SHA"
log "binary_sha_after=$AFTER_SHA"
log "source_digest_before=${BEFORE_DIGEST:-none}"
log "source_digest_after=$AFTER_DIGEST"
log "source_digest_restored=$RESTORED_DIGEST"
log "served_url=$PROBE_URL/health"
log "served_probe_status=$PROBE_STATUS"
log "served_probe_status_exact_count=$STATUS_MATCH_COUNT"
log "PASS: selected checkout mutation forced a shared-helper rebuild and changed served behavior without a version bump"
