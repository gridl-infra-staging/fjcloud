#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/invoke_rc_with_env.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/invoke_rc_with_env.sh"
RUNNER="$REPO_ROOT/scripts/launch/run_ses_coverage_a1_in_vpc.sh"

# shellcheck source=lib/invoke_rc_with_env_harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/invoke_rc_with_env_harness.sh"
# shellcheck source=lib/ses_coverage_a1_runner_harness.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ses_coverage_a1_runner_harness.sh"
# shellcheck source=lib/invoke_rc_with_env_readiness_cases.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/invoke_rc_with_env_readiness_cases.sh"

assert_file_missing() {
    local abs_path="$1" msg="$2"
    if [ ! -e "$abs_path" ]; then
        pass "$msg"
    else
        fail "$msg (unexpected path exists: $abs_path)"
    fi
}

write_metachar_credentials_env() {
    local path="$1" marker_path="$2"
    {
        printf '%s\n' 'AWS_ACCESS_KEY_ID=AKIAINVOKERCWRAPPERTEST'
        printf '%s\n' 'AWS_SECRET_ACCESS_KEY=fixture-secret'
        printf '%s\n' 'AWS_DEFAULT_REGION=us-east-1'
        printf "STRIPE_SECRET_KEY_RESTRICTED=sk_test_\$(touch %s)\n" "$marker_path"
        printf '%s\n' 'STRIPE_WEBHOOK_SECRET=whsec_wrapper_contract'
    } > "$path"
}

write_packer_manifest() {
    local path="$1" ami_id="$2"
    mkdir -p "$(dirname "$path")"
    python3 - "$path" "$ami_id" <<'PY'
import json
import sys

path, ami_id = sys.argv[1], sys.argv[2]
payload = {
    "builds": [
        {
            "name": "flapjack-ami",
            "builder_type": "amazon-ebs",
            "artifact_id": f"us-east-1:{ami_id}",
            "custom_data": {"ami_id": ami_id},
        }
    ]
}
with open(path, "w", encoding="utf-8") as fh:
    json.dump(payload, fh)
    fh.write("\n")
PY
}

write_summary_fixture() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path"
}

write_portal_card_rendered_artifacts() {
    local fixture_dir="$1"
    local lane_dir="$fixture_dir/browser_portal_cancel"
    local trace_dir="$lane_dir/playwright-traces/billing_portal_payment_method_update/e2e-ui-full-billing_portal-setup-chromium"
    mkdir -p "$trace_dir"
    cat > "$lane_dir/billing_portal_payment_method_update.txt" <<'LOG'
Locator: getByTestId('payment-element').locator('iframe[name^="__privateStripeFrame"]').contentFrame().getByRole('button', { name: /^Card$/i })
Expected: visible
Timeout: 30000ms
Error: element(s) not found
LOG
    cat > "$trace_dir/error-context.md" <<'TRACE'
- heading "Add Payment Method" [level=1]
- iframe:
  - generic: Card
  - textbox "Card number":
    - /placeholder: 1234 1234 1234 1234
  - textbox "Expiration date MM / YY":
    - /placeholder: MM / YY
  - textbox "Security code":
    - /placeholder: CVC
  - textbox "ZIP code":
    - /placeholder: "12345"
- button "Save payment method"
TRACE
}

invoke_rc_with_env_after_setup() {
    # The main wrapper contract tests are not exercising install behavior.
    # Preinstall the vite stub so they stay focused on argument and dry-run
    # semantics while the dedicated bootstrap test owns install-path coverage.
    install_present_vite_stub
    install_successful_wrapper_preflight_stubs
}

assembled_command_line() {
    combined_output | grep -m1 'bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc' || true
}

assert_no_side_effect_calls() {
    local msg="$1"
    local calls
    calls="$(grep -E '^(packer|npm|npx|playwright|e2e-preflight|run_full_backend_validation)\|' "$TEST_CALL_LOG" 2>/dev/null || true)"
    assert_eq "$calls" "" "$msg"
}

assert_jq_eq() {
    local file="$1" filter="$2" expected="$3" msg="$4"
    local actual
    actual="$(jq -r "$filter" "$file")"
    assert_eq "$actual" "$expected" "$msg"
}

