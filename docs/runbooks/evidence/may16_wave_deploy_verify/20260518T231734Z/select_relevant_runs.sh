#!/usr/bin/env bash
set -euo pipefail
canon="$1"
live="$2"
json="$3"
mirror_repo="$4"
jq -r '.[].databaseId' "$json" | while read -r run_id; do
  head_sha="$(jq -r ".[] | select(.databaseId==$run_id) | .headSha" "$json")"
  ok=0
  if [ "$head_sha" = "$live" ]; then
    ok=1
  else
    if git -C "$mirror_repo" cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
      if git -C "$mirror_repo" merge-base --is-ancestor "$canon" "$head_sha" 2>/dev/null; then
        ok=1
      fi
    fi
  fi
  if [ "$ok" -eq 1 ]; then
    echo "$run_id"
  fi
done
