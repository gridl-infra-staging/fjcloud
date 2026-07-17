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

# --- Existence / executability -------------------------------------------
[ -f "$TARGET" ] && pass "launcher exists" || { fail "launcher missing at $TARGET"; echo "1 fatal"; exit 1; }
[ -x "$TARGET" ] && pass "launcher is executable" || fail "launcher not executable"
if bash -n "$TARGET"; then pass "launcher parses (bash -n)"; else fail "launcher has a syntax error"; fi

# --- Argument handling (returns before any stack/SSM work) ---------------
assert_exit_code 0  "--help exits 0"                     bash "$TARGET" --help
assert_exit_code 64 "missing --lane exits 64"            bash "$TARGET"
assert_exit_code 64 "unknown --lane value exits 64"      bash "$TARGET" --lane bogus_lane
assert_exit_code 64 "unknown flag exits 64"              bash "$TARGET" --nope
# --help must document the three lanes.
help_out="$(bash "$TARGET" --help 2>&1)"
case "$help_out" in
  *signup_to_paid_invoice*billing_portal_payment_method_update*both*) pass "--help lists all three lanes" ;;
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
# Runs the specs with the required flags.
assert_source_contains '--no-deps' "runs Playwright with --no-deps"
assert_source_contains '--reporter=list' "runs Playwright with --reporter=list"
assert_source_contains '--trace on' "runs Playwright with --trace on"
# Launches the API directly (NOT api-dev.sh) so our SSM pk_test wins over the
# .env.local pk_live_ that api-dev.sh would force. Clearing STRIPE_LOCAL_MODE is
# what makes the real Stripe client engage.
assert_source_contains 'cargo run --manifest-path infra/Cargo.toml -p api' "launches the API via direct cargo run"
assert_source_contains 'unset STRIPE_LOCAL_MODE' "clears STRIPE_LOCAL_MODE for real Stripe"
# Always tears down on exit; only its own PIDs.
assert_source_contains 'trap cleanup EXIT' "installs an EXIT teardown trap"
assert_source_absent 'killall' "never uses killall"
assert_source_absent 'pkill' "never uses pkill"
# Pins all ports the config would otherwise cwd-hash.
assert_source_contains 'PLAYWRIGHT_WEB_PORT' "pins web port"
assert_source_contains 'PLAYWRIGHT_API_PORT' "pins api port"
assert_source_contains 'PLAYWRIGHT_FLAPJACK_PORT' "pins flapjack port"

echo ""
echo "run_browser_lane_locally_test: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ]
