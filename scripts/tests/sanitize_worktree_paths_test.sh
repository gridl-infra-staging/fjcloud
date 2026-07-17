#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SANITIZER="$REPO_ROOT/scripts/sanitize_worktree_paths.sh"
WORKTREE_PATH_PREFIX="/Users/stuart/parallel""_development"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

create_fixture_repo() {
    local temp_repo

    temp_repo="$(mktemp -d)"
    if [ -z "$temp_repo" ]; then
        return 1
    fi

    git -C "$temp_repo" init -q || return 1
    printf '%s\n' "$temp_repo"
}

write_tracked_file() {
    local fixture_root="$1"
    local relative_path="$2"
    local content="$3"

    mkdir -p "$fixture_root/$(dirname "$relative_path")" || return 1
    printf '%s' "$content" > "$fixture_root/$relative_path" || return 1
    git -C "$fixture_root" add "$relative_path" || return 1
}

read_fixture_file() {
    local fixture_root="$1"
    local relative_path="$2"

    cat "$fixture_root/$relative_path"
}

run_sanitizer() {
    local fixture_root="$1"
    local mode="$2"

    REPO_ROOT="$fixture_root" bash "$SANITIZER" "$mode"
}

run_sanitizer_with_input() {
    local fixture_root="$1"
    local mode="$2"
    local input_paths="$3"

    printf '%s\n' "$input_paths" | REPO_ROOT="$fixture_root" bash "$SANITIZER" "$mode"
}

assert_file_content() {
    local fixture_root="$1"
    local relative_path="$2"
    local expected="$3"
    local actual

    actual="$(read_fixture_file "$fixture_root" "$relative_path")"
    if [ "$actual" = "$expected" ]; then
        return 0
    fi

    printf 'expected: %s\nactual:   %s\n' "$expected" "$actual" >&2
    return 1
}

assert_no_bak_files() {
    local fixture_root="$1"

    if find "$fixture_root" -name '*.bak' -print -quit | grep . >/dev/null; then
        find "$fixture_root" -name '*.bak' -print >&2
        return 1
    fi
}

