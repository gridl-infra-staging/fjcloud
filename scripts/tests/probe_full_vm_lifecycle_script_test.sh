#!/usr/bin/env bash
# Stage 1 contract probe for scripts/validate_full_vm_lifecycle_prod.sh.
#
# This is a red-first contract suite: the target orchestrator script does not
# exist yet (Stage 2 will implement it). Every assertion in this suite locks
# one named contract the Stage 2 implementation must satisfy. Each FAIL
# message names the contract it is locking, so the next session knows exactly
# what to build to flip the assertion green.
#
# Locked contracts:
#   1. Dry-run mode does not require Stripe/admin/payment secrets in env.
#   2. trap cleanup EXIT runs cleanup exactly once on failure paths.
#   3. CLI accepts {dry-run, run-a, run-b}; unknown args fail with usage.
#   4. Script reuses shared seams:
#        - scripts/lib/http_json.sh (api_json_call/capture_json_response)
#        - scripts/lib/env.sh (load_env_file/load_layered_env_files)
#      and does NOT inline duplicate curl/env-parsing helpers.
#
# Hermetic: no outbound network, no .env.secret dependency, fixtures under
# mktemp -d, cleaned up on exit. Output is deterministic across re-runs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/validate_full_vm_lifecycle_prod.sh"

# shellcheck source=scripts/tests/lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=scripts/tests/lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

TEST_TMP_DIR=""

cleanup_test_tmp_dir() {
    if [ -n "${TEST_TMP_DIR:-}" ] && [ -d "$TEST_TMP_DIR" ]; then
        rm -rf "$TEST_TMP_DIR"
    fi
}
trap cleanup_test_tmp_dir EXIT

make_test_tmp_dir() {
    cleanup_test_tmp_dir
    TEST_TMP_DIR="$(mktemp -d)"
}

