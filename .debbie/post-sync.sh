#!/bin/bash
set -euo pipefail

run_scrai_strip() {
  local target="${1:?}"
  local repo_root=""
  local candidate=""
  local -a repo_candidates=()

  # Honor an explicit workspace pin before consulting ambient PATH tools.
  if [[ -n "${MATT_REPO_ROOT:-}" ]]; then
    repo_candidates+=("${MATT_REPO_ROOT}")
  fi
  repo_candidates+=("$HOME/repos/gridl/mike_dev")
  for candidate in "$HOME"/parallel_development/mike_dev/*/mike_dev; do
    [[ -d "$candidate" ]] || continue
    repo_candidates+=("$candidate")
  done

  for repo_root in "${repo_candidates[@]}"; do
    [[ -f "$repo_root/matt_root/matt/scrai/strip.py" ]] || continue
    if PYTHONPATH="$repo_root/matt_root${PYTHONPATH:+:$PYTHONPATH}" python3 -m matt scrai strip --help >/dev/null 2>&1; then
      PYTHONPATH="$repo_root/matt_root${PYTHONPATH:+:$PYTHONPATH}" python3 -m matt scrai strip "$target"
      return
    fi
  done

  if command -v matt >/dev/null 2>&1 && matt scrai strip --help >/dev/null 2>&1; then
    matt scrai strip "$target"
    return
  fi

  if command -v python3 >/dev/null 2>&1 && python3 -m matt scrai strip --help >/dev/null 2>&1; then
    python3 -m matt scrai strip "$target"
    return
  fi

  echo "error: unable to resolve matt scrai strip runtime; set MATT_REPO_ROOT to a mike_dev checkout that includes matt_root/matt/scrai/strip.py" >&2
  return 1
}

regenerate_openapi_artifact() {
  local target_root="${1:?}"

  (
    cd "$target_root/infra"
    UPDATE_OPENAPI_ARTIFACT=1 cargo test -p api --test platform \
      openapi_spec_matches_committed_artifact -- --nocapture
  )
}

run_post_strip_sync_commit_push() {
  local target_root="${1:?}"
  local dirty_state=""
  local current_branch=""
  local script_path=""
  local -a required_executable_scripts=(
    "ops/scripts/deploy.sh"
    "scripts/algolia_source_discovery_live_probe.sh"
    "scripts/engine_index_identity_live_probe.sh"
    "scripts/probe_flapjack_source_rebuild.sh"
    "scripts/seed_local.sh"
  )

  # Debbie's copy projection does not preserve executable bits. Restore the
  # modes required by the mirror's script-hygiene and deploy contracts before
  # committing.
  for script_path in "${required_executable_scripts[@]}"; do
    chmod +x "$target_root/$script_path"
  done

  dirty_state="$(git -C "$target_root" status --porcelain)"
  if [[ -z "$dirty_state" ]]; then
    return
  fi

  git -C "$target_root" add -A
  for script_path in "${required_executable_scripts[@]}"; do
    git -C "$target_root" update-index --chmod=+x "$script_path"
  done
  git -C "$target_root" commit -m "chore: debbie post-sync mirror update"
  current_branch="$(git -C "$target_root" rev-parse --abbrev-ref HEAD)"
  git -C "$target_root" push origin "$current_branch"
}

run_scrai_strip "${DEBBIE_TARGET_ROOT:?}"
regenerate_openapi_artifact "${DEBBIE_TARGET_ROOT:?}"
run_post_strip_sync_commit_push "${DEBBIE_TARGET_ROOT:?}"
