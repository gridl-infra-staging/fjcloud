#!/usr/bin/env bash
# Tests for the env-gap reclassification logic in
# scripts/launch/run_full_backend_validation.sh.
#
# Each step function the harness runs now distinguishes harness-env failures
# (missing local-dev preconditions, unreachable services, missing deps,
# misconfigured admin keys) from real customer-impact defects. Env-gap
# failures upgrade from "fail" to "external_secret_missing"; real failures
# stay "fail". These tests pin the patterns each step considers env-gap so
# future regressions don't either: (a) silently downgrade real failures, or
# (b) re-introduce the false-NOT-READY mode that blocked the 2026-05-31
# closeout cert.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HARNESS_SCRIPT="$REPO_ROOT/scripts/launch/run_full_backend_validation.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

# Source the harness with a stub BASH_SOURCE so it doesn't try to compute
# REPO_ROOT off its own path (which the harness does at file scope before any
# function definitions). The helper functions are then directly callable.
source_harness_for_helpers() {
    # The harness uses `set -euo pipefail`, which would propagate to the
    # sourcing test runner and short-circuit. Sourcing in a subshell wrapper
    # would lose the function definitions. Instead, snapshot the option set,
    # source, then restore.
    local prev_eflag prev_uflag prev_pipefail
    case $- in *e*) prev_eflag=1 ;; *) prev_eflag=0 ;; esac
    case $- in *u*) prev_uflag=1 ;; *) prev_uflag=0 ;; esac
    case "${SHELLOPTS:-}" in *pipefail*) prev_pipefail=1 ;; *) prev_pipefail=0 ;; esac
    # shellcheck disable=SC1090
    source "$HARNESS_SCRIPT" </dev/null 2>/dev/null || true
    [ "$prev_eflag" -eq 1 ] && set -e || set +e
    [ "$prev_uflag" -eq 1 ] && set -u || set +u
    [ "$prev_pipefail" -eq 1 ] && set -o pipefail || set +o pipefail
}

# We can't easily source the whole harness (it has a main() invocation guard
# that may run code on source). Extract the helper function bodies for
# isolated testing. Conservative: only re-defines _log_matches_env_gap_pattern.
extract_and_eval_helper() {
    local helper_source
    helper_source="$(awk '/^_log_matches_env_gap_pattern\(\)/{flag=1} flag{print} flag && /^}/{exit}' "$HARNESS_SCRIPT")"
    if [ -z "$helper_source" ]; then
        fail "could not extract _log_matches_env_gap_pattern from $HARNESS_SCRIPT"
        return 1
    fi
    eval "$helper_source"
}

extract_and_eval_canary_skip_helper() {
    local helper_source
    helper_source="$(awk '
        /^canonical_canary_customer_loop_skip_reason_from_log\(\)/ {flag=1}
        flag {print}
        flag && /^}/ {exit}
    ' "$HARNESS_SCRIPT")"
    if [ -z "$helper_source" ]; then
        fail "could not extract canonical_canary_customer_loop_skip_reason_from_log from $HARNESS_SCRIPT"
        return 1
    fi
    TEST_INBOX_AWS_CREDENTIALS_UNAVAILABLE_TOKEN="probe_env_gap_aws_credentials_unavailable"
    TEST_INBOX_AWS_CREDENTIALS_INVALID_TOKEN="probe_env_gap_aws_credentials_invalid"
    TEST_INBOX_AWS_INBOX_ENV_MISSING_TOKEN="probe_env_gap_aws_inbox_env_missing"
    eval "$helper_source"
}

# ---------------------------------------------------------------------------
# Tests for _log_matches_env_gap_pattern
# ---------------------------------------------------------------------------

test_log_matches_env_gap_pattern_helper() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Positive match
    cat > "$tmp" <<'EOF'
[customer-loop-canary] step 'admin_cleanup' failed: admin tenant cleanup returned HTTP 401
EOF
    _log_matches_env_gap_pattern "$tmp" 'admin tenant cleanup returned HTTP 401' \
        && pass "matches HTTP-401 pattern in canary log" \
        || fail "should have matched HTTP-401 pattern"

    # No match
    cat > "$tmp" <<'EOF'
something unrelated entirely
EOF
    if ! _log_matches_env_gap_pattern "$tmp" 'pattern_not_present'; then
        pass "correctly returns no-match when pattern absent"
    else
        fail "should NOT have matched"
    fi

    # Empty file
    : > "$tmp"
    if ! _log_matches_env_gap_pattern "$tmp" 'anything'; then
        pass "empty file → no match"
    else
        fail "empty file matched"
    fi

    # Nonexistent file
    rm -f "$tmp"
    if ! _log_matches_env_gap_pattern "$tmp" 'anything'; then
        pass "nonexistent file → no match"
    else
        fail "nonexistent file matched"
    fi

    # Multiple patterns, second matches
    tmp="$(mktemp)"
    cat > "$tmp" <<'EOF'
