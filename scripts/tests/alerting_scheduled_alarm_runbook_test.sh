#!/usr/bin/env bash
# Contract for the deploy-currency freeze and scheduled-alarm incident record.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK="$REPO_ROOT/docs/runbooks/alerting.md"
DEPLOY_CURRENCY_SECTION="$(sed -n '/^## Deploy-currency drift alarm$/,/^### API panic alarm$/p' "$RUNBOOK")"
FAIL_COUNT=0

assert_contains() {
    local expected="$1" description="$2"
    if grep -Fq "$expected" <<<"$DEPLOY_CURRENCY_SECTION"; then
        printf 'PASS: %s\n' "$description"
    else
        printf 'FAIL: %s (missing %s)\n' "$description" "$expected" >&2
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
}

assert_contains 'scripts/canary/deploy_currency_check.sh' \
    'the runbook preserves the breach-rule owner'
assert_contains 'scripts/probe_scheduled_alarm_liveness.sh' \
    'the freeze procedure names the scheduled-alarm liveness guard'
assert_contains 'scripts/tests/scheduled_alarm_acknowledgements.txt' \
    'the freeze procedure names the single deliberate-silence registry'
assert_contains 'disabled_manually' \
    'the incident records the disabled staging state'
assert_contains 'zero lifetime runs' \
    'the incident records the empty staging run history'
assert_contains 'prod copy skipped by design' \
    'the incident records the guarded prod behavior'
assert_contains 'existing tests stayed green' \
    'the incident records why static coverage missed the silence'
assert_contains 'found only by external audit' \
    'the incident records how the silence was discovered'

printf '\nSummary: %s failed\n' "$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
