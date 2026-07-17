#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/rc_invocation.sh
source "$REPO_ROOT/scripts/lib/rc_invocation.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/aws_identity.sh
source "$REPO_ROOT/scripts/lib/aws_identity.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/hydrate_staging_env.sh
source "$REPO_ROOT/scripts/lib/hydrate_staging_env.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/web_runtime.sh
source "$REPO_ROOT/scripts/lib/web_runtime.sh"

DEFAULT_CREDENTIAL_ENV_FILE="${HOME:-}/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret"
COORDINATOR_RELATIVE_PATH="scripts/launch/run_full_backend_validation.sh"
COORDINATOR_PATH="$REPO_ROOT/$COORDINATOR_RELATIVE_PATH"

DRY_RUN=0
CLASSIFY_EXISTING=0
VALIDATE_EXISTING=0
BILLING_PREFLIGHT_CHECK=0
SHA=""
ARTIFACT_DIR=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_API_AMI_ID=""
STAGING_SMOKE_FLAPJACK_AMI_ID=""
ONLY_STEPS=""
SUMMARY_PATH=""
VERDICT_OUTPUT=""
VERDICT_PATH=""
RUN_RECEIPT=""
VALIDATION_OUTPUT=""
BILLING_INPUT_MANIFEST=""
SECTION1_MANIFEST=""
COORDINATOR_ARGS=()

print_usage() {
    cat <<'USAGE'
Usage:
  invoke_rc_with_env.sh [--dry-run] --sha=<GIT_SHA> --artifact-dir=<dir> [options] [--staging-only]
  invoke_rc_with_env.sh --classify-existing --summary=<summary.json> [--verdict-output=<verdict.json>]
  invoke_rc_with_env.sh --help

Options:
  --dry-run                      Print the delegated paid-beta RC command without running it
  --billing-preflight-check      Run wrapper-prepared staging billing dry-run preflight only
  --classify-existing            Generate verdict.json from an existing RC summary.json without rerunning probes
  --validate-existing            Validate an existing RC run receipt without rerunning probes
  --summary=<summary.json>       Existing RC summary.json to classify
  --verdict-output=<verdict.json>
                                 Output verdict path (default: sibling verdict.json)
  --verdict=<verdict.json>       Existing canonical verdict to validate
  --run-receipt=<path>           Existing rc_run_receipt.json to validate
  --validation-output=<validation.json>
                                 Output closeout validation receipt path
  --sha=<GIT_SHA>                Commit SHA to validate
  --artifact-dir=<dir>           Artifact directory for delegated RC evidence outputs
  --credential-env-file=<path>   Credentials env file (KEY=value) used by delegated proof inputs
  --billing-month=<YYYY-MM>      Billing month for RC staging billing rehearsal
  --section1-manifest=<path>     Complete §1 in-VPC runner manifest to bind RC classification
  --staging-smoke-api-ami-id=<ami-id>
                                 API instance AMI for RC staging runtime smoke proof
  --staging-smoke-flapjack-ami-id=<ami-id>
                                 Flapjack runtime-pointer AMI for RC staging runtime smoke proof
  --only-steps=<csv>             Forward a comma-separated paid-beta RC step filter to the coordinator
  --input-manifest=<path>        Sanitized billing-preflight argv/env status manifest
  --staging-only                 Forward staging-only RC sub-mode to the coordinator
  --help                         Show this help text
USAGE
}

