#!/usr/bin/env bash
# Contract tests for the clone-scoped local-ci --fast lock.
#
# This suite is intentionally seconds-scale. It drives the future sourced
# helper directly instead of starting the full local-ci --fast gate.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK_LIB="$REPO_ROOT/scripts/lib/local_ci_fast_lock.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

if [ ! -f "$LOCK_LIB" ]; then
    fail "local-ci --fast lock helper is missing: $LOCK_LIB"
    run_test_summary
fi

source "$LOCK_LIB"

CONTENTION_EXIT_CODE=75
WAIT_ENV_NAME="FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS"
MEASURED_FAST_RUN_SECONDS=1241
PROTECTED_LIVE_HOLDER_MULTIPLIER=3

new_fixture() {
    FIXTURE_DIR="$(mktemp -d)"
    FJCLOUD_LOCAL_CI_FAST_LOCK_DIR="$FIXTURE_DIR/local_ci_fast.lock"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE="$FIXTURE_DIR/worktree"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
    export FJCLOUD_LOCAL_CI_FAST_LOCK_DIR
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS
    mkdir -p "$FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE"
}

cleanup_fixture() {
    if [ -n "${FIXTURE_DIR:-}" ] && [ -d "$FIXTURE_DIR" ]; then
        rm -rf "$FIXTURE_DIR"
    fi
    FIXTURE_DIR=""
}

run_reclaim_capture() {
    RECLAIM_RC=0
    acquire_fast_lock >"$FIXTURE_DIR/reclaim.stdout" 2>"$FIXTURE_DIR/reclaim.stderr" || RECLAIM_RC=$?
    RECLAIM_STDOUT="$(cat "$FIXTURE_DIR/reclaim.stdout")"
    RECLAIM_STDERR="$(cat "$FIXTURE_DIR/reclaim.stderr")"
}

seed_reclaimable_holder() {
    local holder_kind="$1"
    mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
    case "$holder_kind" in
        stale)
            printf 'pid=99999999\nworktree=%s\nstarted_at=%s\n' \
                "$FIXTURE_DIR/stale_worktree" "$(date +%s)" \
                > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"
            ;;
        corrupt)
            printf 'pid=not-a-pid\nworktree=%s\nstarted_at=%s\n' \
                "$FIXTURE_DIR/corrupt_worktree" "$(date +%s)" \
                > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"
            ;;
    esac
}

run_concurrent_reclaimer_case() {
    local holder_kind="$1" contender_b_pid
    local contender_a_rc=0 contender_b_rc success_count refusal_count
    new_fixture
    seed_reclaimable_holder "$holder_kind"

    (
        trap - EXIT
        local delayed_removal=0
        rm() {
            if [ "$delayed_removal" -eq 0 ] \
                && [ "${1:-}" = "-rf" ] \
                && [ "${2:-}" = "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR" ]
            then
                delayed_removal=1
                : > "$FIXTURE_DIR/reclaimer_b_ready"
                sleep 1
            fi
            command rm "$@"
        }
        set +e
        acquire_fast_lock >"$FIXTURE_DIR/reclaimer_b.stdout" 2>"$FIXTURE_DIR/reclaimer_b.stderr"
        contender_b_rc=$?
        printf '%s' "$contender_b_rc" > "$FIXTURE_DIR/reclaimer_b.rc"
        [ "$contender_b_rc" -eq 0 ] && sleep 2
        release_fast_lock
    ) &
    contender_b_pid=$!

    while [ ! -f "$FIXTURE_DIR/reclaimer_b_ready" ]; do
        sleep 0.05
    done

    acquire_fast_lock >"$FIXTURE_DIR/reclaimer_a.stdout" 2>"$FIXTURE_DIR/reclaimer_a.stderr" \
        || contender_a_rc=$?
    [ "$contender_a_rc" -eq 0 ] && sleep 2
    release_fast_lock
    wait "$contender_b_pid"
    contender_b_rc="$(cat "$FIXTURE_DIR/reclaimer_b.rc")"
    success_count=$(( (contender_a_rc == 0) + (contender_b_rc == 0) ))
    refusal_count=$(( (contender_a_rc == CONTENTION_EXIT_CODE) + (contender_b_rc == CONTENTION_EXIT_CODE) ))

    assert_eq "$success_count" "1" \
        "$holder_kind takeover permits exactly one concurrent reclaimer"
    assert_eq "$refusal_count" "1" \
        "$holder_kind takeover refuses the losing reclaimer with exit 75"
    cleanup_fixture
}

holder_value() {
    local field="$1"
    awk -F= -v field="$field" '$1 == field { sub(/^[^=]*=/, ""); print; exit }' \
        "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"
}

normalize_refusal() {
    sed -E 's/held_seconds=[0-9]+/held_seconds=<elapsed>/'
}

expected_refusal() {
    local holder_pid="$1" holder_worktree="$2" wait_seconds="$3"
    printf '%s' \
        "local-ci --fast lock refused (exit $CONTENTION_EXIT_CODE): holder_pid=$holder_pid holder_worktree=$holder_worktree held_seconds=<elapsed>; wait for its natural exit rather than bypass; $WAIT_ENV_NAME=$wait_seconds; exit $CONTENTION_EXIT_CODE means contention, not a gate result; do not replace the whole suite with self-selected --gate <name> runs"
}

