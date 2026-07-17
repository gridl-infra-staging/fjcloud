#!/usr/bin/env bash
# Static contract test for the web-plane (Cloudflare Pages) deploy step in
# .github/workflows/ci.yml.
#
# WHY THIS TEST EXISTS (silent-guard incident, 2026-06-05 → 07-07):
# The `flapjack-cloud` Cloudflare Pages project has NO git integration
# (`source: null` in the Pages API), so web deploys only happen when someone
# runs `wrangler pages deploy` by hand. Mirror CI deployed the API plane only,
# and `e2e-deployed`'s Pages-parity poll deliberately skips (exit 0) on lag —
# so the web plane went stale for a month while every pipeline signal stayed
# green. This lane adds an automatic `deploy-web` step to the staging mirror's
# `deploy-staging` job. This contract test pins the load-bearing properties of
# that step so it cannot be silently removed, moved, or turned into a no-op.
#
# CREDENTIAL MODEL: the deploy step authenticates with a least-privilege,
# Pages-scoped API token (Account → Cloudflare Pages → Edit) provided as
# CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID — the Cloudflare-documented auth
# for `wrangler pages deploy`. It deliberately does NOT use the legacy global
# API key. (The separate `e2e-deployed` parity poll still uses the global key
# pending a future consolidation; that surface is out of scope here.)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

# Workflow-parsing seams (_grep, job_block, step_block, assert_* helpers) live
# in the shared lib so the Lane 24 deploy contract test reuses ONE parser.
# shellcheck source=lib/ci_workflow_contract.sh
source "$SCRIPT_DIR/lib/ci_workflow_contract.sh"

echo ""
echo "=== CI web-deploy contract tests ==="
echo ""

# 1. The deploy-staging job carries the named web-deploy step.
assert_job_contains_regex "deploy-staging" \
  'name:\s+Deploy web to Cloudflare Pages' \
  "deploy-staging has 'Deploy web to Cloudflare Pages' step"

# 2. The step builds and publishes the exact served bundle: npm ci, npm run
#    build, and the full versioned wrangler invocation. Served commit ==
#    mirror CI commit is the whole provenance model — assert the exact flags.
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'cd web' "web-deploy step runs from the web workspace"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'npm ci' "web-deploy step runs npm ci"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'npm run build' "web-deploy step runs npm run build"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'npx --yes wrangler@4 pages deploy \.svelte-kit/cloudflare' \
  "web-deploy step invokes npx --yes wrangler@4 pages deploy on the .svelte-kit/cloudflare bundle"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  '--project-name=flapjack-cloud' "web-deploy step targets the flapjack-cloud project"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  '--branch=main' "web-deploy step deploys the production (branch=main) environment"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  '--commit-hash="\$GITHUB_SHA"' "web-deploy step stamps the served bundle with GITHUB_SHA"
assert_step_contains_normalized_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'npx --yes wrangler@4 pages deploy \.svelte-kit/cloudflare --project-name=flapjack-cloud --branch=main --commit-hash="\$GITHUB_SHA"' \
  "web-deploy step keeps the exact Cloudflare Pages deploy invocation"

# 2b. Branch-alias topology: cloud.staging.flapjack.foo is a CNAME to the
#     Pages `staging` BRANCH alias (staging.flapjack-cloud.pages.dev), which
#     only refreshes on a `--branch=staging` deploy. The single web-deploy
#     step therefore runs TWO branch deploys from ONE build: `--branch=main`
#     (production alias, unchanged, FIRST) then `--branch=staging` (the staging
#     branch alias). Assert the staging deploy exists, is the exact contiguous
#     invocation, and follows the main deploy so a staging hiccup can never
#     regress the live prod deploy.
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  '--branch=staging' "web-deploy step also deploys the staging branch alias (branch=staging)"
assert_step_contains_normalized_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'npx --yes wrangler@4 pages deploy \.svelte-kit/cloudflare --project-name=flapjack-cloud --branch=staging --commit-hash="\$GITHUB_SHA"' \
  "web-deploy step keeps the exact staging-branch Cloudflare Pages deploy invocation"
assert_step_contains_normalized_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  '--branch=main .*--commit-hash="\$GITHUB_SHA".*--branch=staging' \
  "web-deploy step deploys --branch=main BEFORE --branch=staging"

# 3. The job must set up Node 22 itself — deploy-staging has no Node setup today
#    (its Rust build runs inside an Amazon Linux docker container; the runner
#    shell never gets setup-node). Without it the web build rides undeclared
#    runner-image defaults.
assert_job_contains_regex "deploy-staging" \
  'name:\s+Set up Node.js' "deploy-staging has a 'Set up Node.js' step"
