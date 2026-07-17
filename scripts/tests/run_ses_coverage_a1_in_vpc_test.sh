#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/run_ses_coverage_a1_in_vpc.sh.
#
# Hermetic: stubs aws, git, python3, and ssm_exec_staging.sh on PATH so no
# external calls are made. Each test sets up a fresh temp workspace.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUNNER="$REPO_ROOT/scripts/launch/run_ses_coverage_a1_in_vpc.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"
source "$SCRIPT_DIR/lib/ses_coverage_a1_runner_harness.sh"

# Six probe IDs in the spec-required order.
PROBE_IDS=(
    verify_email_clickthrough
    password_reset_clickthrough
    dunning_email_inbox
    ses_bounce
    ses_complaint
    staging_dunning_delivery
)

VALID_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
VALID_MONTH="2026-07"

RUN_STDOUT=""
RUN_STDERR=""
RUN_RC=0
TEST_WORKSPACE=""
CLEANUP_DIRS=()

cleanup_workspaces() {
    for d in "${CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap cleanup_workspaces EXIT

setup_workspace() {
    ses_coverage_a1_setup_workspace
}

run_runner() {
    ses_coverage_a1_run_runner "$@"
}

# Helper: run runner with valid args but custom scenario stubs.
run_runner_scenario() {
    ses_coverage_a1_run_runner_scenario "$@"
}

# Helper: parse a JSON field from a file using python3.
json_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$file" "$field"
}

json_has_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if sys.argv[2] in d else 1)" "$file" "$field"
}

json_len() {
    local file="$1" field="$2"
    python3 -c "import json,sys; print(len(json.load(open(sys.argv[1]))[sys.argv[2]]))" "$file" "$field"
}

# --- argv contract tests ---

test_rejects_missing_sha() {
    setup_workspace
    run_runner \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "missing --sha should reject"
        assert_contains "$RUN_STDERR" "sha" "error should mention sha"
    fi
}

test_rejects_malformed_sha() {
    setup_workspace
    run_runner \
        --sha="not-a-sha" \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "malformed --sha should reject"
        assert_contains "$RUN_STDERR" "sha" "error should mention sha"
    fi
}

test_rejects_sha_too_short() {
    setup_workspace
    run_runner \
        --sha="aabbcc" \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "short --sha should reject"
    fi
}

test_rejects_missing_artifact_dir() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "missing --artifact-dir should reject"
        assert_contains "$RUN_STDERR" "artifact" "error should mention artifact-dir"
    fi
}

test_rejects_missing_credential_env_file() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "missing --credential-env-file should reject"
        assert_contains "$RUN_STDERR" "credential" "error should mention credential-env-file"
    fi
}

test_rejects_missing_billing_month() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "missing --billing-month should reject"
        assert_contains "$RUN_STDERR" "billing" "error should mention billing-month"
    fi
}

test_rejects_malformed_billing_month() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="docs/runbooks/evidence/ses-coverage-a1/test_bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="July-2026"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "malformed --billing-month should reject"
        assert_contains "$RUN_STDERR" "billing" "error should mention billing-month"
    fi
}

# --- artifact-dir hardening tests ---

test_rejects_absolute_artifact_dir() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="/tmp/absolute_path" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "absolute --artifact-dir should reject"
        assert_contains "$RUN_STDERR" "absolute" "error should mention absolute path"
    fi
}

test_rejects_dotdot_artifact_dir() {
    setup_workspace
    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="docs/runbooks/../../../etc/shadow" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "dotdot --artifact-dir should reject"
        assert_contains "$RUN_STDERR" ".." "error should mention .."
    fi
}

test_rejects_symlink_artifact_dir() {
    setup_workspace
    mkdir -p "$TEST_WORKSPACE/docs/runbooks/evidence/real_target"
    ln -s "$TEST_WORKSPACE/docs/runbooks/evidence/real_target" \
          "$TEST_WORKSPACE/docs/runbooks/evidence/link_dir"

    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="docs/runbooks/evidence/link_dir/bundle" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "symlink component --artifact-dir should reject"
        assert_contains "$RUN_STDERR" "symlink" "error should mention symlink"
    fi
}

