#!/usr/bin/env bash
# capture_billing_cross_check_inputs.sh — read-only Stage 1 billing replay bundle capture.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck source=../lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"
# shellcheck source=../lib/metering_checks.sh
source "$REPO_ROOT/scripts/lib/metering_checks.sh"
# shellcheck source=../lib/staging_billing_rehearsal_impl.sh
source "$REPO_ROOT/scripts/lib/staging_billing_rehearsal_impl.sh"
# shellcheck source=../lib/staging_billing_rehearsal_evidence.sh
source "$REPO_ROOT/scripts/lib/staging_billing_rehearsal_evidence.sh"

TARGET_ENV="staging"
INVOICE_ID=""
BUNDLE_DIR=""

print_usage() {
    cat <<'USAGE'
Usage:
  capture_billing_cross_check_inputs.sh --env <staging> --invoice-id <uuid> --bundle-dir <path>
  capture_billing_cross_check_inputs.sh --help
USAGE
}

require_option_value() {
    local option_name="$1"
    local option_value="${2-}"
    if [ -z "$option_value" ] || [[ "$option_value" == --* ]]; then
        echo "ERROR: Missing value for ${option_name}" >&2
        exit 2
    fi
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --env)
                require_option_value "--env" "${2-}"
                TARGET_ENV="$2"
                shift 2
                ;;
            --env=*)
                TARGET_ENV="${1#--env=}"
                shift
                ;;
            --invoice-id)
                require_option_value "--invoice-id" "${2-}"
                INVOICE_ID="$2"
                shift 2
                ;;
            --invoice-id=*)
                INVOICE_ID="${1#--invoice-id=}"
                shift
                ;;
            --bundle-dir)
                require_option_value "--bundle-dir" "${2-}"
                BUNDLE_DIR="$2"
                shift 2
                ;;
            --bundle-dir=*)
                BUNDLE_DIR="${1#--bundle-dir=}"
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                echo "ERROR: Unknown argument: $1" >&2
                print_usage >&2
                exit 2
                ;;
        esac
    done
}

require_nonempty() {
    local value="$1"
    local label="$2"
    if [ -z "$value" ]; then
        echo "ERROR: Missing required argument: ${label}" >&2
        exit 2
    fi
}

validate_inputs() {
    require_nonempty "$TARGET_ENV" "--env"
    require_nonempty "$INVOICE_ID" "--invoice-id"
    require_nonempty "$BUNDLE_DIR" "--bundle-dir"
    if ! [[ "$INVOICE_ID" =~ ^[0-9a-fA-F-]{36}$ ]]; then
        echo "ERROR: --invoice-id must look like a UUID" >&2
        exit 2
    fi
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ] || [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]; then
        echo "ERROR: AWS credentials must already be loaded in the operator environment." >&2
        exit 2
    fi
}

hydrate_database_url_from_ssm() {
    local hydrate_output hydrate_file
    local line parse_status hydrated_database_url=""

    hydrate_output="$(bash "$REPO_ROOT/scripts/launch/hydrate_seeder_env_from_ssm.sh" "$TARGET_ENV")"
    hydrate_file="$(mktemp)"
    printf '%s\n' "$hydrate_output" > "$hydrate_file"

    while IFS= read -r line || [ -n "$line" ]; do
        parse_env_assignment_line "$line" && parse_status=0 || parse_status=$?
        if [ "$parse_status" -eq 0 ] && [ "$ENV_ASSIGNMENT_KEY" = "DATABASE_URL" ]; then
            hydrated_database_url="$ENV_ASSIGNMENT_VALUE"
            break
        fi
    done < "$hydrate_file"

    load_env_file "$hydrate_file"
    rm -f "$hydrate_file"

    if [ -z "$hydrated_database_url" ]; then
        echo "ERROR: hydrate_seeder_env_from_ssm.sh did not provide DATABASE_URL." >&2
        exit 1
    fi

    # Force the hydrated staging DB URL for this capture path, even when the
    # operator shell already exported DATABASE_URL or INTEGRATION_DB_URL.
    DATABASE_URL="$hydrated_database_url"
    INTEGRATION_DB_URL="$hydrated_database_url"
    export DATABASE_URL INTEGRATION_DB_URL
}

main() {
    umask 077
    parse_args "$@"
    validate_inputs
    hydrate_database_url_from_ssm

    ensure_psql_on_path || true
    if ! command -v psql >/dev/null 2>&1; then
        echo "ERROR: psql not found on PATH after sourcing scripts/lib/psql_path.sh." >&2
        exit 1
    fi

    if capture_billing_cross_check_inputs "$INVOICE_ID" "$BUNDLE_DIR"; then
        printf '{"result":"passed","classification":"%s","detail":"%s","invoice_id":"%s","bundle_dir":"%s"}\n' \
            "$EVIDENCE_LAST_CLASSIFICATION" \
            "$EVIDENCE_LAST_DETAIL" \
            "$INVOICE_ID" \
            "$BUNDLE_DIR"
        exit 0
    fi

    printf '{"result":"failed","classification":"%s","detail":"%s","invoice_id":"%s","bundle_dir":"%s"}\n' \
        "${EVIDENCE_LAST_CLASSIFICATION:-capture_failed}" \
        "${EVIDENCE_LAST_DETAIL:-cross-check capture failed.}" \
        "$INVOICE_ID" \
        "$BUNDLE_DIR" >&2
    exit 1
}

main "$@"