parse_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help)
                print_usage
                exit 0
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --billing-preflight-check)
                BILLING_PREFLIGHT_CHECK=1
                ;;
            --classify-existing)
                CLASSIFY_EXISTING=1
                ;;
            --validate-existing)
                VALIDATE_EXISTING=1
                ;;
            --summary=*)
                SUMMARY_PATH="${arg#--summary=}"
                ;;
            --verdict-output=*)
                VERDICT_OUTPUT="${arg#--verdict-output=}"
                ;;
            --verdict=*)
                VERDICT_PATH="${arg#--verdict=}"
                ;;
            --run-receipt=*)
                RUN_RECEIPT="${arg#--run-receipt=}"
                ;;
            --validation-output=*)
                VALIDATION_OUTPUT="${arg#--validation-output=}"
                ;;
            --sha=*)
                SHA="${arg#--sha=}"
                ;;
            --artifact-dir=*)
                ARTIFACT_DIR="${arg#--artifact-dir=}"
                ;;
            --credential-env-file=*)
                CREDENTIAL_ENV_FILE="${arg#--credential-env-file=}"
                ;;
            --billing-month=*)
                BILLING_MONTH="${arg#--billing-month=}"
                ;;
            --section1-manifest=*)
                SECTION1_MANIFEST="${arg#--section1-manifest=}"
                ;;
            --staging-smoke-api-ami-id=*)
                STAGING_SMOKE_API_AMI_ID="${arg#--staging-smoke-api-ami-id=}"
                ;;
            --staging-smoke-flapjack-ami-id=*)
                STAGING_SMOKE_FLAPJACK_AMI_ID="${arg#--staging-smoke-flapjack-ami-id=}"
                ;;
            --staging-smoke-ami-id=*)
                echo "ERROR: --staging-smoke-ami-id was removed; pass --staging-smoke-api-ami-id and --staging-smoke-flapjack-ami-id" >&2
                exit 2
                ;;
            --only-steps=*)
                ONLY_STEPS="${arg#--only-steps=}"
                ;;
            --input-manifest=*)
                BILLING_INPUT_MANIFEST="${arg#--input-manifest=}"
                ;;
            --staging-only)
                COORDINATOR_ARGS+=("$arg")
                ;;
            --env-file=*)
                echo "ERROR: unknown argument '$arg'; use --credential-env-file=<path>" >&2
                exit 2
                ;;
            --*)
                echo "ERROR: unknown argument '$arg'" >&2
                exit 2
                ;;
            *)
                echo "ERROR: unexpected positional argument '$arg'" >&2
                exit 2
                ;;
        esac
    done
}

validate_classify_existing_inputs() {
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "ERROR: --dry-run cannot be combined with --classify-existing" >&2
        exit 2
    fi
    if [ -z "$SUMMARY_PATH" ]; then
        echo "ERROR: missing required argument: --summary=<summary.json>" >&2
        exit 2
    fi
    if [ ! -f "$SUMMARY_PATH" ] || [ ! -r "$SUMMARY_PATH" ]; then
        echo "ERROR: summary is not readable: $SUMMARY_PATH" >&2
        exit 1
    fi
    if [ -z "$VERDICT_OUTPUT" ]; then
        VERDICT_OUTPUT="$(dirname "$SUMMARY_PATH")/verdict.json"
    fi
    if [ -n "$SECTION1_MANIFEST" ]; then
        if [ -z "$SHA" ]; then
            echo "ERROR: --section1-manifest with --classify-existing requires --sha=<GIT_SHA>" >&2
            exit 2
        fi
        if ! rc_is_valid_sha "$SHA"; then
            echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
            exit 2
        fi
        if [ -z "$BILLING_MONTH" ]; then
            echo "ERROR: --section1-manifest with --classify-existing requires --billing-month=<YYYY-MM>" >&2
            exit 2
        fi
        if ! rc_is_valid_billing_month "$BILLING_MONTH"; then
            echo "ERROR: --billing-month must use YYYY-MM format with month 01-12" >&2
            exit 2
        fi
        if [ -z "$ARTIFACT_DIR" ]; then
            echo "ERROR: --section1-manifest with --classify-existing requires --artifact-dir=<dir>" >&2
            exit 2
        fi
        if ! rc_validate_section1_manifest "$SECTION1_MANIFEST" "$SHA" "$BILLING_MONTH" "$ARTIFACT_DIR"; then
            exit 1
        fi
    fi
}