test_rejects_nonempty_artifact_dir() {
    setup_workspace
    local nonempty_dir="docs/runbooks/evidence/ses-coverage-a1/nonempty_$$"
    mkdir -p "$TEST_WORKSPACE/$nonempty_dir"
    echo "existing file" > "$TEST_WORKSPACE/$nonempty_dir/existing.txt"

    run_runner \
        --sha="$VALID_SHA" \
        --artifact-dir="$nonempty_dir" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$VALID_MONTH"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
    else
        assert_ne "$RUN_RC" "0" "pre-existing non-empty --artifact-dir should reject"
        assert_contains "$RUN_STDERR" "non-empty" "error should mention non-empty"
    fi
}

# --- rc/status contract tests ---

test_green_scenario() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "all-green scenario should exit 0"

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_green_* 2>/dev/null | head -1)"

    assert_file_exists "$artifact_dir/run_status.json" "run_status.json should exist"
    assert_file_exists "$artifact_dir/run_manifest.json" "run_manifest.json should exist"

    local status rc
    status="$(json_field "$artifact_dir/run_status.json" status)"
    rc="$(json_field "$artifact_dir/run_status.json" rc)"
    assert_eq "$status" "green" "status should be green"
    assert_eq "$rc" "0" "status rc should be 0"

    json_has_field "$artifact_dir/run_status.json" "argv" && pass "run_status has argv" || fail "run_status missing argv"
    json_has_field "$artifact_dir/run_status.json" "instance_id" && pass "run_status has instance_id" || fail "run_status missing instance_id"

    local manifest_n source_sha billing_month
    manifest_n="$(json_field "$artifact_dir/run_manifest.json" n)"
    source_sha="$(json_field "$artifact_dir/run_manifest.json" source_sha)"
    billing_month="$(json_field "$artifact_dir/run_manifest.json" billing_month)"
    assert_eq "$manifest_n" "6" "manifest n should be 6"
    assert_eq "$source_sha" "$VALID_SHA" "manifest source_sha should match"
    assert_eq "$billing_month" "$VALID_MONTH" "manifest billing_month should match"

    json_has_field "$artifact_dir/run_manifest.json" "schema_version" && pass "manifest has schema_version" || fail "manifest missing schema_version"
    json_has_field "$artifact_dir/run_manifest.json" "archive_digest" && pass "manifest has archive_digest" || fail "manifest missing archive_digest"
    json_has_field "$artifact_dir/run_manifest.json" "bundle_path" && pass "manifest has bundle_path" || fail "manifest missing bundle_path"
    json_has_field "$artifact_dir/run_manifest.json" "probes" && pass "manifest has probes" || fail "manifest missing probes"
    json_has_field "$artifact_dir/run_manifest.json" "integrity_status" && pass "manifest has integrity_status" || fail "manifest missing integrity_status"
    json_has_field "$artifact_dir/run_manifest.json" "owner_digests" && pass "manifest has owner_digests" || fail "manifest missing owner_digests"

    local probes_len
    probes_len="$(json_len "$artifact_dir/run_manifest.json" probes)"
    assert_eq "$probes_len" "6" "manifest should have exactly 6 probe rows"

    local all_pass
    all_pass="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
print(all(p.get('pass') for p in m['probes']))
" "$artifact_dir/run_manifest.json")"
    assert_eq "$all_pass" "True" "all probes should pass in green scenario"

    assert_file_exists "$artifact_dir/probe_results.tsv" "probe_results.tsv should exist"
    assert_file_exists "$artifact_dir/all_green.txt" "all_green.txt should exist"
    assert_file_exists "$artifact_dir/failure_classifications.json" "failure_classifications.json should exist"
    assert_file_exists "$artifact_dir/GAP_SPEC.md" "GAP_SPEC.md should exist"
    if [ -s "$artifact_dir/GAP_SPEC.md" ]; then
        pass "GAP_SPEC.md should be nonempty"
    else
        fail "GAP_SPEC.md should be nonempty"
    fi

    local all_green_val
    all_green_val="$(cat "$artifact_dir/all_green.txt")"
    assert_eq "$all_green_val" "1" "all_green.txt should be 1 for green scenario"
    assert_expected_deployable_currency \
        "$artifact_dir/run_manifest.json" \
        "$TEST_WORKSPACE/tmp/uploaded_deployable_currency.json"

    rm -rf "$artifact_dir"
}

