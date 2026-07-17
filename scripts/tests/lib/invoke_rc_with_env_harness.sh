#!/usr/bin/env bash
# Shared harness helpers for invoke_rc_with_env shell tests.
#
# Callers must define:
#   REPO_ROOT
#   TARGET_SCRIPT

SCRIPT_DIR_HARNESS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=test_runner.sh
source "$SCRIPT_DIR_HARNESS/test_runner.sh"
# shellcheck source=assertions.sh
source "$SCRIPT_DIR_HARNESS/assertions.sh"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR_HARNESS/test_helpers.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
RUN_LOADER_STDOUT=""
RUN_LOADER_STDERR=""
RUN_LOADER_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
TEST_FACADE_ENV=()
CLEANUP_DIRS=()
INVOKE_RC_HARNESS_REPO_ROOT="${REPO_ROOT:?}"

cleanup_test_workspaces() {
    local d
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup_test_workspaces EXIT

shell_quote_for_script() {
    local quoted
    printf -v quoted '%q' "$1"
    printf '%s\n' "$quoted"
}

is_valid_shell_variable_name() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

is_safe_logged_test_credential() {
    case "$1" in
        AKIAINVOKERCWRAPPERTEST|GOODFILEKEY|REJECTEDFILEKEY)
            return 0
            ;;
    esac
    return 1
}

redact_logged_test_credential() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        printf '%s' ""
    elif is_safe_logged_test_credential "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "[REDACTED]"
    fi
}

write_mock_command() {
    local path="$1" label="$2" exit_code="${3:-99}"
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    write_mock_script "$path" "$(cat <<MOCK
set -euo pipefail
CALL_LOG=$quoted_log
echo "$label|\$*" >> "\$CALL_LOG"
exit $exit_code
MOCK
)"
}

write_env_capture_command() {
    local path="$1" label="$2" capture_path="$3"
    shift 3
    local quoted_log quoted_capture var
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"
    quoted_capture="$(shell_quote_for_script "$capture_path")"

    for var in "$@"; do
        if ! is_valid_shell_variable_name "$var"; then
            printf 'write_env_capture_command: invalid shell variable name %q\n' "$var" >&2
            return 1
        fi
    done

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf 'CALL_LOG=%s\n' "$quoted_log"
        printf 'CAPTURE_PATH=%s\n' "$quoted_capture"
        printf 'echo "%s|$*" >> "$CALL_LOG"\n' "$label"
        printf 'printf "label=%s\\n" >> "$CAPTURE_PATH"\n' "$label"
        printf 'printf "argv=" >> "$CAPTURE_PATH"\n'
        printf 'printf " %%q" "$@" >> "$CAPTURE_PATH"\n'
        printf 'printf "\\n" >> "$CAPTURE_PATH"\n'
        for var in "$@"; do
            printf 'if [ -n "${%s+x}" ]; then printf "%%s=%%s\\n" %q "$%s" >> "$CAPTURE_PATH"; else printf "%%s=<unset>\\n" %q >> "$CAPTURE_PATH"; fi\n' \
                "$var" "$var" "$var" "$var"
        done
        printf '%s\n' 'exit 0'
    } > "$path"
    chmod +x "$path"
}

write_side_effect_mocks() {
    mkdir -p "$TEST_WORKSPACE/bin" "$TEST_WORKSPACE/scripts/launch" "$TEST_WORKSPACE/scripts"
    write_mock_command "$TEST_WORKSPACE/bin/aws" "aws"
    write_mock_command "$TEST_WORKSPACE/bin/curl" "curl"
    write_mock_command "$TEST_WORKSPACE/bin/packer" "packer"
    write_mock_command "$TEST_WORKSPACE/bin/npm" "npm"
    write_mock_command "$TEST_WORKSPACE/bin/npx" "npx"
    write_mock_command "$TEST_WORKSPACE/bin/playwright" "playwright"
    write_mock_command "$TEST_WORKSPACE/scripts/e2e-preflight.sh" "e2e-preflight"
    write_mock_command "$TEST_WORKSPACE/scripts/staging_billing_dry_run.sh" "staging_billing_dry_run" 0
    write_mock_command "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" "run_full_backend_validation"
}