validate_existing_receipt_inputs() {
    if [ "$DRY_RUN" -eq 1 ] || [ "$CLASSIFY_EXISTING" -eq 1 ]; then
        echo "ERROR: --validate-existing cannot be combined with --dry-run or --classify-existing" >&2
        exit 2
    fi
    if [ -z "$RUN_RECEIPT" ]; then
        echo "ERROR: missing required argument: --run-receipt=<path>" >&2
        exit 2
    fi
    if [ ! -f "$RUN_RECEIPT" ] || [ ! -r "$RUN_RECEIPT" ]; then
        echo "ERROR: run receipt is not readable: $RUN_RECEIPT" >&2
        exit 1
    fi
    if [ -z "$SHA" ] || ! rc_is_valid_sha "$SHA"; then
        echo "ERROR: --validate-existing requires --sha=<GIT_SHA>" >&2
        exit 2
    fi
    if [ -z "$BILLING_MONTH" ] || ! rc_is_valid_billing_month "$BILLING_MONTH"; then
        echo "ERROR: --validate-existing requires --billing-month=<YYYY-MM>" >&2
        exit 2
    fi
    if [ -z "$SECTION1_MANIFEST" ]; then
        echo "ERROR: --validate-existing requires --section1-manifest=<path>" >&2
        exit 2
    fi
    if [ ! -f "$SECTION1_MANIFEST" ] || [ ! -r "$SECTION1_MANIFEST" ]; then
        echo "ERROR: section1 manifest is not readable: $SECTION1_MANIFEST" >&2
        exit 1
    fi
    if [ -n "$SUMMARY_PATH" ] && { [ ! -f "$SUMMARY_PATH" ] || [ ! -r "$SUMMARY_PATH" ]; }; then
        echo "ERROR: summary is not readable: $SUMMARY_PATH" >&2
        exit 1
    fi
    if [ -n "$VERDICT_PATH" ] || [ -n "$VALIDATION_OUTPUT" ]; then
        if [ -z "$SUMMARY_PATH" ]; then
            echo "ERROR: validation receipt output requires --summary=<summary.json>" >&2
            exit 2
        fi
        if [ -z "$VERDICT_PATH" ]; then
            echo "ERROR: validation receipt output requires --verdict=<verdict.json>" >&2
            exit 2
        fi
        if [ ! -f "$VERDICT_PATH" ] || [ ! -r "$VERDICT_PATH" ]; then
            echo "ERROR: verdict is not readable: $VERDICT_PATH" >&2
            exit 1
        fi
        if [ -z "$VALIDATION_OUTPUT" ]; then
            echo "ERROR: --verdict requires --validation-output=<validation.json>" >&2
            exit 2
        fi
    fi
}

resolve_optional_defaults() {
    if [ -z "$CREDENTIAL_ENV_FILE" ]; then
        CREDENTIAL_ENV_FILE="$DEFAULT_CREDENTIAL_ENV_FILE"
    fi
    if [ -z "$BILLING_MONTH" ]; then
        BILLING_MONTH="$(date -u +%Y-%m)"
    fi
    if [ -z "$STAGING_SMOKE_FLAPJACK_AMI_ID" ]; then
        STAGING_SMOKE_FLAPJACK_AMI_ID="$(resolve_manifest_ami_id)"
    fi
}

resolve_manifest_ami_id() {
    local manifest_path candidate
    for manifest_path in \
        "$REPO_ROOT/ops/packer/flapjack-ami-manifest.json" \
        "$REPO_ROOT/flapjack-ami-manifest.json"; do
        if [ -f "$manifest_path" ]; then
            candidate="$(extract_ami_id_from_manifest "$manifest_path")"
            if [ -n "$candidate" ]; then
                printf '%s\n' "$candidate"
                return 0
            fi
        fi
    done
    return 0
}

extract_ami_id_from_manifest() {
    local manifest_path="$1"
    python3 - "$manifest_path" <<'PY'
import json
import re
import sys

manifest_path = sys.argv[1]
ami_pattern = re.compile(r"^ami-[0-9a-f]{8}(?:[0-9a-f]{9})?$")

with open(manifest_path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)

for build in payload.get("builds", []):
    custom_ami = build.get("custom_data", {}).get("ami_id")
    if isinstance(custom_ami, str) and ami_pattern.match(custom_ami):
        print(custom_ami)
        raise SystemExit(0)

    artifact_id = build.get("artifact_id")
    if not isinstance(artifact_id, str):
        continue
    for part in re.split(r"[,\\s]+", artifact_id):
        candidate = part.rsplit(":", 1)[-1]
        if ami_pattern.match(candidate):
            print(candidate)
            raise SystemExit(0)
PY
}