test_deployable_currency_uses_frozen_source_sha_not_ambient_main() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "green scenario should complete before inspecting currency"
    local artifact_dir
    artifact_dir="$(latest_artifact_dir green)"

    assert_file_exists "$TEST_WORKSPACE/tmp/uploaded_deployable_currency.json" \
        "verdict upload should preserve serialized JSON"
    assert_eq "$(wc -l < "$TEST_WORKSPACE/tmp/deploy_status_commands.log" | tr -d ' ')" "1" \
        "deploy_status should be acquired exactly once"
    assert_eq "$(cat "$TEST_WORKSPACE/tmp/deploy_status_commands.log")" "--json --env staging" \
        "deploy_status argv should remain unchanged"
    assert_contains "$(cat "$TEST_WORKSPACE/tmp/git_commands.log")" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb..$VALID_SHA" \
        "classifier should compare acquired dev_sha to frozen source sha"
    assert_not_contains "$(cat "$TEST_WORKSPACE/tmp/git_commands.log")" \
        "cccccccccccccccccccccccccccccccccccccccc..$VALID_SHA" \
        "classifier should not compare ambient main to frozen source sha"
    assert_expected_deployable_currency \
        "$artifact_dir/run_manifest.json" \
        "$TEST_WORKSPACE/tmp/uploaded_deployable_currency.json"
    rm -rf "$artifact_dir"
}

test_hydrate_strips_archive_prefix_before_probe_execution() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "green scenario should complete before inspecting SSM commands"

    local commands
    commands="$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")"
    assert_contains "$commands" "tar xf /tmp/source.tar -C /opt/ses-coverage-a1 --strip-components=1" \
        "hydrate should strip the git archive prefix before probe execution"
    assert_contains "$commands" "aws s3 cp s3://fjcloud-releases-staging/ses-coverage-a1/$VALID_SHA/deployable_currency.json .runtime/deployable_currency.json" \
        "hydrate/materialize should place the verdict at the runtime path"
    assert_contains "$commands" "cd /opt/ses-coverage-a1 && FJCLOUD_DEPLOYABLE_CURRENCY_JSON=.runtime/deployable_currency.json FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA=$VALID_SHA bash scripts/probe_verify_email_clickthrough_e2e.sh --env-file .runtime/host.env" \
        "probes should execute from the hydrated repo root with injected currency and env-file"
}

test_materialize_host_env_runs_before_probes() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "green scenario should complete before inspecting SSM commands"

    local commands
    commands="$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")"
    assert_contains "$commands" "mkdir -p .runtime && aws s3 cp s3://fjcloud-releases-staging/ses-coverage-a1/$VALID_SHA/deployable_currency.json .runtime/deployable_currency.json && python3 -c 'import hashlib" \
        "materialize_host_env should materialize and digest-check verdict before host.env"

    local materialize_line probe_line
    materialize_line="$(grep -n 'hydrate_seeder_env_from_ssm' "$TEST_WORKSPACE/tmp/ssm_commands.log" | head -1 | cut -d: -f1)"
    probe_line="$(grep -n 'probe_verify_email_clickthrough' "$TEST_WORKSPACE/tmp/ssm_commands.log" | head -1 | cut -d: -f1)"
    if [ -n "$materialize_line" ] && [ -n "$probe_line" ]; then
        if [ "$materialize_line" -lt "$probe_line" ]; then
            pass "materialize runs before first probe"
        else
            fail "materialize should run before probes (line $materialize_line vs $probe_line)"
        fi
    else
        fail "could not find materialize and probe lines in SSM command log"
    fi
}

