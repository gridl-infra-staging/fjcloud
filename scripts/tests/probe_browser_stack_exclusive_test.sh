#!/usr/bin/env bash
# Contract tests for scripts/probe_browser_stack_exclusive.sh.
#
# The defect this probe replaces was a guard that could never pass. These tests
# therefore assert BOTH directions with live specimens: the probe must report
# free when nothing holds the resource, and it must report held when something
# does. A test that only asserted the free direction would reproduce the
# original defect in mirror image.
#
# HOST-CONCURRENCY SAFETY. The probe is a host-wide oracle: its DEV_STACK_PATTERN
# matches ANY worker's local-dev-up/web-dev/api-dev/local_demo starter on this
# shared host, so a co-resident lane's real stack is a legitimate holder the
# probe must report. Asserting an absolute `holders=0` baseline therefore made
# every case false-red whenever another lane held the resource, even though the
# probe was behaving correctly. This contract gives the production probe a
# test-scoped `ps` seam that retains only real processes under this test's
# unique temp root (plus the nested arm's external specimen). It then measures
# the resulting baseline and asserts exact deltas for only the holders this
# test owns: a live starter must read baseline+1, and killing it must return to
# baseline. The port signal is independently isolated to an unused port.

set -euo pipefail

# Negative-specimen hook, installed before this run forks anything so the whole
# owned subtree inherits it: SIG_IGN survives fork and exec. When the nested arm
# asks for the TERM-ignoring specimen, neither the nested child nor any process
# it starts may die from SIGTERM, so only the timeout cleanup's KILL escalation
# can end the run. Without this specimen, a TERM-only cleanup looks correct.
if [ "${FJCLOUD_EXCLUSIVE_TEST_NESTED:-0}" = "1" ] \
    && [ "${FJCLOUD_EXCLUSIVE_TEST_TERM_IGNORING_SPECIMEN:-0}" = "1" ]; then
    trap '' TERM
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_browser_stack_exclusive.sh"

resolve_system_ps() {
    local system_ps=""
    local candidate=""

    for candidate in /bin/ps /usr/bin/ps; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    system_ps="${FJCLOUD_EXCLUSIVE_TEST_REAL_PS:-}"
    if [ -n "$system_ps" ] && [ -x "$system_ps" ]; then
        printf '%s\n' "$system_ps"
        return 0
    fi

    system_ps="$(command -p -v ps 2>/dev/null || true)"
    if [ -z "$system_ps" ]; then
        system_ps="$(command -v ps)"
    fi
    if [ -z "$system_ps" ] || [ ! -x "$system_ps" ]; then
        echo "FATAL: unable to resolve a runnable system ps binary" >&2
        exit 1
    fi
    printf '%s\n' "$system_ps"
}

WORK_DIR="$(mktemp -d)"
SYSTEM_PS="$(resolve_system_ps)"
# Pin the seam to the host's system ps. The env var exists only so the shim and
# nested child can reuse this already-resolved safe path after PATH is modified.
REAL_PS="$SYSTEM_PS"
# One scalar, not an array: macOS ships bash 3.2, where ${arr[-1]} is a syntax
# error rather than the last element. Only one fake holder is ever live at once.
FAKE_PID=""
# The nested pre-existing-holder arm starts one holder OUTSIDE the FAKE_PID
# lifecycle (it must stay alive across a full nested suite run), tracked in its
# own scalar so an abort mid-arm cannot leak a ps-visible specimen into another
# lane's view.
EXTERNAL_PID=""
cleanup() {
    if [ -n "$FAKE_PID" ]; then
        kill "$FAKE_PID" 2>/dev/null || true
        # Reap it here, or the shell prints a "Terminated" job notice after the
        # totals line and a clean pass looks like a crash.
        wait "$FAKE_PID" 2>/dev/null || true
    fi
    if [ -n "$EXTERNAL_PID" ]; then
        kill "$EXTERNAL_PID" 2>/dev/null || true
        wait "$EXTERNAL_PID" 2>/dev/null || true
    fi
    rm -rf "$WORK_DIR"
    return 0
}
trap cleanup EXIT

