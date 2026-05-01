#!/usr/bin/env bash

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck disable=SC1091
# shellcheck source=../lib/stripe_checks.sh
source "$REPO_ROOT/scripts/lib/stripe_checks.sh"
# shellcheck disable=SC1091
# shellcheck source=../lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"

SHA=""
ARTIFACT_ROOT=""
CREDENTIAL_ENV_FILE=""
BILLING_MONTH=""
STAGING_SMOKE_AMI_ID=""
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
  --staging-smoke-ami-id=<ami-id>
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
            --staging-smoke-ami-id=*)
                STAGING_SMOKE_AMI_ID="${arg#--staging-smoke-ami-id=}"
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
    if [ -z "$STAGING_SMOKE_AMI_ID" ]; then
        echo "missing required argument: --staging-smoke-ami-id" >&2
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

load_credential_env_file() {
    local line=""
    local key=""
    local value=""

    if [ ! -r "$CREDENTIAL_ENV_FILE" ]; then
        echo "ERROR: credential env file is not readable: $CREDENTIAL_ENV_FILE" >&2
        exit 1
    fi

    # Parse credential env files as inert KEY=value data only; never source
    # executable shell content from a user-provided file path.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|'#'*) continue ;;
        esac
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            echo "ERROR: credential env file contains non KEY=value line: $line" >&2
            exit 1
        fi
        key="${line%%=*}"
        value="${line#*=}"
        export "${key}=${value}"
    done < "$CREDENTIAL_ENV_FILE"

    # Downstream Stripe owners resolve the canonical variable name. Bridge the
    # operator-only restricted alias once so every delegated stage sees the same
    # effective credential without duplicating fallback logic.
    if [ -z "${STRIPE_SECRET_KEY:-}" ] && [ -n "${STRIPE_SECRET_KEY_RESTRICTED:-}" ]; then
        export STRIPE_SECRET_KEY="$STRIPE_SECRET_KEY_RESTRICTED"
    fi
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
    summary_json="{\"run_id\":$(validation_json_escape "$RUN_ID"),\"status\":$(validation_json_escape "$status"),\"sha\":$(validation_json_escape "$SHA"),\"billing_month\":$(validation_json_escape "$BILLING_MONTH"),\"staging_smoke_ami_id\":$(validation_json_escape "$STAGING_SMOKE_AMI_ID"),\"dns_domain\":$(validation_json_escape "$dns_domain"),\"dry_run\":$([ "$DRY_RUN" -eq 1 ] && echo true || echo false)}"
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

run_live_sequence() {
    local dns_domain="$1"
    local health_url
    local stage3_exit=0

    health_url="https://api.${dns_domain}/health"

    curl -fsS "$health_url" > "$RUN_DIR/01_stripe_runtime/health.json"
    (journalctl --no-pager | grep -c "STRIPE_SECRET_KEY" || true) > "$RUN_DIR/01_stripe_runtime/stripe_secret_key_warning_count.txt"
    bash "$REPO_ROOT/scripts/validate-stripe.sh" > "$RUN_DIR/01_stripe_runtime/validate_stripe.log" 2>&1

    (journalctl --no-pager | grep -c "alert webhook" || true) > "$RUN_DIR/02_alert_log/alert_webhook_count.txt"

    bash "$REPO_ROOT/scripts/launch/run_full_backend_validation.sh" \
        --paid-beta-rc \
        "--sha=$SHA" \
        "--artifact-dir=$RUN_DIR/03_paid_beta_rc" \
        "--credential-env-file=$CREDENTIAL_ENV_FILE" \
        "--billing-month=$BILLING_MONTH" \
        "--staging-smoke-ami-id=$STAGING_SMOKE_AMI_ID" \
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

    load_credential_env_file
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