test_probe_commands_include_env_file_and_flags() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "green scenario should complete before inspecting probe commands"

    local commands
    commands="$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")"

    assert_contains "$commands" "probe_verify_email_clickthrough_e2e.sh --env-file .runtime/host.env" \
        "verify_email_clickthrough should get --env-file"
    assert_contains "$commands" "probe_password_reset_clickthrough_e2e.sh --env-file .runtime/host.env" \
        "password_reset_clickthrough should get --env-file"
    assert_contains "$commands" "probe_dunning_email_inbox_e2e.sh --env-file .runtime/host.env --month $VALID_MONTH" \
        "dunning_email_inbox should get --env-file and --month"
    assert_contains "$commands" "probe_ses_bounce_complaint_e2e.sh bounce .runtime/host.env" \
        "ses_bounce should get positional env-file after mode"
    assert_contains "$commands" "probe_ses_bounce_complaint_e2e.sh complaint .runtime/host.env" \
        "ses_complaint should get positional env-file after mode"
    assert_contains "$commands" "validate_staging_dunning_delivery.sh --env-file .runtime/host.env --month $VALID_MONTH --confirm-live-mutation" \
        "staging_dunning_delivery should get --env-file, --month, and --confirm-live-mutation"
    local injected_count
    injected_count="$(grep -c 'FJCLOUD_DEPLOYABLE_CURRENCY_JSON=.runtime/deployable_currency.json FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA=' "$TEST_WORKSPACE/tmp/ssm_commands.log")"
    assert_eq "$injected_count" "6" "all six probe commands should receive deployable-currency inputs"
    assert_contains "$commands" \
        "FJCLOUD_DEPLOYABLE_CURRENCY_JSON=.runtime/deployable_currency.json FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA=$VALID_SHA bash scripts/probe_verify_email_clickthrough_e2e.sh --env-file .runtime/host.env" \
        "injection should preserve verify-email flags"
}

test_default_transport_bucket_matches_existing_staging_bucket() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "0" "green scenario should complete before inspecting SSM commands"

    local commands
    commands="$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")"
    assert_contains "$commands" "s3://fjcloud-releases-staging/ses-coverage-a1/" \
        "default transport bucket should be the existing staging releases bucket"
    local aws_commands
    aws_commands="$(cat "$TEST_WORKSPACE/tmp/aws_commands.log")"
    assert_contains "$aws_commands" "s3://fjcloud-releases-staging/ses-coverage-a1/$VALID_SHA/source.tar" \
        "archive should upload under the source SHA prefix"
    assert_contains "$aws_commands" "s3://fjcloud-releases-staging/ses-coverage-a1/$VALID_SHA/deployable_currency.json" \
        "verdict should upload under the source SHA prefix"
}

test_complete_red_scenario() {
    setup_workspace
    run_runner_scenario "complete_red"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "10" "complete_red scenario should exit 10"

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_complete_red_* 2>/dev/null | head -1)"

    local status rc
    status="$(json_field "$artifact_dir/run_status.json" status)"
    rc="$(json_field "$artifact_dir/run_status.json" rc)"
    assert_eq "$status" "complete_red" "status should be complete_red"
    assert_eq "$rc" "10" "status rc should be 10"

    local all_green_val
    all_green_val="$(cat "$artifact_dir/all_green.txt")"
    assert_eq "$all_green_val" "0" "all_green.txt should be 0 for red scenario"

    local failures_count
    failures_count="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print(len(d.get('failures',[])))
" "$artifact_dir/failure_classifications.json")"
    assert_ne "$failures_count" "0" "failure_classifications should have entries for red scenario"
    assert_file_exists "$artifact_dir/GAP_SPEC.md" "complete_red should emit GAP_SPEC.md"
    if [ -s "$artifact_dir/GAP_SPEC.md" ]; then
        pass "complete_red GAP_SPEC.md should be nonempty"
    else
        fail "complete_red GAP_SPEC.md should be nonempty"
    fi

    local has_classifications
    has_classifications="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
classified = [p for p in m['probes'] if not p.get('pass') and 'classification' in p]
print(len(classified) > 0)
" "$artifact_dir/run_manifest.json")"
    assert_eq "$has_classifications" "True" "failed probes should have per-probe classifications in manifest"

    local classifications_valid
    classifications_valid="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
valid_cats = {'setup_infra','real_defect','investigate'}
for p in m['probes']:
    if not p.get('pass') and 'classification' in p:
        if p['classification_category'] not in valid_cats:
            print('False')
            sys.exit(0)
print('True')
" "$artifact_dir/run_manifest.json")"
    assert_eq "$classifications_valid" "True" "classification categories should be from the KAT-derived taxonomy"
    assert_expected_deployable_currency \
        "$artifact_dir/run_manifest.json" \
        "$TEST_WORKSPACE/tmp/uploaded_deployable_currency.json"

    rm -rf "$artifact_dir"
}

