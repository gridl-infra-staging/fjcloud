#!/usr/bin/env bash
# Regression: the parser in ops/scripts/lib/parse_cloudflare_zone.sh must
# extract .result.name, not the nested .result.plan.name. Captured 2026-05-14
# from the prod-env-provision lane post-mortem.
set -euo pipefail

cd "$(dirname "$0")/../../.."
FIXTURE="ops/scripts/tests/fixtures/cloudflare_zone_get_response.json"
[[ -f "$FIXTURE" ]] || { echo "FAIL: fixture missing at $FIXTURE -- run ops/scripts/tests/capture_cloudflare_zone_fixture.sh"; exit 1; }

# shellcheck disable=SC1091
source ops/scripts/lib/parse_cloudflare_zone.sh

ZONE_RESPONSE=$(cat "$FIXTURE")

# Sanity: fixture must contain BOTH result.name and result.plan.name. If the
# fixture loses the plan field, the test stops exercising the original bug.
jq -e '.result.name == "flapjack.foo" and .result.plan.name == "Free Website"' "$FIXTURE" >/dev/null \
  || { echo "FAIL: fixture no longer contains both result.name and plan.name -- test would silently pass without exercising the bug"; exit 1; }

# Primary assertion: the actual library used by validate_bootstrap.sh.
GOT=$(extract_zone_name "$ZONE_RESPONSE")
[[ "$GOT" == "flapjack.foo" ]] \
  || { echo "FAIL: extract_zone_name returned '$GOT' (expected 'flapjack.foo')"; exit 1; }
echo "PASS: extract_zone_name returned 'flapjack.foo' (the lib used by validate_bootstrap.sh)"

# Canary-of-the-canary: prove the test can fail. Simulate the original buggy
# greedy regex against the fixture and assert it returns the wrong answer.
# If this ever stops returning "Free Website", the fixture has drifted away
# from the bug shape and the regression test is no longer meaningful.
#
# The real Cloudflare response (the original-bug context) was a single-line
# JSON blob; our fixture is jq-pretty-printed on disk for readability, so we
# flatten via `jq -c` before applying the buggy regex. Without flattening,
# sed -n processes per-line and matches the FIRST line's "name" rather than
# the LAST -- which would falsely show the bug as "fixed."
FLAT=$(printf '%s' "$ZONE_RESPONSE" | jq -c '.')
WRONG=$(printf '%s' "$FLAT" | sed -nE 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
[[ "$WRONG" == "Free Website" ]] \
  || { echo "FAIL: original-bug simulation returned '$WRONG' (expected 'Free Website') -- fixture has drifted; re-capture and verify plan.name appears AFTER result.name in the flattened JSON (jq sorts keys alphabetically, so plan > name)"; exit 1; }
echo "PASS: original-bug simulation reproduces 'Free Website' -- fixture genuinely exercises the bug"
