#!/usr/bin/env bash
#
# run_browser_lane_against_staging.sh — drive the LB-2 / LB-3 Playwright
# specs against deployed staging on current-main code and capture an
# evidence bundle.
#
# Closes the LB-2 (signup_to_paid_invoice) and LB-3
# (billing_portal_payment_method_update) launch blockers per LAUNCH.md.
# The browser navigates the deployed staging UI (cloud.flapjack.foo).
# Fixtures hit the deployed staging API (api.flapjack.foo) with admin
# credentials sourced from SSM. Email verification tokens are read
# directly from the staging customers table via SSM-exec'd psql (Mailpit
# doesn't exist on staging).
#
# Usage:
#   scripts/launch/run_browser_lane_against_staging.sh \
#     --lane signup_to_paid_invoice|billing_portal_payment_method_update|both \
#     [--evidence-dir <path>]
#
# Alias removal criteria: see the `billing_portal_cancel` normalization
# block below for the explicit removal contract and grep-based exit check.
#
# `billing_portal_cancel` is accepted as a temporary alias for
# `billing_portal_payment_method_update` so existing operator muscle
# memory and runbooks keep resolving after the LB-3 spec was reframed.
#
# Env (auto-hydrated from SSM if not already set):
#   ADMIN_KEY            — staging API admin key
#   STRIPE_SECRET_KEY    — Stripe (test mode) sk_test_... matching staging API
#   STRIPE_WEBHOOK_SECRET
#
# Cost note: this creates real Stripe (test-mode) customers and writes to
# the staging customers / subscriptions / invoices tables. Cleanup is
# handled by the existing trackCustomerForCleanup fixture machinery
# (which deletes via the staging admin API). Stripe test-mode resources
# are free.
#
# Operator pre-reqs:
#   - AWS credentials with ssm:Get* + ssm:SendCommand permission
#     (typically: set -a; source .secret/.env.secret; set +a)
#   - Docker NOT required; node_modules in web/ must be installed
#   - Network reachability to cloud.flapjack.foo + api.flapjack.foo

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

LANE_ARG=""
EVIDENCE_DIR_ARG=""
SHOW_HELP=0
LANE_TIMEOUT_SECONDS="${BROWSER_LANE_TIMEOUT_SECONDS:-1800}"