# The production probe intentionally asks a host-wide question, while this
# contract shares the host with unrelated workers that may start or stop a real
# stack between two assertions. Filter the probe's `ps` input by this test's
# unguessable temp ownership root so those unrelated transitions cannot race an
# exact delta. The nested child additionally admits the outer arm's root, which
# preserves a real pre-existing-holder specimen. Other `ps` calls in this file
# bypass the shim through REAL_PS so liveness and legacy-decoy checks still see
# the actual host process table.
#
# The filter is one `grep -F`, not a per-line bash loop. Measured on a host with
# ~1300 processes, the loop cost 2.0s per shim call against 0.14s for the raw
# `ps` it wrapped, and one nested run makes ~40 shim calls; that 14x tax, not the
# probe itself, is what pushed the nested wall clock past its bound under normal
# co-resident load. Both roots are absolute paths, so fixed-string matching is
# the same predicate the loop's `case` globs applied.
PS_SHIM_DIR="$WORK_DIR/bin"
mkdir -p "$PS_SHIM_DIR"
pass=0
fail=0
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'real_ps="$FJCLOUD_EXCLUSIVE_TEST_REAL_PS"' \
    'if [ "${FJCLOUD_EXCLUSIVE_TEST_RECURSIVE_PS_SPECIMEN:-0}" = "1" ]; then' \
    '    if [ "${FJCLOUD_EXCLUSIVE_TEST_TERM_IGNORING_SPECIMEN:-0}" = "1" ]; then' \
    '        trap "" TERM' \
    '    fi' \
    '    if [ "${FJCLOUD_EXCLUSIVE_TEST_RECURSIVE_PS_DEPTH:-0}" = "0" ]; then' \
    '        FJCLOUD_EXCLUSIVE_TEST_RECURSIVE_PS_DEPTH=1 "$0" "$@"' \
    '        exit $?' \
    '    fi' \
    '    sleep 3600' \
    '    exit 0' \
    'fi' \
    'owned_root="$FJCLOUD_EXCLUSIVE_TEST_OWNED_ROOT"' \
    'external_root="${FJCLOUD_EXCLUSIVE_TEST_EXTERNAL_ROOT:-}"' \
    'if [ -n "$external_root" ]; then' \
    '    "$real_ps" "$@" | grep -F -e "$owned_root" -e "$external_root" || true' \
    'else' \
    '    "$real_ps" "$@" | grep -F -e "$owned_root" || true' \
    'fi' \
    'exit 0' > "$PS_SHIM_DIR/ps"
chmod +x "$PS_SHIM_DIR/ps"

resolved_after_shim="$(PATH="$PS_SHIM_DIR:$PATH" resolve_system_ps)"
if [ "$SYSTEM_PS" = "$resolved_after_shim" ]; then
    echo "PASS: system ps resolver ignores shimmed PATH"
    pass=$((pass + 1))
else
    echo "FAIL: system ps resolver ignores shimmed PATH (expected '$SYSTEM_PS', got '$resolved_after_shim')" >&2
    fail=$((fail + 1))
fi
export FJCLOUD_EXCLUSIVE_TEST_REAL_PS="$REAL_PS"
export FJCLOUD_EXCLUSIVE_TEST_OWNED_ROOT="$WORK_DIR/fakestack"
export PATH="$PS_SHIM_DIR:$PATH"

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

# Wall clock for the healthy nested run, which re-runs every outer section and
# so costs ~22s on an idle host with ~1300 processes. A co-resident lane's load
# was measured amplifying that by ~5x, and this bound only has to contain an
# indefinite hang, not police performance: budget ~8x the idle baseline. A
# tighter bound false-reds the positive direction, which is the worse failure —
# the leaked-writer specimens carry their own fail-fast bound below.
NESTED_POSITIVE_TIMEOUT_SECONDS=180
# Wall clock for the leaked-writer specimens. These hang on their first probe
# call, so they never need the healthy run's budget.
NESTED_SPECIMEN_TIMEOUT_SECONDS=5
# How long a timed-out nested run may keep running after SIGTERM before this
# suite escalates to SIGKILL. Short on purpose: the grace exists so a cooperative
# child can run its own EXIT trap, not so an uncooperative one can stall us.
NESTED_TERM_GRACE_SECONDS=2
# Upper bound on one whole timed-out nested run, derived from its parts rather
# than pinned as a magic number: the specimen's own wall clock, the TERM grace,
# and slack for the descendant snapshots and reaping poll on a loaded host.
# Tight enough that a regression to an unbounded wait reports as a failed check.
NESTED_CLEANUP_UPPER_BOUND_SECONDS=$((NESTED_SPECIMEN_TIMEOUT_SECONDS + NESTED_TERM_GRACE_SECONDS + 8))
# PIDs the last timeout cleanup owned, published so the arm can assert none of
# them survived the escalation.
nested_owned_pids=""

