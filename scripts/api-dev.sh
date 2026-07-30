#!/usr/bin/env bash
# api-dev.sh — Start the API with repo-local env files exported.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${FJCLOUD_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/health.sh
source "$SCRIPT_DIR/lib/health.sh"
# shellcheck source=lib/stripe_checks.sh
source "$SCRIPT_DIR/lib/stripe_checks.sh"
# shellcheck source=lib/local_url.sh
source "$SCRIPT_DIR/lib/local_url.sh"

log() { echo "[api-dev] $*"; }
die() {
    echo "[api-dev] ERROR: $*" >&2
    exit 1
}

resolve_port_from_addr() {
    local raw_addr="$1"
    local env_name="$2"
    local normalized="$raw_addr"
    local port

    if [[ "$normalized" == *"://"* ]]; then
        normalized="${normalized#*://}"
        normalized="${normalized%%/*}"
    fi

    port="${normalized##*:}"
    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        die "${env_name} must include a numeric port (got: ${raw_addr})"
    fi

    printf '%s\n' "$port"
}

resolve_listen_port() {
    local default_api_port="${PLAYWRIGHT_API_PORT:-3001}"
    resolve_port_from_addr "${LISTEN_ADDR:-0.0.0.0:${default_api_port}}" "LISTEN_ADDR"
}

resolve_default_s3_port() {
    local explicit_s3_port="${PLAYWRIGHT_S3_PORT:-}"
    local default_api_port="${PLAYWRIGHT_API_PORT:-3001}"

    if [ -n "$explicit_s3_port" ]; then
        if ! [[ "$explicit_s3_port" =~ ^[0-9]+$ ]]; then
            die "PLAYWRIGHT_S3_PORT must be numeric when set (got: ${explicit_s3_port})"
        fi
        printf '%s\n' "$explicit_s3_port"
        return
    fi

    if ! [[ "$default_api_port" =~ ^[0-9]+$ ]]; then
        die "PLAYWRIGHT_API_PORT must be numeric when used for S3 port derivation (got: ${default_api_port})"
    fi

    printf '%s\n' "$((default_api_port + 1))"
}

resolve_s3_listen_port() {
    local default_s3_port
    default_s3_port="$(resolve_default_s3_port)"
    resolve_port_from_addr "${S3_LISTEN_ADDR:-0.0.0.0:${default_s3_port}}" "S3_LISTEN_ADDR"
}

# Force one key from an env file into the current process when present.
# This keeps live Stripe key selection anchored to .env.local in proof lanes.
read_env_file_assignment_for_key() {
    local env_file="$1"
    local key="$2"
    local line parse_status

    ENV_FILE_ASSIGNMENT_VALUE=""
    [ -f "$env_file" ] || return 1

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ]; then
            if [ "$ENV_ASSIGNMENT_KEY" = "$key" ]; then
                ENV_FILE_ASSIGNMENT_VALUE="$ENV_ASSIGNMENT_VALUE"
                return 0
            fi
            continue
        fi

        if [ "$parse_status" -eq 2 ]; then
            continue
        fi

        echo "ERROR: Unsupported syntax in ${env_file}; only KEY=value assignments are allowed" >&2
        exit 1
    done < "$env_file"

    return 1
}

prefer_env_file_assignment_for_key() {
    local env_file="$1"
    local key="$2"

    read_env_file_assignment_for_key "$env_file" "$key" || return 1
    printf -v "$key" '%s' "$ENV_FILE_ASSIGNMENT_VALUE"
    export "$key"
    return 0
}

# Keep Stripe secret-key resolution anchored to .env.local even when the file
# only defines STRIPE_TEST_SECRET_KEY and the parent shell already exports a
# stale STRIPE_SECRET_KEY that would otherwise win inside resolve_stripe_secret_key.
prefer_env_file_live_stripe_secret_selection() {
    local env_file="$1"
    local secret_present=1
    local test_secret_present=1
    local any_file_secret_assignment_present=0
    local secret_value=""
    local test_secret_value=""

    if read_env_file_assignment_for_key "$env_file" "STRIPE_SECRET_KEY"; then
        any_file_secret_assignment_present=1
        secret_value="$ENV_FILE_ASSIGNMENT_VALUE"
    else
        secret_present=0
    fi

    if read_env_file_assignment_for_key "$env_file" "STRIPE_TEST_SECRET_KEY"; then
        any_file_secret_assignment_present=1
        test_secret_value="$ENV_FILE_ASSIGNMENT_VALUE"
    else
        test_secret_present=0
    fi

    # When the env file mentions either Stripe secret-key slot, clear both
    # inherited values first so an explicit blank assignment fails closed
    # instead of silently reusing a parent-shell secret.
    if [ "$any_file_secret_assignment_present" -eq 1 ]; then
        unset STRIPE_SECRET_KEY
        unset STRIPE_TEST_SECRET_KEY
    fi

    if [ "$secret_present" -eq 1 ] && [ -n "$secret_value" ]; then
        export STRIPE_SECRET_KEY="$secret_value"
    fi

    if [ "$test_secret_present" -eq 1 ] && [ -n "$test_secret_value" ]; then
        export STRIPE_TEST_SECRET_KEY="$test_secret_value"
    fi
}

