#!/usr/bin/env bash
# seed-documents.sh — Deterministically insert N documents into a test index.
# Usage: seed-documents.sh <tier> [api_base]
#   tier: 1k | 10k | 100k
#   api_base: defaults to http://localhost:3099

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/metrics.sh
source "$SCRIPT_DIR/lib/metrics.sh"
# shellcheck source=../lib/deterministic_batch_payload.sh
source "$SCRIPT_DIR/../lib/deterministic_batch_payload.sh"

TIER="${1:?Usage: seed-documents.sh <1k|10k|100k>}"
API_BASE="${2:-http://localhost:${API_PORT}}"
ADMIN_KEY="${ADMIN_KEY:-integration-test-admin-key}"
FLAPJACK_BASE="${FLAPJACK_BASE:-http://localhost:${FLAPJACK_PORT:-7799}}"

# Map tier to document count
case "$TIER" in
    1k)   DOC_COUNT=1000 ;;
    10k)  DOC_COUNT=10000 ;;
    100k) DOC_COUNT=100000 ;;
    *)    rdie "Invalid tier: $TIER (expected 1k, 10k, or 100k)" ;;
esac

SEED=42  # Fixed seed for reproducibility
INDEX_NAME="reliability_${TIER}"
BATCH_SIZE=100

rlog "Seeding $DOC_COUNT documents into index '$INDEX_NAME' (seed=$SEED)"

# Create test index via admin API (idempotent)
rlog "Ensuring index '$INDEX_NAME' exists..."
curl_flapjack POST "${FLAPJACK_BASE}/1/indexes" \
    -H "Content-Type: application/json" \
    -d "{\"uid\": \"${INDEX_NAME}\"}" >/dev/null 2>&1 || true

# Generate and insert documents in batches
rlog "Inserting $DOC_COUNT documents in batches of $BATCH_SIZE..."
inserted=0
batch_num=0

while [ "$inserted" -lt "$DOC_COUNT" ]; do
    remaining=$((DOC_COUNT - inserted))
    current_batch=$((remaining < BATCH_SIZE ? remaining : BATCH_SIZE))

    # Generate deterministic batch using seed + offset.
    batch_json="$(deterministic_batch_payload "$SEED" "$inserted" "$current_batch")"

    # POST batch to flapjack using the current authenticated batch contract.
    curl_flapjack POST "${FLAPJACK_BASE}/1/indexes/${INDEX_NAME}/batch" \
        -H "Content-Type: application/json" \
        -d "$batch_json" >/dev/null 2>&1 \
        || rdie "Failed to insert batch at offset $inserted"

    inserted=$((inserted + current_batch))
    batch_num=$((batch_num + 1))

    # Progress every 10 batches
    if [ $((batch_num % 10)) -eq 0 ]; then
        rlog "  Progress: $inserted / $DOC_COUNT documents"
    fi
done

rlog "Seeding complete: $inserted documents in index '$INDEX_NAME'"
echo "$INDEX_NAME"