# Extract the cleanup() body from script content for contract checks.
extract_cleanup_body() {
    local script_content="$1"
    printf '%s\n' "$script_content" | awk '
        function brace_delta(line,   copy, opens, closes) {
            copy = line
            opens = gsub(/\{/, "{", copy)
            closes = gsub(/\}/, "}", copy)
            return opens - closes
        }
        function is_cleanup_header_with_brace(line) {
            return line ~ /^[[:space:]]*function[[:space:]]+cleanup([[:space:]]*\(\))?[[:space:]]*\{([[:space:]]*#.*)?[[:space:]]*$/ \
                || line ~ /^[[:space:]]*cleanup[[:space:]]*\(\)[[:space:]]*\{([[:space:]]*#.*)?[[:space:]]*$/
        }
        function is_cleanup_header_without_brace(line) {
            return line ~ /^[[:space:]]*function[[:space:]]+cleanup([[:space:]]*\(\))?[[:space:]]*([[:space:]]*#.*)?[[:space:]]*$/ \
                || line ~ /^[[:space:]]*cleanup[[:space:]]*\(\)[[:space:]]*([[:space:]]*#.*)?[[:space:]]*$/
        }
        {
            line = $0
        }
        is_cleanup_header_with_brace(line) || is_cleanup_header_without_brace(line) {
            if (!in_cleanup) {
                in_cleanup = 1
                depth = 0
                saw_opening_brace = 0
            }
        }
        in_cleanup {
            print
            if (index($0, "{") > 0) {
                saw_opening_brace = 1
            }
            if (!saw_opening_brace) {
                next
            }
            depth += brace_delta($0)
            if (depth <= 0) {
                exit
            }
        }
    '
}

# Require an executable re-entry guard inside cleanup(). Comments do not count.
cleanup_body_has_reentry_guard() {
    local cleanup_body="$1"
    local executable_lines has_cleanup_assignment has_cleanup_return_guard
    executable_lines="$(printf '%s\n' "$cleanup_body" | sed -E '/^[[:space:]]*#/d; /^[[:space:]]*$/d')"

    if [ -z "$executable_lines" ]; then
        return 1
    fi
    if printf '%s\n' "$executable_lines" | grep -Eq '(^|[[:space:];])trap[[:space:]]+-[[:space:]]+EXIT([[:space:];]|$)'; then
        return 0
    fi

    has_cleanup_assignment=1
    if ! printf '%s\n' "$executable_lines" | grep -Eq '(^|[[:space:];])CLEANUP_RAN[[:space:]]*='; then
        has_cleanup_assignment=0
    fi
    has_cleanup_return_guard=1
    if ! printf '%s\n' "$executable_lines" | grep -Eq '(CLEANUP_RAN[^#]*return|return[^#]*CLEANUP_RAN)'; then
        has_cleanup_return_guard=0
    fi
    [ "$has_cleanup_assignment" -eq 1 ] && [ "$has_cleanup_return_guard" -eq 1 ]
}

# Ensure trap registration is on a live executable line.
script_registers_cleanup_exit_trap() {
    local script_path="$1"
    grep -Eq "^[[:space:]]*trap[[:space:]]+[\"']?cleanup[\"']?[[:space:]]+EXIT([[:space:];]|$)" "$script_path"
}

# Return success only for canonical repo-owned seam paths.
path_is_repo_owned_seam() {
    local candidate_path="$1"
    local seam_filename="$2"
    case "$candidate_path" in
        "scripts/lib/$seam_filename" | \
        "./scripts/lib/$seam_filename" | \
        "\$SCRIPT_DIR/lib/$seam_filename" | \
        "\${SCRIPT_DIR}/lib/$seam_filename" | \
        "\$REPO_ROOT/scripts/lib/$seam_filename" | \
        "\${REPO_ROOT}/scripts/lib/$seam_filename")
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Detect whether the script sources a repo-owned seam file from a live source line.
file_sources_repo_owned_seam() {
    local script_path="$1"
    local seam_filename="$2"
    local line trimmed source_path remainder
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        if [ -z "$trimmed" ] || [[ "$trimmed" == \#* ]]; then
            continue
        fi
        if [[ "$trimmed" =~ ^(\.|source)[[:space:]]+(.+)$ ]]; then
            remainder="${BASH_REMATCH[2]}"
            source_path="${remainder%%[[:space:];]*}"
            source_path="${source_path#\"}"
            source_path="${source_path%\"}"
            source_path="${source_path#\'}"
            source_path="${source_path%\'}"
            if path_is_repo_owned_seam "$source_path" "$seam_filename"; then
                return 0
            fi
        fi
    done < "$script_path"
    return 1
}

# Detect Bash function declarations semantically on executable lines.
file_declares_function_name() {
    local script_path="$1"
    local function_name="$2"
    awk -v function_name="$function_name" '
        function line_is_blank_or_comment(line,   trimmed_line) {
            trimmed_line = line
            sub(/^[[:space:]]+/, "", trimmed_line)
            return trimmed_line == "" || trimmed_line ~ /^#/
        }
        function declares_with_inline_brace(line) {
            return line ~ ("^[[:space:]]*function[[:space:]]+" function_name "([[:space:]]*\\(\\))?[[:space:]]*\\{([[:space:]]*#.*)?[[:space:]]*$") \
                || line ~ ("^[[:space:]]*" function_name "[[:space:]]*\\(\\)[[:space:]]*\\{([[:space:]]*#.*)?[[:space:]]*$")
        }
        function declares_header_without_brace(line) {
            return line ~ ("^[[:space:]]*function[[:space:]]+" function_name "([[:space:]]*\\(\\))?[[:space:]]*([[:space:]]*#.*)?[[:space:]]*$") \
                || line ~ ("^[[:space:]]*" function_name "[[:space:]]*\\(\\)[[:space:]]*([[:space:]]*#.*)?[[:space:]]*$")
        }
        {
            line = $0
            if (line_is_blank_or_comment(line)) {
                next
            }
            if (pending_multiline_header) {
                if (line ~ /^[[:space:]]*\{([[:space:]]*#.*)?[[:space:]]*$/) {
                    found = 1
                    exit 0
                }
                pending_multiline_header = 0
            }
            if (declares_with_inline_brace(line)) {
                found = 1
                exit 0
            }
            if (declares_header_without_brace(line)) {
                pending_multiline_header = 1
            }
        }
        END {
            exit found ? 0 : 1
        }
    ' "$script_path"
}

run_source_probe_with_trace() {
    local script_path="$1"
    local source_probe_runner
    source_probe_runner="$TEST_TMP_DIR/source_probe_runner.sh"
    cat > "$source_probe_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_script="$1"
PS4='TRACE:${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]:-TOP}:${BASH_COMMAND}\n'
set -x
source "$target_script"
set +x
echo "source-ok"
EOF
    chmod +x "$source_probe_runner"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            ORCHESTRATOR_SOURCE_FOR_TEST="1" \
            bash "$source_probe_runner" "$script_path" 2>&1
    )" || RUN_EXIT_CODE=$?
    SOURCE_TRACE_OUTPUT="$RUN_STDOUT"
}

run_source_probe_and_print_exit_trap() {
    local script_path="$1"
    local source_probe_runner
    source_probe_runner="$TEST_TMP_DIR/source_probe_exit_trap.sh"
    cat > "$source_probe_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_script="$1"
source "$target_script"
trap -p EXIT
EOF
    chmod +x "$source_probe_runner"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            ORCHESTRATOR_SOURCE_FOR_TEST="1" \
            bash "$source_probe_runner" "$script_path" 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_flow_order_probe() {
    local mode="$1"
    local probe_runner
    probe_runner="$TEST_TMP_DIR/flow_order_probe.sh"
    cat > "$probe_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_script="$1"
mode="$2"

source "$target_script"

record_step() {
    printf '%s\n' "$1"
}

run_signup_step() { record_step "signup"; }
run_verify_email_step() { record_step "verify_email"; }
run_index_create_step() { record_step "create_index"; }
run_index_batch_step() { record_step "batch_index"; }
run_index_search_step() { record_step "search_index"; }
run_sync_stripe_step() { CANARY_STRIPE_CUSTOMER_ID="cus_probe_123"; record_step "sync_stripe"; }
run_prepare_run_b_payment_step() { record_step "prepare_run_b_payment"; }
run_invoice_generation_step() { LIFECYCLE_INVOICE_ID="inv_probe_123"; record_step "generate_invoice"; }
run_invoice_finalize_step() { record_step "finalize_invoice"; }
run_pay_invoice_out_of_band_step() { record_step "pay_invoice_out_of_band"; }
run_wait_for_paid_invoice_step() { record_step "wait_for_paid_invoice"; }
run_tenant_invoice_read_step() { record_step "read_invoices"; }
run_optional_privacy_card_step() { record_step "privacy_branch"; }

LIFECYCLE_MODE="$mode"
run_orchestration_flow
EOF
    chmod +x "$probe_runner"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            bash "$probe_runner" "$TARGET_SCRIPT" "$mode" 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_index_create_retry_probe() {
    local probe_runner
    probe_runner="$TEST_TMP_DIR/index_create_retry_probe.sh"
    cat > "$probe_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_script="$1"

source "$target_script"

INDEX_CREATE_CALLS=0

capture_json_response() {
    INDEX_CREATE_CALLS=$((INDEX_CREATE_CALLS + 1))
    if [ "$INDEX_CREATE_CALLS" -eq 1 ]; then
        HTTP_RESPONSE_CODE="504"
        HTTP_RESPONSE_BODY='{"error":"timeout"}'
        return 0
    fi
    HTTP_RESPONSE_CODE="201"
    HTTP_RESPONSE_BODY='{"id":"idx_probe"}'
    return 0
}

mark_failure() {
    FLOW_FAILED=1
    FLOW_FAILURE_STEP="$1"
    FLOW_FAILURE_DETAIL="$2"
    return 0
}

log() { :; }

CANARY_NONCE="probe-nonce"
CANARY_TOKEN="probe-token"
CANARY_INDEX_REGION="us-east-1"
CANARY_INDEX_CREATED=0
FLOW_FAILED=0
FLOW_FAILURE_STEP=""
FLOW_FAILURE_DETAIL=""

if run_index_create_step; then
    echo "rc=0"
else
    rc=$?
    echo "rc=$rc"
fi
echo "calls=$INDEX_CREATE_CALLS"
echo "created=$CANARY_INDEX_CREATED"
echo "flow_failed=$FLOW_FAILED"
echo "flow_step=$FLOW_FAILURE_STEP"
EOF
    chmod +x "$probe_runner"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            ORCHESTRATOR_SOURCE_FOR_TEST="1" \
            bash "$probe_runner" "$TARGET_SCRIPT" 2>&1
    )" || RUN_EXIT_CODE=$?
}

run_run_b_stripe_key_selection_probe() {
    local probe_runner
    probe_runner="$TEST_TMP_DIR/run_b_stripe_key_probe.sh"
    cat > "$probe_runner" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
target_script="$1"

source "$target_script"

mark_failure() {
    FLOW_FAILED=1
    FLOW_FAILURE_STEP="$1"
    FLOW_FAILURE_DETAIL="$2"
    return 0
}

resolve_stripe_secret_key() {
    printf 'sk_test_generic_key\n'
}

stripe_secret_key_has_allowed_prefix() {
    return 0
}

STRIPE_SECRET_KEY_flapjack_cloud="sk_test_cloud_key"
FLOW_FAILED=0
FLOW_FAILURE_STEP=""
FLOW_FAILURE_DETAIL=""

if load_run_b_stripe_transport; then
    echo "rc=0"
else
    rc=$?
    echo "rc=$rc"
fi
echo "effective=$STRIPE_SECRET_KEY_EFFECTIVE"
echo "flow_failed=$FLOW_FAILED"
echo "flow_step=$FLOW_FAILURE_STEP"
EOF
    chmod +x "$probe_runner"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            ORCHESTRATOR_SOURCE_FOR_TEST="1" \
            bash "$probe_runner" "$TARGET_SCRIPT" 2>&1
    )" || RUN_EXIT_CODE=$?
}

trace_shows_sourced_top_level_function_dispatch() {
    local trace_output="$1"
    local sourced_script_path="$2"
    local line command first_token
    while IFS= read -r line; do
        if [[ "$line" != *"TRACE:${sourced_script_path}:"*":TOP:"* ]]; then
            continue
        fi
        command="${line##*:TOP:}"
        command="${command#"${command%%[![:space:]]*}"}"
        if [ -z "$command" ]; then
            continue
        fi
        if [[ "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            continue
        fi
        first_token="${command%%[[:space:];]*}"
        case "$first_token" in
            "" | "if" | "then" | "elif" | "else" | "fi" | "for" | "while" | "until" | "do" | "done" | \
            "case" | "esac" | "select" | "in" | "function" | "local" | "declare" | "typeset" | \
            "readonly" | "export" | "unset" | "return" | "exit" | "source" | "." | "trap" | "set")
                continue
                ;;
        esac
        if [[ "$command" =~ ^[A-Za-z_][A-Za-z0-9_]*([[:space:]].*)?$ ]]; then
            return 0
        fi
    done <<< "$trace_output"
    return 1
}

# Run the target script under a sanitized env that strips every secret-bearing
# variable. If any code path requires Stripe/admin keys to run dry-run, the
# invocation will fail and the assertion locks the "dry-run is hermetic" contract.
#
# Output: writes RUN_STDOUT (combined stdout+stderr) and RUN_EXIT_CODE globals.
run_target_with_minimal_env() {
    local mode="$1"
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i \
            PATH="/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_TMP_DIR" \
            TMPDIR="$TEST_TMP_DIR" \
            bash "$TARGET_SCRIPT" "$mode" 2>&1
    )" || RUN_EXIT_CODE=$?
}

# Each test is structured so that when the target script is missing, the
# assertion still fails with a message naming the locked contract — not a
# harness wiring error.

test_target_script_exists_and_is_executable() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[script-exists]: scripts/validate_full_vm_lifecycle_prod.sh must exist (Stage 2 will create it)"
        return
    fi
    if [ ! -x "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[script-executable]: scripts/validate_full_vm_lifecycle_prod.sh must be executable (chmod +x)"
        return
    fi
    pass "target orchestrator script exists and is executable"
}

test_dry_run_succeeds_without_secret_env_vars() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[dry-run-no-secrets]: dry-run must exit 0 with no Stripe/admin/payment env vars set — script missing"
        return
    fi
    run_target_with_minimal_env "dry-run"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[dry-run-no-secrets]: dry-run must exit 0 with no Stripe/admin/payment env vars set"
    assert_contains "$RUN_STDOUT" "dry-run" \
        "CONTRACT[dry-run-banner]: dry-run output must announce dry-run mode"
}

test_dry_run_does_not_require_env_secret_file() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[dry-run-no-env-secret]: dry-run must not depend on .env.secret — script missing"
        return
    fi
    run_target_with_minimal_env "dry-run"
    assert_not_contains "$RUN_STDOUT" ".env.secret" \
        "CONTRACT[dry-run-no-env-secret]: dry-run must not read or require .env.secret"
    assert_not_contains "$RUN_STDOUT" "missing secret" \
        "CONTRACT[dry-run-no-secret-error]: dry-run must not error on missing secrets"
}

test_run_a_mode_is_recognized() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[mode-run-a]: 'run-a' must be a recognized CLI mode — script missing"
        return
    fi
    run_target_with_minimal_env "run-a"
    assert_contains "$RUN_STDOUT" "run-a" \
        "CONTRACT[mode-run-a]: invoking run-a must dispatch into run-a mode (mode-specific output includes 'run-a')"
    assert_not_contains "$RUN_STDOUT" "unknown" \
        "CONTRACT[mode-run-a]: invoking run-a must not be treated as an unknown mode"
    assert_not_contains "$RUN_STDOUT" "Usage" \
        "CONTRACT[mode-run-a]: invoking run-a must not fall back to top-level usage output"
}

test_run_b_mode_is_recognized() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[mode-run-b]: 'run-b' must be a recognized CLI mode — script missing"
        return
    fi
    run_target_with_minimal_env "run-b"
    assert_contains "$RUN_STDOUT" "run-b" \
        "CONTRACT[mode-run-b]: invoking run-b must dispatch into run-b mode (mode-specific output includes 'run-b')"
    assert_not_contains "$RUN_STDOUT" "unknown" \
        "CONTRACT[mode-run-b]: invoking run-b must not be treated as an unknown mode"
    assert_not_contains "$RUN_STDOUT" "Usage" \
        "CONTRACT[mode-run-b]: invoking run-b must not fall back to top-level usage output"
}

test_unknown_mode_fails_with_usage() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[mode-unknown]: unknown CLI mode must exit non-zero with usage message — script missing"
        return
    fi
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i PATH="/usr/bin:/bin:/usr/local/bin" HOME="$TEST_TMP_DIR" TMPDIR="$TEST_TMP_DIR" \
            bash "$TARGET_SCRIPT" --bogus-mode 2>&1
    )" || RUN_EXIT_CODE=$?
    assert_ne "$RUN_EXIT_CODE" "0" \
        "CONTRACT[mode-unknown-exit]: unknown CLI mode must exit non-zero"
    assert_contains "$RUN_STDOUT" "Usage" \
        "CONTRACT[mode-unknown-usage]: unknown CLI mode must print usage"
}

test_no_mode_fails_with_usage() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[mode-missing]: invoking with no mode must exit non-zero with usage — script missing"
        return
    fi
    RUN_EXIT_CODE=0
    RUN_STDOUT="$(
        env -i PATH="/usr/bin:/bin:/usr/local/bin" HOME="$TEST_TMP_DIR" TMPDIR="$TEST_TMP_DIR" \
            bash "$TARGET_SCRIPT" 2>&1
    )" || RUN_EXIT_CODE=$?
    assert_ne "$RUN_EXIT_CODE" "0" \
        "CONTRACT[mode-missing-exit]: missing CLI mode must exit non-zero"
    assert_contains "$RUN_STDOUT" "Usage" \
        "CONTRACT[mode-missing-usage]: missing CLI mode must print usage"
}

test_trap_cleanup_is_declared_and_re_entry_safe() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[trap-cleanup-declared]: script must register 'trap cleanup EXIT' — script missing"
        fail "CONTRACT[trap-cleanup-re-entry-safe]: cleanup function must be guarded against double-execution (re-entry safe) — script missing"
        return
    fi
    local content cleanup_body
    content="$(cat "$TARGET_SCRIPT")"
    if script_registers_cleanup_exit_trap "$TARGET_SCRIPT"; then
        pass "CONTRACT[trap-cleanup-declared]: script must register 'trap cleanup EXIT' for deterministic teardown"
    else
        fail "CONTRACT[trap-cleanup-declared]: script must register 'trap cleanup EXIT' on a live executable line"
    fi
    cleanup_body="$(extract_cleanup_body "$content")"
    if cleanup_body_has_reentry_guard "$cleanup_body"; then
        pass "CONTRACT[trap-cleanup-re-entry-safe]: cleanup function declares a re-entry guard"
    else
        fail "CONTRACT[trap-cleanup-re-entry-safe]: cleanup function must guard against double-execution (sentinel var or 'trap - EXIT' inside cleanup)"
    fi
}

