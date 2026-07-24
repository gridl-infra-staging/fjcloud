#!/usr/bin/env bash
# Cleanup helpers for Stage 2 private Terraform plan worktrees.
#
# Source this file from the bounded live-plan shell before `terraform init`.

stage2_canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

stage2_path_is_under_root() {
  local root="$1"
  local path="$2"
  case "$path" in
    "$root" | "$root"/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

stage2_private_root_is_safe() {
  local root="$1"
  local root_name

  root_name="$(basename "$root")"
  [[ "$root_name" == fjcloud_stage2_* ]]
}

stage2_cleanup_private_artifacts() {
  local repo_root="$1"
  local private_plan="$2"
  local plan_json="$3"
  local worktree="$4"
  local repo_root_real private_plan_real plan_json_real worktree_real private_root plan_dir
  local status=0

  repo_root_real="$(stage2_canonical_path "$repo_root")" || return 1
  private_plan_real="$(stage2_canonical_path "$private_plan")" || return 1
  plan_json_real="$(stage2_canonical_path "$plan_json")" || return 1
  worktree_real="$(stage2_canonical_path "$worktree")" || return 1
  private_root="$(dirname "$worktree_real")"
  plan_dir="$(dirname "$private_plan_real")"

  if ! stage2_private_root_is_safe "$private_root"; then
    return 2
  fi
  if ! stage2_path_is_under_root "$private_root" "$private_plan_real"; then
    return 2
  fi
  if ! stage2_path_is_under_root "$private_root" "$plan_json_real"; then
    return 2
  fi
  if [[ "$(basename "$worktree_real")" != "source" ]]; then
    return 2
  fi

  rm -f "$private_plan_real" "$plan_json_real" || status=1

  if git -C "$repo_root_real" worktree list --porcelain 2>/dev/null \
      | rg -Fqx "worktree ${worktree_real}"; then
    git -C "$repo_root_real" worktree remove --force "$worktree_real" >/dev/null 2>&1 || status=1
  elif [[ -e "$worktree_real" ]]; then
    rm -rf "$worktree_real" || status=1
  fi

  rmdir "$plan_dir" >/dev/null 2>&1 || true
  rmdir "$private_root" >/dev/null 2>&1 || true

  return "$status"
}

stage2_cleanup_on_exit() {
  local original_status="${1:-0}"
  local cleanup_status=0

  stage2_cleanup_private_artifacts \
    "$STAGE2_CLEANUP_REPO_ROOT" \
    "$STAGE2_CLEANUP_PRIVATE_PLAN" \
    "$STAGE2_CLEANUP_PLAN_JSON" \
    "$STAGE2_CLEANUP_WORKTREE" || cleanup_status=$?

  if [[ "$original_status" -ne 0 ]]; then
    exit "$original_status"
  fi
  exit "$cleanup_status"
}

stage2_install_plan_cleanup() {
  local repo_root="$1"
  local private_plan="$2"
  local plan_json="$3"
  local worktree="$4"

  STAGE2_CLEANUP_REPO_ROOT="$(stage2_canonical_path "$repo_root")"
  STAGE2_CLEANUP_PRIVATE_PLAN="$(stage2_canonical_path "$private_plan")"
  STAGE2_CLEANUP_PLAN_JSON="$(stage2_canonical_path "$plan_json")"
  STAGE2_CLEANUP_WORKTREE="$(stage2_canonical_path "$worktree")"
  export STAGE2_CLEANUP_REPO_ROOT
  export STAGE2_CLEANUP_PRIVATE_PLAN
  export STAGE2_CLEANUP_PLAN_JSON
  export STAGE2_CLEANUP_WORKTREE

  trap 'stage2_cleanup_on_exit "$?"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}
