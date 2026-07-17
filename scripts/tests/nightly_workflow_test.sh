#!/usr/bin/env bash
# Static contract test for .github/workflows/nightly.yml

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/nightly.yml"
PRICING_CALCULATOR_LIB="$REPO_ROOT/infra/pricing-calculator/src/lib.rs"

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

assert_path_contains_regex() {
  local path="$1"
  local pattern="$2"
  local msg="$3"
  if _grep -n "$pattern" "$path" >/dev/null 2>&1; then
    pass "$msg"
  else
    fail "$msg (pattern not found in $path: $pattern)"
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

strip_pricing_freshness_tripwire_body() {
  local path="$1"
  awk '
      /fn pricing_freshness_wall_clock_tripwire[[:space:]]*\(/ {
        in_tripwire = 1
        depth = 0
        body_started = 0
      }
      in_tripwire {
        opens = gsub(/\{/, "{")
        closes = gsub(/\}/, "}")
        if (opens > 0) {
          body_started = 1
        }
        depth += opens - closes
        if (body_started && depth <= 0) {
          in_tripwire = 0
        }
        next
      }
      { print }
    ' "$path"
}

self_test_pricing_freshness_tripwire_stripper() {
  local fixture
  fixture="$(mktemp)"
  trap 'rm -f "$fixture"' RETURN
  cat >"$fixture" <<'RUST'
#[test]
#[ignore]
fn pricing_freshness_wall_clock_tripwire() {
    ensure_pricing_freshness(90).expect("wall-clock tripwire");
}

#[test]
fn default_suite_contract() {
    ensure_pricing_freshness(90).expect("default suite must not use wall clock");
}
RUST

  local stripped
  stripped="$(strip_pricing_freshness_tripwire_body "$fixture")"
  if _grep -n 'ensure_pricing_freshness\(90\)' <<<"$stripped" >/dev/null 2>&1; then
    pass "pricing freshness tripwire stripper resumes after ignored function body"
  else
    fail "pricing freshness tripwire stripper resumes after ignored function body"
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test_pricing_freshness_tripwire_stripper
  echo ""
  echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
  [[ "$FAIL_COUNT" -eq 0 ]]
  exit
fi

assert_pricing_freshness_default_suite_uses_injected_dates() {
  local remaining_wall_clock_calls
  remaining_wall_clock_calls="$(
    strip_pricing_freshness_tripwire_body "$PRICING_CALCULATOR_LIB" | _grep -n 'stale_providers\(90\)|ensure_pricing_freshness\(90\)' || true
  )"

  if [[ -n "$remaining_wall_clock_calls" ]]; then
    fail "default pricing freshness tests use injected dates (wall-clock calls outside ignored tripwire: $remaining_wall_clock_calls)"
  else
    pass "default pricing freshness tests use injected dates"
  fi
}

assert_pricing_freshness_tripwire_is_ignored_test() {
  local header
  if ! header="$(
    awk '
      /^[[:space:]]*#\[/ {
        attributes = attributes $0 "\n"
        next
      }
      /^[[:space:]]*$/ {
        next
      }
      /^[[:space:]]*fn pricing_freshness_wall_clock_tripwire[[:space:]]*\(/ {
        print attributes $0
        found = 1
        exit
      }
      {
        attributes = ""
      }
      END {
        if (!found) {
          exit 1
        }
      }
    ' "$PRICING_CALCULATOR_LIB"
  )"; then
    fail "pricing freshness tripwire source is an ignored Rust test (function missing)"
    return
  fi

  if _grep -n '^\s*#\[test\]' <<<"$header" >/dev/null 2>&1 &&
    _grep -n '^\s*#\[ignore\]' <<<"$header" >/dev/null 2>&1; then
    pass "pricing freshness tripwire source is an ignored Rust test"
  else
    fail "pricing freshness tripwire source is an ignored Rust test (missing #[test] or #[ignore])"
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
  # GitHub silently stops cron-scheduling a workflow it cannot parse (pushes
  # surface only 0s "workflow file issue" startup failures), so the grep-level
  # assertions below cannot catch a dead nightly schedule on their own.
  local err
  if err="$(python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$WORKFLOW_FILE" 2>&1)"; then
    pass "nightly workflow is well-formed YAML"
  else
    fail "nightly workflow is well-formed YAML (parse error: $(tail -1 <<<"$err"))"
  fi
}

echo ""
echo "=== Nightly Workflow Contract Tests ==="
echo ""

assert_file_exists "$WORKFLOW_FILE" "nightly workflow file exists"
assert_file_exists "$PRICING_CALCULATOR_LIB" "pricing calculator lib source exists"
assert_workflow_yaml_parses

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
assert_job_contains_regex "stripe-test-clock-live" 'run:\s+"cd infra && cargo test -p api --test billing stripe_test_clock_full_cycle_test::"' "stripe-test-clock-live runs only the stripe test-clock module slice"
assert_job_not_contains_regex "stripe-test-clock-live" 'cargo test --workspace' "stripe-test-clock-live does not run full workspace test sweep"