test_trap_cleanup_runs_exactly_once_on_failure_path() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[trap-cleanup-once-on-failure]: cleanup must run exactly once on failure paths — script missing"
        return
    fi
    local content cleanup_body
    content="$(cat "$TARGET_SCRIPT")"
    cleanup_body="$(extract_cleanup_body "$content")"
    if [ -z "$cleanup_body" ]; then
        fail "CONTRACT[trap-cleanup-once-on-failure]: script must define cleanup() and make it re-entry safe so failure-path cleanup runs once"
        return
    fi
    if cleanup_body_has_reentry_guard "$cleanup_body"; then
        pass "CONTRACT[trap-cleanup-once-on-failure]: cleanup() contains a re-entry guard to ensure failure-path cleanup executes once"
    else
        fail "CONTRACT[trap-cleanup-once-on-failure]: cleanup() must contain a re-entry guard (sentinel var or 'trap - EXIT') so failure-path cleanup executes once"
    fi
}

test_script_is_sourceable_without_running_main() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[sourceable]: script must support being sourced for tests without executing main flow — script missing"
        return
    fi
    make_test_tmp_dir
    run_source_probe_with_trace "$TARGET_SCRIPT"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[sourceable]: sourcing script with ORCHESTRATOR_SOURCE_FOR_TEST=1 must not execute main flow"
    assert_contains "$RUN_STDOUT" "source-ok" \
        "CONTRACT[sourceable]: script must be source-safe under test harness sourcing"
    assert_not_contains "$RUN_STDOUT" "Usage" \
        "CONTRACT[sourceable]: sourcing must not print top-level CLI usage"
    if trace_shows_sourced_top_level_function_dispatch "$SOURCE_TRACE_OUTPUT" "$TARGET_SCRIPT"; then
        fail "CONTRACT[sourceable-no-main-dispatch]: sourcing under test guard must not execute top-level function dispatch (e.g., main)"
    else
        pass "CONTRACT[sourceable-no-main-dispatch]: sourcing under test guard does not execute top-level function dispatch"
    fi

    run_source_probe_and_print_exit_trap "$TARGET_SCRIPT"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[sourceable-no-trap-side-effect]: sourcing script must allow trap inspection without execution failure"
    assert_not_contains "$RUN_STDOUT" "cleanup" \
        "CONTRACT[sourceable-no-trap-side-effect]: sourcing script must not leave 'trap cleanup EXIT' in the caller shell"
}

