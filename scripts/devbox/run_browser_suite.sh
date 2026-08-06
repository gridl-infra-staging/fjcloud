#!/usr/bin/env bash
# Run the Playwright browser suite on a devbox, with a Stripe TEST key injected
# for the billing rows that require one.
#
# WHY THIS EXISTS
#   provision_devbox.sh and sync_to_devbox.sh stand a devbox up and push source
#   to it, but nothing in the repo ever ran the suite there — the run step was
#   re-invented by hand each time, including the Stripe wiring, which is exactly
#   the sort of thing that gets it wrong. This is that missing step.
#
# THE STRIPE SITUATION, WHICH IS NOT WHAT IT LOOKS LIKE
#   Four browser rows need a Stripe test key and fail closed without one
#   (web/tests/fixtures/fixtures.ts), so the devbox reports 350 of 354. The
#   obvious fix — hand it a key — was tried and MEASURED, and it is wrong:
#
#   infra/api/src/startup.rs:84-94 picks the Stripe service by presence. A set
#   STRIPE_SECRET_KEY yields LiveStripeService; only its ABSENCE lets
#   STRIPE_LOCAL_MODE=1 select LocalStripeService, the stateful mock that also
#   spawns an in-process webhook dispatcher. The devbox's generated .env.local
#   sets STRIPE_LOCAL_MODE=1 and carries no key, so the box runs the mock.
#
#   Injecting a key therefore does not add four rows — it switches the entire
#   stack to real Stripe, whose webhooks arrive over the network instead of from
#   that dispatcher, and this box runs no `stripe listen` forwarder. That is read
#   from the source above, not measured: an attempt to measure it on 2026-08-05
#   was invalidated when a second session was found syncing to the same devbox
#   with `rsync --delete`, which removes the gitignored tests/fixtures/.auth/
#   mid-run and fails the suite for reasons unrelated to Stripe. So the key is
#   OPT-IN (--stripe-live) on the strength of the startup.rs contract alone, and
#   the default run withholds it. Whether it would help or hurt is UNMEASURED.
#
#   Closing the 350/354 gap for real needs a webhook forwarder on the box, not a
#   credential. That is not built here.
#
# WHAT IT WILL NOT DO
#   Send a live-mode key, under any flag or environment. The shared prefix
#   policy in scripts/lib/stripe_checks.sh permits live keys when
#   STRIPE_LIVE_CUTOVER=1 because one deliberate cutover path needs that; this
#   path is stricter and refuses them unconditionally. A live key on a devbox
#   moves real money and buys nothing.
#
#   Copy `.secret/.env.secret` wholesale. sync_to_devbox.sh refuses to, in terms
#   callers cannot override, and that must stay: the file holds LIVE Stripe keys
#   (sk_live_, rk_live_) beside the test ones, and the devbox is a public-IP host
#   given no IAM role precisely so compromising it yields nothing.
#
# PUBLIC MIRROR
#   scripts/ syncs wholesale to the public mirror, so this file is published.
#   No host names, account ids, instance ids, or credentials may be hardcoded —
#   everything environment-specific is a flag or an environment variable.
#
# USAGE
#   run_browser_suite.sh --host <host> [--key <ssh-key>] [options]
#
#   --host <host>          REQUIRED. Devbox SSH host.
#   --key <path>           SSH private key. Default: $DEVBOX_SSH_KEY.
#   --user <name>          SSH user. Default: ubuntu.
#   --remote-dir <path>    Repo path on the devbox. Default: ~/fjcloud_dev.
#   --flapjack-dir <path>  Engine checkout on the devbox. Default: ~/flapjack_engine.
#   --json-out <path>      Remote path for the Playwright JSON report.
#   --stripe-live          Opt in to injecting the Stripe test key. Read the section above first.
#   --dry-run              Print the plan and the resolved coverage; connect to nothing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Canonical Stripe prefix policy lives here; reuse it rather than re-deriving
# what a valid test key looks like in a second place.
# shellcheck source=/dev/null
. "$REPO_ROOT/scripts/lib/stripe_checks.sh"

HOST=""
SSH_KEY="${DEVBOX_SSH_KEY:-}"
SSH_USER="ubuntu"
REMOTE_DIR="fjcloud_dev"
FLAPJACK_DIR="flapjack_engine"
JSON_OUT="e2e_report.json"
DRY_RUN=0
STRIPE_LIVE=0

# Single exit path for precondition failures. The DEVBOX_REFUSED: prefix is
# machine-readable on purpose so tests can distinguish "refused for reason X"
# from "the script blew up", which also exits non-zero. Matches the convention
# already used by provision_devbox.sh and sync_to_devbox.sh.
refuse() {
    echo "DEVBOX_REFUSED: $*" >&2
    exit 2
}

