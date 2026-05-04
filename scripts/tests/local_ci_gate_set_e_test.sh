#!/usr/bin/env bash
# Regression test for the bash 3.2 `set -e` pitfall in scripts/local-ci.sh
# gate functions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"
FIXTURE_PATH="$REPO_ROOT/infra/api/tests/_local_ci_set_e_regression_fixture.rs"
trap 'rm -f "$FIXTURE_PATH"' EXIT

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT+1)); }

rust_lint_block_has_generate_ssm_hook() {
    local rust_lint_block="$1"
    if printf '%s\n' "$rust_lint_block" | grep -Eq '^[[:space:]]*bash[[:space:]]+"\$REPO_ROOT/scripts/tests/generate_ssm_env_test\.sh"([[:space:]]*\|\|.*)?$'; then
        return 0
    fi
    return 1
}

rust_lint_block_has_set_e_hook() {
    local rust_lint_block="$1"
    if printf '%s\n' "$rust_lint_block" | grep -Eq '^[[:space:]]*bash[[:space:]]+"\$REPO_ROOT/scripts/tests/local_ci_gate_set_e_test\.sh"([[:space:]]*\|\|.*)?$'; then
        return 0
    fi
    return 1
}

write_fmt_violation_fixture() {
    local fixture_path="$1"
    cat > "$fixture_path" <<'FIXTURE_EOF'
//! Regression fixture for scripts/tests/local_ci_gate_set_e_test.sh.
#[test]
fn fixture_intentionally_too_long() {
    assert_eq!(std::env::var("LOCAL_CI_REGRESSION_FIXTURE").ok().as_deref(), Some("intentional_long_line_to_force_a_rustfmt_diff_so_we_test_the_gate_contract"));
}
FIXTURE_EOF
}

assert_fixture_trips_fmt_check() {
    local fixture_path="$1"
    if ( cd "$REPO_ROOT/infra" && cargo fmt -- --check >/dev/null 2>&1 ); then
        rm -f "$fixture_path"
        fail "fmt-violating fixture did not actually trip cargo fmt --check; test is mis-configured"
        return 1
    fi
    return 0
}

test_local_ci_rust_lint_fails_on_real_fmt_violation() {
    if (( BASH_VERSINFO[0] < 4 )); then
        local fixture_path="$FIXTURE_PATH"
        write_fmt_violation_fixture "$fixture_path"
        assert_fixture_trips_fmt_check "$fixture_path" || return

        local out_skip
        local skip_status=0
        out_skip="$(LOCAL_CI_SKIP_SET_E_REGRESSION_TEST=1 bash "$LOCAL_CI" --gate rust-lint 2>&1)" || skip_status=$?
        rm -f "$fixture_path"
        if [[ "$skip_status" -ne 1 ]]; then
            fail "local-ci.sh --gate rust-lint returned $skip_status on bash<4; expected 1 because cargo fmt violation should still fail the gate. Output tail: $(echo "$out_skip" | tail -20)"
            return
        fi
        if [[ "$out_skip" == *"Result: FAIL"* ]] \
            && { [[ "$out_skip" == *"rust-lint           FAIL"* ]] || [[ "$out_skip" == *"rust-lint  FAIL"* ]]; } \
            && [[ "$out_skip" != *"rust-lint           SKIP"* ]] \
            && [[ "$out_skip" != *"rust-lint  SKIP"* ]]; then
            pass "local-ci.sh --gate rust-lint treats generate_ssm_env_test.sh as a sub-check skip and still fails on real cargo fmt violations on bash<4"
        else
            fail "local-ci.sh --gate rust-lint did not keep running after generate_ssm_env_test.sh bash<4 skip. Output tail: $(echo "$out_skip" | tail -20)"
        fi
        return
    fi

    local fixture_path="$FIXTURE_PATH"
    write_fmt_violation_fixture "$fixture_path"
    assert_fixture_trips_fmt_check "$fixture_path" || return

    local out
    local status=0
    out="$(LOCAL_CI_SKIP_SET_E_REGRESSION_TEST=1 bash "$LOCAL_CI" --gate rust-lint 2>&1)" || status=$?

    rm -f "$fixture_path"

    if [[ "$status" -ne 1 ]]; then
        fail "local-ci.sh --gate rust-lint returned $status on bash>=4; expected 1 because cargo fmt violation should fail the gate. Output tail: $(echo "$out" | tail -20)"
        return
    fi

    if [[ "$out" == *"rust-lint           FAIL"* ]] || [[ "$out" == *"rust-lint  FAIL"* ]] || [[ "$out" == *"Result: FAIL"* ]]; then
        pass "local-ci.sh --gate rust-lint records FAIL when cargo fmt --check finds a violation"
    else
        fail "local-ci.sh --gate rust-lint did not report FAIL on a real fmt violation. Output tail: $(echo "$out" | tail -10)"
    fi
}