assert_common_rc_command_contract() {
    local expected_sha="$1" expected_artifact_dir="$2" expected_credentials_file="$3" expected_billing_month="$4" expected_api_ami_id="$5" expected_flapjack_ami_id="$6"
    local command_line
    command_line="$(assembled_command_line)"

    assert_contains "$command_line" "bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc" "dry-run should print the delegated paid-beta RC coordinator command"
    assert_not_contains "$command_line" "--dry-run" "wrapper dry-run must not forward coordinator --dry-run"
    assert_contains "$command_line" "--sha=$expected_sha" "assembled command should preserve --sha byte-for-byte"
    assert_contains "$command_line" "--artifact-dir=$expected_artifact_dir" "assembled command should preserve --artifact-dir byte-for-byte"
    assert_contains "$command_line" "--credential-env-file=$expected_credentials_file" "assembled command should forward canonical credential env flag"
    assert_contains "$command_line" "--billing-month=$expected_billing_month" "assembled command should include resolved billing month"
    assert_contains "$command_line" "--staging-smoke-api-ami-id=$expected_api_ami_id" "assembled command should include resolved API staging smoke AMI"
    assert_contains "$command_line" "--staging-smoke-flapjack-ami-id=$expected_flapjack_ami_id" "assembled command should include resolved Flapjack staging smoke AMI"
    assert_not_contains "$command_line" "--staging-smoke-ami-id" "assembled command must not include removed single staging smoke AMI flag"
}

assert_section1_manifest_receipt() {
    local receipt_path="$1" expected_sha="$2" expected_billing_month="$3" msg="$4"

    assert_file_exists "$receipt_path" "$msg should write validation receipt"
    assert_jq_eq "$receipt_path" ".status" "validated" "$msg should validate manifest"
    assert_jq_eq "$receipt_path" ".sha" "$expected_sha" "$msg should record SHA provenance"
    assert_jq_eq "$receipt_path" ".billing_month" "$expected_billing_month" "$msg should record billing-month provenance"
    assert_jq_eq "$receipt_path" ".manifest_digest | length" "64" "$msg should record manifest digest"
}

section1_manifest_digest() {
    local receipt_path="$1"
    jq -r '.manifest_digest' "$receipt_path"
}

summary_digest() {
    local summary_path="$1"
    python3 - "$summary_path" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as fh:
    print(hashlib.sha256(fh.read()).hexdigest())
PY
}

install_successful_coordinator_receipt_mock() {
    local summary_payload="${1:-}"
    cat > "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "run_full_backend_validation|$*" >> "$TEST_CALL_LOG"
artifact_dir=""
for arg in "$@"; do
    case "$arg" in
        --artifact-dir=*) artifact_dir="${arg#--artifact-dir=}" ;;
    esac
done
if [ -n "$artifact_dir" ] && [ -n "${MOCK_COORDINATOR_SUMMARY_JSON:-}" ]; then
    mkdir -p "$artifact_dir"
    printf '%s\n' "$MOCK_COORDINATOR_SUMMARY_JSON" > "$artifact_dir/summary.json"
fi
exit 0
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh"
    if [ -n "$summary_payload" ]; then
        add_facade_env "MOCK_COORDINATOR_SUMMARY_JSON=$summary_payload"
    fi
    add_facade_env "TEST_CALL_LOG=$TEST_CALL_LOG"
}