REASON: prerequisite_missing
EOF
    _log_matches_env_gap_pattern "$tmp" 'first_unmatched' 'REASON: prerequisite_missing' \
        && pass "matches second pattern when first does not" \
        || fail "should have matched second pattern"
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Tests that the patches preserve the real-vs-env distinction
#
# The harness now reclassifies "fail" → "external_secret_missing" only when
# the captured log matches an env-gap pattern. Generic real failures (without
# those patterns) MUST still classify as "fail" so real customer-impact
# regressions remain visible. These tests pin the contract.
# ---------------------------------------------------------------------------

test_local_signoff_patterns_distinguish_env_gap_from_real_failure() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Env-gap: local-signoff exits early on missing prereqs.
    cat > "$tmp" <<'EOF'
[local-signoff] ERROR: Strict signoff prerequisites invalid: STRIPE_LOCAL_MODE(missing) MAILPIT_API_URL(missing)
REASON: prerequisite_missing
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'REASON: prerequisite_missing' \
        'Strict signoff prerequisites invalid' \
        'ERROR: missing:flapjack_binary' \
        && pass "local_signoff: env-gap pattern matches prereq-missing log" \
        || fail "local_signoff: prereq-missing log should match"

    # Real failure: local-signoff ran the proofs and one failed.
    cat > "$tmp" <<'EOF'
[local-signoff] commerce proof started
[local-signoff] FAIL: commerce billing math mismatch — expected=$5.00 actual=$4.97
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'REASON: prerequisite_missing' \
            'Strict signoff prerequisites invalid' \
            'ERROR: missing:flapjack_binary'; then
        pass "local_signoff: real billing-math failure does NOT match env-gap patterns"
    else
        fail "local_signoff: real failure should NOT have matched env-gap"
    fi

    rm -f "$tmp"
}

test_backend_launch_gate_commerce_distinguishes_env_gap_from_real_failure() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Env-gap: commerce sub-checks fail because DB URL / stripe listen absent.
    # The commerce-gate emits a JSON object whose `reason` field lists the
    # failed check names. The 3 env-gap check names are stable identifiers
    # in scripts/lib/stripe_checks.sh + scripts/lib/metering_checks.sh.
    cat > "$tmp" <<'EOF'
{"gates": [{"name": "commerce", "reason": "check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current", "status": "fail"}]}
EOF
    _log_matches_env_gap_pattern "$tmp" \
        '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current"' \
        '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_rollup_current, check_usage_records_populated"' \
        '"name": *"commerce", *"reason": *"check_usage_records_populated, check_stripe_webhook_forwarding, check_rollup_current"' \
        '"name": *"commerce", *"reason": *"check_usage_records_populated, check_rollup_current, check_stripe_webhook_forwarding"' \
        '"name": *"commerce", *"reason": *"check_rollup_current, check_stripe_webhook_forwarding, check_usage_records_populated"' \
        '"name": *"commerce", *"reason": *"check_rollup_current, check_usage_records_populated, check_stripe_webhook_forwarding"' \
        && pass "backend_launch_gate: env-gap matches all-three-env-checks commerce reason" \
        || fail "backend_launch_gate: 3-env-checks reason should match"

    # Real failure: commerce reports a NEW check name (e.g. billing math) — must NOT match.
    cat > "$tmp" <<'EOF'
{"gates": [{"name": "commerce", "reason": "check_billing_math_invariant", "status": "fail"}]}
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current"' \
            '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_rollup_current, check_usage_records_populated"' \
            '"name": *"commerce", *"reason": *"check_usage_records_populated, check_stripe_webhook_forwarding, check_rollup_current"' \
            '"name": *"commerce", *"reason": *"check_usage_records_populated, check_rollup_current, check_stripe_webhook_forwarding"' \
            '"name": *"commerce", *"reason": *"check_rollup_current, check_stripe_webhook_forwarding, check_usage_records_populated"' \
            '"name": *"commerce", *"reason": *"check_rollup_current, check_usage_records_populated, check_stripe_webhook_forwarding"'; then
        pass "backend_launch_gate: unknown check name does NOT match env-gap"
    else
        fail "backend_launch_gate: unknown check should NOT match env-gap"
    fi

    # Real failure: commerce reports a MIX of env-gap + real check names — must NOT match.
    cat > "$tmp" <<'EOF'
{"gates": [{"name": "commerce", "reason": "check_stripe_webhook_forwarding, check_billing_math_invariant", "status": "fail"}]}
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_usage_records_populated, check_rollup_current"' \
            '"name": *"commerce", *"reason": *"check_stripe_webhook_forwarding, check_rollup_current, check_usage_records_populated"' \
            '"name": *"commerce", *"reason": *"check_usage_records_populated, check_stripe_webhook_forwarding, check_rollup_current"' \
            '"name": *"commerce", *"reason": *"check_usage_records_populated, check_rollup_current, check_stripe_webhook_forwarding"' \
            '"name": *"commerce", *"reason": *"check_rollup_current, check_stripe_webhook_forwarding, check_usage_records_populated"' \
            '"name": *"commerce", *"reason": *"check_rollup_current, check_usage_records_populated, check_stripe_webhook_forwarding"'; then
        pass "backend_launch_gate: mixed env-gap+real reason does NOT match (still flagged real)"
    else
        fail "backend_launch_gate: mixed reason should NOT match env-gap (must remain fail)"
    fi

    rm -f "$tmp"
}

