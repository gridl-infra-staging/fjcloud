#!/usr/bin/env bash
# Stage 1 preflight bootstrap: probe live state, discover latest audit summaries,
# and persist deterministic state for later W3 triage stages.

set -euo pipefail

STATE_FILE=/tmp/w3_triage_state.env

bash scripts/probe_live_state.sh

PARITY_SUMMARY=$(ls -1d docs/audits/feature-parity/*_fjcloud_vs_engine_dashboard/SUMMARY.md 2>/dev/null | sort -r | head -1 || true)
COVERAGE_SUMMARY=$(ls -1d docs/audits/test-coverage/*_console_index_tabs/SUMMARY.md 2>/dev/null | sort -r | head -1 || true)

if [[ -z "$PARITY_SUMMARY" || ! -f "$PARITY_SUMMARY" ]]; then
  echo "MISSING: docs/audits/feature-parity/*_fjcloud_vs_engine_dashboard/SUMMARY.md — re-run W2.1 first" >&2
  exit 1
fi

if [[ -z "$COVERAGE_SUMMARY" || ! -f "$COVERAGE_SUMMARY" ]]; then
  echo "MISSING: docs/audits/test-coverage/*_console_index_tabs/SUMMARY.md — re-run W2.2 first" >&2
  exit 1
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
TRIAGE_DIR="docs/audits/triage/$TS"

umask 077
tmp_state=$(mktemp "${STATE_FILE}.XXXXXX")
trap 'rm -f "$tmp_state"' EXIT

{
  printf 'export PARITY_SUMMARY=%q\n' "$PARITY_SUMMARY"
  printf 'export COVERAGE_SUMMARY=%q\n' "$COVERAGE_SUMMARY"
  printf 'export TS=%q\n' "$TS"
  printf 'export TRIAGE_DIR=%q\n' "$TRIAGE_DIR"
} > "$tmp_state"

mv -f "$tmp_state" "$STATE_FILE"
trap - EXIT

printf 'PARITY_SUMMARY=%s\n' "$PARITY_SUMMARY"
printf 'COVERAGE_SUMMARY=%s\n' "$COVERAGE_SUMMARY"
printf 'TS=%s\n' "$TS"
printf 'TRIAGE_DIR=%s\n' "$TRIAGE_DIR"
printf 'Stage state written to %s\n' "$STATE_FILE"