caller_stripe_publishable_key_present=0
if [ "${STRIPE_PUBLISHABLE_KEY+x}" = "x" ]; then
    caller_stripe_publishable_key_present=1
fi

# The API treats SES_FROM_ADDRESS, SES_REGION, and SES_CONFIGURATION_SET as one
# startup family (infra/api/src/startup_env.rs::ses_family_state): any member
# left set forces SesStartupMode::Ses, so local Mailpit lanes must clear all
# three rather than just the credential pair.
SES_ROUTING_ENV_KEYS=(SES_FROM_ADDRESS SES_REGION SES_CONFIGURATION_SET)
LOCAL_EMAIL_DELIVERY_ENVIRONMENT_VALUES=(local dev development)

clear_ses_routing_env() {
    local key
    for key in "${SES_ROUTING_ENV_KEYS[@]}"; do
        unset "$key"
    done
}

require_or_default_local_email_delivery_startup_mode() {
    local normalized_environment normalized_node_secret_backend allowed_environment=0
    local environment_value

    if [ -z "${ENVIRONMENT:-}" ]; then
        export ENVIRONMENT="local"
    fi
    if [ -z "${NODE_SECRET_BACKEND:-}" ]; then
        export NODE_SECRET_BACKEND="memory"
    fi

    normalized_environment="$(printf '%s' "$ENVIRONMENT" | tr '[:upper:]' '[:lower:]' | xargs)"
    normalized_node_secret_backend="$(printf '%s' "$NODE_SECRET_BACKEND" | tr '[:upper:]' '[:lower:]' | xargs)"

    for environment_value in "${LOCAL_EMAIL_DELIVERY_ENVIRONMENT_VALUES[@]}"; do
        if [ "$normalized_environment" = "$environment_value" ]; then
            allowed_environment=1
            break
        fi
    done

    if [ "$allowed_environment" -ne 1 ] || [ "$normalized_node_secret_backend" != "memory" ]; then
        die "API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 requires ENVIRONMENT=local/dev/development and NODE_SECRET_BACKEND=memory so API startup selects Mailpit instead of SES"
    fi
}

require_loopback_http_mailpit_api_url() {
    local mailpit_api_url="$1"

    if ! loopback_http_url_is_valid "$mailpit_api_url"; then
        die "API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 needs a loopback HTTP MAILPIT_API_URL so verification email stays in the local Mailpit inbox"
    fi
}

# Captured before .env.local loads so an env file cannot switch the fail-closed
# local-delivery contract back off after the caller demanded it.
caller_requires_local_email_delivery="${API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY:-0}"

if [ -f "$REPO_ROOT/.env.local" ]; then
    load_env_file "$REPO_ROOT/.env.local"
    if [ "${API_DEV_ALLOW_LIVE_STRIPE:-}" = "1" ]; then
        prefer_env_file_live_stripe_secret_selection "$REPO_ROOT/.env.local"
        if [ "$caller_stripe_publishable_key_present" -ne 1 ]; then
            prefer_env_file_assignment_for_key "$REPO_ROOT/.env.local" "STRIPE_PUBLISHABLE_KEY" || true
        fi
        prefer_env_file_assignment_for_key "$REPO_ROOT/.env.local" "STRIPE_WEBHOOK_SECRET" || true
    fi
fi

requires_local_email_delivery="${API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY:-0}"
if [ "$caller_requires_local_email_delivery" = "1" ]; then
    requires_local_email_delivery=1
fi

# Fail-closed local-delivery mode for browser proofs that must redeem a real
# verification token out of Mailpit. Both escape hatches below are honored from
# .env.local as well as the parent shell, so this mode revokes them AFTER the
# env file has loaded — revoking them earlier would let a stale env file reinstate
# auto-verification or SES routing and send the proof email outside the local stack.
if [ "$requires_local_email_delivery" = "1" ]; then
    [ -n "${MAILPIT_API_URL:-}" ] \
        || die "API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1 needs MAILPIT_API_URL so verification email stays in the local Mailpit inbox"
    require_loopback_http_mailpit_api_url "$MAILPIT_API_URL"
    require_or_default_local_email_delivery_startup_mode
    unset API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION
    unset API_DEV_ALLOW_SES_EMAIL
fi

