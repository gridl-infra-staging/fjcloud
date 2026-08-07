#!/usr/bin/env bash

# Hermetic contract tests for scripts/security/probe_signup_closed.sh.
#
# These run with no network I/O: the probe's --fixture-status/--fixture-body mode
# feeds it the exact response shapes it must classify. The cases that matter most
# are the negative controls -- the ones asserting the probe REFUSES to report
# CLOSED for a response that merely resembles a closed endpoint. A probe that
# cannot go red for an outage or for a marker-bearing 200 is not a guard.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The probe and its contract live in scripts/security/; this suite sits in
# scripts/tests/ so the local-CI reachability manifest picks it up.
SECURITY_DIR="$(cd "$SCRIPT_DIR/../security" && pwd)"
PROBE="$SECURITY_DIR/probe_signup_closed.sh"
# shellcheck source=../security/signup_block_contract.sh disable=SC1091
source "$SECURITY_DIR/signup_block_contract.sh"

PASS=0
FAIL=0

# assert_case <description> <expected_verdict> <expected_exit> <status> [body]
assert_case() {
    local desc="$1" want_verdict="$2" want_exit="$3" status="$4" body="${5:-}"
    local out rc got_verdict

    out="$(bash "$PROBE" --fixture-status "$status" --fixture-body "$body" 2>&1)"
    rc=$?
    got_verdict="$(printf '%s\n' "$out" | sed -n 's/^verdict=//p')"

    if [ "$got_verdict" = "$want_verdict" ] && [ "$rc" = "$want_exit" ]; then
        printf 'PASS: %s\n' "$desc"
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n      want verdict=%s exit=%s; got verdict=%s exit=%s\n' \
            "$desc" "$want_verdict" "$want_exit" "${got_verdict:-<none>}" "$rc"
        FAIL=$((FAIL + 1))
    fi
}

# --- The one shape that may report CLOSED -----------------------------------
assert_case "marker-bearing refusal is the only CLOSED verdict" \
    CLOSED 0 "$SIGNUP_BLOCK_STATUS" "service unavailable: $SIGNUP_BLOCK_MARKER"

# --- Negative controls: near-misses that must NOT read as closed ------------
# A real ALB/target-group outage returns a bare 503. If this ever reports CLOSED,
# an outage would be recorded as a security control.
assert_case "bare 503 outage is INDETERMINATE, never CLOSED" \
    INDETERMINATE 1 "$SIGNUP_BLOCK_STATUS" "503 Service Temporarily Unavailable"

# The marker alone must not rescue a success. If the handler ran and returned 2xx,
# registration is open no matter what the body happens to contain.
assert_case "marker in a 200 body is still OPEN" \
    OPEN 1 "200" "$SIGNUP_BLOCK_MARKER"

assert_case "marker in a 201 body is still OPEN" \
    OPEN 1 "201" "created; $SIGNUP_BLOCK_MARKER"

# --- Live-endpoint shapes: the handler ran, so registration is OPEN ---------
# 422 is what production returns today: deserialization rejected the payload,
# which proves the route is live and processing.
assert_case "422 validation refusal is OPEN (handler ran)" \
    OPEN 1 "422" "missing field \`name\`"

assert_case "400 validation refusal is OPEN (handler ran)" \
    OPEN 1 "400" "name, email, and password are required"

assert_case "409 duplicate-email conflict is OPEN (handler ran)" \
    OPEN 1 "409" "email already registered"

assert_case "200 is OPEN" OPEN 1 "200" "ok"

# --- Indeterminate: never default to healthy --------------------------------
assert_case "transport failure (no status) is INDETERMINATE" \
    INDETERMINATE 1 "" ""

assert_case "non-numeric status is INDETERMINATE" \
    INDETERMINATE 1 "not-a-status" ""

# 404 could mean the route was removed, or that the probe was pointed at the
# wrong host. Either way it cannot prove the block is what is refusing.
assert_case "404 is INDETERMINATE, not CLOSED" \
    INDETERMINATE 1 "404" "not found"

assert_case "500 is INDETERMINATE, not CLOSED" \
    INDETERMINATE 1 "500" "internal error"

printf '\n=== Results: %d passed, %d failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
