#!/usr/bin/env bash
# Tests for scripts/reliability/ profile artifacts.
# Validates: artifact presence, staleness, and JSON schema conformance.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROFILES_DIR="$REPO_ROOT/scripts/reliability/profiles"
SEED_PROFILES_SCRIPT="$REPO_ROOT/scripts/reliability/seed-test-profiles.sh"

PASS_COUNT=0
FAIL_COUNT=0
BOOTSTRAPPED_PROFILES=0
PROFILES_DIR_PREEXISTED=0
if [ -d "$PROFILES_DIR" ]; then
    PROFILES_DIR_PREEXISTED=1
fi

cleanup_bootstrapped_profiles() {
    if [ "$BOOTSTRAPPED_PROFILES" -eq 1 ] && [ "$PROFILES_DIR_PREEXISTED" -eq 0 ]; then
        rm -rf "$PROFILES_DIR"
    fi
}
trap cleanup_bootstrapped_profiles EXIT

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

# ============================================================================
# Profile artifact presence tests
# ============================================================================

TIERS=("1k" "10k" "100k")
METRIC_TYPES=("cpu" "mem" "disk" "latency")

artifact_exists() {
    local tier="$1" metric="$2"
    [ -f "$PROFILES_DIR/${tier}_${metric}.json" ]
}

required_artifacts_exist() {
    local tier metric
    for tier in "${TIERS[@]}"; do
        for metric in "${METRIC_TYPES[@]}"; do
            if ! artifact_exists "$tier" "$metric"; then
                return 1
            fi
        done
    done
    [ -f "$PROFILES_DIR/summary.json" ]
}

bootstrap_profile_artifacts_if_missing() {
    if required_artifacts_exist; then
        return 0
    fi

    if [ ! -x "$SEED_PROFILES_SCRIPT" ]; then
        fail "cannot bootstrap missing profile artifacts: seed script not executable at $SEED_PROFILES_SCRIPT"
        return 1
    fi

    local seed_output
    if ! seed_output="$("$SEED_PROFILES_SCRIPT" 2>&1)"; then
        fail "profile bootstrap failed via seed-test-profiles.sh"
        echo "$seed_output" >&2
        return 1
    fi

    if ! required_artifacts_exist; then
        fail "profile bootstrap completed but required artifacts are still missing"
        return 1
    fi

    BOOTSTRAPPED_PROFILES=1
    pass "profile artifacts bootstrapped via seed-test-profiles.sh"
    return 0
}

test_profile_artifacts_exist() {
    for tier in "${TIERS[@]}"; do
        for metric in "${METRIC_TYPES[@]}"; do
            local artifact="$PROFILES_DIR/${tier}_${metric}.json"
            if [ -f "$artifact" ]; then
                pass "artifact exists: ${tier}_${metric}.json"
            else
                fail "artifact missing: ${tier}_${metric}.json (expected at $artifact)"
            fi
        done
    done
}

test_summary_artifact_exists() {
    local summary="$PROFILES_DIR/summary.json"
    if [ -f "$summary" ]; then
        pass "summary.json exists"
    else
        fail "summary.json missing (expected at $summary)"
    fi
}

# ============================================================================
# Profile staleness tests
# ============================================================================

test_profile_artifacts_not_stale() {
    local max_age_days="${RELIABILITY_STALENESS_DAYS:-30}"
    local max_age_secs=$((max_age_days * 86400))
    local now
    now="$(date +%s)"

    for tier in "${TIERS[@]}"; do
        for metric in "${METRIC_TYPES[@]}"; do
            local artifact="$PROFILES_DIR/${tier}_${metric}.json"
            if [ ! -f "$artifact" ]; then
                fail "staleness check skipped (missing): ${tier}_${metric}.json"
                continue
            fi
            local mtime
            # macOS stat vs GNU stat
            if stat -f %m "$artifact" >/dev/null 2>&1; then
                mtime="$(stat -f %m "$artifact")"
            else
                mtime="$(stat -c %Y "$artifact")"
            fi
            local age=$((now - mtime))
            if [ "$age" -gt "$max_age_secs" ]; then
                fail "stale artifact: ${tier}_${metric}.json is ${age}s old (max ${max_age_secs}s / ${max_age_days}d)"
            else
                pass "fresh artifact: ${tier}_${metric}.json (${age}s old)"
            fi
        done
    done
}

# ============================================================================
# Profile JSON schema validation tests
# ============================================================================

test_profile_json_schema() {
    for tier in "${TIERS[@]}"; do
        for metric in "${METRIC_TYPES[@]}"; do
            local artifact="$PROFILES_DIR/${tier}_${metric}.json"
            if [ ! -f "$artifact" ]; then
                fail "schema check skipped (missing): ${tier}_${metric}.json"
                continue
            fi

            # Must be valid JSON
            if ! python3 -m json.tool "$artifact" >/dev/null 2>&1; then
                fail "invalid JSON: ${tier}_${metric}.json"
                continue
            fi

            # Must have required top-level keys: tier, timestamp, envelope
            local validation
            validation="$(python3 -c "
import json, sys
with open('$artifact') as f:
    d = json.load(f)
errors = []
if d.get('tier') != '$tier':
    errors.append(f\"tier: expected '$tier', got '{d.get('tier')}'\" )
if 'timestamp' not in d:
    errors.append('missing timestamp')
if 'envelope' not in d or not isinstance(d['envelope'], dict):
    errors.append('missing or invalid envelope')
if errors:
    print('ERRORS: ' + '; '.join(errors))
else:
    print('OK')
" 2>&1)"

            if [ "$validation" = "OK" ]; then
                pass "schema valid: ${tier}_${metric}.json"
            else
                fail "schema invalid: ${tier}_${metric}.json — $validation"
            fi
        done
    done
}

test_summary_json_schema() {
    local summary="$PROFILES_DIR/summary.json"
    if [ ! -f "$summary" ]; then
        fail "summary schema check skipped (missing)"
        return
    fi

    local validation
    validation="$(python3 -c "
import json, sys
with open('$summary') as f:
    d = json.load(f)
errors = []
if 'generated_at' not in d:
    errors.append('missing generated_at')
if 'tiers' not in d or not isinstance(d['tiers'], dict):
    errors.append('missing or invalid tiers')
else:
    for tier in ['1k', '10k', '100k']:
        if tier not in d['tiers']:
            errors.append(f'missing tier: {tier}')
        else:
            t = d['tiers'][tier]
            for metric in ['cpu', 'mem', 'disk', 'latency']:
                if metric not in t:
                    errors.append(f'tier {tier} missing metric: {metric}')
if errors:
    print('ERRORS: ' + '; '.join(errors))
else:
    print('OK')
" 2>&1)"

    if [ "$validation" = "OK" ]; then
        pass "summary.json schema valid"
    else
        fail "summary.json schema invalid — $validation"
    fi
}

# ============================================================================
# Run tests
# ============================================================================

echo "=== reliability profile artifact tests ==="
echo ""
echo "--- artifact bootstrap ---"
if ! bootstrap_profile_artifacts_if_missing; then
    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    exit 1
fi
echo ""
echo "--- artifact presence ---"
test_profile_artifacts_exist
test_summary_artifact_exists
echo ""
echo "--- artifact staleness ---"
test_profile_artifacts_not_stale
echo ""
echo "--- JSON schema ---"
test_profile_json_schema
test_summary_json_schema
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