test_script_sources_http_json_seam() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[seam-http-json]: script must source scripts/lib/http_json.sh — script missing"
        return
    fi
    if file_sources_repo_owned_seam "$TARGET_SCRIPT" "http_json.sh"; then
        pass "CONTRACT[seam-http-json]: script sources scripts/lib/http_json.sh"
    else
        fail "CONTRACT[seam-http-json]: script must source lib/http_json.sh via source or '.' (use api_json_call/capture_json_response)"
    fi
}

test_script_sources_env_seam() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[seam-env]: script must source scripts/lib/env.sh — script missing"
        return
    fi
    if file_sources_repo_owned_seam "$TARGET_SCRIPT" "env.sh"; then
        pass "CONTRACT[seam-env]: script sources scripts/lib/env.sh"
    else
        fail "CONTRACT[seam-env]: script must source lib/env.sh via source or '.' (use load_env_file/load_layered_env_files)"
    fi
}

test_script_sources_privacy_client_seam() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[seam-privacy-client]: script must source scripts/lib/privacy_com_client.sh for optional-gated card lifecycle — script missing"
        return
    fi
    if file_sources_repo_owned_seam "$TARGET_SCRIPT" "privacy_com_client.sh"; then
        pass "CONTRACT[seam-privacy-client]: script sources scripts/lib/privacy_com_client.sh"
    else
        fail "CONTRACT[seam-privacy-client]: script must source scripts/lib/privacy_com_client.sh for optional-gated privacy card lifecycle"
    fi
}

