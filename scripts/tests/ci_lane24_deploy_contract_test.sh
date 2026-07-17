#!/usr/bin/env bash
# Static exact-source / exact-destination deployment contract for Lane 24
# (customer-facing Algolia-migration safety bytes). Hermetic: it inspects only
# .github/workflows/ci.yml, .debbie.toml, and the two prod-sync guard scripts —
# never a live deploy.
#
# WHAT THIS PINS (and why each matters for Lane 24):
#   1. deploy-staging is the SOLE `wrangler pages deploy` owner for BOTH the
#      production (--branch=main) and staging (--branch=staging) Pages aliases.
#      A second Pages deployer on any other job would race those aliases and
#      could republish stale/mismatched web bytes.
#   2. deploy-prod deploys the prod API ONLY (build + upload + trigger) and
#      carries no Pages deploy — so promoting the API can never clobber the
#      staging-owned Pages SHA.
#   3. debbie feeds the deploy the EXACT caller-merged dev SHA via the sync
#      manifest (.debbie/sync_manifest.json .dev_sha) over a clean canonical
#      checkout (.debbie.toml sync scope), never worktree-only build bytes.
#   4. The prod-sync guards reject the loose/ancestor/prod-derived matches that
#      the exact-identity gate replaced.
#
# Reuses the shared workflow parser (lib/ci_workflow_contract.sh) — it does NOT
# fork a second ci.yml parser.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"
DEBBIE_TOML="$REPO_ROOT/.debbie.toml"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"
SYNC_HELPER="$REPO_ROOT/scripts/launch/post_wave_a_sync_prod.sh"
VERIFY_SCRIPT="$REPO_ROOT/scripts/tests/post_wave_sync_to_prod_verify_test.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/ci_workflow_contract.sh"

echo ""
echo "=== Lane 24 exact deploy-contract tests ==="
echo ""

# --- 1. Sole Pages deployer for BOTH aliases -------------------------------
# Scan every top-level job; exactly one (deploy-staging) may carry a
# `wrangler ... pages deploy`. Any second deployer fails this contract.
pages_deployer_jobs=()
while IFS= read -r job; do
    if job_block "$job" | grep -Ev '^[[:space:]]*#' | grep -Eq 'wrangler@4 pages deploy'; then
        pages_deployer_jobs+=("$job")
    fi
done < <(workflow_job_names)

assert_eq "${#pages_deployer_jobs[@]}" "1" \
    "exactly one job runs 'wrangler pages deploy' (found: ${pages_deployer_jobs[*]:-none})"
assert_eq "${pages_deployer_jobs[0]:-none}" "deploy-staging" \
    "the sole Pages deployer is deploy-staging"

# Both customer aliases publish from that one deployer.
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
    '--branch=main' "deploy-staging publishes the production (--branch=main) Pages alias"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
    '--branch=staging' "deploy-staging publishes the staging (--branch=staging) Pages alias"

# --- 2. deploy-prod is API-only, never a Pages deployer ---------------------
assert_job_not_contains_regex "deploy-prod" \
    'wrangler@4 pages deploy' "deploy-prod contains no wrangler Pages deploy"
assert_job_not_contains_regex "deploy-prod" \
    'Deploy web to Cloudflare Pages' "deploy-prod has no web-deploy step (Pages stays staging-owned)"
# It DOES deploy the prod API: build + upload + trigger.
assert_job_contains_regex "deploy-prod" \
    'name:\s+Build release binaries' "deploy-prod builds the prod API release binaries"
assert_job_contains_regex "deploy-prod" \
    'name:\s+Upload release artifacts' "deploy-prod uploads the prod API artifacts"
assert_job_contains_regex "deploy-prod" \
    'name:\s+Trigger API deploy' "deploy-prod triggers the prod API deploy"

