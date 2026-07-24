#!/usr/bin/env bash
#
# run_browser_lane_locally.sh — FAST local iteration lane for the LB-2 / LB-3
# Stripe billing browser specs.
#
# ─── Why this exists ──────────────────────────────────────────────────────
# scripts/launch/run_browser_lane_against_staging.sh drives the SAME two specs
# but only against DEPLOYED staging, so every code change costs a 30–60 min
# deploy round-trip. The specs can just as well run against a LOCAL stack using
# REAL Stripe *test mode* — no deploy needed. This launcher is that local lane.
#
#   * Use THIS script for fast inner-loop verification of billing/Stripe code.
#   * run_browser_lane_against_staging.sh REMAINS the final pre-launch gate:
#     it proves the specs green against the actually-deployed staging surface.
#     A green run here is necessary-but-not-sufficient; still run the staging
#     lane before flipping a LAUNCH.md verdict.
#
# ─── What it does ─────────────────────────────────────────────────────────
#   1. Hydrates test-mode Stripe keys (sk_test_/pk_test_/whsec_) from SSM
#      (the staging Stripe sandbox — same account as .secret/.env.secret's
#      sk_test, VERIFIED account acct_1Sy…z4UH). Fails closed on wrong prefix.
#   2. Starts a local flapjack + a local API (real Stripe test mode) in the
#      background, on explicitly-pinned ports.
#   3. Lets Playwright own the web server (SvelteKit dev) via the config's
#      explicit --no-deps web-only path, pointed at our local API.
#   4. Runs the target spec(s), captures an evidence bundle mirroring the
#      staging launcher's shape (SUMMARY.md, git_sha.txt, per-lane .txt).
#   5. Always tears down the flapjack + API processes it started (EXIT trap),
#      touching only its own PIDs.
#
# ─── Why we DON'T reuse scripts/api-dev.sh / playwright_local_stack.sh for the
#     API (important, non-obvious) ────────────────────────────────────────
# api-dev.sh, when API_DEV_ALLOW_LIVE_STRIPE=1, force-loads STRIPE_PUBLISHABLE_KEY
# directly from .env.local via prefer_env_file_assignment_for_key(), overriding
# anything the caller exported. In this repo .env.local's STRIPE_PUBLISHABLE_KEY
# is a MISMATCHED pk_live_ (while its secret key is sk_test_). The backend serves
# that publishable key verbatim at /billing/publishable-key (infra/api/src/config.rs
# reads STRIPE_PUBLISHABLE_KEY raw), so the browser's Stripe.js would initialise
# with a LIVE publishable key while every SetupIntent/PaymentIntent client_secret
# is TEST mode → the Stripe Payment Element refuses to mount → the LB-3
# @p0_coverage test fails. There is no env override for this because api-dev.sh
# reads the value straight from the file. playwright_local_stack.sh starts the API
# via api-dev.sh, so it inherits the same defect.
# => We therefore launch the API ourselves with an explicitly-corrected env
#    (SSM pk_test_ wins), while still REUSING the shared lib helpers
#    (scripts/lib/env.sh, scripts/lib/stripe_checks.sh, scripts/lib/health.sh,
#    scripts/lib/flapjack_binary.sh) for everything else.
#    FINDING for maintainers: api-dev.sh's live-Stripe publishable-key selection
#    should prefer a caller-exported STRIPE_PUBLISHABLE_KEY (or validate that the
#    .env.local publishable key mode matches the secret key mode). Reported, not
#    fixed here (out of scope for this task).
#
# ─── Why no Mailpit / no remote opt-in (non-obvious) ──────────────────────
# The billing fixture arrangeBillingPortalCustomer auto-verifies fresh signups
# through the local API's SKIP_EMAIL_VERIFICATION path — the auto-verify branch
# (resolveFreshSignupVerificationTokenOrAutoVerifiedSentinel) triggers precisely
# when PLAYWRIGHT_TARGET_REMOTE is NOT set. So we deliberately DO NOT set
# PLAYWRIGHT_TARGET_REMOTE (that is the staging/remote lane's opt-in) and we need
# NO Mailpit: no verification email is ever sent when auto-verify is on. Setting
# the remote opt-in here would (a) route fixtures at deployed hosts and (b) skip
# the local auto-verify, breaking signup.
#
# ─── Port pinning (non-obvious) ───────────────────────────────────────────
# playwright.config.contract.ts derives per-workspace default ports by hashing
# the cwd, so an unpinned run can drift between the stack we start and the ports
# Playwright targets. We pin PLAYWRIGHT_WEB_PORT / PLAYWRIGHT_API_PORT /
# PLAYWRIGHT_FLAPJACK_PORT (and the derived LISTEN_ADDR / S3_LISTEN_ADDR /
# API_URL / API_BASE_URL / BASE_URL / FLAPJACK_URL) once, and export the SAME
# values to both the backend processes and the Playwright invocation.
#
# Usage:
#   scripts/launch/run_browser_lane_locally.sh \
#     --lane signup_to_paid_invoice|billing_portal_payment_method_update|both \
#     [--evidence-dir <path>]
#
#   scripts/launch/run_browser_lane_locally.sh --help
#
# Env / prerequisites:
#   - AWS credentials with ssm:GetParameter on /fjcloud/staging/stripe_* .
#     Sourced automatically from .secret/.env.secret (override with
#     FJCLOUD_SECRET_FILE) when AWS_ACCESS_KEY_ID is not already in the shell.
#   - Postgres running + migrated on the DATABASE_URL in .env.local (the task's
#     local stack; same assumption as api-dev.sh).
#   - web/node_modules installed (npm ci) and a local flapjack binary reachable
#     (FLAPJACK_DEV_DIR or an adjacent flapjack_dev checkout — see
#     scripts/lib/flapjack_binary.sh).
#   - Port overrides: PLAYWRIGHT_WEB_PORT / PLAYWRIGHT_API_PORT /
#     PLAYWRIGHT_FLAPJACK_PORT (defaults 5273 / 3051 / 7751).
#
# Cost note: creates real Stripe *test-mode* customers/payment-methods (free)
# and writes to the LOCAL postgres. Fixture cleanup machinery removes the
# customers it tracks.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Shared helpers — the same owners api-dev.sh / playwright_local_stack.sh use.
# shellcheck source=../lib/env.sh
source "$SCRIPT_DIR/../lib/env.sh"
# shellcheck source=../lib/health.sh
source "$SCRIPT_DIR/../lib/health.sh"
# shellcheck source=../lib/stripe_checks.sh
source "$SCRIPT_DIR/../lib/stripe_checks.sh"
# shellcheck source=../lib/web_runtime.sh
source "$SCRIPT_DIR/../lib/web_runtime.sh"
# shellcheck source=../lib/flapjack_binary.sh
source "$SCRIPT_DIR/../lib/flapjack_binary.sh"

