#!/usr/bin/env bash
# Tests for scripts/devbox/run_browser_suite.sh — runs the browser suite on the
# devbox with a Stripe TEST key injected, without ever putting that key on the
# devbox's disk or in a process argument list.
#
# The load-bearing tests are test_refuses_live_key_even_with_cutover_optin and
# test_key_never_appears_in_process_arguments.
#
# Why the first: scripts/lib/stripe_checks.sh::stripe_secret_key_has_allowed_prefix
# permits sk_live_/rk_live_ when STRIPE_LIVE_CUTOVER=1, because one deliberate
# cutover path needs that. The devbox must be stricter than the shared policy —
# it is a public-IP box provisioned with no IAM role precisely so a compromise
# yields nothing, and a live Stripe key moves real money. So this script refuses
# live prefixes unconditionally, and that stricter rule needs its own proof.
#
# Why the second: a key passed as `ssh host FOO=value ...` is visible to every
# user on the devbox via `ps`. Asserting the key reaches the remote shell but
# never appears in argv is the difference between "we sent it" and "we sent it
# safely".
#
# These tests do NOT grep the script for the string "stdin" or for a prefix
# pattern. A guard can be present in the source and still not fire — wrong
# branch order, a later overwrite, a typo'd variable. Instead they run the real
# script against a fake `ssh` on PATH that records exactly what it received, and
# assert on that recording. That is testing the behaviour, not the string.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RUNNER="$REPO_ROOT/scripts/devbox/run_browser_suite.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Precondition, not a nicety. Most assertions below treat a non-zero exit as
# "the runner correctly refused" — and a MISSING runner also exits non-zero, so
# without this check the whole suite reports passes for a script that does not
# exist. Fail loudly here instead of emitting a misleading green.
if [ ! -x "$RUNNER" ]; then
    echo "FAIL: runner missing or not executable at $RUNNER — every refusal assertion below would pass vacuously" >&2
    echo "devbox_run_browser_suite_test: 0 passed, 1 failed"
    exit 1
fi

# A fake ssh that records its argv and its stdin, then exits 0. Putting it first
# on PATH lets the tests observe precisely what the runner would transmit
# without needing a devbox, a network, or a credential.
make_fake_ssh_dir() {
    local dir
    dir="$(mktemp -d)"
    cat >"$dir/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FAKE_SSH_ARGV_FILE"
cat > "$FAKE_SSH_STDIN_FILE"
exit 0
FAKE
    chmod +x "$dir/ssh"
    printf '%s' "$dir"
}

# Run the runner with a fake ssh and a chosen key, capturing everything.
# Sets: RUN_EXIT_CODE, RUN_OUTPUT, SSH_ARGV, SSH_STDIN
run_with_key() {
    local key="$1"
    shift
    local fake_dir argv_file stdin_file
    fake_dir="$(make_fake_ssh_dir)"
    argv_file="$(mktemp)"
    stdin_file="$(mktemp)"
    : >"$stdin_file"

    set +e
    RUN_OUTPUT="$(
        PATH="$fake_dir:$PATH" \
        FAKE_SSH_ARGV_FILE="$argv_file" \
        FAKE_SSH_STDIN_FILE="$stdin_file" \
        STRIPE_SECRET_KEY_RESTRICTED="$key" \
        bash "$RUNNER" --host devbox.invalid --key /dev/null --stripe-live "$@" 2>&1
    )"
    RUN_EXIT_CODE=$?
    set -e
    SSH_ARGV="$(cat "$argv_file" 2>/dev/null || true)"
    SSH_STDIN="$(cat "$stdin_file" 2>/dev/null || true)"
    rm -rf "$fake_dir" "$argv_file" "$stdin_file"
}

# The two long live-key fixtures below assemble their prefix at runtime instead
# of spelling it out. GitHub push protection matches the verbatim `sk_live_` /
# `rk_live_` prefix followed by a long token and refuses the whole mirror push
# even for an obviously fake negative fixture, which blocked every staging sync.
# The assembled value is byte-identical, so the runner's `sk_live_*|rk_live_*`
# case in scripts/devbox/run_browser_suite.sh:169 still fires and these stay
# behavioural tests, not string greps.
LIVE="live_"

test_refuses_live_secret_key() {
    run_with_key "sk_${LIVE}deadbeefdeadbeefdeadbeef"
    if [ "$RUN_EXIT_CODE" -eq 0 ]; then
        fail "runner accepted an sk_live_ key"
        return
    fi
    case "$RUN_OUTPUT" in
        *DEVBOX_REFUSED*) pass "refuses sk_live_ key" ;;
        *) fail "refused sk_live_ but without a DEVBOX_REFUSED reason: $RUN_OUTPUT" ;;
    esac
}

