#!/usr/bin/env bash
# Tests for the fake-service process registry in scripts/tests/lib/local_dev_test_state.sh.
#
# WHY THIS FILE EXISTS. Teardown tests (local_dev_down_test.sh, integration_down_test.sh)
# need a *real* process whose `ps comm=` name matches a service, because the matcher
# under test keys on that name. The historical fixture spawned one with
# `nohup <copy of sleep> 300 &` inside a subshell and cleaned up with
# `rm -rf "$tmp_dir"` — which removes the directory and never the process. Whenever the
# code under test failed to kill the sleeper (exactly the case those tests exist to
# detect) it outlived the test and re-parented to init.
#
# Measured on the development host 2026-08-04: 913 such processes — 229 `flapjack`,
# 228 each of `npm`, `metering-agent`, `fjcloud-api` — up to six days old, all wedged in
# uninterruptible `UE` state where SIGKILL does not land and only a reboot clears them.
#
# These tests pin the two properties that prevent a recurrence: a spawned fixture is
# always reapable, and the reaper only ever touches PIDs it spawned itself.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"

# `ps -o comm=` is the field the teardown matchers under test actually read, so the
# fixture is only useful if it reports the requested service name there.
process_comm_basename() {
    local pid="$1"
    ps -o comm= -p "$pid" 2>/dev/null | sed 's#.*/##' | tr -d ' '
}

process_is_alive() {
    local pid="$1"
    kill -0 "$pid" 2>/dev/null
}

test_spawn_reports_requested_service_name() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'reap_named_test_services; rm -rf "'"$tmp_dir"'"' RETURN

    # The helper reports through a global rather than stdout on purpose: command
    # substitution would run it in a subshell, where both the PID registry and the
    # parent's ability to `wait` on the child would be lost.
    local pid
    spawn_named_test_service "$tmp_dir" "fjcloud-api"
    pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"

    if process_is_alive "$pid"; then
        pass "spawned fixture process is running"
    else
        fail "spawned fixture process should be running"
        return
    fi

    assert_eq "$(process_comm_basename "$pid")" "fjcloud-api" \
        "ps comm= reports the requested service name so teardown matchers can find it"
}

test_reap_terminates_every_spawned_service() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'reap_named_test_services; rm -rf "'"$tmp_dir"'"' RETURN

    # Spawn the exact quartet the leak census recorded, so this case fails if any
    # single name escapes the registry.
    local flapjack_pid api_pid web_pid metering_pid
    spawn_named_test_service "$tmp_dir" "flapjack"
    flapjack_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    spawn_named_test_service "$tmp_dir" "fjcloud-api"
    api_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    spawn_named_test_service "$tmp_dir" "npm"
    web_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"
    spawn_named_test_service "$tmp_dir" "metering-agent"
    metering_pid="$FJCLOUD_TEST_LAST_SPAWNED_PID"

    reap_named_test_services

    local pid name survivors=""
    for pid in "$flapjack_pid" "$api_pid" "$web_pid" "$metering_pid"; do
        if process_is_alive "$pid"; then
            name="$(process_comm_basename "$pid")"
            survivors="$survivors $name($pid)"
        fi
    done

    assert_eq "$survivors" "" \
        "reaping leaves no spawned fixture process alive"
}

test_reap_never_touches_a_process_it_did_not_spawn() {
    # The safety property. scripts/tests/integration_down_test.sh deliberately keeps a
    # live unrelated process to prove teardown skips it; a reaper that killed anything
    # beyond its own registry would silently destroy that fixture, and on a shared
    # development host could reach a process no test owns at all.
    sleep 30 &
    local unrelated_pid=$!

    reap_named_test_services

    if process_is_alive "$unrelated_pid"; then
        pass "reaping leaves an unregistered process untouched"
    else
        fail "reaping must never terminate a process it did not spawn"
    fi

    kill "$unrelated_pid" 2>/dev/null || true
    wait "$unrelated_pid" 2>/dev/null || true
}

main() {
    test_spawn_reports_requested_service_name
    test_reap_terminates_every_spawned_service
    test_reap_never_touches_a_process_it_did_not_spawn

    run_test_summary
}

main "$@"