# Wall-clock seconds, sampled in a fresh process per call. Must be
# comparable ACROSS processes: on macOS `time.monotonic()`'s reference point
# is per-process (both samples read ~0), so a monotonic clock measured this
# way reports ~0 elapsed regardless of the real wait. `time.time()` is
# epoch-based and therefore comparable between the two sampling processes,
# with the same sub-second precision the bounded-wait window relies on.
wall_clock_seconds() {
    python3 -c 'import time; print(time.time())'
}

assert_elapsed_between() {
    local elapsed="$1" minimum="$2" maximum="$3" message="$4"
    if awk -v elapsed="$elapsed" -v minimum="$minimum" -v maximum="$maximum" \
        'BEGIN { exit !(elapsed >= minimum && elapsed <= maximum) }'
    then
        pass "$message"
    else
        fail "$message (expected $minimum <= elapsed <= $maximum, actual=$elapsed)"
    fi
}

test_free_acquire_records_holder_values() {
    local before after expected_pid rc=0
    new_fixture
    before="$(date +%s)"
    expected_pid="${BASHPID:-$$}"

    acquire_fast_lock || rc=$?
    after="$(date +%s)"

    assert_eq "$rc" "0" "free lock acquisition succeeds"
    assert_file_exists "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder" \
        "free lock acquisition writes a holder record"
    assert_eq "$(holder_value pid)" "$expected_pid" \
        "holder record contains the acquiring shell PID"
    assert_eq "$(holder_value worktree)" "$FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE" \
        "holder record contains the exact worktree path"
    assert_elapsed_between "$(holder_value started_at)" "$before" "$after" \
        "holder record contains an acquisition epoch timestamp"

    release_fast_lock
    cleanup_fixture
}

test_default_lock_dir_is_stable_through_worktree_symlink() {
    local physical_lock_dir logical_lock_dir
    new_fixture
    mkdir "$FIXTURE_DIR/repo"
    git -C "$FIXTURE_DIR/repo" init -q
    ln -s "$FIXTURE_DIR/repo" "$FIXTURE_DIR/repo_link"

    physical_lock_dir="$(
        cd "$FIXTURE_DIR/repo"
        unset FJCLOUD_LOCAL_CI_FAST_LOCK_DIR
        _fast_lock_dir
    )"
    logical_lock_dir="$(
        cd "$FIXTURE_DIR/repo_link"
        unset FJCLOUD_LOCAL_CI_FAST_LOCK_DIR
        _fast_lock_dir
    )"

    assert_eq "$logical_lock_dir" "$physical_lock_dir" \
        "default lock key is stable when one clone is entered through a symlink"
    cleanup_fixture
}

test_contended_acquire_refuses_with_holder_identity() {
    local holder_pid holder_worktree output normalized rc=0
    new_fixture
    acquire_fast_lock
    holder_pid="$(holder_value pid)"
    holder_worktree="$(holder_value worktree)"

    ( acquire_fast_lock >"$FIXTURE_DIR/contended.stdout" 2>"$FIXTURE_DIR/contended.stderr" ) || rc=$?
    output="$(cat "$FIXTURE_DIR/contended.stderr")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"

    assert_eq "$rc" "$CONTENTION_EXIT_CODE" \
        "contended acquisition returns the reserved refusal code"
    assert_ne "$rc" "0" "contention is not reported as success"
    assert_ne "$rc" "1" "contention is distinct from a failed gate"
    assert_eq "$normalized" "$(expected_refusal "$holder_pid" "$holder_worktree" "0")" \
        "contention stderr identifies the holder and gives actionable refusal guidance"
    assert_eq "$(cat "$FIXTURE_DIR/contended.stdout")" "" \
        "contention keeps the refusal diagnostic on stderr"

    release_fast_lock
    cleanup_fixture
}

test_refusal_forbids_gate_subset_substitution() {
    local output normalized rc=0
    new_fixture
    acquire_fast_lock

    ( acquire_fast_lock >"$FIXTURE_DIR/substitution.stdout" \
        2>"$FIXTURE_DIR/substitution.stderr" ) || rc=$?
    output="$(cat "$FIXTURE_DIR/substitution.stderr")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"

    assert_eq "$rc" "$CONTENTION_EXIT_CODE" \
        "whole-suite contention returns the reserved refusal code"
    assert_contains "$normalized" \
        "exit 75 means contention, not a gate result; do not replace the whole suite with self-selected --gate <name> runs" \
        "refusal forbids substituting self-selected gate runs for the whole suite"
    assert_eq "$(cat "$FIXTURE_DIR/substitution.stdout")" "" \
        "whole-suite substitution guidance stays on stderr"

    release_fast_lock
    cleanup_fixture
}

