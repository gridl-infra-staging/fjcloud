#!/usr/bin/env bash
# Contract tests for scripts/probe_browser_stack_exclusive.sh.
#
# The defect this probe replaces was a guard that could never pass. These tests
# therefore assert BOTH directions with live specimens: the probe must report
# free when nothing holds the resource, and it must report held when something
# does. A test that only asserted the free direction would reproduce the
# original defect in mirror image.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_browser_stack_exclusive.sh"

WORK_DIR="$(mktemp -d)"
# One scalar, not an array: macOS ships bash 3.2, where ${arr[-1]} is a syntax
# error rather than the last element. Only one fake holder is ever live at once.
FAKE_PID=""
cleanup() {
    if [ -n "$FAKE_PID" ]; then
        kill "$FAKE_PID" 2>/dev/null || true
        # Reap it here, or the shell prints a "Terminated" job notice after the
        # totals line and a clean pass looks like a crash.
        wait "$FAKE_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
    return 0
}
trap cleanup EXIT

pass=0
fail=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "PASS: $name"
        pass=$((pass + 1))
    else
        echo "FAIL: $name (expected '$expected', got '$actual')" >&2
        fail=$((fail + 1))
    fi
}

# Use an engine port no real stack binds, so the port signal cannot make these
# tests depend on whatever else is running on the host.
export FJCLOUD_ENGINE_PORT=65533

# --- 1. Free when nothing holds it -----------------------------------------
rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "free: exit 0" "0" "$rc"
check "free: holders=0" "holders=0" "$(printf '%s\n' "$out" | grep -o 'holders=[0-9]*')"

# --- 2. Held when a real local-dev-up.sh invocation exists ------------------
# Fail-capability proof. `bash <path>/scripts/local-dev-up.sh` is the exact argv
# shape the probe anchors on.
mkdir -p "$WORK_DIR/fakestack/scripts"
printf '#!/usr/bin/env bash\nsleep 30\n' > "$WORK_DIR/fakestack/scripts/local-dev-up.sh"
bash "$WORK_DIR/fakestack/scripts/local-dev-up.sh" &
FAKE_PID="$!"
sleep 1

rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "held: exit 1" "1" "$rc"
check "held: holders=1" "holders=1" "$(printf '%s\n' "$out" | grep -o 'holders=[0-9]*')"
check "held: names the holder" "yes" \
    "$(printf '%s\n' "$out" | grep -q 'HOLDER local-stack:' && echo yes || echo no)"

kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
sleep 1

# --- 3. Free again once the holder exits ------------------------------------
rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "released: exit 0" "0" "$rc"
check "released: holders=0" "holders=0" "$(printf '%s\n' "$out" | grep -o 'holders=[0-9]*')"

# --- 3b. The other three stack starters named by the ownership rule ---------
# CLAUDE.md "Local Stack Ownership" names four starters: local_demo.sh,
# local-dev-up.sh, web-dev.sh, api-dev.sh. Orchestration stage-close checks ask
# for "0 owned stack processes" across local-dev-up|web-dev|api-dev, so a probe
# that modelled only local-dev-up.sh would report free while a lane's web or api
# server was still up, and the lane would close its stage on a false clean.
#
# These three cases are the fail-capability proof for the widened
# DEV_STACK_PATTERN. 984788683 shipped that widening with only a HOLDER-label
# rename on this file, leaving the new behavior with no assertion at all; the
# pattern could have been reverted to local-dev-up.sh alone and every test here
# would still have passed.
for starter in web-dev.sh api-dev.sh local_demo.sh; do
    printf '#!/usr/bin/env bash\nsleep 30\n' > "$WORK_DIR/fakestack/scripts/$starter"
    bash "$WORK_DIR/fakestack/scripts/$starter" &
    FAKE_PID="$!"
    sleep 1

    rc=0
    out="$("$PROBE" 2>&1)" || rc=$?
    check "$starter: exit 1 (held)" "1" "$rc"
    check "$starter: holders=1" "holders=1" \
        "$(printf '%s\n' "$out" | grep -o 'holders=[0-9]*')"

    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
    sleep 1
done

# --- 4. Stage-prompt text must NOT register as a holder ---------------------
# This is the original defect. A process whose arguments merely contain the
# words "playwright" and "local-dev-up" — exactly what a worker's stage prompt
# looks like — must not be counted.
# The decoy must actually STAY ALIVE while the probe runs, or this test passes
# vacuously. `bash -c <cmd> <name>` puts <name> in argv, so the specimen both
# carries the trigger words and survives the probe.
# The trigger words go inside the `-c` script text, which IS argv[2] and stays
# in `ps` output. Passing them as $0 does not work: `bash -c 'sleep 30' NAME`
# execs straight into `sleep`, and the decoy vanishes from argv.
DECOY_ARGV="run playwright against the stack started by scripts/local-dev-up.sh"
/bin/sh -c "while :; do sleep 1; done # $DECOY_ARGV" &
FAKE_PID="$!"
sleep 1

# Assert the decoy is live and really does carry the words, so a silently-dead
# specimen can never be mistaken for a passing test.
check "prompt text: decoy is alive" "yes" \
    "$(kill -0 "$FAKE_PID" 2>/dev/null && echo yes || echo no)"
# Snapshot `ps`, then match with a shell `case` — no pipe at all. Under
# `pipefail`, ANY `... | grep -q` succeeds so fast that it closes the pipe and
# SIGPIPEs the producer, making the pipeline report 141: a CORRECT match reads
# as a failure. Same hazard the orchestrations call out for `git | grep`, and it
# bit this very assertion twice before being removed rather than worked around.
PS_SNAPSHOT="$(ps -axo args=)"
case "$PS_SNAPSHOT" in
    *"$DECOY_ARGV"*) decoy_visible=yes ;;
    *)               decoy_visible=no ;;
esac
check "prompt text: decoy argv carries the trigger words" "yes" "$decoy_visible"

rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "prompt text: exit 0 (not a holder)" "0" "$rc"
check "prompt text: holders=0" "holders=0" "$(printf '%s\n' "$out" | grep -o 'holders=[0-9]*')"

# The superseded inline probe is asserted to be wrong on this same specimen, so
# nobody reintroduces it believing it was adequate.
legacy_count="$(ps -axo args= | grep -cE 'local-dev-up|playwright' || true)"
check "prompt text: superseded inline probe is fooled" "yes" \
    "$([ "$legacy_count" -gt 0 ] && echo yes || echo no)"

kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

echo
echo "Totals: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