log() { echo "[local-browser-lane] $*"; }
die() { echo "[local-browser-lane] ERROR: $*" >&2; exit 1; }

canonicalize_path() {
  python3 - "$1" <<'PY'
import os, sys
print(os.path.realpath(sys.argv[1]))
PY
}

# Keep evidence writes inside the repo (mirrors the staging launcher's guard).
validate_repo_owned_output_dir() {
  local candidate="$1" repo_root_real candidate_real
  repo_root_real="$(canonicalize_path "$REPO_ROOT")"
  candidate_real="$(canonicalize_path "$candidate")"
  case "$candidate_real" in
    "$repo_root_real" | "$repo_root_real"/*) return 0 ;;
    *) echo "ERROR: evidence dir must stay within repo root: $REPO_ROOT" >&2; return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Argument parsing (mirrors run_browser_lane_against_staging.sh where sensible).
# ---------------------------------------------------------------------------
LANE_ARG=""
EVIDENCE_DIR_ARG=""
SHOW_HELP=0
LANE_TIMEOUT_SECONDS="${BROWSER_LANE_TIMEOUT_SECONDS:-600}"

print_usage() {
  cat <<'EOF'
Usage:
  scripts/launch/run_browser_lane_locally.sh \
    --lane <signup_to_paid_invoice|billing_portal_payment_method_update|both> \
    [--evidence-dir <path>]

  scripts/launch/run_browser_lane_locally.sh --help

Lanes:
  signup_to_paid_invoice                — drives the LB-2 spec
  billing_portal_payment_method_update  — drives the LB-3 spec (@p0_coverage)
  both                                  — runs LB-2 then LB-3 sequentially

Default evidence dir:
  .local/browser-lane-evidence/<UTC-timestamp>/   (gitignored — this is a dev
  iteration lane, so its evidence stays OUT of the committed tree by default.
  Pass --evidence-dir to capture a bundle somewhere you intend to commit.)

Ports (override via env; defaults shown):
  PLAYWRIGHT_WEB_PORT=5273  PLAYWRIGHT_API_PORT=3051  PLAYWRIGHT_FLAPJACK_PORT=7751

Timeout:
  BROWSER_LANE_TIMEOUT_SECONDS bounds each lane (default 600).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lane) LANE_ARG="${2:-}"; shift 2 || die "--lane requires a value" ;;
    --evidence-dir) EVIDENCE_DIR_ARG="${2:-}"; shift 2 || die "--evidence-dir requires a value" ;;
    --help|-h) SHOW_HELP=1; shift ;;
    *) echo "ERROR: unknown argument: $1" >&2; print_usage >&2; exit 64 ;;
  esac
done

if [ "$SHOW_HELP" = "1" ]; then print_usage; exit 0; fi

case "$LANE_ARG" in
  signup_to_paid_invoice|billing_portal_payment_method_update|both) ;;
  "") echo "ERROR: --lane is required" >&2; print_usage >&2; exit 64 ;;
  *) echo "ERROR: --lane must be signup_to_paid_invoice|billing_portal_payment_method_update|both (got: $LANE_ARG)" >&2; exit 64 ;;
esac

if ! [[ "$LANE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$LANE_TIMEOUT_SECONDS" -le 0 ]; then
  die "BROWSER_LANE_TIMEOUT_SECONDS must be a positive integer (got: $LANE_TIMEOUT_SECONDS)"
fi

# ---------------------------------------------------------------------------
# AWS credentials for SSM. Prefer whatever is already in the shell; otherwise
# source the repo-local secret file (never echo its contents).
# ---------------------------------------------------------------------------
FJCLOUD_SECRET_FILE="${FJCLOUD_SECRET_FILE:-$REPO_ROOT/.secret/.env.secret}"
if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
  [ -f "$FJCLOUD_SECRET_FILE" ] || die "AWS credentials not in env and secret file not found: $FJCLOUD_SECRET_FILE"
  log "Sourcing AWS credentials from $FJCLOUD_SECRET_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$FJCLOUD_SECRET_FILE"
  set +a
fi
[ -n "${AWS_ACCESS_KEY_ID:-}" ] || die "AWS_ACCESS_KEY_ID unavailable after sourcing secret file"
AWS_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

# The secret file also exports SES_* + a pk_live_ STRIPE_PUBLISHABLE_KEY; those
# would (a) force the API into SES mode → crash on missing SES_CONFIGURATION_SET
# and (b) fight our SSM pk_test. We auto-verify locally so no email is sent —
# drop SES config entirely (mirrors api-dev.sh's Mailpit branch). The Stripe
# trio is overwritten from SSM immediately below.
unset SES_FROM_ADDRESS SES_REGION SES_CONFIGURATION_SET || true

# ---------------------------------------------------------------------------
# Hydrate test-mode Stripe keys from SSM and fail closed on the wrong prefix.
# We read publishable + secret + webhook explicitly (the seeder hydrator does
# not export the publishable key, which the browser needs).
# ---------------------------------------------------------------------------
ssm_value() {
  aws ssm get-parameter --name "$1" --with-decryption --region "$AWS_REGION" \
    --query 'Parameter.Value' --output text 2>/dev/null
}

log "Hydrating test-mode Stripe keys from SSM (region $AWS_REGION)"
STRIPE_PUBLISHABLE_KEY="$(ssm_value /fjcloud/staging/stripe_publishable_key)"
STRIPE_SECRET_KEY="$(ssm_value /fjcloud/staging/stripe_secret_key)"
STRIPE_WEBHOOK_SECRET="$(ssm_value /fjcloud/staging/stripe_webhook_secret)"

[ -n "$STRIPE_PUBLISHABLE_KEY" ] && [ "$STRIPE_PUBLISHABLE_KEY" != "None" ] \
  || die "failed to fetch /fjcloud/staging/stripe_publishable_key from SSM"
[ -n "$STRIPE_SECRET_KEY" ] && [ "$STRIPE_SECRET_KEY" != "None" ] \
  || die "failed to fetch /fjcloud/staging/stripe_secret_key from SSM"
[ -n "$STRIPE_WEBHOOK_SECRET" ] && [ "$STRIPE_WEBHOOK_SECRET" != "None" ] \
  || die "failed to fetch /fjcloud/staging/stripe_webhook_secret from SSM"

# Fail closed: this lane is TEST MODE ONLY. Never let a live key run here.
case "$STRIPE_PUBLISHABLE_KEY" in
  pk_test_*) ;;
  *) die "STRIPE_PUBLISHABLE_KEY must start with pk_test_; refusing to run" ;;
esac
case "$STRIPE_SECRET_KEY" in
  sk_test_*|rk_test_*) ;;
  *) die "STRIPE_SECRET_KEY must start with sk_test_ or rk_test_; refusing to run" ;;
esac
case "$STRIPE_WEBHOOK_SECRET" in
  whsec_*) ;;
  *) die "STRIPE_WEBHOOK_SECRET must start with whsec_; refusing to run" ;;
esac
export STRIPE_PUBLISHABLE_KEY STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET
log "Stripe keys OK (publishable ${STRIPE_PUBLISHABLE_KEY:0:8}…, secret key present, webhook secret present)"

# Verify the secret key actually authenticates against Stripe before we spend
# minutes building/booting the API (reuses the backend launch-gate check).
log "Validating live Stripe test key against Stripe API"
BACKEND_LIVE_GATE=1 check_stripe_key_present
BACKEND_LIVE_GATE=1 check_stripe_key_live
log "Stripe key authenticates"

# ---------------------------------------------------------------------------
# Pin ports and derive the URLs shared by the backend AND Playwright.
# ---------------------------------------------------------------------------
PLAYWRIGHT_WEB_PORT="${PLAYWRIGHT_WEB_PORT:-5273}"
PLAYWRIGHT_API_PORT="${PLAYWRIGHT_API_PORT:-3051}"
PLAYWRIGHT_FLAPJACK_PORT="${PLAYWRIGHT_FLAPJACK_PORT:-7751}"
for p in "$PLAYWRIGHT_WEB_PORT" "$PLAYWRIGHT_API_PORT" "$PLAYWRIGHT_FLAPJACK_PORT"; do
  [[ "$p" =~ ^[0-9]+$ ]] || die "ports must be numeric (got: $p)"
done
S3_PORT=$((PLAYWRIGHT_API_PORT + 1))

API_HTTP="http://127.0.0.1:${PLAYWRIGHT_API_PORT}"
WEB_HTTP="http://localhost:${PLAYWRIGHT_WEB_PORT}"
FLAPJACK_HTTP="http://127.0.0.1:${PLAYWRIGHT_FLAPJACK_PORT}"

# Backend listen addresses.
export LISTEN_ADDR="127.0.0.1:${PLAYWRIGHT_API_PORT}"
export S3_LISTEN_ADDR="127.0.0.1:${S3_PORT}"
# URL contract shared by the API, the fixtures, and Playwright.
export API_URL="$API_HTTP"
export API_BASE_URL="$API_HTTP"
export BASE_URL="$WEB_HTTP"
export FLAPJACK_URL="$FLAPJACK_HTTP"
export LOCAL_DEV_FLAPJACK_URL="$FLAPJACK_HTTP"
# Make the config's port resolvers deterministic (no cwd-hash drift).
export PLAYWRIGHT_WEB_PORT PLAYWRIGHT_API_PORT PLAYWRIGHT_FLAPJACK_PORT

# ---------------------------------------------------------------------------
# Build the API/web env. load_env_file skips already-exported keys, so our
# pre-exported Stripe trio + ports survive; .env.local fills DATABASE_URL,
# JWT_SECRET, ADMIN_KEY, ENVIRONMENT=local, FLAPJACK_ADMIN_KEY, OAuth, etc.
# ---------------------------------------------------------------------------
[ -f "$REPO_ROOT/.env.local" ] || die ".env.local not found at $REPO_ROOT/.env.local (needed for DATABASE_URL/JWT_SECRET/ADMIN_KEY)"
load_env_file "$REPO_ROOT/.env.local"

# Corrections that must win over .env.local for the local live-test-Stripe lane:
unset STRIPE_LOCAL_MODE || true          # .env.local sets =1 (in-process mock); MUST be clear for real Stripe.
unset STRIPE_TEST_SECRET_KEY || true     # avoid ambiguity; STRIPE_SECRET_KEY (SSM sk_test) is canonical.
unset SES_FROM_ADDRESS SES_REGION SES_CONFIGURATION_SET || true  # keep SES disabled (see above).
export ENVIRONMENT="${ENVIRONMENT:-local}"
export SKIP_EMAIL_VERIFICATION=1                 # local auto-verify (gated on ENVIRONMENT=local in the API).
export API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1
export API_DEV_ALLOW_LIVE_STRIPE=1               # documents intent; we don't route through api-dev.sh (see header).
export REPLICATION_CYCLE_INTERVAL_SECS="${REPLICATION_CYCLE_INTERVAL_SECS:-999999}"  # keep replication dormant.
export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
[ -n "${DATABASE_URL:-}" ] || die "DATABASE_URL not set (expected in .env.local)"
[ -n "${JWT_SECRET:-}" ] || die "JWT_SECRET not set (expected in .env.local)"
[ -n "${ADMIN_KEY:-}" ] || die "ADMIN_KEY not set (expected in .env.local)"

# Fixture/admin credentials the Playwright fixtures consume.
export E2E_ADMIN_KEY="$ADMIN_KEY"
TS_SEED="$(date -u +%Y%m%dT%H%M%SZ)"
export E2E_USER_EMAIL="${E2E_USER_EMAIL:-local-browser-lane-${TS_SEED}@e2e.griddle.test}"
export E2E_USER_PASSWORD="${E2E_USER_PASSWORD:-LocalLanePass${TS_SEED}!}"

# Fail closed if the Playwright runtime deps are missing (deterministic hint).
if ! has_web_playwright_test_runtime "$REPO_ROOT"; then
  die "$(web_playwright_test_runtime_missing_message) — owner: scripts/launch/run_browser_lane_locally.sh"
fi

# ---------------------------------------------------------------------------
# Preflight: refuse to run if our pinned ports are already occupied. We own
# only what we start; we never kill a foreign holder.
# ---------------------------------------------------------------------------
assert_port_free() {
  local port="$1" name="$2"
  if lsof -iTCP:"$port" -sTCP:LISTEN -P >/dev/null 2>&1; then
    echo "[local-browser-lane] ERROR: port $port ($name) is already in use." >&2
    lsof -iTCP:"$port" -sTCP:LISTEN -P 2>/dev/null | sed 's/^/[local-browser-lane]   /' >&2 || true
    die "free it or override PLAYWRIGHT_*_PORT, then retry"
  fi
}
assert_port_free "$PLAYWRIGHT_API_PORT" "api"
assert_port_free "$S3_PORT" "api-s3"
assert_port_free "$PLAYWRIGHT_WEB_PORT" "web"
# flapjack: only refuse if a NON-flapjack process holds the port.
if lsof -iTCP:"$PLAYWRIGHT_FLAPJACK_PORT" -sTCP:LISTEN -P >/dev/null 2>&1; then
  if curl -fsS "$FLAPJACK_HTTP/health" >/dev/null 2>&1; then
    die "port $PLAYWRIGHT_FLAPJACK_PORT already serves a flapjack we did not start; override PLAYWRIGHT_FLAPJACK_PORT"
  fi
  die "port $PLAYWRIGHT_FLAPJACK_PORT ($PLAYWRIGHT_FLAPJACK_PORT) is in use by a non-flapjack process"
fi

LOCAL_DIR="$REPO_ROOT/.local"
mkdir -p "$LOCAL_DIR"
FLAPJACK_LOG="$LOCAL_DIR/local_browser_lane_flapjack.log"
API_LOG="$LOCAL_DIR/local_browser_lane_api.log"

# ---------------------------------------------------------------------------
# Teardown — own PIDs only. cargo spawns the fjcloud-api binary as a child, so
# terminate the whole tree of each PID we started.
# ---------------------------------------------------------------------------
FLAPJACK_PID=""
API_PID=""

terminate_pid_tree() {
  local signal="$1" root_pid="$2" child_pid children
  children="$(pgrep -P "$root_pid" 2>/dev/null || true)"
  for child_pid in $children; do terminate_pid_tree "$signal" "$child_pid"; done
  kill "-$signal" "$root_pid" 2>/dev/null || true
}

cleanup() {
  if [ -n "$API_PID" ] && kill -0 "$API_PID" 2>/dev/null; then
    log "Stopping local API (pid $API_PID)"
    terminate_pid_tree TERM "$API_PID"; sleep 1; terminate_pid_tree KILL "$API_PID"
    wait "$API_PID" 2>/dev/null || true
  fi
  if [ -n "$FLAPJACK_PID" ] && kill -0 "$FLAPJACK_PID" 2>/dev/null; then
    log "Stopping local flapjack (pid $FLAPJACK_PID)"
    terminate_pid_tree TERM "$FLAPJACK_PID"; sleep 1; terminate_pid_tree KILL "$FLAPJACK_PID"
    wait "$FLAPJACK_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Start flapjack (background). Reuses the shared binary-discovery helper.
# ---------------------------------------------------------------------------
FLAPJACK_BIN="$(find_restart_ready_flapjack_binary "${FLAPJACK_DEV_DIR:-}" || true)"
if [ -z "$FLAPJACK_BIN" ] || [ ! -x "$FLAPJACK_BIN" ]; then
  die "no local flapjack binary found. Set FLAPJACK_DEV_DIR to your flapjack_dev checkout and: cargo build -p flapjack-server"
fi
log "Flapjack provenance: $(flapjack_source_provenance_summary)"
FLAPJACK_DATA_DIR="$LOCAL_DIR/flapjack-data-locallane-${PLAYWRIGHT_FLAPJACK_PORT}"
mkdir -p "$FLAPJACK_DATA_DIR"
log "Starting flapjack ($FLAPJACK_BIN) on :$PLAYWRIGHT_FLAPJACK_PORT"
FLAPJACK_ADMIN_KEY="$FLAPJACK_ADMIN_KEY" nohup "$FLAPJACK_BIN" \
  --port "$PLAYWRIGHT_FLAPJACK_PORT" --data-dir "$FLAPJACK_DATA_DIR" \
  < /dev/null > "$FLAPJACK_LOG" 2>&1 &
FLAPJACK_PID=$!
if ! wait_for_health "$FLAPJACK_HTTP/health" "flapjack" 45; then
  echo "---- flapjack log tail ----" >&2; tail -n 60 "$FLAPJACK_LOG" >&2 || true
  die "flapjack did not become healthy at $FLAPJACK_HTTP/health"
fi

# ---------------------------------------------------------------------------
# Start the API (background) with the corrected live-test-Stripe env. Direct
# cargo run — NOT api-dev.sh — so our SSM pk_test wins (see header rationale).
# ---------------------------------------------------------------------------
log "Starting local API on :$PLAYWRIGHT_API_PORT (real Stripe test mode; publishable ${STRIPE_PUBLISHABLE_KEY:0:8}…)"
( cd "$REPO_ROOT" && exec cargo run --manifest-path infra/Cargo.toml -p api ) > "$API_LOG" 2>&1 &
API_PID=$!
# First build can take several minutes; allow a generous bound.
API_READY_TIMEOUT="${LOCAL_LANE_API_READY_TIMEOUT_SECONDS:-360}"
if ! wait_for_health "$API_HTTP/health" "api" "$API_READY_TIMEOUT"; then
  echo "---- api log tail ----" >&2; tail -n 80 "$API_LOG" >&2 || true
  die "API did not become healthy at $API_HTTP/health within ${API_READY_TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
# Pre-create empty storage-state files for the chromium project. With --no-deps
# the auth.setup project does not run, but the chromium project still declares
# storageState: .auth/user.json etc. — a missing file is ENOENT before any test.
# Both target specs override cookies inside the test, so empty state is safe.
# ---------------------------------------------------------------------------
mkdir -p "$REPO_ROOT/web/tests/fixtures/.auth"
for state_file in user.json admin.json onboarding.json customer-journeys.json; do
  state_path="$REPO_ROOT/web/tests/fixtures/.auth/$state_file"
  [ -f "$state_path" ] || printf '{"cookies": [], "origins": []}\n' > "$state_path"
done

# ---------------------------------------------------------------------------
# Evidence bundle (same shape as the staging launcher).
# ---------------------------------------------------------------------------
if [ -z "$EVIDENCE_DIR_ARG" ]; then
  # Default under .local/ (gitignored — see .gitignore `*.local`). This is the
  # fast INNER-LOOP lane; its evidence is a throwaway dev artifact, unlike the
  # staging launcher whose bundles are committed launch-gate proof. Callers who
  # do want a committed bundle pass --evidence-dir explicitly.
  EVIDENCE_DIR_ARG="$REPO_ROOT/.local/browser-lane-evidence/${TS_SEED}"
fi
validate_repo_owned_output_dir "$EVIDENCE_DIR_ARG"
mkdir -p "$EVIDENCE_DIR_ARG"
GIT_SHA="$(cd "$REPO_ROOT" && git rev-parse HEAD)"
echo "$GIT_SHA" > "$EVIDENCE_DIR_ARG/git_sha.txt"
cat > "$EVIDENCE_DIR_ARG/SUMMARY.md" <<EOF
# Browser-lane LOCAL evidence — ${TS_SEED}

- **Lane:** $LANE_ARG
- **Git SHA:** $GIT_SHA
- **Target:** LOCAL stack, REAL Stripe test mode
- **BASE_URL (web):** $BASE_URL
- **API_URL:** $API_URL
- **FLAPJACK_URL:** $FLAPJACK_URL
- **Stripe publishable prefix:** ${STRIPE_PUBLISHABLE_KEY:0:8}…
- **PLAYWRIGHT_TARGET_REMOTE:** (unset — local auto-verify)
- **Started at (UTC):** $TS_SEED

Run by \`scripts/launch/run_browser_lane_locally.sh\`. Per-spec stdout lives in
\`signup_to_paid_invoice.txt\` / \`billing_portal_payment_method_update.txt\`
(each ends with an \`exit=<code>\` line). This is the FAST local lane;
\`run_browser_lane_against_staging.sh\` remains the deploy gate.
EOF

# ---------------------------------------------------------------------------
# Playwright runner with a per-lane timeout (adapted from the staging launcher).
# ---------------------------------------------------------------------------
run_playwright_with_timeout() {
  local timeout_seconds="$1" stdout_path="$2" working_dir="$3"; shift 3
  local timeout_flag; timeout_flag="$(mktemp "${TMPDIR:-/tmp}/fjcloud-local-lane-timeout.XXXXXX")"; rm -f "$timeout_flag"
  ( cd "$working_dir"; "$@" ) >"$stdout_path" 2>&1 &
  local cmd_pid=$!
  ( sleep "$timeout_seconds"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      printf 'timed out after %ss\n' "$timeout_seconds" > "$timeout_flag"
      terminate_pid_tree TERM "$cmd_pid"; sleep 1; terminate_pid_tree KILL "$cmd_pid"
    fi ) &
  local watchdog_pid=$!
  local exit_code=0
  wait "$cmd_pid" || exit_code=$?
  terminate_pid_tree TERM "$watchdog_pid"; wait "$watchdog_pid" 2>/dev/null || true
  if [ -s "$timeout_flag" ]; then cat "$timeout_flag" >> "$stdout_path"; rm -f "$timeout_flag"; return 124; fi
  rm -f "$timeout_flag"; return "$exit_code"
}

run_one_lane() {
  local lane="$1" spec_file
  case "$lane" in
    signup_to_paid_invoice) spec_file="tests/e2e-ui/full/signup_to_paid_invoice.spec.ts" ;;
    billing_portal_payment_method_update) spec_file="tests/e2e-ui/full/billing_portal_payment_method_update.spec.ts" ;;
    *) echo "ERROR: unknown lane: $lane" >&2; return 64 ;;
  esac
  echo "=== Running $lane (spec: $spec_file) against local $BASE_URL / api $API_URL ==="
  local stdout_path="$EVIDENCE_DIR_ARG/${lane}.txt"
  local lane_output_dir="test-results/${lane}"
  local exit_code=0
  # --no-deps: skip auth.setup (target specs arrange their own auth). Explicit
  # BASE_URL + --no-deps (no PLAYWRIGHT_TARGET_REMOTE) makes the config start the
  # web-only dev server itself, pointed at our already-running local API.
  run_playwright_with_timeout "$LANE_TIMEOUT_SECONDS" "$stdout_path" "$REPO_ROOT/web" \
    npx playwright test "$spec_file" --reporter=list --trace on --output "$lane_output_dir" --no-deps || exit_code=$?
  # Scrub absolute repo paths out of the captured stdout (repo rule).
  local scrubbed; scrubbed="$(sed "s|${REPO_ROOT}/||g" "$stdout_path")"
  printf '%s\n' "$scrubbed" > "$stdout_path"
  cat "$stdout_path"
  echo "exit=$exit_code" >> "$stdout_path"
  return "$exit_code"
}

OVERALL_EXIT=0
case "$LANE_ARG" in
  signup_to_paid_invoice) run_one_lane signup_to_paid_invoice || OVERALL_EXIT=$? ;;
  billing_portal_payment_method_update) run_one_lane billing_portal_payment_method_update || OVERALL_EXIT=$? ;;
  both)
    run_one_lane signup_to_paid_invoice || OVERALL_EXIT=$?
    run_one_lane billing_portal_payment_method_update || OVERALL_EXIT=$?
    ;;
esac

echo ""
log "Evidence bundle: $EVIDENCE_DIR_ARG"
exit "$OVERALL_EXIT"