write_aws_sts_mock() {
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf 'CALL_LOG=%q\n' "$TEST_CALL_LOG"
        cat <<'MOCK'
is_safe_logged_test_credential() {
    case "$1" in
        AKIAINVOKERCWRAPPERTEST|GOODFILEKEY|REJECTEDFILEKEY)
            return 0
            ;;
    esac
    return 1
}
redact_logged_test_credential() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        printf '%s' ""
    elif is_safe_logged_test_credential "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "[REDACTED]"
    fi
}
echo "aws|$*|key=$(redact_logged_test_credential "${AWS_ACCESS_KEY_ID:-}")|session=$(redact_logged_test_credential "${AWS_SESSION_TOKEN:-}")" >> "$CALL_LOG"
if [[ "${1:-}" == "sts" && "${2:-}" == "get-caller-identity" ]]; then
    case "${AWS_ID_MOCK_MODE:-success}" in
        success)
            echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/wrapper","UserId":"u"}'
            exit 0 ;;
        invalid)
            echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.' >&2
            exit 254 ;;
        key_gated)
            if [[ "${AWS_ACCESS_KEY_ID:-}" == "${AWS_ID_MOCK_GOOD_KEY:-__none__}" && -z "${AWS_SESSION_TOKEN:-}" ]]; then
                echo '{"Account":"999999999999","Arn":"arn:aws:iam::999999999999:user/file-backed","UserId":"u"}'
                exit 0
            fi
            echo 'An error occurred (InvalidClientTokenId) when calling the GetCallerIdentity operation: The security token included in the request is invalid.' >&2
            exit 254 ;;
    esac
fi
echo "unexpected aws call: $*" >&2
exit 99
MOCK
    } > "$TEST_WORKSPACE/bin/aws"
    chmod +x "$TEST_WORKSPACE/bin/aws"
}

write_successful_curl_mock() {
    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'set -euo pipefail'
        printf 'CALL_LOG=%q\n' "$TEST_CALL_LOG"
        cat <<'MOCK'
echo "curl|$*" >> "$CALL_LOG"
exit 0
MOCK
    } > "$TEST_WORKSPACE/bin/curl"
    chmod +x "$TEST_WORKSPACE/bin/curl"
}

write_successful_staging_hydrator_mock() {
    cat > "$TEST_WORKSPACE/scripts/launch/hydrate_seeder_env_from_ssm.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'export ADMIN_KEY=admin_wrapper_contract'
printf '%s\n' 'export API_URL=http://127.0.0.1:3999'
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/launch/hydrate_seeder_env_from_ssm.sh"
}

install_successful_wrapper_preflight_stubs() {
    write_aws_sts_mock
    write_successful_curl_mock
    write_successful_staging_hydrator_mock
    add_facade_env "AWS_ID_MOCK_MODE=success"
}

