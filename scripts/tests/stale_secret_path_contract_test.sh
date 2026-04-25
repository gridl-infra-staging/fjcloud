#!/usr/bin/env bash
# Contract test: active docs/generated/script surfaces must not reintroduce
# deprecated shared secret source paths from legacy local setups.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

DEPRECATED_PATHS=(
    "/Users/stuart/repos/gridl/fjcloud/.secret/.env.secret"
    "~/repos/gridl/fjcloud/.secret/.env.secret"
)

# Intentionally scoped to active surfaces only.
# Historical chats/deliverables and other archival artifacts are excluded.
EXACT_TARGETS=(
    "$REPO_ROOT/.scrai/rules.md"
    "$REPO_ROOT/.scrai/summaries.json"
    "$REPO_ROOT/AGENTS.md"
    "$REPO_ROOT/CLAUDE.md"
    "$REPO_ROOT/scripts/bootstrap-env-local.sh"
    "$REPO_ROOT/scripts/lib/env.sh"
    "$REPO_ROOT/ops/scripts/lib/generate_ssm_env.sh"
    "$REPO_ROOT/ops/scripts/rds_restore_evidence.sh"
)

MANDATORY_ACTIVE_SCRIPT_OWNERS=(
    "$REPO_ROOT/scripts/bootstrap-env-local.sh"
    "$REPO_ROOT/scripts/lib/env.sh"
    "$REPO_ROOT/ops/scripts/lib/generate_ssm_env.sh"
    "$REPO_ROOT/ops/scripts/rds_restore_evidence.sh"
)

TARGET_DIRS=(
    "$REPO_ROOT/docs/runbooks"
    "$REPO_ROOT/docs/checklists"
)

# Active assertion-owner tests may mention deprecated absolute paths only
# inside explicit negative assertions.
ASSERTION_OWNER_TESTS=(
    "$REPO_ROOT/scripts/tests/live_e2e_evidence_docs_test.sh"
    "$REPO_ROOT/scripts/tests/ses_runbook_test.sh"
    "$REPO_ROOT/scripts/tests/ses_deliverability_evidence_test.sh"
)

check_exact_targets_cover_mandatory_owner_surfaces() {
    local owner target found owner_rel
    for owner in "${MANDATORY_ACTIVE_SCRIPT_OWNERS[@]}"; do
        owner_rel="${owner#"$REPO_ROOT/"}"
        found=false
        for target in "${EXACT_TARGETS[@]}"; do
            if [ "$target" = "$owner" ]; then
                found=true
                break
            fi
        done
        if [ "$found" = true ]; then
            pass "exact target coverage includes $owner_rel"
        else
            fail "exact target coverage missing mandatory active owner $owner_rel"
        fi
    done
}

check_active_surfaces_do_not_contain_deprecated_paths() {
    local deprecated_path matches
    for deprecated_path in "${DEPRECATED_PATHS[@]}"; do
        matches="$(rg -n -F "$deprecated_path" "${EXACT_TARGETS[@]}" "${TARGET_DIRS[@]}" 2>/dev/null || true)"
        if [ -n "$matches" ]; then
            fail "active surfaces should not contain deprecated path '$deprecated_path'\n$matches"
        else
            pass "active surfaces exclude deprecated path '$deprecated_path'"
        fi
    done
}

check_assertion_owner_tests_keep_negative_assertion_only() {
    local deprecated_absolute_path deprecated_tilde_path
    local all_matches non_owner_matches owner_file owner_matches
    local owner_pattern

    owner_pattern="$(printf "%s\n" "${ASSERTION_OWNER_TESTS[@]}" | paste -sd'|' -)"

    deprecated_absolute_path="${DEPRECATED_PATHS[0]}"
    all_matches="$(
        rg -n -F \
            --glob '!stale_secret_path_contract_test.sh' \
            "$deprecated_absolute_path" \
            "$REPO_ROOT/scripts/tests" || true
    )"
    non_owner_matches="$(printf "%s\n" "$all_matches" | rg -v "$owner_pattern" || true)"

    if [ -n "$non_owner_matches" ]; then
        fail "deprecated absolute path should appear only in explicit assertion-owner tests\n$non_owner_matches"
    else
        pass "deprecated absolute path is scoped to explicit assertion-owner tests"
    fi

    for owner_file in "${ASSERTION_OWNER_TESTS[@]}"; do
        owner_matches="$(rg -n -F "$deprecated_absolute_path" "$owner_file" || true)"
        if [ -n "$owner_matches" ]; then
            pass "$(basename "$owner_file") keeps an explicit deprecated absolute-path assertion"
            positive_uses="$(rg -F "$deprecated_absolute_path" "$owner_file" | rg 'assert_contains' | rg -v 'assert_not_contains' || true)"
            if [ -n "$positive_uses" ]; then
                fail "$(basename "$owner_file") uses deprecated path in a positive assertion (must be assert_not_contains only)"
            fi
        else
            fail "$(basename "$owner_file") should keep an explicit deprecated absolute-path assertion"
        fi
    done

    deprecated_tilde_path="${DEPRECATED_PATHS[1]}"
    all_matches="$(
        rg -n -F \
            --glob '!stale_secret_path_contract_test.sh' \
            "$deprecated_tilde_path" \
            "$REPO_ROOT/scripts/tests" || true
    )"
    if [ -n "$all_matches" ]; then
        fail "tilde-form deprecated path should not appear in scripts/tests\n$all_matches"
    else
        pass "scripts/tests avoid tilde-form deprecated path references"
    fi
}

echo "=== stale secret path contract tests ==="
check_exact_targets_cover_mandatory_owner_surfaces
check_active_surfaces_do_not_contain_deprecated_paths
check_assertion_owner_tests_keep_negative_assertion_only

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