test_deployable_currency_setup_failures_stop_before_transport() {
    setup_workspace

    if [ ! -f "$RUNNER" ]; then
        assert_eq "127" "127" "red: runner missing (expected)"
        return
    fi

    for scenario in status_nonzero status_malformed status_missing_dev_sha status_uppercase_dev_sha status_delimiter_dev_sha status_ref_dev_sha currency_unclassifiable; do
        run_runner_scenario "$scenario"
        assert_eq "$RUN_RC" "20" "$scenario should exit setup_failed"
        assert_status_and_no_manifest "$(latest_artifact_dir "$scenario")" "setup_failed"
        assert_no_transport_or_probe_commands
        if [ "$scenario" = "status_ref_dev_sha" ]; then
            if [ -f "$TEST_WORKSPACE/tmp/git_commands.log" ]; then
                fail "commit-ish dev_sha should fail before currency classification"
            else
                pass "commit-ish dev_sha should fail before currency classification"
            fi
        fi
        if [ "$scenario" = "currency_unclassifiable" ]; then
            assert_contains "$(cat "$TEST_WORKSPACE/tmp/git_commands.log")" \
                "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb..$VALID_SHA" \
                "unclassifiable currency should exercise the acquired dev_sha range"
        fi
        rm -f "$TEST_WORKSPACE/tmp/aws_commands.log" "$TEST_WORKSPACE/tmp/ssm_commands.log" \
              "$TEST_WORKSPACE/tmp/deploy_status_commands.log" "$TEST_WORKSPACE/tmp/git_commands.log"
        rm -rf "$(latest_artifact_dir "$scenario")"
    done
}

test_setup_failed_scenario() {
    setup_workspace
    run_runner_scenario "archive_fail"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "20" "git archive failure should exit 20 (setup_failed)"

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_archive_fail_* 2>/dev/null | head -1)"

    if [ -n "$artifact_dir" ] && [ -f "$artifact_dir/run_status.json" ]; then
        local status
        status="$(json_field "$artifact_dir/run_status.json" status)"
        assert_eq "$status" "setup_failed" "status should be setup_failed"
        rm -rf "$artifact_dir"
    else
        pass "no artifact dir expected for setup_failed (setup never completed)"
    fi
}

test_structural_failed_scenario() {
    setup_workspace
    run_runner_scenario "structural_failed"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "21" "SSM failure should exit 21 (structural_failed)"

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_structural_failed_* 2>/dev/null | head -1)"

    if [ -n "$artifact_dir" ] && [ -f "$artifact_dir/run_status.json" ]; then
        local status
        status="$(json_field "$artifact_dir/run_status.json" status)"
        assert_eq "$status" "structural_failed" "status should be structural_failed"
        rm -rf "$artifact_dir"
    else
        pass "no artifact dir for structural_failed (infra never reached)"
    fi
}

test_cleanup_failed_scenario() {
    setup_workspace
    run_runner_scenario "cleanup_fail"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    assert_eq "$RUN_RC" "22" "S3 cleanup failure should exit 22 (cleanup_failed)"

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_cleanup_fail_* 2>/dev/null | head -1)"

    if [ -n "$artifact_dir" ] && [ -f "$artifact_dir/run_status.json" ]; then
        local status
        status="$(json_field "$artifact_dir/run_status.json" status)"
        assert_eq "$status" "cleanup_failed" "status should be cleanup_failed"
        assert_contains "$(cat "$TEST_WORKSPACE/tmp/aws_commands.log")" \
            "s3://fjcloud-releases-staging/ses-coverage-a1/$VALID_SHA" \
            "cleanup should remove the whole source-SHA prefix"
        assert_contains "$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")" \
            "rm -rf /opt/ses-coverage-a1 /tmp/source.tar /tmp/deployable_currency.json" \
            "cleanup should remove remote transport artifacts"
        rm -rf "$artifact_dir"
    else
        pass "no cleanup_failed artifact dir to check"
    fi
}

# --- classifiability tests ---

test_only_green_and_complete_red_are_classifiable() {
    setup_workspace

    if [ ! -f "$RUNNER" ]; then
        assert_eq "127" "127" "red: runner missing (expected)"
        return
    fi

    for scenario in archive_fail structural_failed cleanup_fail; do
        run_runner_scenario "$scenario"

        local artifact_dir
        artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_${scenario}_* 2>/dev/null | head -1)"

        if [ -n "$artifact_dir" ] && [ -f "$artifact_dir/run_manifest.json" ]; then
            local has_probe_results
            has_probe_results="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
