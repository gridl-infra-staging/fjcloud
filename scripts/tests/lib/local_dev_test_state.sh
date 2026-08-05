#!/usr/bin/env bash
# Shared helpers for local-dev shell tests that temporarily replace repo-local state.

# --- fake service process registry -------------------------------------------
#
# Teardown tests need a REAL process whose `ps comm=` name matches a service,
# because the matcher in the code under test keys on that name. Spawning one is
# easy; the historical bug was that nothing reaped it. The old fixture ran
# `nohup <copy of sleep> 300 &` inside a subshell — making the process a child of
# that subshell, so the test shell could never `wait` on it — and cleaned up with
# `rm -rf "$tmp_dir"`, which removes the binary and leaves the process running.
# Whenever the code under test failed to kill the sleeper, which is the exact case
# those tests exist to detect, it outlived the test and re-parented to init.
#
# Measured on the development host 2026-08-04: 913 leaked processes (229 flapjack,
# 228 each of npm, metering-agent, fjcloud-api), up to six days old, all wedged in
# uninterruptible `UE` state where SIGKILL does not land and only a reboot clears
# them. Cleanup must therefore be unconditional, not contingent on the assertion
# passing.
#
# Two deliberate choices:
#   1. Spawn as a DIRECT child of the calling shell (no subshell, no nohup) so the
#      caller can `wait` and leave no zombie behind.
#   2. Reap ONLY PIDs recorded here. A PID a test obtained some other way is never
#      touched — scripts/tests/integration_down_test.sh deliberately keeps a live
#      unrelated process to prove teardown skips it, and this host runs concurrent
#      workers whose processes must never be reachable from a test's cleanup.
FJCLOUD_TEST_SPAWNED_SERVICE_PIDS=()

# Set by spawn_named_test_service. Callers read this instead of using command
# substitution, which would run the helper in a subshell and discard both the
# registry entry and the parent's claim on the child.
FJCLOUD_TEST_LAST_SPAWNED_PID=""

# Spawn a fake service process named "$service_name" inside "$bin_dir".
# Reports the new PID in FJCLOUD_TEST_LAST_SPAWNED_PID.
spawn_named_test_service() {
    local bin_dir="$1"
    local service_name="$2"
    local lifetime_seconds="${3:-300}"

    # A SYMLINK, never a copy. This is the whole defect. `cp`ing a signed macOS
    # system binary strips its code signature, and on Apple Silicon the kernel
    # refuses to run the unsigned result: the process never reaches main, lands in
    # uninterruptible `UE` state with a 32 KB RSS, ignores SIGKILL, and survives
    # until reboot. Every one of the 913 leaked processes measured on this host was
    # such a corpse. The fixture still satisfied its assertions the whole time,
    # because the code under test matches on a PID file plus `ps comm=` and a wedged
    # process still has both — so nothing ever reported the breakage.
    #
    # A symlink keeps the target's signature intact, so the process actually runs
    # and can actually be killed, while `ps -o comm=` still reports the link name
    # the teardown matcher needs. scripts/tests/integration_down_test.sh has always
    # used this form, and it leaked nothing.
    ln -sf "$(command -v sleep)" "$bin_dir/$service_name"
    "$bin_dir/$service_name" "$lifetime_seconds" >/dev/null 2>&1 &
    FJCLOUD_TEST_LAST_SPAWNED_PID=$!
    FJCLOUD_TEST_SPAWNED_SERVICE_PIDS+=("$FJCLOUD_TEST_LAST_SPAWNED_PID")
    # Drop the job from the shell's job table so the expected SIGTERM during reaping
    # does not print a "Terminated: 15" line into the middle of test output. The PID
    # stays valid for `kill`/`kill -0`, which is all the reaper needs.
    disown "$FJCLOUD_TEST_LAST_SPAWNED_PID" 2>/dev/null || true
}

