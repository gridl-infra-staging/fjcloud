#!/usr/bin/env bash
# Regression test for the bash 3.2 `set -e` pitfall in scripts/local-ci.sh
# gate functions.
#
# Why this test exists:
#   bash 3.2 (macOS default) silently disables `set -e` inside a function
#   when that function is invoked as part of a `||` expression. local-ci.sh
#   invokes each gate via `"$@" > "$log" 2>&1 || rc=$?` in run_gate, so a
#   gate body relying on `set -e` alone will continue past a failing command
#   and record PASS even when an internal step (e.g. cargo fmt --check)
#   fails.
#
#   The established convention in local-ci.sh — applied in gate_web_lint
#   and gate_web_test — is explicit `|| return $?` after each command.
#   That convention was missed in gate_rust_lint and gate_rust_test on
#   2026-04-30, producing a real false positive when my own fmt-violating
#   test code passed local-ci but failed staging CI's cargo fmt --check.
#
# Contract under test (load-bearing):
#   When `cargo fmt --check` finds a real violation, `local-ci.sh --gate
#   rust-lint` MUST report FAIL. End-to-end against the real script — no
#   mocking — because that's the surface the operator relies on.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT+1)); }

# ---------------------------------------------------------------------------
# End-to-end test against the real local-ci.sh — gate_rust_lint must FAIL
# when cargo fmt --check finds a violation. This is the load-bearing
# contract: the user-facing local-ci.sh must catch what CI catches.
#
# Strategy: temporarily write a fmt-violating Rust file inside infra/, then
# invoke `local-ci.sh --gate rust-lint` and assert FAIL in the summary.
# We restore the file regardless of test outcome (trap on EXIT).
# ---------------------------------------------------------------------------

test_local_ci_rust_lint_fails_on_real_fmt_violation() {
    local fixture_path
    fixture_path="$REPO_ROOT/infra/api/tests/_local_ci_set_e_regression_fixture.rs"

    # Write a Rust file with a long line that rustfmt will want to wrap.
    # The fixture name is unique to this test so it won't collide with any
    # real source file. We clean it up unconditionally at every exit point
    # below — explicit cleanup beats a RETURN trap that would re-fire
    # against out-of-scope locals under `set -u`.
    cat > "$fixture_path" <<'FIXTURE_EOF'
//! Regression fixture for scripts/tests/local_ci_gate_set_e_test.sh.
//! This file intentionally violates rustfmt: the assert_eq! line below
//! exceeds the configured line width. cargo fmt --check should report a
//! diff and exit non-zero, which local-ci's rust-lint gate must surface
//! as FAIL. The test removes this file at every exit path.
#[test]
fn fixture_intentionally_too_long() {
    assert_eq!(std::env::var("LOCAL_CI_REGRESSION_FIXTURE").ok().as_deref(), Some("intentional_long_line_to_force_a_rustfmt_diff_so_we_test_the_gate_contract"));
}
FIXTURE_EOF

    # Pre-check: cargo fmt --check on its own must reject the fixture.
    # If this fails, the test isn't actually exercising the bug — bail
    # with cleanup rather than report a misleading pass.
    if ( cd "$REPO_ROOT/infra" && cargo fmt -- --check >/dev/null 2>&1 ); then
        rm -f "$fixture_path"
        fail "fmt-violating fixture did not actually trip cargo fmt --check; test is mis-configured"
        return
    fi

    # Run local-ci's rust-lint gate. With the bug, this prints PASS.
    # With the fix, it prints FAIL.
    local out
    out="$(bash "$LOCAL_CI" --gate rust-lint 2>&1 || true)"

    rm -f "$fixture_path"

    if [[ "$out" == *"rust-lint           FAIL"* ]] || [[ "$out" == *"rust-lint  FAIL"* ]] || [[ "$out" == *"Result: FAIL"* ]]; then
        pass "local-ci.sh --gate rust-lint records FAIL when cargo fmt --check finds a violation"
    else
        fail "local-ci.sh --gate rust-lint did not report FAIL on a real fmt violation. Output tail: $(echo "$out" | tail -10)"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo "=== local_ci_gate_set_e_test ==="
    test_local_ci_rust_lint_fails_on_real_fmt_violation
    echo
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [[ "$FAIL_COUNT" -ne 0 ]]; then
        exit 1
    fi
}

main "$@"
