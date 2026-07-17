#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/ops/scripts/lib/deploy_validation.sh"

canonicalize_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

validate_repo_owned_output_dir() {
  local candidate="$1"
  local repo_root_real candidate_real

  repo_root_real="$(canonicalize_path "$REPO_ROOT")"
  candidate_real="$(canonicalize_path "$candidate")"

  case "$candidate_real" in
    "$repo_root_real" | "$repo_root_real"/*)
      return 0
      ;;
    *)
      echo "ERROR: evidence dir must stay within repo root: $REPO_ROOT" >&2
      return 1
      ;;
  esac
}

VERIFY_TIMEOUT_SECONDS=3600
VERIFY_EXPECTED_DEV_SHA=""
VERIFY_EVIDENCE_DIR=""
VERIFY_MIRROR_REPO="${VERIFY_E2E_GATE_MIRROR_REPO:-gridl-infra-staging/fjcloud}"

VERIFY_DEV_HEAD=""
VERIFY_MIRROR_HEAD=""
VERIFY_SYNCED_DEV_SHA=""
VERIFY_RUN_ID=""
VERIFY_RUN_URL=""
VERIFY_JOB_CONCLUSIONS=""
VERIFY_WALL_SECONDS="0"

print_usage() {
  cat <<'USAGE'
Usage:
  verify_e2e_deployed_gate.sh [--timeout-seconds N] [--evidence-dir PATH] [--expected-dev-sha SHA]
  verify_e2e_deployed_gate.sh --help

Phase B post-merge verifier:
  - Run after Phase B (or Lane 2) merges to main.
  - Verifies deploy-staging and e2e-deployed for the mirror main SHA.
  - Required before Phase C spawn.

Flags:
  --timeout-seconds N   Maximum wall clock budget in seconds (default: 3600)
  --evidence-dir PATH   Output directory (default: docs/live-state/lane_evidence/lane_b_post_merge_gate_<UTC-TS>/)
  --expected-dev-sha S  Expected dev SHA (default: git fetch origin && git rev-parse origin/main)
USAGE
}

utc_timestamp_compact() {
  date -u +%Y%m%dT%H%M%SZ
}

ms_now() {
  python3 -c 'import time; print(int(time.time()*1000))'
}

default_evidence_dir() {
  printf '%s/docs/live-state/lane_evidence/lane_b_post_merge_gate_%s\n' "$REPO_ROOT" "$(utc_timestamp_compact)"
}

resolve_staging_mirror_root_from_debbie_toml() {
  local debbie_toml="$REPO_ROOT/.debbie.toml"
  if [ ! -f "$debbie_toml" ]; then
    return 1
  fi

  awk '
    /^\[repos\.staging\][[:space:]]*$/ { in_section=1; next }
    /^\[[^]]+\][[:space:]]*$/ { if (in_section) exit; next }
    in_section && /^[[:space:]]*path[[:space:]]*=/ {
      line=$0
      gsub(/^[[:space:]]*path[[:space:]]*=[[:space:]]*"/, "", line)
      gsub(/"[[:space:]]*$/, "", line)
      print line
      exit
    }
  ' "$debbie_toml"
}

read_synced_dev_sha_from_local_manifest() {
  local staging_root
  staging_root="$(resolve_staging_mirror_root_from_debbie_toml 2>/dev/null || true)"
  if [ -z "$staging_root" ]; then
    return 1
  fi

  local manifest_file="$staging_root/.debbie/sync_manifest.json"
  if [ ! -f "$manifest_file" ]; then
    return 1
  fi

  jq -r '.dev_sha // empty' "$manifest_file" 2>/dev/null || true
}

sleep_with_budget() {
  local start_ms="$1"
  local timeout_seconds="$2"
  local preferred_sleep="$3"
  local now_ms elapsed_seconds remaining_seconds sleep_seconds

  now_ms="$(ms_now)"
  elapsed_seconds=$(( (now_ms - start_ms) / 1000 ))
  remaining_seconds=$(( timeout_seconds - elapsed_seconds ))
  if [ "$remaining_seconds" -le 0 ]; then
    return 1
  fi

  sleep_seconds="$preferred_sleep"
  if [ "$sleep_seconds" -gt "$remaining_seconds" ]; then
    sleep_seconds="$remaining_seconds"
  fi
  if [ "$sleep_seconds" -le 0 ]; then
    sleep_seconds=1
  fi

  sleep "$sleep_seconds"
}

record_wall_seconds() {
  local start_ms="$1"
  local now_ms
  now_ms="$(ms_now)"
  VERIFY_WALL_SECONDS="$(( (now_ms - start_ms) / 1000 ))"
}

ensure_summary_exclusive() {
  local evidence_dir="$1"
  if [ -e "$evidence_dir/SUMMARY.PASS.md" ] && [ -e "$evidence_dir/SUMMARY.FAIL.md" ]; then
    echo "ERROR: invalid evidence state: both SUMMARY.PASS.md and SUMMARY.FAIL.md exist in $evidence_dir" >&2
    return 1
  fi
}

write_summary() {
  local verdict="$1"
  local reason="$2"
  local detail="$3"
  local evidence_dir="$4"
  local summary_file opposite_file

  mkdir -p "$evidence_dir"
  if [ "$verdict" = "pass" ]; then
    summary_file="$evidence_dir/SUMMARY.PASS.md"
    opposite_file="$evidence_dir/SUMMARY.FAIL.md"
  else
    summary_file="$evidence_dir/SUMMARY.FAIL.md"
    opposite_file="$evidence_dir/SUMMARY.PASS.md"
  fi

  rm -f "$opposite_file"

  cat > "$summary_file" <<EOF_SUMMARY
reason: $reason
detail: $detail
DEV_HEAD: ${VERIFY_DEV_HEAD:-}
MIRROR_HEAD: ${VERIFY_MIRROR_HEAD:-}
SYNCED_DEV_SHA: ${VERIFY_SYNCED_DEV_SHA:-}
RUN_ID: ${VERIFY_RUN_ID:-}
RUN_URL: ${VERIFY_RUN_URL:-}
job_conclusions: ${VERIFY_JOB_CONCLUSIONS:-none}
wall_seconds: ${VERIFY_WALL_SECONDS}
verdict: $verdict
EOF_SUMMARY

  ensure_summary_exclusive "$evidence_dir"
}

is_hex_sha40() {
  local sha="$1"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
}

resolve_dev_head() {
  if [ -n "$VERIFY_EXPECTED_DEV_SHA" ]; then
    printf '%s\n' "$VERIFY_EXPECTED_DEV_SHA"
    return 0
  fi
  git fetch origin >/dev/null 2>&1 && git rev-parse origin/main
}

extract_job_conclusion() {
  local jobs_json="$1"
  local job_name="$2"
  jq -r --arg job_name "$job_name" '.jobs[]? | select(.name == $job_name) | (.conclusion // "in_progress")' <<< "$jobs_json" | tail -n 1
}

extract_job_conclusion_lines() {
  local jobs_json="$1"
  jq -r '.jobs[]? | "\(.name)=\(.conclusion // "in_progress")"' <<< "$jobs_json"
}

attempt_ci_verdict_for_current_mirror_head() {
  local evidence_dir="$1"
  local start_ms="$2"

  VERIFY_MIRROR_HEAD="$({ github_branch_head_sha "$VERIFY_MIRROR_REPO" "main" 2>/dev/null; } || true)"
  if ! is_hex_sha40 "$VERIFY_MIRROR_HEAD"; then
    return 2
  fi

  local run_json
  run_json="$({ github_latest_ci_run_for_sha "$VERIFY_MIRROR_REPO" "$VERIFY_MIRROR_HEAD" 2>/dev/null; } || true)"
  VERIFY_RUN_ID="$(jq -r '.[0].databaseId // empty' <<< "$run_json" 2>/dev/null || true)"
  VERIFY_RUN_URL="$(jq -r '.[0].url // empty' <<< "$run_json" 2>/dev/null || true)"
  if [ -z "$VERIFY_RUN_ID" ]; then
    return 2
  fi

  local jobs_json
  jobs_json="$({ github_ci_run_jobs_json "$VERIFY_MIRROR_REPO" "$VERIFY_RUN_ID" 2>/dev/null; } || true)"
  VERIFY_JOB_CONCLUSIONS="$(extract_job_conclusion_lines "$jobs_json" 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)"
  if [ -z "$VERIFY_JOB_CONCLUSIONS" ]; then
    VERIFY_JOB_CONCLUSIONS="none"
  fi

  local deploy_conclusion e2e_conclusion
  deploy_conclusion="$(extract_job_conclusion "$jobs_json" "deploy-staging" 2>/dev/null || true)"
  e2e_conclusion="$(extract_job_conclusion "$jobs_json" "e2e-deployed" 2>/dev/null || true)"

  if [ -z "$deploy_conclusion" ]; then
    record_wall_seconds "$start_ms"
    write_summary "fail" "job_absent_deploy_staging" "deploy-staging job absent from CI run" "$evidence_dir"
    return 1
  fi

  if [ -z "$e2e_conclusion" ]; then
    record_wall_seconds "$start_ms"
    write_summary "fail" "job_absent_e2e_deployed" "e2e-deployed job missing from CI run" "$evidence_dir"
    return 1
  fi

  if [ "$deploy_conclusion" = "in_progress" ] || [ "$deploy_conclusion" = "null" ] || [ "$e2e_conclusion" = "in_progress" ] || [ "$e2e_conclusion" = "null" ]; then
    return 2
  fi

  if [ "$deploy_conclusion" != "success" ]; then
    record_wall_seconds "$start_ms"
    write_summary "fail" "job_failure_deploy_staging" "deploy-staging job not success: $deploy_conclusion" "$evidence_dir"
    return 1
  fi

  if [ "$e2e_conclusion" != "success" ]; then
    record_wall_seconds "$start_ms"
    write_summary "fail" "job_failure_e2e_deployed" "e2e-deployed job not success: $e2e_conclusion" "$evidence_dir"
    return 1
  fi

  record_wall_seconds "$start_ms"
  write_summary "pass" "all_checks_passed" "deploy-staging and e2e-deployed are both success" "$evidence_dir"
  return 0
}

run_gate() {
  local start_ms
  start_ms="$(ms_now)"

  VERIFY_DEV_HEAD="$(resolve_dev_head)"
  if ! is_hex_sha40 "$VERIFY_DEV_HEAD"; then
    echo "ERROR: expected dev SHA must be a 40-character lowercase hexadecimal commit SHA" >&2
    return 2
  fi

  local evidence_dir="$VERIFY_EVIDENCE_DIR"
  if [ -z "$evidence_dir" ]; then
    evidence_dir="$(default_evidence_dir)"
  fi
  validate_repo_owned_output_dir "$evidence_dir" || return 2
  mkdir -p "$evidence_dir"

  while true; do
    local now_ms elapsed_seconds
    now_ms="$(ms_now)"
    elapsed_seconds=$(( (now_ms - start_ms) / 1000 ))
    if [ "$elapsed_seconds" -ge "$VERIFY_TIMEOUT_SECONDS" ]; then
      record_wall_seconds "$start_ms"
      write_summary "fail" "manifest_timeout" "expected DEV_HEAD did not appear in mirror sync_manifest within budget" "$evidence_dir"
      echo "FAIL: expected DEV_HEAD did not appear in mirror sync_manifest within budget" >&2
      return 1
    fi

    VERIFY_SYNCED_DEV_SHA="$(read_synced_dev_sha_from_local_manifest 2>/dev/null || true)"
    if [ -z "$VERIFY_SYNCED_DEV_SHA" ]; then
      local manifest_json
      manifest_json="$({ github_file_content_decoded "$VERIFY_MIRROR_REPO" ".debbie/sync_manifest.json" 2>/dev/null; } || true)"
      VERIFY_SYNCED_DEV_SHA="$(jq -r '.dev_sha // empty' <<< "$manifest_json" 2>/dev/null || true)"
    fi

    if [ "$VERIFY_SYNCED_DEV_SHA" != "$VERIFY_DEV_HEAD" ]; then
      sleep_with_budget "$start_ms" "$VERIFY_TIMEOUT_SECONDS" 30 || true
      continue
    fi

    if attempt_ci_verdict_for_current_mirror_head "$evidence_dir" "$start_ms"; then
      echo "PASS: deploy-staging and e2e-deployed are both success"
      return 0
    fi

    if [ -f "$evidence_dir/SUMMARY.FAIL.md" ]; then
      local failure_reason
      failure_reason="$(sed -n 's/^reason:[[:space:]]*//p' "$evidence_dir/SUMMARY.FAIL.md" | head -n 1)"
      echo "FAIL: ${failure_reason:-mirror CI verdict failure}" >&2
      return 1
    fi

    sleep_with_budget "$start_ms" "$VERIFY_TIMEOUT_SECONDS" 30 || true
  done
}

