#!/usr/bin/env bash
# Contract tests for secret rotation runbook content.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/secret_rotation.md"
LAUNCH_RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/launch-backend.md"
INCIDENT_RUNBOOK_PATH="$REPO_ROOT/docs/runbooks/incident-response.md"
LANE7_POINTER_PATH="$REPO_ROOT/.lane7_evidence_dir"
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

PASS_COUNT=0
FAIL_COUNT=0
IAM_EVIDENCE_ROOT=""

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

load_required_file() {
    local path="$1"
    local description="$2"

    if [[ ! -f "$path" ]]; then
        fail "$description"
        return 1
    fi

    cat "$path"
}

load_iam_evidence_root() {
    if [[ -n "$IAM_EVIDENCE_ROOT" ]]; then
        return 0
    fi

    if [[ ! -f "$LANE7_POINTER_PATH" ]]; then
        fail "lane 7 evidence pointer should exist at .lane7_evidence_dir"
        return 1
    fi

    IAM_EVIDENCE_ROOT="$(tr -d '\r' < "$LANE7_POINTER_PATH")"
    IAM_EVIDENCE_ROOT="${IAM_EVIDENCE_ROOT%/}"
    if [[ -z "$IAM_EVIDENCE_ROOT" ]]; then
        fail "lane 7 evidence pointer should resolve to a non-empty path"
        return 1
    fi

    if [[ ! -d "$REPO_ROOT/$IAM_EVIDENCE_ROOT" ]]; then
        fail "lane 7 evidence root should exist at $IAM_EVIDENCE_ROOT"
        return 1
    fi
}

assert_iam_artifact_exists() {
    local relative_path="$1"
    local description="$2"

    load_iam_evidence_root || return
    if [[ -e "$REPO_ROOT/$IAM_EVIDENCE_ROOT/$relative_path" ]]; then
        pass "$description"
    else
        fail "$description"
    fi
}

test_secret_rotation_runbook_exists() {
    if [ -f "$RUNBOOK_PATH" ]; then
        pass "secret rotation runbook should exist"
    else
        fail "secret rotation runbook should exist at docs/runbooks/secret_rotation.md"
    fi
}

test_runbook_references_env_vars_contract() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return

    assert_contains "$content" "docs/env-vars.md" "runbook should reference docs/env-vars.md as canonical variable contract"
    assert_contains "$content" "STRIPE_SECRET_KEY" "runbook should reference STRIPE_SECRET_KEY"
    assert_contains "$content" "STRIPE_WEBHOOK_SECRET" "runbook should reference STRIPE_WEBHOOK_SECRET"
    assert_contains "$content" "JWT_SECRET" "runbook should reference JWT_SECRET"
    assert_contains "$content" "SES_FROM_ADDRESS" "runbook should reference SES_FROM_ADDRESS"
    assert_contains "$content" "SES_REGION" "runbook should reference SES_REGION"
}

test_runbook_covers_required_rotation_sections() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return

    assert_contains "$content" "## Stripe Rotation" "runbook should include a Stripe rotation section"
    assert_contains "$content" "## SES Rotation" "runbook should include an SES rotation section"
    assert_contains "$content" "## JWT Rotation" "runbook should include a JWT rotation section"
    assert_contains "$content" "Prechecks" "runbook should include prechecks guidance"
    assert_contains "$content" "Cutover" "runbook should include cutover guidance"
    assert_contains "$content" "Rollback" "runbook should include rollback guidance"
    assert_contains "$content" "Post-rotation verification" "runbook should include post-rotation verification guidance"
}

