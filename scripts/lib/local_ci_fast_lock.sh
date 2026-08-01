#!/usr/bin/env bash
# local_ci_fast_lock.sh — clone-scoped mutual exclusion for whole-suite
# `local-ci --fast`.
#
# WHY THIS EXISTS: the observed contention came from several git worktrees of
# ONE clone each starting a full `--fast` run at the same time and thrashing
# the shared host. The lock is therefore scoped to the CLONE (every worktree
# hashes the same `git rev-parse --git-common-dir`), not the individual
# worktree, and lives under a host-global root (`/tmp`) so sibling worktrees —
# which each carry their own process/session `TMPDIR` — all observe the same
# lock directory.
#
# NO REUSABLE OWNER: an existing-owner probe
#   grep -rniE 'flock|acquire_lock|_lease|mkdir .*lock' scripts/
# surfaces only DB worker *leases* (algolia/catalog job reconciliation) and a
# test mock in seed_synthetic_traffic_test.sh. None is a general-purpose,
# process-scoped filesystem lock, so this file is the single new owner rather
# than an extension of any of them.
#
# PID SEMANTICS: holder identity uses `${BASHPID:-$$}`, the repo's established
# pattern (scripts/live-backend-gate.sh:220). Inside a plain function call
# (no subshell) BASHPID and $$ are identical, so this matches the Stage-1
# contract exactly while degrading to a real PID on bash 3.2, where BASHPID is
# unset — keeping the lock functional rather than silently empty.
#
# This file is meant to be SOURCED. It defines functions and constants only;
# it must not execute work or mutate global shell state at source time.

# Reserved contention exit code. Distinct from 0 (success) and 1 (a failed
# gate) so a caller can tell "another run holds the lock" apart from "a gate
# failed". Kept in sync with scripts/tests/local_ci_fast_lock_test.sh.
FAST_LOCK_CONTENTION_EXIT_CODE=75

# Bounded-wait knob. Invalid => immediate refusal (0); absent or empty => the
# bounded default below.
FAST_LOCK_WAIT_ENV_NAME="FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS"

# Default bounded wait, in seconds, applied when the knob is absent or empty.
#
# WHY NON-ZERO: a whole-suite `--fast` run is clone-exclusive and long-running,
# and nothing in this repo or the orchestrator ever exports the knob. With a 0
# default every concurrent worktree got an instant exit-75 refusal, recorded
# `--fast` as an unrunnable gate, and pushed on a self-selected subset of
# `--gate` runs instead — which is how partially validated work reached `main`.
# Queueing behind the holder makes the canonical pre-push gate slow rather than
# unobtainable. The wait stays bounded so no caller hangs forever, and an
# explicit `0` still opts back into fail-fast for interactive use.
FAST_LOCK_DEFAULT_WAIT_SECONDS=1800

# Poll cadence for the bounded wait, in hundredths of a second. The wait loop
# re-attempts acquisition every tick, so a holder that exits mid-wait is
# picked up promptly rather than after the whole budget elapses.
_FAST_LOCK_POLL_HUNDREDTHS=25

# ---------------------------------------------------------------------------
# Path derivation
# ---------------------------------------------------------------------------

# _fast_lock_hash <string> — stable short digest used only to name the lock
# directory. Correctness needs stability + collision-resistance, not crypto.
_fast_lock_hash() {
    local input="$1"
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$input" | shasum | awk '{ print $1 }'
    elif command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$input" | sha1sum | awk '{ print $1 }'
    else
        printf '%s' "$input" | cksum | awk '{ print $1 }'
    fi
}

