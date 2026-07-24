#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../lib/stripe_checks.sh
source "$REPO_ROOT/scripts/lib/stripe_checks.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/env.sh
source "$REPO_ROOT/scripts/lib/env.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/rc_invocation.sh
source "$REPO_ROOT/scripts/lib/rc_invocation.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"

SHA=""
ARTIFACT_ROOT=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_API_AMI_ID=""
STAGING_SMOKE_FLAPJACK_AMI_ID=""
DRY_RUN=0
REJECT_KNOWN_BAD_SHAS=()

RUN_ID=""
RUN_DIR=""
SUMMARY_PATH=""

print_usage() {
    cat <<'USAGE'
Usage: post_deploy_evidence_capture.sh
  --sha=<git-sha>
  --artifact-dir=<dir>
  --credential-env-file=<path>
  --billing-month=<YYYY-MM>
  --staging-smoke-api-ami-id=<ami-id>
  --staging-smoke-flapjack-ami-id=<ami-id>
  [--dry-run]
  [--reject-known-bad-sha=<sha>]
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
            --sha=*)
                SHA="${arg#--sha=}"
                ;;
            --artifact-dir=*)
                ARTIFACT_ROOT="${arg#--artifact-dir=}"
                ;;
            --credential-env-file=*)
                CREDENTIAL_ENV_FILE="${arg#--credential-env-file=}"
                ;;
            --billing-month=*)
                BILLING_MONTH="${arg#--billing-month=}"
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
            --dry-run)
                DRY_RUN=1
                ;;
            --reject-known-bad-sha=*)
                REJECT_KNOWN_BAD_SHAS+=("${arg#--reject-known-bad-sha=}")
                ;;
            *)
                echo "ERROR: unknown argument '$arg'" >&2
                exit 2
                ;;
        esac
    done
}

