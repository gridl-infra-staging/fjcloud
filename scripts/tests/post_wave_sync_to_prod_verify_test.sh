#!/usr/bin/env bash
# Terminal deploy-verify for a dev->prod debbie sync wave. EXACT-IDENTITY gate:
# the prod deploy must serve precisely the identities the promotion committed
# to, never merely "recent enough" ones.
#
# Owner boundary: this script is the SOLE owner of the served-vs-expected
# identity comparison. post_wave_a_sync_prod.sh (execute_sync) derives the
# expected identities and hands them in via the env vars below, then propagates
# this script's exit status; it does NOT re-implement the comparison.
#
# Expected identities are supplied by the caller (no ambient auto-discovery —
# a verifier that discovers its own expectation can never fail closed):
#   POST_WAVE_EXPECTED_DEV_SHA     40-hex dev-repo HEAD this promotion shipped.
#                                  Served .envs.prod.dev_sha must equal it.
#   POST_WAVE_EXPECTED_MIRROR_SHA  40-hex prod mirror HEAD debbie produced.
#                                  Served .envs.prod.mirror_sha must equal it.
#   POST_WAVE_EXPECTED_PAGES_SHA   40-hex staging-owned Cloudflare Pages commit
#                                  (deploy-staging is the sole Pages deployer).
#                                  Must be a real 40-hex AND must NOT equal the
#                                  prod mirror HEAD — a prod-derived Pages SHA
#                                  means prod CI wrongly republished Pages.
# Optional test seam:
#   POST_WAVE_DEPLOY_STATUS_SCRIPT Override the deploy-status owner path
#                                  (default: scripts/deploy_status.sh) so the
#                                  suite can drive hermetic served-identity
#                                  fixtures instead of a live /version probe.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

is_40hex() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

expected_dev_sha="${POST_WAVE_EXPECTED_DEV_SHA:-}"
expected_mirror_sha="${POST_WAVE_EXPECTED_MIRROR_SHA:-}"
expected_pages_sha="${POST_WAVE_EXPECTED_PAGES_SHA:-}"

# Fail closed on any missing / malformed expectation. No discovery fallback:
# without a caller-supplied expectation there is nothing exact to check, so the
# only safe verdict is FAIL.
for pair in \
    "POST_WAVE_EXPECTED_DEV_SHA:$expected_dev_sha" \
    "POST_WAVE_EXPECTED_MIRROR_SHA:$expected_mirror_sha" \
    "POST_WAVE_EXPECTED_PAGES_SHA:$expected_pages_sha"; do
    name="${pair%%:*}"
    value="${pair#*:}"
    if [ -z "$value" ]; then
        fail "$name is required (no ambient auto-discovery of expected identities)"
    elif ! is_40hex "$value"; then
        fail "$name must be exactly 40 hex chars (got '$value')"
    else
        pass "$name supplied as 40-hex"
    fi
done

deploy_status_script="${POST_WAVE_DEPLOY_STATUS_SCRIPT:-$REPO_ROOT/scripts/deploy_status.sh}"
deploy_json=$(bash "$deploy_status_script" --json 2>/dev/null)

prod_dev_sha=$(echo "$deploy_json" | jq -r '.envs.prod.dev_sha')
prod_mirror_sha=$(echo "$deploy_json" | jq -r '.envs.prod.mirror_sha')

# 1) Served dev_sha must be EXACTLY the promoted dev SHA — not merely an
#    ancestor of origin/main (a stale-but-ancestor prod would pass that window).
if [ "$prod_dev_sha" = "$expected_dev_sha" ]; then
    pass "served prod dev_sha matches expected ${expected_dev_sha:0:12}"
else
    fail "served prod dev_sha ${prod_dev_sha} != expected ${expected_dev_sha}"
fi

# 2) Served mirror_sha must be EXACTLY the prod mirror HEAD debbie produced —
#    not a build-time freshness window. A stale prod that never redeployed keeps
#    an old mirror_sha and now fails here instead of sliding under a 24h age gate.
if [ "$prod_mirror_sha" = "$expected_mirror_sha" ]; then
    pass "served prod mirror_sha matches derived head ${expected_mirror_sha:0:12}"
else
    fail "served prod mirror_sha ${prod_mirror_sha} != derived prod mirror head ${expected_mirror_sha}"
fi

# 3) Pages must stay staging-owned. deploy-staging is the sole Pages deployer
#    (ci_deploy_web_contract_test.sh pins this); prod CI republishing Pages with
#    its own mirror SHA is the failure mode. Reject a prod-derived Pages SHA.
if [ "$expected_pages_sha" = "$expected_mirror_sha" ]; then
    fail "expected Pages SHA equals prod mirror head ${expected_mirror_sha:0:12} — Pages is prod-derived, not staging-owned"
else
    pass "expected Pages SHA is distinct from the prod mirror head (staging-owned)"
fi

run_test_summary
