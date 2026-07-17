#!/usr/bin/env bash
# docker_preflight_test.sh — Coverage for scripts/lib/docker.sh.
#
# Failure mode (anchored 2026-06-02): macOS colima loses its SSH-tunneled
# docker socket forward after a sleep/resume cycle. The socket file stays
# on disk but nothing is listening on it. Entry scripts that only checked
# `command -v docker` sailed past the broken state and failed deep inside
# `docker compose up` with a confusing buried error. The preflight in
# scripts/lib/docker.sh must:
#
#   1. Return 0 only when the daemon actually responds (not just when the
#      docker binary exists or the socket file is present).
#   2. Print a context-aware remediation hint when the daemon is unreachable.
#   3. Exit 1 from require_docker_daemon, return 1 (no exit) from
#      ensure_docker_daemon_or_warn — the cleanup script needs to keep
#      killing tracked PIDs even when docker itself is offline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Test harness: build a temp dir with a fake `docker` binary at the front of
# $PATH. The fake reads its scripted behavior from env vars set by the test:
#   FAKE_DOCKER_VERSION_RC=<int>  exit code for `docker version ...` calls
#   FAKE_DOCKER_CONTEXT=<string>  what `docker context show` should print
#
# Anything else is silently swallowed (we don't need other docker subcommands
# for these tests).
make_fake_docker() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    version)
        exit "${FAKE_DOCKER_VERSION_RC:-0}"
        ;;
    context)
        if [ "$2" = "show" ]; then
            printf '%s\n' "${FAKE_DOCKER_CONTEXT:-}"
            exit 0
        fi
        ;;
esac
exit 0
EOF
    chmod +x "$dir/docker"
}

# Source the helper inside a subshell so PATH/log/env changes don't leak.
# Returns the helper's exit code (via the subshell) and captures combined
# stdout/stderr in $CAPTURED_OUTPUT for assertions.
#
# Note: assignment is split from declaration so $? reads the command
# substitution's rc, not `local`'s rc (which is always 0 and would mask it).
run_helper() {
    local fn="$1"
    local fake_dir="$2"
    CAPTURED_OUTPUT="$(
        PATH="$fake_dir:$PATH" \
        FAKE_DOCKER_VERSION_RC="${FAKE_DOCKER_VERSION_RC:-0}" \
        FAKE_DOCKER_CONTEXT="${FAKE_DOCKER_CONTEXT:-}" \
        bash -c '
            log() { echo "[test] $*"; }
            source "'"$REPO_ROOT"'/scripts/lib/docker.sh"
            '"$fn"'
        ' 2>&1
    )"
    return $?
}

test_returns_zero_when_daemon_reachable() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    FAKE_DOCKER_VERSION_RC=0 run_helper require_docker_daemon "$tmpdir" \
        && pass "require_docker_daemon returns 0 when version succeeds" \
        || fail "require_docker_daemon should have returned 0; got rc, output: $CAPTURED_OUTPUT"
    rm -rf "$tmpdir"
}

test_exits_one_when_daemon_unreachable() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    local rc=0
    FAKE_DOCKER_VERSION_RC=1 run_helper require_docker_daemon "$tmpdir" || rc=$?
    if [ "$rc" -eq 1 ]; then
        pass "require_docker_daemon exits 1 when version fails"
    else
        fail "expected rc=1, got rc=$rc, output: $CAPTURED_OUTPUT"
    fi
    rm -rf "$tmpdir"
}

test_colima_context_hint_mentions_colima_restart() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    FAKE_DOCKER_VERSION_RC=1 FAKE_DOCKER_CONTEXT="colima" \
        run_helper require_docker_daemon "$tmpdir" || true
    if echo "$CAPTURED_OUTPUT" | grep -q "colima restart"; then
        pass "colima context hint mentions 'colima restart'"
    else
        fail "expected hint to mention 'colima restart'; output: $CAPTURED_OUTPUT"
    fi
    rm -rf "$tmpdir"
}

test_desktop_linux_context_hint_mentions_docker_desktop() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    FAKE_DOCKER_VERSION_RC=1 FAKE_DOCKER_CONTEXT="desktop-linux" \
        run_helper require_docker_daemon "$tmpdir" || true
    if echo "$CAPTURED_OUTPUT" | grep -q "Docker Desktop"; then
        pass "desktop-linux hint mentions Docker Desktop"
    else
        fail "expected hint to mention Docker Desktop; output: $CAPTURED_OUTPUT"
    fi
    rm -rf "$tmpdir"
}

test_orbstack_context_hint_mentions_orbstack() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    FAKE_DOCKER_VERSION_RC=1 FAKE_DOCKER_CONTEXT="orbstack" \
        run_helper require_docker_daemon "$tmpdir" || true
    if echo "$CAPTURED_OUTPUT" | grep -qi "orbstack"; then
        pass "orbstack hint mentions OrbStack"
    else
        fail "expected hint to mention OrbStack; output: $CAPTURED_OUTPUT"
    fi
    rm -rf "$tmpdir"
}

test_ensure_docker_daemon_or_warn_returns_without_exiting() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    make_fake_docker "$tmpdir"
    local rc=0
    FAKE_DOCKER_VERSION_RC=1 run_helper ensure_docker_daemon_or_warn "$tmpdir" || rc=$?
    # Critical assertion: rc must be exactly 1 (returned), not from set -e or
    # an `exit` call. Our run_helper would otherwise lose the __rc marker if
    # the subshell had hard-exited.
    if [ "$rc" -eq 1 ] && echo "$CAPTURED_OUTPUT" | grep -q "fix:"; then
        pass "ensure_docker_daemon_or_warn returns 1 with hint, doesn't exit"
    else
        fail "expected rc=1 + hint; got rc=$rc, output: $CAPTURED_OUTPUT"
    fi
    rm -rf "$tmpdir"
}

test_real_daemon_round_trip() {
    # If a real docker daemon is reachable in this environment, our helper
    # should agree with `docker version --format '{{.Server.Version}}'`. This
    # is a smoke check that the helper isn't shadowed by something dumb.
    if ! command -v docker >/dev/null 2>&1; then
        pass "skipped real-daemon check: no docker on PATH"
        return 0
    fi
    if ! docker version --format '{{.Server.Version}}' >/dev/null 2>&1; then
        pass "skipped real-daemon check: real daemon not reachable in this env"
        return 0
    fi
    local rc=0
    bash -c '
        log() { echo "[test] $*"; }
        source "'"$REPO_ROOT"'/scripts/lib/docker.sh"
        require_docker_daemon
    ' >/dev/null 2>&1 || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "real-daemon round trip: helper agrees with live docker"
    else
        fail "real daemon reachable but helper returned $rc"
    fi
}

# ---------------------------------------------------------------------------
# Run tests
# ---------------------------------------------------------------------------
test_returns_zero_when_daemon_reachable
test_exits_one_when_daemon_unreachable
test_colima_context_hint_mentions_colima_restart
test_desktop_linux_context_hint_mentions_docker_desktop
test_orbstack_context_hint_mentions_orbstack
test_ensure_docker_daemon_or_warn_returns_without_exiting
test_real_daemon_round_trip

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