assert_rc_run_receipt_common() {
    local receipt_path="$1" expected_artifact_dir="$2" expected_exit="$3" expected_section1_digest="$4" msg="$5"

    assert_file_exists "$receipt_path" "$msg should write rc run receipt"
    assert_jq_eq "$receipt_path" ".artifact_dir" "$expected_artifact_dir" "$msg should record artifact directory"
    assert_jq_eq "$receipt_path" ".wrapper_exit" "$expected_exit" "$msg should record wrapper exit"
    assert_jq_eq "$receipt_path" ".section1_manifest_digest" "$expected_section1_digest" "$msg should bind section1 manifest digest"
    assert_jq_eq "$receipt_path" ".argv | type" "array" "$msg should record sanitized argv array"
    assert_jq_eq "$receipt_path" "has(\"summary_path\")" "false" "$msg receipt should not record summary paths"
    assert_not_contains "$(jq -r '.argv | join(" ")' "$receipt_path")" "sk_test_" "$msg receipt argv should not contain Stripe secrets"
    assert_not_contains "$(jq -r '.argv | join(" ")' "$receipt_path")" "$REPO_ROOT" "$msg receipt argv should not contain absolute worktree paths"
    assert_not_contains "$(cat "$receipt_path")" "$TEST_WORKSPACE" "$msg receipt should not contain absolute workspace paths"
}
test_missing_target_is_explicit_red_cause() {
    setup_workspace
    _run_facade --help

    if [ -f "$TARGET_SCRIPT" ]; then
        pass "invoke_rc_with_env.sh exists for post-red implementation state"
    else
        assert_eq "$RUN_EXIT_CODE" "127" "missing facade should be an explicit red cause, not a harness crash"
        assert_contains "$RUN_STDERR" "MISSING_TARGET: $TARGET_SCRIPT" "missing facade red cause should name the target script"
    fi
}

test_help_contract_usage_surface() {
    setup_workspace
    _run_facade --help

    assert_eq "$RUN_EXIT_CODE" "0" "--help should exit 0"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "Usage:" "--help should include usage text"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--dry-run" "--help should include wrapper --dry-run"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--sha=<GIT_SHA>" "--help should include --sha=<GIT_SHA>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--artifact-dir=<dir>" "--help should include --artifact-dir=<dir>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--credential-env-file=<path>" "--help should include --credential-env-file=<path>"
    if [[ "$RUN_STDOUT$RUN_STDERR" == *"--env-file"* ]]; then
        assert_contains "$RUN_STDOUT$RUN_STDERR" "--env-file=<path>" "--help should spell the optional env-file alias exactly when advertised"
    else
        pass "--help does not advertise optional --env-file alias"
    fi
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--billing-month=<YYYY-MM>" "--help should include --billing-month=<YYYY-MM>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--verdict=<verdict.json>" "--help should include the validate-existing verdict input"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--validation-output=<validation.json>" "--help should include the validate-existing receipt output"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-api-ami-id=<ami-id>" "--help should include --staging-smoke-api-ami-id=<ami-id>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-flapjack-ami-id=<ami-id>" "--help should include --staging-smoke-flapjack-ami-id=<ami-id>"
    assert_not_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-ami-id=<ami-id>" "--help should not include removed --staging-smoke-ami-id=<ami-id>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-only" "--help should include --staging-only"
}

test_dry_run_assembles_paid_beta_rc_command_without_delegation() {
    setup_workspace
    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    local artifact_dir="$TEST_WORKSPACE/artifacts"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$artifact_dir" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210 \
        --staging-only

    assert_eq "$RUN_EXIT_CODE" "0" "wrapper dry-run with explicit inputs should exit 0"
    assert_common_rc_command_contract "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$artifact_dir" "$credential_file" "2026-06" "ami-0123456789abcdef0" "ami-0fedcba9876543210"
    assert_contains "$(assembled_command_line)" "--section1-manifest=$section1_manifest" "assembled command should forward validated section1 manifest"
    assert_section1_manifest_receipt "$artifact_dir/section1_manifest_validation.json" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06" "wrapper dry-run"
    assert_rc_run_receipt_common "$artifact_dir/rc_run_receipt.json" "<artifact_dir>" "0" "$(section1_manifest_digest "$artifact_dir/section1_manifest_validation.json")" "wrapper dry-run"
    assert_jq_eq "$artifact_dir/rc_run_receipt.json" ".coordinator_exit == null" "true" "dry-run receipt should not invent a coordinator exit"
    assert_jq_eq "$artifact_dir/rc_run_receipt.json" ".summary_digest == null" "true" "dry-run receipt should omit summary digest when no summary exists"
    assert_contains "$(assembled_command_line)" "--staging-only" "assembled command should preserve --staging-only byte-for-byte"
    assert_no_side_effect_calls "wrapper dry-run should not invoke coordinator or external/bootstrap tools"
}

