#!/usr/bin/env bash
# staging_billing_dry_run.sh — safe staging billing preflight / rehearsal entrypoint.
#
# This script intentionally stays small and orchestration-focused. It does not
# introduce a second billing implementation. Instead, it validates the staging
# configuration required for a future metering -> aggregation -> invoice ->
# Stripe webhook rehearsal, then emits machine-readable status so later sessions
# can tell the difference between "ready", "missing config", and
# "Cloudflare/DNS still blocks public webhook delivery".
#
# Important contract note: the API runtime itself reads STRIPE_SECRET_KEY,
# not STRIPE_TEST_SECRET_KEY. This preflight therefore validates the runtime
# variable that the staging API actually needs for live Stripe wiring while
# still rejecting live-mode keys.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/validation_json.sh
source "$SCRIPT_DIR/lib/validation_json.sh"
# shellcheck source=lib/billing_rehearsal_steps.sh
source "$SCRIPT_DIR/lib/billing_rehearsal_steps.sh"

append_step() { validation_append_step "$@"; }

MODE="check"
ENV_FILES=()

print_usage() {
    cat <<'USAGE' >&2
Usage:
  staging_billing_dry_run.sh [--check|--run] [--env-file <path>]
  staging_billing_dry_run.sh --help

Modes:
  --check    Validate config only. Does not call external services.
  --run      Validate config, then perform a non-mutating API health probe.
USAGE
}

# Centralized result emission keeps the JSON schema stable for tests and
# runbooks. The caller passes the final boolean and first failure classification.
emit_preflight_result() {
    local passed="$1"
    local classification="$2"
    local planned_steps_json elapsed_ms classification_json

    planned_steps_json="$(billing_rehearsal_planned_steps_json)"

    elapsed_ms=$(( $(validation_ms_now) - VALIDATION_START_MS ))
    classification_json="$(validation_json_escape "$classification")"

    printf '{"passed":%s,"mode":"%s","classification":%s,"planned_steps":%s,"steps":[%s],"elapsed_ms":%s}\n' \
        "$passed" "$MODE" "$classification_json" "$planned_steps_json" "$VALIDATION_STEPS_JSON" "$elapsed_ms"
}

# The helper records the first classification as the headline blocker while
# still capturing every failed step in the JSON payload.
FIRST_FAILURE_CLASSIFICATION=""
HAS_FAILURES=0

record_failure() {
    local step_name="$1"
    local detail="$2"
    local classification="$3"

    append_step "$step_name" false "$detail"
    HAS_FAILURES=1
    if [ -z "$FIRST_FAILURE_CLASSIFICATION" ]; then
        FIRST_FAILURE_CLASSIFICATION="$classification"
    fi
}

record_success() {
    local step_name="$1"
    local detail="$2"
    append_step "$step_name" true "$detail"
}

require_nonempty_env() {
    local env_name="$1"
    local step_name="$2"
    local classification="$3"

    if [ -z "${!env_name:-}" ]; then
        record_failure "$step_name" "${env_name} is required" "$classification"
        return 1
    fi

    record_success "$step_name" "${env_name} is set"
    return 0
}

is_absolute_http_url() {
    local url="$1"
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]]
}

validate_staging_api_url() {
    if ! require_nonempty_env "STAGING_API_URL" "staging_api_url_present" "staging_api_url_missing"; then
        return 0
    fi

    if ! is_absolute_http_url "$STAGING_API_URL"; then
        record_failure \
            "staging_api_url_format" \
            "STAGING_API_URL must be an absolute http(s) URL without whitespace" \
            "staging_api_url_invalid"
        return 0
    fi

    record_success "staging_api_url_format" "STAGING_API_URL is a valid absolute URL"
}