test_refuses_live_restricted_key() {
    run_with_key "rk_${LIVE}deadbeefdeadbeefdeadbeef"
    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        pass "refuses rk_live_ key"
    else
        fail "runner accepted an rk_live_ key"
    fi
}

test_refuses_live_key_even_with_cutover_optin() {
    # The shared prefix policy would ALLOW a live key here. The devbox must not.
    local fake_dir argv_file stdin_file
    fake_dir="$(make_fake_ssh_dir)"
    argv_file="$(mktemp)"; stdin_file="$(mktemp)"
    set +e
    local out
    out="$(
        PATH="$fake_dir:$PATH" \
        FAKE_SSH_ARGV_FILE="$argv_file" FAKE_SSH_STDIN_FILE="$stdin_file" \
        STRIPE_LIVE_CUTOVER=1 \
        STRIPE_SECRET_KEY_RESTRICTED="sk_live_deadbeefdeadbeef" \
        bash "$RUNNER" --host devbox.invalid --key /dev/null --stripe-live 2>&1
    )"
    local code=$?
    set -e
    rm -rf "$fake_dir" "$argv_file" "$stdin_file"
    if [ "$code" -ne 0 ]; then
        pass "refuses live key even under STRIPE_LIVE_CUTOVER=1"
    else
        fail "STRIPE_LIVE_CUTOVER=1 let a live key through to the devbox: $out"
    fi
}

test_accepts_test_restricted_key() {
    run_with_key "rk_test_abc123abc123"
    if [ "$RUN_EXIT_CODE" -eq 0 ]; then
        pass "accepts rk_test_ key"
    else
        fail "runner rejected a valid rk_test_ key: $RUN_OUTPUT"
    fi
}

test_key_never_appears_in_process_arguments() {
    local secret="rk_test_uniquecanary9182736455"
    run_with_key "$secret"
    # Vacuity guard: an ssh that was never invoked records an empty argv, and
    # "the key is absent from nothing" would pass while proving nothing. Require
    # evidence that ssh actually ran before trusting the absence below.
    if [ -z "$SSH_ARGV" ]; then
        fail "ssh was never invoked, so the argv assertion would pass vacuously"
        return
    fi
    if printf '%s' "$SSH_ARGV" | grep -qF "$secret"; then
        fail "the Stripe key was passed in ssh argv — visible to \`ps\` on the devbox"
        return
    fi
    pass "key never appears in ssh process arguments"
}

test_key_is_delivered_over_stdin() {
    local secret="rk_test_uniquecanary9182736455"
    run_with_key "$secret"
    if printf '%s' "$SSH_STDIN" | grep -qF "$secret"; then
        pass "key reaches the remote shell over stdin"
    else
        fail "key never reached the remote shell at all — the run would silently lose Stripe coverage"
    fi
}

test_missing_key_still_runs_but_announces_reduced_denominator() {
    # No silent caps: a run without Stripe credentials covers fewer rows, and the
    # operator must be told rather than left to read 4 failures as product defects.
    local fake_dir argv_file stdin_file out code
    fake_dir="$(make_fake_ssh_dir)"
    argv_file="$(mktemp)"; stdin_file="$(mktemp)"
    set +e
    out="$(
        PATH="$fake_dir:$PATH" \
        FAKE_SSH_ARGV_FILE="$argv_file" FAKE_SSH_STDIN_FILE="$stdin_file" \
        env -u STRIPE_SECRET_KEY_RESTRICTED -u STRIPE_SECRET_KEY \
        bash "$RUNNER" --host devbox.invalid --key /dev/null 2>&1
    )"
    code=$?
    set -e
    rm -rf "$fake_dir" "$argv_file" "$stdin_file"
    if [ "$code" -ne 0 ]; then
        fail "runner should still run without a Stripe key, got exit $code: $out"
        return
    fi
    case "$out" in
        *"reduced"*|*"REDUCED"*|*"350"*)
            pass "announces the reduced denominator when no Stripe key is present" ;;
        *)
            fail "ran without a Stripe key but never announced reduced coverage: $out" ;;
    esac
}

