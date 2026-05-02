#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/post_deploy_evidence_capture.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$REPO_ROOT/scripts/launch/post_deploy_evidence_capture.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
CLEANUP_DIRS=()

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

assert_nonzero_exit() {
    local actual="$1" msg="$2"
    if [ "$actual" -ne 0 ]; then
        pass "$msg"
    else
        fail "$msg (actual exit code was 0)"
    fi
}

run_dir_count_under_root() {
    local root="$1"
    local count=0
    local d
    for d in "$root"/*; do
        [ -d "$d" ] || continue
        count=$((count + 1))
    done
    printf '%s\n' "$count"
}

first_run_dir_under_root() {
    local root="$1"
    local d
    for d in "$root"/*; do
        [ -d "$d" ] || continue
        printf '%s\n' "$d"
        return 0
    done
    printf '\n'
    return 0
}

assert_exactly_once_in_text() {
    local payload="$1" needle="$2" msg="$3"
    local count
    count="$(awk -v needle="$needle" 'index($0, needle) { count += 1 } END { print count + 0 }' <<< "$payload")"
    if [ "$count" -eq 1 ]; then
        pass "$msg"
    else
        fail "$msg (expected occurrence count=1 actual=$count needle=$needle)"
    fi
}

write_fixture_credentials_env() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIAPOSTDEPLOYFIXTURE
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_fixture_contract
STRIPE_WEBHOOK_SECRET=whsec_fixture_contract
ENVFILE
}

write_mock_commands() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    cat > "$TEST_WORKSPACE/bin/aws" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "aws|\$*" >> "\$CALL_LOG"
if [ "\${1:-}" = "sts" ] && [ "\${2:-}" = "get-caller-identity" ]; then
    printf '{"Account":"000000000000"}\n'
    exit 0
fi
if [ "\${1:-}" = "ssm" ] && [ "\${2:-}" = "get-parameter" ]; then
    printf '%s\n' "\${MOCK_LAST_DEPLOY_SHA:-0000000000000000000000000000000000000000}"
    exit 0
fi
exit 0
MOCK

    cat > "$TEST_WORKSPACE/bin/curl" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "curl|\$*" >> "\$CALL_LOG"
printf '{"ok":true}\n'
MOCK

    cat > "$TEST_WORKSPACE/bin/journalctl" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "journalctl|\$*" >> "\$CALL_LOG"
exit 0
MOCK

    cat > "$TEST_WORKSPACE/bin/stripe" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "stripe|\$*" >> "\$CALL_LOG"
exit 0
MOCK

    chmod +x "$TEST_WORKSPACE/bin/aws" "$TEST_WORKSPACE/bin/curl" "$TEST_WORKSPACE/bin/journalctl" "$TEST_WORKSPACE/bin/stripe"
}

overwrite_aws_mock_to_require_exported_credentials() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    cat > "$TEST_WORKSPACE/bin/aws" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "aws|\$*" >> "\$CALL_LOG"
: "\${AWS_ACCESS_KEY_ID:?missing aws access key in child process}"
if [ "\${1:-}" = "ssm" ] && [ "\${2:-}" = "get-parameter" ]; then
    printf '%s\n' "cccccccccccccccccccccccccccccccccccccccc"
    exit 0
fi
exit 0
MOCK

    chmod +x "$TEST_WORKSPACE/bin/aws"
}

overwrite_delegated_owners_to_require_stripe_key_bridge() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    cat > "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "run_full_backend_validation|\$*" >> "\$CALL_LOG"
: "\${STRIPE_SECRET_KEY:?missing STRIPE_SECRET_KEY in backend validation}"
[ "\$STRIPE_SECRET_KEY" = "sk_test_fixture_contract" ]
printf '{"verdict":"pass"}\n'
exit 0
MOCK

    cat > "$TEST_WORKSPACE/scripts/validate-stripe.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
CALL_LOG=$quoted_log
echo "validate_stripe|\$*" >> "\$CALL_LOG"
: "\${STRIPE_SECRET_KEY:?missing STRIPE_SECRET_KEY in validate-stripe}"
[ "\$STRIPE_SECRET_KEY" = "sk_test_fixture_contract" ]
exit 0
MOCK

    chmod +x "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" "$TEST_WORKSPACE/scripts/validate-stripe.sh"
}

write_mock_delegated_owners() {
    local quoted_log
    quoted_log="$(shell_quote_for_script "$TEST_CALL_LOG")"

    mkdir -p "$TEST_WORKSPACE/scripts/launch" "$TEST_WORKSPACE/scripts"

    cat > "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "run_full_backend_validation|\$*" >> $quoted_log
printf '{"verdict":"pass"}\n'
exit 0
MOCK

    cat > "$TEST_WORKSPACE/scripts/validate-stripe.sh" <<MOCK
#!/usr/bin/env bash
set -euo pipefail
echo "validate_stripe|\$*" >> $quoted_log
exit 0
MOCK

    chmod +x "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" "$TEST_WORKSPACE/scripts/validate-stripe.sh"
}

copy_workspace_dependencies() {
    mkdir -p "$TEST_WORKSPACE/scripts/launch" "$TEST_WORKSPACE/scripts/lib"
    if [ -f "$TARGET_SCRIPT" ]; then
        cp "$TARGET_SCRIPT" "$TEST_WORKSPACE/scripts/launch/post_deploy_evidence_capture.sh"
        chmod +x "$TEST_WORKSPACE/scripts/launch/post_deploy_evidence_capture.sh"
    fi

    cp "$REPO_ROOT/scripts/lib"/*.sh "$TEST_WORKSPACE/scripts/lib/" 2>/dev/null || true
}

setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")

    mkdir -p "$TEST_WORKSPACE/bin" "$TEST_WORKSPACE/tmp" "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs"
    TEST_CALL_LOG="$TEST_WORKSPACE/tmp/calls.log"
    : > "$TEST_CALL_LOG"

    copy_workspace_dependencies
    write_mock_commands
    write_mock_delegated_owners
    write_fixture_credentials_env "$TEST_WORKSPACE/inputs/credentials.env"
}

_run_post_deploy_capture() {
    local cli_args=""
    local env_args=()
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --args)
                cli_args="$2"
                shift 2
                ;;
            *)
                env_args+=("$1")
                shift
                ;;
        esac
    done

    local wrapper_script="$TEST_WORKSPACE/scripts/launch/post_deploy_evidence_capture.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/post_deploy_stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/post_deploy_stderr.txt"

    env_args+=("PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin")
    env_args+=("HOME=$TEST_WORKSPACE")
    env_args+=("TMPDIR=$TEST_WORKSPACE/tmp")

    RUN_EXIT_CODE=0
    if [ -n "$cli_args" ]; then
        # shellcheck disable=SC2086
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" $cli_args >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    else
        (cd "$TEST_WORKSPACE" && env -i "${env_args[@]}" /bin/bash "$wrapper_script" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    fi

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

validate_dry_run_order() {
    local output_file="$1"
    awk '
BEGIN {
    expected[1] = "[dry-run] STAGE_0: would verify deploy advanced past --reject-known-bad-sha"
    expected[2] = "[dry-run] STAGE_1: would curl https://api.<dns_domain>/health"
    expected[3] = "[dry-run] STAGE_1: would journalctl-grep STRIPE_SECRET_KEY warning count"
    expected[4] = "[dry-run] STAGE_1: would invoke validate-stripe.sh"
    expected[5] = "[dry-run] STAGE_2: would journalctl-grep alert webhook configured"
    expected[6] = "[dry-run] STAGE_3: would invoke run_full_backend_validation.sh --paid-beta-rc"
    state = 1
}
{
    if (state > 6) {
        next
    }
    if ($0 == expected[state]) {
        state += 1
        next
    }
    if ($0 ~ /^\[dry-run\]/) {
        print "unexpected dry-run line while waiting for: " expected[state] " ; got: " $0
        exit 1
    }
}
END {
    if (state <= 6) {
        print "missing dry-run line: " expected[state]
        exit 1
    }
}
' "$output_file"
}

common_required_args() {
    local artifact_dir="$1"
    local credentials_file="$2"
    printf '%s' "--sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --artifact-dir=$artifact_dir --credential-env-file=$credentials_file --billing-month=2026-04 --staging-smoke-ami-id=ami-0123456789abcdef0"
}

test_script_exists_and_executable() {
    local exists="no"
    local executable="no"
    [ -f "$TARGET_SCRIPT" ] && exists="yes"
    [ -x "$TARGET_SCRIPT" ] && executable="yes"
    assert_eq "$exists" "yes" "post_deploy_evidence_capture.sh should exist"
    assert_eq "$executable" "yes" "post_deploy_evidence_capture.sh should be executable"
}

test_help_contract_usage_surface() {
    setup_workspace
    _run_post_deploy_capture --args "--help"

    assert_eq "$RUN_EXIT_CODE" "0" "--help should exit 0"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "Usage: post_deploy_evidence_capture.sh" "--help should include usage header"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--sha=<git-sha>" "--help should include --sha=<git-sha>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--artifact-dir=<dir>" "--help should include --artifact-dir=<dir>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--credential-env-file=<path>" "--help should include --credential-env-file=<path>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--billing-month=<YYYY-MM>" "--help should include --billing-month=<YYYY-MM>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--staging-smoke-ami-id=<ami-id>" "--help should include --staging-smoke-ami-id=<ami-id>"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--dry-run" "--help should include --dry-run"
    assert_contains "$RUN_STDOUT$RUN_STDERR" "--reject-known-bad-sha=<sha>" "--help should include --reject-known-bad-sha=<sha>"
}

test_cli_unknown_argument_exits_2() {
    setup_workspace
    local args
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    _run_post_deploy_capture --args "$args --unknown-flag"

    assert_eq "$RUN_EXIT_CODE" "2" "unknown argument should exit 2"
    assert_contains "$RUN_STDERR" "ERROR: unknown argument" "unknown argument should emit canonical error fragment"
}

test_cli_missing_required_flags_exit_2() {
    setup_workspace
    local args

    _run_post_deploy_capture
    assert_eq "$RUN_EXIT_CODE" "2" "missing --sha should exit 2"
    assert_contains "$RUN_STDERR" "missing required argument: --sha" "missing --sha should emit canonical error text"

    args="--sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    _run_post_deploy_capture --args "$args"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --artifact-dir should exit 2"
    assert_contains "$RUN_STDERR" "missing required argument: --artifact-dir" "missing --artifact-dir should emit canonical error text"

    args="--sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --artifact-dir=$TEST_WORKSPACE/artifacts"
    _run_post_deploy_capture --args "$args"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --credential-env-file should exit 2"
    assert_contains "$RUN_STDERR" "missing required argument: --credential-env-file" "missing --credential-env-file should emit canonical error text"

    args="--sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --artifact-dir=$TEST_WORKSPACE/artifacts --credential-env-file=$TEST_WORKSPACE/inputs/credentials.env"
    _run_post_deploy_capture --args "$args"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --billing-month should exit 2"
    assert_contains "$RUN_STDERR" "missing required argument: --billing-month" "missing --billing-month should emit canonical error text"

    args="--sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --artifact-dir=$TEST_WORKSPACE/artifacts --credential-env-file=$TEST_WORKSPACE/inputs/credentials.env --billing-month=2026-04"
    _run_post_deploy_capture --args "$args"
    assert_eq "$RUN_EXIT_CODE" "2" "missing --staging-smoke-ami-id should exit 2"
    assert_contains "$RUN_STDERR" "missing required argument: --staging-smoke-ami-id" "missing --staging-smoke-ami-id should emit canonical error text"
}

test_dry_run_planned_actions_are_ordered_and_side_effect_free() {
    setup_workspace

    local args out_file order_result
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --dry-run --reject-known-bad-sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --reject-known-bad-sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"
    assert_eq "$RUN_EXIT_CODE" "0" "dry-run with required inputs should exit 0"

    out_file="$TEST_WORKSPACE/tmp/dry_run_out.log"
    printf '%s\n' "$RUN_STDOUT" > "$out_file"

    if order_result="$(validate_dry_run_order "$out_file" 2>&1)"; then
        pass "dry-run should print the six planned-action lines in strict order"
    else
        fail "dry-run ordering contract failed: $order_result"
    fi

    assert_eq "$(grep -E "^(aws|curl|journalctl|stripe|run_full_backend_validation|validate_stripe)\|" "$TEST_CALL_LOG" 2>/dev/null || true)" "" "dry-run should not invoke live AWS/Stripe/curl/journalctl/delegated owners"
}

test_dry_run_artifact_layout_contract() {
    setup_workspace
    local artifact_root args
    artifact_root="$TEST_WORKSPACE/artifacts"
    args="$(common_required_args "$artifact_root" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --dry-run"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"

    assert_eq "$RUN_EXIT_CODE" "0" "dry-run artifact layout path should exit 0"
    assert_eq "$(run_dir_count_under_root "$artifact_root")" "1" "wrapper should create exactly one run directory under artifact root"

    local run_dir
    run_dir="$(first_run_dir_under_root "$artifact_root")"
    if [ -d "$run_dir/logs" ]; then
        pass "run directory should include logs/"
    else
        fail "run directory should include logs/"
    fi
    if [ -f "$run_dir/summary.json" ]; then
        pass "run directory should include summary.json"
    else
        fail "run directory should include summary.json"
    fi

    assert_exactly_once_in_text "$RUN_STDOUT" "01_stripe_runtime/" "dry-run output should include 01_stripe_runtime/ exactly once"
    assert_exactly_once_in_text "$RUN_STDOUT" "02_alert_log/" "dry-run output should include 02_alert_log/ exactly once"
    assert_exactly_once_in_text "$RUN_STDOUT" "03_paid_beta_rc/" "dry-run output should include 03_paid_beta_rc/ exactly once"
}

test_artifact_root_rejects_file_path_without_partial_run_dir() {
    setup_workspace
    local artifact_file artifact_parent args
    artifact_file="$TEST_WORKSPACE/inputs/not_a_directory"
    artifact_parent="$(dirname "$artifact_file")"
    printf 'sentinel\n' > "$artifact_file"

    args="$(common_required_args "$artifact_file" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --dry-run"

    _run_post_deploy_capture --args "$args"

    assert_nonzero_exit "$RUN_EXIT_CODE" "artifact-dir file path should fail nonzero"
    assert_eq "$(run_dir_count_under_root "$artifact_parent")" "0" "artifact-dir file path should not leave partial run directories"
}

test_credential_env_file_treated_as_data_not_executable_shell() {
    setup_workspace
    local marker_file args
    marker_file="$TEST_WORKSPACE/tmp/credential_exec_marker"

    cat > "$TEST_WORKSPACE/inputs/credentials.env" <<ENVFILE
AWS_ACCESS_KEY_ID=AKIAPOSTDEPLOYFIXTURE
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_test_\$(touch "$marker_file")
STRIPE_WEBHOOK_SECRET=whsec_fixture_contract
ENVFILE

    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    _run_post_deploy_capture --args "$args --dry-run"

    assert_eq "$RUN_EXIT_CODE" "0" "credential env parser should accept KEY=value lines containing shell metacharacters"
    if [ -e "$marker_file" ]; then
        fail "credential env parser must not execute command substitutions from credential values"
    else
        pass "credential env parser must treat credential values as inert data"
    fi
}

test_stripe_live_key_rejection_sk_live_reuses_canonical_text() {
    setup_workspace
    cat > "$TEST_WORKSPACE/inputs/credentials.env" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIAPOSTDEPLOYFIXTURE
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=sk_live_FAKE_FOR_TEST
STRIPE_WEBHOOK_SECRET=whsec_fixture_contract
ENVFILE

    local args
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    _run_post_deploy_capture --args "$args --dry-run"

    assert_nonzero_exit "$RUN_EXIT_CODE" "sk_live_ key should be rejected"
    assert_contains "$RUN_STDERR" "STRIPE_SECRET_KEY must start with sk_test_ or rk_test_ (sk_live_ and rk_live_ keys are not allowed)" "live-key rejection should reuse canonical stripe_checks text"
    assert_contains "$RUN_STDERR" "REASON: stripe_key_bad_prefix" "live-key rejection should preserve stripe_key_bad_prefix reason semantics"
}

test_stripe_live_key_rejection_rk_live_reuses_canonical_text() {
    setup_workspace
    cat > "$TEST_WORKSPACE/inputs/credentials.env" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIAPOSTDEPLOYFIXTURE
AWS_SECRET_ACCESS_KEY=fixture-secret
AWS_DEFAULT_REGION=us-east-1
STRIPE_SECRET_KEY_RESTRICTED=rk_live_FAKE_FOR_TEST
STRIPE_WEBHOOK_SECRET=whsec_fixture_contract
ENVFILE

    local args
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    _run_post_deploy_capture --args "$args --dry-run"

    assert_nonzero_exit "$RUN_EXIT_CODE" "rk_live_ key should be rejected"
    assert_contains "$RUN_STDERR" "STRIPE_SECRET_KEY must start with sk_test_ or rk_test_ (sk_live_ and rk_live_ keys are not allowed)" "restricted live-key rejection should reuse canonical stripe_checks text"
    assert_contains "$RUN_STDERR" "REASON: stripe_key_bad_prefix" "restricted live-key rejection should preserve stripe_key_bad_prefix reason semantics"
}

test_reject_known_bad_sha_accumulates_across_repeated_flags() {
    setup_workspace
    local args
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --dry-run --reject-known-bad-sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --reject-known-bad-sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    assert_nonzero_exit "$RUN_EXIT_CODE" "known-bad SHA match should fail"
    assert_contains "$RUN_STDERR" "deploy SHA bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb matches a known-bad SHA from the rejection list" "known-bad SHA match should use canonical message text"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"
    assert_eq "$RUN_EXIT_CODE" "0" "non-rejected SHA should pass reject-list gate"
    assert_contains "$RUN_STDOUT" "[dry-run] STAGE_0: would verify deploy advanced past --reject-known-bad-sha" "non-rejected SHA should continue to dry-run planned actions"
}

test_live_mode_reject_list_uses_exported_aws_credentials() {
    setup_workspace
    overwrite_aws_mock_to_require_exported_credentials

    local args call_lines
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --reject-known-bad-sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

    _run_post_deploy_capture --args "$args"

    assert_eq "$RUN_EXIT_CODE" "0" "live reject-list gate should inherit bare AWS credentials from credential env file"
    call_lines="$(grep -E '^(aws|run_full_backend_validation)\|' "$TEST_CALL_LOG" || true)"
    assert_contains "$call_lines" "aws|ssm get-parameter --name /fjcloud/staging/last_deploy_sha" "live reject-list gate should query the deployed SHA via AWS"
    assert_contains "$call_lines" "run_full_backend_validation|--paid-beta-rc" "live reject-list gate should continue into Stage 3 after AWS precheck succeeds"
}

test_restricted_stripe_key_alias_is_exported_to_delegated_owners() {
    setup_workspace
    overwrite_delegated_owners_to_require_stripe_key_bridge

    local args call_lines
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"

    assert_eq "$RUN_EXIT_CODE" "0" "restricted Stripe key alias should be bridged into delegated live validators"
    call_lines="$(grep -E '^(validate_stripe|run_full_backend_validation)\|' "$TEST_CALL_LOG" || true)"
    assert_contains "$call_lines" "validate_stripe|" "restricted Stripe key bridge should reach validate-stripe owner"
    assert_contains "$call_lines" "run_full_backend_validation|--paid-beta-rc" "restricted Stripe key bridge should reach backend validation owner"
}

test_run_id_collision_fails_fast_with_exact_message() {
    setup_workspace
    local args
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"
    args="$args --dry-run"

    _run_post_deploy_capture --args "$args" "POST_DEPLOY_RUN_ID=fixture_run_001" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"
    assert_eq "$RUN_EXIT_CODE" "0" "first run with deterministic RUN_ID should succeed"

    _run_post_deploy_capture --args "$args" "POST_DEPLOY_RUN_ID=fixture_run_001" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"
    assert_nonzero_exit "$RUN_EXIT_CODE" "second run with same deterministic RUN_ID should fail"
    assert_contains "$RUN_STDERR" "RUN_ID fixture_run_001 already exists; pass a fresh --artifact-dir or remove the existing run dir" "RUN_ID collision should fail fast with canonical message"
}

test_live_mode_zero_warning_counts_do_not_abort() {
    setup_workspace
    local args call_lines
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"

    assert_eq "$RUN_EXIT_CODE" "0" "live mode should succeed when journal warning count is zero"
    assert_eq "$(run_dir_count_under_root "$TEST_WORKSPACE/artifacts")" "1" "live mode should create exactly one run directory"

    call_lines="$(grep -E '^(curl|journalctl|validate_stripe|run_full_backend_validation)\|' "$TEST_CALL_LOG" || true)"
    assert_contains "$call_lines" "curl|-fsS https://api.flapjack.foo/health" "live mode should execute Stage 1 health curl"
    assert_contains "$call_lines" "validate_stripe|" "live mode should invoke validate-stripe owner"
    assert_contains "$call_lines" "run_full_backend_validation|--paid-beta-rc" "live mode should invoke Stage 3 delegated owner"
    assert_contains "$RUN_STDOUT" "01_stripe_runtime/" "live mode should print stage artifact dir names"
}

test_live_mode_without_journalctl_still_runs_and_writes_zero_counts() {
    setup_workspace
    local args run_dir stripe_count_path alert_count_path call_lines
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"

    rm -f "$TEST_WORKSPACE/bin/journalctl"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"

    assert_eq "$RUN_EXIT_CODE" "0" "live mode should not fail when host journalctl is unavailable"
    assert_contains "$RUN_STDERR" "WARNING: journalctl not found on host; writing fallback zero count for STRIPE_SECRET_KEY" "missing journalctl should emit stripe fallback warning"
    assert_contains "$RUN_STDERR" "WARNING: journalctl not found on host; writing fallback zero count for alert webhook" "missing journalctl should emit alert fallback warning"

    run_dir="$(first_run_dir_under_root "$TEST_WORKSPACE/artifacts")"
    stripe_count_path="$run_dir/01_stripe_runtime/stripe_secret_key_warning_count.txt"
    alert_count_path="$run_dir/02_alert_log/alert_webhook_count.txt"
    assert_eq "$(cat "$stripe_count_path")" "0" "missing journalctl should force stripe warning count to 0"
    assert_eq "$(cat "$alert_count_path")" "0" "missing journalctl should force alert webhook count to 0"

    call_lines="$(grep -E '^(journalctl|validate_stripe|run_full_backend_validation)\|' "$TEST_CALL_LOG" || true)"
    assert_not_contains "$call_lines" "journalctl|" "missing journalctl fallback should not attempt journalctl invocation"
    assert_contains "$call_lines" "validate_stripe|" "missing journalctl fallback should still run validate-stripe owner"
    assert_contains "$call_lines" "run_full_backend_validation|--paid-beta-rc" "missing journalctl fallback should still run backend validation owner"
}

test_live_mode_failure_persists_fail_summary_json() {
    setup_workspace
    local args run_dir summary_json
    args="$(common_required_args "$TEST_WORKSPACE/artifacts" "$TEST_WORKSPACE/inputs/credentials.env")"

    cat > "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
exit 1
MOCK
    chmod +x "$TEST_WORKSPACE/scripts/launch/run_full_backend_validation.sh"

    _run_post_deploy_capture --args "$args" "MOCK_LAST_DEPLOY_SHA=cccccccccccccccccccccccccccccccccccccccc"

    assert_nonzero_exit "$RUN_EXIT_CODE" "live mode should fail when Stage 3 delegated owner fails"
    assert_eq "$(run_dir_count_under_root "$TEST_WORKSPACE/artifacts")" "1" "failed live mode should still create exactly one run directory"

    run_dir="$(first_run_dir_under_root "$TEST_WORKSPACE/artifacts")"
    if [ -f "$run_dir/summary.json" ]; then
        pass "failed live mode should still emit summary.json"
    else
        fail "failed live mode should still emit summary.json"
    fi

    summary_json="$(cat "$run_dir/summary.json")"
    assert_contains "$summary_json" "\"status\":\"fail\"" "failed live mode summary should set status fail"
    assert_contains "$summary_json" "\"run_id\":" "failed live mode summary should include run_id metadata"
    assert_contains "$summary_json" "\"sha\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"" "failed live mode summary should include sha metadata"
    assert_contains "$summary_json" "\"billing_month\":\"2026-04\"" "failed live mode summary should include billing_month metadata"
    assert_contains "$summary_json" "\"staging_smoke_ami_id\":\"ami-0123456789abcdef0\"" "failed live mode summary should include staging_smoke_ami_id metadata"
}

run_all_tests() {
    echo "=== post_deploy_evidence_capture.sh contract tests ==="
    test_script_exists_and_executable
    test_help_contract_usage_surface
    test_cli_unknown_argument_exits_2
    test_cli_missing_required_flags_exit_2
    test_dry_run_planned_actions_are_ordered_and_side_effect_free
    test_dry_run_artifact_layout_contract
    test_artifact_root_rejects_file_path_without_partial_run_dir
    test_credential_env_file_treated_as_data_not_executable_shell
    test_stripe_live_key_rejection_sk_live_reuses_canonical_text
    test_stripe_live_key_rejection_rk_live_reuses_canonical_text
    test_reject_known_bad_sha_accumulates_across_repeated_flags
    test_live_mode_reject_list_uses_exported_aws_credentials
    test_restricted_stripe_key_alias_is_exported_to_delegated_owners
    test_run_id_collision_fails_fast_with_exact_message
    test_live_mode_zero_warning_counts_do_not_abort
    test_live_mode_without_journalctl_still_runs_and_writes_zero_counts
    test_live_mode_failure_persists_fail_summary_json
    run_test_summary
}

run_all_tests