# Spelled out rather than sed'ing a line range out of the header comment: a
# range silently prints the wrong thing the first time anyone edits above it.
usage() {
    cat <<'USAGE'
Usage: run_browser_suite.sh --host <host> [options]

  --host <host>          REQUIRED. Devbox SSH host.
  --key <path>           SSH private key. Default: $DEVBOX_SSH_KEY.
  --user <name>          SSH user. Default: ubuntu.
  --remote-dir <path>    Repo path on the devbox, relative to $HOME. Default: fjcloud_dev.
  --flapjack-dir <path>  Engine checkout on the devbox, relative to $HOME. Default: flapjack_engine.
  --json-out <path>      Playwright JSON report path on the devbox, relative to $HOME.
  --stripe-live          Inject the Stripe test key. Switches the API to LiveStripeService
                         and REQUIRES a stripe listen forwarder on the box. Not for full-suite runs.
  --dry-run              Print the plan and resolved coverage; connect to nothing.

Stripe: the default run injects NO key, so the API keeps LocalStripeService and
its in-process webhook dispatcher — the best full-suite denominator this box can
produce (~350 of 354). --stripe-live sends STRIPE_SECRET_KEY_RESTRICTED
(preferred) or STRIPE_SECRET_KEY over ssh stdin, which switches the API to
LiveStripeService and needs a stripe listen forwarder on the box; without one it
scores far worse than the default. Live-mode keys are refused unconditionally.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)         HOST="${2:-}"; shift 2 ;;
        --key)          SSH_KEY="${2:-}"; shift 2 ;;
        --user)         SSH_USER="${2:-}"; shift 2 ;;
        --remote-dir)   REMOTE_DIR="${2:-}"; shift 2 ;;
        --flapjack-dir) FLAPJACK_DIR="${2:-}"; shift 2 ;;
        --json-out)     JSON_OUT="${2:-}"; shift 2 ;;
        --stripe-live)  STRIPE_LIVE=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --help|-h)      usage; exit 0 ;;
        *)              refuse "unknown argument '$1'" ;;
    esac
done

[ -n "$HOST" ] || refuse "--host is required"

# ---------------------------------------------------------------------------
# Resolve the Stripe key.
#
# Prefer the restricted key: it is scoped to the resources the browser fixtures
# actually touch, so a leak is bounded and it can be revoked without disturbing
# the operator's own key. Fall back to canonical STRIPE_SECRET_KEY only when no
# restricted key exists, matching the precedence already used by
# scripts/launch/post_deploy_evidence_capture.sh.
# ---------------------------------------------------------------------------
STRIPE_KEY=""
COVERAGE_NOTE=""

# MEASURED 2026-08-05, and the reason this is opt-in rather than automatic.
#
# infra/api/src/startup.rs:84-94 selects the Stripe service by presence: a set
# STRIPE_SECRET_KEY yields LiveStripeService, and ONLY its absence lets
# STRIPE_LOCAL_MODE=1 select LocalStripeService — the stateful mock that also
# spawns its own webhook dispatcher. The devbox's generated .env.local sets
# STRIPE_LOCAL_MODE=1 and carries no key, so the box runs the mock.
#
# Exporting a key therefore does not "add" the four Stripe rows; it switches the
# whole stack to real Stripe, and real Stripe delivers webhooks over the network
# rather than through the in-process dispatcher, which this box does not run.
# Opt-in rests on that contract, not on a measurement: the run intended to
# measure it was invalidated by a second session syncing to the same devbox with
# `rsync --delete` (see the header). Default to withholding, because switching a
# whole stack's payment backend should be something a caller asks for.
if [ "$STRIPE_LIVE" = "1" ]; then
    STRIPE_KEY="${STRIPE_SECRET_KEY_RESTRICTED:-${STRIPE_SECRET_KEY:-}}"
    [ -n "$STRIPE_KEY" ] || refuse "--stripe-live needs STRIPE_SECRET_KEY_RESTRICTED or STRIPE_SECRET_KEY in the environment"
fi

