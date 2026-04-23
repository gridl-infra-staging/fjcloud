#!/usr/bin/env bash
# Static validation tests for Stage 6: CI/CD Pipeline
# TDD: these tests define the contract; workflow must satisfy them.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/test_helpers.sh"

workflow_file=".github/workflows/ci.yml"

assert_pattern_count_at_least() {
  local file="$1"
  local pattern="$2"
  local expected_minimum="$3"
  local description="$4"
  local count
  count=$(rg -c "$pattern" "$file" || true)
  if [[ "$count" -ge "$expected_minimum" ]]; then
    pass "$description"
  else
    fail "$description (found $count, expected at least $expected_minimum)"
  fi
}

echo ""
echo "=== Stage 6 Static Tests: CI/CD Pipeline ==="
echo ""

echo "--- Workflow file existence and triggers ---"
assert_file_exists "$workflow_file" ".github/workflows/ci.yml exists"
assert_file_contains "$workflow_file" '^name:\s*CI' "workflow name is set"
assert_file_contains "$workflow_file" '^on:' "workflow defines triggers"
assert_file_contains "$workflow_file" '^  push:' "workflow has push trigger"
assert_file_contains "$workflow_file" 'branches: \[main\]' "workflow push trigger targets main"
assert_file_contains "$workflow_file" '^  pull_request:' "workflow has pull_request trigger"
assert_file_contains "$workflow_file" 'concurrency:' "workflow has deploy concurrency guard"
assert_file_contains "$workflow_file" 'group:\s*["'\'']?deploy-staging["'\'']?' "workflow concurrency groups staging deploy"
assert_file_contains "$workflow_file" 'cancel-in-progress:\s*true' "workflow cancels in-progress deploys"

echo ""
echo "--- Job definitions ---"
assert_file_contains "$workflow_file" '^  rust-test:' "workflow defines rust-test job"
assert_file_contains "$workflow_file" '^  rust-lint:' "workflow defines rust-lint job"
assert_file_contains "$workflow_file" '^  migration-test:' "workflow defines migration-test job"
assert_file_contains "$workflow_file" '^  web-test:' "workflow defines web-test job"
assert_file_contains "$workflow_file" '^  deploy-staging:' "workflow defines deploy-staging job"

assert_file_contains "$workflow_file" 'needs:\s*\[rust-test, rust-lint, migration-test, web-test\]' "deploy-staging depends on all test jobs"
assert_file_contains "$workflow_file" "if: github.ref == 'refs/heads/main' && github.event_name == 'push'" "deploy-staging is restricted to main push events"

echo ""
echo "--- Quality gate commands ---"
assert_file_contains "$workflow_file" 'cargo test --workspace' "rust-test runs cargo test --workspace"
assert_file_contains "$workflow_file" 'cargo clippy --workspace -- -D warnings' "rust-lint runs clippy with warnings denied"
assert_file_contains "$workflow_file" 'sqlx migrate run --source infra/migrations' "migration-test runs sqlx migrate from infra/migrations"
assert_file_contains "$workflow_file" 'npm test' "web-test runs npm test"

echo ""
echo "--- Build and deploy contract checks ---"
assert_file_contains "$workflow_file" 'runs-on:\s*ubuntu-24\.04-arm' "deploy-staging uses ARM64 runner"
assert_file_contains "$workflow_file" 'cargo build --release -p api -p aggregation-job -p metering-agent' "deploy-staging builds all Rust release binaries"
assert_file_contains "$workflow_file" 'mv target/release/fjcloud-api fjcloud-api' "build renames api binary to fjcloud-api"
assert_file_contains "$workflow_file" 'mv target/release/fjcloud-aggregation-job fjcloud-aggregation-job' "build renames aggregation-job binary to fjcloud-aggregation-job"
assert_file_contains "$workflow_file" 'mv target/release/fj-metering-agent fj-metering-agent' "build renames metering-agent binary to fj-metering-agent"
assert_file_contains "$workflow_file" 's3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-api' "upload: fjcloud-api to correct S3 path"
assert_file_contains "$workflow_file" 's3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-aggregation-job' "upload: fjcloud-aggregation-job to correct S3 path"
assert_file_contains "$workflow_file" 's3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fj-metering-agent' "upload: fj-metering-agent to correct S3 path"
assert_file_contains "$workflow_file" 's3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/migrations' "upload: migrations to correct S3 path"
assert_file_contains "$workflow_file" 's3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/scripts/migrate\.sh' "upload: migrate.sh to correct S3 path"
assert_file_contains "$workflow_file" 'bash ops\/scripts\/deploy\.sh staging "\$\{GITHUB_SHA\}"' "deploy-staging calls deploy.sh with env and commit SHA"

echo ""
echo "--- Hardening checks ---"
assert_file_not_contains "$workflow_file" 'AWS_ACCESS_KEY_ID:\s*\$\{\{\s*secrets\.AWS_ACCESS_KEY_ID\s*\}\}' "workflow does not use AWS_ACCESS_KEY_ID secret"
assert_file_not_contains "$workflow_file" 'AWS_SECRET_ACCESS_KEY:\s*\$\{\{\s*secrets\.AWS_SECRET_ACCESS_KEY\s*\}\}' "workflow does not use AWS_SECRET_ACCESS_KEY secret"
assert_file_contains "$workflow_file" 'uses:\s*aws-actions/configure-aws-credentials@v4' "deploy job configures AWS credentials via GitHub OIDC action"
assert_file_contains "$workflow_file" 'role-to-assume:\s*\$\{\{\s*secrets\.DEPLOY_IAM_ROLE_ARN\s*\}\}' "deploy job assumes IAM role from GitHub secret"
assert_file_contains "$workflow_file" 'id-token:\s*write' "workflow grants id-token: write for OIDC"

echo ""
echo "--- Infra service/test contract checks ---"
assert_pattern_count_at_least "$workflow_file" 'postgres:' 2 "workflow includes postgres service for rust and migration jobs"
assert_file_contains "$workflow_file" 'POSTGRES_DB' "migration and/or tests configure postgres DB name"
assert_file_contains "$workflow_file" 'POSTGRES_USER' "migration and/or tests configure postgres user"
assert_file_contains "$workflow_file" 'POSTGRES_PASSWORD' "migration and/or tests configure postgres password"
assert_pattern_count_at_least "$workflow_file" 'postgres:16' 2 "workflow uses postgres:16 image"

assert_file_contains "$workflow_file" 'DATABASE_URL' "migration-test sets DATABASE_URL env var"
assert_file_contains "$workflow_file" 'pg_isready' "postgres service has health check"

assert_file_contains "$workflow_file" 'uses: Swatinem/rust-cache@v2' "workflow uses rust cache action"
assert_file_contains "$workflow_file" 'workspaces:\s*infra' "workflow passes infra to rust-cache workspaces"
assert_file_contains "$workflow_file" 'sqlx-cli --version 0.8' "migration-test pins sqlx-cli to 0.8.x"
assert_pattern_count_at_least "$workflow_file" 'cargo install sqlx-cli' 1 "workflow installs sqlx-cli"

echo ""
echo "--- Toolchain and checkout checks ---"
assert_pattern_count_at_least "$workflow_file" 'uses: actions/checkout@v4' 5 "all 5 jobs use actions/checkout@v4"
assert_pattern_count_at_least "$workflow_file" 'dtolnay/rust-toolchain@stable' 4 "Rust jobs use dtolnay/rust-toolchain@stable (not stale @v1)"
assert_file_not_contains "$workflow_file" 'rust-toolchain@v1' "workflow does not use unmaintained @v1 tag"
assert_file_contains "$workflow_file" 'working-directory:\s*infra' "cargo commands use working-directory: infra"
assert_file_contains "$workflow_file" 'working-directory:\s*web' "web-test uses working-directory: web"
assert_file_contains "$workflow_file" 'actions/setup-node' "web-test installs Node.js"
assert_file_contains "$workflow_file" 'npm ci' "web-test runs npm ci before tests"

test_summary "Stage 6 static checks"
