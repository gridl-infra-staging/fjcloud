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
#         bash scripts/deploy_status.sh --json    # machine-readable

set -euo pipefail

# One row per live environment. Format: "label|url". Keep the label short
# enough to fit the human-readable table column (under 12 chars).
ENVS=(
  "prod|https://api.flapjack.foo/version"
  "staging|https://api.staging.flapjack.foo/version"
)

JSON_MODE=0
if [[ "${1:-}" == "--json" ]]; then
  JSON_MODE=1
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
DEV_MAIN_SHA=$(git rev-parse origin/main 2>/dev/null \
  || git rev-parse main 2>/dev/null \
  || git rev-parse HEAD)

# Gap computation: how many dev-repo commits is each env behind main?
# Returns "unknown" if the deployed dev_sha is not in dev-repo history
# (e.g. it's "local-dev" or pre-/version era, or a different repo's SHA).
commits_behind_main() {
  local deployed_sha="$1"
  if [[ "$deployed_sha" == "unknown" ]] || [[ "$deployed_sha" == "local-dev" ]]; then
    echo "unknown"
    return
  fi
  if ! git cat-file -e "${deployed_sha}^{commit}" 2>/dev/null; then
    echo "unknown (SHA not in dev-repo history)"
    return
  fi
  git rev-list --count "${deployed_sha}..${DEV_MAIN_SHA}" 2>/dev/null || echo "unknown"
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
      '$acc + {($label): {url: $url, dev_sha: $dev_sha, mirror_sha: $mirror_sha, synced_at: $synced_at, build_time: $build_time, commits_behind_main: $gap}}')
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
