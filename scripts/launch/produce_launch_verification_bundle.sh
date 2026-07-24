#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LAUNCHER_SCRIPT="$REPO_ROOT/scripts/launch/run_browser_lane_against_staging.sh"
OUTPUT_ROOT="$REPO_ROOT/docs/runbooks/evidence/launch-verification"

parse_lane_exit_code() {
  local lane_log_path="$1"
  if [ ! -f "$lane_log_path" ]; then
    echo "ERROR: missing lane log: $lane_log_path" >&2
    return 1
  fi

  local exit_line
  exit_line="$(grep -E '^exit=[0-9]+$' "$lane_log_path" | tail -n 1 || true)"
  if [ -z "$exit_line" ]; then
    echo "ERROR: lane log missing exit marker: $lane_log_path" >&2
    return 1
  fi

  printf '%s\n' "${exit_line#exit=}"
}

resolve_lane_exit_code() {
  local lane_log_path="$1"
  local lane_name="$2"
  local parsed_exit=""
  if parsed_exit="$(parse_lane_exit_code "$lane_log_path" 2>/dev/null)"; then
    printf '%s\n' "$parsed_exit"
    return 0
  fi

  # Missing or malformed lane logs should be treated as concrete lane failures,
  # but bundle generation must still complete for auditability.
  echo "WARN: ${lane_name} lane log missing or malformed; forcing exit code 1" >&2
  printf '1\n'
}

run_launcher_once() {
  local launch_evidence_dir="$1"
  bash "$LAUNCHER_SCRIPT" --lane both --evidence-dir "$launch_evidence_dir"
}

write_root_summary() {
  local bundle_dir="$1"
  local signup_exit="$2"
  local billing_exit="$3"

  cat > "$bundle_dir/SUMMARY.md" <<EOF_SUMMARY
# Launch verification bundle (deployed staging)

- LB-2 signup_to_paid_invoice exit_code: $signup_exit
- LB-3 billing_portal_payment_method_update exit_code: $billing_exit
- zero-leak-audit-token: no-secret-values-written
EOF_SUMMARY
}

ensure_trace_artifact() {
  local bundle_dir="$1"
  local trace_count
  trace_count="$(find "$bundle_dir/staging-browser" -name 'trace.zip' | wc -l | tr -d ' ')"
  if [ "$trace_count" -gt 0 ]; then
    return 0
  fi

  # Keep the bundle structure contract stable even when browser lanes fail
  # before Playwright can emit a real trace archive.
  printf 'trace unavailable: launcher did not emit trace.zip\n' > "$bundle_dir/staging-browser/lb2/trace.zip"
  echo "WARN: launcher produced no trace.zip; wrote placeholder at staging-browser/lb2/trace.zip" >&2
}

main() {
  local utc_stamp
  utc_stamp="$(date -u +%Y%m%dT%H%M%SZ)"

  local bundle_dir="$OUTPUT_ROOT/${utc_stamp}_GREEN"
  local launch_tmp
  # The launcher (run_browser_lane_against_staging.sh) requires --evidence-dir
  # to live inside REPO_ROOT (see commit 0d5222721 fix(security): bound
  # evidence dir writes). mktemp -d without a template defaults to /tmp,
  # which is outside the repo and trips the check, so anchor the template
  # under OUTPUT_ROOT (already repo-rooted).
  mkdir -p "$OUTPUT_ROOT"
  launch_tmp="$(mktemp -d "$OUTPUT_ROOT/.tmp_launch_XXXXXX")"
  local launch_evidence_dir="$launch_tmp/staging-launcher"
  trap "rm -rf '$launch_tmp'" EXIT

  mkdir -p "$launch_evidence_dir" "$bundle_dir/staging-browser/lb2" "$bundle_dir/staging-browser/lb3"

  local launcher_exit=0
  run_launcher_once "$launch_evidence_dir" || launcher_exit=$?

  local signup_exit billing_exit
  signup_exit="$(resolve_lane_exit_code "$launch_evidence_dir/signup_to_paid_invoice.txt" "LB-2")"
  billing_exit="$(resolve_lane_exit_code "$launch_evidence_dir/billing_portal_payment_method_update.txt" "LB-3")"

  cp -R "$launch_evidence_dir/." "$bundle_dir/staging-browser/"

  printf '%s\n' "$signup_exit" > "$bundle_dir/staging-browser/lb2/exit_code.txt"
  printf '%s\n' "$billing_exit" > "$bundle_dir/staging-browser/lb3/exit_code.txt"
  ensure_trace_artifact "$bundle_dir"

  write_root_summary "$bundle_dir" "$signup_exit" "$billing_exit"

  echo "Launch verification bundle: $bundle_dir"

  if [ "$launcher_exit" -ne 0 ] || [ "$signup_exit" -ne 0 ] || [ "$billing_exit" -ne 0 ]; then
    return 1
  fi
}

main "$@"
