#!/usr/bin/env bash
# clean_orphans_test.sh — Coverage for scripts/clean-orphans.sh.
#
# Tests the parsing/filter logic without spawning real long-lived
# processes (which would be fragile and slow). The script's unit
# functions (etime_to_seconds, comm_is_target) are extracted via
# sourcing a stripped harness; the end-to-end behavior is exercised
# in list-only mode against the live process table.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEAN_SCRIPT="$REPO_ROOT/scripts/clean-orphans.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Source the script's functions by extracting everything up to the
# `# Run`/main-body section. This lets us unit-test internal helpers
# without invoking the main loop.
#
# We rely on a stable marker in clean-orphans.sh: the line that begins
# the main execution. If you move that boundary, update the awk script.
source_helpers() {
    local tmpfn
    tmpfn="$(mktemp)"
    awk '/^if \[ "\$DO_KILL" -eq 1 \]; then$/{exit} {print}' "$CLEAN_SCRIPT" > "$tmpfn"
    # The extracted prefix still has `set -euo pipefail` and the flag
    # parsing while-loop. We need to neuter those so sourcing doesn't
    # try to parse command-line args or fail on `set -u` for unset
    # vars in the caller. Strip them.
    sed -i.bak \
        -e 's/^set -euo pipefail$//' \
        -e '/^while \[ "\$#" -gt 0 \]; do$/,/^done$/d' \
        "$tmpfn"
    # shellcheck disable=SC1090
    source "$tmpfn"
    rm -f "$tmpfn" "$tmpfn.bak"
}

test_etime_to_seconds_mm_ss() {
    source_helpers
    local got
    got="$(etime_to_seconds "00:30")"
    [ "$got" = "30" ] && pass "MM:SS '00:30' -> 30s" \
        || fail "expected 30, got '$got'"
}

test_etime_to_seconds_hh_mm_ss() {
    source_helpers
    local got
    got="$(etime_to_seconds "01:30:00")"
    [ "$got" = "5400" ] && pass "HH:MM:SS '01:30:00' -> 5400s (1.5h)" \
        || fail "expected 5400, got '$got'"
}

test_etime_to_seconds_days() {
    source_helpers
    local got
    got="$(etime_to_seconds "01-20:20:38")"
    # 1*86400 + 20*3600 + 20*60 + 38 = 86400 + 72000 + 1200 + 38 = 159638
    [ "$got" = "159638" ] && pass "D-HH:MM:SS '01-20:20:38' -> 159638s" \
        || fail "expected 159638, got '$got'"
}

test_etime_to_seconds_handles_leading_zeros() {
    source_helpers
    # Leading zeros must not trigger octal interpretation (08, 09 would
    # error in $((08)) ).
    local got
    got="$(etime_to_seconds "00-08:09:00")"
    # 0 + 8*3600 + 9*60 + 0 = 28800 + 540 = 29340
    [ "$got" = "29340" ] && pass "leading-zero hours/minutes don't break (08:09 valid)" \
        || fail "expected 29340, got '$got'"
}

test_comm_is_target_matches() {
    source_helpers
    comm_is_target fjcloud-api      && pass "comm_is_target fjcloud-api matches" \
        || fail "fjcloud-api should be a target"
    comm_is_target fj-metering-agent && pass "comm_is_target fj-metering-agent matches" \
        || fail "fj-metering-agent should be a target"
    comm_is_target flapjack         && pass "comm_is_target flapjack matches" \
        || fail "flapjack should be a target"
}

test_comm_is_target_rejects_non_targets() {
    source_helpers
    if comm_is_target launchd; then
        fail "launchd should NOT be a target"
    else
        pass "comm_is_target launchd rejected"
    fi
    if comm_is_target ""; then
        fail "empty string should NOT be a target"
    else
        pass "comm_is_target empty string rejected"
    fi
    if comm_is_target fjcloud-api-other; then
        fail "fjcloud-api-other (suffix) should NOT match exact target"
    else
        pass "comm_is_target rejects non-exact matches"
    fi
}

test_list_mode_runs_without_killing() {
    # Smoke: invoking list mode against the real process table must exit
    # 0, not kill anything, and produce structured output that matches
    # our expected format.
    local out
    out="$(bash "$CLEAN_SCRIPT" 2>&1)"
    if ! echo "$out" | grep -q "^\[clean-orphans\] Mode: list only"; then
        fail "list mode banner missing; got: $out"
        return
    fi
    if ! echo "$out" | grep -q "^\[clean-orphans\] Summary:"; then
        fail "summary line missing; got: $out"
        return
    fi
    if echo "$out" | grep -q "FAILED to kill"; then
        fail "list mode should never attempt kills; got: $out"
        return
    fi
    pass "list mode runs cleanly with banner+summary, no kill attempts"
}

test_min_age_filter_excludes_young() {
    # Set min-age very high (10000 days). No real orphans should be
    # older than that, so the script must report zero matches.
    local out
    out="$(bash "$CLEAN_SCRIPT" --min-age $((86400 * 10000)) 2>&1)"
    if echo "$out" | grep -q "found=0 \|No orphans matched"; then
        pass "min-age filter excludes everything when threshold exceeds reality"
    else
        fail "min-age 10000d should exclude all; got: $out"
    fi
}

# ---------------------------------------------------------------------------
test_etime_to_seconds_mm_ss
test_etime_to_seconds_hh_mm_ss
test_etime_to_seconds_days
test_etime_to_seconds_handles_leading_zeros
test_comm_is_target_matches
test_comm_is_target_rejects_non_targets
test_list_mode_runs_without_killing
test_min_age_filter_excludes_young

echo ""
echo "Summary: $PASS_COUNT passed, $FAIL_COUNT failed"
[ "$FAIL_COUNT" -eq 0 ] || exit 1
