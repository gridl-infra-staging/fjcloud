#!/usr/bin/env bash
# deploy_status.sh — one-screen answer to "what's deployed?"
#
# Probes /version on the live API, compares dev_sha against `git rev-parse main`
# in the dev repo, and shows the gap. Replaces the prior workflow of
# round-tripping through SSM parameter lookups and status docs that may be
# stale. See `docs/runbooks/infra-deploy.md` for the broader deploy lifecycle.
#
# Topology note: two environments are probed — prod (https://api.flapjack.foo)
# and staging (https://api.staging.flapjack.foo). Each is one row in the ENVS
# array below. To add or change an environment, edit that array.
#
# Usage:  bash scripts/deploy_status.sh
#         bash scripts/deploy_status.sh --json            # machine-readable
#         bash scripts/deploy_status.sh --json --env prod # probe one env only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=scripts/lib/deployable_currency.sh
source "$REPO_ROOT/scripts/lib/deployable_currency.sh"

# One row per live environment. Format: "label|url". Keep the label short
# enough to fit the human-readable table column (under 12 chars).
ALL_ENVS=(
  "prod|https://api.flapjack.foo/version"
  "staging|https://api.staging.flapjack.foo/version"
)

JSON_MODE=0
ENV_FILTER=""
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --json)
      JSON_MODE=1
      shift
      ;;
    --env)
      if [[ -z "${2:-}" ]]; then
        echo "ERROR: --env requires a label (for example: prod)" >&2
        exit 2
      fi
      ENV_FILTER="$2"
      shift 2
      ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

ENVS=()
if [[ -n "$ENV_FILTER" ]]; then
  for entry in "${ALL_ENVS[@]}"; do
    label="${entry%%|*}"
    if [[ "$label" == "$ENV_FILTER" ]]; then
      ENVS+=("$entry")
    fi
  done
  if [[ "${#ENVS[@]}" -eq 0 ]]; then
    echo "ERROR: unknown env label: $ENV_FILTER" >&2
    exit 2
  fi
else
  ENVS=("${ALL_ENVS[@]}")
fi

# Probe /version. Returns the JSON body or the literal "PROBE_FAILED" if
# the endpoint is unreachable, non-200, or returns non-JSON. We treat every
# failure as "unknown state" rather than failing the script — the operator
# needs the partial info even when one env is down.
probe_version() {
  local url="$1"
  local body
  body=$(curl -fsS --max-time 5 "$url" 2>/dev/null || echo "PROBE_FAILED")
  if [[ "$body" == "PROBE_FAILED" ]]; then
    echo "PROBE_FAILED"
    return
  fi
  # Validate it's parseable JSON with at least dev_sha — defends against an
  # HTML error page being mistaken for a /version response. The endpoint
  # didn't exist before 2026-05-13; calling against an older binary yields
  # 404 (curl fails) or HTML, both of which fall through to PROBE_FAILED.
  if echo "$body" | jq -e '.dev_sha' >/dev/null 2>&1; then
    echo "$body"
  else
    echo "PROBE_FAILED"
  fi
}

extract_field() {
  local body="$1"
  local field="$2"
  if [[ "$body" == "PROBE_FAILED" ]]; then
    echo "unknown"
  else
    echo "$body" | jq -r ".$field // \"unknown\""
  fi
}

# Reference point for "is anything stale?" Prefer origin/main when set —
# accounts for the case where local `main` is itself behind. Fall back to
# local main or HEAD if the remote ref isn't available.
DEV_MAIN_SHA=$(git -C "$REPO_ROOT" rev-parse origin/main 2>/dev/null \
  || git -C "$REPO_ROOT" rev-parse main 2>/dev/null \
  || git -C "$REPO_ROOT" rev-parse HEAD)

# Gap computation: how many dev-repo commits is each env behind main?
# Returns "unknown" if the deployed dev_sha is not in dev-repo history
# (e.g. it's "local-dev" or pre-/version era, or a different repo's SHA).
commits_behind_main() {
  local deployed_sha="$1"
  if [[ "$deployed_sha" == "unknown" ]] || [[ "$deployed_sha" == "local-dev" ]]; then
    echo "unknown"
    return
  fi
  if ! git -C "$REPO_ROOT" cat-file -e "${deployed_sha}^{commit}" 2>/dev/null; then
    echo "unknown (SHA not in dev-repo history)"
    return
  fi
  git -C "$REPO_ROOT" rev-list --count "${deployed_sha}..${DEV_MAIN_SHA}" 2>/dev/null || echo "unknown"
}