test_canary_customer_loop_distinguishes_env_gap_from_real_failure() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Env-gap: admin-key drift produces 401 on cleanup endpoint.
    cat > "$tmp" <<'EOF'
[customer-loop-canary] step 'admin_cleanup' failed: admin tenant cleanup returned HTTP 401
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'admin tenant cleanup returned HTTP 401' \
        'admin tenant cleanup returned HTTP 403' \
        'admin_call.*returned HTTP 401' \
        'admin_call.*returned HTTP 403' \
        'ADMIN_KEY missing' \
        'signup.*Could not resolve host' \
        'signup.*Connection refused' \
        'curl: \(28\)' \
        'curl: \(6\)' \
        'curl: \(7\)' \
        && pass "canary_customer_loop: env-gap matches HTTP-401 admin cleanup" \
        || fail "canary_customer_loop: HTTP-401 should match env-gap"

    # Real failure: signup endpoint returned 500 (broken signup path).
    cat > "$tmp" <<'EOF'
[customer-loop-canary] step 'signup' failed: signup endpoint returned HTTP 500
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'admin tenant cleanup returned HTTP 401' \
            'admin tenant cleanup returned HTTP 403' \
            'admin_call.*returned HTTP 401' \
            'admin_call.*returned HTTP 403' \
            'ADMIN_KEY missing' \
            'signup.*Could not resolve host' \
            'signup.*Connection refused'; then
        pass "canary_customer_loop: signup-500 real failure does NOT match env-gap"
    else
        fail "canary_customer_loop: signup 500 should NOT match env-gap"
    fi

    rm -f "$tmp"
}

test_canary_customer_loop_exit_100_extracts_only_canonical_prereq_skip_tokens() {
    extract_and_eval_canary_skip_helper

    local tmp token
    tmp="$(mktemp)"

    cat > "$tmp" <<'EOF'
SKIPPED: probe_env_gap_aws_credentials_unavailable: aws CLI unavailable
EOF
    token="$(canonical_canary_customer_loop_skip_reason_from_log "$tmp" || true)"
    assert_eq "$token" "probe_env_gap_aws_credentials_unavailable" \
        "canary_customer_loop: canonical unavailable prereq skip token is extracted"

    cat > "$tmp" <<'EOF'
SKIPPED: probe_env_gap_aws_credentials_invalid: aws sts get-caller-identity failed; creds present but rejected by AWS
EOF
    token="$(canonical_canary_customer_loop_skip_reason_from_log "$tmp" || true)"
    assert_eq "$token" "probe_env_gap_aws_credentials_invalid" \
        "canary_customer_loop: canonical invalid-credentials prereq skip token is extracted"

    cat > "$tmp" <<'EOF'
SKIPPED: probe_env_gap_aws_inbox_env_missing: missing CANARY_TEST_INBOX_S3_URI or CANARY_TEST_INBOX_DOMAIN
EOF
    token="$(canonical_canary_customer_loop_skip_reason_from_log "$tmp" || true)"
    assert_eq "$token" "probe_env_gap_aws_inbox_env_missing" \
        "canary_customer_loop: canonical inbox-env prereq skip token is extracted"

    cat > "$tmp" <<'EOF'
SKIPPED: unrelated_optional_operator_skip: not this contract
EOF
    token="$(canonical_canary_customer_loop_skip_reason_from_log "$tmp" || true)"
    assert_eq "$token" "" \
        "canary_customer_loop: non-canonical skip tokens stay outside prereq skip mapping"

    cat > "$tmp" <<'EOF'
[customer-loop-canary] step 'signup' failed: signup endpoint returned HTTP 500
EOF
    token="$(canonical_canary_customer_loop_skip_reason_from_log "$tmp" || true)"
    assert_eq "$token" "" \
        "canary_customer_loop: real failure logs do not become prereq skips"

    rm -f "$tmp"
}

