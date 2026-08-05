#!/usr/bin/env bash
# Static / contract tests for scripts/launch/run_browser_lane_locally.sh
#
# These are cheap, deterministic checks: argument handling (which returns
# before any stack/SSM work) plus grep-based invariants over the script source
# that must not silently regress. They intentionally do NOT bring up the stack
# or call SSM — that is the launcher's own empirical proof lane.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$REPO_ROOT/scripts/launch/run_browser_lane_locally.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

assert_exit_code() {
  local expected="$1" message="$2"; shift 2
  local actual=0
  "$@" >/dev/null 2>&1 || actual=$?
  if [ "$actual" = "$expected" ]; then pass "$message"; else fail "$message (expected exit $expected, got $actual)"; fi
}

assert_source_contains() {
  local needle="$1" message="$2"
  if grep -Fq -- "$needle" "$TARGET"; then pass "$message"; else fail "$message (source missing: $needle)"; fi
}

assert_source_absent() {
  local needle="$1" message="$2"
  if grep -Fq -- "$needle" "$TARGET"; then fail "$message (source unexpectedly contains: $needle)"; else pass "$message"; fi
}

assert_both_dispatch_contains() {
  local needle="$1" message="$2" both_dispatch
  both_dispatch="$(awk '/^  both\)$/,/^    ;;$/' "$TARGET")"
  if grep -Fq -- "$needle" <<<"$both_dispatch"; then
    pass "$message"
  else
    fail "$message (both dispatch missing: $needle)"
  fi
}

assert_both_dispatches_exact_lanes() {
  local both_dispatch actual expected
  both_dispatch="$(awk '/^  both\)$/,/^    ;;$/' "$TARGET")"
  actual="$(sed -n 's/^[[:space:]]*run_one_lane \([^[:space:]]*\).*/\1/p' <<<"$both_dispatch")"
  expected="$(printf '%s\n' \
    signup_to_paid_invoice \
    billing_portal_payment_method_update \
    upgrade_to_shared_unmocked)"
  if [ "$actual" = "$expected" ]; then
    pass "both lane dispatches exactly the three billing lanes"
  else
    fail "both lane dispatch changed (expected: ${expected//$'\n'/, }; got: ${actual//$'\n'/, })"
  fi
}

assert_b21_case_contains() {
  local needle="$1" message="$2" b21_case
  b21_case="$(awk '/^    b21_verify_email\)$/,/^      ;;$/' "$TARGET")"
  if grep -Fq -- "$needle" <<<"$b21_case"; then
    pass "$message"
  else
    fail "$message (B21 case missing: $needle)"
  fi
}

assert_b21_dispatch_absent() {
  local b21_case
  b21_case="$(awk '/^    b21_verify_email\)$/,/^      ;;$/' "$TARGET")"
  if [ -z "$b21_case" ]; then
    fail "B21 lane does not pass --no-deps (B21 case missing)"
  elif grep -Fq -- '--no-deps' <<<"$b21_case"; then
    fail "B21 lane must let Playwright spawn its email-verification stack"
  else
    pass "B21 lane does not pass --no-deps"
  fi
}

assert_helper_defined_before_lane_stack_branch() {
  local helper="$1" message="$2" helper_line branch_line
  helper_line="$(grep -n "^${helper}()" "$TARGET" | head -n 1 | cut -d: -f1)"
  branch_line="$(grep -n '^if lane_needs_local_stack "\$LANE_ARG"; then' "$TARGET" | head -n 1 | cut -d: -f1)"
  if [ -n "$helper_line" ] && [ -n "$branch_line" ] && [ "$helper_line" -lt "$branch_line" ]; then
    pass "$message"
  else
    fail "$message (${helper} must be defined before the lane stack branch)"
  fi
}

# --- Existence / executability -------------------------------------------
[ -f "$TARGET" ] && pass "launcher exists" || { fail "launcher missing at $TARGET"; echo "1 fatal"; exit 1; }
[ -x "$TARGET" ] && pass "launcher is executable" || fail "launcher not executable"
if bash -n "$TARGET"; then pass "launcher parses (bash -n)"; else fail "launcher has a syntax error"; fi

# --- Argument handling (returns before any stack/SSM work) ---------------
assert_exit_code 0  "--help exits 0"                     bash "$TARGET" --help
assert_exit_code 64 "missing --lane exits 64"            bash "$TARGET"
assert_exit_code 64 "unknown --lane value exits 64"      bash "$TARGET" --lane bogus_lane
assert_exit_code 64 "unknown flag exits 64"              bash "$TARGET" --nope
# --help must document the routine local browser lanes.
help_out="$(bash "$TARGET" --help 2>&1)"
case "$help_out" in
  *signup_to_paid_invoice*billing_portal_payment_method_update*upgrade_to_shared_unmocked*b21_verify_email*both*) pass "--help lists all routine local browser lanes" ;;
  *) fail "--help missing one of the lane names" ;;
esac