test_live_delegation_writes_rc_run_receipt_with_summary_digest() {
    setup_workspace
    local credential_file artifact_dir section1_manifest summary_path
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    artifact_dir="$TEST_WORKSPACE/artifacts"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    summary_path="$artifact_dir/summary.json"
    write_safe_credentials_env "$credential_file"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"
    install_successful_coordinator_receipt_mock '{"mode":"paid_beta_rc","ready":true,"steps":[]}'

    _run_facade \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$artifact_dir" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "0" "live delegation should return successful coordinator exit"
    assert_rc_run_receipt_common "$artifact_dir/rc_run_receipt.json" "<artifact_dir>" "0" "$(section1_manifest_digest "$artifact_dir/section1_manifest_validation.json")" "live delegation"
    assert_jq_eq "$artifact_dir/rc_run_receipt.json" ".coordinator_exit" "0" "live receipt should record coordinator exit"
    assert_jq_eq "$artifact_dir/rc_run_receipt.json" ".summary_digest" "$(summary_digest "$summary_path")" "live receipt should record summary digest"
}

test_runner_emitted_section1_manifest_flows_through_existing_receipt_seams() {
    setup_workspace
    ses_coverage_a1_prepare_runner_workspace
    local sha billing_month runner_artifact_rel section1_manifest
    sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    billing_month="2026-06"
    runner_artifact_rel="docs/runbooks/evidence/ses-coverage-a1/cross_stage_green_$$"

    ses_coverage_a1_run_runner_scenario "green" "$sha" "$billing_month" "$runner_artifact_rel"
    assert_eq "$RUN_RC" "0" "cross-stage KAT runner fixture should produce a green section1 bundle"
    section1_manifest="$TEST_WORKSPACE/$runner_artifact_rel/run_manifest.json"
    assert_file_exists "$section1_manifest" "cross-stage KAT should use the runner-emitted run_manifest.json"

    assert_runner_emitted_green_tuple "$section1_manifest" "$sha" "$billing_month"
    assert_runner_emitted_real_defect_tuple "$section1_manifest" "$sha" "$billing_month"
    assert_runner_manifest_provenance_drift_rejected \
        "$RUNNER_EMITTED_REAL_DEFECT_RECEIPT" \
        "$section1_manifest" \
        "$RUNNER_EMITTED_REAL_DEFECT_SUMMARY" \
        "$sha" \
        "$billing_month"
    assert_no_side_effect_calls "cross-stage classify/validate KAT should not invoke coordinator or external/bootstrap tools"
}

test_paid_beta_requires_section1_manifest_before_any_side_effects() {
    setup_workspace
    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_safe_credentials_env "$credential_file"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "2" "missing section1 manifest should fail as usage error"
    assert_contains "$RUN_STDERR" "--section1-manifest=<path>" "missing section1 manifest error should name required flag"
    assert_file_missing "$TEST_WORKSPACE/artifacts/section1_manifest_validation.json" "missing section1 manifest should not write a validation receipt"
    assert_no_side_effect_calls "missing section1 manifest should not invoke STS, browser preflight, npm, or coordinator"
}

test_unreadable_section1_manifest_refuses_before_any_side_effects() {
    setup_workspace
    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    local missing_manifest="$TEST_WORKSPACE/section1_bundle/missing_manifest.json"
    write_safe_credentials_env "$credential_file"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$missing_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "1" "unreadable section1 manifest should fail before preflight"
    assert_contains "$RUN_STDERR" "section1 manifest validation failed" "unreadable section1 manifest error should identify manifest validation"
    assert_file_missing "$TEST_WORKSPACE/artifacts/section1_manifest_validation.json" "unreadable section1 manifest should not write a validation receipt"
    assert_no_side_effect_calls "unreadable section1 manifest should not invoke STS, browser preflight, npm, or coordinator"
}

test_malformed_section1_manifest_refuses_before_any_side_effects() {
    setup_workspace
    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    local malformed_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    mkdir -p "$(dirname "$malformed_manifest")"
    printf '{not json}\n' > "$malformed_manifest"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$malformed_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "1" "malformed section1 manifest should fail before preflight"
    assert_contains "$RUN_STDERR" "section1 manifest validation failed" "malformed section1 manifest error should identify manifest validation"
    assert_file_missing "$TEST_WORKSPACE/artifacts/section1_manifest_validation.json" "malformed section1 manifest should not write a validation receipt"
    assert_no_side_effect_calls "malformed section1 manifest should not invoke STS, browser preflight, npm, or coordinator"
}