test_script_sources_staging_db_seam() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[seam-staging-db]: script must source scripts/lib/staging_db.sh for raw DB lifecycle evidence — script missing"
        return
    fi
    if file_sources_repo_owned_seam "$TARGET_SCRIPT" "staging_db.sh"; then
        pass "CONTRACT[seam-staging-db]: script sources scripts/lib/staging_db.sh"
    else
        fail "CONTRACT[seam-staging-db]: script must source scripts/lib/staging_db.sh for raw DB lifecycle evidence"
    fi
}

test_load_orchestration_env_clears_ambient_aws_exports() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[load-env-clears-ambient-aws]: load_orchestration_env must unset ambient AWS exports before loading secret files — script missing"
        return
    fi
    if grep -Eq 'unset[[:space:]]+AWS_ACCESS_KEY_ID[[:space:]]+AWS_SECRET_ACCESS_KEY[[:space:]]+AWS_SESSION_TOKEN[[:space:]]+AWS_PROFILE[[:space:]]+AWS_DEFAULT_REGION[[:space:]]+AWS_REGION' "$TARGET_SCRIPT"; then
        pass "CONTRACT[load-env-clears-ambient-aws]: load_orchestration_env clears ambient AWS exports before loading layered env files"
    else
        fail "CONTRACT[load-env-clears-ambient-aws]: load_orchestration_env must unset AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY/AWS_SESSION_TOKEN/AWS_PROFILE/AWS_DEFAULT_REGION/AWS_REGION before load_layered_env_files"
    fi
}

test_run_b_sequences_paid_invoice_steps() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[run-b-paid-sequence]: run-b must attach a reusable payment method before finalize, perform any out-of-band pay handoff after finalize, and wait for paid convergence last — script missing"
        return
    fi

    run_flow_order_probe "run-b"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[run-b-paid-sequence]: flow-order probe for run-b must succeed"
    assert_contains "$RUN_STDOUT" "prepare_run_b_payment" \
        "CONTRACT[run-b-payment-attach-step]: run-b must include a dedicated payment-attach/default step"
    assert_contains "$RUN_STDOUT" "pay_invoice_out_of_band" \
        "CONTRACT[run-b-out-of-band-step]: run-b must execute the out-of-band payment seam after finalize"
    assert_contains "$RUN_STDOUT" "wait_for_paid_invoice" \
        "CONTRACT[run-b-paid-wait-step]: run-b must wait for paid invoice convergence"
    if python3 - "$RUN_STDOUT" <<'PY'
import sys

steps = [line.strip() for line in sys.argv[1].splitlines() if line.strip()]
required = ["prepare_run_b_payment", "finalize_invoice", "pay_invoice_out_of_band", "wait_for_paid_invoice"]
positions = {}
for step in required:
    try:
        positions[step] = steps.index(step)
    except ValueError:
        raise SystemExit(1)
raise SystemExit(
    0
    if positions["prepare_run_b_payment"] < positions["finalize_invoice"] < positions["pay_invoice_out_of_band"] < positions["wait_for_paid_invoice"]
    else 1
)
PY
    then
        pass "CONTRACT[run-b-paid-sequence-order]: run-b attaches payment before finalize, performs any out-of-band pay after finalize, and waits for paid status last"
    else
        fail "CONTRACT[run-b-paid-sequence-order]: run-b must attach payment before finalize, run out-of-band pay after finalize, and wait for paid status last"
    fi
}

test_run_a_skips_run_b_only_paid_steps() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[run-a-no-paid-branch]: run-a must not execute run-b-only payment attach or paid-wait steps — script missing"
        return
    fi

    run_flow_order_probe "run-a"
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[run-a-no-paid-branch]: flow-order probe for run-a must succeed"
    assert_not_contains "$RUN_STDOUT" "prepare_run_b_payment" \
        "CONTRACT[run-a-no-payment-attach]: run-a must not execute run-b payment attach/default logic"
    assert_not_contains "$RUN_STDOUT" "wait_for_paid_invoice" \
        "CONTRACT[run-a-no-paid-wait]: run-a must not wait for paid invoice convergence"
}

test_index_create_retries_transient_504() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[index-create-retry-504]: index create must retry transient 504 before failing — script missing"
        return
    fi
    run_index_create_retry_probe
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[index-create-retry-504]: retry probe harness must execute successfully"
    assert_contains "$RUN_STDOUT" "rc=0" \
        "CONTRACT[index-create-retry-504]: run_index_create_step must recover when first attempt is HTTP 504 and second succeeds"
    assert_contains "$RUN_STDOUT" "calls=2" \
        "CONTRACT[index-create-retry-504]: run_index_create_step must retry at least once after transient HTTP 504"
    assert_contains "$RUN_STDOUT" "created=1" \
        "CONTRACT[index-create-retry-504]: successful retry must mark CANARY_INDEX_CREATED=1"
    assert_contains "$RUN_STDOUT" "flow_failed=0" \
        "CONTRACT[index-create-retry-504]: transient 504 recovery must not leave FLOW_FAILED set"
}

test_run_b_prefers_flapjack_cloud_stripe_key() {
    make_test_tmp_dir
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[run-b-stripe-key-precedence]: run-b Stripe transport must prefer flapjack cloud key when present — script missing"
        return
    fi
    run_run_b_stripe_key_selection_probe
    assert_eq "$RUN_EXIT_CODE" "0" \
        "CONTRACT[run-b-stripe-key-precedence]: stripe key probe harness must execute successfully"
    assert_contains "$RUN_STDOUT" "rc=0" \
        "CONTRACT[run-b-stripe-key-precedence]: load_run_b_stripe_transport must succeed when flapjack cloud key is available"
    assert_contains "$RUN_STDOUT" "effective=sk_test_cloud_key" \
        "CONTRACT[run-b-stripe-key-precedence]: run-b must use STRIPE_SECRET_KEY_flapjack_cloud before generic STRIPE_SECRET_KEY"
    assert_contains "$RUN_STDOUT" "flow_failed=0" \
        "CONTRACT[run-b-stripe-key-precedence]: selecting flapjack cloud key must not mark transport failure"
}

