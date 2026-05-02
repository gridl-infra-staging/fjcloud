#!/usr/bin/env bash
# Static contract test for .github/workflows/ci.yml
# TDD red/green stages for Stage 1 CI hardening.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

PASS_COUNT=0
FAIL_COUNT=0

# Portable grep wrapper: converts \s to [[:space:]] so patterns work with
# POSIX grep -E on both macOS (BSD grep) and Linux (GNU grep).
_grep() {
  local flags=()
  while [[ $# -gt 1 && "$1" == -* ]]; do
    flags+=("$1"); shift
  done
  local pattern="$1"; shift
  pattern="${pattern//\\s/[[:space:]]}"
  if [[ ${#flags[@]} -gt 0 ]]; then
    grep -E "${flags[@]}" -- "$pattern" "$@"
  else
    grep -E -- "$pattern" "$@"
  fi
}

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_file_exists() {
  local path="$1"
  local msg="$2"
  if [[ -f "$path" ]]; then
    pass "$msg"
  else
    fail "$msg (missing file: $path)"
  fi
}

assert_contains_regex() {
  local pattern="$1"
  local msg="$2"
  if _grep -n "$pattern" "$WORKFLOW_FILE" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (pattern not found: $pattern)"
  fi
}

job_block() {
  local job_name="$1"
  awk -v job="$job_name" '
    $0 ~ "^  " job ":$" { in_job=1; print; next }
    in_job && $0 ~ "^  [a-zA-Z0-9_-]+:$" { exit }
    in_job { print }
  ' "$WORKFLOW_FILE"
}

assert_job_contains_regex() {
  local job_name="$1"
  local pattern="$2"
  local msg="$3"
  local block
  block="$(job_block "$job_name")"
  block="$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*#')"
  if [[ -z "$block" ]]; then
    fail "$msg (job block missing: $job_name)"
    return
  fi

  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (pattern not found in $job_name: $pattern)"
  fi
}

assert_job_not_contains_regex() {
  local job_name="$1"
  local pattern="$2"
  local msg="$3"
  local block
  block="$(job_block "$job_name")"
  if [[ -z "$block" ]]; then
    fail "$msg (job block missing: $job_name)"
    return
  fi

  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    fail "$msg (unexpected pattern found in $job_name: $pattern)"
  else
    pass "$msg"
  fi
}

step_block() {
  local job_name="$1"
  local step_name="$2"
  job_block "$job_name" | awk -v step="$step_name" '
    $0 ~ "^[[:space:]]+- name: " step "$" { in_step=1; print; next }
    in_step && $0 ~ "^[[:space:]]+- name: " { exit }
    in_step { print }
  '
}

assert_step_contains_regex() {
  local job_name="$1"
  local step_name="$2"
  local pattern="$3"
  local msg="$4"
  local block
  block="$(step_block "$job_name" "$step_name")"
  block="$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*#')"
  if [[ -z "$block" ]]; then
    fail "$msg (step missing in $job_name: $step_name)"
    return
  fi

  if _grep -n "$pattern" <<<"$block" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (pattern not found in $job_name/$step_name: $pattern)"
  fi
}

step_line_number() {
  local job_name="$1"
  local step_name="$2"
  local block
  block="$(job_block "$job_name")"
  printf '%s\n' "$block" | awk -v step="$step_name" '
    $0 ~ "^[[:space:]]+- name: " step "$" { print NR; exit }
  '
}

assert_step_order() {
  local job_name="$1"
  local first_step="$2"
  local second_step="$3"
  local msg="$4"
  local first_line second_line

  first_line="$(step_line_number "$job_name" "$first_step")"
  second_line="$(step_line_number "$job_name" "$second_step")"

  if [[ -z "$first_line" || -z "$second_line" ]]; then
    fail "$msg (missing step in $job_name: $first_step -> $second_step)"
    return
  fi

  if (( first_line < second_line )); then
    pass "$msg"
  else
    fail "$msg (order wrong in $job_name: $first_step line $first_line, $second_step line $second_line)"
  fi
}

assert_all_uses_are_sha_pinned() {
  local invalid
  invalid="$(_grep -n '^\s*uses:\s+[[:graph:]]+@|^\s*-\s*uses:\s+[[:graph:]]+@' "$WORKFLOW_FILE" | _grep -v '@[0-9a-f]{40}(\s+#.*)?$' || true)"
  if [[ -n "$invalid" ]]; then
    fail "all uses: entries must pin exact 40-char commit SHA (invalid lines: $invalid)"
  else
    pass "all uses: entries pin exact 40-char commit SHA"
  fi
}

assert_deploy_uploads_use_git_sha() {
  local deploy_block s3_lines missing_sha
  deploy_block="$(job_block "deploy-staging")"
  s3_lines="$(_grep 'aws s3 (cp|sync)' <<<"$deploy_block" || true)"
  if [[ -z "$s3_lines" ]]; then
    fail "deploy-staging must include aws s3 upload commands"
    return
  fi

  missing_sha="$(_grep -n 'aws s3 (cp|sync)' <<<"$deploy_block" | _grep -v '\$\{GITHUB_SHA\}|\$\{\{\s*github\.sha\s*\}\}' || true)"
  if [[ -n "$missing_sha" ]]; then
    fail "every deploy-staging aws s3 upload path must include git SHA (invalid lines: $missing_sha)"
  else
    pass "deploy-staging aws s3 upload paths include git SHA"
  fi
}

assert_deploy_has_s3_overwrite_guard() {
  local deploy_block
  deploy_block="$(job_block "deploy-staging")"
  if _grep -n 'aws s3 ls|aws s3api head-object|aws s3api list-objects-v2' <<<"$deploy_block" >/dev/null 2>&1; then
    pass "deploy-staging checks artifact existence before upload"
  else
    fail "deploy-staging must check S3 artifact existence before upload to prevent overwrite"
  fi
}

echo ""
echo "=== CI Workflow Contract Tests ==="
echo ""

assert_file_exists "$WORKFLOW_FILE" "ci workflow file exists"

assert_contains_regex '^\s{2}rust-test:\s*$' "job rust-test exists"
assert_contains_regex '^\s{2}rust-lint:\s*$' "job rust-lint exists"
assert_contains_regex '^\s{2}migration-test:\s*$' "job migration-test exists"
assert_contains_regex '^\s{2}web-test:\s*$' "job web-test exists"
assert_contains_regex '^\s{2}check-sizes:\s*$' "job check-sizes exists"
assert_contains_regex '^\s{2}web-lint:\s*$' "job web-lint exists"
assert_contains_regex '^\s{2}playwright:\s*$' "job playwright exists"
assert_contains_regex '^\s{2}secret-scan:\s*$' "job secret-scan exists"
assert_contains_regex '^\s{2}deploy-staging:\s*$' "job deploy-staging exists"

assert_job_contains_regex "rust-test" 'uses:\s+actions/checkout@' "rust-test has checkout step"
assert_job_contains_regex "rust-test" 'run:\s+bash scripts/reliability/seed-test-profiles.sh' "rust-test seeds reliability profile artifacts"
assert_job_contains_regex "rust-test" 'uses:\s+dtolnay/rust-toolchain@' "rust-test has rust toolchain setup"
assert_job_contains_regex "rust-test" 'run:\s+cargo test --workspace' "rust-test has cargo test command"
# tenant_isolation_proptest moved to nightly.yml on 2026-05-02 — kept out
# of the per-push deploy gate to shave ~3-5 min off every CI cycle. See
# nightly_workflow_test.sh for its new contract assertion.
assert_job_not_contains_regex "rust-test" 'tenant_isolation_proptest' "rust-test does not run tenant isolation proptest (nightly only)"

assert_job_contains_regex "rust-lint" 'uses:\s+actions/checkout@' "rust-lint has checkout step"
assert_job_contains_regex "rust-lint" 'run:\s+bash scripts/tests/generate_ssm_env_test\.sh' "rust-lint runs generate_ssm_env contract test"
assert_job_contains_regex "rust-lint" 'run:\s+bash scripts/tests/local_ci_gate_set_e_test\.sh' "rust-lint runs local-ci rust-lint regression test"
assert_job_contains_regex "rust-lint" 'uses:\s+dtolnay/rust-toolchain@' "rust-lint has rust toolchain setup"
assert_job_contains_regex "rust-lint" 'run:\s+cargo clippy --workspace -- -D warnings' "rust-lint has cargo clippy command"
assert_step_order "rust-lint" 'Install Rust' 'Run local-ci rust-lint regression test' "rust-lint installs Rust before the local-ci regression test"

assert_job_contains_regex "migration-test" 'uses:\s+actions/checkout@' "migration-test has checkout step"
assert_job_contains_regex "migration-test" 'uses:\s+dtolnay/rust-toolchain@' "migration-test has rust toolchain setup"
assert_job_contains_regex "migration-test" 'run:\s+sqlx migrate run --source infra/migrations --database-url "\$DATABASE_URL"' "migration-test has migration test command"

assert_job_contains_regex "web-test" 'uses:\s+actions/checkout@' "web-test has checkout step"
assert_job_contains_regex "web-test" 'uses:\s+actions/setup-node@' "web-test has node setup step"
assert_job_contains_regex "web-test" 'npm test' "web-test has test command"

assert_job_contains_regex "check-sizes" 'uses:\s+actions/checkout@' "check-sizes has checkout step"
assert_job_contains_regex "check-sizes" 'run:\s+bash scripts/check-sizes.sh' "check-sizes runs size check script"

assert_job_contains_regex "web-lint" 'uses:\s+actions/checkout@' "web-lint has checkout step"
assert_job_contains_regex "web-lint" 'uses:\s+actions/setup-node@' "web-lint has node setup step"
assert_job_contains_regex "web-lint" 'npm run check' "web-lint runs svelte-check"
assert_job_contains_regex "web-lint" 'eslint' "web-lint runs eslint"
assert_job_contains_regex "web-lint" 'npm run lint:e2e' "web-lint runs browser-unmocked lint"
assert_job_contains_regex "web-lint" 'screen_specs_coverage_test\.sh' "web-lint runs screen spec coverage contract"

assert_job_contains_regex "playwright" 'uses:\s+actions/checkout@' "playwright has checkout step"
assert_job_contains_regex "playwright" 'uses:\s+actions/setup-node@' "playwright has node setup step"
assert_job_contains_regex "playwright" 'services:' "playwright defines services block"
assert_job_contains_regex "playwright" 'postgres:' "playwright starts postgres service"
assert_job_contains_regex "playwright" 'POSTGRES_DB:\s+fjcloud_test' "playwright postgres uses canonical test database"
assert_job_contains_regex "playwright" 'POSTGRES_USER:\s+fjcloud' "playwright postgres uses canonical test user"
assert_job_contains_regex "playwright" 'POSTGRES_PASSWORD:\s+password' "playwright postgres uses canonical test password"
assert_job_contains_regex "playwright" 'DATABASE_URL:\s+postgres://fjcloud:password@127.0.0.1:5432/fjcloud_test' "playwright sets canonical DATABASE_URL"
assert_job_contains_regex "playwright" 'ENVIRONMENT:\s+local' "playwright sets local environment for zero-dependency API bootstrap"
assert_job_contains_regex "playwright" 'NODE_SECRET_BACKEND:\s+memory' "playwright enables in-memory node secret backend for zero-dependency API bootstrap"
assert_job_contains_regex "playwright" 'BASE_URL:\s+http://127.0.0.1:5173' "playwright sets BASE_URL for browser tests"
assert_job_contains_regex "playwright" 'API_URL:\s+http://127.0.0.1:3001' "playwright sets API_URL for browser tests"
assert_job_contains_regex "playwright" 'MAILPIT_API_URL:\s+http://127.0.0.1:8025' "playwright sets MAILPIT_API_URL for signup email verification fixtures"
assert_job_contains_regex "playwright" 'mailpit:' "playwright starts mailpit service"
assert_job_contains_regex "playwright" 'axllent/mailpit:' "playwright uses the canonical mailpit service image"
assert_job_contains_regex "playwright" '8025:8025' "playwright exposes mailpit API port"
assert_job_contains_regex "playwright" 'name:\s+Install Rust' "playwright installs Rust toolchain"
assert_job_contains_regex "playwright" 'name:\s+Install sqlx-cli' "playwright installs sqlx-cli"
assert_job_contains_regex "playwright" 'sqlx migrate run --source infra/migrations --database-url "\$DATABASE_URL"' "playwright runs migrations before tests"
assert_job_contains_regex "playwright" 'name:\s+Build API binary' "playwright pre-builds API binary so readiness wait covers startup only, not compile"
assert_job_contains_regex "playwright" 'cargo build -p api --bin fjcloud-api' "playwright pre-builds API via cargo build to bound the readiness wait"
assert_job_contains_regex "playwright" 'name:\s+Start API server' "playwright starts API server"
assert_job_contains_regex "playwright" '\./target/debug/fjcloud-api' "playwright launches the prebuilt API binary, not cargo run"
assert_job_contains_regex "playwright" 'name:\s+Start web server' "playwright starts web server"
assert_job_contains_regex "playwright" 'npm run dev -- --host 127\.0\.0\.1 --port 5173 --strictPort' "playwright starts web via npm owner script on deterministic host/port"
assert_job_contains_regex "playwright" 'name:\s+Wait for API and web readiness' "playwright polls readiness before tests"
assert_job_contains_regex "playwright" 'timeout 120s bash -lc' "playwright readiness check is bounded"
assert_job_contains_regex "playwright" 'http://127\.0\.0\.1:3001/health' "playwright readiness checks API health endpoint"
assert_job_contains_regex "playwright" 'curl -fsS "\$\{BASE_URL\}/"' "playwright readiness checks web BASE_URL endpoint"
assert_job_contains_regex "playwright" 'curl -fsS "\$\{MAILPIT_API_URL\}/api/v1/info"' "playwright readiness checks mailpit API endpoint"
assert_job_contains_regex "playwright" 'playwright install --with-deps chromium' "playwright installs only contract-required browsers"
# Firefox/WebKit dropped 2026-05-02 — Playwright-on-Linux WebKit isn't
# real Safari (no ITP, no Apple Pay, no Stripe 3DS quirks) and Firefox is
# ~3-6% of users. Real-Safari smoke is operator-driven on macOS pre-launch.
assert_job_not_contains_regex "playwright" 'firefox|webkit' "playwright does not install firefox or webkit (chromium-only after 2026-05-02 cutover)"
assert_job_contains_regex "playwright" 'playwright test' "playwright runs tests"
assert_job_not_contains_regex "playwright" 'playwright test .*--project' "playwright job does not override project selection from config"
assert_job_contains_regex "playwright" 'name:\s+Upload Playwright artifacts' "playwright uploads test artifacts"
assert_job_contains_regex "playwright" 'uses:\s+actions/upload-artifact@' "playwright artifact step uses upload-artifact action"
assert_job_contains_regex "playwright" 'path:\s+\|' "playwright artifact upload uses explicit multi-path block"
assert_job_contains_regex "playwright" 'web/playwright-report' "playwright artifact upload includes playwright-report"
assert_job_contains_regex "playwright" 'web/test-results' "playwright artifact upload includes test-results"
assert_job_contains_regex "playwright" '^\s+/tmp/fjcloud-api\.log$' "playwright artifact upload includes API readiness log"
assert_job_contains_regex "playwright" '^\s+/tmp/fjcloud-web\.log$' "playwright artifact upload includes web readiness log"
assert_step_contains_regex "playwright" 'Upload Playwright artifacts' 'if:\s+always\(\)' "playwright artifact upload always runs for failure evidence"
assert_step_contains_regex "playwright" 'Stop API and web servers' 'if:\s+always\(\)' "playwright cleanup always runs"
assert_step_order "playwright" 'Run migrations' 'Start API server' "playwright runs migrations before starting the API"
assert_step_order "playwright" 'Start API server' 'Wait for API and web readiness' "playwright starts the API before readiness polling"
assert_step_order "playwright" 'Start web server' 'Wait for API and web readiness' "playwright starts the web server before readiness polling"
assert_step_order "playwright" 'Wait for API and web readiness' 'Install Playwright browsers' "playwright readiness polling completes before browser install"
assert_step_order "playwright" 'Install Playwright browsers' 'Run Playwright tests' "playwright installs browsers before running tests"
assert_step_order "playwright" 'Run Playwright tests' 'Upload Playwright artifacts' "playwright uploads artifacts after the test step"
assert_step_order "playwright" 'Upload Playwright artifacts' 'Stop API and web servers' "playwright stops background servers after artifact collection"

assert_job_contains_regex "secret-scan" 'uses:\s+actions/checkout@' "secret-scan has checkout step"
assert_job_contains_regex "secret-scan" 'gitleaks' "secret-scan uses gitleaks"
assert_job_contains_regex "secret-scan" 'name:\s+Run gitleaks \(PR diff\)' "secret-scan has PR diff scan step"
assert_job_contains_regex "secret-scan" "if:\s+github\\.event_name == 'pull_request'" "secret-scan scopes diff scan to pull requests"
assert_job_contains_regex "secret-scan" 'GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}' "secret-scan passes GITHUB_TOKEN for PR scanning"
assert_job_contains_regex "secret-scan" 'name:\s+Run gitleaks \(main full history\)' "secret-scan has main full-history scan step"
assert_job_contains_regex "secret-scan" "if:\s+github\\.event_name == 'push' && github\\.ref == 'refs/heads/main'" "secret-scan scopes full-history scan to main pushes"
assert_job_contains_regex "secret-scan" 'run:\s+gitleaks detect' "secret-scan runs gitleaks detect for main full-history scan"
assert_job_not_contains_regex "secret-scan" 'args:\s+git' "secret-scan does not rely on unsupported args input"
assert_job_not_contains_regex "secret-scan" '--log-opts=' "main full-history scan does not use commit-range log opts"

assert_job_contains_regex "deploy-staging" 'uses:\s+actions/checkout@' "deploy-staging has checkout step"
assert_job_contains_regex "deploy-staging" 'permissions:' "deploy-staging declares explicit permissions"
assert_job_contains_regex "deploy-staging" 'id-token:\s+write' "deploy-staging grants id-token: write for GitHub OIDC"
assert_job_contains_regex "deploy-staging" 'contents:\s+read' "deploy-staging grants contents: read"
assert_job_contains_regex "deploy-staging" 'uses:\s+aws-actions/configure-aws-credentials@ff717079ee2060e4bcee96c4779b553acc87447c' "deploy-staging pins AWS credentials action by commit SHA"
assert_job_contains_regex "deploy-staging" 'role-to-assume:\s+\$\{\{\s*secrets\.DEPLOY_IAM_ROLE_ARN\s*\}\}' "deploy-staging assumes role from secret-backed role-to-assume"
assert_job_contains_regex "deploy-staging" 'name:\s+Build release binaries' "deploy-staging has build step"
assert_job_not_contains_regex "deploy-staging" 'dnf install -y curl' "deploy-staging does not install curl package in Amazon Linux (curl-minimal conflict)"
assert_job_not_contains_regex "deploy-staging" 'curl\s+https://sh\.rustup\.rs.*\|\s*sh' "deploy-staging avoids curl-pipe-shell remote installer execution"
assert_job_contains_regex "deploy-staging" 'dnf install -y .*rust.*cargo' "deploy-staging installs rust/cargo from distro packages"
assert_job_contains_regex "deploy-staging" 'name:\s+Upload release artifacts' "deploy-staging has S3 upload step"
assert_job_contains_regex "deploy-staging" 'name:\s+Trigger API deploy' "deploy-staging has deploy trigger step"
assert_job_contains_regex "deploy-staging" 'needs:' "deploy-staging declares required gate dependencies"
for required_gate in rust-test rust-lint migration-test web-test check-sizes web-lint secret-scan; do
  assert_job_contains_regex "deploy-staging" "${required_gate},?" "deploy-staging needs ${required_gate}"
done
assert_job_not_contains_regex "deploy-staging" '^\s*playwright,\s*$' "deploy-staging keeps playwright advisory (outside needs)"
assert_job_contains_regex "deploy-staging" "if:\s+github\\.ref == 'refs/heads/main' && github\\.event_name == 'push'" "deploy-staging is gated to main push"
assert_job_contains_regex "deploy-staging" 'ARTIFACT_PREFIX="staging/\$\{GITHUB_SHA\}/"' "deploy-staging scopes artifact prefix to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3api list-objects-v2 --bucket fjcloud-releases-staging --prefix "\$\{ARTIFACT_PREFIX\}" --max-items 1' "deploy-staging performs pre-write S3 list-objects-v2 overwrite guard for staging bucket"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fjcloud-api s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-api' "deploy-staging uploads fjcloud-api to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fj-metering-agent s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fj-metering-agent' "deploy-staging uploads fj-metering-agent to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fjcloud-aggregation-job s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-aggregation-job' "deploy-staging uploads fjcloud-aggregation-job to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 sync infra/migrations s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/migrations' "deploy-staging uploads infra/migrations to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp ops/scripts/migrate.sh s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/scripts/migrate.sh' "deploy-staging uploads migrate.sh to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp ops/scripts/lib/generate_ssm_env.sh s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/scripts/generate_ssm_env.sh' "deploy-staging uploads generate_ssm_env.sh to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp ops/systemd/fj-metering-agent\.service s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/systemd/fj-metering-agent\.service' "deploy-staging uploads fj-metering-agent.service to staging SHA path"
assert_job_contains_regex "deploy-staging" 'bash ops/scripts/deploy\.sh staging "\$\{GITHUB_SHA\}"' "deploy-staging triggers staging deploy with GitHub SHA"

assert_contains_regex 'cargo fmt --check' "workflow includes cargo fmt --check"
assert_all_uses_are_sha_pinned
assert_deploy_uploads_use_git_sha
assert_deploy_has_s3_overwrite_guard

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