nested_descendant_pids() {
    local root_pid="$1"
    local frontier="$root_pid"
    local descendants=""
    local snapshot=""
    local next_frontier=""
    local parent=""
    local pid=""
    local current_parent=""

    snapshot="$("$REAL_PS" -axo pid=,ppid= 2>/dev/null || true)"
    while [ -n "$frontier" ]; do
        next_frontier=""
        for current_parent in $frontier; do
            while read -r pid parent; do
                if [ "$parent" = "$current_parent" ]; then
                    descendants="$descendants $pid"
                    next_frontier="$next_frontier $pid"
                fi
            done <<EOF
$snapshot
EOF
        done
        frontier="$next_frontier"
    done
    printf '%s\n' "$descendants"
}

# Tear down a timed-out nested run within a bounded budget, and publish the PIDs
# it owned in `nested_owned_pids` so the caller can assert none survived.
#
# SIGTERM alone cannot bound this path: a nested child that ignores TERM keeps
# the trailing `wait` blocked forever, which reproduces the very hang the
# wall-clock bound exists to prevent. The grace period is therefore capped and
# always followed by SIGKILL, which no process can catch or ignore, so `wait` is
# guaranteed to return. The descendant snapshot must be taken while the child is
# still alive: once it dies its children reparent to init and are no longer
# reachable from child_pid, which is how TERM-only cleanup leaked the recursive
# `ps` shim chain onto the host.
terminate_nested_child() {
    local child_pid="$1"
    local waited=0
    local pid=""

    nested_owned_pids="$child_pid $(nested_descendant_pids "$child_pid")"
    kill $nested_owned_pids 2>/dev/null || true

    while [ "$waited" -lt "$NESTED_TERM_GRACE_SECONDS" ]; do
        if ! nested_child_is_active "$child_pid"; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    # Anything the child started during the grace period is still this arm's to
    # clean up, so re-snapshot before escalating rather than trusting the first
    # reading. Dedupe so a PID is not signalled twice.
    for pid in $(nested_descendant_pids "$child_pid"); do
        case " $nested_owned_pids " in
            *" $pid "*) ;;
            *) nested_owned_pids="$nested_owned_pids $pid" ;;
        esac
    done

    kill -KILL $nested_owned_pids 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
}

# Answer "did the escalation actually clear the tree?" within a bound. Polling is
# required because a SIGKILLed descendant is not this shell's child, so it stays
# visible for the moment it takes init to reap it. Returning "no" on expiry keeps
# a survivor a reported failure rather than a hang.
nested_owned_pids_all_gone() {
    local deadline_seconds="$1"
    local waited=0
    local pid=""
    local survivor=""

    while :; do
        survivor=""
        for pid in $nested_owned_pids; do
            if kill -0 "$pid" 2>/dev/null; then
                survivor="$pid"
                break
            fi
        done
        if [ -z "$survivor" ]; then
            printf 'yes\n'
            return 0
        fi
        if [ "$waited" -ge "$deadline_seconds" ]; then
            printf 'no\n'
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

nested_child_is_active() {
    local child_pid="$1"
    local state=""

    if ! kill -0 "$child_pid" 2>/dev/null; then
        return 1
    fi
    state="$("$REAL_PS" -p "$child_pid" -o stat= 2>/dev/null || true)"
    set -- $state
    state="${1:-}"
    if [ -z "$state" ]; then
        return 1
    fi
    case "$state" in
        Z*) return 1 ;;
        *)  return 0 ;;
    esac
}

