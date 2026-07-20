#!/usr/bin/env bash
# Static contract test for .github/workflows/ci.yml
# TDD red/green stages for Stage 1 CI hardening.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ci.yml"

PASS_COUNT=0
FAIL_COUNT=0
E2E_DEPLOYED_FAILURE_PAGING_BUFFER_MINUTES=10

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

assert_not_contains_regex() {
  local pattern="$1"
  local msg="$2"
  if _grep -n "$pattern" "$WORKFLOW_FILE" >/dev/null 2>&1; then
    fail "$msg (unexpected pattern found: $pattern)"
  else
    pass "$msg"
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

assert_step_timeout_leaves_job_buffer() {
  local job_name="$1"
  local step_name="$2"
  local min_buffer_minutes="$3"
  local msg="$4"
  local job_timeout step_timeout actual_buffer_minutes detail

  job_timeout="$(job_block "$job_name" | awk '
    /^[[:space:]]{4}timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
      print $2
      exit
    }
  ')"
  step_timeout="$(step_block "$job_name" "$step_name" | awk '
    /^[[:space:]]+timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
      print $2
      exit
    }
  ')"

  if [[ -z "$job_timeout" ]]; then
    fail "$msg (job timeout missing: $job_name)"
    return
  fi

  if [[ -z "$step_timeout" ]]; then
    fail "$msg (step timeout missing in $job_name/$step_name)"
    return
  fi

  actual_buffer_minutes=$((job_timeout - step_timeout))
  if (( actual_buffer_minutes >= min_buffer_minutes )); then
    pass "$msg"
  else
    detail="step timeout $step_timeout leaves ${actual_buffer_minutes}m before job timeout $job_timeout"
    fail "$msg ($detail; need at least ${min_buffer_minutes}m in $job_name/$step_name)"
  fi
}

assert_timeout_helper_rejects_near_equal_timeout() {
  local original_workflow_file="$WORKFLOW_FILE"
  local original_pass_count="$PASS_COUNT"
  local original_fail_count="$FAIL_COUNT"
  local temp_dir temp_workflow inner_fail_count

  temp_dir="$(mktemp -d)"
  temp_workflow="$temp_dir/ci.yml"
  cat >"$temp_workflow" <<'YAML'
jobs:
  e2e-deployed:
    timeout-minutes: 45
    steps:
      - name: Run deployed staging browser lane wrapper
        timeout-minutes: 44
        run: bash scripts/launch/produce_launch_verification_bundle.sh
YAML

  WORKFLOW_FILE="$temp_workflow"
  PASS_COUNT=0
  FAIL_COUNT=0
  assert_step_timeout_leaves_job_buffer \
    "e2e-deployed" \
    'Run deployed staging browser lane wrapper' \
    "$E2E_DEPLOYED_FAILURE_PAGING_BUFFER_MINUTES" \
    "timeout helper rejects unsafe near-equal step/job timeouts" >/dev/null 2>&1
  inner_fail_count="$FAIL_COUNT"
  WORKFLOW_FILE="$original_workflow_file"
  PASS_COUNT="$original_pass_count"
  FAIL_COUNT="$original_fail_count"
  rm -rf "$temp_dir"

  if (( inner_fail_count > 0 )); then
    pass "timeout helper rejects unsafe near-equal step/job timeouts"
  else
    fail "timeout helper rejects unsafe near-equal step/job timeouts (44m wrapper under 45m job was accepted)"
  fi
}