test_refusal_consumes_exported_holder_description() {
    local output normalized
    new_fixture
    describe_fast_lock_holder() {
        printf 'holder_pid=123 holder_worktree=/exported-helper held_seconds=4'
    }

    output="$(_fast_lock_refuse "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"
    assert_eq "$normalized" \
        "$(expected_refusal "123" "/exported-helper" "0")" \
        "refusal consumes the exported holder-description helper"

    source "$LOCK_LIB"
    cleanup_fixture
}

test_release_allows_subsequent_acquire() {
    local rc=0
    new_fixture
    acquire_fast_lock

    release_fast_lock

    assert_eq "$([ -d "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR" ] && printf present || printf absent)" \
        "absent" "release removes the owned lock directory"
    acquire_fast_lock || rc=$?
    assert_eq "$rc" "0" "a subsequent acquire succeeds after release"

    release_fast_lock
    cleanup_fixture
}

test_dead_holder_is_reclaimed() {
    local dead_pid
    new_fixture
    # Manufacture a dead PID. The sleeper MUST clear the inherited EXIT trap
    # first: bash fires an inherited EXIT trap when a backgrounded subshell
    # terminates (deterministically so on the bash 3.2 the reachability gate
    # runs under), and cleanup_fixture would then rm the live fixture out from
    # under this test. `trap - EXIT` in the child neutralizes that.
    ( trap - EXIT; : > "$FIXTURE_DIR/sleeper.ready"; exec sleep 30 ) &
    dead_pid=$!
    while [ ! -f "$FIXTURE_DIR/sleeper.ready" ]; do
        sleep 0.01
    done
    kill "$dead_pid"
    wait "$dead_pid" 2>/dev/null || true
    mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
    printf 'pid=%s\nworktree=%s\nstarted_at=%s\n' \
        "$dead_pid" "$FIXTURE_DIR/dead_worktree" "$(date +%s)" \
        > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"

    run_reclaim_capture

    assert_eq "$RECLAIM_RC" "0" "a lock owned by a reaped PID is reclaimed"
    assert_eq "$RECLAIM_STDERR" \
        "reclaiming stale local-ci --fast lock held by dead PID $dead_pid" \
        "stale-lock diagnostic names the exact dead PID"
    assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
        "stale reclamation replaces the dead holder record"
    assert_eq "$RECLAIM_STDOUT" "" \
        "stale-lock reclamation emits its diagnostic only on stderr"

    release_fast_lock
    cleanup_fixture
}

test_live_holder_reclaim_boundaries() {
    local holder_kind live_pid live_worktree started_at normalized protected_holder_age
    local original_holder held_seconds_rc
    assert_eq "$FAST_LOCK_LIVE_RECLAIM_SECONDS" "3900" \
        "the default-wait retune leaves the frozen live-holder reclaim boundary unchanged"
    protected_holder_age="$(( MEASURED_FAST_RUN_SECONDS * PROTECTED_LIVE_HOLDER_MULTIPLIER ))"
    assert_eq "$protected_holder_age" "3723" \
        "legitimate-runtime specimen protects three measured 1241-second --fast runs"

    for holder_kind in \
        stale recent legitimate_runtime missing_started_at unparseable_started_at
    do
        new_fixture
        ( trap - EXIT; exec sleep 30 ) &
        live_pid="$!"
        live_worktree="$FIXTURE_DIR/${holder_kind}_live_worktree"
        case "$holder_kind" in
            stale) started_at=1 ;;
            recent) started_at="$(date +%s)" ;;
            legitimate_runtime) started_at="$(( $(date +%s) - protected_holder_age ))" ;;
            missing_started_at) started_at="" ;;
            unparseable_started_at) started_at="not-an-epoch" ;;
        esac
        mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
        printf 'pid=%s\nworktree=%s\n' "$live_pid" "$live_worktree" \
            > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"
        if [ "$holder_kind" != missing_started_at ]; then
            printf 'started_at=%s\n' "$started_at" \
                >> "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"
        fi
        original_holder="$(cat "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder")"

        if [ "$holder_kind" = missing_started_at ] \
            || [ "$holder_kind" = unparseable_started_at ]
        then
            held_seconds_rc=0
            fast_lock_holder_held_seconds "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR" \
                > "$FIXTURE_DIR/held_seconds.stdout" 2>/dev/null \
                || held_seconds_rc=$?
            assert_eq "$held_seconds_rc" "1" \
                "$holder_kind age evidence is rejected by the canonical parser"
            assert_eq "$(cat "$FIXTURE_DIR/held_seconds.stdout")" "" \
                "$holder_kind age evidence cannot produce a held-seconds value"
        fi

        run_reclaim_capture
        normalized="$(printf '%s' "$RECLAIM_STDERR" | normalize_refusal)"
        if [ "$holder_kind" = stale ]; then
            assert_eq "$RECLAIM_RC" "0" \
                "a live holder older than the reclaim bound releases the lock to the waiter"
            assert_contains "$RECLAIM_STDERR" "reclaiming" \
                "stale-live reclamation is loud rather than silently stealing the lock"
            assert_contains "$normalized" \
                "holder_pid=$live_pid holder_worktree=$live_worktree held_seconds=<elapsed>" \
                "stale-live reclamation identifies the displaced holder in the canonical shape"
            assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
                "stale-live reclamation replaces the old holder record"
        else
            assert_eq "$RECLAIM_RC" "$CONTENTION_EXIT_CODE" \
                "a $holder_kind live holder inside the reclaim bound remains protected"
            assert_eq "$normalized" "$(expected_refusal "$live_pid" "$live_worktree" "0")" \
                "$holder_kind refusal preserves the canonical holder diagnostic"
            assert_eq "$(holder_value pid)" "$live_pid" \
                "$holder_kind refusal leaves the holder record unchanged"
            assert_eq "$(cat "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder")" "$original_holder" \
                "$holder_kind refusal preserves the complete holder record"
        fi
        assert_eq "$(kill -0 "$live_pid" 2>/dev/null && printf alive || printf dead)" "alive" \
            "$holder_kind reclaim decision never signals the holder"
        [ "$RECLAIM_RC" -eq 0 ] && release_fast_lock
        kill "$live_pid" 2>/dev/null || true
        wait "$live_pid" 2>/dev/null || true
        cleanup_fixture
    done
}