test_dry_run_defaults_billing_month_and_credential_env_file() {
    setup_workspace
    local expected_month expected_credentials artifact_dir section1_manifest
    expected_month="$(date -u +%Y-%m)"
    expected_credentials="$TEST_WORKSPACE/repos/gridl-infra-dev/fjcloud_dev/.secret/.env.secret"
    artifact_dir="$TEST_WORKSPACE/artifacts"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    mkdir -p "$(dirname "$expected_credentials")"
    write_safe_credentials_env "$expected_credentials"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0abc1111222233334"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$expected_month"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$artifact_dir" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "wrapper dry-run should default omitted operator inputs"
    assert_common_rc_command_contract "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$artifact_dir" "$expected_credentials" "$expected_month" "ami-0123456789abcdef0" "ami-0abc1111222233334"
    assert_no_side_effect_calls "default resolution should not invoke coordinator or external/bootstrap tools"
}

test_explicit_credential_env_file_is_forwarded_unchanged() {
    setup_workspace
    local credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    local section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    local expected_month
    expected_month="$(date -u +%Y-%m)"
    write_safe_credentials_env "$credential_file"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0abc1111222233334"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$expected_month"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 \
        --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "explicit credential env file dry-run should exit 0"
    assert_contains "$(assembled_command_line)" "--credential-env-file=$credential_file" "explicit credential env file should be forwarded unchanged"
    assert_no_side_effect_calls "credential env forwarding dry-run should not invoke coordinator or external/bootstrap tools"
}

test_env_file_alias_normalizes_only_when_advertised() {
    setup_workspace
    local help_output credential_file
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    write_safe_credentials_env "$credential_file"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0abc1111222233334"

    _run_facade --help
    help_output="$RUN_STDOUT$RUN_STDERR"
    if [[ "$help_output" != *"--env-file"* ]]; then
        pass "optional --env-file alias is not advertised, so alias normalization contract is inactive"
        return
    fi

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --env-file="$credential_file"

    assert_eq "$RUN_EXIT_CODE" "0" "advertised --env-file alias should be accepted"
    assert_contains "$(assembled_command_line)" "--credential-env-file=$credential_file" "env-file alias should normalize to canonical coordinator flag"
    assert_not_contains "$(assembled_command_line)" "--env-file=$credential_file" "env-file alias should not be forwarded to coordinator"
    assert_no_side_effect_calls "env-file alias dry-run should not invoke coordinator or external/bootstrap tools"
}

test_credential_env_values_are_inert_and_never_printed() {
    setup_workspace
    local credential_file marker_file output section1_manifest expected_month
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    marker_file="$TEST_WORKSPACE/tmp/credential_exec_marker"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    expected_month="$(date -u +%Y-%m)"
    write_metachar_credentials_env "$credential_file" "$marker_file"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0abc1111222233334"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$expected_month"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 \
        --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210 \
        --section1-manifest="$section1_manifest"
    output="$(combined_output)"

    assert_eq "$RUN_EXIT_CODE" "0" "credential env parser should accept shell metacharacters as inert data"
    assert_file_missing "$marker_file" "credential env parser must not execute command substitution values"
    assert_not_contains "$output" "sk_test_" "dry-run output must not print Stripe credential values"
    assert_not_contains "$output" "whsec_" "dry-run output must not print webhook secret values"
    assert_no_side_effect_calls "credential parsing dry-run should not invoke coordinator or external/bootstrap tools"
}

test_explicit_ami_takes_precedence_over_manifest_files() {
    setup_workspace
    local credential_file section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0aaa1111222233334"
    write_packer_manifest "$TEST_WORKSPACE/flapjack-ami-manifest.json" "ami-0bbb1111222233335"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "0" "explicit staging smoke AMIs dry-run should exit 0"
    assert_contains "$(assembled_command_line)" "--staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210" "explicit AMIs should be forwarded unchanged"
    assert_not_contains "$(assembled_command_line)" "ami-0aaa1111222233334" "explicit Flapjack AMI should take precedence over ops manifest"
    assert_not_contains "$(assembled_command_line)" "ami-0bbb1111222233335" "explicit Flapjack AMI should take precedence over root manifest"
    assert_no_side_effect_calls "explicit AMIs dry-run should not invoke coordinator or external/bootstrap tools"
}