# Launch one nested run of this suite under a wall-clock bound.
#
# `specimen_mode` selects the negative specimen the nested child runs under:
#   none                       — an ordinary nested run
#   recursive_ps               — the leaked-writer recursion from Stage 1
#   recursive_ps_term_ignoring — the same recursion, with the whole owned subtree
#                                immune to SIGTERM
run_nested_suite() {
    local name="$1"
    local external_root="$2"
    local specimen_mode="$3"
    local timeout_seconds="$4"
    local stdout_file="$WORK_DIR/${name}.stdout"
    local stderr_file="$WORK_DIR/${name}.stderr"
    local child_pid=""
    local elapsed=0
    local recursive_ps_specimen=0
    local term_ignoring_specimen=0

    case "$specimen_mode" in
        none)                       ;;
        recursive_ps)               recursive_ps_specimen=1 ;;
        recursive_ps_term_ignoring) recursive_ps_specimen=1; term_ignoring_specimen=1 ;;
        *)
            echo "FATAL: unknown nested specimen mode '$specimen_mode'" >&2
            exit 1
            ;;
    esac

    nested_out=""
    nested_run_status="exit"
    nested_rc=0
    nested_owned_pids=""

    FJCLOUD_EXCLUSIVE_TEST_NESTED=1 \
        FJCLOUD_EXCLUSIVE_TEST_EXTERNAL_ROOT="$external_root" \
        FJCLOUD_EXCLUSIVE_TEST_RECURSIVE_PS_SPECIMEN="$recursive_ps_specimen" \
        FJCLOUD_EXCLUSIVE_TEST_TERM_IGNORING_SPECIMEN="$term_ignoring_specimen" \
        bash "$0" >"$stdout_file" 2>"$stderr_file" &
    child_pid="$!"

    while nested_child_is_active "$child_pid"; do
        if [ "$elapsed" -ge "$timeout_seconds" ]; then
            nested_run_status="timeout:$name"
            nested_rc=124
            terminate_nested_child "$child_pid"
            nested_out="$(cat "$stdout_file" "$stderr_file" 2>/dev/null || true)"
            return 124
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    wait "$child_pid" || nested_rc=$?
    nested_out="$(cat "$stdout_file" "$stderr_file" 2>/dev/null || true)"
    return "$nested_rc"
}

holder_count_token() {
    local input="$1"
    local line=""
    local token=""
    local canonical_count=0
    local malformed_count=0

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            holders=*)
                if [[ "$line" =~ ^holders=[0-9][0-9]*$ ]]; then
                    canonical_count=$((canonical_count + 1))
                    token="$line"
                else
                    malformed_count=$((malformed_count + 1))
                fi
                ;;
        esac
    done <<< "$input"

    if [ "$canonical_count" -eq 1 ] && [ "$malformed_count" -eq 0 ]; then
        printf '%s\n' "$token"
    else
        printf '%s\n' "__invalid_holders__"
    fi
}

expected_holders_token() {
    printf 'holders=%s\n' "$expected_holders"
}

expected_holders_plus_one_token() {
    printf 'holders=%s\n' "$((expected_holders + 1))"
}

expected_baseline_exit() {
    if [ "$expected_holders" -eq 0 ]; then
        printf '0\n'
    else
        printf '1\n'
    fi
}

check_stack_specimen_live_and_visible() {
    local name="$1" path="$2"
    local visible="no"

    check "$name: starter is alive" "yes" \
        "$(kill -0 "$FAKE_PID" 2>/dev/null && echo yes || echo no)"

    PS_SNAPSHOT="$("$REAL_PS" -axo args=)"
    case "$PS_SNAPSHOT" in
        *"$path"*) visible=yes ;;
        *)         visible=no ;;
    esac
    check "$name: starter argv is visible" "yes" "$visible"
}