test_runbook_anchors_stripe_contract_to_canonical_checks() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return
    local live_cutover_anchor_count
    live_cutover_anchor_count="$(grep -c '^### Stripe Live Cutover$' "$RUNBOOK_PATH" || true)"

    assert_contains "$content" "scripts/stripe_cutover_prereqs.sh" "runbook should reference Stage 1 Stripe prerequisite gate"
    assert_contains "$content" "STRIPE_SECRET_KEY_RESTRICTED" "runbook should name the restricted key prerequisite"
    assert_contains "$content" "STRIPE_RESTRICTED_KEY_ID" "runbook should name restricted-key id comment prerequisite"
    assert_contains "$content" "STRIPE_OLD_KEY_ID" "runbook should name old-key id comment prerequisite"
    assert_contains "$content" "REASON: prerequisite_missing" "runbook should document stable prerequisite failure reason"
    assert_contains "$content" "docs/runbooks/evidence/secret-rotation/<UTC-stamp>_stripe_cutover/" "runbook should document prerequisite evidence bundle path shape"
    assert_contains "$content" "resolve_stripe_secret_key" "runbook should reference resolve_stripe_secret_key"
    assert_contains "$content" "check_stripe_key_present" "runbook should reference check_stripe_key_present"
    assert_contains "$content" "check_stripe_key_live" "runbook should reference check_stripe_key_live"
    assert_contains "$content" "check_stripe_webhook_secret_present" "runbook should reference check_stripe_webhook_secret_present"
    assert_contains "$content" "stripe_key_prefix_policy_allows_key" "runbook should reference the canonical Stripe prefix-policy seam owner"
    assert_contains "$content" "scripts/validate-stripe.sh" "runbook should reference validate-stripe.sh"
    assert_contains "$content" "bash scripts/validate-stripe.sh --live-cutover" "runbook should document explicit live-cutover invocation command"
    assert_contains "$content" "STRIPE_LIVE_CUTOVER=1" "runbook should require explicit live-cutover control env var"
    assert_contains "$content" "require_live_cutover_control" "runbook should document the live-cutover control failure step name"
    assert_contains "$content" "If rollback restores a live key, rerun explicit live cutover validation:" "runbook should require live-cutover validation command when rollback restores a live key"
    assert_contains "$content" "If rollback restores a test key, rerun default-deny validation:" "runbook should keep default-deny rollback command for test-key restores"
    assert_not_contains "$content" "Re-run default-deny validation and expect pass:" "runbook should not prescribe default-deny rollback validation for every rollback"
    assert_contains "$content" "docs/runbooks/launch-backend.md" "runbook should cross-reference launch-backend guidance"
    assert_contains "$content" "STRIPE_TEST_SECRET_KEY" "runbook should document compatibility fallback behavior"
    assert_eq "$live_cutover_anchor_count" "1" "runbook should define exactly one Stripe Live Cutover subsection"
    assert_contains "$content" "STRIPE_LIVE_CUTOVER=1" "runbook should require explicit live-cutover gate opt-in"
    assert_contains "$content" "sk_live_/rk_live_ prefixes are rejected unless STRIPE_LIVE_CUTOVER=1 is set" "runbook should document live-prefix gate behavior"
    assert_contains "$content" "bash scripts/validate-stripe.sh remains test-mode validation and is not the live-cutover verifier" "runbook should keep validate-stripe as test-mode only"
    assert_contains "$content" "SSM parameter history rollback (version restore) for runtime Stripe values" "runbook should define rollback via SSM parameter history"
    assert_contains "$content" "operator comment markers are metadata only and are not runtime config values" "runbook should define marker boundary"
}

test_runbook_anchors_ses_contract_to_existing_readiness_docs() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return

    assert_contains "$content" "docs/runbooks/email-production.md" "runbook should cross-reference email-production SES procedure"
    assert_contains "$content" "scripts/validate_ses_readiness.sh" "runbook should reference validate_ses_readiness.sh"
    assert_contains "$content" "SesConfig::from_reader" "runbook should reference SesConfig::from_reader"
    assert_contains "$content" "AWS credential chain" "runbook should defer credential-chain handling to email-production"
    assert_not_contains "$content" "bash scripts/validate_ses_readiness.sh --identity \"\$SES_FROM_ADDRESS\" --region \"\$SES_REGION\"" "runbook should not expand SES args from inline-only assignments"
    assert_contains "$content" "bash scripts/validate_ses_readiness.sh --identity noreply@example.com --region us-east-1" "runbook should show SES readiness args with explicit placeholder literals"
}

test_runbook_defers_iam_rotation_details_to_evidence_bundle() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return
    load_iam_evidence_root || return

    assert_contains "$content" "## IAM Rotation Evidence Pointer" "runbook should include a dedicated IAM rotation pointer section"
    assert_contains "$content" "${IAM_EVIDENCE_ROOT}/" "runbook should point to the canonical IAM evidence root"
    assert_contains "$content" "discovery_summary.json" "runbook should reference the IAM discovery summary artifact"
    assert_contains "$content" "iam_plan.json" "runbook should reference the IAM plan artifact"
    assert_contains "$content" "stage3/simulations/summary.json" "runbook should reference Stage 3 IAM simulation summary"
    assert_contains "$content" "stage3/live_path_deploy_staging_success_62fabe596675b28023c8d374125cd4c758110f36_ssm_get_command_invocation.json" "runbook should reference Stage 3 live-path evidence"
    assert_iam_artifact_exists "discovery_summary.json" "IAM discovery summary artifact should exist under the lane 7 evidence root"
    assert_iam_artifact_exists "iam_plan.json" "IAM plan artifact should exist under the lane 7 evidence root"
    assert_iam_artifact_exists "stage3/simulations/summary.json" "IAM Stage 3 simulation summary should exist under the lane 7 evidence root"
    assert_iam_artifact_exists "stage3/live_path_deploy_staging_success_62fabe596675b28023c8d374125cd4c758110f36_ssm_get_command_invocation.json" "IAM Stage 3 live-path evidence should exist under the lane 7 evidence root"
}