test_pidless_holder_is_reclaimed() {
    new_fixture
    mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
    printf 'worktree=%s\nstarted_at=not-an-epoch\n' "$FIXTURE_DIR/corrupt_worktree" \
        > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"

    run_reclaim_capture

    assert_eq "$RECLAIM_RC" "0" "a PID-less holder record is reclaimed"
    assert_eq "$RECLAIM_STDERR" \
        "reclaiming corrupt local-ci --fast lock: holder PID missing or invalid" \
        "corrupt-lock diagnostic explains the exact defect"
    assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
        "corrupt reclamation writes a valid replacement holder"
    assert_eq "$RECLAIM_STDOUT" "" \
        "corrupt-lock reclamation emits its diagnostic only on stderr"

    release_fast_lock
    cleanup_fixture
}

test_invalid_pid_holder_is_reclaimed() {
    new_fixture
    mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"
    printf 'pid=not-a-pid\nworktree=%s\nstarted_at=%s\n' \
        "$FIXTURE_DIR/corrupt_worktree" "$(date +%s)" \
        > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/holder"

    run_reclaim_capture

    assert_eq "$RECLAIM_RC" "0" "an invalid-PID holder record is reclaimed"
    assert_eq "$RECLAIM_STDERR" \
        "reclaiming corrupt local-ci --fast lock: holder PID missing or invalid" \
        "invalid-PID reclamation reuses the corrupt-lock diagnostic"
    assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
        "invalid-PID reclamation writes a valid replacement holder"
    assert_eq "$RECLAIM_STDOUT" "" \
        "invalid-PID reclamation emits its diagnostic only on stderr"

    release_fast_lock
    cleanup_fixture
}

test_bounded_wait_honors_interval_then_refuses() {
    local start end elapsed holder_pid holder_worktree output normalized rc=0
    new_fixture
    acquire_fast_lock
    holder_pid="$(holder_value pid)"
    holder_worktree="$(holder_value worktree)"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=1
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS
    start="$(wall_clock_seconds)"

    ( acquire_fast_lock >"$FIXTURE_DIR/wait.stdout" 2>"$FIXTURE_DIR/wait.stderr" ) || rc=$?
    end="$(wall_clock_seconds)"
    output="$(cat "$FIXTURE_DIR/wait.stderr")"
    elapsed="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", end - start }')"
    normalized="$(printf '%s' "$output" | normalize_refusal)"

    assert_elapsed_between "$elapsed" "1" "4.5" \
        "bounded contention waits for the configured interval without hanging"
    assert_eq "$rc" "$CONTENTION_EXIT_CODE" \
        "bounded contention still returns the reserved refusal code"
    assert_eq "$normalized" "$(expected_refusal "$holder_pid" "$holder_worktree" "1")" \
        "bounded-wait refusal preserves the exact holder diagnostic"
    assert_eq "$(cat "$FIXTURE_DIR/wait.stdout")" "" \
        "bounded-wait refusal keeps the diagnostic on stderr"

    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
    release_fast_lock
    cleanup_fixture
}

test_bounded_wait_includes_metadata_guard_attempt_time() {
    local start end elapsed holder_pid holder_worktree output normalized rc=0
    new_fixture
    acquire_fast_lock
    holder_pid="$(holder_value pid)"
    holder_worktree="$(holder_value worktree)"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=1
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS

    _fast_lock_try_acquire_metadata_guard() {
        local lock_dir="$1"
        sleep 1
        cp "$lock_dir/holder" "$lock_dir.guard"
        return "$CONTENTION_EXIT_CODE"
    }

    start="$(wall_clock_seconds)"
    ( acquire_fast_lock >"$FIXTURE_DIR/slow_guard.stdout" \
        2>"$FIXTURE_DIR/slow_guard.stderr" ) || rc=$?
    end="$(wall_clock_seconds)"
    elapsed="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", end - start }')"
    output="$(cat "$FIXTURE_DIR/slow_guard.stderr")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"

    assert_elapsed_between "$elapsed" "1" "4.5" \
        "metadata-guard work is charged to the configured wait budget"
    assert_eq "$rc" "$CONTENTION_EXIT_CODE" \
        "slow metadata-guard contention returns the reserved refusal code"
    assert_eq "$normalized" "$(expected_refusal "$holder_pid" "$holder_worktree" "1")" \
        "slow metadata-guard refusal preserves the holder diagnostic"

    source "$LOCK_LIB"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
    release_fast_lock
    cleanup_fixture
}

