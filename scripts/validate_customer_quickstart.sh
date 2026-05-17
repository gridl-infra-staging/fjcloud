#!/usr/bin/env bash
# Validate customer quickstart contracts across staging/prod modes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/env.sh"

EXIT_USAGE=2
EXIT_RUNTIME=1

QUICKSTART_MODE=""
QUICKSTART_CONTRACT_ONLY=0

print_usage() {
    cat <<'USAGE'
Usage: validate_customer_quickstart.sh <staging|prod> [--contract-only]

Modes:
  staging              Run full quickstart validation flow.
  prod                 Run full quickstart validation flow.
  prod --contract-only Run non-destructive contract probes only.

Notes:
  --contract-only is only valid with prod mode.
USAGE
}

die_usage() {
    echo "ERROR: $*" >&2
    print_usage >&2
    exit "$EXIT_USAGE"
}

log() {
    echo "[validate_customer_quickstart] $*"
}

load_validator_env() {
    local default_secret_file="$REPO_ROOT/.secret/.env.secret"
    local secret_file="${FJCLOUD_SECRET_FILE:-$default_secret_file}"

    # Keep local/dev behavior aligned with the secret-source precedence contract:
    # explicit FJCLOUD_SECRET_FILE override first, then repo-local default path.
    load_env_file "$secret_file"

    export API_URL="${API_URL:-}"
}

resolve_scripts_root() {
    if [ -n "${QUICKSTART_STUB_ROOT:-}" ]; then
        if [ "${QUICKSTART_ALLOW_STUB_ROOT:-0}" != "1" ]; then
            echo "ERROR: QUICKSTART_STUB_ROOT is test-only; set QUICKSTART_ALLOW_STUB_ROOT=1 to enable stubbed script ownership" >&2
            return 1
        fi
        printf '%s/scripts\n' "$QUICKSTART_STUB_ROOT"
    else
        printf '%s/scripts\n' "$REPO_ROOT"
    fi
}

curl_http_code() {
    local method="$1"
    local url="$2"

    curl -sS -o /dev/null -w '%{http_code}' -X "$method" "$url" 2>/dev/null || printf '000'
}

probe_success_endpoint() {
    local path="$1"
    local code

    code="$(curl_http_code GET "${API_URL}${path}")"
    if [[ "$code" =~ ^[23][0-9][0-9]$ ]]; then
        log "probe succeeded: GET ${path} (http=${code})"
        return 0
    fi

    echo "ERROR: expected success for ${path}, got HTTP ${code}" >&2
    return 1
}

probe_endpoint_reachability() {
    local method="$1"
    local path="$2"
    local code

    code="$(curl_http_code "$method" "${API_URL}${path}")"
    if [ "$code" = "000" ]; then
        echo "ERROR: endpoint unreachable (transport failure) for ${method} ${path}" >&2
        return 1
    fi

    # Reachability probes validate that routes exist without assuming request validity.
    # 404 means route is absent; 5xx means app-level failure. Other statuses (e.g. 405)
    # still prove the endpoint is present.
    if [ "$code" = "404" ] || [[ "$code" =~ ^5[0-9][0-9]$ ]]; then
        echo "ERROR: endpoint returned HTTP ${code} for ${method} ${path}" >&2
        return 1
    fi

    log "probe reachable: ${method} ${path} (http=${code})"
    return 0
}

parse_args() {
    if [ "$#" -lt 1 ]; then
        die_usage "missing mode argument"
    fi

    QUICKSTART_MODE="$1"
    shift

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --contract-only)
                QUICKSTART_CONTRACT_ONLY=1
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                die_usage "unknown argument: $1"
                ;;
        esac
        shift
    done

    if [ "$QUICKSTART_MODE" != "staging" ] && [ "$QUICKSTART_MODE" != "prod" ]; then
        die_usage "mode must be staging or prod"
    fi

    if [ "$QUICKSTART_CONTRACT_ONLY" -eq 1 ] && [ "$QUICKSTART_MODE" != "prod" ]; then
        die_usage "--contract-only is only supported for prod mode"
    fi
}

