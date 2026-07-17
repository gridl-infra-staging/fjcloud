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
#
# Second failure mode (anchored 2026-06-03): on macOS Colima (and Docker
# Desktop / OrbStack), the *host-side* listener for any docker-published
# port is the runtime's port-forwarder (`ssh: ... [mux]` for Colima,
# `com.docker.backend`/vpnkit for Docker Desktop, etc.) — not the
# container actually publishing the port. So the PID/cmd/cwd diagnostic
# correctly identifies the forwarder but misleads the operator into
# thinking the problem is host-side. The real owner is one docker layer
# deeper. A stray `fj_cold_probe sleep infinity` container from an
# ad-hoc `docker run` ate :7700 today; the original diagnostic pointed
# at `ssh ... [mux]` with `cwd: /Users/stuart/repos/gridl/mike_dev`
# (colima's cwd, not the container owner). Tests below cover the
# docker-layer chase that closes this gap.

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

# Helper: install a `docker` shim on PATH whose `docker ps --filter
# publish=<port>` output is controlled by the caller. Other `docker`
# subcommands print nothing and exit 0 (matches the helper's best-effort
# contract — silent fall-through is fine for anything other than the
# query we're testing).
#
# Args:
#   $1  the held port the shim should report a container for; pass empty
#       to simulate "docker up but no container publishes this port"
#   $2  the fake container name to return (default: "stray_orphan")
#   $3  the fake image to return (default: "alpine:latest")
#
# Returns the temp dir path on stdout; caller is responsible for
# prepending it to PATH and cleaning up.
install_docker_shim() {
    local target_port="${1:-}"
    local fake_name="${2:-stray_orphan}"
    local fake_image="${3:-alpine:latest}"
    local tmpdir
    tmpdir=$(mktemp -d)

    # The shim only matches the exact `--filter publish=<port>` form the
    # helper uses; anything else returns empty. Output uses tab between
    # name and image to match the `--format '{{.Names}}\t{{.Image}}'`
    # contract the production helper relies on.
    cat > "$tmpdir/docker" <<SHIM
#!/usr/bin/env bash
# Test shim — do not ship.
if [ "\$1" = "ps" ]; then
    for arg in "\$@"; do
        if [ "\$arg" = "publish=${target_port}" ] && [ -n "${target_port}" ]; then
            printf '%s\t%s\n' '${fake_name}' '${fake_image}'
            exit 0
        fi
    done
fi
exit 0
SHIM
    chmod +x "$tmpdir/docker"
    printf '%s' "$tmpdir"
}

test_docker_layer_surfaces_container_when_port_published_by_container() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/health.sh"
    LOG_CAPTURE=""
    log() { LOG_CAPTURE="${LOG_CAPTURE}${*}"$'\n'; }

    local holder_pid="" held_port=""
    bind_test_port holder_pid held_port \
        || { fail "could not bind a test port"; return; }

    # Install docker shim configured to claim the held port is owned by
    # a container called "ghost_probe". Prepend to PATH so `command -v
    # docker` and `docker ps` resolve to the shim, not the real binary.
    local shim_dir
    shim_dir=$(install_docker_shim "$held_port" "ghost_probe" "fj_cold_probe_stage3")
    local saved_path="$PATH"
    export PATH="$shim_dir:$PATH"

    local exit_code=0
    check_port_available "$held_port" "test-docker-layer" || exit_code=$?

    # Restore environment before assertions so a test-side failure can't
    # poison subsequent tests' PATH.
    export PATH="$saved_path"
    kill "$holder_pid" 2>/dev/null || true
    rm -rf "$shim_dir"

    if [ "$exit_code" -eq 0 ]; then
        fail "check_port_available should return non-zero when port is held"
        return
    fi

    # The docker-layer probe MUST surface the container name (not just the
    # host-side forwarder PID), plus a paste-able `docker rm -f` command
    # that mirrors the existing `kill $pid` line. Without these, an
    # operator on Colima/Docker Desktop sees only the forwarder and has
    # no signal that the real owner is a container.
    case "$LOG_CAPTURE" in
        *"ghost_probe"*) pass "diagnostic surfaces the docker container name" ;;
        *) fail "diagnostic missing container name 'ghost_probe'; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"fj_cold_probe_stage3"*) pass "diagnostic surfaces the docker image" ;;
        *) fail "diagnostic missing image 'fj_cold_probe_stage3'; got: $LOG_CAPTURE" ;;
    esac
    case "$LOG_CAPTURE" in
        *"docker rm -f ghost_probe"*) pass "diagnostic includes paste-able 'docker rm -f <name>' command" ;;
        *) fail "diagnostic missing 'docker rm -f ghost_probe'; got: $LOG_CAPTURE" ;;
    esac
}

