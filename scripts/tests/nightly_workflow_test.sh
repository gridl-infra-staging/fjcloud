#!/usr/bin/env bash
# Static contract test for .github/workflows/nightly.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/nightly.yml"

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

assert_job_not_contains_regex() {
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

echo ""
echo "=== Nightly Workflow Contract Tests ==="
echo ""

assert_file_exists "$WORKFLOW_FILE" "nightly workflow file exists"

# Triggers: nightly-only entry points.
assert_contains_regex '^on:\s*$' "workflow defines on block"
assert_contains_regex '^\s{2}schedule:\s*$' "workflow uses schedule trigger"
assert_contains_regex '^\s{4}-\s+cron:\s+"[^"]+"\s*$' "workflow defines a nightly cron"
assert_not_contains_regex '^\s{2}push:\s*$' "workflow does not use push trigger"
assert_not_contains_regex '^\s{2}pull_request:\s*$' "workflow does not use pull_request trigger"
assert_not_contains_regex 'cargo test --workspace' "workflow does not run full workspace tests"

# Slow-lane job contract.
assert_contains_regex '^\s{2}stripe-test-clock-live:\s*$' "stripe-test-clock-live job exists"
assert_job_contains_regex "stripe-test-clock-live" 'uses:\s+actions/checkout@' "stripe-test-clock-live has checkout step"
assert_job_contains_regex "stripe-test-clock-live" 'uses:\s+dtolnay/rust-toolchain@' "stripe-test-clock-live installs rust toolchain"
assert_job_contains_regex "stripe-test-clock-live" 'run:\s+bash scripts/tests/nightly_workflow_test.sh' "stripe-test-clock-live self-checks workflow contract"
assert_job_contains_regex "stripe-test-clock-live" 'run:\s+cd infra && cargo test -p api --test stripe_test_clock_full_cycle_test' "stripe-test-clock-live runs only the stripe test-clock test"
assert_job_not_contains_regex "stripe-test-clock-live" 'cargo test --workspace' "stripe-test-clock-live does not run full workspace test sweep"

# Env contract: normalized Stripe env vars + integration gate.
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_SECRET_KEY:\s+\$\{\{\s*secrets\.STRIPE_SECRET_KEY\s*\}\}' "stripe-test-clock-live maps STRIPE_SECRET_KEY from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_WEBHOOK_SECRET:\s+\$\{\{\s*secrets\.STRIPE_WEBHOOK_SECRET\s*\}\}' "stripe-test-clock-live maps STRIPE_WEBHOOK_SECRET from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'INTEGRATION:\s+"1"' "stripe-test-clock-live enables integration gate"
assert_job_contains_regex "stripe-test-clock-live" 'BACKEND_LIVE_GATE:\s+"1"' "stripe-test-clock-live enables live gate"

assert_all_uses_are_sha_pinned

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
