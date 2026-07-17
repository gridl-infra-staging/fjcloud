#!/usr/bin/env bash
# Static red contract test for .github/workflows/deploy_currency.yml.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/deploy_currency.yml"

PASS_COUNT=0
FAIL_COUNT=0

# Portable grep wrapper: converts \s to [[:space:]] for BSD/GNU grep -E.
_grep() {
  local flags=()
  while [[ $# -gt 1 && "$1" == -* ]]; do
    flags+=("$1")
    shift
  done
  local pattern="$1"
  shift
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
  [[ -f "$WORKFLOW_FILE" ]] || return 0
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
  block="$(job_block "$job_name" || true)"
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

assert_all_uses_are_sha_pinned() {
  local invalid
  invalid="$(_grep -n '^\s*uses:\s+[[:graph:]]+@|^\s*-\s*uses:\s+[[:graph:]]+@' "$WORKFLOW_FILE" | _grep -v '@[0-9a-f]{40}(\s+#.*)?$' || true)"
  if [[ -n "$invalid" ]]; then
    fail "all uses: entries must pin exact 40-char commit SHA (invalid lines: $invalid)"
  else
    pass "all uses: entries pin exact 40-char commit SHA"
  fi
}

assert_workflow_yaml_parses() {
  local err
  if err="$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW_FILE" 2>&1)"; then
    pass "deploy-currency workflow is well-formed YAML"
  else
    fail "deploy-currency workflow is well-formed YAML (parse error: $(tail -1 <<<"$err"))"
  fi
}

main() {
  echo ""
  echo "=== Deploy Currency Workflow Contract Tests ==="
  echo ""

  assert_file_exists "$WORKFLOW_FILE" "deploy-currency workflow file exists"
  if [[ ! -f "$WORKFLOW_FILE" ]]; then
    echo ""
    echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    exit 1
  fi

  assert_workflow_yaml_parses

  assert_contains_regex '^on:\s*$' "workflow defines on block"
  assert_contains_regex '^\s{2}schedule:\s*$' "workflow uses schedule trigger"
  assert_contains_regex '^\s{4}-\s+cron:\s+"[0-9]+ \* \* \* \*"\s*$' "workflow runs hourly"
  assert_contains_regex '^\s{2}workflow_dispatch:\s*$' "workflow supports manual dispatch"
  assert_not_contains_regex '^\s{2}push:\s*$' "workflow does not use push trigger"
  assert_not_contains_regex '^\s{2}pull_request:\s*$' "workflow does not use pull_request trigger"

  assert_contains_regex '^\s{2}deploy-currency:\s*$' "deploy-currency job exists"
  assert_job_contains_regex "deploy-currency" "if:\s+github\\.repository == 'gridl-infra-staging/fjcloud' \\|\\| github\\.event_name == 'workflow_dispatch'" "deploy-currency job has exact staging-or-manual guard"
  assert_job_contains_regex "deploy-currency" 'uses:\s+actions/checkout@' "deploy-currency job has checkout step"
  assert_job_contains_regex "deploy-currency" 'run:\s+bash scripts/tests/deploy_currency_workflow_test\.sh' "deploy-currency job self-checks workflow contract"
  assert_job_contains_regex "deploy-currency" 'run:\s+bash scripts/canary/deploy_currency_check\.sh' "deploy-currency job runs deploy-currency check"
  assert_job_contains_regex "deploy-currency" 'DISCORD_WEBHOOK_URL:\s+\$\{\{\s*secrets\.DISCORD_WEBHOOK_URL\s*\}\}' "deploy-currency job maps Discord webhook secret"
  assert_job_contains_regex "deploy-currency" 'GITHUB_TOKEN:\s+\$\{\{\s*github\.token\s*\}\}' "deploy-currency job maps GitHub token"

  assert_all_uses_are_sha_pinned

  echo ""
  echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

  [[ "$FAIL_COUNT" -eq 0 ]]
}

main "$@"