listen_port="$(resolve_listen_port)"
s3_listen_port="$(resolve_s3_listen_port)"
default_s3_port="$(resolve_default_s3_port)"
if [ -z "${S3_LISTEN_ADDR:-}" ]; then
    export S3_LISTEN_ADDR="0.0.0.0:${default_s3_port}"
fi
check_port_available "$listen_port" "api LISTEN_ADDR" \
    || die "port $listen_port is already in use (needed for api LISTEN_ADDR ${LISTEN_ADDR:-0.0.0.0:${PLAYWRIGHT_API_PORT:-3001}})"
check_port_available "$s3_listen_port" "api S3_LISTEN_ADDR" \
    || die "port $s3_listen_port is already in use (needed for api S3_LISTEN_ADDR ${S3_LISTEN_ADDR:-0.0.0.0:${default_s3_port}})"

# Stage-proof defaults: verification lanes require real token delivery.
# Opt back in for demo-only quickstart runs via API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1.
if [ "${API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION:-}" != "1" ]; then
    unset SKIP_EMAIL_VERIFICATION
fi

# Prefer Mailpit delivery for local browser-lane proofs when it is configured.
# Keep SES available behind explicit API_DEV_ALLOW_SES_EMAIL=1 opt-in.
if [ -n "${MAILPIT_API_URL:-}" ] && [ "${API_DEV_ALLOW_SES_EMAIL:-}" != "1" ]; then
    clear_ses_routing_env
fi

# Default local dev to the in-process Stripe mock so checkout-based fixture
# arrangement remains deterministic even when bootstrap injected live test keys.
# Explicit live-Stripe opt-in must also clear any inherited/local STRIPE_LOCAL_MODE=1
# so downstream billing code does not silently stay pinned to the mock path.
if [ "${API_DEV_ALLOW_LIVE_STRIPE:-}" = "1" ]; then
    unset STRIPE_LOCAL_MODE
    log "Validating live Stripe key before API launch"
    BACKEND_LIVE_GATE=1 check_stripe_key_present
    BACKEND_LIVE_GATE=1 check_stripe_key_live
    # Guard against a publishable/secret key MODE MISMATCH. check_stripe_key_live
    # above proves the SECRET key is sk_test_/rk_test_, but STRIPE_PUBLISHABLE_KEY
    # is anchored separately (from .env.local) and is served to the browser at
    # /api/stripe/publishable-key. Stripe.js rejects a test-mode SetupIntent
    # client secret when loaded with a pk_live_ key, so the Payment Element
    # silently fails to mount with NO server-side error — a trap that cost real
    # debugging time. Fail closed with an actionable message instead of shipping
    # a broken form. (Empty is allowed: a run may legitimately not set a pk yet.)
    if [ -n "${STRIPE_PUBLISHABLE_KEY:-}" ] && [[ "${STRIPE_PUBLISHABLE_KEY}" != pk_test_* ]]; then
        die "STRIPE_PUBLISHABLE_KEY mode mismatch: resolved publishable mode is non-test while resolved secret mode is test. live-Stripe dev mode requires a pk_test_ publishable key from the same Stripe sandbox as STRIPE_SECRET_KEY."
    fi
else
    export STRIPE_LOCAL_MODE="${STRIPE_LOCAL_MODE:-1}"
    if [ "${STRIPE_LOCAL_MODE}" = "1" ]; then
        unset STRIPE_SECRET_KEY
        unset STRIPE_TEST_SECRET_KEY
        unset STRIPE_PUBLISHABLE_KEY
        export STRIPE_WEBHOOK_SECRET="${STRIPE_WEBHOOK_SECRET:-whsec_local_dev_secret}"
    else
        # Explicit nonlocal mode without live-Stripe opt-in is the deterministic
        # unconfigured billing proof path. Clear env-file keys after loading so
        # the API does not accidentally construct a live Stripe client.
        unset STRIPE_SECRET_KEY
        unset STRIPE_TEST_SECRET_KEY
        unset STRIPE_PUBLISHABLE_KEY
        unset STRIPE_WEBHOOK_SECRET
    fi
fi

export FLAPJACK_ADMIN_KEY="${FLAPJACK_ADMIN_KEY:-$DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY}"
# Local Flapjack does not expose the internal replication API used by the
# production orchestrator. Keep the task effectively dormant unless a developer
# explicitly opts into testing replication behavior with a shorter interval.
export REPLICATION_CYCLE_INTERVAL_SECS="${REPLICATION_CYCLE_INTERVAL_SECS:-999999}"

api_pid_file="${API_DEV_PID_FILE:-$REPO_ROOT/.local/api.pid}"
mkdir -p "$(dirname "$api_pid_file")"
printf '%s\n' "$$" > "$api_pid_file"

cd "$REPO_ROOT"
exec cargo run --manifest-path infra/Cargo.toml -p api "$@"