validate_inputs() {
    if [ -n "$SUMMARY_PATH" ] || [ -n "$VERDICT_OUTPUT" ]; then
        echo "ERROR: --summary and --verdict-output require --classify-existing" >&2
        exit 2
    fi
    if [ -z "$SHA" ]; then
        echo "ERROR: missing required argument: --sha=<GIT_SHA>" >&2
        exit 2
    fi
    if ! rc_is_valid_sha "$SHA"; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        exit 2
    fi
    if [ -z "$ARTIFACT_DIR" ]; then
        echo "ERROR: missing required argument: --artifact-dir=<dir>" >&2
        exit 2
    fi
    if [ "$BILLING_PREFLIGHT_CHECK" -eq 1 ] && [ -z "$BILLING_INPUT_MANIFEST" ]; then
        BILLING_INPUT_MANIFEST="$ARTIFACT_DIR/billing_preflight_input_manifest.json"
    fi
    if ! rc_is_valid_billing_month "$BILLING_MONTH"; then
        echo "ERROR: --billing-month must use YYYY-MM format with month 01-12" >&2
        exit 2
    fi
    if [ -z "$SECTION1_MANIFEST" ]; then
        echo "ERROR: missing required argument: --section1-manifest=<path>" >&2
        exit 2
    fi
    if ! rc_validate_section1_manifest "$SECTION1_MANIFEST" "$SHA" "$BILLING_MONTH" "$ARTIFACT_DIR"; then
        exit 1
    fi
    if [ -z "$STAGING_SMOKE_API_AMI_ID" ]; then
        echo "ERROR: missing staging API smoke AMI; pass --staging-smoke-api-ami-id=<ami-id>" >&2
        exit 2
    fi
    if [ -z "$STAGING_SMOKE_FLAPJACK_AMI_ID" ]; then
        echo "ERROR: missing staging Flapjack smoke AMI; pass --staging-smoke-flapjack-ami-id=<ami-id> or build an AMI manifest" >&2
        exit 2
    fi
    if ! rc_is_valid_ami_id "$STAGING_SMOKE_API_AMI_ID"; then
        echo "ERROR: --staging-smoke-api-ami-id must use AMI ID format (ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx)" >&2
        exit 2
    fi
    if ! rc_is_valid_ami_id "$STAGING_SMOKE_FLAPJACK_AMI_ID"; then
        echo "ERROR: --staging-smoke-flapjack-ami-id must use AMI ID format (ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx)" >&2
        exit 2
    fi
}

prepare_rc_environment() {
    rc_load_credential_env_file "$CREDENTIAL_ENV_FILE"
    ensure_credential_preflight
    ensure_browser_preflight
}

assemble_paid_beta_argv() {
    rc_build_paid_beta_argv "$SHA" "$ARTIFACT_DIR" "$CREDENTIAL_ENV_FILE" "$BILLING_MONTH" "$STAGING_SMOKE_API_AMI_ID" "$STAGING_SMOKE_FLAPJACK_AMI_ID" "$SECTION1_MANIFEST" "$ONLY_STEPS"
}

write_rc_run_receipt() {
    local wrapper_exit="$1"
    local coordinator_exit="$2"
    local summary_path="$3"
    local receipt_argv=("$COORDINATOR_RELATIVE_PATH" "${RC_PAID_BETA_ARGV[@]}")
    if [ "${#COORDINATOR_ARGS[@]}" -gt 0 ]; then
        receipt_argv+=("${COORDINATOR_ARGS[@]}")
    fi
    rc_write_run_receipt \
        "$ARTIFACT_DIR/rc_run_receipt.json" \
        "$ARTIFACT_DIR" \
        "$wrapper_exit" \
        "$coordinator_exit" \
        "$summary_path" \
        "$RC_SECTION1_MANIFEST_VALIDATION_OUTPUT" \
        "$SHA" \
        "$BILLING_MONTH" \
        "${receipt_argv[@]}"
}