test_bounded_wait_accounts_for_missing_guard_fallback_race() {
    local start end elapsed holder_pid holder_worktree output normalized rc=0
    new_fixture
    acquire_fast_lock
    holder_pid="$(holder_value pid)"
    holder_worktree="$(holder_value worktree)"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=1
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS

    _fast_lock_try_acquire_metadata_guard() {
        sleep 1
        return "$CONTENTION_EXIT_CODE"
    }

    start="$(wall_clock_seconds)"
    ( acquire_fast_lock >"$FIXTURE_DIR/missing_guard.stdout" \
        2>"$FIXTURE_DIR/missing_guard.stderr" ) || rc=$?
    end="$(wall_clock_seconds)"
    elapsed="$(awk -v start="$start" -v end="$end" 'BEGIN { printf "%.3f", end - start }')"
    output="$(cat "$FIXTURE_DIR/missing_guard.stderr")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"

    assert_elapsed_between "$elapsed" "1" "4.5" \
        "missing-guard fallback race is still charged to the configured wait budget"
    assert_eq "$rc" "$CONTENTION_EXIT_CODE" \
        "missing-guard fallback race still returns the reserved refusal code"
    assert_eq "$normalized" "$(expected_refusal "$holder_pid" "$holder_worktree" "1")" \
        "missing-guard fallback race reuses the completed holder diagnostic"

    source "$LOCK_LIB"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
    release_fast_lock
    cleanup_fixture
}

test_wait_seconds_parse_decimal_and_clamp_invalid() {
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=08
    assert_eq "$(_fast_lock_wait_seconds)" "8" \
        "leading-zero wait values are normalized as decimal"
    assert_eq "$(_fast_lock_wait_hundredths)" "800" \
        "normalized decimal wait values are safe in Bash arithmetic"

    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=-1
    assert_eq "$(_fast_lock_wait_seconds)" "0" \
        "negative wait values clamp to immediate refusal"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=not_a_number
    assert_eq "$(_fast_lock_wait_seconds)" "0" \
        "non-numeric wait values clamp to immediate refusal"
    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
}

test_in_progress_holder_publication_is_not_reclaimed() {
    local publisher_pid publisher_rc contender_rc=0 contender_output
    local contender_started contender_finished contender_elapsed expected_publisher_pid
    new_fixture

    _fast_lock_write_holder() {
        local lock_dir="$1" worktree="$2"
        printf 'started\n' > "$FIXTURE_DIR/publisher.started"
        sleep 6
        printf 'pid=%s\nworktree=%s\nstarted_at=%s\n' \
            "${BASHPID:-$$}" "$worktree" "$(date +%s)" \
            > "$lock_dir/holder"
    }

    (
        trap - EXIT
        publisher_rc=0
        printf '%s' "${BASHPID:-$$}" > "$FIXTURE_DIR/publisher.expected_pid"
        acquire_fast_lock >"$FIXTURE_DIR/publisher.stdout" 2>"$FIXTURE_DIR/publisher.stderr"
        publisher_rc=$?
        printf '%s' "$publisher_rc" > "$FIXTURE_DIR/publisher.rc"
        if [ "$publisher_rc" -eq 0 ]; then
            : > "$FIXTURE_DIR/publisher.acquired"
            while [ ! -f "$FIXTURE_DIR/publisher.release" ]; do
                sleep 0.05
            done
            release_fast_lock
        fi
    ) &
    publisher_pid=$!

    while [ ! -f "$FIXTURE_DIR/publisher.started" ]; do
        sleep 0.05
    done

    contender_started="$(wall_clock_seconds)"
    ( acquire_fast_lock >"$FIXTURE_DIR/contender.stdout" 2>"$FIXTURE_DIR/contender.stderr" ) \
        || contender_rc=$?
    contender_finished="$(wall_clock_seconds)"
    contender_elapsed="$(awk -v start="$contender_started" -v finish="$contender_finished" \
        'BEGIN { print finish - start }')"
    : > "$FIXTURE_DIR/publisher.release"
    wait "$publisher_pid" 2>/dev/null || true
    publisher_rc="$(cat "$FIXTURE_DIR/publisher.rc")"
    contender_output="$(cat "$FIXTURE_DIR/contender.stderr")"
    expected_publisher_pid="$(cat "$FIXTURE_DIR/publisher.expected_pid")"

    assert_eq "$publisher_rc" "0" \
        "publisher acquires the lock after delayed holder publication"
    assert_elapsed_between "$contender_elapsed" "0" "2" \
        "default-zero contender refuses immediately while publication is paused"
    assert_eq "$contender_rc" "$CONTENTION_EXIT_CODE" \
        "contender refuses instead of reclaiming an in-progress holder publication"
    assert_eq "$(printf '%s' "$contender_output" | normalize_refusal)" \
        "$(expected_refusal "$expected_publisher_pid" "$FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE" "0")" \
        "in-progress refusal names the true paused publisher"
    assert_not_contains "$contender_output" "reclaiming corrupt local-ci --fast lock" \
        "in-progress publication is not treated as a corrupt holder"
    assert_eq "$(cat "$FIXTURE_DIR/contender.stdout")" "" \
        "in-progress publication refusal keeps the diagnostic on stderr"

    source "$LOCK_LIB"
    cleanup_fixture
}