test_ops_packer_manifest_supplies_staging_smoke_ami() {
    setup_workspace
    local credential_file section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_packer_manifest "$TEST_WORKSPACE/ops/packer/flapjack-ami-manifest.json" "ami-0abc1111222233334"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "ops/packer manifest should satisfy omitted Flapjack AMI input"
    assert_contains "$(assembled_command_line)" "--staging-smoke-api-ami-id=ami-0123456789abcdef0" "ops/packer manifest fallback should preserve explicit API AMI"
    assert_contains "$(assembled_command_line)" "--staging-smoke-flapjack-ami-id=ami-0abc1111222233334" "ops/packer manifest Flapjack AMI should be forwarded to coordinator"
    assert_no_side_effect_calls "ops manifest AMI resolution should not invoke coordinator, packer, or browser tooling beyond preflight"
}

test_root_manifest_supplies_staging_smoke_ami() {
    setup_workspace
    local credential_file section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_packer_manifest "$TEST_WORKSPACE/flapjack-ami-manifest.json" "ami-0def5555666677778"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "0" "root manifest should satisfy omitted Flapjack AMI input"
    assert_contains "$(assembled_command_line)" "--staging-smoke-api-ami-id=ami-0123456789abcdef0" "root manifest fallback should preserve explicit API AMI"
    assert_contains "$(assembled_command_line)" "--staging-smoke-flapjack-ami-id=ami-0def5555666677778" "root manifest Flapjack AMI should be forwarded to coordinator"
    assert_no_side_effect_calls "root manifest AMI resolution should not invoke coordinator, packer, or browser tooling beyond preflight"
}

test_missing_ami_exits_before_coordinator_invocation_with_remediation() {
    setup_workspace
    local credential_file section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest"

    assert_eq "$RUN_EXIT_CODE" "2" "missing API AMI should fail before coordinator invocation"
    assert_contains "$RUN_STDERR" "--staging-smoke-api-ami-id=<ami-id>" "missing API AMI remediation should name the explicit API AMI flag"
    assert_not_contains "$(combined_output)" "bash scripts/launch/run_full_backend_validation.sh --paid-beta-rc" "missing API AMI should not print a coordinator command"
    assert_no_side_effect_calls "missing API AMI should not invoke coordinator or external/bootstrap tools"
}

test_dry_run_never_bootstraps_browser_or_runtime_dependencies() {
    setup_workspace
    local credential_file section1_manifest
    credential_file="$TEST_WORKSPACE/inputs/credentials.env"
    section1_manifest="$TEST_WORKSPACE/section1_bundle/manifest.json"
    write_safe_credentials_env "$credential_file"
    write_section1_manifest "$section1_manifest" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "2026-06"

    _run_facade --dry-run \
        --sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        --artifact-dir="$TEST_WORKSPACE/artifacts" \
        --credential-env-file="$credential_file" \
        --billing-month=2026-06 \
        --section1-manifest="$section1_manifest" \
        --staging-smoke-api-ami-id=ami-0123456789abcdef0 --staging-smoke-flapjack-ami-id=ami-0fedcba9876543210

    assert_eq "$RUN_EXIT_CODE" "0" "preflighted dry-run should exit 0"
    assert_no_side_effect_calls "wrapper-only dry-run must not bootstrap browser deps, call Playwright, e2e-preflight, or the coordinator"
}