# _fast_lock_dir — resolve the lock directory. Honors the Stage-1 override
# FJCLOUD_LOCAL_CI_FAST_LOCK_DIR; otherwise derives a clone-scoped default
# from the git common dir under the host-global /tmp root.
_fast_lock_dir() {
    if [ -n "${FJCLOUD_LOCAL_CI_FAST_LOCK_DIR:-}" ]; then
        printf '%s' "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
        return 0
    fi

    local common_dir canonical_common_dir digest
    common_dir="$(git rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -z "$common_dir" ]; then
        common_dir="${PWD:-.}/.git"
    fi
    # `--git-common-dir` can be repo-relative (e.g. ".git"); make it absolute
    # so every worktree of the clone hashes the one shared path.
    case "$common_dir" in
        /*) ;;
        *)  common_dir="${PWD:-.}/$common_dir" ;;
    esac
    # Resolve logical symlink components before hashing. The main worktree
    # commonly reports a relative `.git`; hashing logical $PWD directly would
    # give the same clone a second lock key when invoked through a symlink.
    if [ -d "$common_dir" ]; then
        canonical_common_dir="$(cd "$common_dir" && pwd -P)" || return 1
        common_dir="$canonical_common_dir"
    fi

    digest="$(_fast_lock_hash "$common_dir")"
    printf '/tmp/fjcloud_local_ci_fast_lock.%s' "$digest"
}

# _fast_lock_worktree — path recorded in the holder for operator diagnostics.
# Honors the Stage-1 override FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE.
_fast_lock_worktree() {
    if [ -n "${FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE:-}" ]; then
        printf '%s' "$FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE"
        return 0
    fi
    git rev-parse --show-toplevel 2>/dev/null || printf '%s' "${PWD:-.}"
}

# ---------------------------------------------------------------------------
# Wait-budget parsing
# ---------------------------------------------------------------------------

# _fast_lock_wait_seconds — the effective wait budget in whole seconds.
# Absent or empty resolves to FAST_LOCK_DEFAULT_WAIT_SECONDS. Invalid or
# negative values clamp to 0 (immediate refusal), never wait forever, and
# never introduce a new CLI flag.
_fast_lock_wait_seconds() {
    local raw="${FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS:-$FAST_LOCK_DEFAULT_WAIT_SECONDS}"
    case "$raw" in
        ''|*[!0-9]*) printf '0' ;;
        *)
            # Bash treats a leading zero as octal in arithmetic expressions.
            # Normalize digit-only input first so values such as `08` retain
            # their documented decimal-seconds meaning.
            while [ "${raw#0}" != "$raw" ]; do
                raw="${raw#0}"
            done
            printf '%s' "${raw:-0}"
            ;;
    esac
}

_fast_lock_wait_hundredths() {
    printf '%s' "$(( $(_fast_lock_wait_seconds) * 100 ))"
}

# ---------------------------------------------------------------------------
# Holder record helpers
# ---------------------------------------------------------------------------

# _fast_lock_holder_field <lock_dir> <field> — read one `key=value` line from
# the holder record. Mirrors the reader in the contract test so both sides
# agree on the record format.
_fast_lock_holder_field() {
    local lock_dir="$1" field="$2"
    _fast_lock_record_field "$lock_dir/holder" "$field"
}

_fast_lock_record_field() {
    local record="$1" field="$2"
    [ -f "$record" ] || return 0
    awk -F= -v field="$field" \
        '$1 == field { sub(/^[^=]*=/, ""); print; exit }' \
        "$record"
}

_fast_lock_set_current_process_pid() {
    local pid_file
    pid_file="$(mktemp "${TMPDIR:-/tmp}/fjcloud_fast_lock_pid.XXXXXX")" || return 1
    if ! python3 -c 'import os; print(os.getppid())' > "$pid_file"; then
        rm -f "$pid_file"
        return 1
    fi
    IFS= read -r _FAST_LOCK_PROCESS_PID < "$pid_file"
    rm -f "$pid_file"
}

# Build the metadata-guard record before publishing it. The guard process
# hard-links this complete inode into the stable `.guard` path atomically, so
# readers can never observe an empty or partially rewritten owner record.
_fast_lock_prepare_guard_record() {
    local lock_dir="$1" worktree="$2"
    _FAST_LOCK_GUARD_RECORD="$(mktemp "${lock_dir}.guard_candidate.XXXXXX")" \
        || return 1
    printf 'pid=%s\nprocess_pid=%s\nworktree=%s\nstarted_at=%s\n' \
        "${BASHPID:-$$}" "$_FAST_LOCK_PROCESS_PID" "$worktree" "$(date +%s)" \
        > "$_FAST_LOCK_GUARD_RECORD"
}

# The stable guard path is a hard link to a complete, uniquely prepared record
# whose inode this child flocks. An existing unlocked inode is orphaned and can
# be unlinked safely while its flock is held; an existing locked inode names
# the actual in-progress publisher and produces an immediate refusal.
_fast_lock_start_metadata_guard() {
    local lock_dir="$1" process_pid="$2" guard_record="$3"
    _FAST_LOCK_GUARD_STATE="$(mktemp -d "${lock_dir}.guard_state.XXXXXX")" || return 1

    python3 - "$lock_dir.guard" "$_FAST_LOCK_GUARD_STATE" \
        "$process_pid" "$guard_record" <<'PY' &
import fcntl
import os
from pathlib import Path
import sys
import time

guard_path, state_path, process_pid_text, candidate_path = sys.argv[1:]
state = Path(state_path)
candidate_descriptor = os.open(candidate_path, os.O_RDWR)
os.fsync(candidate_descriptor)
fcntl.flock(candidate_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)

while True:
    try:
        os.link(candidate_path, guard_path)
        break
    except FileExistsError:
        try:
            existing_descriptor = os.open(guard_path, os.O_RDWR)
        except FileNotFoundError:
            continue
        try:
            fcntl.flock(
                existing_descriptor,
                fcntl.LOCK_EX | fcntl.LOCK_NB,
            )
        except BlockingIOError:
            os.close(existing_descriptor)
            os.close(candidate_descriptor)
            os.unlink(candidate_path)
            (state / "busy").touch()
            sys.exit(75)

        existing_stat = os.fstat(existing_descriptor)
        try:
            current_stat = os.stat(guard_path)
        except FileNotFoundError:
            current_stat = None
        if current_stat is not None and (
            existing_stat.st_dev,
            existing_stat.st_ino,
        ) == (current_stat.st_dev, current_stat.st_ino):
            os.unlink(guard_path)
        os.close(existing_descriptor)

os.unlink(candidate_path)
(state / "ready").touch()
process_pid = int(process_pid_text)
while not (state / "release").exists():
    try:
        os.kill(process_pid, 0)
    except ProcessLookupError:
        (state / "ready").unlink(missing_ok=True)
        state.rmdir()
        break
    if os.getppid() != process_pid:
        break
    time.sleep(0.02)

guard_stat = os.fstat(candidate_descriptor)
try:
    current_stat = os.stat(guard_path)
except FileNotFoundError:
    current_stat = None
if current_stat is not None and (
    guard_stat.st_dev,
    guard_stat.st_ino,
) == (current_stat.st_dev, current_stat.st_ino):
    os.unlink(guard_path)
os.close(candidate_descriptor)
try:
    (state / "ready").unlink(missing_ok=True)
    state.rmdir()
except OSError:
    pass
PY
    _FAST_LOCK_GUARD_PID=$!
}

_fast_lock_try_acquire_metadata_guard() {
    local lock_dir="$1" process_pid="$2" worktree="$3" attempt=0 guard_rc
    _fast_lock_prepare_guard_record "$lock_dir" "$worktree" || return 1
    if ! _fast_lock_start_metadata_guard \
        "$lock_dir" "$process_pid" "$_FAST_LOCK_GUARD_RECORD"
    then
        rm -f "$_FAST_LOCK_GUARD_RECORD"
        _FAST_LOCK_GUARD_RECORD=""
        return 1
    fi
    while [ "$attempt" -lt 100 ]; do
        [ -f "$_FAST_LOCK_GUARD_STATE/ready" ] && return 0
        if [ -f "$_FAST_LOCK_GUARD_STATE/busy" ] \
            || ! kill -0 "$_FAST_LOCK_GUARD_PID" 2>/dev/null
        then
            guard_rc=0
            wait "$_FAST_LOCK_GUARD_PID" 2>/dev/null || guard_rc=$?
            rm -rf "$_FAST_LOCK_GUARD_STATE"
            rm -f "$_FAST_LOCK_GUARD_RECORD"
            _FAST_LOCK_GUARD_PID=""
            _FAST_LOCK_GUARD_STATE=""
            _FAST_LOCK_GUARD_RECORD=""
            [ "$guard_rc" -eq "$FAST_LOCK_CONTENTION_EXIT_CODE" ] \
                && return "$FAST_LOCK_CONTENTION_EXIT_CODE"
            return 1
        fi
        sleep 0.01
        attempt=$(( attempt + 1 ))
    done

    kill "$_FAST_LOCK_GUARD_PID" 2>/dev/null || true
    wait "$_FAST_LOCK_GUARD_PID" 2>/dev/null || true
    rm -rf "$_FAST_LOCK_GUARD_STATE"
    rm -f "$_FAST_LOCK_GUARD_RECORD"
    _FAST_LOCK_GUARD_PID=""
    _FAST_LOCK_GUARD_STATE=""
    _FAST_LOCK_GUARD_RECORD=""
    return 1
}

_fast_lock_release_metadata_guard() {
    [ -n "${_FAST_LOCK_GUARD_PID:-}" ] || return 0
    : > "$_FAST_LOCK_GUARD_STATE/release"
    wait "$_FAST_LOCK_GUARD_PID" 2>/dev/null || true
    rm -rf "$_FAST_LOCK_GUARD_STATE"
    _FAST_LOCK_GUARD_PID=""
    _FAST_LOCK_GUARD_STATE=""
    _FAST_LOCK_GUARD_RECORD=""
}

_fast_lock_is_nonneg_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *)           return 0 ;;
    esac
}

# _fast_lock_pid_is_valid <pid> — a usable holder PID is a positive integer.
_fast_lock_pid_is_valid() {
    _fast_lock_is_nonneg_int "$1" || return 1
    [ "$1" -gt 0 ]
}

# _fast_lock_write_holder <lock_dir> <worktree> — record the acquiring shell's
# identity. Written only after mkdir has established ownership of lock_dir.
# The exact field set — pid, worktree, started_at — is asserted by the
# contract test.
_fast_lock_write_holder() {
    local lock_dir="$1" worktree="$2"
    printf 'pid=%s\nworktree=%s\nstarted_at=%s\n' \
        "${BASHPID:-$$}" "$worktree" "$(date +%s)" \
        > "$lock_dir/holder"
}

# describe_fast_lock_holder <lock_dir> — render the holder identity consumed by
# the refusal path: `holder_pid=<pid> holder_worktree=<path> held_seconds=<n>`.
describe_fast_lock_holder() {
    local lock_dir="$1" record="${2:-$1/holder}"
    local pid worktree started_at now held
    pid="$(_fast_lock_record_field "$record" pid)"
    worktree="$(_fast_lock_record_field "$record" worktree)"
    started_at="$(_fast_lock_record_field "$record" started_at)"

    now="$(date +%s)"
    if _fast_lock_is_nonneg_int "$started_at"; then
        held=$(( now - started_at ))
        [ "$held" -lt 0 ] && held=0
    else
        held=0
    fi

    printf 'holder_pid=%s holder_worktree=%s held_seconds=%s' \
        "$pid" "$worktree" "$held"
}

# _fast_lock_refuse <lock_dir> — emit the full contention diagnostic. Written
# by the caller to stderr; keeps the refusal string in one place.
_fast_lock_refuse() {
    local lock_dir="$1" record="${2:-$1/holder}"
    printf 'local-ci --fast lock refused (exit %s): %s; wait for its natural exit rather than bypass; %s=%s\n' \
        "$FAST_LOCK_CONTENTION_EXIT_CODE" \
        "$(describe_fast_lock_holder "$lock_dir" "$record")" \
        "$FAST_LOCK_WAIT_ENV_NAME" \
        "$(_fast_lock_wait_seconds)"
}

_fast_lock_acquire_guarded() {
    local lock_dir="$1" worktree="$2" holder_pid
    if mkdir "$lock_dir" 2>/dev/null; then
        _fast_lock_write_holder "$lock_dir" "$worktree"
        return 0
    fi

    holder_pid="$(_fast_lock_holder_field "$lock_dir" pid)"
    if ! _fast_lock_pid_is_valid "$holder_pid"; then
        printf 'reclaiming corrupt local-ci --fast lock: holder PID missing or invalid\n' >&2
    elif kill -0 "$holder_pid" 2>/dev/null; then
        return "$FAST_LOCK_CONTENTION_EXIT_CODE"
    else
        printf 'reclaiming stale local-ci --fast lock held by dead PID %s\n' \
            "$holder_pid" >&2
    fi

    rm -rf "$lock_dir"
    mkdir "$lock_dir"
    _fast_lock_write_holder "$lock_dir" "$worktree"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# acquire_fast_lock — atomically claim the clone-scoped fast lock.
#   0                              -> lock held by this shell
#   FAST_LOCK_CONTENTION_EXIT_CODE -> a live run holds it (diagnostic on stderr)
# A holder whose PID is dead, missing, or non-numeric is reclaimed in place
# with a diagnostic on stderr, then acquisition retries.
acquire_fast_lock() {
    local lock_dir worktree process_pid
    local budget_hundredths waited_hundredths guard_rc guarded_rc refusal_record
    lock_dir="$(_fast_lock_dir)"
    worktree="$(_fast_lock_worktree)"
    _fast_lock_set_current_process_pid || return 1
    process_pid="$_FAST_LOCK_PROCESS_PID"
    _fast_lock_pid_is_valid "$process_pid" || return 1
    budget_hundredths="$(_fast_lock_wait_hundredths)"
    waited_hundredths=0

    while : ; do
        guard_rc=0
        _fast_lock_try_acquire_metadata_guard "$lock_dir" "$process_pid" "$worktree" \
            || guard_rc=$?
        if [ "$guard_rc" -eq "$FAST_LOCK_CONTENTION_EXIT_CODE" ]; then
            # The stable guard path always points at a complete record for the
            # process publishing or reclaiming metadata. If it disappeared
            # between the busy result and this read, retry against the completed
            # holder instead of emitting an empty diagnostic.
            [ -f "$lock_dir.guard" ] || continue
            refusal_record="$lock_dir.guard"
        else
            [ "$guard_rc" -eq 0 ] || return "$guard_rc"

            guarded_rc=0
            _fast_lock_acquire_guarded "$lock_dir" "$worktree" || guarded_rc=$?
            _fast_lock_release_metadata_guard
            if [ "$guarded_rc" -eq 0 ]; then
                return 0
            fi
            if [ "$guarded_rc" -ne "$FAST_LOCK_CONTENTION_EXIT_CODE" ]; then
                return "$guarded_rc"
            fi
            refusal_record="$lock_dir/holder"
        fi

        if [ "$waited_hundredths" -lt "$budget_hundredths" ]; then
            sleep 0.25
            waited_hundredths=$(( waited_hundredths + _FAST_LOCK_POLL_HUNDREDTHS ))
            continue
        fi

        _fast_lock_refuse "$lock_dir" "$refusal_record" >&2
        return "$FAST_LOCK_CONTENTION_EXIT_CODE"
    done
}

# release_fast_lock — remove the lock only if THIS shell owns it. A different
# live holder's lock is left untouched. Always returns 0 so it is safe to call
# from an EXIT trap.
release_fast_lock() {
    local lock_dir holder_pid
    lock_dir="$(_fast_lock_dir)"
    [ -d "$lock_dir" ] || return 0

    holder_pid="$(_fast_lock_holder_field "$lock_dir" pid)"
    if [ "$holder_pid" = "${BASHPID:-$$}" ]; then
        rm -rf "$lock_dir"
    fi
    return 0
}