validate_public_webhook_url() {
    if ! require_nonempty_env "STAGING_STRIPE_WEBHOOK_URL" "staging_webhook_url_present" "dns_or_cloudflare_blocked"; then
        return 0
    fi

    if [[ "$STAGING_STRIPE_WEBHOOK_URL" != https://* ]]; then
        record_failure \
            "staging_webhook_url_https" \
            "STAGING_STRIPE_WEBHOOK_URL must use https:// so Stripe can reach a public webhook endpoint" \
            "dns_or_cloudflare_blocked"
        return 0
    fi

    if [[ "$STAGING_STRIPE_WEBHOOK_URL" != */webhooks/stripe ]]; then
        record_failure \
            "staging_webhook_url_path" \
            "STAGING_STRIPE_WEBHOOK_URL should target the /webhooks/stripe route" \
            "staging_webhook_url_invalid"
        return 0
    fi

    record_success "staging_webhook_url_https" "Public Stripe webhook URL uses HTTPS"
    record_success "staging_webhook_url_path" "Public Stripe webhook URL targets /webhooks/stripe"
}

validate_runtime_stripe_key() {
    if ! require_nonempty_env "STRIPE_SECRET_KEY" "stripe_secret_key_present" "stripe_secret_key_missing"; then
        return 0
    fi

    # Reject live keys loudly so the runner cannot be pointed at real money flow.
    if [[ "$STRIPE_SECRET_KEY" == sk_live_* ]]; then
        record_failure \
            "stripe_secret_key_mode" \
            "STRIPE_SECRET_KEY must use an sk_test_ key; sk_live_ keys are not allowed for this dry run" \
            "stripe_live_key_rejected"
        return 0
    fi

    if [[ "$STRIPE_SECRET_KEY" != sk_test_* ]]; then
        record_failure \
            "stripe_secret_key_prefix" \
            "STRIPE_SECRET_KEY must start with sk_test_" \
            "stripe_secret_key_invalid"
        return 0
    fi

    record_success "stripe_secret_key_mode" "Stripe runtime key is explicitly test-mode"
}

validate_webhook_secret() {
    if ! require_nonempty_env "STRIPE_WEBHOOK_SECRET" "stripe_webhook_secret_present" "stripe_webhook_secret_missing"; then
        return 0
    fi

    if [[ "$STRIPE_WEBHOOK_SECRET" != whsec_* ]]; then
        record_failure \
            "stripe_webhook_secret_prefix" \
            "STRIPE_WEBHOOK_SECRET must start with whsec_" \
            "stripe_webhook_secret_invalid"
        return 0
    fi

    record_success "stripe_webhook_secret_prefix" "Webhook signing secret uses the expected Stripe prefix"
}

validate_operator_auth_path() {
    # The later credentialed rehearsal needs one operator-controlled path to
    # inspect or drive the pipeline. We accept either API admin auth or direct
    # DB access because different staging sessions may use different evidence
    # collection paths.
    if [ -n "${ADMIN_KEY:-}" ] || [ -n "${DATABASE_URL:-}" ] || [ -n "${INTEGRATION_DB_URL:-}" ]; then
        record_success \
            "operator_auth_path_present" \
            "At least one operator path is configured (ADMIN_KEY or DATABASE_URL / INTEGRATION_DB_URL)"
        return 0
    fi

    record_failure \
        "operator_auth_path_present" \
        "Set ADMIN_KEY or DATABASE_URL / INTEGRATION_DB_URL so the staging rehearsal has an authenticated inspection path" \
        "operator_auth_missing"
}

run_non_mutating_health_probe() {
    local health_url="${STAGING_API_URL%/}/health"

    # `--run` is still intentionally safe. The only live call is a GET health
    # probe so operators can tell the difference between "config ready" and
    # "staging endpoint still unreachable".
    if curl -fsS "$health_url" >/dev/null 2>&1; then
        record_success "staging_api_health" "API responded at ${health_url}"
        return 0
    fi

    record_failure \
        "staging_api_health" \
        "API health probe failed at ${health_url}" \
        "staging_api_unreachable"
    return 0
}

load_explicit_env_files() {
    # This script intentionally does not read repo-local .env.local files.
    # Staging preflight must only trust explicitly supplied env files or the
    # caller's shell exports; otherwise a developer's local-dev credentials can
    # make staging checks pass for the wrong reasons.
    if [ "${#ENV_FILES[@]}" -gt 0 ]; then
        load_layered_env_files "${ENV_FILES[@]}"
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --check)
                MODE="check"
                shift
                ;;
            --run)
                MODE="run"
                shift
                ;;
            --env-file)
                [ "$#" -ge 2 ] || { echo "ERROR: --env-file requires a path" >&2; exit 2; }
                ENV_FILES+=("$2")
                shift 2
                ;;
            --env-file=*)
                ENV_FILES+=("${1#--env-file=}")
                shift
                ;;
            --help)
                print_usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                print_usage
                exit 2
                ;;
        esac
    done
}

main() {
    parse_args "$@"
    load_explicit_env_files

    validate_staging_api_url
    validate_public_webhook_url
    validate_runtime_stripe_key
    validate_webhook_secret
    validate_operator_auth_path

    if [ "$MODE" = "check" ] && [ "$HAS_FAILURES" -eq 0 ]; then
        record_success \
            "preflight_plan_ready" \
            "Configuration is ready for staged metering -> aggregation -> invoice -> Stripe test webhook -> email rehearsal"
    fi

    if [ "$MODE" = "run" ] && [ "$HAS_FAILURES" -eq 0 ]; then
        run_non_mutating_health_probe
    fi

    if [ "$HAS_FAILURES" -eq 0 ]; then
        emit_preflight_result true "ready"
        exit 0
    fi

    emit_preflight_result false "$FIRST_FAILURE_CLASSIFICATION"
    exit 1
}

main "$@"