# --- 3. Exact source: caller-merged dev SHA via the sync manifest -----------
# deploy-prod stamps provenance from debbie's manifest, so the served /version
# dev_sha is the EXACT dev commit debbie synced — not an ambient GITHUB_SHA.
assert_step_contains_regex "deploy-prod" "Inject build-time provenance from debbie sync manifest" \
    '\.debbie/sync_manifest\.json' "deploy-prod reads the debbie sync manifest for provenance"
assert_step_contains_regex "deploy-prod" "Inject build-time provenance from debbie sync manifest" \
    "DEV_SHA=\\\$\\(jq -r '\\.dev_sha'" "deploy-prod derives FJCLOUD_DEV_SHA from manifest .dev_sha"
assert_step_contains_regex "deploy-prod" "Inject build-time provenance from debbie sync manifest" \
    'FJCLOUD_MIRROR_SHA=\$\{GITHUB_SHA\}' "deploy-prod records the prod mirror SHA (GITHUB_SHA)"

# Clean canonical checkout: debbie mirrors the code trees but excludes
# worktree-only build outputs, so worktree-only bytes never reach the mirror.
assert_file_contains_regex "$DEBBIE_TOML" 'path = "infra/"' \
    ".debbie.toml syncs the infra/ code tree"
assert_file_contains_regex "$DEBBIE_TOML" 'path = "web/"' \
    ".debbie.toml syncs the web/ code tree"
assert_file_contains_regex "$DEBBIE_TOML" '"target"' \
    ".debbie.toml excludes infra build output (target) — no worktree-only bytes"
assert_file_contains_regex "$DEBBIE_TOML" '"node_modules"' \
    ".debbie.toml excludes web node_modules — no worktree-only bytes"
assert_file_contains_regex "$DEBBIE_TOML" '"\.svelte-kit"' \
    ".debbie.toml excludes the .svelte-kit build cache — no worktree-only bytes"

# --- 4. Negative cases the prod-sync guards must reject ---------------------
# unknown source / dirty mirror: the sync helper compares the prod mirror's own
# manifest dev_sha against the caller expectation (never substitutes it).
assert_file_contains_regex "$SYNC_HELPER" 'manifest_dev_sha' \
    "prod-sync helper derives the prod mirror manifest dev_sha"
assert_file_contains_regex "$SYNC_HELPER" '\[ "\$manifest_dev_sha" != "\$expected_dev_sha" \]' \
    "prod-sync helper rejects a mirror whose manifest dev_sha != the caller expectation (unknown source / dirty mirror)"
# caller-supplied, not ambient/discovered:
assert_file_contains_regex "$SYNC_HELPER" '\[ "\$expected_dev_sha" != "\$dev_head_sha" \]' \
    "prod-sync helper requires --expected-dev-sha to equal dev HEAD (no ambient discovery)"

# loose/ancestor-only match rejected: the terminal verifier no longer carries
# the ancestor / age / commits_behind windows the exact-identity gate replaced.
assert_file_not_contains_regex "$VERIFY_SCRIPT" 'is-ancestor' \
    "verifier no longer accepts an is-ancestor (loose) match"
assert_file_not_contains_regex "$VERIFY_SCRIPT" 'max_age' \
    "verifier no longer accepts a build-time freshness window"
assert_file_not_contains_regex "$VERIFY_SCRIPT" 'commits_behind' \
    "verifier no longer accepts a commits_behind window"
# and it DOES enforce exact identity + rejects a prod-derived Pages SHA:
assert_file_contains_regex "$VERIFY_SCRIPT" 'POST_WAVE_EXPECTED_MIRROR_SHA' \
    "verifier checks the served mirror_sha against the exact derived head"
assert_file_contains_regex "$VERIFY_SCRIPT" 'prod-derived' \
    "verifier rejects a prod-derived Pages SHA (Pages stays staging-owned)"

# --- 5. Self-wiring: an unregistered contract test never runs ---------------
assert_file_contains_regex "$LOCAL_CI" \
    'scripts/tests/ci_lane24_deploy_contract_test\.sh' \
    "scripts/local-ci.sh registers this Lane 24 deploy contract test"

run_test_summary