# Terminate every process spawned by spawn_named_test_service, then clear the
# registry. Idempotent, and safe when nothing was ever spawned.
#
# Callers must run this BEFORE removing the directory holding the fake binary:
# deleting a running process's executable is what leaves these wedged rather than
# merely orphaned.
reap_named_test_services() {
    local pid
    # bash 3.2 errors on "${arr[@]}" for an empty array under `set -u`; the
    # ${arr[@]+...} form expands to nothing instead.
    for pid in ${FJCLOUD_TEST_SPAWNED_SERVICE_PIDS[@]+"${FJCLOUD_TEST_SPAWNED_SERVICE_PIDS[@]}"}; do
        [ -n "$pid" ] || continue
        kill "$pid" 2>/dev/null || true
        # Poll with a hard bound instead of blocking on `wait`. A `wait` here would
        # hang the whole suite forever the moment any child became unkillable, which
        # is exactly the state this helper exists to prevent — a cleanup path must
        # not be able to deadlock on the failure it is cleaning up. Leaving a brief
        # zombie is strictly better than a hung test run; the shell reaps it on exit.
        local waited=0
        while [ "$waited" -lt 20 ] && kill -0 "$pid" 2>/dev/null; do
            sleep 0.1
            waited=$((waited + 1))
        done
    done
    FJCLOUD_TEST_SPAWNED_SERVICE_PIDS=()
    FJCLOUD_TEST_LAST_SPAWNED_PID=""
}

require_single_line_env_value() {
    local name="$1"
    local value="$2"

    case "$value" in
        *$'\n'*|*$'\r'*)
            printf 'write_local_dev_env_file: %s must be a single-line value\n' "$name" >&2
            return 1
            ;;
    esac
}

# Move a repo-local path aside for a test and return a restore token.
# TODO: Document backup_repo_path.
backup_repo_path() {
    local original_path="$1"
    local backup_path="$2"

    if [ ! -e "$original_path" ] && [ ! -L "$original_path" ]; then
        # Signal that the original didn't exist so restore_repo_path can
        # clean up whatever the test creates without confusing this with
        # the leaked-RETURN-trap case (empty string after caller clears).
        printf '__NO_ORIGINAL__\n'
        return 0
    fi

    rm -rf "$backup_path"
    mv "$original_path" "$backup_path"
    printf '%s\n' "$backup_path"
}

restore_repo_path() {
    local original_path="$1"
    local backup_path="${2:-}"

    # Only delete the original when the backup exists and can be restored.
    # This guards against leaked RETURN traps (bash macOS behavior) calling
    # restore after the backup temp dir was already cleaned up.
    if [ "$backup_path" = "__NO_ORIGINAL__" ]; then
        # Original didn't exist before the test — remove whatever it created.
        rm -rf "$original_path"
    elif [ -n "$backup_path" ] && { [ -e "$backup_path" ] || [ -L "$backup_path" ]; }; then
        rm -rf "$original_path"
        mv "$backup_path" "$original_path"
    fi
    # Otherwise (empty or non-empty-but-missing) do nothing:
    # - Empty string means the caller already cleared after a successful
    #   restore and a leaked RETURN trap (macOS bash) is re-firing.
    # - Non-empty but file missing means backup was already consumed.
}

write_local_dev_env_file() {
    local env_file="$1"
    local database_url="$2"

    require_single_line_env_value "DATABASE_URL" "$database_url" || return 1

    cat > "$env_file" <<EOF
DATABASE_URL=$database_url
JWT_SECRET=test-jwt-secret
ADMIN_KEY=test-admin-key
LISTEN_ADDR=127.0.0.1:3001
RUST_LOG=info,api=debug
FLAPJACK_URL=http://localhost:7700
EOF
}

create_local_dev_fixture_repo_root() {
    local tmp_dir="$1"
    local database_url="${2:-}"
    local fixture_root="$tmp_dir/fixture_repo"

    mkdir -p "$fixture_root/.local"
    if [ -n "$database_url" ]; then
        write_local_dev_env_file "$fixture_root/.env.local" "$database_url" || return 1
    fi
    printf '%s\n' "$fixture_root"
}

create_script_fixture_repo_root() {
    local tmp_dir="$1"
    local checkout_root="$2"
    local fixture_root="$tmp_dir/script_fixture_repo"

    mkdir -p "$fixture_root/.local" "$fixture_root/web"
    ln -s "$checkout_root/scripts" "$fixture_root/scripts"
    printf '%s\n' "$fixture_root"
}