test_orphaned_reclaim_claim_is_recovered() {
    local contender_pid contender_rc attempts=0
    new_fixture
    seed_reclaimable_holder stale
    mkdir "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR/.reclaiming"

    (
        trap - EXIT
        local rc=0
        printf '%s' "${BASHPID:-$$}" > "$FIXTURE_DIR/orphan.expected_pid"
        acquire_fast_lock >"$FIXTURE_DIR/orphan.stdout" 2>"$FIXTURE_DIR/orphan.stderr" \
            || rc=$?
        printf '%s' "$rc" > "$FIXTURE_DIR/orphan.rc"
    ) &
    contender_pid=$!

    while [ ! -f "$FIXTURE_DIR/orphan.rc" ] && [ "$attempts" -lt 40 ]; do
        sleep 0.05
        attempts=$(( attempts + 1 ))
    done
    if [ -f "$FIXTURE_DIR/orphan.rc" ]; then
        contender_rc="$(cat "$FIXTURE_DIR/orphan.rc")"
    else
        contender_rc="timed_out"
        kill "$contender_pid" 2>/dev/null || true
    fi
    wait "$contender_pid" 2>/dev/null || true

    assert_eq "$contender_rc" "0" \
        "an orphaned reclaim claim does not wedge immediate acquisition"
    assert_eq "$(holder_value pid)" "$(cat "$FIXTURE_DIR/orphan.expected_pid")" \
        "orphaned reclaim recovery replaces the dead holder record"

    release_fast_lock
    cleanup_fixture
}

test_orphaned_metadata_guard_is_recovered() {
    local rc=0
    new_fixture
    printf 'pid=99999999\nprocess_pid=99999999\nworktree=%s\nstarted_at=%s\n' \
        "$FIXTURE_DIR/orphaned_guard" "$(date +%s)" \
        > "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR.guard"

    acquire_fast_lock >"$FIXTURE_DIR/orphan_guard.stdout" \
        2>"$FIXTURE_DIR/orphan_guard.stderr" || rc=$?

    assert_eq "$rc" "0" \
        "an unlocked orphaned metadata guard is reclaimed"
    assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
        "metadata-guard recovery installs the current holder"
    assert_eq "$([ -e "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR.guard" ] && printf present || printf absent)" \
        "absent" "metadata guard path is removed after acquisition metadata completes"

    release_fast_lock
    cleanup_fixture
}

test_interrupted_reclaimer_releases_metadata_guard() {
    local reclaimer_pid replacement_rc=0 attempts=0
    new_fixture
    seed_reclaimable_holder stale
    mkfifo "$FIXTURE_DIR/reclaimer.blocker"

    (
        trap - EXIT
        rm() {
            if [ "${1:-}" = "-rf" ] \
                && [ "${2:-}" = "$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR" ]
            then
                : > "$FIXTURE_DIR/reclaimer.entered"
                read -r _ < "$FIXTURE_DIR/reclaimer.blocker"
            fi
            command rm "$@"
        }
        acquire_fast_lock >"$FIXTURE_DIR/interrupted.stdout" \
            2>"$FIXTURE_DIR/interrupted.stderr"
    ) &
    reclaimer_pid=$!

    while [ ! -f "$FIXTURE_DIR/reclaimer.entered" ] && [ "$attempts" -lt 40 ]; do
        sleep 0.05
        attempts=$(( attempts + 1 ))
    done
    kill "$reclaimer_pid" 2>/dev/null || true
    wait "$reclaimer_pid" 2>/dev/null || true
    sleep 0.1

    acquire_fast_lock >"$FIXTURE_DIR/replacement.stdout" \
        2>"$FIXTURE_DIR/replacement.stderr" || replacement_rc=$?

    assert_eq "$replacement_rc" "0" \
        "an interrupted reclaimer releases the metadata guard"
    assert_eq "$(holder_value pid)" "${BASHPID:-$$}" \
        "acquisition after reclaimer interruption installs a live holder"

    release_fast_lock
    cleanup_fixture
}