test_cleanup_probe_accepts_function_keyword_form() {
    local sample_script sample_cleanup
    sample_script=$'function cleanup() {\n    trap - EXIT\n}\n'
    sample_cleanup="$(extract_cleanup_body "$sample_script")"
    assert_ne "$sample_cleanup" "" \
        "CONTRACT[probe-cleanup-accepts-function-keyword]: cleanup extractor must support 'function cleanup() { ... }' declarations"
}

test_cleanup_probe_accepts_multiline_header_form() {
    local sample_script sample_cleanup
    sample_script=$'function cleanup()\n{\n    trap - EXIT\n}\n'
    sample_cleanup="$(extract_cleanup_body "$sample_script")"
    assert_ne "$sample_cleanup" "" \
        "CONTRACT[probe-cleanup-accepts-multiline-header]: cleanup extractor must support declaration headers where '{' is on the next line"
}

test_cleanup_probe_rejects_comment_only_guard_text() {
    local sample_script sample_body
    sample_script=$'cleanup() {\n    # CLEANUP_RAN=1\n    # trap - EXIT\n    return 0\n}\n'
    sample_body="$(extract_cleanup_body "$sample_script")"
    if cleanup_body_has_reentry_guard "$sample_body"; then
        fail "CONTRACT[probe-cleanup-requires-executable-guard]: cleanup guard probe must ignore comment-only guard text"
    else
        pass "CONTRACT[probe-cleanup-requires-executable-guard]: cleanup guard probe ignores comment-only guard text"
    fi
}

test_function_detector_accepts_multiline_header_form() {
    make_test_tmp_dir
    local multiline_function_script
    multiline_function_script="$TEST_TMP_DIR/multiline_function.sh"
    cat > "$multiline_function_script" <<'EOF'
#!/usr/bin/env bash
api_json_call()
{
    return 0
}
EOF
    if file_declares_function_name "$multiline_function_script" "api_json_call"; then
        pass "CONTRACT[probe-function-detector-accepts-multiline-header]: function detector accepts multiline declaration headers"
    else
        fail "CONTRACT[probe-function-detector-accepts-multiline-header]: function detector must detect valid multiline declaration headers"
    fi
}

test_sourceable_probe_rejects_sourced_main_execution() {
    make_test_tmp_dir
    local synthetic_target
    synthetic_target="$TEST_TMP_DIR/synthetic_target.sh"
    cat > "$synthetic_target" <<'EOF'
#!/usr/bin/env bash
main() {
    echo "main-ran-while-sourced"
    return 0
}

main "$@"
EOF

    run_source_probe_with_trace "$synthetic_target"
    if trace_shows_sourced_top_level_function_dispatch "$SOURCE_TRACE_OUTPUT" "$synthetic_target"; then
        pass "CONTRACT[probe-sourceable-rejects-sourced-main-exec]: sourceability probe detects sourced main-flow execution"
    else
        fail "CONTRACT[probe-sourceable-rejects-sourced-main-exec]: sourceability probe must detect sourced main-flow execution"
    fi
}

test_seam_probe_accepts_repo_owned_script_dir_source() {
    make_test_tmp_dir
    local script_with_script_dir_source
    script_with_script_dir_source="$TEST_TMP_DIR/script_dir_source.sh"
    cat > "$script_with_script_dir_source" <<'EOF'
#!/usr/bin/env bash
source "${SCRIPT_DIR}/lib/http_json.sh"
EOF
    if file_sources_repo_owned_seam "$script_with_script_dir_source" "http_json.sh"; then
        pass "CONTRACT[probe-seam-accepts-script-dir-source]: seam probe accepts \${SCRIPT_DIR}/lib/http_json.sh"
    else
        fail "CONTRACT[probe-seam-accepts-script-dir-source]: seam probe must accept \${SCRIPT_DIR}/lib/http_json.sh as repo-owned seam"
    fi
}

test_seam_probe_rejects_commented_out_and_non_repo_sources() {
    make_test_tmp_dir
    local commented_script vendor_script

    commented_script="$TEST_TMP_DIR/commented_source.sh"
    cat > "$commented_script" <<'EOF'
#!/usr/bin/env bash
# source "$SCRIPT_DIR/lib/http_json.sh"
EOF
    if file_sources_repo_owned_seam "$commented_script" "http_json.sh"; then
        fail "CONTRACT[probe-seam-rejects-commented-source]: seam probe must ignore commented-out source lines"
    else
        pass "CONTRACT[probe-seam-rejects-commented-source]: seam probe ignores commented-out source lines"
    fi

    vendor_script="$TEST_TMP_DIR/vendor_source.sh"
    cat > "$vendor_script" <<'EOF'
#!/usr/bin/env bash
source "vendor/lib/http_json.sh"
EOF
    if file_sources_repo_owned_seam "$vendor_script" "http_json.sh"; then
        fail "CONTRACT[probe-seam-rejects-non-repo-path]: seam probe must reject non-repo lib/http_json.sh paths"
    else
        pass "CONTRACT[probe-seam-rejects-non-repo-path]: seam probe rejects non-repo lib/http_json.sh paths"
    fi
}

test_script_does_not_inline_curl_post() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-inline-curl-post]: script must not inline curl POST calls — script missing"
        return
    fi
    if grep -Eq 'curl[[:space:]]+-s[S]?[[:space:]]+-X[[:space:]]+POST' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-curl-post]: script must not inline 'curl -s -X POST' — use api_json_call/admin_call from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-inline-curl-post]: script does not inline curl POST calls"
    fi
}

test_script_does_not_inline_curl_delete() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-inline-curl-delete]: script must not inline curl DELETE calls — script missing"
        return
    fi
    if grep -Eq 'curl[[:space:]]+-s[S]?[[:space:]]+-X[[:space:]]+DELETE' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-curl-delete]: script must not inline 'curl -s -X DELETE' — use api_json_call from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-inline-curl-delete]: script does not inline curl DELETE calls"
    fi
}

