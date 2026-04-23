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

assert_job_contains_regex "rust-lint" 'uses:\s+actions/checkout@' "rust-lint has checkout step"
assert_job_contains_regex "rust-lint" 'uses:\s+dtolnay/rust-toolchain@' "rust-lint has rust toolchain setup"
assert_job_contains_regex "rust-lint" 'run:\s+cargo clippy --workspace -- -D warnings' "rust-lint has cargo clippy command"

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
assert_job_contains_regex "playwright" 'playwright install' "playwright installs browser"
assert_job_contains_regex "playwright" 'playwright test' "playwright runs tests"

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
assert_job_contains_regex "deploy-staging" 'uses:\s+aws-actions/configure-aws-credentials@' "deploy-staging has AWS credentials step"
assert_job_contains_regex "deploy-staging" 'name:\s+Build release binaries' "deploy-staging has build step"
assert_job_contains_regex "deploy-staging" 'name:\s+Upload release artifacts' "deploy-staging has S3 upload step"
assert_job_contains_regex "deploy-staging" 'name:\s+Trigger API deploy' "deploy-staging has deploy trigger step"
assert_job_contains_regex "deploy-staging" 'needs:' "deploy-staging declares required gate dependencies"
for required_gate in rust-test rust-lint migration-test web-test check-sizes web-lint playwright secret-scan; do
  assert_job_contains_regex "deploy-staging" "${required_gate},?" "deploy-staging needs ${required_gate}"
done
assert_job_contains_regex "deploy-staging" "if:\s+github\\.ref == 'refs/heads/main' && github\\.event_name == 'push'" "deploy-staging is gated to main push"

assert_contains_regex 'cargo fmt --check' "workflow includes cargo fmt --check"
assert_all_uses_are_sha_pinned
assert_deploy_uploads_use_git_sha
assert_deploy_has_s3_overwrite_guard
assert_job_contains_regex "deploy-staging" 'generate_ssm_env\.sh' "deploy-staging uploads generate_ssm_env.sh to S3"

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
