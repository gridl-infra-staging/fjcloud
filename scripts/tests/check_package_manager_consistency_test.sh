#!/usr/bin/env bash
# Contract tests for scripts/check_package_manager_consistency.sh.
#
# WHY THIS GATE EXISTS (captured 2026-07-19):
# web/ carried BOTH package-lock.json and pnpm-lock.yaml. CI installs with
# `npm ci` in 5 places and never invokes pnpm, yet local-ci.sh told developers
# to run `pnpm install` — while the very next comment in the same function said
# "local devs already have node_modules from `npm install`". The working tree
# had BOTH install markers present (.package-lock.json and .modules.yaml), so
# node_modules was a hybrid of two package managers. That split-brain already
# produced real drift: commit ba6b0ce07f exists solely to re-sync
# package-lock.json's devalue 5.6.3 -> 5.8.1 to "mirror npm ci".
#
# The `packageManager` field in package.json CANNOT enforce this: Corepack was
# unbundled from Node 25+ and is not installed on this machine (verified
# 2026-07-19), so that field is documentation only. This executable gate is the
# actual enforcement mechanism — it is what makes a returning pnpm-lock.yaml
# fail a build instead of silently re-forking the dependency graph.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK_SCRIPT="$REPO_ROOT/scripts/check_package_manager_consistency.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

run_check() {
    local repo_root="$1"
    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(FJCLOUD_REPO_ROOT="$repo_root" bash "$CHECK_SCRIPT" 2>&1)" || RUN_EXIT_CODE=$?
}

# Builds a minimal web/ fixture. Callers add or remove lockfiles per case.
make_fixture() {
    local dir="$1" package_manager_field="$2"
    mkdir -p "$dir/web"
    if [ -n "$package_manager_field" ]; then
        printf '{\n  "name": "web",\n  "packageManager": "%s"\n}\n' "$package_manager_field" > "$dir/web/package.json"
    else
        printf '{\n  "name": "web"\n}\n' > "$dir/web/package.json"
    fi
    printf '{}\n' > "$dir/web/package-lock.json"
}

test_passes_with_npm_lock_only() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir" "npm@11.12.1"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "npm-only web/ satisfies the single-package-manager contract"
    assert_contains "$RUN_OUTPUT" "OK" "success output should be affirmative"
    rm -rf "$tmpdir"
}

# THE REGRESSION THIS GATE OWNS: a returning pnpm-lock.yaml must fail loudly.
test_fails_when_pnpm_lock_present() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir" "npm@11.12.1"
    printf 'lockfileVersion: 9.0\n' > "$tmpdir/web/pnpm-lock.yaml"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "a second lockfile must fail the gate"
    assert_contains "$RUN_OUTPUT" "pnpm-lock.yaml" "failure must name the offending file"
    rm -rf "$tmpdir"
}

test_fails_when_npm_lock_missing() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir" "npm@11.12.1"
    rm -f "$tmpdir/web/package-lock.json"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "missing package-lock.json must fail (CI runs npm ci, which requires it)"
    assert_contains "$RUN_OUTPUT" "package-lock.json" "failure must name the missing lockfile"
    rm -rf "$tmpdir"
}

test_fails_when_package_manager_field_is_not_npm() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir" "pnpm@9.0.0"

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "1" "a non-npm packageManager declaration must fail"
    assert_contains "$RUN_OUTPUT" "packageManager" "failure must name the field"
    rm -rf "$tmpdir"
}

# Absent packageManager is tolerated: Corepack is not installed, so the field is
# advisory. The lockfile invariants above are the real contract.
test_passes_when_package_manager_field_absent() {
    local tmpdir; tmpdir="$(mktemp -d)"
    make_fixture "$tmpdir" ""

    run_check "$tmpdir"

    assert_eq "$RUN_EXIT_CODE" "0" "absent packageManager field is advisory, not a failure"
    rm -rf "$tmpdir"
}

test_passes_with_npm_lock_only
test_fails_when_pnpm_lock_present
test_fails_when_npm_lock_missing
test_fails_when_package_manager_field_is_not_npm
test_passes_when_package_manager_field_absent

run_test_summary