validate_required_args() {
    if [ -z "$SHA" ]; then
        echo "missing required argument: --sha" >&2
        exit 2
    fi
    if [ -z "$ARTIFACT_ROOT" ]; then
        echo "missing required argument: --artifact-dir" >&2
        exit 2
    fi
    if [ -z "$CREDENTIAL_ENV_FILE" ]; then
        echo "missing required argument: --credential-env-file" >&2
        exit 2
    fi
    if [ -z "$BILLING_MONTH" ]; then
        echo "missing required argument: --billing-month" >&2
        exit 2
    fi
    if [ -z "$STAGING_SMOKE_API_AMI_ID" ]; then
        echo "missing required argument: --staging-smoke-api-ami-id" >&2
        exit 2
    fi
    if [ -z "$STAGING_SMOKE_FLAPJACK_AMI_ID" ]; then
        echo "missing required argument: --staging-smoke-flapjack-ami-id" >&2
        exit 2
    fi
    if ! rc_is_valid_sha "$SHA"; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        exit 2
    fi
    if ! rc_is_valid_billing_month "$BILLING_MONTH"; then
        echo "ERROR: --billing-month must use YYYY-MM format with month 01-12" >&2
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

ensure_artifact_root() {
    if [ -e "$ARTIFACT_ROOT" ] && [ ! -d "$ARTIFACT_ROOT" ]; then
        echo "ERROR: --artifact-dir must be a directory path: $ARTIFACT_ROOT" >&2
        exit 1
    fi
    mkdir -p "$ARTIFACT_ROOT"
}

create_run_id() {
    if [ -n "${POST_DEPLOY_RUN_ID:-}" ]; then
        printf '%s\n' "$POST_DEPLOY_RUN_ID"
        return
    fi
    printf 'fjcloud_post_deploy_evidence_%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

create_run_dir() {
    local run_id="$1"
    local run_dir="$ARTIFACT_ROOT/$run_id"
    if [ -e "$run_dir" ]; then
        echo "RUN_ID $run_id already exists; pass a fresh --artifact-dir or remove the existing run dir" >&2
        exit 1
    fi

    mkdir -p "$run_dir"
    mkdir -p "$run_dir/logs"
    : > "$run_dir/summary.json"

    mkdir -p "$run_dir/01_stripe_runtime" "$run_dir/02_alert_log" "$run_dir/03_paid_beta_rc"

    RUN_ID="$run_id"
    RUN_DIR="$run_dir"
    SUMMARY_PATH="$run_dir/summary.json"
}

run_stripe_prefix_gate() {
    local had_stripe_key=0 saved_stripe_key=""
    local had_gate=0 saved_gate=""
    local check_exit=0

    if [ "${STRIPE_SECRET_KEY+x}" = "x" ]; then
        had_stripe_key=1
        saved_stripe_key="$STRIPE_SECRET_KEY"
    fi

    if [ "${BACKEND_LIVE_GATE+x}" = "x" ]; then
        had_gate=1
        saved_gate="$BACKEND_LIVE_GATE"
    fi

    if [ -n "${STRIPE_SECRET_KEY_RESTRICTED:-}" ]; then
        export STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY_RESTRICTED"
    fi
    export BACKEND_LIVE_GATE=1

    check_stripe_key_present || check_exit=$?

    if [ "$had_stripe_key" -eq 1 ]; then
        export STRIPE_SECRET_KEY="$saved_stripe_key"
    else
        unset STRIPE_SECRET_KEY
    fi

    if [ "$had_gate" -eq 1 ]; then
        export BACKEND_LIVE_GATE="$saved_gate"
    else
        unset BACKEND_LIVE_GATE
    fi

    if [ "$check_exit" -ne 0 ]; then
        exit "$check_exit"
    fi
}

resolve_deploy_sha_for_reject_gate() {
    if [ "$DRY_RUN" -eq 1 ]; then
        if [ -n "${MOCK_LAST_DEPLOY_SHA:-}" ]; then
            printf '%s\n' "$MOCK_LAST_DEPLOY_SHA"
            return 0
        fi
        printf '%s\n' "$SHA"
        return 0
    fi

    aws ssm get-parameter \
        --name "/fjcloud/staging/last_deploy_sha" \
        --with-decryption \
        --region "${AWS_DEFAULT_REGION:-us-east-1}" \
        --query 'Parameter.Value' \
        --output text
}

run_stage_0_reject_known_bad_sha_gate() {
    local deploy_sha
    local rejected_sha

    [ "${#REJECT_KNOWN_BAD_SHAS[@]}" -gt 0 ] || return 0

    deploy_sha="$(resolve_deploy_sha_for_reject_gate)"
    for rejected_sha in "${REJECT_KNOWN_BAD_SHAS[@]}"; do
        if [ "$deploy_sha" = "$rejected_sha" ]; then
            echo "deploy SHA $deploy_sha matches a known-bad SHA from the rejection list" >&2
            exit 1
        fi
    done
}

resolve_dns_domain() {
    if [ -n "${DNS_DOMAIN:-}" ]; then
        printf '%s\n' "$DNS_DOMAIN"
        return 0
    fi

    if [ -n "${API_URL:-}" ]; then
        local host
        local domain
        host="${API_URL#*://}"
        host="${host%%/*}"
        host="${host%%:*}"
        domain="$host"
        if [[ "$domain" == api.* ]]; then
            domain="${domain#api.}"
        fi
        if [ -n "$domain" ]; then
            printf '%s\n' "$domain"
            return 0
        fi
    fi

    printf 'flapjack.foo\n'
}

write_summary_json() {
    local status="$1"
    local dns_domain="$2"
    local summary_json
    summary_json="{\"run_id\":$(validation_json_escape "$RUN_ID"),\"status\":$(validation_json_escape "$status"),\"sha\":$(validation_json_escape "$SHA"),\"billing_month\":$(validation_json_escape "$BILLING_MONTH"),\"staging_smoke_api_ami_id\":$(validation_json_escape "$STAGING_SMOKE_API_AMI_ID"),\"staging_smoke_flapjack_ami_id\":$(validation_json_escape "$STAGING_SMOKE_FLAPJACK_AMI_ID"),\"dns_domain\":$(validation_json_escape "$dns_domain"),\"dry_run\":$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)}"
    printf '%s\n' "$summary_json" > "$SUMMARY_PATH"
}

run_dry_run_plan() {
    echo "[dry-run] STAGE_0: would verify deploy advanced past --reject-known-bad-sha"
    echo "[dry-run] STAGE_1: would curl https://api.<dns_domain>/health"
    echo "[dry-run] STAGE_1: would journalctl-grep STRIPE_SECRET_KEY warning count"
    echo "[dry-run] STAGE_1: would invoke validate-stripe.sh"
    echo "[dry-run] STAGE_2: would journalctl-grep alert webhook configured"
    echo "[dry-run] STAGE_3: would invoke run_full_backend_validation.sh --paid-beta-rc"

    echo "01_stripe_runtime/"
    echo "02_alert_log/"
    echo "03_paid_beta_rc/"
}

journal_warning_count_to_file_or_zero() {
    local needle="$1"
    local output_path="$2"
    local warning_context="$3"
    if command -v journalctl >/dev/null 2>&1; then
        (journalctl --no-pager | grep -c "$needle" || true) > "$output_path"
        return 0
    fi

    echo "WARNING: journalctl not found on host; writing fallback zero count for $warning_context" >&2
    printf '0\n' > "$output_path"
}

run_live_sequence() {
    local dns_domain="$1"
    local health_url
    local stage3_exit=0

    health_url="https://api.${dns_domain}/health"

    curl -fsS "$health_url" > "$RUN_DIR/01_stripe_runtime/health.json"
    journal_warning_count_to_file_or_zero "STRIPE_SECRET_KEY" "$RUN_DIR/01_stripe_runtime/stripe_secret_key_warning_count.txt" "STRIPE_SECRET_KEY"
    bash "$REPO_ROOT/scripts/validate-stripe.sh" > "$RUN_DIR/01_stripe_runtime/validate_stripe.log" 2>&1

    journal_warning_count_to_file_or_zero "alert webhook" "$RUN_DIR/02_alert_log/alert_webhook_count.txt" "alert webhook"

    rc_build_paid_beta_argv "$SHA" "$RUN_DIR/03_paid_beta_rc" "$CREDENTIAL_ENV_FILE" "$BILLING_MONTH" "$STAGING_SMOKE_API_AMI_ID" "$STAGING_SMOKE_FLAPJACK_AMI_ID"
    bash "$REPO_ROOT/scripts/launch/run_full_backend_validation.sh" "${RC_PAID_BETA_ARGV[@]}" \
        > "$RUN_DIR/03_paid_beta_rc/full_backend_validation.log" 2>&1 || stage3_exit=$?

    if [ "$stage3_exit" -ne 0 ]; then
        return "$stage3_exit"
    fi

    echo "01_stripe_runtime/"
    echo "02_alert_log/"
    echo "03_paid_beta_rc/"

    write_summary_json "pass" "$dns_domain"
}

main() {
    parse_args "$@"
    validate_required_args
    ensure_artifact_root

    RUN_ID="$(create_run_id)"
    create_run_dir "$RUN_ID"

    rc_load_credential_env_file "$CREDENTIAL_ENV_FILE"
    rc_bridge_restricted_stripe_secret_key
    run_stripe_prefix_gate
    run_stage_0_reject_known_bad_sha_gate

    if [ "$DRY_RUN" -eq 1 ]; then
        run_dry_run_plan
        write_summary_json "dry_run" "<dns_domain>"
        return 0
    fi

    local dns_domain=""
    local live_exit=0
    dns_domain="$(resolve_dns_domain)"

    run_live_sequence "$dns_domain" || live_exit=$?
    if [ "$live_exit" -ne 0 ]; then
        write_summary_json "fail" "$dns_domain"
        return "$live_exit"
    fi
}

main "$@"