print_delegated_command() {
    local printable_args=()
    local quoted arg
    local all_args=("$COORDINATOR_RELATIVE_PATH" "${RC_PAID_BETA_ARGV[@]}")
    if [ "${#COORDINATOR_ARGS[@]}" -gt 0 ]; then
        all_args+=("${COORDINATOR_ARGS[@]}")
    fi

    for arg in "${all_args[@]}"; do
        printf -v quoted '%q' "$arg"
        printable_args+=("$quoted")
    done

    printf 'bash %s\n' "${printable_args[*]}"
}

bootstrap_web_prerequisites() {
    if ! has_web_vite_runtime "$REPO_ROOT"; then
        (cd "$REPO_ROOT/web" && npm ci --no-audit --no-fund)
    fi
}

write_preflight_refusal_json() {
    local classification="$1"
    local status="$2"
    local diagnostic="$3"
    local source="${4:-}"
    local account="${5:-}"
    local arn="${6:-}"
    local raw_error="${7:-}"
    local refusal_path="$ARTIFACT_DIR/preflight_refusal.json"

    mkdir -p "$ARTIFACT_DIR"
    python3 - "$refusal_path" "$classification" "$status" "$diagnostic" "$source" "$account" "$arn" "$raw_error" <<'PY'
import json
import sys

path, classification, status, diagnostic, source, account, arn, raw_error = sys.argv[1:9]
payload = {
    "classification": classification,
    "status": status,
    "diagnostic": diagnostic,
    "details": {
        "source": source,
        "account": account,
        "arn": arn,
        "raw_error": raw_error,
    },
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

ensure_credential_preflight() {
    aws_identity_ensure "$CREDENTIAL_ENV_FILE" || true
    case "${AWS_IDENTITY_STATUS:-}" in
        valid|recovered)
            return 0
            ;;
    esac

    local preflight_diagnostic raw_error_detail
    case "${AWS_IDENTITY_STATUS:-}" in
        invalid_credentials)
            preflight_diagnostic="aws credentials rejected by STS; raw provider output redacted"
            ;;
        *)
            preflight_diagnostic="${AWS_IDENTITY_DIAGNOSTIC:-aws identity preflight failed}"
            ;;
    esac
    if [ -n "${AWS_IDENTITY_RAW_ERROR:-}" ]; then
        raw_error_detail="[REDACTED]"
    else
        raw_error_detail=""
    fi

    write_preflight_refusal_json \
        "credential_invalid" \
        "${AWS_IDENTITY_STATUS:-unknown}" \
        "$preflight_diagnostic" \
        "${AWS_IDENTITY_SOURCE:-}" \
        "${AWS_IDENTITY_ACCOUNT:-}" \
        "${AWS_IDENTITY_ARN:-}" \
        "$raw_error_detail"
    echo "ERROR: AWS identity preflight failed: $preflight_diagnostic" >&2
    exit 3
}

refuse_browser_preflight() {
    local status="$1"
    local diagnostic="$2"

    write_preflight_refusal_json "browser_env_gap" "$status" "$diagnostic"
    echo "ERROR: browser preflight failed: $diagnostic" >&2
    exit 3
}

ensure_browser_preflight() {
    hydrate_env_from_ssm staging || true

    if [ -z "${ADMIN_KEY:-}" ]; then
        refuse_browser_preflight "admin_key_missing" "ADMIN_KEY missing after hydrate_env_from_ssm staging"
    fi
    export E2E_ADMIN_KEY="$ADMIN_KEY"

    local api_url="${API_URL:-${API_BASE_URL:-}}"
    if [ -z "$api_url" ]; then
        refuse_browser_preflight "api_url_missing" "API_URL missing after hydrate_env_from_ssm staging"
    fi

    local health_url="${api_url%/}/health"
    if ! web_runtime_service_is_ready "$health_url"; then
        refuse_browser_preflight "api_unready" "API health check failed at ${health_url}"
    fi
}