if [ -n "$STRIPE_KEY" ]; then
    # Unconditional live refusal, checked BEFORE the shared policy so that no
    # environment variable can reach the permissive branch of that policy.
    case "$STRIPE_KEY" in
        sk_live_*|rk_live_*)
            refuse "refusing to send a LIVE Stripe key to a devbox (resolved key has a live prefix); the devbox takes test-mode keys only, regardless of STRIPE_LIVE_CUTOVER"
            ;;
    esac
    if ! stripe_secret_key_has_allowed_prefix "$STRIPE_KEY"; then
        refuse "resolved Stripe key has no permitted test-mode prefix (expected sk_test_ or rk_test_)"
    fi
    COVERAGE_NOTE="STRIPE-LIVE: key injected, so the API runs LiveStripeService instead of the local mock. This is NOT a valid full-suite denominator unless a stripe listen webhook forwarder is running on the box — without one, webhook-driven rows fail and the run scores far WORSE than omitting the key. Use for targeted Stripe specs."
else
    # No silent caps. Without a key the four Stripe-backed fixtures fail closed
    # rather than skipping, so the run reports fewer usable rows. Say so up front
    # instead of leaving the operator to read four env failures as product bugs.
    COVERAGE_NOTE="mock Stripe (default): the API uses LocalStripeService, so ~350 of 354 rows are meaningful and the 4 Stripe-backed rows fail closed. That is the best full-suite denominator this box can produce today; see --stripe-live before assuming a key would raise it."
fi

echo "[devbox-run] host=$SSH_USER@$HOST remote-dir=~/$REMOTE_DIR"
echo "[devbox-run] coverage: $COVERAGE_NOTE"

if [ "$DRY_RUN" = "1" ]; then
    echo "[devbox-run] dry run: no connection attempted, no key transmitted"
    exit 0
fi

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=20 -o BatchMode=yes)
[ -n "$SSH_KEY" ] && SSH_OPTS=(-i "$SSH_KEY" "${SSH_OPTS[@]}")

# ---------------------------------------------------------------------------
# Transmit.
#
# The key is written into the remote script's TEXT, which travels over ssh's
# stdin. It is never an ssh argument and never an argument of the remote
# command, so it cannot be read out of `ps` on the devbox, and it is never
# written to the devbox's filesystem. printf %q keeps it intact through the
# remote shell's parsing.
#
# Residual exposure, stated rather than glossed: once exported it lives in the
# environment of the remote shell and its children, so anything already running
# as the same user could read it from /proc/<pid>/environ for the duration of
# the run. That is strictly narrower than argv (which `ps` exposes to every
# user) or a dotfile (which outlives the run and survives a reboot), and on a
# single-purpose devbox where the suite is the only workload it is the residual
# we accept. It is also why the key should be the scoped rk_test_ one: a leak
# is bounded to test-mode objects and revocable on its own.
# ---------------------------------------------------------------------------
{
    if [ -n "$STRIPE_KEY" ]; then
        printf 'export STRIPE_SECRET_KEY=%q\n' "$STRIPE_KEY"
    fi
    printf 'REMOTE_DIR=%q\nFLAPJACK_DIR=%q\nJSON_OUT=%q\n' \
        "$REMOTE_DIR" "$FLAPJACK_DIR" "$JSON_OUT"
    cat <<'REMOTE_BODY'
set -uo pipefail
cd "$HOME/$REMOTE_DIR/web" || { echo "[devbox-run] repo not found at ~/$REMOTE_DIR — run sync_to_devbox.sh first" >&2; exit 3; }

export FLAPJACK_DEV_DIR="$HOME/$FLAPJACK_DIR"
export PATH="$HOME/.cargo/bin:$PATH"
export PLAYWRIGHT_JSON_OUTPUT_NAME="$HOME/$JSON_OUT"

# The compose services stop with the instance, so a devbox that was auto-stopped
# comes back with postgres down and the suite fails at bootstrap rather than on
# any real defect. Start them and wait for postgres to actually accept
# connections before handing over to Playwright.
# Compose derives its project name from the directory, so the container names
# follow --remote-dir rather than being fixed to one checkout name.
for svc in postgres mailpit seaweedfs; do
    docker start "${REMOTE_DIR}-${svc}-1" >/dev/null 2>&1 || true
done
for _ in $(seq 1 30); do
    pg_isready -h localhost -p 5432 >/dev/null 2>&1 && break
    sleep 2
done
if ! pg_isready -h localhost -p 5432 >/dev/null 2>&1; then
    echo "[devbox-run] postgres never became ready; refusing to report a denominator from a broken bootstrap" >&2
    exit 4
fi

echo "[devbox-run] start $(date -u +%FT%TZ)"
npm run test:e2e -- --reporter=line,json --max-failures=0
status=$?
echo "[devbox-run] exit=$status $(date -u +%FT%TZ)"
exit "$status"
REMOTE_BODY
} | ssh "${SSH_OPTS[@]}" "$SSH_USER@$HOST" 'bash -s'