# --- Invariants that MUST hold (these are why this lane is correct) -------
# Fails closed on non-test Stripe key prefixes.
assert_source_contains 'pk_test_*'  "fails closed unless publishable key is pk_test_"
assert_source_contains 'sk_test_*'  "fails closed unless secret key is sk_test_/rk_test_"
assert_source_contains 'whsec_*'    "fails closed unless webhook secret is whsec_"
# Local auto-verify: must NOT opt into the remote/staging target (that would
# disable local auto-verify and route fixtures at deployed hosts).
assert_source_absent 'PLAYWRIGHT_TARGET_REMOTE=1' "does not enable remote-target opt-in"
assert_source_absent 'export PLAYWRIGHT_TARGET_REMOTE' "does not export PLAYWRIGHT_TARGET_REMOTE"
# Local auto-verify is explicitly enabled.
assert_source_contains 'API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1' "enables local skip-email-verification"
assert_source_contains 'SKIP_EMAIL_VERIFICATION=1' "sets SKIP_EMAIL_VERIFICATION for local auto-verify"
# Hydrates test-mode Stripe keys from the staging SSM sandbox.
assert_source_contains '/fjcloud/staging/stripe_publishable_key' "hydrates publishable key from SSM"
assert_source_contains '/fjcloud/staging/stripe_secret_key' "hydrates secret key from SSM"
assert_source_contains '/fjcloud/staging/stripe_webhook_secret' "hydrates webhook secret from SSM"
assert_source_contains 'failed to fetch $1 from SSM' "reports exact SSM fetch failures"
assert_source_contains 'aws exit' "reports AWS CLI exit status on SSM failures"
assert_source_contains 'set +e' "captures AWS SSM exit status without set -e short-circuit"
assert_source_contains 'set -e' "restores fail-closed shell mode after SSM status capture"
assert_source_absent '--output text 2>/dev/null' "does not suppress AWS SSM error diagnostics"
# Runs the specs with the required flags.
assert_source_contains '--no-deps' "runs Playwright with --no-deps"
assert_source_contains '--reporter=list' "runs Playwright with --reporter=list"
assert_source_contains '--trace on' "runs Playwright with --trace on"
assert_source_contains 'signup_to_paid_invoice|billing_portal_payment_method_update|upgrade_to_shared_unmocked|b21_verify_email|both' \
  "accepts every standalone local browser lane"
assert_source_contains 'billing_portal_payment_method_update) spec_file="tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts"' \
  "maps B2 lane to billing_portal_payment_method_update spec"
assert_source_contains 'upgrade_to_shared_unmocked) spec_file="tests/e2e-ui/full/upgrade_to_shared_unmocked.spec.ts"' \
  "maps B7 lane to upgrade_to_shared_unmocked spec"
assert_source_contains 'upgrade_to_shared_unmocked) run_one_lane upgrade_to_shared_unmocked || OVERALL_EXIT=$? ;;' \
  "dispatches standalone B7 lane to run_one_lane"
assert_both_dispatch_contains 'run_one_lane upgrade_to_shared_unmocked || OVERALL_EXIT=$?' \
  "both lane includes B7 upgrade_to_shared_unmocked"
assert_b21_case_contains 'spec_file="tests/e2e-ui/full/auth-end-effects.spec.ts"' \
  "maps B21 lane to auth-end-effects spec"
assert_b21_case_contains '--project=chromium:email-verification' \
  "B21 lane selects the email-verification project"
assert_b21_case_contains '--grep "valid verification token shows success heading and login CTA @p0_coverage"' \
  "B21 lane selects the exact verification test title"
assert_b21_case_contains '--reporter=list' "B21 lane uses the list reporter"
assert_source_contains 'b21_verify_email) run_one_lane b21_verify_email || OVERALL_EXIT=$? ;;' \
  "dispatches standalone B21 lane to run_one_lane"
assert_b21_dispatch_absent
assert_both_dispatches_exact_lanes
# Launches the API directly so this evidence lane owns its SSM-hydrated proof
# env and pinned ports. Clearing STRIPE_LOCAL_MODE is what makes the real
# Stripe client engage.
assert_source_contains 'cargo run --manifest-path infra/Cargo.toml -p api' "launches the API via direct cargo run"
assert_source_contains 'unset STRIPE_LOCAL_MODE' "clears STRIPE_LOCAL_MODE for real Stripe"
# Always tears down on exit; only its own PIDs.
assert_source_contains 'trap cleanup EXIT' "installs an EXIT teardown trap"
assert_helper_defined_before_lane_stack_branch 'terminate_pid_tree' \
  "timeout teardown helper is shared by stack and no-stack lanes"
assert_source_absent 'killall' "never uses killall"
assert_source_absent 'pkill' "never uses pkill"
# Pins all ports the config would otherwise cwd-hash.
assert_source_contains 'PLAYWRIGHT_WEB_PORT' "pins web port"
assert_source_contains 'PLAYWRIGHT_API_PORT' "pins api port"
assert_source_contains 'PLAYWRIGHT_FLAPJACK_PORT' "pins flapjack port"

echo ""
echo "run_browser_lane_locally_test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
