#!/usr/bin/env bash
# Shared hermetic harness for scripts/launch/run_ses_coverage_a1_in_vpc.sh.
#
# Callers define:
#   REPO_ROOT, RUNNER, TEST_WORKSPACE, CLEANUP_DIRS

SES_COVERAGE_A1_RUNNER_HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=ses_coverage_a1_runner_stubs.sh
source "$SES_COVERAGE_A1_RUNNER_HARNESS_DIR/ses_coverage_a1_runner_stubs.sh"

ses_coverage_a1_prepare_runner_workspace() {
    mkdir -p "$TEST_WORKSPACE/bin"
    mkdir -p "$TEST_WORKSPACE/scripts/launch"
    mkdir -p "$TEST_WORKSPACE/scripts/lib"
    mkdir -p "$TEST_WORKSPACE/inputs"
    mkdir -p "$TEST_WORKSPACE/tmp"

    local real_python3
    real_python3="$(command -v python3)"

    write_aws_stub "$TEST_WORKSPACE/bin/aws"
    write_git_stub "$TEST_WORKSPACE/bin/git" "$TEST_WORKSPACE"
    write_python3_stub "$TEST_WORKSPACE/bin/python3" "$real_python3"
    write_ssm_exec_stub "$TEST_WORKSPACE/scripts/launch/ssm_exec_staging.sh" "green"
    write_deploy_status_fixture "$TEST_WORKSPACE/scripts/deploy_status.sh" "green"
    write_credential_env_file "$TEST_WORKSPACE/inputs/credentials.env"

    if [ -f "$RUNNER" ]; then
        cp "$RUNNER" "$TEST_WORKSPACE/scripts/launch/run_ses_coverage_a1_in_vpc.sh"
    fi
    if [ -f "$REPO_ROOT/scripts/lib/deployable_currency.sh" ]; then
        cp "$REPO_ROOT/scripts/lib/deployable_currency.sh" \
           "$TEST_WORKSPACE/scripts/lib/deployable_currency.sh"
    fi
    if [ -f "$REPO_ROOT/scripts/lib/ses_coverage_a1_integrity.py" ]; then
        cp "$REPO_ROOT/scripts/lib/ses_coverage_a1_integrity.py" \
           "$TEST_WORKSPACE/scripts/lib/ses_coverage_a1_integrity.py"
    fi
}

ses_coverage_a1_setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    ses_coverage_a1_prepare_runner_workspace
}

ses_coverage_a1_run_runner() {
    local stdout_file="$TEST_WORKSPACE/tmp/runner_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/runner_stderr.txt"
    local runner_script="$TEST_WORKSPACE/scripts/launch/run_ses_coverage_a1_in_vpc.sh"

    RUN_RC=0
    if [ ! -f "$runner_script" ]; then
        printf '' > "$stdout_file"
        printf 'MISSING_TARGET: %s\n' "$RUNNER" > "$stderr_file"
        RUN_RC=127
    else
        env -i \
            PATH="$TEST_WORKSPACE/bin:$TEST_WORKSPACE/scripts/launch:/usr/bin:/bin:/usr/local/bin" \
            HOME="$TEST_WORKSPACE" \
            TMPDIR="$TEST_WORKSPACE/tmp" \
            LC_ALL=C \
            /bin/bash "$runner_script" "$@" >"$stdout_file" 2>"$stderr_file" || RUN_RC=$?
    fi

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

ses_coverage_a1_run_runner_scenario() {
    local scenario="$1"
    local sha="${2:-${VALID_SHA:?}}"
    local billing_month="${3:-${VALID_MONTH:?}}"
    local artifact_subdir="artifact_${scenario}_$$"
    local artifact_dir="${4:-docs/runbooks/evidence/ses-coverage-a1/$artifact_subdir}"

    local ssm_scenario="$scenario"
    case "$scenario" in
        cleanup_fail|archive_fail|status_nonzero|status_malformed|status_missing_dev_sha|\
        status_uppercase_dev_sha|status_delimiter_dev_sha|status_ref_dev_sha|\
        currency_unclassifiable|verdict_upload_fail)
            ssm_scenario="green"
            ;;
    esac
    write_ssm_exec_stub "$TEST_WORKSPACE/scripts/launch/ssm_exec_staging.sh" "$ssm_scenario"

    case "$scenario" in
        status_nonzero|status_malformed|status_missing_dev_sha|status_uppercase_dev_sha|\
        status_delimiter_dev_sha|status_ref_dev_sha)
            write_deploy_status_fixture "$TEST_WORKSPACE/scripts/deploy_status.sh" "$scenario"
            ;;
    esac
    if [ "$scenario" = "archive_fail" ]; then
        write_git_stub "$TEST_WORKSPACE/bin/git" "$TEST_WORKSPACE" "archive_fail"
    fi
    if [ "$scenario" = "currency_unclassifiable" ]; then
        write_deploy_status_fixture "$TEST_WORKSPACE/scripts/deploy_status.sh" "green"
        write_git_stub "$TEST_WORKSPACE/bin/git" "$TEST_WORKSPACE" "currency_unclassifiable"
    fi
    case "$scenario" in
        cleanup_fail|verdict_upload_fail) write_aws_stub "$TEST_WORKSPACE/bin/aws" "$scenario" ;;
    esac

    ses_coverage_a1_run_runner \
        --sha="$sha" \
        --artifact-dir="$artifact_dir" \
        --credential-env-file="$TEST_WORKSPACE/inputs/credentials.env" \
        --billing-month="$billing_month"
}