test_script_does_not_inline_env_file_parser() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-inline-env-parser]: script must not inline env-file parsing — script missing"
        return
    fi
    # Common ad-hoc env-parsing patterns we explicitly forbid in favor of load_env_file.
    if grep -Eq 'while[[:space:]]+IFS=.*read.*\.env' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-env-parser-loop]: script must not loop-parse .env files — use load_env_file from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-inline-env-parser-loop]: script does not loop-parse .env files"
    fi
    if grep -Eq '\$\(grep[[:space:]].*\.env.*[[:space:]]*\|[[:space:]]*cut' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-env-parser-grep-cut]: script must not parse .env with grep|cut — use load_env_file from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-inline-env-parser-grep-cut]: script does not grep|cut-parse .env files"
    fi
    if grep -Eq '^[[:space:]]*export[[:space:]]+\$\(' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-env-export-subshell]: script must not 'export \$(...)' .env contents — use load_env_file from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-inline-env-export-subshell]: script does not export .env contents via subshell"
    fi
}

test_script_does_not_inline_privacy_http_calls() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-inline-privacy-http]: script must not inline Privacy HTTP calls — script missing"
        return
    fi
    if grep -Eq 'api\.privacy\.com|/v1/cards' "$TARGET_SCRIPT"; then
        fail "CONTRACT[no-inline-privacy-http]: script must not inline Privacy card endpoints — use scripts/lib/privacy_com_client.sh"
    else
        pass "CONTRACT[no-inline-privacy-http]: script does not inline Privacy card endpoints"
    fi
}

test_script_does_not_redeclare_http_seam_functions() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-redeclare-http-seams]: script must not redeclare shared HTTP seam functions — script missing"
        return
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "api_json_call"; then
        fail "CONTRACT[no-redeclare-api-json-call]: script must not redeclare api_json_call — reuse from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-redeclare-api-json-call]: script does not redeclare api_json_call"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "admin_call"; then
        fail "CONTRACT[no-redeclare-admin-call]: script must not redeclare admin_call — reuse from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-redeclare-admin-call]: script does not redeclare admin_call"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "tenant_call"; then
        fail "CONTRACT[no-redeclare-tenant-call]: script must not redeclare tenant_call — reuse from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-redeclare-tenant-call]: script does not redeclare tenant_call"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "capture_json_response"; then
        fail "CONTRACT[no-redeclare-capture-json-response]: script must not redeclare capture_json_response — reuse from scripts/lib/http_json.sh"
    else
        pass "CONTRACT[no-redeclare-capture-json-response]: script does not redeclare capture_json_response"
    fi
}

test_script_does_not_redeclare_env_seam_functions() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-redeclare-env-seams]: script must not redeclare shared env seam functions — script missing"
        return
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "load_env_file"; then
        fail "CONTRACT[no-redeclare-load-env-file]: script must not redeclare load_env_file — reuse from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-redeclare-load-env-file]: script does not redeclare load_env_file"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "load_layered_env_files"; then
        fail "CONTRACT[no-redeclare-load-layered-env-files]: script must not redeclare load_layered_env_files — reuse from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-redeclare-load-layered-env-files]: script does not redeclare load_layered_env_files"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "parse_env_assignment_line"; then
        fail "CONTRACT[no-redeclare-parse-env-assignment-line]: script must not redeclare parse_env_assignment_line — reuse from scripts/lib/env.sh"
    else
        pass "CONTRACT[no-redeclare-parse-env-assignment-line]: script does not redeclare parse_env_assignment_line"
    fi
}

test_script_does_not_redeclare_privacy_client_functions() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[no-redeclare-privacy-functions]: script must not redeclare privacy client seam functions — script missing"
        return
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "privacy_com_create_card"; then
        fail "CONTRACT[no-redeclare-privacy-create-card]: script must not redeclare privacy_com_create_card — reuse scripts/lib/privacy_com_client.sh"
    else
        pass "CONTRACT[no-redeclare-privacy-create-card]: script does not redeclare privacy_com_create_card"
    fi
    if file_declares_function_name "$TARGET_SCRIPT" "privacy_com_close_card"; then
        fail "CONTRACT[no-redeclare-privacy-close-card]: script must not redeclare privacy_com_close_card — reuse scripts/lib/privacy_com_client.sh"
    else
        pass "CONTRACT[no-redeclare-privacy-close-card]: script does not redeclare privacy_com_close_card"
    fi
}

test_invoice_id_validation_is_not_numeric_only() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[invoice-id-uuid]: invoice id validation must allow UUID identifiers — script missing"
        return
    fi
    local invoice_validation_line
    invoice_validation_line="$(grep -E 'require_safe_identifier[[:space:]]+"invoice_id"' "$TARGET_SCRIPT" || true)"
    if [[ "$invoice_validation_line" == *"'^[0-9]+$'"* ]]; then
        fail "CONTRACT[invoice-id-uuid]: invoice id validation must not be numeric-only because prod invoices are UUIDs"
    else
        pass "CONTRACT[invoice-id-uuid]: invoice id validation is not numeric-only"
    fi
}

test_payment_method_id_validation_allows_underscore() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[payment-method-id-underscore]: payment method validation must allow Stripe fixture IDs — script missing"
        return
    fi
    local payment_method_validation_line
    payment_method_validation_line="$(grep -E 'require_safe_identifier[[:space:]]+"payment_method_id"' "$TARGET_SCRIPT" || true)"
    if [[ "$payment_method_validation_line" == *"'^pm_[A-Za-z0-9]+$'"* ]]; then
        fail "CONTRACT[payment-method-id-underscore]: payment method validation must allow underscores for IDs like pm_card_visa"
    else
        pass "CONTRACT[payment-method-id-underscore]: payment method validation allows underscore-bearing Stripe IDs"
    fi
}