main() {
  local arg
  while [ "$#" -gt 0 ]; do
    arg="$1"
    case "$arg" in
      --help)
        print_usage
        return 0
        ;;
      --timeout-seconds)
        VERIFY_TIMEOUT_SECONDS="${2:-}"
        shift 2
        ;;
      --timeout-seconds=*)
        VERIFY_TIMEOUT_SECONDS="${arg#--timeout-seconds=}"
        shift
        ;;
      --evidence-dir)
        VERIFY_EVIDENCE_DIR="${2:-}"
        shift 2
        ;;
      --evidence-dir=*)
        VERIFY_EVIDENCE_DIR="${arg#--evidence-dir=}"
        shift
        ;;
      --expected-dev-sha)
        VERIFY_EXPECTED_DEV_SHA="${2:-}"
        shift 2
        ;;
      --expected-dev-sha=*)
        VERIFY_EXPECTED_DEV_SHA="${arg#--expected-dev-sha=}"
        shift
        ;;
      *)
        echo "ERROR: unknown argument '$arg'" >&2
        print_usage >&2
        return 2
        ;;
    esac
  done

  if ! [[ "$VERIFY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$VERIFY_TIMEOUT_SECONDS" -le 0 ]; then
    echo "ERROR: --timeout-seconds must be a positive integer" >&2
    return 2
  fi

  if [ -n "$VERIFY_EXPECTED_DEV_SHA" ] && ! is_hex_sha40 "$VERIFY_EXPECTED_DEV_SHA"; then
    echo "ERROR: --expected-dev-sha must be a 40-character lowercase hexadecimal commit SHA" >&2
    return 2
  fi

  run_gate
}

if [[ "${__VERIFY_E2E_DEPLOYED_GATE_SOURCED:-0}" != "1" ]]; then
  main "$@"
fi