# A refusal issued while a publisher is mid-acquisition reads the atomically
# published guard record. A lexicographically-first obsolete waiting intent
# reproduces the old fallback input and proves it cannot displace the actual
# guard-owning publisher.
test_refusal_uses_completed_holder_during_torn_owner_read() {
    local publisher_pid waiter_pid attempts=0 contender_rc=0
    local lock_dir publisher_holder_pid output normalized
    new_fixture
    lock_dir="$FJCLOUD_LOCAL_CI_FAST_LOCK_DIR"

    _fast_lock_write_holder() {
        local ld="$1" wt="$2"
        printf 'started\n' > "$FIXTURE_DIR/publisher.started"
        sleep 1
        printf 'pid=%s\nworktree=%s\nstarted_at=%s\n' \
            "${BASHPID:-$$}" "$wt" "$(date +%s)" > "$ld/holder"
    }
    (
        trap - EXIT
        local rc=0
        printf '%s' "${BASHPID:-$$}" > "$FIXTURE_DIR/publisher.expected_pid"
        acquire_fast_lock >"$FIXTURE_DIR/publisher.stdout" \
            2>"$FIXTURE_DIR/publisher.stderr" || rc=$?
        printf '%s' "$rc" > "$FIXTURE_DIR/publisher.rc"
        if [ "$rc" -eq 0 ]; then
            : > "$FIXTURE_DIR/publisher.acquired"
            while [ ! -f "$FIXTURE_DIR/publisher.release" ]; do
                sleep 0.05
            done
            release_fast_lock
        fi
    ) &
    publisher_pid=$!
    while [ ! -f "$FIXTURE_DIR/publisher.started" ] && [ "$attempts" -lt 120 ]; do
        sleep 0.05
        attempts=$(( attempts + 1 ))
    done

    ( trap - EXIT; exec sleep 30 ) &
    waiter_pid=$!
    # `-` sorts before mktemp's [A-Za-z0-9] suffixes, so this waiting intent is
    # lexicographically first — the old code would return it.
    printf 'pid=%s\nprocess_pid=%s\nworktree=%s\nstarted_at=%s\n' \
        "$waiter_pid" "$waiter_pid" "$lock_dir/waiting_contender" "$(date +%s)" \
        > "$lock_dir.acquiring.------"

    acquire_fast_lock >"$FIXTURE_DIR/contender.stdout" \
        2>"$FIXTURE_DIR/contender.stderr" || contender_rc=$?
    output="$(cat "$FIXTURE_DIR/contender.stderr")"
    normalized="$(printf '%s' "$output" | normalize_refusal)"
    publisher_holder_pid="$(cat "$FIXTURE_DIR/publisher.expected_pid")"

    assert_eq "$contender_rc" "$CONTENTION_EXIT_CODE" \
        "torn-owner contender immediately refuses during publisher metadata"
    assert_eq "$normalized" \
        "$(expected_refusal "$publisher_holder_pid" "$FJCLOUD_LOCAL_CI_FAST_LOCK_WORKTREE" "0")" \
        "torn-owner refusal uses the atomic publisher guard record"
    assert_not_contains "$output" "$lock_dir/waiting_contender" \
        "torn-owner refusal never names an arbitrary waiting contender"
    assert_eq "$(cat "$FIXTURE_DIR/contender.stdout")" "" \
        "torn-owner refusal keeps the diagnostic on stderr"

    : > "$FIXTURE_DIR/publisher.release"
    wait "$publisher_pid" 2>/dev/null || true
    kill "$waiter_pid" 2>/dev/null || true
    wait "$waiter_pid" 2>/dev/null || true
    source "$LOCK_LIB"
    cleanup_fixture
}

test_concurrent_stale_reclaimers_have_one_winner() {
    run_concurrent_reclaimer_case stale
}

test_concurrent_corrupt_reclaimers_have_one_winner() {
    run_concurrent_reclaimer_case corrupt
}

test_unset_wait_budget_defaults_to_bounded_wait() {
    # Regression: nothing in this repo or the orchestrator ever exports the
    # knob, so the effective budget on every real worker was 0 and a second
    # concurrent whole-suite run refused instantly with exit 75. Lanes then
    # recorded `--fast` as an unrunnable gate and pushed on a hand-picked gate
    # subset instead, which is how partially validated work reached `main`.
    # An unset budget must queue behind the holder rather than refuse.
    local queues
    unset FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS
    assert_eq "$(_fast_lock_wait_seconds)" "$FAST_LOCK_DEFAULT_WAIT_SECONDS" \
        "an unset wait budget falls back to the bounded-wait default"
    queues=$([ "$(_fast_lock_wait_seconds)" -gt 0 ] && printf 'queues' || printf 'refuses')
    assert_eq "$queues" "queues" \
        "the default budget is positive so contention queues instead of refusing"

    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=""
    assert_eq "$(_fast_lock_wait_seconds)" "$FAST_LOCK_DEFAULT_WAIT_SECONDS" \
        "an empty wait budget falls back to the same default"

    FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS=0
    assert_eq "$(_fast_lock_wait_seconds)" "0" \
        "an explicit 0 still opts into immediate refusal"
    export FJCLOUD_LOCAL_CI_FAST_LOCK_WAIT_SECONDS
}

