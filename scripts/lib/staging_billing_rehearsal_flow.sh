#!/usr/bin/env bash
# Flow helpers for scripts/staging_billing_rehearsal.sh.

set_blocked_summary() {
    local classification="$1"
    local detail="$2"
    SUMMARY_RESULT="blocked"
    SUMMARY_CLASSIFICATION="$classification"
    SUMMARY_DETAIL="$detail"
}

parse_args_token() {
    case "$1" in
        --env-file)
            [ "$#" -ge 2 ] || {
                set_blocked_summary "explicit_env_file_required" "--env-file requires a path."
                return 1
            }
            ENV_FILE="$2"
            PARSE_ARGS_SHIFT=2
            return 0
            ;;
        --env-file=*)
            ENV_FILE="${1#--env-file=}"
            PARSE_ARGS_SHIFT=1
            return 0
            ;;
        --month)
            [ "$#" -ge 2 ] || {
                set_blocked_summary "billing_month_required" "--month requires a value in YYYY-MM format."
                return 1
            }
            BILLING_MONTH="$2"
            PARSE_ARGS_SHIFT=2
            return 0
            ;;
        --month=*)
            BILLING_MONTH="${1#--month=}"
            PARSE_ARGS_SHIFT=1
            return 0
            ;;
        --confirm-live-mutation)
            CONFIRM_LIVE_MUTATION=1
            PARSE_ARGS_SHIFT=1
            return 0
            ;;
        --reset-test-state)
            RESET_TEST_STATE=1
            PARSE_ARGS_SHIFT=1
            return 0
            ;;
        --confirm-test-tenant)
            [ "$#" -ge 2 ] || {
                set_blocked_summary "test_tenant_confirmation_required" \
                    "--confirm-test-tenant requires a tenant UUID value."
                return 1
            }
            CONFIRM_TEST_TENANT_ID="$2"
            PARSE_ARGS_SHIFT=2
            return 0
            ;;
        --confirm-test-tenant=*)
            CONFIRM_TEST_TENANT_ID="${1#--confirm-test-tenant=}"
            PARSE_ARGS_SHIFT=1
            return 0
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            set_blocked_summary "unknown_argument" "Unknown argument: $1"
            return 1
            ;;
    esac
}

validate_parsed_args() {
    if [ -z "$ENV_FILE" ]; then
        set_blocked_summary "explicit_env_file_required" \
            "--env-file is required and must point to an explicit staging env file."
        return 1
    fi
    if is_repo_default_env_file_name "$ENV_FILE"; then
        set_blocked_summary "repo_default_env_file_rejected" \
            "Repo-default env filenames are forbidden for staging rehearsal: $ENV_FILE"
        return 1
    fi
    if [ "$CONFIRM_LIVE_MUTATION" -eq 1 ] && [ -z "$BILLING_MONTH" ]; then
        set_blocked_summary "billing_month_required" \
            "--month is required when --confirm-live-mutation is provided."
        return 1
    fi
    if [ -n "$BILLING_MONTH" ] && [ "$RESET_TEST_STATE" -ne 1 ] && [ "$CONFIRM_LIVE_MUTATION" -ne 1 ]; then
        set_blocked_summary "live_mutation_confirmation_required" \
            "--confirm-live-mutation is required when --month is provided."
        return 1
    fi
    if [ "$RESET_TEST_STATE" -eq 1 ] && [ "$CONFIRM_LIVE_MUTATION" -eq 1 ]; then
        set_blocked_summary "reset_mode_live_mutation_conflict" \
            "--confirm-live-mutation cannot be combined with --reset-test-state."
        return 1
    fi
    if [ "$RESET_TEST_STATE" -eq 1 ] && [ -z "$CONFIRM_TEST_TENANT_ID" ]; then
        set_blocked_summary "test_tenant_confirmation_required" \
            "--confirm-test-tenant is required when --reset-test-state is provided."
        return 1
    fi
    if [ -n "$CONFIRM_TEST_TENANT_ID" ] && [ "$RESET_TEST_STATE" -ne 1 ]; then
        set_blocked_summary "reset_test_state_required" \
            "--reset-test-state is required when --confirm-test-tenant is provided."
        return 1
    fi
    return 0
}

parse_args_impl() {
    PARSE_ARGS_SHIFT=0
    while [ "$#" -gt 0 ]; do
        parse_args_token "$@" || return 1
        shift "$PARSE_ARGS_SHIFT"
    done
    validate_parsed_args
}

handle_parse_failure() {
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_GUARD_DETAIL="$SUMMARY_DETAIL"
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_ATTEMPT_DETAIL="Live mutation path remained blocked."
}

handle_env_parse_failure() {
    STEP_PREFLIGHT_RESULT="blocked"
    STEP_PREFLIGHT_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_PREFLIGHT_DETAIL="$SUMMARY_DETAIL"
    STEP_METERING_RESULT="blocked"
    STEP_METERING_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_METERING_DETAIL="Metering evidence skipped because env-file parsing failed."
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_GUARD_DETAIL="Guard evaluation skipped because env-file parsing failed."
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_ATTEMPT_DETAIL="Live mutation was not attempted because env-file parsing failed."
}

handle_preflight_failure() {
    STEP_METERING_RESULT="blocked"
    STEP_METERING_CLASSIFICATION="preflight_failed"
    STEP_METERING_DETAIL="Metering evidence skipped because preflight failed."
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="preflight_failed"
    STEP_GUARD_DETAIL="Guard evaluation skipped because preflight failed."
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="preflight_failed"
    STEP_ATTEMPT_DETAIL="Live mutation was not attempted because preflight failed."
}

handle_health_failure() {
    STEP_METERING_RESULT="blocked"
    STEP_METERING_CLASSIFICATION="health_probe_failed"
    STEP_METERING_DETAIL="Metering evidence skipped because health probe failed."
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="health_probe_failed"
    STEP_GUARD_DETAIL="Guard evaluation skipped because health probe failed."
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="health_probe_failed"
    STEP_ATTEMPT_DETAIL="Live mutation was not attempted because health probe failed."
}

handle_metering_failure() {
    STEP_GUARD_RESULT="blocked"
    STEP_GUARD_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_GUARD_DETAIL="Guard evaluation skipped because metering evidence failed."
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_ATTEMPT_DETAIL="Live mutation was not attempted because metering evidence failed."
}

handle_guard_failure() {
    STEP_ATTEMPT_RESULT="blocked"
    STEP_ATTEMPT_CLASSIFICATION="$SUMMARY_CLASSIFICATION"
    STEP_ATTEMPT_DETAIL="Live mutation was not attempted because guard preconditions failed."
}

run_rehearsal_flow() {
    if ! parse_args "$@"; then
        handle_parse_failure
        return 0
    fi

    if ! validate_explicit_env_file_syntax "$ENV_FILE"; then
        handle_env_parse_failure
        return 0
    fi

    clear_rehearsal_input_env
    load_layered_env_files "$ENV_FILE"

    if ! validate_test_tenant_allowlist; then
        return 0
    fi

    if [ "$RESET_TEST_STATE" -eq 1 ]; then
        if ! run_reset_flow; then
            return 0
        fi
        return 0
    fi

    if ! run_preflight_owner; then
        handle_preflight_failure
        return 0
    fi

    if ! capture_health_artifact; then
        handle_health_failure
        return 0
    fi

    if ! run_metering_evidence_step; then
        handle_metering_failure
        return 0
    fi

    if ! run_live_mutation_guard; then
        handle_guard_failure
        return 0
    fi

    if ! run_live_mutation_attempt; then
        return 0
    fi
    return 0
}
