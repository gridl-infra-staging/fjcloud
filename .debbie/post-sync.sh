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

  # Private deploy proof can be present in a dirty dev worktree while a release
  # is being promoted. It is intentionally excluded from the copy projection;
  # prune any older mirror copy before committing so exclusions cannot strand it.
  rm -rf "$target_root/docs/runbooks/evidence/prod-fleet-rebuild"

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

# Publish guard runs FIRST, before scrai-strip, the openapi regeneration and
# the commit+push below. Debbie has already copied files into the mirror
# working tree by the time this hook runs, so the earliest thing this hook can
# still protect is publication itself — and refusing here means no mirror
# commit is created and nothing reaches the public remote.
#
# This is the single enforcement point for the rule, because debbie runs this
# hook for every caller: `git_push_with_sync.sh`, `post_wave_a_sync_prod.sh`,
# and a bare `debbie sync <target>` typed by a lane. See
# scripts/lib/publish_guard.sh for why ancestry is the whole predicate.
#
# A refusal also restores the mirror working tree. Debbie has already copied the
# dev tree over the mirror by the time this hook runs, and leaving those files
# behind would recreate the exact harm the guard exists to prevent: the publish
# step below is `git add -A`, and debbie's prune only considers TRACKED paths
# (sync.py `_git_tracked_paths`), so an untracked file left by a refused sync
# would be committed and published by the NEXT legitimate sync.
#
# Restoring is safe here specifically because the mirror is a derived,
# debbie-owned target whose only source of truth is the dev repo: resetting to
# HEAD restores exactly the last published state, and nothing else writes this
# clone. `clean -fd` deliberately omits `-x`, so ignored build artefacts are
# left alone.
# A missing guard must not read as "nothing to enforce". Fail closed and say so
# plainly, rather than letting `source` emit a bare "No such file or directory"
# that looks like an unrelated path bug.
publish_guard_lib="${DEBBIE_DEV_ROOT:?}/scripts/lib/publish_guard.sh"
if [[ ! -f "$publish_guard_lib" ]]; then
    echo "post-sync: publish guard missing at $publish_guard_lib; refusing to publish." >&2
    exit 3
fi
# shellcheck source=../scripts/lib/publish_guard.sh
source "$publish_guard_lib"
# Capture the status with `|| guard_status=$?` rather than testing `if ! ...`.
# Inside an `if !` condition, `$?` in the body is the status of the negated
# test (0), not the function's return, so the refusal status would be lost and
# the hook would exit 0 on a refusal — proving the opposite of what it means to.
guard_status=0
assert_dev_head_is_publishable "${DEBBIE_DEV_ROOT:?}" || guard_status=$?
if [[ "$guard_status" -ne 0 ]]; then
    git -C "${DEBBIE_TARGET_ROOT:?}" reset --hard HEAD >/dev/null 2>&1 || true
    git -C "${DEBBIE_TARGET_ROOT:?}" clean -fd >/dev/null 2>&1 || true
    echo "post-sync: refusing to publish; mirror was NOT committed or pushed," >&2
    echo "post-sync: and its working tree was restored to the last published commit." >&2
    exit "$guard_status"
fi

run_scrai_strip "${DEBBIE_TARGET_ROOT:?}"
regenerate_openapi_artifact "${DEBBIE_TARGET_ROOT:?}"
run_post_strip_sync_commit_push "${DEBBIE_TARGET_ROOT:?}"