# Keep the probe-visible `bash .../scripts/<starter>.sh` wrapper alive while
# ensuring the wrapper owns and reaps its sleep child. A plain `sleep N` script
# leaves that child behind when the test kills only the tracked wrapper PID;
# inside the nested command substitution, the orphan also keeps the output pipe
# open until N expires. The canonical reachability gate exposed that leak when
# the nested run outlived its separately timed external holder and false-red.
write_stack_specimen() {
    local path="$1"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'child_pid=""' \
        'cleanup_child() {' \
        '    trap - EXIT INT TERM' \
        '    if [ -n "$child_pid" ]; then' \
        '        kill "$child_pid" 2>/dev/null || true' \
        '        wait "$child_pid" 2>/dev/null || true' \
        '    fi' \
        '    exit 0' \
        '}' \
        'trap cleanup_child EXIT INT TERM' \
        'sleep 3600 &' \
        'child_pid="$!"' \
        'wait "$child_pid"' > "$path"
}

# Measure the admitted baseline THROUGH the probe rather than assuming it is
# zero. `expected_holders` becomes whatever the probe currently reports before
# this test starts any holder of its own; every later assertion is a delta off
# this reading. In the nested child, the admitted baseline includes the outer
# arm's separately owned external holder.
#
# The probe exits 1 whenever holders is nonzero, so the call MUST be guarded
# (`|| true`) — an unguarded `$("$PROBE")` would abort the whole suite under
# `set -euo pipefail` on exactly the host state this test exists to tolerate.
#
# Fail closed on an unparseable baseline: if holder_count_token cannot find
# exactly one canonical `holders=<int>` line, record a failed check, dump the
# raw probe output, and stop. Never fall through with a non-integer, which would
# crash `$((expected_holders + 1))` instead of reporting a real failure.
capture_expected_holders() {
    local context="$1"
    local out token
    out="$("$PROBE" 2>&1)" || true
    token="$(holder_count_token "$out")"
    if [ "$token" = "__invalid_holders__" ]; then
        check "$context: baseline probe emits exactly one canonical holders line" \
            "canonical" "__invalid_holders__"
        echo "FATAL: baseline probe output was unparseable; raw output follows:" >&2
        printf '%s\n' "$out" >&2
        echo "Totals: pass=$pass fail=$fail" >&2
        exit 1
    fi
    expected_holders="${token#holders=}"
    echo "baseline[$context]: expected_holders=$expected_holders"
}

# Use an engine port no real stack binds, so the port signal cannot make these
# tests depend on whatever else is running on the host.
export FJCLOUD_ENGINE_PORT=65533

# --- 1. Free when nothing holds it -----------------------------------------
# "Free" now means "at the measured baseline" — the host may legitimately hold
# the resource for a co-resident lane. Capture that baseline before any
# test-owned holder starts, then assert the probe reports it.
capture_expected_holders "free"
rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "free: baseline exit" "$(expected_baseline_exit)" "$rc"
check "free: expected holders" "$(expected_holders_token)" "$(holder_count_token "$out")"

# --- 2. Held when a real local-dev-up.sh invocation exists ------------------
# Fail-capability proof. `bash <path>/scripts/local-dev-up.sh` is the exact argv
# shape the probe anchors on.
mkdir -p "$WORK_DIR/fakestack/scripts"
LOCAL_DEV_UP_SPECIMEN="$WORK_DIR/fakestack/scripts/local-dev-up.sh"
write_stack_specimen "$LOCAL_DEV_UP_SPECIMEN"
# Re-capture immediately before this block: a co-resident lane may have started
# or stopped a stack since the last reading, and the delta must be measured off
# the baseline that is live right now, not a stale up-front one.
capture_expected_holders "held:local-dev-up"
bash "$LOCAL_DEV_UP_SPECIMEN" &
FAKE_PID="$!"
sleep 1

check_stack_specimen_live_and_visible "held" "$LOCAL_DEV_UP_SPECIMEN"
rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "held: exit 1" "1" "$rc"
check "held: holders increment by one" "$(expected_holders_plus_one_token)" "$(holder_count_token "$out")"
check "held: names the holder" "yes" \
    "$(printf '%s\n' "$out" | grep -q 'HOLDER local-stack:' && echo yes || echo no)"

kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""
sleep 1

# --- 3. Free again once the holder exits ------------------------------------
rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "released: baseline exit" "$(expected_baseline_exit)" "$rc"
check "released: holders return to expected" "$(expected_holders_token)" "$(holder_count_token "$out")"