is_allowed_hydrated_key() {
  case "$1" in
    ADMIN_KEY|DATABASE_URL|API_URL|FLAPJACK_URL|STRIPE_SECRET_KEY|SES_FROM_ADDRESS|STRIPE_WEBHOOK_SECRET|STAGING_API_URL|STAGING_STRIPE_WEBHOOK_URL)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_hydrated_export_line() {
  local line="$1"
  local payload key raw_value

  case "$line" in
    export\ *=*)
      payload="${line#export }"
      key="${payload%%=*}"
      raw_value="${payload#*=}"
      ;;
    *)
      return 1
      ;;
  esac

  is_allowed_hydrated_key "$key" || return 1
  [ -n "$raw_value" ] || return 1

  case "$raw_value" in
    *$'\n'*|*$'\r'*)
      return 1
      ;;
    \$\'*\')
      [[ "$raw_value" =~ ^\$\'([^\'\\]|\\.)*\'$ ]] || return 1
      ;;
    *)
      [[ "$raw_value" =~ ^([^[:space:];\&\|<>\`\"\'\$]|\'.*\'|\\.)+$ ]] || return 1
      ;;
  esac
}

hydrate_staging_env_from_ssm() {
  local hydrate_output
  hydrate_output="$(mktemp "${TMPDIR:-/tmp}/fjcloud_stage_hydrate.XXXXXX")"

  if ! bash "$REPO_ROOT/scripts/launch/hydrate_seeder_env_from_ssm.sh" staging > "$hydrate_output"; then
    rm -f "$hydrate_output"
    return 1
  fi

  while IFS= read -r line; do
    if ! validate_hydrated_export_line "$line"; then
      rm -f "$hydrate_output"
      echo "ERROR: hydrate_seeder_env_from_ssm.sh emitted an unexpected export line" >&2
      exit 1
    fi
  done < "$hydrate_output"

  # shellcheck disable=SC1090
  source "$hydrate_output"
  rm -f "$hydrate_output"
}

print_usage() {
  cat <<'EOF'
Usage:
  scripts/launch/run_browser_lane_against_staging.sh \
    --lane <signup_to_paid_invoice|billing_portal_payment_method_update|billing_portal_cancel|both> \
    [--evidence-dir <path>]

  scripts/launch/run_browser_lane_against_staging.sh --help

Lanes:
  signup_to_paid_invoice                — drives the LB-2 spec
  billing_portal_payment_method_update  — drives the LB-3 spec
  billing_portal_cancel                 — DEPRECATED alias, use billing_portal_payment_method_update
  both                                  — runs LB-2 then LB-3 sequentially

Default evidence dir:
  docs/runbooks/evidence/browser-evidence/<UTC-timestamp>_current_main/

Timeout:
  Set BROWSER_LANE_TIMEOUT_SECONDS to bound each lane runtime.
  On timeout, the lane exits 124, records a timeout line in its lane log,
  and --lane both still runs the other lane.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane)
      LANE_ARG="${2:-}"
      shift 2 || { echo "ERROR: --lane requires a value" >&2; exit 64; }
      ;;
    --evidence-dir)
      EVIDENCE_DIR_ARG="${2:-}"
      shift 2 || { echo "ERROR: --evidence-dir requires a value" >&2; exit 64; }
      ;;
    --help|-h)
      SHOW_HELP=1
      shift
      ;;
    *)
      echo "ERROR: unknown argument: $1" >&2
      print_usage >&2
      exit 64
      ;;
  esac
done

if [ "$SHOW_HELP" = "1" ]; then
  print_usage
  exit 0
fi

case "$LANE_ARG" in
  signup_to_paid_invoice|billing_portal_payment_method_update|billing_portal_cancel|both) ;;
  "")
    echo "ERROR: --lane is required" >&2
    print_usage >&2
    exit 64
    ;;
  *)
    echo "ERROR: --lane must be signup_to_paid_invoice|billing_portal_payment_method_update|billing_portal_cancel|both (got: $LANE_ARG)" >&2
    exit 64
    ;;
esac

# `billing_portal_cancel` is a temporary alias for the reframed LB-3
# lane. Normalize early so all downstream evidence filenames, log lines,
# and dispatch use the canonical name without duplicating mapping logic.
# Alias removal criteria (Wave 2 browser-specs): remove this alias once
# Wave 2 browser-specs ship and docs/runbooks/staging-evidence.md no longer
# references
# `billing_portal_cancel` in any active (non-archived) section. Verify
# with a repo grep: when zero `billing_portal_cancel` hits remain outside
# this script and archived evidence bundles, alias removal is safe.
if [ "$LANE_ARG" = "billing_portal_cancel" ]; then
  echo "NOTE: --lane billing_portal_cancel is a DEPRECATED alias; use billing_portal_payment_method_update" >&2
  LANE_ARG="billing_portal_payment_method_update"
fi

if [[ ! "$LANE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$LANE_TIMEOUT_SECONDS" -le 0 ]; then
  echo "ERROR: BROWSER_LANE_TIMEOUT_SECONDS must be a positive integer (got: $LANE_TIMEOUT_SECONDS)" >&2
  exit 64
fi

# ---------------------------------------------------------------------------
# Hydrate env from SSM. Reuses the canonical seeder hydrator so this stays
# in lockstep with the seeder + RC orchestrator.
# ---------------------------------------------------------------------------

# Source a validated temp file instead of eval'ing raw hydrator output.
# The hydrator prints `export KEY=%q` lines; validating the shape first keeps
# staged secret values from becoming shell syntax on the operator host.
#
# Preserve a pre-set, valid STRIPE_SECRET_KEY across hydration. The
# operator may source a working key from .secret/.env.secret (e.g.
# post-rotation when SSM /fjcloud/staging/stripe_secret_key holds a
# sentinel placeholder while the real key stays local-only). SSM stays
# canonical for everything else; only this one var defers to env when
# SSM produces a value that fails the downstream prefix check.
PRESERVED_STRIPE_SECRET_KEY=""
if [[ "${STRIPE_SECRET_KEY:-}" == sk_test_* || "${STRIPE_SECRET_KEY:-}" == rk_test_* ]]; then
  PRESERVED_STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY"
fi
unset STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET
hydrate_staging_env_from_ssm
if [[ "${STRIPE_SECRET_KEY:-}" != sk_test_* && "${STRIPE_SECRET_KEY:-}" != rk_test_* && -n "$PRESERVED_STRIPE_SECRET_KEY" ]]; then
  STRIPE_SECRET_KEY="$PRESERVED_STRIPE_SECRET_KEY"
  export STRIPE_SECRET_KEY
fi

if [ -z "${ADMIN_KEY:-}" ]; then
  echo "ERROR: ADMIN_KEY not hydrated from SSM" >&2
  exit 1
fi
if [ -z "${STRIPE_SECRET_KEY:-}" ]; then
  echo "ERROR: STRIPE_SECRET_KEY not hydrated from SSM" >&2
  exit 1
fi
if [[ "$STRIPE_SECRET_KEY" != sk_test_* && "$STRIPE_SECRET_KEY" != rk_test_* ]]; then
  echo "ERROR: STRIPE_SECRET_KEY must start with sk_test_ or rk_test_ for staging browser lanes" >&2
  exit 1
fi
if [ -z "${STRIPE_WEBHOOK_SECRET:-}" ]; then
  echo "ERROR: STRIPE_WEBHOOK_SECRET not hydrated from SSM" >&2
  exit 1
fi
if [[ "$STRIPE_WEBHOOK_SECRET" != whsec_* ]]; then
  echo "ERROR: STRIPE_WEBHOOK_SECRET must start with whsec_ for staging browser lanes" >&2
  exit 1
fi

# E2E_ADMIN_KEY is what the Playwright fixtures actually consume.
export E2E_ADMIN_KEY="$ADMIN_KEY"

# Browser navigates the deployed staging UI; fixtures hit the deployed
# staging API. PLAYWRIGHT_TARGET_REMOTE=1 lifts the loopback guard for
# the *.flapjack.foo allowlist (see web/playwright.config.contract.ts
# REMOTE_TARGET_HOST_SUFFIX_ALLOWLIST).
export BASE_URL="https://cloud.flapjack.foo"
export API_URL="https://api.flapjack.foo"
export API_BASE_URL="$API_URL"
export PLAYWRIGHT_TARGET_REMOTE=1

# Provide a placeholder MAILPIT_API_URL — the SSM verification path takes
# over when PLAYWRIGHT_TARGET_REMOTE=1, but the loopback guard in
# getMailpitApiUrl() still validates it on construction. Pointing at a
# loopback address that won't be hit avoids the guard error without
# weakening the local-lane behavior.
export MAILPIT_API_URL="${MAILPIT_API_URL:-http://127.0.0.1:9999}"

# Generate a per-customer cleanup-tracked seed user. The existing
# fixture machinery requires E2E_USER_EMAIL/PASSWORD to be set even when
# the spec under test creates its own fresh-signup users (the auth.setup
# project always runs). Use a unique value so reruns don't collide.
TS_SEED="$(date -u +%Y%m%dT%H%M%SZ)"
export E2E_USER_EMAIL="${E2E_USER_EMAIL:-staging-browser-lane-${TS_SEED}@e2e.griddle.test}"
export E2E_USER_PASSWORD="${E2E_USER_PASSWORD:-StagingLanePass${TS_SEED}!}"

# ---------------------------------------------------------------------------
# Empty storage-state files for the chromium project.
#
# We use --no-deps below to skip the auth.setup project (it tries to log in
# as a pre-existing E2E_USER_EMAIL that doesn't exist on staging). With
# --no-deps the .auth/user.json (and siblings) won't be created by setup,
# but Playwright still loads them on a clean machine because the chromium
# project declares `storageState: PLAYWRIGHT_STORAGE_STATE.user` — missing
# file = ENOENT before any test runs.
#
# Both target specs override the cookie inside the test (signup spec uses
# `test.use({ storageState: { cookies: [], origins: [] } })`; portal spec
# calls setAuthCookieForToken to inject a freshly-arranged user's cookie),
# so an empty initial storageState is safe — the test body sets whatever
# auth state it needs.
mkdir -p "$REPO_ROOT/web/tests/fixtures/.auth"
for state_file in user.json admin.json onboarding.json customer-journeys.json; do
  state_path="$REPO_ROOT/web/tests/fixtures/.auth/$state_file"
  if [ ! -f "$state_path" ]; then
    printf '{"cookies": [], "origins": []}\n' > "$state_path"
    echo "Pre-created empty storage state: $state_path"
  fi
done

# ---------------------------------------------------------------------------
# Evidence dir setup.
# ---------------------------------------------------------------------------

if [ -z "$EVIDENCE_DIR_ARG" ]; then
  EVIDENCE_DIR_ARG="$REPO_ROOT/docs/runbooks/evidence/browser-evidence/${TS_SEED}_current_main"
fi
mkdir -p "$EVIDENCE_DIR_ARG"

GIT_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
echo "$GIT_SHA" > "$EVIDENCE_DIR_ARG/git_sha.txt"

cat > "$EVIDENCE_DIR_ARG/SUMMARY.md" <<EOF
# Browser-lane staging evidence — ${TS_SEED}

- **Lane:** $LANE_ARG
- **Git SHA:** $GIT_SHA
- **BASE_URL:** $BASE_URL
- **API_URL:** $API_URL
- **PLAYWRIGHT_TARGET_REMOTE:** $PLAYWRIGHT_TARGET_REMOTE
- **Started at (UTC):** $TS_SEED

Run by \`scripts/launch/run_browser_lane_against_staging.sh\`. See
\`signup_to_paid_invoice.txt\` and/or
\`billing_portal_payment_method_update.txt\` for per-spec stdout.
Playwright artifacts under
\`web/test-results/\` and \`web/playwright-report/\` are NOT copied here
by default — the operator should run \`cp -r web/test-results <bundle>\`
after the run if needed for failure diagnosis.
EOF

# ---------------------------------------------------------------------------
# Run the lanes.
# ---------------------------------------------------------------------------

# TODO: Document run_one_lane.
terminate_pid_tree() {
  local signal="$1"
  local root_pid="$2"
  local child_pid=""
  local children=""

  children="$(pgrep -P "$root_pid" 2>/dev/null || true)"
  for child_pid in $children; do
    terminate_pid_tree "$signal" "$child_pid"
  done

  kill "-$signal" "$root_pid" 2>/dev/null || true
}

run_playwright_with_timeout() {
  local timeout_seconds="$1"
  local stdout_path="$2"
  local working_dir="$3"
  shift 3

  local timeout_flag
  timeout_flag="$(mktemp "${TMPDIR:-/tmp}/fjcloud-browser-lane-timeout.XXXXXX")"
  rm -f "$timeout_flag"

  (
    cd "$working_dir"
    "$@"
  ) >"$stdout_path" 2>&1 &
  local cmd_pid=$!

  (
    sleep "$timeout_seconds"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      printf 'timed out after %ss\n' "$timeout_seconds" > "$timeout_flag"
      terminate_pid_tree TERM "$cmd_pid"
      sleep 1
      terminate_pid_tree KILL "$cmd_pid"
    fi
  ) &
  local watchdog_pid=$!

  local exit_code=0
  wait "$cmd_pid" || exit_code=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [ -s "$timeout_flag" ]; then
    cat "$timeout_flag" >> "$stdout_path"
    rm -f "$timeout_flag"
    return 124
  fi

  rm -f "$timeout_flag"
  return "$exit_code"
}

run_one_lane() {
  local lane="$1"
  local spec_file
  case "$lane" in
    signup_to_paid_invoice)
      spec_file="tests/e2e-ui/full/signup_to_paid_invoice.spec.ts"
      ;;
    billing_portal_payment_method_update)
      spec_file="tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts"
      ;;
    *)
      echo "ERROR: unknown lane: $lane" >&2
      return 64
      ;;
  esac

  echo "=== Running $lane (spec: $spec_file) against $BASE_URL ==="
  local stdout_path="$EVIDENCE_DIR_ARG/${lane}.txt"
  local exit_code=0
  # --no-deps skips the auth.setup project. The setup project tries to log
  # in as a pre-existing E2E_USER_EMAIL — that user only exists on local
  # via Mailpit auto-verification. The signup spec creates its own user
  # (already storageState: {cookies: [], origins: []}) and the portal
  # spec overrides the cookie via setAuthCookieForToken, so neither
  # actually needs the setup-project user when running against staging.
  run_playwright_with_timeout "$LANE_TIMEOUT_SECONDS" "$stdout_path" "$REPO_ROOT/web" \
    npx playwright test "$spec_file" --reporter=list --no-deps || exit_code=$?
  cat "$stdout_path"
  echo "exit=$exit_code" >> "$stdout_path"
  return "$exit_code"
}

OVERALL_EXIT=0
case "$LANE_ARG" in
  signup_to_paid_invoice)
    run_one_lane signup_to_paid_invoice || OVERALL_EXIT=$?
    ;;
  billing_portal_payment_method_update)
    run_one_lane billing_portal_payment_method_update || OVERALL_EXIT=$?
    ;;
  both)
    run_one_lane signup_to_paid_invoice || OVERALL_EXIT=$?
    # Run LB-3 even if LB-2 failed — they are independent and we want
    # both stdouts captured in one bundle for diagnosis.
    run_one_lane billing_portal_payment_method_update || OVERALL_EXIT=$?
    ;;
esac

echo ""
echo "Evidence bundle: $EVIDENCE_DIR_ARG"
exit "$OVERALL_EXIT"