test_local_ci_rust_lint_includes_generate_ssm_env_contract() {
    local rust_lint_block
    rust_lint_block="$(
        awk '
            /^gate_rust_lint\(\) \{/ { in_block=1; print; next }
            in_block { print }
            in_block && /^}/ { exit }
        ' "$LOCAL_CI"
    )"

    if rust_lint_block_has_generate_ssm_hook "$rust_lint_block"; then
        pass "gate_rust_lint executes generate_ssm_env_test.sh"
    else
        fail "gate_rust_lint is missing generate_ssm_env_test.sh contract hook"
    fi
}

test_local_ci_rust_lint_includes_set_e_regression_hook() {
    local rust_lint_block
    rust_lint_block="$(
        awk '
            /^gate_rust_lint\(\) \{/ { in_block=1; print; next }
            in_block { print }
            in_block && /^}/ { exit }
        ' "$LOCAL_CI"
    )"

    if rust_lint_block_has_set_e_hook "$rust_lint_block"; then
        pass "gate_rust_lint executes local_ci_gate_set_e_test.sh"
    else
        fail "gate_rust_lint is missing local_ci_gate_set_e_test.sh regression hook"
    fi
}

test_hook_detection_rejects_comment_only_mentions() {
    local comment_only_block
    comment_only_block=$'gate_rust_lint() {\n    # scripts/tests/generate_ssm_env_test.sh is documented here only\n    bash "$REPO_ROOT/scripts/tests/ci_workflow_test.sh" || return $?\n}'

    if rust_lint_block_has_generate_ssm_hook "$comment_only_block"; then
        fail "hook detection accepted a comment-only mention; expected executable invocation requirement"
    else
        pass "hook detection rejects comment-only mentions of generate_ssm_env_test.sh"
    fi
}

test_set_e_hook_detection_rejects_comment_only_mentions() {
    local comment_only_block
    comment_only_block=$'gate_rust_lint() {\n    # scripts/tests/local_ci_gate_set_e_test.sh is documented here only\n    bash "$REPO_ROOT/scripts/tests/ci_workflow_test.sh" || return $?\n}'

    if rust_lint_block_has_set_e_hook "$comment_only_block"; then
        fail "set-e hook detection accepted a comment-only mention; expected executable invocation requirement"
    else
        pass "set-e hook detection rejects comment-only mentions of local_ci_gate_set_e_test.sh"
    fi
}

test_local_ci_migration_gate_uses_local_postgres_default_url() {
    local migration_block
    migration_block="$(
        awk '
            /^gate_migration_test\(\) \{/ { in_block=1; print; next }
            in_block { print }
            in_block && /^}/ { exit }
        ' "$LOCAL_CI"
    )"

    local expected_default='local db_url="${DATABASE_URL:-postgres://griddle:griddle_local@127.0.0.1:5432/fjcloud_test}"'
    if [[ "$migration_block" == *"$expected_default"* ]]; then
        pass "gate_migration_test defaults DATABASE_URL to local docker-compose postgres credentials"
    else
        fail "gate_migration_test default DATABASE_URL diverges from local docker-compose postgres credentials"
    fi
}

main() {
    echo "=== local_ci_gate_set_e_test ==="
    test_local_ci_rust_lint_fails_on_real_fmt_violation
    test_local_ci_rust_lint_includes_generate_ssm_env_contract
    test_local_ci_rust_lint_includes_set_e_regression_hook
    test_hook_detection_rejects_comment_only_mentions
    test_set_e_hook_detection_rejects_comment_only_mentions
    test_local_ci_migration_gate_uses_local_postgres_default_url
    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [[ "$FAIL_COUNT" -ne 0 ]]; then
        exit 1
    fi
}

main "$@"