# --- 3a. A matching starter outside the owned root stays excluded -----------
# The hermetic ps seam must reject a real holder owned by another lane, not
# merely admit this suite's holders. Without this negative specimen, replacing
# the shim with a pass-through would still pass whenever the host happened to
# have no other stack running.
UNRELATED_SPECIMEN="$WORK_DIR/unrelated/scripts/local-dev-up.sh"
mkdir -p "$(dirname "$UNRELATED_SPECIMEN")"
write_stack_specimen "$UNRELATED_SPECIMEN"
capture_expected_holders "unrelated holder"
bash "$UNRELATED_SPECIMEN" &
FAKE_PID="$!"
sleep 1

check_stack_specimen_live_and_visible "unrelated holder" "$UNRELATED_SPECIMEN"
PS_SHIM_SNAPSHOT="$("$PS_SHIM_DIR/ps" -axo args=)"
case "$PS_SHIM_SNAPSHOT" in
    *"$UNRELATED_SPECIMEN"*) unrelated_visible=yes ;;
    *)                        unrelated_visible=no ;;
esac
check "unrelated holder: ps shim excludes outside-root starter" "no" "$unrelated_visible"

rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "unrelated holder: baseline exit" "$(expected_baseline_exit)" "$rc"
check "unrelated holder: holders stay expected" \
    "$(expected_holders_token)" "$(holder_count_token "$out")"

kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

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
    STARTER_SPECIMEN="$WORK_DIR/fakestack/scripts/$starter"
    write_stack_specimen "$STARTER_SPECIMEN"
    capture_expected_holders "$starter"
    bash "$STARTER_SPECIMEN" &
    FAKE_PID="$!"
    sleep 1

    check_stack_specimen_live_and_visible "$starter" "$STARTER_SPECIMEN"
    rc=0
    out="$("$PROBE" 2>&1)" || rc=$?
    check "$starter: exit 1 (held)" "1" "$rc"
    check "$starter: holders increment by one" "$(expected_holders_plus_one_token)" \
        "$(holder_count_token "$out")"

    kill "$FAKE_PID" 2>/dev/null || true
    wait "$FAKE_PID" 2>/dev/null || true
    FAKE_PID=""
    sleep 1

    rc=0
    out="$("$PROBE" 2>&1)" || rc=$?
    check "$starter: released baseline exit" "$(expected_baseline_exit)" "$rc"
    check "$starter: holders return to expected" "$(expected_holders_token)" \
        "$(holder_count_token "$out")"
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
capture_expected_holders "prompt text"
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
PS_SNAPSHOT="$("$REAL_PS" -axo args=)"
case "$PS_SNAPSHOT" in
    *"$DECOY_ARGV"*) decoy_visible=yes ;;
    *)               decoy_visible=no ;;
esac
check "prompt text: decoy argv carries the trigger words" "yes" "$decoy_visible"

rc=0
out="$("$PROBE" 2>&1)" || rc=$?
check "prompt text: baseline exit (not a holder)" "$(expected_baseline_exit)" "$rc"
check "prompt text: holders stay expected" "$(expected_holders_token)" "$(holder_count_token "$out")"

# The superseded inline probe is asserted to be wrong on this same specimen, so
# nobody reintroduces it believing it was adequate.
legacy_count="$("$REAL_PS" -axo args= | grep -cE 'local-dev-up|playwright' || true)"
check "prompt text: superseded inline probe is fooled" "yes" \
    "$([ "$legacy_count" -gt 0 ] && echo yes || echo no)"

kill "$FAKE_PID" 2>/dev/null || true
wait "$FAKE_PID" 2>/dev/null || true
FAKE_PID=""