test_deep_leak_write_scrubs_to_repo_relative_path() {
    local fixture_root
    local file_path="docs/deep_probe.md"

    fixture_root="$(create_fixture_repo)" || {
        fail "deep leak fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "$file_path" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/web/src/routes/+page.svelte" || {
            rm -rf "$fixture_root"
            fail "deep leak fixture file could not be created"
            return
        }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "path=web/src/routes/+page.svelte"; then
        pass "deep worktree leak is scrubbed to a repo-relative path"
    else
        fail "deep worktree leak was not scrubbed correctly"
    fi
    rm -rf "$fixture_root"
}

test_shallow_leak_write_scrubs_to_repo_relative_path() {
    local fixture_root
    local file_path="docs/shallow_probe.md"

    fixture_root="$(create_fixture_repo)" || {
        fail "shallow leak fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "$file_path" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/DIRMAP.md" || {
            rm -rf "$fixture_root"
            fail "shallow leak fixture file could not be created"
            return
        }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "path=docs/DIRMAP.md"; then
        pass "shallow worktree leak is scrubbed to a repo-relative path"
    else
        fail "shallow worktree leak was not scrubbed correctly"
    fi
    rm -rf "$fixture_root"
}

test_source_leak_write_is_preserved() {
    local fixture_root
    local file_path="web/tests/source_probe.ts"
    local content

    content="path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/fjcloud_dev/web/tests/source_probe.ts"
    fixture_root="$(create_fixture_repo)" || {
        fail "source leak fixture repo could not be created"
        return
    }
    write_tracked_file "$fixture_root" "$file_path" "$content" || {
        rm -rf "$fixture_root"
        fail "source leak fixture file could not be created"
        return
    }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "$content" \
        && assert_no_bak_files "$fixture_root"; then
        pass "source/config file leaks are preserved by write mode"
    else
        fail "source/config file leak was modified by write mode"
    fi
    rm -rf "$fixture_root"
}

test_shell_source_bare_prefix_write_is_preserved() {
    local fixture_root
    local file_path="scripts/source_probe.sh"
    local content

    content="for candidate in ${WORKTREE_PATH_PREFIX}/mike_dev/*/mike_dev; do"
    fixture_root="$(create_fixture_repo)" || {
        fail "shell source fixture repo could not be created"
        return
    }
    write_tracked_file "$fixture_root" "$file_path" "$content" || {
        rm -rf "$fixture_root"
        fail "shell source fixture file could not be created"
        return
    }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "$content" \
        && assert_no_bak_files "$fixture_root"; then
        pass "shell source file leaks are preserved by write mode"
    else
        fail "shell source file leak was modified by write mode"
    fi
    rm -rf "$fixture_root"
}

test_bare_guard_prefix_write_is_scrubbed() {
    local fixture_root
    local file_path="docs/bare_prefix_probe.md"

    fixture_root="$(create_fixture_repo)" || {
        fail "bare-prefix fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "$file_path" \
        "probe=git grep -lE '${WORKTREE_PATH_PREFIX}' origin/main" || {
            rm -rf "$fixture_root"
            fail "bare-prefix fixture file could not be created"
            return
        }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "probe=git grep -lE '<worktree-root>' origin/main"; then
        pass "bare guard-visible worktree prefix is scrubbed"
    else
        fail "bare guard-visible worktree prefix was not scrubbed"
    fi
    rm -rf "$fixture_root"
}

test_docs_script_artifact_write_is_scrubbed() {
    local fixture_root
    local file_path="docs/runbooks/evidence/probe/00_commands.sh"

    fixture_root="$(create_fixture_repo)" || {
        fail "docs script artifact fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "$file_path" \
        "probe=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/fjcloud_dev/scripts/local-ci.sh" || {
            rm -rf "$fixture_root"
            fail "docs script artifact fixture file could not be created"
            return
        }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "probe=scripts/local-ci.sh"; then
        pass "docs script artifacts are scrubbed by write mode"
    else
        fail "docs script artifact was not scrubbed"
    fi
    rm -rf "$fixture_root"
}

test_no_leak_write_is_noop_without_backup() {
    local fixture_root
    local file_path="docs/no_leak.md"

    fixture_root="$(create_fixture_repo)" || {
        fail "no-leak fixture repo could not be created"
        return
    }
    write_tracked_file "$fixture_root" "$file_path" "path=docs/no_leak.md" || {
        rm -rf "$fixture_root"
        fail "no-leak fixture file could not be created"
        return
    }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "path=docs/no_leak.md" \
        && assert_no_bak_files "$fixture_root"; then
        pass "no-leak fixture is unchanged and leaves no backup files"
    else
        fail "no-leak fixture was modified or left backup files"
    fi
    rm -rf "$fixture_root"
}

test_decisions_leak_is_excluded_from_write() {
    local fixture_root
    local file_path="decisions/preserved_leak.md"
    local content

    content="path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/DIRMAP.md"
    fixture_root="$(create_fixture_repo)" || {
        fail "decisions fixture repo could not be created"
        return
    }
    write_tracked_file "$fixture_root" "$file_path" "$content" || {
        rm -rf "$fixture_root"
        fail "decisions fixture file could not be created"
        return
    }

    if run_sanitizer "$fixture_root" --write \
        && assert_file_content "$fixture_root" "$file_path" "$content"; then
        pass "decisions leak is preserved by the sanitizer exclusion"
    else
        fail "decisions leak was not preserved by the sanitizer exclusion"
    fi
    rm -rf "$fixture_root"
}

test_write_mode_is_idempotent() {
    local fixture_root
    local file_path="docs/idempotent_probe.md"
    local first_status
    local second_status

    fixture_root="$(create_fixture_repo)" || {
        fail "idempotence fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "$file_path" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/MAR17_11_2_data_management_features/fjcloud_dev/scripts/local-ci.sh" || {
            rm -rf "$fixture_root"
            fail "idempotence fixture file could not be created"
            return
        }

    run_sanitizer "$fixture_root" --write
    first_status=$?
    git -C "$fixture_root" add "$file_path" || {
        rm -rf "$fixture_root"
        fail "idempotence fixture file could not be restaged"
        return
    }
    run_sanitizer "$fixture_root" --write
    second_status=$?

    if [ "$first_status" -eq 0 ] \
        && [ "$second_status" -eq 0 ] \
        && assert_file_content "$fixture_root" "$file_path" "path=scripts/local-ci.sh" \
        && git -C "$fixture_root" diff --quiet \
        && assert_no_bak_files "$fixture_root"; then
        pass "write mode is idempotent after an initial scrub"
    else
        fail "write mode was not idempotent after an initial scrub"
    fi
    rm -rf "$fixture_root"
}

test_check_mode_reports_clean_tree() {
    local fixture_root
    local output

    fixture_root="$(create_fixture_repo)" || {
        fail "clean check fixture repo could not be created"
        return
    }
    write_tracked_file "$fixture_root" "docs/clean.md" "path=docs/clean.md" || {
        rm -rf "$fixture_root"
        fail "clean check fixture file could not be created"
        return
    }

    if output="$(run_sanitizer "$fixture_root" --check 2>&1)" \
        && [[ "$output" == *"[sanitize] no worktree-path leaks to scrub"* ]]; then
        pass "check mode reports a clean tree"
    else
        fail "check mode did not report a clean tree"
    fi
    rm -rf "$fixture_root"
}

test_check_mode_reports_rewritable_leak() {
    local fixture_root
    local output=""
    local status=0

    fixture_root="$(create_fixture_repo)" || {
        fail "check leak fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "docs/check_probe.md" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/DIRMAP.md" || {
            rm -rf "$fixture_root"
            fail "check leak fixture file could not be created"
            return
        }

    output="$(run_sanitizer "$fixture_root" --check 2>&1)" || status=$?
    if [ "$status" -eq 1 ] \
        && [[ "$output" == *"[sanitize] would rewrite docs/check_probe.md"* ]] \
        && [[ "$output" == *"sanitize_worktree_paths.sh --write"* ]]; then
        pass "check mode reports rewritable leaks and exits non-zero"
    else
        fail "check mode did not report the rewritable leak as expected"
    fi
    rm -rf "$fixture_root"
}

test_stdin_file_list_limits_write_scope() {
    local fixture_root

    fixture_root="$(create_fixture_repo)" || {
        fail "stdin scope fixture repo could not be created"
        return
    }
    write_tracked_file \
        "$fixture_root" \
        "docs/stdin_target.md" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/DIRMAP.md" || {
            rm -rf "$fixture_root"
            fail "stdin target fixture file could not be created"
            return
        }
    write_tracked_file \
        "$fixture_root" \
        "docs/stdin_other.md" \
        "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/OTHER.md" || {
            rm -rf "$fixture_root"
            fail "stdin other fixture file could not be created"
            return
        }

    if run_sanitizer_with_input "$fixture_root" --write "docs/stdin_target.md" \
        && assert_file_content "$fixture_root" "docs/stdin_target.md" "path=docs/DIRMAP.md" \
        && assert_file_content "$fixture_root" "docs/stdin_other.md" "path=${WORKTREE_PATH_PREFIX}/fjcloud_dev/jun11_pm_1_dirmap_guard_widen_and_sanitizer/docs/OTHER.md"; then
        pass "stdin file list limits write mode to the requested paths"
    else
        fail "stdin file list did not constrain write mode as expected"
    fi
    rm -rf "$fixture_root"
}

main() {
    echo "=== sanitize_worktree_paths_test ==="
    test_deep_leak_write_scrubs_to_repo_relative_path
    test_shallow_leak_write_scrubs_to_repo_relative_path
    test_source_leak_write_is_preserved
    test_shell_source_bare_prefix_write_is_preserved
    test_bare_guard_prefix_write_is_scrubbed
    test_docs_script_artifact_write_is_scrubbed
    test_no_leak_write_is_noop_without_backup
    test_decisions_leak_is_excluded_from_write
    test_write_mode_is_idempotent
    test_check_mode_reports_clean_tree
    test_check_mode_reports_rewritable_leak
    test_stdin_file_list_limits_write_scope
    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -ne 0 ]; then
        exit 1
    fi
}

main "$@"