test_runbook_documents_single_key_jwt_cutover_constraints() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return

    assert_contains "$content" "Config::from_reader" "runbook should reference Config::from_reader"
    assert_contains "$content" "issue_jwt" "runbook should reference issue_jwt"
    assert_contains "$content" "AuthenticatedTenant::from_request_parts" "runbook should reference JWT verify path in tenant extractor"
    assert_contains "$content" "extract_tenant_id_from_jwt" "runbook should reference JWT verify path in middleware"
    assert_contains "$content" "RequestSpan::extract_tenant_id" "runbook should reference JWT verify path in request logging"
    assert_contains "$content" "single JWT_SECRET" "runbook should state that one JWT secret is used"
    assert_contains "$content" "not seamless" "runbook should state JWT rotation is not seamless"
    assert_contains "$content" "invalidate outstanding bearer tokens" "runbook should state token invalidation impact"
    assert_contains "$content" "deploy/restart" "runbook should document deploy/restart requirement for new secret"
}

test_runbook_avoids_internal_auth_secret_argv_exposure() {
    local content
    content="$(load_required_file "$RUNBOOK_PATH" "secret rotation runbook should exist at docs/runbooks/secret_rotation.md")" || return

    assert_contains "$content" "Do not pass the decrypted token" "runbook should warn against argv-based internal auth token handling"
    assert_contains "$content" '`sed` replacement or `curl -H` argument' "runbook should name the unsafe argv patterns to avoid"
    assert_contains "$content" 'printf '\''%s'\'' "$NEW_KEY" | sudo python3 -c '\''' "runbook should update metering env from stdin instead of argv"
    assert_contains "$content" 'curl --silent --show-error --output /dev/null --write-out '\''%{http_code}'\'' --config - <<EOF' "runbook should verify internal auth with curl config from stdin"
    assert_not_contains "$content" 'sudo sed -i "s|^INTERNAL_KEY=.*|INTERNAL_KEY=$NEW_KEY|"' "runbook should not place INTERNAL_KEY secrets in sed argv"
    assert_not_contains "$content" 'curl -H "x-internal-key: $INTERNAL_KEY" "$TENANT_MAP_URL"' "runbook should not place internal auth header secrets in curl argv"
}

test_launch_and_incident_docs_link_secret_rotation_runbook() {
    local launch_content incident_content
    launch_content="$(load_required_file "$LAUNCH_RUNBOOK_PATH" "launch-backend runbook should exist at docs/runbooks/launch-backend.md")" || return
    incident_content="$(load_required_file "$INCIDENT_RUNBOOK_PATH" "incident-response runbook should exist at docs/runbooks/incident-response.md")" || return

    assert_contains "$launch_content" "docs/runbooks/secret_rotation.md" "launch-backend runbook should link to secret rotation runbook"
    assert_contains "$launch_content" "SELECT COUNT(*) FROM usage_records WHERE recorded_at >= NOW() - INTERVAL '1 hour'" "launch-backend runbook should use recorded_at for usage_records recency checks"
    assert_not_contains "$launch_content" "SELECT COUNT(*) FROM usage_records WHERE created_at >= NOW() - INTERVAL '1 hour'" "launch-backend runbook should not use created_at for usage_records recency checks"
    assert_contains "$incident_content" "docs/runbooks/secret_rotation.md" "incident-response runbook should link to secret rotation runbook"
}

echo "=== secret rotation runbook contract tests ==="
test_secret_rotation_runbook_exists
test_runbook_references_env_vars_contract
test_runbook_covers_required_rotation_sections
test_runbook_anchors_stripe_contract_to_canonical_checks
test_runbook_anchors_ses_contract_to_existing_readiness_docs
test_runbook_defers_iam_rotation_details_to_evidence_bundle
test_runbook_documents_single_key_jwt_cutover_constraints
test_runbook_avoids_internal_auth_secret_argv_exposure
test_launch_and_incident_docs_link_secret_rotation_runbook

echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