# --- 5. Nested pre-existing-holder regression arm --------------------------
# The defect Stage 2 repairs: the suite went false-red whenever a real holder
# already existed on the host before it ran. This arm reproduces exactly that
# condition and proves the repaired suite passes. It starts one holder OUTSIDE
# this run's FAKE_PID lifecycle, then re-execs the whole suite as a child while
# that holder is live. The child must (a) exit 0 — every delta assertion holds
# despite the pre-existing holder — and (b) report a captured "free" baseline of
# at least one, proving it measured the holder rather than assuming zero.
#
# Guarded by FJCLOUD_EXCLUSIVE_TEST_NESTED so the child does not recurse.
if [ "${FJCLOUD_EXCLUSIVE_TEST_NESTED:-0}" != "1" ]; then
    EXTERNAL_STACK_SPECIMEN="$WORK_DIR/fakestack/scripts/local-dev-up.sh"
    write_stack_specimen "$EXTERNAL_STACK_SPECIMEN"
    capture_expected_holders "nested-arm:outer"
    outer_baseline="$expected_holders"
    bash "$EXTERNAL_STACK_SPECIMEN" &
    EXTERNAL_PID="$!"
    sleep 1
    check "nested arm: external holder is alive" "yes" \
        "$(kill -0 "$EXTERNAL_PID" 2>/dev/null && echo yes || echo no)"

    run_nested_suite "nested_positive" "$WORK_DIR/fakestack" "none" "$NESTED_POSITIVE_TIMEOUT_SECONDS" || true
    check "nested arm: nested suite exits 0 with a pre-existing holder" "0" "$nested_rc"

    # Extract the child's measured "free" baseline from its own output. The child
    # captured it AFTER the external holder was live, so it must be >= 1.
    nested_baseline="$(printf '%s\n' "$nested_out" \
        | grep 'baseline\[free\]:' | head -n1 | sed 's/.*expected_holders=//')"
    echo "nested arm: outer_baseline=$outer_baseline nested_free_baseline=$nested_baseline"
    check "nested arm: nested run measured an elevated baseline (>=1)" "yes" \
        "$([ -n "$nested_baseline" ] && [ "$nested_baseline" -ge 1 ] 2>/dev/null && echo yes || echo no)"

    run_nested_suite "nested_recursive_ps_specimen" "$WORK_DIR/fakestack" \
        "recursive_ps" "$NESTED_SPECIMEN_TIMEOUT_SECONDS" || true
    check "nested arm: recursive ps leaked-writer specimen fails fast by timeout" \
        "timeout:nested_recursive_ps_specimen" "$nested_run_status"
    check "nested arm: recursive ps leaked-writer specimen returns timeout rc" \
        "124" "$nested_rc"
    check "nested arm: recursive ps specimen leaves no owned process alive" "yes" \
        "$(nested_owned_pids_all_gone 5)"

    # Same leaked-writer recursion, but nothing in the nested subtree dies from
    # SIGTERM. A TERM-only cleanup blocks forever here, so these assertions are
    # the fail-capability proof for the bounded grace period plus KILL
    # escalation: without it the direct suite never reaches the totals line.
    nested_started_at="$SECONDS"
    run_nested_suite "nested_term_ignoring_specimen" "$WORK_DIR/fakestack" \
        "recursive_ps_term_ignoring" "$NESTED_SPECIMEN_TIMEOUT_SECONDS" || true
    nested_cleanup_elapsed=$((SECONDS - nested_started_at))
    check "nested arm: TERM-ignoring specimen fails fast by timeout" \
        "timeout:nested_term_ignoring_specimen" "$nested_run_status"
    check "nested arm: TERM-ignoring specimen returns timeout rc" "124" "$nested_rc"
    echo "nested arm: term_ignoring_cleanup_elapsed=${nested_cleanup_elapsed}s" \
        "bound=${NESTED_CLEANUP_UPPER_BOUND_SECONDS}s"
    check "nested arm: TERM-ignoring cleanup stays within its wall-clock bound" "yes" \
        "$([ "$nested_cleanup_elapsed" -le "$NESTED_CLEANUP_UPPER_BOUND_SECONDS" ] \
            && echo yes || echo no)"
    check "nested arm: TERM-ignoring specimen leaves no owned process alive" "yes" \
        "$(nested_owned_pids_all_gone 5)"

    kill "$EXTERNAL_PID" 2>/dev/null || true
    wait "$EXTERNAL_PID" 2>/dev/null || true
    EXTERNAL_PID=""
fi

echo
echo "Totals: pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