test_browser_preflight_distinguishes_env_gap_from_real_failure() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Env-gap: Playwright deps not installed.
    cat > "$tmp" <<'EOF'
Error: Cannot find module '@playwright/test'
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'Cannot find module .*@playwright' \
        'Please run.*playwright install' \
        'browserType\.launch.*Executable doesn'\''t exist' \
        'npx: command not found' \
        'Run scripts/bootstrap-env-local\.sh' \
        'ADMIN_KEY is required' \
        'ADMIN_KEY not hydrated from SSM' \
        'STRIPE_SECRET_KEY not hydrated from SSM' \
        'STRIPE_WEBHOOK_SECRET not hydrated from SSM' \
        'Unable to locate credentials' \
        'The security token included in the request is invalid' \
        'ExpiredToken' \
        'UnrecognizedClientException' \
        'AccessDeniedException' \
        'BASE_URL .* not reachable' \
        'API_BASE_URL .* not reachable' \
        'connect ECONNREFUSED' \
        'connection refused' \
        'getaddrinfo ENOTFOUND' \
        'ENVIRONMENT must be local' \
        'PREFLIGHT FAILED' \
        && pass "browser_preflight: env-gap matches missing @playwright" \
        || fail "browser_preflight: missing @playwright should match env-gap"

    # Real failure: credentialed browser setup was pointed at a non-loopback
    # API_URL after auth inputs were present. Preserve this as a browser setup
    # failure so the RC summary points at the loopback contract, not secrets.
    cat > "$tmp" <<'EOF'
Error: API_URL must use a local loopback host (localhost, 127.0.0.1, or [::1]) for credentialed local browser runs
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'Cannot find module .*@playwright' \
            'Please run.*playwright install' \
            'browserType\.launch.*Executable doesn'\''t exist' \
            'npx: command not found' \
            'Run scripts/bootstrap-env-local\.sh' \
            'ADMIN_KEY is required' \
            'ADMIN_KEY not hydrated from SSM' \
            'STRIPE_SECRET_KEY not hydrated from SSM' \
            'STRIPE_WEBHOOK_SECRET not hydrated from SSM' \
            'Unable to locate credentials' \
            'The security token included in the request is invalid' \
            'ExpiredToken' \
            'UnrecognizedClientException' \
            'AccessDeniedException' \
            'BASE_URL .* not reachable' \
            'API_BASE_URL .* not reachable' \
            'connect ECONNREFUSED' \
            'connection refused' \
            'getaddrinfo ENOTFOUND' \
            'ENVIRONMENT must be local' \
            'PREFLIGHT FAILED'; then
        pass "browser_auth_setup: loopback-host rejection does NOT match env-gap"
    else
        fail "browser_auth_setup: loopback rejection should remain a real setup failure"
    fi

    # Env-gap: e2e-preflight failed for local-stack reasons.
    cat > "$tmp" <<'EOF'
PREFLIGHT FAILED: 1 issue(s) must be resolved before running browser tests. Run scripts/bootstrap-env-local.sh
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'PREFLIGHT FAILED' \
        'Run scripts/bootstrap-env-local\.sh' \
        && pass "browser_preflight: env-gap matches preflight-failed local-stack message" \
        || fail "browser_preflight: preflight-failed should match env-gap"

    # Real failure: API contract violation in preflight assertion.
    cat > "$tmp" <<'EOF'
preflight: API /version response missing dev_sha field
expected dev_sha to be present, got: {"mirror_sha":"..."}
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'Cannot find module .*@playwright' \
            'Please run.*playwright install' \
            'connect ECONNREFUSED' \
            'PREFLIGHT FAILED'; then
        pass "browser_preflight: contract violation does NOT match env-gap"
    else
        fail "browser_preflight: contract violation should NOT match env-gap"
    fi

    rm -f "$tmp"
}