write_billing_input_manifest() {
    local manifest_path="$1"
    shift

    mkdir -p "$(dirname "$manifest_path")"
    python3 - "$manifest_path" "$@" <<'PY'
import json
import os
import sys

manifest_path = sys.argv[1]
argv = sys.argv[2:]
fixed_names = [
    "STAGING_API_URL",
    "STAGING_STRIPE_WEBHOOK_URL",
    "STRIPE_SECRET_KEY",
    "STRIPE_WEBHOOK_SECRET",
    "ADMIN_KEY",
    "DATABASE_URL",
    "INTEGRATION_DB_URL",
    "MAILPIT_API_URL",
    "SES_REGION",
    "AWS_DEFAULT_REGION",
]
names = fixed_names + sorted(
    name for name in os.environ if name.startswith("REHEARSAL_SES_")
)
payload = {
    "argv": argv,
    "env": {
        name: "set" if name in os.environ and os.environ.get(name, "") != "" else "unset"
        for name in names
    },
}
with open(manifest_path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

run_billing_preflight_check() {
    local dry_run_argv=(
        "bash"
        "scripts/staging_billing_dry_run.sh"
        "--check"
        "--env-file"
        "$CREDENTIAL_ENV_FILE"
    )

    write_billing_input_manifest "$BILLING_INPUT_MANIFEST" "${dry_run_argv[@]}"
    exec bash "$REPO_ROOT/scripts/staging_billing_dry_run.sh" --check --env-file "$CREDENTIAL_ENV_FILE"
}

main() {
    parse_args "$@"
    if [ "$VALIDATE_EXISTING" -eq 1 ]; then
        validate_existing_receipt_inputs
        rc_validate_run_receipt "$RUN_RECEIPT" "$SHA" "$BILLING_MONTH" "$SECTION1_MANIFEST" "$SUMMARY_PATH" >/dev/null
        if [ -n "$VALIDATION_OUTPUT" ]; then
            local validation_dir validation_exit=0
            validation_dir="$(mktemp -d "${TMPDIR:-/tmp}/fjcloud_rc_validation.XXXXXX")"
            rc_validate_section1_manifest "$SECTION1_MANIFEST" "$SHA" "$BILLING_MONTH" "$validation_dir" || validation_exit=$?
            if [ "$validation_exit" -eq 0 ]; then
                rc_validate_verdict_for_summary \
                    "$VERDICT_PATH" "$SUMMARY_PATH" "$RC_SECTION1_MANIFEST_VALIDATION_OUTPUT" || validation_exit=$?
            fi
            if [ "$validation_exit" -eq 0 ]; then
                rc_write_validation_receipt \
                    "$VALIDATION_OUTPUT" "$SHA" "$RC_SECTION1_MANIFEST_VALIDATION_OUTPUT" "$VERDICT_PATH" || validation_exit=$?
            fi
            rm -rf "$validation_dir"
            exit "$validation_exit"
        fi
        exit 0
    fi
    if [ "$CLASSIFY_EXISTING" -eq 1 ]; then
        validate_classify_existing_inputs
        rc_write_verdict_for_summary "$SUMMARY_PATH" "$VERDICT_OUTPUT" "$RC_SECTION1_MANIFEST_VALIDATION_OUTPUT"
        if [ -n "$ARTIFACT_DIR" ] && [ -n "$RC_SECTION1_MANIFEST_VALIDATION_OUTPUT" ]; then
            assemble_paid_beta_argv
            write_rc_run_receipt 0 "" "$SUMMARY_PATH"
        fi
        exit 0
    fi

    resolve_optional_defaults
    validate_inputs
    prepare_rc_environment
    if [ "$BILLING_PREFLIGHT_CHECK" -eq 1 ]; then
        run_billing_preflight_check
    fi
    bootstrap_web_prerequisites
    assemble_paid_beta_argv

    if [ "$DRY_RUN" -eq 1 ]; then
        print_delegated_command
        write_rc_run_receipt 0 "" ""
        exit 0
    fi

    local coordinator_exit=0
    if [ "${#COORDINATOR_ARGS[@]}" -gt 0 ]; then
        bash "$COORDINATOR_PATH" "${RC_PAID_BETA_ARGV[@]}" "${COORDINATOR_ARGS[@]}" || coordinator_exit=$?
    else
        bash "$COORDINATOR_PATH" "${RC_PAID_BETA_ARGV[@]}" || coordinator_exit=$?
    fi
    if [ "$coordinator_exit" -eq 0 ]; then
        write_rc_run_receipt 0 "$coordinator_exit" "$ARTIFACT_DIR/summary.json"
    fi
    exit "$coordinator_exit"
}

main "$@"
