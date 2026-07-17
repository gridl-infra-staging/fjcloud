#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "Usage: redact_playwright_json.sh <input-json> <output-json>" >&2
}

if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

INPUT_JSON="$1"
OUTPUT_JSON="$2"

if ! command -v jq >/dev/null 2>&1; then
    echo "ERROR: jq is required" >&2
    exit 1
fi

if [ ! -f "$INPUT_JSON" ]; then
    echo "ERROR: input JSON not found: $INPUT_JSON" >&2
    exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT_JSON")"
if [ ! -d "$OUTPUT_DIR" ]; then
    echo "ERROR: output directory not found: $OUTPUT_DIR" >&2
    exit 1
fi

TMP_OUTPUT="$(mktemp "${TMPDIR:-/tmp}/redact_playwright_json.XXXXXX")"
cleanup() {
    rm -f "$TMP_OUTPUT"
}
trap cleanup EXIT

if ! jq 'del(.config.webServer.env)' "$INPUT_JSON" > "$TMP_OUTPUT"; then
    rm -f "$OUTPUT_JSON"
    exit 1
fi

mv "$TMP_OUTPUT" "$OUTPUT_JSON"
trap - EXIT