read_deployable_currency_field() {
  local classifier_output="$1"
  local key="$2"
  local line

  while IFS= read -r line; do
    case "$line" in
      "$key="*)
        echo "${line#*=}"
        return
        ;;
    esac
  done <<< "$classifier_output"

  echo "unknown"
}

# Short SHA prefixes (12 chars) match `git log --oneline` convention so
# operators can paste them directly into git commands.
short() { echo "${1:0:12}"; }

# Collect rows into parallel arrays (bash 3 on macOS lacks assoc-array iteration).
LABELS=()
URLS=()
DEV_SHAS=()
MIRROR_SHAS=()
SYNCED_ATS=()
BUILD_TIMES=()
GAPS=()
DEPLOYABLE_DRIFTS=()
DOC_ONLY_AHEADS=()
for entry in "${ENVS[@]}"; do
  label="${entry%%|*}"
  url="${entry#*|}"
  body=$(probe_version "$url")
  # Pull dev_sha first so we can compute the gap before appending (macOS
  # bash 3 doesn't support negative array subscripts like ${arr[-1]}).
  dev_sha=$(extract_field "$body" "dev_sha")
  LABELS+=("$label")
  URLS+=("$url")
  DEV_SHAS+=("$dev_sha")
  MIRROR_SHAS+=("$(extract_field "$body" "mirror_sha")")
  SYNCED_ATS+=("$(extract_field "$body" "synced_at")")
  BUILD_TIMES+=("$(extract_field "$body" "build_time")")
  GAPS+=("$(commits_behind_main "$dev_sha")")
  currency_output="$(classify_deployable_currency "$REPO_ROOT" "$dev_sha" "$DEV_MAIN_SHA" 2>/dev/null || true)"
  DEPLOYABLE_DRIFTS+=("$(read_deployable_currency_field "$currency_output" "deployable_drift")")
  DOC_ONLY_AHEADS+=("$(read_deployable_currency_field "$currency_output" "doc_only_ahead")")
done

if [[ "$JSON_MODE" == "1" ]]; then
  # Build a JSON object whose keys are env labels. Stable order matches ENVS.
  envs_json="{}"
  for i in "${!LABELS[@]}"; do
    envs_json=$(jq -n \
      --argjson acc "$envs_json" \
      --arg label "${LABELS[$i]}" \
      --arg url "${URLS[$i]}" \
      --arg dev_sha "${DEV_SHAS[$i]}" \
      --arg mirror_sha "${MIRROR_SHAS[$i]}" \
      --arg synced_at "${SYNCED_ATS[$i]}" \
      --arg build_time "${BUILD_TIMES[$i]}" \
      --arg gap "${GAPS[$i]}" \
      --arg deployable_drift "${DEPLOYABLE_DRIFTS[$i]}" \
      --arg doc_only_ahead "${DOC_ONLY_AHEADS[$i]}" \
      '$acc + {($label): {url: $url, dev_sha: $dev_sha, mirror_sha: $mirror_sha, synced_at: $synced_at, build_time: $build_time, commits_behind_main: $gap, deployable_drift: $deployable_drift, doc_only_ahead: $doc_only_ahead}}')
  done
  jq -n --arg dev_main "$DEV_MAIN_SHA" --argjson envs "$envs_json" \
    '{dev_main_sha: $dev_main, envs: $envs}'
  exit 0
fi

echo "dev-repo main:   $(short "$DEV_MAIN_SHA")  ($DEV_MAIN_SHA)"
echo
printf "%-10s %-14s %-14s %-22s %-22s %s\n" "env" "dev_sha" "mirror_sha" "synced_at" "build_time" "behind_main"
printf "%-10s %-14s %-14s %-22s %-22s %s\n" "---" "-------" "----------" "---------" "----------" "-----------"
for i in "${!LABELS[@]}"; do
  printf "%-10s %-14s %-14s %-22s %-22s %s\n" \
    "${LABELS[$i]}" \
    "$(short "${DEV_SHAS[$i]}")" \
    "$(short "${MIRROR_SHAS[$i]}")" \
    "${SYNCED_ATS[$i]}" \
    "${BUILD_TIMES[$i]}" \
    "${GAPS[$i]}"
done
echo
echo "Probe URLs:"
for i in "${!LABELS[@]}"; do
  printf "  %-10s %s\n" "${LABELS[$i]}:" "${URLS[$i]}"
done