probes=m.get('probes',[])
print(any(p.get('pass') is not None for p in probes))
" "$artifact_dir/run_manifest.json")"
            assert_ne "$has_probe_results" "True" \
                "rc=$RUN_RC ($scenario) should not have classifiable probe results"
            rm -rf "$artifact_dir"
        else
            pass "$scenario: no manifest with classifiable results (correct)"
        fi
    done
}

# --- run_manifest.json structural checks ---

test_manifest_probe_ids_match_spec() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_green_* 2>/dev/null | head -1)"

    local probe_ids_match
    probe_ids_match="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
expected = ['verify_email_clickthrough','password_reset_clickthrough',
            'dunning_email_inbox','ses_bounce','ses_complaint',
            'staging_dunning_delivery']
actual = [p['probe_id'] for p in m['probes']]
print(actual == expected)
" "$artifact_dir/run_manifest.json")"
    assert_eq "$probe_ids_match" "True" "manifest probe_ids should match spec order"

    local each_probe_has_fields
    each_probe_has_fields="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
required = {'probe_id','pass','rc','log_path','detect_kind'}
for p in m['probes']:
    if not required.issubset(set(p.keys())):
        print('False')
        sys.exit(0)
print('True')
" "$artifact_dir/run_manifest.json")"
    assert_eq "$each_probe_has_fields" "True" "each probe row should have required fields"

    rm -rf "$artifact_dir"
}

test_manifest_owner_digests_present() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_green_* 2>/dev/null | head -1)"

    local has_integrity_sha
    has_integrity_sha="$(python3 -c "
import json,sys
m=json.load(open(sys.argv[1]))
d=m.get('owner_digests',{})
print('integrity_library' in d and len(d['integrity_library']) == 64)
" "$artifact_dir/run_manifest.json")"
    assert_eq "$has_integrity_sha" "True" "manifest should have integrity_library SHA-256 digest"

    rm -rf "$artifact_dir"
}

# --- run_status.json structural checks ---

test_status_has_required_fields() {
    setup_workspace
    run_runner_scenario "green"

    if [ ! -f "$RUNNER" ]; then
        assert_eq "$RUN_RC" "127" "red: runner missing (expected)"
        return
    fi

    local artifact_dir
    artifact_dir="$(ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_green_* 2>/dev/null | head -1)"

    for field in status rc argv instance_id; do
        json_has_field "$artifact_dir/run_status.json" "$field" \
            && pass "run_status has $field" \
            || fail "run_status missing $field"
    done

    local status_set_valid
    status_set_valid="$(python3 -c "
import json,sys
s=json.load(open(sys.argv[1]))
valid={'green','complete_red','setup_failed','structural_failed','cleanup_failed'}
print(s['status'] in valid)
" "$artifact_dir/run_status.json")"
    assert_eq "$status_set_valid" "True" "status value should be in the spec set"

    rm -rf "$artifact_dir"
}

# --- invoke test functions ---

test_rejects_missing_sha
test_rejects_malformed_sha
test_rejects_sha_too_short
test_rejects_missing_artifact_dir
test_rejects_missing_credential_env_file
test_rejects_missing_billing_month
test_rejects_malformed_billing_month
test_rejects_absolute_artifact_dir
test_rejects_dotdot_artifact_dir
test_rejects_symlink_artifact_dir
test_rejects_nonempty_artifact_dir
test_green_scenario
test_deployable_currency_uses_frozen_source_sha_not_ambient_main
test_hydrate_strips_archive_prefix_before_probe_execution
test_materialize_host_env_runs_before_probes
test_probe_commands_include_env_file_and_flags
test_default_transport_bucket_matches_existing_staging_bucket
test_complete_red_scenario
test_deployable_currency_setup_failures_stop_before_transport
test_setup_failed_scenario
test_structural_failed_scenario
test_verdict_transport_failures_are_structural
test_cleanup_failed_scenario
test_only_green_and_complete_red_are_classifiable
test_manifest_probe_ids_match_spec
test_manifest_owner_digests_present
test_status_has_required_fields

run_test_summary