test_default_wait_plus_one_run_fits_the_caller_session() {
    # Budgets come from the sourced FAST_LOCK_* constants so this stays pinned
    # to the single owner rather than to literals copied into the harness.
    #
    # This assertion was inverted until 2026-08-06. It recorded the constraint
    # as OPEN and named its two closing moves: shrink the whole-suite gate, or
    # raise matt's caller timeout. The second was taken --- matt's `build` and
    # `review_remediation` prompt types are now sized against this repo's
    # measured gate rather than sharing the generic session fallback. The test
    # is kept, not deleted, because its arithmetic is the tripwire that fires
    # if the gate grows back past the budget.
    #
    # It also carried a real defect while it was open: it compared the run
    # against the whole session budget, but matt interrupts a session for
    # wrap-up at 90% of that budget, so the deadline a gate must actually beat
    # was 10% lower than this test claimed. The wrap-up lead is included below.
    local working_budget worst_case_seconds fits positive margin_seconds

    assert_eq "$FAST_LOCK_MEASURED_FAST_RUN_SECONDS" "2386" \
        "measured runtime rounds the same-locality 2385.98-second specimen up without under-counting"
    assert_eq "$FAST_LOCK_DEFAULT_WAIT_SECONDS" "300" \
        "default wait is the Stage 2 retune value, not a false green residual"

    # Integer arithmetic only: this harness runs under bash 3.2, which has no
    # floating point. 90% is expressed as *9/10 rather than *0.9.
    working_budget=$(( FAST_LOCK_CALLER_SESSION_BUDGET_SECONDS
        * (100 - FAST_LOCK_CALLER_SESSION_WRAPUP_LEAD_PERCENT) / 100 ))
    worst_case_seconds=$(( FAST_LOCK_DEFAULT_WAIT_SECONDS + FAST_LOCK_MEASURED_FAST_RUN_SECONDS ))

    fits=$([ "$worst_case_seconds" -le "$working_budget" ] && printf 'fits' || printf 'exceeds')
    assert_eq "$fits" "fits" \
        "default wait plus one measured run must fit before the caller session's wrap-up interrupt (default_wait=${FAST_LOCK_DEFAULT_WAIT_SECONDS}s + measured_run=${FAST_LOCK_MEASURED_FAST_RUN_SECONDS}s = ${worst_case_seconds}s vs working_budget=${working_budget}s of caller_session_budget=${FAST_LOCK_CALLER_SESSION_BUDGET_SECONDS}s; close by shrinking scripts/local-ci.sh --fast or raising matt's build/review_remediation prompt-type timeout)"

    # Fitting is necessary but not sufficient: a lane that spends its entire
    # session in the gate has no time left to act on the result. Require a
    # stated working margin so a future gate growth that technically fits still
    # fails here rather than silently starving the work the session exists to do.
    #
    # 600s is the floor because a session that runs the whole-suite gate is the
    # one at the END of a stage --- the code is already written --- so what it
    # still owes is interpreting the summary, committing, and pushing. Ten
    # minutes covers that. It deliberately does NOT budget for a second gate
    # run: a red gate legitimately ends the session without pushing and the next
    # session retries, and sizing for two runs would push this budget past any
    # value a hung session should be allowed to burn.
    margin_seconds=$(( working_budget - worst_case_seconds ))
    assert_eq "$([ "$margin_seconds" -ge 600 ] && printf 'sufficient' || printf 'starved')" \
        "sufficient" \
        "the session needs working time beyond the gate; margin=${margin_seconds}s is below the 600s floor"

    # Guards the opposite failure mode: shrinking the default to fit must not
    # take it to 0, which is the instant-refusal regression the bounded wait
    # was introduced to remove.
    positive=$([ "$FAST_LOCK_DEFAULT_WAIT_SECONDS" -gt 0 ] && printf 'positive' || printf 'non-positive')
    assert_eq "$positive" "positive" \
        "the default wait stays positive so contention still queues instead of refusing instantly"
}

trap cleanup_fixture EXIT

test_free_acquire_records_holder_values
test_default_lock_dir_is_stable_through_worktree_symlink
test_contended_acquire_refuses_with_holder_identity
test_refusal_forbids_gate_subset_substitution
test_refusal_consumes_exported_holder_description
test_release_allows_subsequent_acquire
test_dead_holder_is_reclaimed
test_live_holder_reclaim_boundaries
test_pidless_holder_is_reclaimed
test_invalid_pid_holder_is_reclaimed
test_bounded_wait_honors_interval_then_refuses
test_bounded_wait_includes_metadata_guard_attempt_time
test_bounded_wait_accounts_for_missing_guard_fallback_race
test_wait_seconds_parse_decimal_and_clamp_invalid
test_unset_wait_budget_defaults_to_bounded_wait
test_default_wait_plus_one_run_fits_the_caller_session
test_in_progress_holder_publication_is_not_reclaimed
test_orphaned_reclaim_claim_is_recovered
test_orphaned_metadata_guard_is_recovered
test_interrupted_reclaimer_releases_metadata_guard
test_refusal_uses_completed_holder_during_torn_owner_read
test_concurrent_stale_reclaimers_have_one_winner
test_concurrent_corrupt_reclaimers_have_one_winner

run_test_summary