test_docker_layer_silent_when_no_container_publishes_port() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/health.sh"
    LOG_CAPTURE=""
    log() { LOG_CAPTURE="${LOG_CAPTURE}${*}"$'\n'; }

    local holder_pid="" held_port=""
    bind_test_port holder_pid held_port \
        || { fail "could not bind a test port"; return; }

    # Docker exists (shim is on PATH) but configured to report nothing —
    # simulates the common case where the host listener is a real
    # non-docker process, not a forwarder. Passing an empty target_port
    # to the shim makes `docker ps --filter publish=<anything>` return
    # empty.
    local shim_dir
    shim_dir=$(install_docker_shim "" )
    local saved_path="$PATH"
    export PATH="$shim_dir:$PATH"

    local exit_code=0
    check_port_available "$held_port" "test-no-docker-owner" || exit_code=$?

    export PATH="$saved_path"
    kill "$holder_pid" 2>/dev/null || true
    rm -rf "$shim_dir"

    if [ "$exit_code" -eq 0 ]; then
        fail "check_port_available should return non-zero when port is held"
        return
    fi

    # Negative assertion: the docker-container line must NOT appear when
    # docker reports no container publishing the port. Guards against a
    # regression where we'd print "docker container: " with an empty
    # value, leaking the empty probe to the operator.
    case "$LOG_CAPTURE" in
        *"docker container:"*)
            fail "diagnostic printed 'docker container:' with no real container; got: $LOG_CAPTURE" ;;
        *) pass "diagnostic stays silent about docker layer when no container publishes the port" ;;
    esac
    # Positive sanity: the existing PID/kill line must still appear so we
    # haven't accidentally short-circuited the host-side diagnostic.
    case "$LOG_CAPTURE" in
        *"kill $holder_pid"*) pass "host-side 'kill <pid>' line still present alongside silent docker probe" ;;
        *) fail "host-side diagnostic was suppressed; got: $LOG_CAPTURE" ;;
    esac
}

test_docker_layer_skipped_when_docker_not_installed() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/lib/health.sh"
    LOG_CAPTURE=""
    log() { LOG_CAPTURE="${LOG_CAPTURE}${*}"$'\n'; }

    local holder_pid="" held_port=""
    bind_test_port holder_pid held_port \
        || { fail "could not bind a test port"; return; }

    # Sanitize PATH to a small set that contains lsof + the core coreutils
    # the diagnostic depends on, but no docker. This simulates the CI
    # Linux runner without docker installed, and any operator machine
    # where docker simply isn't on PATH. lsof's location is OS-dependent
    # (macOS: /usr/sbin, most Linux distros: /usr/bin), so resolve it
    # dynamically rather than hardcoding a directory — hardcoding to
    # /usr/bin made check_port_available short-circuit (the lsof
    # `command -v` check returned false) and the test failed to detect a
    # held port at all.
    local saved_path="$PATH"
    local lsof_dir
    lsof_dir="$(dirname "$(command -v lsof)")"
    export PATH="${lsof_dir}:/usr/bin:/bin"

    local exit_code=0
    check_port_available "$held_port" "test-no-docker-installed" || exit_code=$?

    export PATH="$saved_path"
    kill "$holder_pid" 2>/dev/null || true

    if [ "$exit_code" -eq 0 ]; then
        fail "check_port_available should return non-zero when port is held"
        return
    fi

    # Without docker on PATH the docker probe must be a silent no-op —
    # not an error, not an empty "docker container:" line.
    case "$LOG_CAPTURE" in
        *"docker container:"*)
            fail "diagnostic mentioned docker container without docker on PATH; got: $LOG_CAPTURE" ;;
        *) pass "docker probe silently skipped when docker not on PATH" ;;
    esac
    case "$LOG_CAPTURE" in
        *"PID $holder_pid"*) pass "host-side PID line still present without docker on PATH" ;;
        *) fail "host-side PID line missing without docker on PATH; got: $LOG_CAPTURE" ;;
    esac
}

main() {
    echo "=== port_collision_diagnose_test.sh ==="
    echo ""

    test_check_port_available_succeeds_when_port_is_free
    test_check_port_available_reports_pid_and_command_when_port_held
    test_docker_layer_surfaces_container_when_port_published_by_container
    test_docker_layer_silent_when_no_container_publishes_port
    test_docker_layer_skipped_when_docker_not_installed

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