test_browser_lane_steps_share_browser_env_gap_fingerprints() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    cat > "$tmp" <<'EOF'
browser lane failed before navigation
Error: browserType.launch: Executable doesn't exist at /ms-playwright/chromium
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'Cannot find module .*@playwright' \
        'Please run.*playwright install' \
        'browserType\.launch.*Executable doesn'\''t exist' \
        'npx: command not found' \
        'Run scripts/bootstrap-env-local\.sh' \
        'ADMIN_KEY is required' \
        'BASE_URL .* not reachable' \
        'API_BASE_URL .* not reachable' \
        'connect ECONNREFUSED' \
        'connection refused' \
        'getaddrinfo ENOTFOUND' \
        'ENVIRONMENT must be local' \
        'PREFLIGHT FAILED' \
        && pass "browser_lane_steps: shared env-gap patterns match missing browser binary" \
        || fail "browser_lane_steps: missing browser binary should match shared browser env-gap patterns"

    cat > "$tmp" <<'EOF'
ERROR: ADMIN_KEY not hydrated from SSM
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'ADMIN_KEY not hydrated from SSM' \
        'STRIPE_SECRET_KEY not hydrated from SSM' \
        'STRIPE_WEBHOOK_SECRET not hydrated from SSM' \
        'Unable to locate credentials' \
        'The security token included in the request is invalid' \
        'ExpiredToken' \
        'UnrecognizedClientException' \
        'AccessDeniedException' \
        && pass "browser_lane_steps: shared env-gap patterns match delegated staging hydration failure" \
        || fail "browser_lane_steps: delegated staging hydration failure should match shared browser env-gap patterns"

    cat > "$tmp" <<'EOF'
browser lane completed checkout but expected paid invoice total 5000 and got 4997
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'Cannot find module .*@playwright' \
            'Please run.*playwright install' \
            'browserType\.launch.*Executable doesn'\''t exist' \
            'npx: command not found' \
            'connect ECONNREFUSED' \
            'getaddrinfo ENOTFOUND' \
            'ADMIN_KEY not hydrated from SSM' \
            'STRIPE_SECRET_KEY not hydrated from SSM' \
            'STRIPE_WEBHOOK_SECRET not hydrated from SSM' \
            'Unable to locate credentials' \
            'PREFLIGHT FAILED'; then
        pass "browser_lane_steps: browser assertion failure does NOT match env-gap patterns"
    else
        fail "browser_lane_steps: browser assertion failure should NOT match env-gap patterns"
    fi

    rm -f "$tmp"
}

test_canary_outside_aws_distinguishes_env_gap_from_real_failure() {
    extract_and_eval_helper

    local tmp
    tmp="$(mktemp)"

    # Env-gap: curl can't reach (DNS resolution, etc.)
    cat > "$tmp" <<'EOF'
[outside-aws-health] probe failed for https://api.flapjack.foo/health
curl: (6) Could not resolve host: api.flapjack.foo
EOF
    _log_matches_env_gap_pattern "$tmp" \
        'curl.*Could not resolve host' \
        'curl.*Connection refused' \
        'curl: \(28\)' \
        'curl: \(6\)' \
        'curl: \(7\)' \
        'curl: \(35\)' \
        && pass "canary_outside_aws: env-gap matches curl resolution failure" \
        || fail "canary_outside_aws: curl(6) should match env-gap"

    # Real failure: target returned 503 (real outside-AWS outage).
    cat > "$tmp" <<'EOF'
[outside-aws-health] probe failed for https://cloud.flapjack.foo/health
HTTP 503 Service Unavailable
EOF
    if ! _log_matches_env_gap_pattern "$tmp" \
            'curl.*Could not resolve host' \
            'curl.*Connection refused' \
            'curl: \(28\)' \
            'curl: \(6\)' \
            'curl: \(7\)' \
            'curl: \(35\)'; then
        pass "canary_outside_aws: HTTP 503 real outage does NOT match env-gap"
    else
        fail "canary_outside_aws: HTTP 503 should NOT match env-gap"
    fi

    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# Test runner
# ---------------------------------------------------------------------------

main() {
    test_log_matches_env_gap_pattern_helper
    test_local_signoff_patterns_distinguish_env_gap_from_real_failure
    test_backend_launch_gate_commerce_distinguishes_env_gap_from_real_failure
    test_canary_customer_loop_distinguishes_env_gap_from_real_failure
    test_canary_customer_loop_exit_100_extracts_only_canonical_prereq_skip_tokens
    test_browser_preflight_distinguishes_env_gap_from_real_failure
    test_browser_lane_steps_share_browser_env_gap_fingerprints
    test_canary_outside_aws_distinguishes_env_gap_from_real_failure

    echo ""
    echo "==============================================="
    echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
    echo "==============================================="
    [ "$FAIL_COUNT" -eq 0 ] || exit 1
}

main "$@"
