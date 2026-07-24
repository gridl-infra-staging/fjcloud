#!/usr/bin/env bash
# Behavioral tests for Stage 2 detached Terraform plan cleanup.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

CLEANUP_LIB="ops/terraform/stage2_plan_cleanup.sh"

cleanup_paths=()

remember_cleanup_path() {
  cleanup_paths+=("$1")
}

cleanup_all() {
  local path
  for path in "${cleanup_paths[@]}"; do
    if [[ -n "$path" && -e "$path" ]]; then
      rm -rf "$path"
    fi
  done
}
trap cleanup_all EXIT

canonical_path() {
  python3 - "$1" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
}

make_fixture_repo() {
  local fixture_root="$1"
  local repo="$fixture_root/repo"

  mkdir -p "$repo"
  git -C "$repo" init -q
  git -C "$repo" config user.email "stage2-cleanup@example.invalid"
  git -C "$repo" config user.name "Stage 2 Cleanup Test"
  printf 'fixture\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" commit -q -m "fixture"
  printf '%s\n' "$repo"
}

make_private_artifacts() {
  local fixture_root="$1"
  local plan_dir="$fixture_root/private_plans"

  mkdir -p "$plan_dir"
  printf 'private-plan\n' > "$plan_dir/usage_daily.tfplan"
  printf '{}\n' > "$plan_dir/usage_daily.tfplan.json"
}

assert_path_absent() {
  local path="$1"
  local description="$2"
  if [[ ! -e "$path" ]]; then
    pass "$description"
  else
    fail "$description (still exists: $path)"
  fi
}

assert_worktree_absent_from_git() {
  local repo="$1"
  local worktree="$2"
  local description="$3"
  local worktree_real
  worktree_real="$(canonical_path "$worktree")"
  if git -C "$repo" worktree list --porcelain | rg -q "^worktree ${worktree_real}$"; then
    fail "$description (still registered: $worktree_real)"
  else
    pass "$description"
  fi
}

echo ""
echo "=== Stage 2 Cleanup Behavioral Tests ==="

assert_file_exists "$CLEANUP_LIB" "Stage 2 cleanup library exists"
if [[ -f "$CLEANUP_LIB" ]]; then
  # shellcheck source=stage2_plan_cleanup.sh
  source "$CLEANUP_LIB"
fi

echo ""
echo "--- Canonicalized worktree cleanup ---"

fixture_root="$(mktemp -d /tmp/fjcloud_stage2_cleanup_unit.XXXXXX)"
remember_cleanup_path "$fixture_root"
repo="$(make_fixture_repo "$fixture_root")"
worktree_alias="$fixture_root/source"
git -C "$repo" worktree add -q --detach "$worktree_alias" HEAD
make_private_artifacts "$fixture_root"

stage2_cleanup_private_artifacts \
  "$repo" \
  "$fixture_root/private_plans/usage_daily.tfplan" \
  "$fixture_root/private_plans/usage_daily.tfplan.json" \
  "$worktree_alias"

assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan" "Cleanup removes the private saved plan"
assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan.json" "Cleanup removes the private plan JSON"
assert_path_absent "$worktree_alias" "Cleanup removes the aliased detached worktree path"
assert_path_absent "$(canonical_path "$worktree_alias")" "Cleanup removes the canonical detached worktree path"
assert_worktree_absent_from_git "$repo" "$worktree_alias" "Cleanup unregisters the detached worktree from Git"

echo ""
echo "--- Trap cleanup preserves failure while removing artifacts ---"

fixture_root="$(mktemp -d /tmp/fjcloud_stage2_cleanup_unit.XXXXXX)"
remember_cleanup_path "$fixture_root"
repo="$(make_fixture_repo "$fixture_root")"
worktree_alias="$fixture_root/source"
git -C "$repo" worktree add -q --detach "$worktree_alias" HEAD
make_private_artifacts "$fixture_root"

trap_output=""
trap_status=0
trap_output=$(
  bash -c '
    set -euo pipefail
    source "$1"
    stage2_install_plan_cleanup "$2" "$3" "$4" "$5"
    false
  ' _ "$CLEANUP_LIB" "$repo" \
    "$fixture_root/private_plans/usage_daily.tfplan" \
    "$fixture_root/private_plans/usage_daily.tfplan.json" \
    "$worktree_alias" 2>&1
) || trap_status=$?

if [[ "$trap_status" -ne 0 ]]; then
  pass "Trap preserves the failing command status"
else
  fail "Trap preserves the failing command status (got 0)"
fi
if [[ -z "$trap_output" ]]; then
  pass "Trap cleanup does not print private paths during normal cleanup"
else
  fail "Trap cleanup does not print private paths during normal cleanup (output: $trap_output)"
fi
assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan" "Trap removes the private saved plan"
assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan.json" "Trap removes the private plan JSON"
assert_path_absent "$worktree_alias" "Trap removes the aliased detached worktree path"
assert_path_absent "$(canonical_path "$worktree_alias")" "Trap removes the canonical detached worktree path"
assert_worktree_absent_from_git "$repo" "$worktree_alias" "Trap unregisters the detached worktree from Git"

echo ""
echo "--- Trap cleanup handles interruption ---"

fixture_root="$(mktemp -d /tmp/fjcloud_stage2_cleanup_unit.XXXXXX)"
remember_cleanup_path "$fixture_root"
repo="$(make_fixture_repo "$fixture_root")"
worktree_alias="$fixture_root/source"
git -C "$repo" worktree add -q --detach "$worktree_alias" HEAD
make_private_artifacts "$fixture_root"

term_output=""
term_status=0
term_output=$(
  bash -c '
    set -euo pipefail
    source "$1"
    stage2_install_plan_cleanup "$2" "$3" "$4" "$5"
    kill -TERM "$$"
  ' _ "$CLEANUP_LIB" "$repo" \
    "$fixture_root/private_plans/usage_daily.tfplan" \
    "$fixture_root/private_plans/usage_daily.tfplan.json" \
    "$worktree_alias" 2>&1
) || term_status=$?

if [[ "$term_status" -eq 143 ]]; then
  pass "Trap maps TERM interruption to exit code 143"
else
  fail "Trap maps TERM interruption to exit code 143 (got $term_status)"
fi
if [[ -z "$term_output" ]]; then
  pass "Interrupted trap cleanup does not print private paths during normal cleanup"
else
  fail "Interrupted trap cleanup does not print private paths during normal cleanup (output: $term_output)"
fi
assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan" "Interrupted trap removes the private saved plan"
assert_path_absent "$fixture_root/private_plans/usage_daily.tfplan.json" "Interrupted trap removes the private plan JSON"
assert_path_absent "$worktree_alias" "Interrupted trap removes the aliased detached worktree path"
assert_path_absent "$(canonical_path "$worktree_alias")" "Interrupted trap removes the canonical detached worktree path"
assert_worktree_absent_from_git "$repo" "$worktree_alias" "Interrupted trap unregisters the detached worktree from Git"

test_summary "Stage 2 cleanup behavioral"