copy_workspace_target_if_present() {
    mkdir -p "$TEST_WORKSPACE/scripts/launch" "$TEST_WORKSPACE/scripts/lib"
    cp "$INVOKE_RC_HARNESS_REPO_ROOT/scripts/lib"/*.sh "$TEST_WORKSPACE/scripts/lib/" 2>/dev/null || true
    cp "$INVOKE_RC_HARNESS_REPO_ROOT/scripts/lib"/*.py "$TEST_WORKSPACE/scripts/lib/" 2>/dev/null || true
    if [ -f "$TARGET_SCRIPT" ]; then
        cp "$TARGET_SCRIPT" "$TEST_WORKSPACE/scripts/launch/invoke_rc_with_env.sh"
        chmod +x "$TEST_WORKSPACE/scripts/launch/invoke_rc_with_env.sh"
    fi
    if [ -f "$INVOKE_RC_HARNESS_REPO_ROOT/scripts/launch/run_full_backend_validation.sh" ]; then
        cp "$INVOKE_RC_HARNESS_REPO_ROOT/scripts/launch/run_full_backend_validation.sh" "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh"
        chmod +x "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh"
        sed '/^main "\$@"$/d' "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" > "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation_functions.sh"
    fi
}

run_invoke_rc_with_env_setup_hook() {
    if declare -F invoke_rc_with_env_after_setup >/dev/null 2>&1; then
        invoke_rc_with_env_after_setup
    fi
}

setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")

    mkdir -p "$TEST_WORKSPACE/tmp" "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs" "$TEST_WORKSPACE/ops/packer"
    TEST_CALL_LOG="$TEST_WORKSPACE/tmp/calls.log"
    : > "$TEST_CALL_LOG"
    TEST_FACADE_ENV=()

    write_side_effect_mocks
    copy_workspace_target_if_present
    run_invoke_rc_with_env_setup_hook
}

add_facade_env() {
    TEST_FACADE_ENV+=("$1")
}

write_safe_credentials_env() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIAINVOKERCWRAPPERTEST
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_wrapper_contract
STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract
ENVFILE
}

write_paid_beta_full_pass_summary() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    local function_library registry_json
    function_library="$TEST_WORKSPACE/scripts/launch/run_full_backend_validation_functions.sh"
    if [ ! -f "$function_library" ]; then
        fail "run_full_backend_validation function library should exist before writing paid-beta summary"
        return 1
    fi
    registry_json="$(
        __RUN_FULL_BACKEND_VALIDATION_SOURCED=1 bash -c '
set -euo pipefail
source "$1"
emit_paid_beta_step_registry_json
' _ "$function_library"
    )" || {
        fail "paid-beta summary fixture should derive from canonical registry owner"
        return 1
    }
    python3 - "$path" "$registry_json" <<'PY'
import json
import sys
registry = json.loads(sys.argv[2])
steps = [step["name"] for step in registry["steps"]]
payload = {"mode": "paid_beta_rc", "ready": True, "verdict": "pass",
           "steps": [{"name": name, "status": "pass", "reason": ""} for name in steps]}
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

write_paid_beta_summary_with_step() {
    local path="$1" step_name="$2" status="$3" reason="$4"
    write_paid_beta_full_pass_summary "$path"
    python3 - "$path" "$step_name" "$status" "$reason" <<'PY'
import json
import sys
path, step_name, status, reason = sys.argv[1:5]
with open(path, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
for step in payload["steps"]:
    if step["name"] == step_name:
        step["status"] = status
        step["reason"] = reason
        break
else:
    payload["steps"].append({"name": step_name, "status": status, "reason": reason})
payload["ready"] = False
payload["verdict"] = "fail"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

assert_runner_emitted_green_tuple() {
    local section1_manifest="$1" sha="$2" billing_month="$3"
    local summary_path artifact_dir verdict_path receipt_path validation_path
    summary_path="$TEST_WORKSPACE/fixtures/cross-stage-green/summary.json"
    artifact_dir="$TEST_WORKSPACE/artifacts/cross-stage-green"
    verdict_path="$artifact_dir/verdict.json"
    receipt_path="$artifact_dir/rc_run_receipt.json"
    validation_path="$artifact_dir/section1_manifest_validation.json"
    write_paid_beta_full_pass_summary "$summary_path"

    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path" \
        --sha="$sha" \
        --billing-month="$billing_month" \
        --artifact-dir="$artifact_dir" \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept the runner-emitted section1 manifest"
    assert_jq_eq "$verdict_path" ".verdict" "LAUNCH-READY" "runner-emitted green section1 plus canonical full-pass summary should launch ready"
    assert_jq_eq "$verdict_path" ".section1_manifest.all_probes_pass" "true" "green runner manifest should prove all runner probes passed"
    assert_jq_eq "$verdict_path" ".section1_manifest.all_green" "true" "green runner manifest should expose the root all_green marker"
    assert_jq_eq "$verdict_path" ".summary_required_set_complete" "true" "canonical registry-derived summary should be complete"
    assert_jq_eq "$validation_path" ".manifest_path" "$section1_manifest" "section1 validation receipt should point at the runner-emitted manifest"
    assert_rc_run_receipt_common "$receipt_path" "<artifact_dir>" "0" "$(section1_manifest_digest "$validation_path")" "cross-stage classify-existing"
    assert_jq_eq "$receipt_path" ".summary_digest" "$(summary_digest "$summary_path")" "cross-stage receipt should bind summary digest"

    _run_facade --validate-existing --run-receipt="$receipt_path" \
        --sha="$sha" \
        --billing-month="$billing_month" \
        --section1-manifest="$section1_manifest" \
        --summary="$summary_path"
    assert_eq "$RUN_EXIT_CODE" "0" "validate-existing should accept the unchanged runner manifest, summary, and receipt tuple"
}

assert_runner_emitted_real_defect_tuple() {
    local section1_manifest="$1" sha="$2" billing_month="$3"
    local summary_path artifact_dir verdict_path receipt_path
    summary_path="$TEST_WORKSPACE/fixtures/cross-stage-real-defect/summary.json"
    artifact_dir="$TEST_WORKSPACE/artifacts/cross-stage-real-defect"
    verdict_path="$artifact_dir/verdict.json"
    receipt_path="$artifact_dir/rc_run_receipt.json"
    write_paid_beta_summary_with_step "$summary_path" "cargo_workspace_tests" "fail" "cargo test --workspace failed"

    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path" \
        --sha="$sha" \
        --billing-month="$billing_month" \
        --artifact-dir="$artifact_dir" \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept canonical summary with one real defect"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY-real-defects" "canonical summary real defect should produce the real-defect verdict with the runner-emitted section1 manifest"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "real-defect verdict should not be pre-authorized"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"cargo_workspace_tests\") | .classification" "other_real" "cargo failure should classify as a real defect"

    _run_facade --validate-existing --run-receipt="$receipt_path" \
        --sha="$sha" \
        --billing-month="$billing_month" \
        --section1-manifest="$section1_manifest" \
        --summary="$summary_path"
    assert_eq "$RUN_EXIT_CODE" "0" "validate-existing should accept unchanged real-defect tuple"
    RUNNER_EMITTED_REAL_DEFECT_RECEIPT="$receipt_path"
    RUNNER_EMITTED_REAL_DEFECT_SUMMARY="$summary_path"
}

assert_runner_manifest_provenance_drift_rejected() {
    local receipt_path="$1" section1_manifest="$2" summary_path="$3" sha="$4" billing_month="$5"
    local drift_manifest="$TEST_WORKSPACE/section1_bundle/drifted_run_manifest.json"
    mkdir -p "$(dirname "$drift_manifest")"
    python3 - "$section1_manifest" "$drift_manifest" <<'PY'
import json
import sys
source, target = sys.argv[1:3]
with open(source, "r", encoding="utf-8") as fh:
    payload = json.load(fh)
payload["archive_digest"] = "0" * 64
with open(target, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY

    _run_facade --validate-existing --run-receipt="$receipt_path" \
        --sha="$sha" \
        --billing-month="$billing_month" \
        --section1-manifest="$drift_manifest" \
        --summary="$summary_path"
    assert_eq "$RUN_EXIT_CODE" "1" "validate-existing should reject section1 manifest provenance drift"
    assert_contains "$RUN_STDERR" "section1 manifest digest does not match run receipt" "drift rejection should name the manifest digest mismatch"
}

write_section1_manifest() {
    local path="$1" sha="$2" billing_month="$3"
    mkdir -p "$(dirname "$path")"
    python3 - "$path" "$sha" "$billing_month" <<'PY'
import json
import sys

path, sha, billing_month = sys.argv[1:4]
payload = {
    "source_sha": sha,
    "billing_month": billing_month,
    "all_green": True,
    "probes": [
        {"probe_id": "verify_email_clickthrough", "rc": 0, "pass": True},
        {"probe_id": "password_reset_clickthrough", "rc": 0, "pass": True},
        {"probe_id": "dunning_email_inbox", "rc": 0, "pass": True},
        {"probe_id": "ses_bounce", "rc": 0, "pass": True},
        {"probe_id": "ses_complaint", "rc": 0, "pass": True},
        {"probe_id": "staging_dunning_delivery", "rc": 0, "pass": True},
    ],
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

write_section1_manifest_with_shape() {
    local path="$1" sha="$2" billing_month="$3" shape="$4"
    mkdir -p "$(dirname "$path")"
    python3 - "$path" "$sha" "$billing_month" "$shape" <<'PY'
import json
import sys

path, sha, billing_month, shape = sys.argv[1:5]
probe_ids = [
    "verify_email_clickthrough",
    "password_reset_clickthrough",
    "dunning_email_inbox",
    "ses_bounce",
    "ses_complaint",
    "staging_dunning_delivery",
]
if shape == "green":
    probes = [{"probe_id": probe_id, "rc": 0, "pass": True} for probe_id in probe_ids]
    all_green = True
elif shape == "complete_red":
    probes = [{"probe_id": probe_id, "rc": 1, "pass": False} for probe_id in probe_ids]
    all_green = False
elif shape == "structural_gap":
    probes = [{"probe_id": probe_id, "rc": 0, "pass": True} for probe_id in probe_ids[:-1]]
    all_green = False
else:
    raise SystemExit(f"unknown shape {shape}")
payload = {
    "source_sha": sha,
    "billing_month": billing_month,
    "all_green": all_green,
    "probes": probes,
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

install_present_vite_stub() {
    mkdir -p "$TEST_WORKSPACE/web/node_modules/.bin"
    cat > "$TEST_WORKSPACE/web/node_modules/.bin/vite" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
    chmod +x "$TEST_WORKSPACE/web/node_modules/.bin/vite"
}

run_rc_loader_child() {
    local credential_file="$1"
    local stdout_file="$TEST_WORKSPACE/tmp/loader_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/loader_stderr.txt"
    local env_args=(
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin"
        "HOME=$TEST_WORKSPACE"
        "TMPDIR=$TEST_WORKSPACE/tmp"
        "LC_ALL=C"
        "REPO_ROOT=$TEST_WORKSPACE"
        "CREDENTIAL_FILE=$credential_file"
    )
    if declare -p TEST_FACADE_ENV >/dev/null 2>&1 && [ "${#TEST_FACADE_ENV[@]}" -gt 0 ]; then
        env_args+=("${TEST_FACADE_ENV[@]}")
    fi

    RUN_LOADER_EXIT_CODE=0
    (
        cd "$TEST_WORKSPACE"
        env -i "${env_args[@]}" /bin/bash <<'CHILD'
set -euo pipefail
is_safe_logged_test_credential() {
    case "$1" in
        AKIAINVOKERCWRAPPERTEST|GOODFILEKEY|REJECTEDFILEKEY)
            return 0
            ;;
    esac
    return 1
}
redact_logged_test_credential() {
    local value="${1:-}"
    if [ -z "$value" ]; then
        printf '%s' ""
    elif is_safe_logged_test_credential "$value"; then
        printf '%s' "$value"
    else
        printf '%s' "[REDACTED]"
    fi
}
source "$REPO_ROOT/scripts/lib/env.sh"
source "$REPO_ROOT/scripts/lib/rc_invocation.sh"
rc_load_credential_env_file "$CREDENTIAL_FILE"
aws sts get-caller-identity >/dev/null
printf 'AWS_ACCESS_KEY_ID=%s\n' "$(redact_logged_test_credential "${AWS_ACCESS_KEY_ID:-}")"
if [ -n "${AWS_SESSION_TOKEN+x}" ]; then
    printf 'AWS_SESSION_TOKEN=%s\n' "$(redact_logged_test_credential "$AWS_SESSION_TOKEN")"
else
    printf 'AWS_SESSION_TOKEN=<unset>\n'
fi
CHILD
    ) >"$stdout_file" 2>"$stderr_file" || RUN_LOADER_EXIT_CODE=$?

    RUN_LOADER_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_LOADER_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

assert_call_log_absent() {
    local pattern="$1" msg="$2"
    local calls
    calls="$(grep -E "$pattern" "$TEST_CALL_LOG" 2>/dev/null || true)"
    assert_eq "$calls" "" "$msg"
}

_run_facade() {
    local wrapper_script="$TEST_WORKSPACE/scripts/launch/invoke_rc_with_env.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/invoke_rc_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/invoke_rc_stderr.txt"
    local env_args=(
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin"
        "HOME=$TEST_WORKSPACE"
        "TMPDIR=$TEST_WORKSPACE/tmp"
        "LC_ALL=C"
    )
    if declare -p TEST_FACADE_ENV >/dev/null 2>&1 && [ "${#TEST_FACADE_ENV[@]}" -gt 0 ]; then
        env_args+=("${TEST_FACADE_ENV[@]}")
    fi

    RUN_EXIT_CODE=0
    if [ ! -f "$wrapper_script" ]; then
        printf '' > "$stdout_file"
        printf 'MISSING_TARGET: %s\n' "$TARGET_SCRIPT" > "$stderr_file"
        RUN_EXIT_CODE=127
    else
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" "$@" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    fi

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

combined_output() {
    printf '%s\n%s\n' "$RUN_STDOUT" "$RUN_STDERR"
}

source_rc_coordinator_functions() {
    local function_library="$TEST_WORKSPACE/scripts/launch/run_full_backend_validation_functions.sh"
    local previous_sourced="${__RUN_FULL_BACKEND_VALIDATION_SOURCED-}"
    local had_previous_sourced=0
    if [ ! -f "$function_library" ]; then
        fail "run_full_backend_validation function library should exist in harness workspace"
        return 1
    fi
    if [ -n "${__RUN_FULL_BACKEND_VALIDATION_SOURCED+x}" ]; then
        had_previous_sourced=1
    fi
    __RUN_FULL_BACKEND_VALIDATION_SOURCED=1
    # shellcheck disable=SC1090
    source "$function_library"
    if [ "$had_previous_sourced" -eq 1 ]; then
        __RUN_FULL_BACKEND_VALIDATION_SOURCED="$previous_sourced"
    else
        unset __RUN_FULL_BACKEND_VALIDATION_SOURCED
    fi
}

capture_var_value() {
    local capture_path="$1" var_name="$2"
    awk -F= -v key="$var_name" '$1 == key { value = substr($0, length($1) + 2) } END { if (value != "") print value }' "$capture_path"
}

assert_capture_var_eq() {
    local capture_path="$1" var_name="$2" expected="$3" msg="$4"
    local actual
    actual="$(capture_var_value "$capture_path" "$var_name")"
    assert_eq "$actual" "$expected" "$msg"
}