test_classify_existing_env_lock_fixture_reproduces_prior_verdict_shape() {
    setup_workspace
    local fixture_dir verdict_path
    fixture_dir="$REPO_ROOT/docs/runbooks/evidence/invite-ready-rc/20260610T191851Z_env-lock-rerun"
    verdict_path="$TEST_WORKSPACE/artifacts/env-lock-verdict.json"

    _run_facade --classify-existing \
        --summary="$fixture_dir/summary.json" \
        --verdict-output="$verdict_path"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept the env-lock fixture"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY" "legacy env-lock fixture without a validated section1 manifest should fail closed"
    assert_jq_eq "$verdict_path" ".other_real_count" "0" "env-lock fixture should not count env gaps as real defects"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "legacy env-lock fixture should not be pre-authorized without literal complete-red section1"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"staging_billing_rehearsal\") | .classification" "env_gap" "billing_run_no_created_invoices should remain an explicit env gap"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_auth_setup\") | .classification" "env_gap" "external_secret_missing browser auth setup remains an env gap"
    assert_jq_eq "$verdict_path" ".section_impact[\"1\"]" "partial" "section 1 should stay partial when no real defects supersede the matrix gap"
    assert_no_side_effect_calls "classify-existing should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_real_defect_fixture_reproduces_prior_verdict_shape() {
    setup_workspace
    local fixture_dir verdict_path
    fixture_dir="$REPO_ROOT/docs/runbooks/evidence/invite-ready-rc/20260610T103031Z"
    verdict_path="$TEST_WORKSPACE/artifacts/real-defect-verdict.json"

    _run_facade --classify-existing \
        --summary="$fixture_dir/summary.json" \
        --verdict-output="$verdict_path"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept the real-defect fixture"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY-real-defects" "real-defect fixture verdict should preserve the prior blocked shape"
    assert_jq_eq "$verdict_path" ".other_real_count" "1" "real-defect fixture should count exactly one real defect"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "real defects should not be pre-authorized"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"cargo_workspace_tests\") | .classification" "other_real" "cargo workspace failure should remain a real defect"
    assert_jq_eq "$verdict_path" ".section_impact[\"2\"]" "partial" "section 2 should show the cargo real-defect impact"
    assert_no_side_effect_calls "classify-existing should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_rationale_only_names_present_env_gap_rows() {
    setup_workspace
    local fixture_dir summary_path verdict_path
    fixture_dir="$TEST_WORKSPACE/fixtures/rationale"
    summary_path="$fixture_dir/summary.json"
    verdict_path="$TEST_WORKSPACE/artifacts/rationale-verdict.json"
    write_summary_fixture "$summary_path" <<'JSON'
{
  "mode": "paid_beta_rc",
  "steps": [
    {"name": "staging_billing_rehearsal", "status": "pass", "reason": ""},
    {"name": "browser_auth_setup", "status": "external_secret_missing", "reason": "browser_auth_setup_env_gap"},
    {"name": "browser_signup_paid", "status": "pass", "reason": ""}
  ]
}
JSON

    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept a summary with only browser_auth_setup env gap"
    assert_jq_eq "$verdict_path" ".non_pass_steps | length" "1" "fixture should contain exactly one non-pass row"
    assert_not_contains "$(jq -r '.rationale' "$verdict_path")" "staging_billing_rehearsal billing_run_no_created_invoices" "rationale must not cite absent env-gap rows"
    assert_contains "$(jq -r '.rationale' "$verdict_path")" "browser_auth_setup" "rationale should name the actual env-gap row"
    assert_no_side_effect_calls "classify-existing should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_portal_card_rendered_selector_mismatch_is_harness_gap() {
    setup_workspace
    local fixture_dir summary_path verdict_path
    fixture_dir="$TEST_WORKSPACE/fixtures/portal-card-rendered"
    summary_path="$fixture_dir/summary.json"
    verdict_path="$TEST_WORKSPACE/artifacts/portal-card-rendered-verdict.json"
    write_summary_fixture "$summary_path" <<'JSON'
{
  "mode": "paid_beta_rc",
  "steps": [
    {"name": "browser_auth_setup", "status": "external_secret_missing", "reason": "browser_auth_setup_env_gap"},
    {"name": "browser_portal_cancel", "status": "fail", "reason": "browser_portal_cancel_failed"}
  ]
}
JSON
    write_portal_card_rendered_artifacts "$fixture_dir"

    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept browser portal evidence artifacts"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY" "rendered card fields should not produce a launch-ready or real-defect verdict"
    assert_jq_eq "$verdict_path" ".other_real_count" "0" "selector mismatch with rendered card form should not count as a real defect"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "harness-only browser mismatch should fail closed without literal complete-red section1"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_portal_cancel\") | .classification" "harness_gap" "portal card rendered selector mismatch should be classified as harness gap"
    assert_contains "$(jq -r '.rationale' "$verdict_path")" "browser_portal_cancel" "rationale should name the harness-gap row"
    assert_no_side_effect_calls "classify-existing should not invoke coordinator or external/bootstrap tools"
}

