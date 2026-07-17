#!/usr/bin/env bash
# script_exec_bits_test.sh — Regression test for exec-bit hygiene on top-level
# scripts in scripts/.
#
# Failure mode (anchored 2026-05-31): scripts/api-dev.sh shipped at git mode
# 100644 (non-executable). scripts/local_demo.sh invokes it via
# `env API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1 scripts/api-dev.sh` which
# requires the exec bit. The crash signature was "[local-demo] api failed
# health check after 90s" with the underlying "env: scripts/api-dev.sh:
# Permission denied" only visible in .local/api.log. Other tests masked the
# bug because they invoke scripts via `bash $script`, which doesn't check
# the exec bit.
#
# Discovery surface: 19 top-level scripts were 100644 in git when this test
# was added. Each one is a potential repeat of the api-dev.sh failure.
#
# Scope decision: this test asserts on top-level scripts/*.sh only. We do
# NOT assert on scripts/lib/*.sh (sourced, no exec needed) or
# scripts/tests/*.sh (invoked via `bash $test`, no exec needed). Subdirs
# like scripts/launch/, scripts/canary/, scripts/chaos/ are case-by-case
# and out of scope for this minimal guard — extend later if a regression
# bites there too.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Every .sh file directly under scripts/ (not in any subdirectory) must be
# tracked at git mode 100755. The intent is to catch any future regression
# where a top-level script ships non-executable and only crashes at runtime
# in the local-demo path.
test_all_top_level_scripts_are_executable_in_git() {
    local sh_path mode rel
    local bad_paths=()
    while IFS= read -r sh_path; do
        rel="${sh_path#"$REPO_ROOT/"}"
        mode=$(git -C "$REPO_ROOT" ls-tree HEAD "$rel" | awk '{print $1}')
        if [ -z "$mode" ]; then
            # Untracked .sh files are out of scope — git can't enforce mode
            # on something it doesn't track. Just skip.
            continue
        fi
        if [ "$mode" != "100755" ]; then
            bad_paths+=("$rel (git mode $mode)")
        fi
    done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name "*.sh" | sort)

    if [ ${#bad_paths[@]} -eq 0 ]; then
        pass "every top-level scripts/*.sh is tracked at git mode 100755"
    else
        fail "the following top-level scripts/*.sh files are tracked at the wrong git mode (expected 100755):"
        local p
        for p in "${bad_paths[@]}"; do
            printf '  - %s\n' "$p" >&2
        done
        printf 'Fix: `chmod +x <path> && git add <path>` for each, then commit.\n' >&2
    fi
}

# Sanity check on the test itself: assert that scripts/local_demo.sh exists
# and is one of the scripts the test would check. This guards against the
# test silently passing because the find expression broke.
test_find_scope_covers_local_demo_sh() {
    local sh_path
    local found=false

    if [ ! -f "$REPO_ROOT/scripts/local_demo.sh" ]; then
        fail "scripts/local_demo.sh missing — test scope assumption broken"
        return
    fi
    while IFS= read -r sh_path; do
        if [ "$sh_path" = "$REPO_ROOT/scripts/local_demo.sh" ]; then
            found=true
            break
        fi
    done < <(find "$REPO_ROOT/scripts" -maxdepth 1 -type f -name "*.sh" | sort)
    if [ "$found" != true ]; then
        fail "scripts/local_demo.sh not picked up by the find scope used in this test"
        return
    fi
    pass "test scope covers scripts/local_demo.sh"
}

test_dev_state_audit_is_executable_in_worktree() {
    local audit_script="$REPO_ROOT/scripts/dev_state_audit.sh"

    if [ ! -f "$audit_script" ]; then
        fail "scripts/dev_state_audit.sh missing — local demo audit hook cannot run"
        return
    fi
    if [ ! -x "$audit_script" ]; then
        fail "scripts/dev_state_audit.sh must be executable in the worktree"
        return
    fi

    pass "scripts/dev_state_audit.sh is executable in the worktree"
}

test_cleanup_dev_orphans_is_executable_in_worktree() {
    local cleanup_script="$REPO_ROOT/scripts/cleanup_dev_orphans.sh"

    if [ ! -f "$cleanup_script" ]; then
        fail "scripts/cleanup_dev_orphans.sh missing — local orphan cleanup cannot run"
        return
    fi
    if [ ! -x "$cleanup_script" ]; then
        fail "scripts/cleanup_dev_orphans.sh must be executable in the worktree"
        return
    fi

    pass "scripts/cleanup_dev_orphans.sh is executable in the worktree"
}

main() {
    echo "=== script_exec_bits_test.sh ==="
    echo ""

    test_find_scope_covers_local_demo_sh
    test_dev_state_audit_is_executable_in_worktree
    test_cleanup_dev_orphans_is_executable_in_worktree
    test_all_top_level_scripts_are_executable_in_git

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
