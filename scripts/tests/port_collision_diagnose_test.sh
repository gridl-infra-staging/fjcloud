#!/usr/bin/env bash
# port_collision_diagnose_test.sh — Coverage for check_port_available's
# orphan-process diagnostic output.
#
# Failure mode (anchored 2026-05-31): local_demo.sh hit "port 5173 is
# unavailable" with no information about who was holding the port. The
# holder turned out to be a vite spawned by a different worktree's batman
# session 5 days earlier. The structural problem: the agent (or operator)
# can't act on "port unavailable" — they need the PID + command + cwd
# + start time + a copy-pasteable kill command.
#
# This test asserts check_port_available's failure output includes:
# 1. The owning PID
# 2. The owning process's command-line (so it's recognisable as a vite/
#    cargo/postgres/etc.)
# 3. The owning process's cwd (so cross-worktree orphans are obvious)
# 4. The owning process's start time (so "5 days stale" is visible)
# 5. A kill command the operator can paste

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Helper: bind a TCP port and return the listener's PID and port. The
# listener stays up until the caller kills it. Uses python3 (always present)
# rather than `nc -l` (BSD nc on macOS doesn't support all the flags Linux
# nc does, so portability is awkward).
bind_test_port() {
    local pid_var="$1" port_var="$2"
    local tmp pid_file port_file
    tmp=$(mktemp -d)
    pid_file="$tmp/pid"
    port_file="$tmp/port"

    # Start a python TCP listener in the background. It writes its port and
    # PID to files and then sleeps holding the socket. The shell's variable
    # references can't reach back into the test, so we use temp files.
    python3 - "$port_file" <<'PY' &
import socket, sys, time, os
port_path = sys.argv[1]
s = socket.socket()
s.bind(("127.0.0.1", 0))
s.listen(1)
with open(port_path, "w") as f:
    f.write(str(s.getsockname()[1]))
# Stay alive until killed.
while True:
    time.sleep(60)
PY
    local child_pid=$!
    echo "$child_pid" > "$pid_file"

    # Poll for the port file. The listener writes the port immediately so
    # this should resolve within a few ms.
    local elapsed=0
    while [ $elapsed -lt 50 ] && [ ! -s "$port_file" ]; do
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
    if [ ! -s "$port_file" ]; then
        kill "$child_pid" 2>/dev/null || true
        rm -rf "$tmp"
        return 1
    fi

    printf -v "$pid_var" '%s' "$child_pid"
    printf -v "$port_var" '%s' "$(cat "$port_file")"
    rm -rf "$tmp"
}

test_check_port_available_succeeds_when_port_is_free() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/health.sh"
    log() { :; }

    # Pick a port we know is free by binding then immediately freeing.
    local free_port
    free_port=$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')

    if check_port_available "$free_port" "test-free-port"; then
        pass "check_port_available returns 0 when the port is free"
    else
        fail "check_port_available returned non-zero for a free port ($free_port)"
    fi
}

test_check_port_available_reports_pid_and_command_when_port_held() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/health.sh"
    LOG_CAPTURE=""
    log() { LOG_CAPTURE="${LOG_CAPTURE}${*}"$'\n'; }

    local holder_pid="" held_port=""
    bind_test_port holder_pid held_port \
        || { fail "could not bind a test port"; return; }

    local exit_code=0
    check_port_available "$held_port" "test-name" || exit_code=$?

    # Always clean up the held port, even if assertions below fail.
    kill "$holder_pid" 2>/dev/null || true

    if [ "$exit_code" -eq 0 ]; then
        fail "check_port_available should return non-zero when port is held"
        return
    fi

    # The diagnostic output MUST surface the four anchored fields, plus a
    # paste-able kill command. Without these, the operator gets no signal.
    case "$LOG_CAPTURE" in
        *"PID $holder_pid"*) pass "diagnostic surfaces the holder PID" ;;
        *) fail "diagnostic missing 'PID $holder_pid'; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"cmd"*|*"command"*) pass "diagnostic surfaces the holder command" ;;
        *) fail "diagnostic missing command-line info; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"cwd"*) pass "diagnostic surfaces the holder cwd" ;;
        *) fail "diagnostic missing cwd info; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"started"*|*"start"*) pass "diagnostic surfaces the holder start time" ;;
        *) fail "diagnostic missing start-time info; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"kill $holder_pid"*) pass "diagnostic includes a paste-able 'kill <pid>' command" ;;
        *) fail "diagnostic missing 'kill $holder_pid'; got: $LOG_CAPTURE" ;;
    esac
}

main() {
    echo "=== port_collision_diagnose_test.sh ==="
    echo ""

    test_check_port_available_succeeds_when_port_is_free
    test_check_port_available_reports_pid_and_command_when_port_held

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