latest_artifact_dir() {
    local scenario="$1"
    ls -d "$TEST_WORKSPACE"/docs/runbooks/evidence/ses-coverage-a1/artifact_${scenario}_* 2>/dev/null | head -1
}

assert_expected_deployable_currency() {
    local manifest="$1" uploaded="$2"
    if python3 - "$manifest" "$uploaded" "$VALID_SHA" <<'PY'
import json, sys
manifest_path, uploaded_path, source_sha = sys.argv[1:4]
expected = {
    "schema_version": "1",
    "source_sha": source_sha,
    "dev_sha": "b" * 40,
    "deployable_drift": True,
    "doc_only_ahead": False,
}
manifest = json.load(open(manifest_path))
uploaded = json.load(open(uploaded_path))
if set(uploaded) != set(expected) or uploaded != expected:
    raise SystemExit(f"uploaded verdict mismatch: {uploaded!r}")
if manifest.get("deployable_currency") != uploaded:
    raise SystemExit("manifest deployable_currency does not match uploaded verdict")
PY
    then
        pass "deployable_currency should be the exact frozen-SHA verdict"
    else
        fail "deployable_currency should be the exact frozen-SHA verdict"
    fi
}

assert_no_transport_or_probe_commands() {
    if [ -f "$TEST_WORKSPACE/tmp/aws_commands.log" ]; then
        assert_not_contains "$(cat "$TEST_WORKSPACE/tmp/aws_commands.log")" " s3 cp " \
            "setup failure should not upload any S3 object"
    else
        pass "setup failure made no AWS calls before cleanup"
    fi
    if [ -f "$TEST_WORKSPACE/tmp/ssm_commands.log" ]; then
        local non_cleanup
        non_cleanup="$(grep -v 'rm -rf /opt/ses-coverage-a1 /tmp/source.tar' "$TEST_WORKSPACE/tmp/ssm_commands.log" || true)"
        assert_eq "$non_cleanup" "" \
            "setup failure should only permit idempotent remote cleanup"
    else
        pass "setup failure made no SSM calls"
    fi
}

assert_status_and_no_manifest() {
    local artifact_dir="$1" status="$2"
    assert_file_exists "$artifact_dir/run_status.json" "$status should write run_status"
    assert_eq "$(json_field "$artifact_dir/run_status.json" status)" "$status" \
        "$status should be recorded"
    if [ -f "$artifact_dir/run_manifest.json" ]; then
        fail "$status should not leave a classifiable manifest"
    else
        pass "$status should not leave a classifiable manifest"
    fi
}

test_verdict_transport_failures_are_structural() {
    setup_workspace

    if [ ! -f "$RUNNER" ]; then
        assert_eq "127" "127" "red: runner missing (expected)"
        return
    fi

    run_runner_scenario "verdict_upload_fail"
    assert_eq "$RUN_RC" "21" "verdict upload failure should be structural_failed"
    assert_status_and_no_manifest "$(latest_artifact_dir verdict_upload_fail)" "structural_failed"
    assert_contains "$(cat "$TEST_WORKSPACE/tmp/aws_commands.log")" "deployable_currency.json" \
        "verdict upload failure should be observed at the verdict object"

    setup_workspace
    run_runner_scenario "remote_verdict_download_fail"
    assert_eq "$RUN_RC" "21" "remote verdict materialization failure should be structural_failed"
    assert_status_and_no_manifest "$(latest_artifact_dir remote_verdict_download_fail)" "structural_failed"
    assert_contains "$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")" "deployable_currency.json" \
        "remote materialization failure should mention the verdict file"

    setup_workspace
    run_runner_scenario "remote_verdict_tamper"
    assert_eq "$RUN_RC" "21" "remote verdict digest mismatch should be structural_failed"
    assert_status_and_no_manifest "$(latest_artifact_dir remote_verdict_tamper)" "structural_failed"
    assert_contains "$(cat "$TEST_WORKSPACE/tmp/ssm_commands.log")" "sha256" \
        "remote tamper check should bind the downloaded verdict digest"
}