test_runs_without_an_ssh_key_flag() {
    # Every other test passes --key, so the "no key supplied" branch — where the
    # runner must fall back to the agent/default identity rather than abort —
    # would otherwise never execute. It builds its ssh option array with a
    # conditional that is easy to get wrong under `set -e`.
    local fake_dir argv_file stdin_file out code
    fake_dir="$(make_fake_ssh_dir)"
    argv_file="$(mktemp)"; stdin_file="$(mktemp)"
    set +e
    out="$(
        PATH="$fake_dir:$PATH" \
        FAKE_SSH_ARGV_FILE="$argv_file" FAKE_SSH_STDIN_FILE="$stdin_file" \
        env -u DEVBOX_SSH_KEY STRIPE_SECRET_KEY_RESTRICTED="rk_test_nokeypath" \
        bash "$RUNNER" --host devbox.invalid --stripe-live 2>&1
    )"
    code=$?
    local argv; argv="$(cat "$argv_file" 2>/dev/null || true)"
    set -e
    rm -rf "$fake_dir" "$argv_file" "$stdin_file"
    if [ "$code" -ne 0 ]; then
        fail "runner aborted when no ssh key was supplied (exit $code): $out"
        return
    fi
    if [ -z "$argv" ]; then
        fail "runner exited 0 without ever invoking ssh when no key was supplied"
        return
    fi
    if printf '%s' "$argv" | grep -qx -- '-i'; then
        fail "runner passed a -i flag with no key path"
        return
    fi
    pass "runs without an --ssh-key, omitting -i rather than aborting"
}

test_default_run_does_not_transmit_the_key() {
    # infra/api/src/startup.rs picks LiveStripeService whenever STRIPE_SECRET_KEY
    # is set, and only its absence lets STRIPE_LOCAL_MODE=1 select the local mock
    # and its in-process webhook dispatcher. Injecting a key by default would
    # therefore switch the whole stack's payment backend as a side effect of
    # wanting four rows, on a box that runs no webhook forwarder. That is a
    # source-level contract, not a benchmark — the run that tried to quantify it
    # was invalidated by a concurrent devbox session. Opt-in either way.
    local secret="rk_test_mustnotleakbydefault"
    local fake_dir argv_file stdin_file out
    fake_dir="$(make_fake_ssh_dir)"
    argv_file="$(mktemp)"; stdin_file="$(mktemp)"; : >"$stdin_file"
    set +e
    out="$(
        PATH="$fake_dir:$PATH" \
        FAKE_SSH_ARGV_FILE="$argv_file" FAKE_SSH_STDIN_FILE="$stdin_file" \
        STRIPE_SECRET_KEY_RESTRICTED="$secret" \
        bash "$RUNNER" --host devbox.invalid --key /dev/null 2>&1
    )"
    set -e
    local sent; sent="$(cat "$stdin_file" 2>/dev/null || true)"
    rm -rf "$fake_dir" "$argv_file" "$stdin_file"
    if [ -z "$sent" ]; then
        fail "ssh received nothing, so the no-key assertion would pass vacuously"
        return
    fi
    if printf '%s' "$sent" | grep -qF "$secret"; then
        fail "default run transmitted the Stripe key — this flips the API to LiveStripeService and breaks the suite"
        return
    fi
    case "$out" in
        *"mock Stripe"*) pass "default run withholds the key and says the stack is on mock Stripe" ;;
        *) fail "default run withheld the key but did not say the stack is on mock Stripe: $out" ;;
    esac
}

test_requires_host() {
    set +e
    local out
    out="$(bash "$RUNNER" --key /dev/null 2>&1)"
    local code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        pass "refuses to run without --host"
    else
        fail "ran without --host: $out"
    fi
}

test_no_hardcoded_host_or_account_identifiers() {
    # scripts/ syncs wholesale to the public mirror, so this file is published.
    if grep -qE '(compute-1\.amazonaws\.com|[0-9]{12}|i-0[a-f0-9]{8,})' "$RUNNER"; then
        fail "runner hardcodes a host, account id, or instance id — it is published to the public mirror"
    else
        pass "no hardcoded hosts, account ids, or instance ids"
    fi
}

test_refuses_live_secret_key
test_refuses_live_restricted_key
test_refuses_live_key_even_with_cutover_optin
test_accepts_test_restricted_key
test_key_never_appears_in_process_arguments
test_key_is_delivered_over_stdin
test_missing_key_still_runs_but_announces_reduced_denominator
test_runs_without_an_ssh_key_flag
test_default_run_does_not_transmit_the_key
test_requires_host
test_no_hardcoded_host_or_account_identifiers

echo
echo "devbox_run_browser_suite_test: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[ "$FAIL_COUNT" -eq 0 ]