# Env contract: normalized Stripe env vars + integration gate.
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_SECRET_KEY:\s+\$\{\{\s*secrets\.STRIPE_SECRET_KEY\s*\}\}' "stripe-test-clock-live maps STRIPE_SECRET_KEY from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_WEBHOOK_SECRET:\s+\$\{\{\s*secrets\.STRIPE_WEBHOOK_SECRET\s*\}\}' "stripe-test-clock-live maps STRIPE_WEBHOOK_SECRET from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_PRICE_STARTER:\s+\$\{\{\s*secrets\.STRIPE_PRICE_STARTER\s*\}\}' "stripe-test-clock-live maps STRIPE_PRICE_STARTER from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS:\s+\$\{\{\s*secrets\.STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS\s*\}\}' "stripe-test-clock-live maps STRIPE_PRICE_STARTER_EXPECTED_UNIT_AMOUNT_CENTS from secrets"
assert_job_contains_regex "stripe-test-clock-live" 'INTEGRATION:\s+"1"' "stripe-test-clock-live enables integration gate"
assert_job_contains_regex "stripe-test-clock-live" 'BACKEND_LIVE_GATE:\s+"1"' "stripe-test-clock-live enables live gate"

# Tenant isolation proptest job — moved from per-push CI on 2026-05-02 to
# shave ~3-5 min off every CI cycle. The proptest is mock-only (no
# postgres, no stripe) so the job has no service dependencies.
assert_contains_regex '^\s{2}tenant-isolation-proptest:\s*$' "tenant-isolation-proptest job exists"
assert_job_contains_regex "tenant-isolation-proptest" 'uses:\s+actions/checkout@' "tenant-isolation-proptest has checkout step"
assert_job_contains_regex "tenant-isolation-proptest" 'uses:\s+dtolnay/rust-toolchain@' "tenant-isolation-proptest installs rust toolchain"
assert_job_contains_regex "tenant-isolation-proptest" 'uses:\s+Swatinem/rust-cache@' "tenant-isolation-proptest uses rust cache"
assert_job_contains_regex "tenant-isolation-proptest" 'run:\s+bash scripts/tests/nightly_workflow_test.sh' "tenant-isolation-proptest self-checks workflow contract"
assert_job_contains_regex "tenant-isolation-proptest" 'run:\s+"cd infra && cargo test -p api --test platform --features proptest-tests tenant_isolation_proptest::"' "tenant-isolation-proptest runs only the proptest module with proptest-tests feature"
assert_job_not_contains_regex "tenant-isolation-proptest" 'cargo test --workspace' "tenant-isolation-proptest does not run full workspace test sweep"

# Pricing freshness tripwire job: non-gating nightly wall-clock check for stale competitor pricing.
assert_contains_regex '^\s{2}pricing-freshness:\s*$' "pricing-freshness job exists"
assert_job_contains_regex "pricing-freshness" 'uses:\s+actions/checkout@' "pricing-freshness has checkout step"
assert_job_contains_regex "pricing-freshness" 'uses:\s+dtolnay/rust-toolchain@' "pricing-freshness installs rust toolchain"
assert_job_contains_regex "pricing-freshness" 'uses:\s+Swatinem/rust-cache@' "pricing-freshness uses rust cache"
assert_job_contains_regex "pricing-freshness" 'CARGO_INCREMENTAL:\s+"0"' "pricing-freshness disables incremental builds"
assert_job_contains_regex "pricing-freshness" 'CARGO_PROFILE_TEST_DEBUG:\s+"0"' "pricing-freshness strips test debug symbols"
assert_job_contains_regex "pricing-freshness" 'RUSTFLAGS:\s+"-Clink-arg=-fuse-ld=bfd"' "pricing-freshness uses standard nightly Rust linker flags"
assert_job_contains_regex "pricing-freshness" 'run:\s+bash scripts/tests/nightly_workflow_test.sh' "pricing-freshness self-checks workflow contract"
assert_job_contains_regex "pricing-freshness" 'run:\s+"?cd infra && cargo test -p pricing-calculator -- --ignored pricing_freshness_wall_clock_tripwire"?\s*$' "pricing-freshness runs only the ignored pricing freshness tripwire"
assert_job_not_contains_regex "pricing-freshness" 'cargo test --workspace' "pricing-freshness does not run full workspace test sweep"
assert_job_not_contains_regex "pricing-freshness" 'STRIPE_|secrets\.STRIPE_|INTEGRATION|BACKEND_LIVE_GATE|INTEGRATION_API_BASE|INTEGRATION_DB_URL' "pricing-freshness does not declare live Stripe or integration secrets"
assert_job_not_contains_regex "pricing-freshness" '^\s+needs:' "pricing-freshness has no job dependencies"

assert_path_contains_regex "$PRICING_CALCULATOR_LIB" 'fn pricing_freshness_wall_clock_tripwire[[:space:]]*\(' "pricing freshness ignored tripwire source exists"
assert_path_contains_regex "$PRICING_CALCULATOR_LIB" 'pricing_freshness_wall_clock_tripwire' "pricing freshness workflow filter is bound to source"
assert_pricing_freshness_tripwire_is_ignored_test
assert_pricing_freshness_default_suite_uses_injected_dates

assert_all_uses_are_sha_pinned

echo ""
echo "Summary: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

[[ "$FAIL_COUNT" -eq 0 ]]