test_classify_existing_portal_card_rendered_selector_mismatch_with_second_failure_is_real() {
    setup_workspace
    local fixture_dir summary_path verdict_path
    fixture_dir="$TEST_WORKSPACE/fixtures/portal-card-rendered-with-second-failure"
    summary_path="$fixture_dir/summary.json"
    verdict_path="$TEST_WORKSPACE/artifacts/portal-card-rendered-with-second-failure-verdict.json"
    write_summary_fixture "$summary_path" <<'JSON'
{
  "mode": "paid_beta_rc",
  "steps": [
    {"name": "browser_auth_setup", "status": "external_secret_missing", "reason": "browser_auth_setup_env_gap"},
    {"name": "browser_portal_cancel", "status": "fail", "reason": "browser_portal_cancel_failed"}
  ]
}
JSON
    write_portal_card_rendered_artifacts "$fixture_dir"
    cat > "$fixture_dir/browser_portal_cancel/account_overview_after_cancel.txt" <<'LOG'
Error: expect(locator).toHaveText(expected) failed
Expected: "Canceled"
Received: "Active"
LOG

    _run_facade --classify-existing \
        --summary="$summary_path" \
        --verdict-output="$verdict_path"

    assert_eq "$RUN_EXIT_CODE" "0" "classify-existing should accept mixed browser portal evidence artifacts"
    assert_jq_eq "$verdict_path" ".verdict" "NOT-READY-real-defects" "a second browser failure should prevent pre-authorized harness-gap verdicts"
    assert_jq_eq "$verdict_path" ".other_real_count" "1" "mixed selector mismatch plus another failure should count as a real defect"
    assert_jq_eq "$verdict_path" ".pre_authorized_shape_match" "false" "mixed browser failures should fail closed"
    assert_jq_eq "$verdict_path" ".non_pass_steps[] | select(.name == \"browser_portal_cancel\") | .classification" "other_real" "portal classifier must not hide additional failed browser results"
    assert_no_side_effect_calls "classify-existing should not invoke coordinator or external/bootstrap tools"
}

test_missing_target_is_explicit_red_cause
test_help_contract_usage_surface
test_dry_run_assembles_paid_beta_rc_command_without_delegation
test_live_delegation_writes_rc_run_receipt_with_summary_digest
test_runner_emitted_section1_manifest_flows_through_existing_receipt_seams
test_paid_beta_requires_section1_manifest_before_any_side_effects
test_unreadable_section1_manifest_refuses_before_any_side_effects
test_malformed_section1_manifest_refuses_before_any_side_effects
test_dry_run_defaults_billing_month_and_credential_env_file
test_explicit_credential_env_file_is_forwarded_unchanged
test_env_file_alias_normalizes_only_when_advertised
test_credential_env_values_are_inert_and_never_printed
test_explicit_ami_takes_precedence_over_manifest_files
test_ops_packer_manifest_supplies_staging_smoke_ami
test_root_manifest_supplies_staging_smoke_ami
test_missing_ami_exits_before_coordinator_invocation_with_remediation
test_dry_run_never_bootstraps_browser_or_runtime_dependencies
test_classify_existing_env_lock_fixture_reproduces_prior_verdict_shape
test_classify_existing_real_defect_fixture_reproduces_prior_verdict_shape
test_classify_existing_rationale_only_names_present_env_gap_rows
test_classify_existing_portal_card_rendered_selector_mismatch_is_harness_gap
test_classify_existing_portal_card_rendered_selector_mismatch_with_second_failure_is_real
test_classify_existing_green_section1_manifest_with_full_summary_can_launch_ready
test_classify_existing_green_section1_manifest_with_filtered_summary_is_not_launch_ready
test_validate_existing_requires_summary_when_receipt_records_digest
test_validate_existing_emits_closeout_validation_receipt
test_validate_existing_rejects_noncanonical_verdict_without_receipt
test_classify_existing_complete_red_section1_manifest_is_only_preauthorized_non_green
test_classify_existing_structural_section1_gap_is_not_preauthorized
test_classify_existing_taxonomy_rows_fail_closed_without_real_defects
test_classify_existing_real_defect_overrides_complete_red_section1_preauthorization

run_test_summary