assert_step_contains_regex "deploy-staging" "Set up Node.js" \
  'uses:\s+actions/setup-node@a0853c24544627f65ddf259abe73b1d18a591444' \
  "deploy-staging Node setup is pinned to the same actions/setup-node SHA as web-test"
assert_step_contains_regex "deploy-staging" "Set up Node.js" \
  'node-version:\s+22' "deploy-staging pins Node.js 22"
assert_step_order "deploy-staging" "Trigger API deploy" "Set up Node.js" \
  "deploy-staging sets up Node after the API deploy trigger"
assert_step_order "deploy-staging" "Set up Node.js" "Deploy web to Cloudflare Pages" \
  "deploy-staging deploys the web bundle after Node is set up"
assert_step_order "deploy-staging" "Trigger API deploy" "Deploy web to Cloudflare Pages" \
  "deploy-staging deploys the web bundle after Trigger API deploy"

# 4. Credential model (DEVIATION from the original spec): least-privilege,
#    Pages-scoped token — CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID — NOT the
#    legacy global API key. This is the Cloudflare-documented auth for
#    `wrangler pages deploy`.
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'CLOUDFLARE_API_TOKEN:\s+\$\{\{\s*secrets\.CLOUDFLARE_API_TOKEN\s*\}\}' \
  "web-deploy step wires scoped CLOUDFLARE_API_TOKEN"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'CLOUDFLARE_ACCOUNT_ID:\s+\$\{\{\s*secrets\.CLOUDFLARE_ACCOUNT_ID\s*\}\}' \
  "web-deploy step wires CLOUDFLARE_ACCOUNT_ID"
assert_step_not_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'CLOUDFLARE_GLOBAL_API_KEY' \
  "web-deploy step does NOT use the legacy global API key (least-privilege scoped token only)"

# 5. Bounded retry around the wrangler deploy only (the Pages API returns
#    transient 'Unknown internal error'; observed 2026-07-07, succeeded on
#    retry). The npm build is NOT retried — a build failure is deterministic
#    and must fail fast.
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'for attempt in 1 2 3' "web-deploy step has a bounded 3-attempt retry loop"
assert_step_contains_regex "deploy-staging" "Deploy web to Cloudflare Pages" \
  'sleep 20' "web-deploy retry loop backs off 20s between attempts"

# 6. Single-deployer contract: deploy-prod must NOT publish Pages. The two
#    customer domains ride two branch aliases of the ONE flapjack-cloud Pages
#    project — cloud.flapjack.foo on the --branch=main production alias,
#    cloud.staging.flapjack.foo on the --branch=staging branch alias — and the
#    single deploy-staging deployer publishes both from one build. A second
#    deployer on deploy-prod would race it for those same branch aliases.
#    Assert absence so a future "helpful" duplication fails loud.
assert_job_not_contains_regex "deploy-prod" \
  'wrangler@4 pages deploy' "deploy-prod does NOT contain a Cloudflare Pages deploy"
assert_job_not_contains_regex "deploy-prod" \
  'Deploy web to Cloudflare Pages' "deploy-prod has no web-deploy step"

# 7. Self-wiring: an unregistered contract test never runs and is exactly the
#    silent-guard class this lane exists to kill. rust-lint (in ci.yml) and the
#    local-ci gate must both run this test.
assert_job_contains_regex "rust-lint" \
  'scripts/tests/ci_deploy_web_contract_test\.sh' \
  "rust-lint job runs this web-deploy contract test"
assert_file_contains_regex "$LOCAL_CI" \
  'scripts/tests/ci_deploy_web_contract_test\.sh' \
  "scripts/local-ci.sh registers this web-deploy contract test"

# 8. Runtime bound: deploy-staging must pin a job-level timeout-minutes so a
#    hung docker build or wedged `wrangler pages deploy` cannot burn the
#    six-hour (360 min) GitHub Actions default. Observed healthy runtime is
#    ~19 min (3 recent staging runs, 2026-07-09); 45 min is the sibling
#    e2e-deployed bound and gives ~2.4x headroom. The bound must stay a
#    concrete value in a sane closed range — never the default, never useless.
assert_job_contains_regex "deploy-staging" \
  '^[[:space:]]{4}timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$' \
  "deploy-staging pins a job-level timeout-minutes"
assert_job_timeout_in_range "deploy-staging" 20 60 \
  "deploy-staging timeout-minutes is a concrete bound in [20,60]"

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
[[ "$FAIL_COUNT" -eq 0 ]]