test_post_cleanup_invoice_query_is_guarded_for_empty_invoice_id() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[post-cleanup-invoice-guard]: post-cleanup invoice SQL must be conditional on captured invoice id — script missing"
        return
    fi
    if awk '
        /^capture_stage5_post_cleanup_evidence\(\)[[:space:]]*\{/ { in_fn = 1; next }
        in_fn && /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { in_fn = 0 }
        in_fn && /db_post_cleanup_invoice\.sql\.txt/ { saw_invoice_query = 1 }
        in_fn && /if \[ -n "\$LIFECYCLE_INVOICE_ID" \]; then/ { saw_invoice_guard = 1 }
        END {
            if (saw_invoice_query == 1 && saw_invoice_guard == 1) {
                exit 0
            }
            exit 1
        }
    ' "$TARGET_SCRIPT"; then
        pass "CONTRACT[post-cleanup-invoice-guard]: post-cleanup invoice SQL is guarded by non-empty invoice id"
    else
        fail "CONTRACT[post-cleanup-invoice-guard]: post-cleanup invoice SQL must be skipped when LIFECYCLE_INVOICE_ID is empty"
    fi
}

test_pre_cleanup_invoice_query_is_guarded_for_empty_invoice_id() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[pre-cleanup-invoice-guard]: pre-cleanup invoice SQL must be conditional on captured invoice id — script missing"
        return
    fi
    if awk '
        /^capture_stage5_pre_cleanup_evidence\(\)[[:space:]]*\{/ { in_fn = 1; next }
        in_fn && /^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{/ { in_fn = 0 }
        in_fn && /db_pre_cleanup_invoice\.sql\.txt/ { saw_invoice_query = 1 }
        in_fn && /if \[ -n "\$LIFECYCLE_INVOICE_ID" \]; then/ { saw_invoice_guard = 1 }
        END {
            if (saw_invoice_query == 1 && saw_invoice_guard == 1) {
                exit 0
            }
            exit 1
        }
    ' "$TARGET_SCRIPT"; then
        pass "CONTRACT[pre-cleanup-invoice-guard]: pre-cleanup invoice SQL is guarded by non-empty invoice id"
    else
        fail "CONTRACT[pre-cleanup-invoice-guard]: pre-cleanup invoice SQL must be skipped when LIFECYCLE_INVOICE_ID is empty"
    fi
}

test_script_emits_stage6_raw_evidence_filenames() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[stage6-evidence-filenames]: script must emit raw AWS/DB lifecycle artifacts — script missing"
        return
    fi
    if grep -Fq "aws_verify_email_head_object.json" "$TARGET_SCRIPT"; then
        pass "CONTRACT[stage6-aws-evidence-file]: script references raw AWS head-object evidence filename"
    else
        fail "CONTRACT[stage6-aws-evidence-file]: script must emit aws_verify_email_head_object.json"
    fi
    if grep -Fq "db_post_cleanup_tenant.sql.txt" "$TARGET_SCRIPT"; then
        pass "CONTRACT[stage6-db-post-cleanup-file]: script references raw post-cleanup DB tenant evidence filename"
    else
        fail "CONTRACT[stage6-db-post-cleanup-file]: script must emit db_post_cleanup_tenant.sql.txt"
    fi
    if grep -Fq "db_pre_cleanup_invoice.sql.txt" "$TARGET_SCRIPT"; then
        pass "CONTRACT[stage6-db-pre-cleanup-file]: script references raw pre-cleanup DB invoice evidence filename"
    else
        fail "CONTRACT[stage6-db-pre-cleanup-file]: script must emit db_pre_cleanup_invoice.sql.txt"
    fi
}

test_script_uses_staging_db_run_sql_for_stage6_db_evidence() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        fail "CONTRACT[stage6-db-evidence-owner]: script must use staging_db_run_sql for raw DB lifecycle evidence — script missing"
        return
    fi
    if grep -Fq "staging_db_run_sql" "$TARGET_SCRIPT"; then
        pass "CONTRACT[stage6-db-evidence-owner]: script uses staging_db_run_sql owner seam"
    else
        fail "CONTRACT[stage6-db-evidence-owner]: script must use staging_db_run_sql owner seam for raw DB lifecycle evidence"
    fi
}

main() {
    echo "=== probe_full_vm_lifecycle_script_test.sh ==="
    echo "Target: $TARGET_SCRIPT"
    echo ""

    test_target_script_exists_and_is_executable
    test_dry_run_succeeds_without_secret_env_vars
    test_dry_run_does_not_require_env_secret_file
    test_run_a_mode_is_recognized
    test_run_b_mode_is_recognized
    test_unknown_mode_fails_with_usage
    test_no_mode_fails_with_usage
    test_trap_cleanup_is_declared_and_re_entry_safe
    test_trap_cleanup_runs_exactly_once_on_failure_path
    test_cleanup_probe_accepts_function_keyword_form
    test_cleanup_probe_accepts_multiline_header_form
    test_cleanup_probe_rejects_comment_only_guard_text
    test_function_detector_accepts_multiline_header_form
    test_sourceable_probe_rejects_sourced_main_execution
    test_seam_probe_accepts_repo_owned_script_dir_source
    test_script_is_sourceable_without_running_main
    test_script_sources_http_json_seam
    test_script_sources_env_seam
    test_script_sources_privacy_client_seam
    test_script_sources_staging_db_seam
    test_load_orchestration_env_clears_ambient_aws_exports
    test_run_b_sequences_paid_invoice_steps
    test_run_a_skips_run_b_only_paid_steps
    test_index_create_retries_transient_504
    test_run_b_prefers_flapjack_cloud_stripe_key
    test_invoice_id_validation_is_not_numeric_only
    test_payment_method_id_validation_allows_underscore
    test_post_cleanup_invoice_query_is_guarded_for_empty_invoice_id
    test_pre_cleanup_invoice_query_is_guarded_for_empty_invoice_id
    test_script_emits_stage6_raw_evidence_filenames
    test_script_uses_staging_db_run_sql_for_stage6_db_evidence
    test_seam_probe_rejects_commented_out_and_non_repo_sources
    test_script_does_not_inline_curl_post
    test_script_does_not_inline_curl_delete
    test_script_does_not_inline_env_file_parser
    test_script_does_not_inline_privacy_http_calls
    test_script_does_not_redeclare_http_seam_functions
    test_script_does_not_redeclare_env_seam_functions
    test_script_does_not_redeclare_privacy_client_functions

    run_test_summary
}

main "$@"