assert_step_contains_empty_webhook_warning_branch() {
  local job_name="$1"
  local step_name="$2"
  local msg="$3"
  local block
  block="$(step_block "$job_name" "$step_name")"
  block="$(printf '%s\n' "$block" | grep -Ev '^[[:space:]]*#')"
  if [[ -z "$block" ]]; then
    fail "$msg (step missing in $job_name: $step_name)"
    return
  fi

  if awk '
    /^[[:space:]]*if[[:space:]]+(\[\[?)[[:space:]]+-z[[:space:]]+.*DISCORD_WEBHOOK_URL.*(\]\]?);[[:space:]]*then[[:space:]]*$/ {
      in_empty_webhook_branch=1
      branch_depth=1
      branch_warning_seen=0
      next
    }
    in_empty_webhook_branch && branch_depth == 1 && /^[[:space:]]*(else|elif[[:space:]].*then)[[:space:]]*$/ {
      if (branch_warning_seen) {
        found=1
      }
      exit
    }
    in_empty_webhook_branch && /^[[:space:]]*if[[:space:]].*then[[:space:]]*$/ {
      branch_depth++
      next
    }
    in_empty_webhook_branch && /^[[:space:]]*fi[[:space:]]*$/ {
      if (branch_depth == 1) {
        if (branch_warning_seen) {
          found=1
          exit
        }
        in_empty_webhook_branch=0
        branch_depth=0
        branch_warning_seen=0
        next
      }
      branch_depth--
      next
    }
    in_empty_webhook_branch && /ALERT DELIVERY UNCONFIGURED/ {
      branch_warning_seen=1
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$block" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (missing ALERT DELIVERY UNCONFIGURED inside empty DISCORD_WEBHOOK_URL branch in $job_name/$step_name)"
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

last_named_step() {
  local job_name="$1"
  job_block "$job_name" | awk '
    /^[[:space:]]+- name: / {
      line=$0
      sub(/^[[:space:]]+- name: /, "", line)
      last=line
    }
    END {
      if (last != "") {
        print last
      }
    }
  '
}

assert_final_named_step() {
  local job_name="$1"
  local step_name="$2"
  local msg="$3"
  local last_step

  last_step="$(last_named_step "$job_name")"

  if [[ -z "$last_step" ]]; then
    fail "$msg (job has no named steps: $job_name)"
    return
  fi

  if [[ "$last_step" == "$step_name" ]]; then
    pass "$msg"
  else
    fail "$msg (last named step in $job_name: $last_step)"
  fi
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
  if _grep -n 'release_artifacts_existing_count fjcloud-releases-staging "\$\{ARTIFACT_PREFIX\}"' <<<"$deploy_block" >/dev/null 2>&1 \
    && _grep -n 'aws s3api list-objects-v2' ops/scripts/lib/release_artifacts.sh >/dev/null 2>&1; then
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
assert_contains_regex '^\s{2}shell-hygiene:\s*$' "job shell-hygiene exists"
assert_contains_regex '^\s{2}local-dev-up-smoke:\s*$' "job local-dev-up-smoke exists"
assert_contains_regex '^\s{2}web-lint:\s*$' "job web-lint exists"
assert_contains_regex '^\s{2}e2e-deployed:\s*$' "job e2e-deployed exists"
assert_contains_regex '^\s{2}secret-scan:\s*$' "job secret-scan exists"
assert_contains_regex '^\s{2}deploy-staging:\s*$' "job deploy-staging exists"
assert_not_contains_regex '^\s{2}playwright:\s*$' "job playwright does not exist"
assert_not_contains_regex 'playwright-ci-[[:alnum:]-]+' "workflow does not use playwright-ci mock secrets"
assert_not_contains_regex 'The `playwright` job remains advisory' "workflow does not carry stale advisory deploy comments"

assert_job_contains_regex "rust-test" 'uses:\s+actions/checkout@' "rust-test has checkout step"
assert_job_contains_regex "rust-test" 'run:\s+bash scripts/reliability/seed-test-profiles.sh' "rust-test seeds reliability profile artifacts"
assert_job_contains_regex "rust-test" 'uses:\s+dtolnay/rust-toolchain@' "rust-test has rust toolchain setup"
assert_job_contains_regex "rust-test" 'run:\s+cargo test --workspace' "rust-test has cargo test command"
assert_job_contains_regex "rust-test" 'timeout-minutes:\s+45' "rust-test has bounded timeout"
assert_job_contains_regex "rust-test" 'DATABASE_URL:\s+postgres://fjcloud:password@127\.0\.0\.1:5432/fjcloud_test' "rust-test exposes PostgreSQL service URL to integration tests"
# tenant_isolation_proptest moved to nightly.yml on 2026-05-02 — kept out
# of the per-push deploy gate to shave ~3-5 min off every CI cycle. See
# nightly_workflow_test.sh for its new contract assertion.
assert_job_not_contains_regex "rust-test" 'tenant_isolation_proptest' "rust-test does not run tenant isolation proptest (nightly only)"

assert_job_contains_regex "rust-lint" 'uses:\s+actions/checkout@' "rust-lint has checkout step"
assert_job_contains_regex "rust-lint" 'run:\s+bash scripts/tests/generate_ssm_env_test\.sh' "rust-lint runs generate_ssm_env contract test"
assert_job_contains_regex "rust-lint" 'run:\s+bash scripts/tests/local_ci_gate_set_e_test\.sh' "rust-lint runs local-ci rust-lint regression test"
assert_job_contains_regex "rust-lint" 'run:\s+bash scripts/tests/integration_test_layout_test\.sh' "rust-lint runs integration-test layout contract"
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

# shell-hygiene job — anchored 2026-05-31 after the exec-bit + SIGPIPE +
# seaweedfs probe regression cluster. Each named test must stay wired.
assert_job_contains_regex "shell-hygiene" 'uses:\s+actions/checkout@' "shell-hygiene has checkout step"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/script_exec_bits_test\.sh' "shell-hygiene runs exec-bit regression test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/port_collision_diagnose_test\.sh' "shell-hygiene runs port-collision diagnose test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/compose_project_test\.sh' "shell-hygiene runs compose-project resolver test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/source_pollution_contract_test\.sh' "shell-hygiene runs source-pollution contract test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/git_push_with_sync_test\.sh' "shell-hygiene runs mirror-sync wrapper contract test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/post_wave_a_sync_prod_test\.sh' "shell-hygiene runs prod-promotion gate contract test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/local_dev_runbook_currency_test\.sh' "shell-hygiene runs local-dev contract regression test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/clean_orphans_test\.sh' "shell-hygiene runs clean-orphans regression test"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/local_stack_contract_test\.sh' "shell-hygiene runs local stack compatibility tests"
assert_job_contains_regex "shell-hygiene" 'scripts/tests/e2e_preflight_test\.sh' "shell-hygiene runs browser preflight compatibility tests"

# local-dev-up-smoke job — this is the full local demo gate. It must run the
# orchestration owner script (scripts/local_demo.sh), then verify seeded
# end-to-end API/web behavior before teardown.
assert_job_contains_regex "local-dev-up-smoke" 'uses:\s+actions/checkout@' "local-dev-up-smoke has checkout step"
assert_job_contains_regex "local-dev-up-smoke" 'uses:\s+actions/setup-node@' "local-dev-up-smoke has node setup step"
assert_job_contains_regex "local-dev-up-smoke" 'node-version:\s+22' "local-dev-up-smoke pins Node.js 22"
assert_job_contains_regex "local-dev-up-smoke" 'flapjackhq/flapjack' "local-dev-up-smoke pulls flapjack from public release"
assert_job_contains_regex "local-dev-up-smoke" 'source scripts/lib/flapjack_binary\.sh' "local-dev-up-smoke reads the canonical flapjack dependency version"
assert_job_contains_regex "local-dev-up-smoke" 'FLAPJACK_VERSION="v\$\{FJCLOUD_FLAPJACK_VERSION\}"' "local-dev-up-smoke derives its release tag from the canonical dependency version"
assert_job_not_contains_regex "local-dev-up-smoke" 'FLAPJACK_VERSION:\s+v' "local-dev-up-smoke does not duplicate a flapjack version literal"
assert_job_contains_regex "local-dev-up-smoke" 'releases/download/' "local-dev-up-smoke fetches from public release artifact endpoint"
assert_job_contains_regex "local-dev-up-smoke" 'sha256sum -c' "local-dev-up-smoke verifies flapjack checksum before extract"
assert_job_not_contains_regex "local-dev-up-smoke" 'secrets\.FLAPJACK_' "local-dev-up-smoke does not depend on flapjack-acquisition secrets (flapjack is public)"
assert_job_contains_regex "local-dev-up-smoke" 'bash scripts/local_demo\.sh' "local-dev-up-smoke runs local_demo.sh end-to-end"
assert_job_contains_regex "local-dev-up-smoke" 'curl -fsS "http://127\.0\.0\.1:3001/health"' "local-dev-up-smoke probes api /health after demo startup"
assert_job_contains_regex "local-dev-up-smoke" 'curl -fsS "http://127\.0\.0\.1:5173/"' "local-dev-up-smoke probes web / after demo startup"
assert_job_contains_regex "local-dev-up-smoke" 'Authorization:\s+Bearer.*http://127\.0\.0\.1:3001/indexes' "local-dev-up-smoke verifies seeded authenticated /indexes behavior"
assert_job_contains_regex "local-dev-up-smoke" 'bash scripts/local-dev-down\.sh --clean' "local-dev-up-smoke tears down with --clean"
assert_step_contains_regex "local-dev-up-smoke" 'Tear down' 'if:\s+always\(\)' "local-dev-up-smoke teardown always runs"
assert_step_order "local-dev-up-smoke" 'Download flapjack release binary' 'Run full local demo stack' "local-dev-up-smoke downloads flapjack before running local demo"
assert_step_order "local-dev-up-smoke" 'Run full local demo stack' 'Probe API health endpoint' "local-dev-up-smoke probes api after running local demo"
assert_step_order "local-dev-up-smoke" 'Probe API health endpoint' 'Probe seeded authenticated indexes endpoint' "local-dev-up-smoke verifies seeded auth flow after health probe"
assert_step_order "local-dev-up-smoke" 'Probe seeded authenticated indexes endpoint' 'Tear down' "local-dev-up-smoke tears down after e2e probes"

assert_job_contains_regex "web-lint" 'uses:\s+actions/checkout@' "web-lint has checkout step"
assert_job_contains_regex "web-lint" 'uses:\s+actions/setup-node@' "web-lint has node setup step"
assert_job_contains_regex "web-lint" 'npm run check' "web-lint runs svelte-check"
assert_job_contains_regex "web-lint" 'eslint' "web-lint runs eslint"
assert_job_contains_regex "web-lint" 'npm run lint:e2e' "web-lint runs browser-unmocked lint"
assert_job_contains_regex "web-lint" 'screen_specs_coverage_test\.sh' "web-lint runs screen spec coverage contract"

assert_job_contains_regex "e2e-deployed" 'needs:\s+deploy-staging' "e2e-deployed depends on deploy-staging"
assert_job_contains_regex "e2e-deployed" "if:\s+github\\.repository == 'gridl-infra-staging/fjcloud' && github\\.ref == 'refs/heads/main' && github\\.event_name == 'push'" "e2e-deployed keeps the staging-main push-only gate"
assert_job_contains_regex "e2e-deployed" 'timeout-minutes:\s+45' "e2e-deployed sets timeout-minutes to 45"
assert_job_contains_regex "e2e-deployed" 'group:\s+e2e-deployed-\$\{\{\s*github\.ref\s*\}\}' "e2e-deployed sets concurrency group by ref"
assert_job_contains_regex "e2e-deployed" 'cancel-in-progress:\s+false' "e2e-deployed does not cancel in-progress runs"
assert_job_contains_regex "e2e-deployed" 'permissions:' "e2e-deployed declares explicit permissions"
assert_job_contains_regex "e2e-deployed" 'id-token:\s+write' "e2e-deployed grants id-token: write for GitHub OIDC"
assert_job_contains_regex "e2e-deployed" 'contents:\s+read' "e2e-deployed grants contents: read"
assert_job_contains_regex "e2e-deployed" 'STRIPE_LOCAL_MODE:\s+"1"' "e2e-deployed enables local Stripe mode for deployed Playwright"
assert_job_contains_regex "e2e-deployed" 'uses:\s+actions/checkout@' "e2e-deployed has checkout step"
assert_job_contains_regex "e2e-deployed" 'uses:\s+actions/setup-node@' "e2e-deployed has node setup step"
assert_job_contains_regex "e2e-deployed" 'node-version:\s+22' "e2e-deployed uses Node.js 22"
assert_job_contains_regex "e2e-deployed" 'uses:\s+aws-actions/configure-aws-credentials@ff717079ee2060e4bcee96c4779b553acc87447c' "e2e-deployed pins AWS credentials action by commit SHA"
assert_job_contains_regex "e2e-deployed" 'role-to-assume:\s+\$\{\{\s*secrets\.DEPLOY_IAM_ROLE_ARN\s*\}\}' "e2e-deployed assumes role from secret-backed role-to-assume"
assert_job_contains_regex "e2e-deployed" 'aws-region:\s+\$\{\{\s*env\.AWS_REGION\s*\}\}' "e2e-deployed passes AWS region from env"
assert_job_contains_regex "e2e-deployed" 'run:\s+cd web && npm ci' "e2e-deployed installs web dependencies"
assert_job_contains_regex "e2e-deployed" 'run:\s+cd web && npx playwright install --with-deps chromium' "e2e-deployed installs chromium for Playwright"
assert_job_contains_regex "e2e-deployed" 'run:\s+bash scripts/launch/produce_launch_verification_bundle\.sh' "e2e-deployed runs launch-verification wrapper"
assert_timeout_helper_rejects_near_equal_timeout
assert_step_timeout_leaves_job_buffer \
  "e2e-deployed" \
  'Run deployed staging browser lane wrapper' \
  "$E2E_DEPLOYED_FAILURE_PAGING_BUFFER_MINUTES" \
  "e2e-deployed browser wrapper leaves enough job budget for artifact upload and failure paging"
assert_job_contains_regex "e2e-deployed" 'name:\s+Upload launch verification artifacts' "e2e-deployed uploads launch artifacts"
assert_step_contains_regex "e2e-deployed" 'Upload launch verification artifacts' 'if:\s+always\(\)' "e2e-deployed artifact upload always runs"
assert_step_contains_regex "e2e-deployed" 'Upload launch verification artifacts' 'uses:\s+actions/upload-artifact@' "e2e-deployed artifact upload uses upload-artifact action"
assert_step_contains_regex "e2e-deployed" 'Page e2e-deployed failure' 'if:\s+failure\(\)' "e2e-deployed failure paging runs only after failure"
assert_step_contains_regex "e2e-deployed" 'Page e2e-deployed failure' 'DISCORD_WEBHOOK_URL:\s+\$\{\{\s*secrets\.DISCORD_WEBHOOK_URL\s*\}\}' "e2e-deployed failure paging uses the staging Discord webhook secret"
assert_step_contains_regex "e2e-deployed" 'Page e2e-deployed failure' '\$\{\{\s*github\.server_url\s*\}\}/\$\{\{\s*github\.repository\s*\}\}/actions/runs/\$\{\{\s*github\.run_id\s*\}\}' "e2e-deployed failure paging builds the run URL from GitHub context"
assert_step_contains_empty_webhook_warning_branch "e2e-deployed" 'Page e2e-deployed failure' "e2e-deployed failure paging warns inside the empty Discord webhook branch"
assert_step_order "e2e-deployed" 'Install dependencies' 'Install Playwright browsers' "e2e-deployed installs dependencies before browsers"
assert_step_order "e2e-deployed" 'Install Playwright browsers' 'Run deployed staging browser lane wrapper' "e2e-deployed installs browsers before wrapper run"
assert_step_order "e2e-deployed" 'Run deployed staging browser lane wrapper' 'Upload launch verification artifacts' "e2e-deployed uploads artifacts after wrapper run"
assert_step_order "e2e-deployed" 'Upload launch verification artifacts' 'Page e2e-deployed failure' "e2e-deployed failure paging runs after artifact upload"
assert_final_named_step "e2e-deployed" 'Page e2e-deployed failure' "e2e-deployed failure paging is the final named step"

assert_job_contains_regex "secret-scan" 'uses:\s+actions/checkout@' "secret-scan has checkout step"
assert_job_contains_regex "secret-scan" 'permissions:' "secret-scan declares explicit permissions"
assert_job_contains_regex "secret-scan" 'contents:\s+read' "secret-scan grants contents: read"
assert_job_contains_regex "secret-scan" 'gitleaks' "secret-scan uses gitleaks"
assert_job_contains_regex "secret-scan" 'name:\s+Run gitleaks \(PR diff\)' "secret-scan has PR diff scan step"
assert_job_contains_regex "secret-scan" "if:\s+github\\.event_name == 'pull_request'" "secret-scan scopes diff scan to pull requests"
assert_job_contains_regex "secret-scan" 'GITHUB_TOKEN:\s+\$\{\{\s*secrets\.GITHUB_TOKEN\s*\}\}' "secret-scan passes GITHUB_TOKEN for PR scanning"
assert_job_contains_regex "secret-scan" 'curl -fsSLO "\$\{GITLEAKS_BASE_URL\}/\$\{GITLEAKS_ARCHIVE\}"' "secret-scan downloads the pinned gitleaks archive without shell piping"
assert_job_contains_regex "secret-scan" 'curl -fsSLO "\$\{GITLEAKS_BASE_URL\}/\$\{GITLEAKS_CHECKSUMS\}"' "secret-scan downloads the upstream checksum manifest"
assert_job_contains_regex "secret-scan" 'sha256sum -c -' "secret-scan verifies the gitleaks archive checksum before install"
assert_job_not_contains_regex "secret-scan" 'curl.*\|\s*tar' "secret-scan does not stream remote archives directly into tar"
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
assert_job_contains_regex "deploy-staging" 'cargo build --release .* -p retention-job' "deploy-staging builds retention-job release binary"
assert_job_contains_regex "deploy-prod" 'cargo build --release .* -p retention-job' "deploy-prod builds retention-job release binary"
assert_job_contains_regex "deploy-prod" 'source ops/scripts/lib/release_artifacts\.sh' "deploy-prod uses shared release artifact helper"
assert_job_contains_regex "deploy-prod" 'release_artifacts_reuse_existing fjcloud-releases-prod "\$\{ARTIFACT_PREFIX\}" infra/rollback_contract\.json' "deploy-prod reruns reuse matching prod artifacts"
assert_job_not_contains_regex "deploy-staging" 'dnf install -y curl' "deploy-staging does not install curl package in Amazon Linux (curl-minimal conflict)"
assert_job_not_contains_regex "deploy-staging" 'curl\s+https://sh\.rustup\.rs.*\|\s*sh' "deploy-staging avoids curl-pipe-shell remote installer execution"
assert_job_contains_regex "deploy-staging" 'dnf install -y .*rust.*cargo' "deploy-staging installs rust/cargo from distro packages"
assert_job_contains_regex "deploy-staging" 'name:\s+Upload release artifacts' "deploy-staging has S3 upload step"
assert_job_contains_regex "deploy-staging" 'name:\s+Trigger API deploy' "deploy-staging has deploy trigger step"
assert_job_contains_regex "deploy-staging" 'needs:' "deploy-staging declares required gate dependencies"
for required_gate in rust-test rust-lint migration-test web-test check-sizes shell-hygiene local-dev-up-smoke web-lint secret-scan; do
  assert_job_contains_regex "deploy-staging" "${required_gate},?" "deploy-staging needs ${required_gate}"
done
assert_job_contains_regex "deploy-staging" "if:\s+github\\.repository == 'gridl-infra-staging/fjcloud' && github\\.ref == 'refs/heads/main' && github\\.event_name == 'push'" "deploy-staging is gated to main push on the staging mirror repo"
assert_job_contains_regex "deploy-prod" "if:\s+github\\.repository == 'gridl-infra-prod/fjcloud' && github\\.ref == 'refs/heads/main' && github\\.event_name == 'push'" "deploy-prod is gated to main push on the prod mirror repo"
assert_job_contains_regex "deploy-staging" 'ARTIFACT_PREFIX="staging/\$\{GITHUB_SHA\}/"' "deploy-staging scopes artifact prefix to staging SHA path"
assert_job_contains_regex "deploy-staging" 'source ops/scripts/lib/release_artifacts\.sh' "deploy-staging uses shared release artifact helper"
assert_job_contains_regex "deploy-staging" 'release_artifacts_existing_count fjcloud-releases-staging "\$\{ARTIFACT_PREFIX\}"' "deploy-staging checks existing staging artifacts through shared helper"
assert_job_contains_regex "deploy-staging" 'release_artifacts_reuse_existing fjcloud-releases-staging "\$\{ARTIFACT_PREFIX\}" infra/rollback_contract\.json' "deploy-staging reruns reuse matching staging artifacts"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fjcloud-api s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-api' "deploy-staging uploads fjcloud-api to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fj-metering-agent s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fj-metering-agent' "deploy-staging uploads fj-metering-agent to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fjcloud-aggregation-job s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-aggregation-job' "deploy-staging uploads fjcloud-aggregation-job to staging SHA path"
assert_job_contains_regex "deploy-staging" 'aws s3 cp infra/fjcloud-retention-job s3://fjcloud-releases-staging/staging/\$\{GITHUB_SHA\}/fjcloud-retention-job' "deploy-staging uploads fjcloud-retention-job to staging SHA path"
assert_job_contains_regex "deploy-prod" 'aws s3 cp infra/fjcloud-retention-job s3://fjcloud-releases-prod/prod/\$\{GITHUB_SHA\}/fjcloud-retention-job' "deploy-prod uploads fjcloud-retention-job to prod SHA path"
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
