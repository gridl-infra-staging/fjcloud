#!/usr/bin/env bash

# Keep CLI parsing and mode setup out of the main coordinator so the
# orchestrator can stay under the repo hard line limit.

# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
# TODO: Document parse_cli_args.
parse_cli_args() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            --help)
                print_usage
                return 10
                ;;
            --dry-run)
                if [ -n "$EXPLICIT_MODE" ] && [ "$EXPLICIT_MODE" != "dry_run" ]; then
                    echo "ERROR: --dry-run cannot be combined with --paid-beta-rc" >&2
                    print_usage >&2
                    return 2
                fi
                EXPLICIT_MODE="dry_run"
                ;;
            --paid-beta-rc)
                if [ -n "$EXPLICIT_MODE" ] && [ "$EXPLICIT_MODE" != "paid_beta_rc" ]; then
                    echo "ERROR: --paid-beta-rc cannot be combined with --dry-run" >&2
                    print_usage >&2
                    return 2
                fi
                EXPLICIT_MODE="paid_beta_rc"
                ;;
            --sha=*)
                SHA_OVERRIDE="${arg#--sha=}"
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
            --staging-smoke-ami-id=*)
                STAGING_SMOKE_AMI_ID="${arg#--staging-smoke-ami-id=}"
                ;;
            *)
                echo "ERROR: unknown argument '$arg'" >&2
                print_usage >&2
                return 2
                ;;
        esac
    done
    return 0
}

validate_cli_args() {
    if [ -n "$SHA_OVERRIDE" ] && ! is_valid_sha "$SHA_OVERRIDE"; then
        echo "ERROR: --sha must be a 40-character lowercase hexadecimal commit SHA" >&2
        return 2
    fi
    if [ -n "$BILLING_MONTH" ] && ! is_valid_billing_month "$BILLING_MONTH"; then
        echo "ERROR: --billing-month must use YYYY-MM format with month 01-12" >&2
        return 2
    fi
    if [ -n "$STAGING_SMOKE_AMI_ID" ] && ! is_valid_ami_id "$STAGING_SMOKE_AMI_ID"; then
        echo "ERROR: --staging-smoke-ami-id must use AMI ID format (ami-xxxxxxxx or ami-xxxxxxxxxxxxxxxxx)" >&2
        return 2
    fi
    return 0
}

resolve_mode() {
    if [ -n "$EXPLICIT_MODE" ]; then
        MODE="$EXPLICIT_MODE"
        return
    fi
    if [ "${DRY_RUN:-0}" = "1" ]; then
        MODE="dry_run"
    fi
}

resolve_optional_sha() {
    if resolve_sha >/dev/null 2>&1; then
        resolve_sha
    else
        printf '\n'
    fi
}

prepare_mode_requirements() {
    local start_ms="$1"
    if [ "$MODE" = "live" ]; then
        if ! run_preflight; then
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
        RESOLVED_SHA="$(resolve_sha)"
        return 0
    fi
    if [ "$MODE" = "paid_beta_rc" ]; then
        if [ -z "$RESOLVED_SHA" ]; then
            PRE_FLIGHT_FAILURES=("missing git SHA (pass --sha=<sha> or ensure git rev-parse HEAD works)")
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
        if ! ensure_rc_artifact_dir; then
            PRE_FLIGHT_FAILURES=("unable to prepare --artifact-dir path")
            emit_result_json "fail" "$MODE" "$start_ms" "false"
            return 1
        fi
    fi
    return 0
}