validate_full_flow_prereqs() {
    local missing=()

    if [ -z "${API_URL:-}" ]; then
        missing+=("API_URL")
    fi

    for key in \
        SES_FROM_ADDRESS \
        SES_REGION \
        INBOUND_ROUNDTRIP_S3_URI \
        INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN; do
        if [ -z "${!key:-}" ]; then
            missing+=("$key")
        fi
    done

    # The reused customer-loop owner requires ADMIN_KEY for admin cleanup.
    # Either ADMIN_KEY or FLAPJACK_ADMIN_KEY satisfies the requirement.
    if [ -z "${ADMIN_KEY:-}" ] && [ -z "${FLAPJACK_ADMIN_KEY:-}" ]; then
        missing+=("ADMIN_KEY")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "ERROR: full-flow mode requires these env vars: ${missing[*]}" >&2
        echo "ERROR: use 'prod --contract-only' for non-destructive contract probes when full-flow prerequisites are unavailable" >&2
        return 1
    fi

    return 0
}

run_contract_only_probes() {
    local failures=0

    probe_success_endpoint "/health" || failures=$((failures + 1))
    probe_success_endpoint "/docs" || failures=$((failures + 1))

    probe_endpoint_reachability OPTIONS "/auth/register" || failures=$((failures + 1))
    probe_endpoint_reachability OPTIONS "/auth/verify-email" || failures=$((failures + 1))
    probe_endpoint_reachability OPTIONS "/indexes/contract-check/search" || failures=$((failures + 1))

    if [ "$failures" -gt 0 ]; then
        echo "ERROR: ${failures} contract probe(s) failed" >&2
        return 1
    fi

    log "prod --contract-only completed non-destructive contract checks; full-flow coverage intentionally skipped"
}

run_inbound_roundtrip() {
    local scripts_root="$1"
    local roundtrip_script="$scripts_root/validate_inbound_email_roundtrip.sh"

    if [ ! -f "$roundtrip_script" ]; then
        echo "ERROR: missing roundtrip validator at $roundtrip_script" >&2
        return 1
    fi

    bash "$roundtrip_script"
}

run_signup_verify_search_flow() {
    local scripts_root="$1"
    local customer_loop_script="$scripts_root/canary/customer_loop_synthetic.sh"
    local flow_rc=0

    if [ ! -f "$customer_loop_script" ]; then
        echo "ERROR: missing customer loop owner at $customer_loop_script" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$customer_loop_script"

    load_canary_env
    # Bridge the validated roundtrip inbox contract into the reused canary owner
    # so roundtrip polling and verify-email read the same inbox target.
    CANARY_TEST_INBOX_DOMAIN="$INBOUND_ROUNDTRIP_RECIPIENT_DOMAIN"
    CANARY_TEST_INBOX_S3_URI="$INBOUND_ROUNDTRIP_S3_URI"
    export CANARY_TEST_INBOX_DOMAIN CANARY_TEST_INBOX_S3_URI
    CANARY_LIVE_MODE="0"
    export CANARY_LIVE_MODE

    run_customer_loop || flow_rc=$?
    cleanup_after_flow || true

    if [ "$flow_rc" -ne 0 ]; then
        echo "ERROR: customer quickstart flow failed at step '${FLOW_FAILURE_STEP:-unknown}': ${FLOW_FAILURE_DETAIL:-no detail}" >&2
        return 1
    fi

    log "customer quickstart signup/verify/search flow succeeded"
}

main() {
    local scripts_root

    parse_args "$@"
    load_validator_env
    scripts_root="$(resolve_scripts_root)" || exit "$EXIT_USAGE"

    if [ "$QUICKSTART_MODE" = "prod" ] && [ "$QUICKSTART_CONTRACT_ONLY" -eq 1 ]; then
        run_contract_only_probes || exit "$EXIT_RUNTIME"
        exit 0
    fi

    if ! validate_full_flow_prereqs; then
        exit "$EXIT_USAGE"
    fi

    run_inbound_roundtrip "$scripts_root" || exit "$EXIT_RUNTIME"
    run_signup_verify_search_flow "$scripts_root" || exit "$EXIT_RUNTIME"

    log "${QUICKSTART_MODE} full-flow validation passed"
}

main "$@"
