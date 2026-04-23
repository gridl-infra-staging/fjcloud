#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/ses_deliverability_evidence.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SES_WRAPPER_SCRIPT="$REPO_ROOT/scripts/launch/ses_deliverability_evidence.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0
TEST_WORKSPACE=""
TEST_CALL_LOG=""
WRAPPER_PRESENT=0
CLEANUP_DIRS=()

cleanup_test_workspaces() {
    local dir
    for dir in "${CLEANUP_DIRS[@]:-}"; do
        [ -n "$dir" ] && rm -rf "$dir"
    done
}
trap cleanup_test_workspaces EXIT

read_file_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    else
        printf '\n'
    fi
}

json_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
path = sys.argv[2]
value = payload
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("")
        raise SystemExit(0)
if isinstance(value, bool):
    print("true" if value else "false")
elif value is None:
    print("")
else:
    print(str(value))
PY
}

json_has_field() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
path = sys.argv[2]
value = payload
for part in path.split("."):
    if isinstance(value, dict) and part in value:
        value = value[part]
    else:
        print("false")
        raise SystemExit(0)
print("true")
PY
}

assert_verdict_is_blocked_or_fail() {
    local verdict="$1"
    local msg="$2"
    if [ "$verdict" = "blocked" ] || [ "$verdict" = "fail" ]; then
        pass "$msg"
    else
        fail "$msg (expected blocked|fail actual='$verdict')"
    fi
}

assert_no_wrapper_sender_readiness_call() {
    local calls="$1" sender="$2" msg="$3"
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [[ "$line" == aws\|CALLER=wrapper\|*'|sesv2 get-email-identity '* ]] &&
            { [[ "$line" == *" --email-identity=$sender"* ]] ||
                [[ "$line" == *" --email-identity $sender"* ]]; }; then
            fail "$msg (unexpected wrapper-owned sender identity lookup: $line)"
            return
        fi
    done <<< "$calls"
    pass "$msg"
}

find_single_run_dir() {
    local artifact_root="$1"
    local dir selected="" count=0
    for dir in "$artifact_root"/*; do
        [ -d "$dir" ] || continue
        selected="$dir"
        count=$((count + 1))
    done
    if [ "$count" -eq 1 ]; then
        printf '%s\n' "$selected"
    else
        printf '\n'
    fi
}

find_readiness_artifact() {
    local run_dir="$1"
    local path
    while IFS= read -r path; do
        [ -f "$path" ] || continue
        if [[ "$path" == *readiness* ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done < <(rg --files "$run_dir" 2>/dev/null || true)
    printf '\n'
}

write_secret_fixture_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIATESTDELIVERABILITY
AWS_SECRET_ACCESS_KEY=fake-ses-secret-value
AWS_SESSION_TOKEN=fake-ses-session-token
SES_FROM_ADDRESS=noreply-contract@flapjack.foo
SES_REGION=us-east-1
SES_TEST_RECIPIENT=deliverability-recipient@flapjack.foo
ENVFILE
}

write_mock_aws() {
    cat > "$TEST_WORKSPACE/bin/aws" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

log_path="${SES_DELIV_CALL_LOG:?missing SES_DELIV_CALL_LOG}"
caller="${SES_DELIV_CALLER:-wrapper}"
pager="${AWS_PAGER-__unset__}"
if [ "$pager" = "" ]; then
    pager="<empty>"
elif [ "$pager" = "__unset__" ]; then
    pager="<unset>"
fi
echo "aws|CALLER=$caller|AWS_PAGER=$pager|$*" >> "$log_path"

if [ "${SES_DELIV_AWS_FORCE_CREDENTIAL_ERROR:-0}" = "1" ]; then
    echo "Unable to locate credentials" >&2
    exit 254
fi

if [ "${1:-}" != "sesv2" ]; then
    echo "unexpected aws service: $*" >&2
    exit 91
fi

command="${2:-}"
case "$command" in
    get-account)
        case "${SES_DELIV_AWS_ACCOUNT_MODE:-production}" in
            production)
                cat <<'JSON'
{"SendingEnabled":true,"ProductionAccessEnabled":true,"AccountId":"123456789012"}
JSON
                ;;
            sandbox)
                cat <<'JSON'
{"SendingEnabled":true,"ProductionAccessEnabled":false,"AccountId":"123456789012"}
JSON
                ;;
            sending_disabled)
                cat <<'JSON'
{"SendingEnabled":false,"ProductionAccessEnabled":true,"AccountId":"123456789012"}
JSON
                ;;
            error)
                echo "simulated get-account failure" >&2
                exit 1
                ;;
            *)
                echo "unknown SES_DELIV_AWS_ACCOUNT_MODE" >&2
                exit 92
                ;;
        esac
        ;;
    get-email-identity)
        identity=""
        previous=""
        for token in "$@"; do
            if [ "$previous" = "--email-identity" ]; then
                identity="$token"
                break
            fi
            case "$token" in
                --email-identity=*)
                    identity="${token#--email-identity=}"
                    break
                    ;;
                --email-identity)
                    previous="--email-identity"
                    ;;
                *)
                    previous=""
                    ;;
            esac
        done

        sender_identity="${SES_FROM_ADDRESS:-${SES_DELIV_SENDER_IDENTITY:-}}"
        mode="${SES_DELIV_AWS_RECIPIENT_MODE:-verified_email}"
        if [ -n "$sender_identity" ] && [ "$identity" = "$sender_identity" ]; then
            mode="${SES_DELIV_AWS_SENDER_MODE:-verified_domain}"
        fi

        case "$mode" in
            verified_domain)
                cat <<'JSON'
{"IdentityType":"DOMAIN","VerificationStatus":"SUCCESS","DkimAttributes":{"Status":"SUCCESS"}}
JSON
                ;;
            verified_email)
                cat <<'JSON'
{"IdentityType":"EMAIL_ADDRESS","VerificationStatus":"SUCCESS"}
JSON
                ;;
            unverified)
                cat <<'JSON'
{"IdentityType":"EMAIL_ADDRESS","VerificationStatus":"PENDING"}
JSON
                ;;
            missing)
                echo "NotFoundException: identity not found" >&2
                exit 254
                ;;
            error)
                echo "simulated get-email-identity failure" >&2
                exit 1
                ;;
            *)
                echo "unknown identity mode: $mode" >&2
                exit 93
                ;;
        esac
        ;;
    list-suppressed-destinations)
        case "${SES_DELIV_SUPPRESSION_MODE:-not_checked}" in
            clear)
                cat <<'JSON'
{"SuppressedDestinationSummaries":[]}
JSON
                ;;
            suppressed)
                cat <<'JSON'
{"SuppressedDestinationSummaries":[{"EmailAddress":"deliverability-recipient@flapjack.foo","Reason":"BOUNCE"}]}
JSON
                ;;
            error)
                echo "simulated suppression lookup failure" >&2
                exit 1
                ;;
            *)
                cat <<'JSON'
{"SuppressedDestinationSummaries":[]}
JSON
                ;;
        esac
        ;;
    *)
        echo "unexpected sesv2 command: $*" >&2
        exit 94
        ;;
esac
MOCK
    chmod +x "$TEST_WORKSPACE/bin/aws"
}

write_mock_cargo() {
    cat > "$TEST_WORKSPACE/bin/cargo" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

echo "cargo|SES_LIVE_TEST=${SES_LIVE_TEST:-}|SES_FROM_ADDRESS=${SES_FROM_ADDRESS:-}|SES_REGION=${SES_REGION:-}|SES_TEST_RECIPIENT=${SES_TEST_RECIPIENT:-}|$*" >> "${SES_DELIV_CALL_LOG:?missing SES_DELIV_CALL_LOG}"
if [ -n "${SES_DELIV_CARGO_STDOUT:-}" ]; then
    printf '%s\n' "$SES_DELIV_CARGO_STDOUT"
fi
if [ -n "${SES_DELIV_CARGO_STDERR:-}" ]; then
    printf '%s\n' "$SES_DELIV_CARGO_STDERR" >&2
fi
exit "${SES_DELIV_CARGO_EXIT_CODE:-0}"
MOCK
    chmod +x "$TEST_WORKSPACE/bin/cargo"
}

write_readiness_shim() {
    cat > "$TEST_WORKSPACE/scripts/validate_ses_readiness.sh" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "readiness|AWS_PAGER=${AWS_PAGER-<unset>}|$*" >> "${SES_DELIV_CALL_LOG:?missing SES_DELIV_CALL_LOG}"

if [ "${SES_DELIV_READINESS_FORCE_FAIL:-0}" = "1" ]; then
    cat <<'JSON'
{"passed":false,"steps":[{"name":"get_account","passed":false,"detail":"forced failure"}]}
JSON
    exit 1
fi

if [ -n "${SES_DELIV_READINESS_STDOUT:-}" ]; then
    printf '%s\n' "$SES_DELIV_READINESS_STDOUT"
    exit "${SES_DELIV_READINESS_EXIT_CODE:-0}"
fi

SES_DELIV_CALLER=readiness_owner \
    "$SCRIPT_DIR/validate_ses_readiness_owner.sh" "$@"
SHIM
    chmod +x "$TEST_WORKSPACE/scripts/validate_ses_readiness.sh"
}

copy_optional_support_trees() {
    mkdir -p "$TEST_WORKSPACE/scripts/lib"
    cp "$REPO_ROOT/scripts/lib"/*.sh "$TEST_WORKSPACE/scripts/lib/" 2>/dev/null || true
}

setup_workspace() {
    TEST_WORKSPACE="$(mktemp -d)"
    CLEANUP_DIRS+=("$TEST_WORKSPACE")
    TEST_CALL_LOG="$TEST_WORKSPACE/tmp/calls.log"

    mkdir -p "$TEST_WORKSPACE/scripts/launch" \
             "$TEST_WORKSPACE/scripts" \
             "$TEST_WORKSPACE/bin" \
             "$TEST_WORKSPACE/tmp" \
             "$TEST_WORKSPACE/artifacts" \
             "$TEST_WORKSPACE/fixtures" \
             "$TEST_WORKSPACE/infra/api/tests"
    : > "$TEST_CALL_LOG"

    copy_optional_support_trees
    cp "$REPO_ROOT/scripts/validate_ses_readiness.sh" "$TEST_WORKSPACE/scripts/validate_ses_readiness_owner.sh"
    chmod +x "$TEST_WORKSPACE/scripts/validate_ses_readiness_owner.sh"
    write_readiness_shim
    write_mock_aws
    write_mock_cargo
    write_secret_fixture_env_file "$TEST_WORKSPACE/fixtures/ses_contract.env"
    cp "$REPO_ROOT/infra/api/tests/email_test.rs" "$TEST_WORKSPACE/infra/api/tests/email_test.rs"

    if [ -f "$SES_WRAPPER_SCRIPT" ]; then
        cp "$SES_WRAPPER_SCRIPT" "$TEST_WORKSPACE/scripts/launch/ses_deliverability_evidence.sh"
        chmod +x "$TEST_WORKSPACE/scripts/launch/ses_deliverability_evidence.sh"
        WRAPPER_PRESENT=1
    else
        WRAPPER_PRESENT=0
    fi
}

require_wrapper_for_contract() {
    local reason="$1"
    if [ "$WRAPPER_PRESENT" -ne 1 ]; then
        pass "$reason skipped until scripts/launch/ses_deliverability_evidence.sh exists"
        return 1
    fi
    return 0
}

_run_ses_deliverability() {
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

    local wrapper_script="$TEST_WORKSPACE/scripts/launch/ses_deliverability_evidence.sh"
    local stdout_file="$TEST_WORKSPACE/tmp/ses_wrapper.stdout.txt"
    local stderr_file="$TEST_WORKSPACE/tmp/ses_wrapper.stderr.txt"

    RUN_EXIT_CODE=0
    local base_env=(
        "PATH=$TEST_WORKSPACE/bin:/usr/bin:/bin:/usr/local/bin"
        "HOME=$TEST_WORKSPACE"
        "TMPDIR=$TEST_WORKSPACE/tmp"
        "SES_DELIV_CALL_LOG=$TEST_CALL_LOG"
    )

    if [ -n "$cli_args" ]; then
        # shellcheck disable=SC2086
        (cd "$TEST_WORKSPACE" && env -i "${base_env[@]}" "${env_args[@]}" /bin/bash "$wrapper_script" $cli_args >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    else
        (cd "$TEST_WORKSPACE" && env -i "${base_env[@]}" "${env_args[@]}" /bin/bash "$wrapper_script" >"$stdout_file" 2>"$stderr_file") || RUN_EXIT_CODE=$?
    fi

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_contract_suite_requires_wrapper_script() {
    setup_workspace
    if [ "$WRAPPER_PRESENT" -eq 1 ]; then
        pass "contract suite found scripts/launch/ses_deliverability_evidence.sh"
    else
        fail "contract suite requires scripts/launch/ses_deliverability_evidence.sh (expected Stage 1 red while wrapper is unimplemented)"
    fi
}

test_readiness_delegation_runs_before_live_send_and_preserves_artifact() {
    setup_workspace
    require_wrapper_for_contract "readiness delegation contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_domain" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"

    local calls readiness_line cargo_line run_dir readiness_artifact
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    readiness_line="$(grep -n '^readiness|' "$TEST_CALL_LOG" | head -1 | cut -d: -f1 || true)"
    cargo_line="$(grep -n '^cargo|' "$TEST_CALL_LOG" | head -1 | cut -d: -f1 || true)"

    assert_contains "$calls" "readiness|" "wrapper should delegate readiness to scripts/validate_ses_readiness.sh"
    assert_contains "$calls" "--identity noreply-contract@flapjack.foo" "readiness delegate should use SES_FROM_ADDRESS identity"
    assert_contains "$calls" "--region us-east-1" "readiness delegate should use SES_REGION"
    if [ -n "$readiness_line" ] && [ -n "$cargo_line" ] && [ "$readiness_line" -lt "$cargo_line" ]; then
        pass "wrapper should invoke readiness before cargo live-send seam"
    else
        fail "wrapper should invoke readiness before cargo live-send seam"
    fi
    assert_not_contains "$calls" "aws|CALLER=wrapper|AWS_PAGER=<empty>|sesv2 get-account" "wrapper must not duplicate account readiness outside readiness owner"
    assert_no_wrapper_sender_readiness_call "$calls" "noreply-contract@flapjack.foo" "wrapper must not duplicate sender readiness outside readiness owner"

    run_dir="$(find_single_run_dir "$TEST_WORKSPACE/artifacts")"
    readiness_artifact="$(find_readiness_artifact "$run_dir")"
    if [ -n "$readiness_artifact" ]; then
        pass "wrapper should persist readiness owner stdout as an artifact under run dir"
    else
        fail "wrapper should persist readiness owner stdout as an artifact under run dir"
    fi
}

test_recipient_preflight_contract_states() {
    setup_workspace
    require_wrapper_for_contract "recipient preflight contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_RECIPIENT_MODE=missing"
    assert_valid_json "$RUN_STDOUT" "missing recipient source should still emit JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "missing recipient source should be blocked"
    assert_not_contains "$(read_file_or_empty "$TEST_CALL_LOG")" "cargo|" "missing recipient source should not run cargo send seam"

    setup_workspace
    require_wrapper_for_contract "recipient preflight self-discovery" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"
    assert_contains "$(read_file_or_empty "$TEST_CALL_LOG")" "cargo|" "verified self-recipient discovery should allow send attempt"

    setup_workspace
    require_wrapper_for_contract "recipient preflight simulator allowance" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=success@simulator.amazonses.com" \
        "SES_DELIV_AWS_ACCOUNT_MODE=sandbox" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"
    assert_valid_json "$RUN_STDOUT" "simulator recipient case should emit valid JSON"
    assert_not_contains "$RUN_STDOUT" "inbox receipt proof" "simulator traffic must never be labeled inbox receipt proof"
}

test_sandbox_readiness_reports_blocked_without_live_send() {
    setup_workspace
    require_wrapper_for_contract "sandbox readiness blocked contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=" \
        "SES_DELIV_AWS_ACCOUNT_MODE=sandbox"

    local run_dir summary_payload calls
    run_dir="$(find_single_run_dir "$TEST_WORKSPACE/artifacts")"
    summary_payload="$(read_file_or_empty "$run_dir/summary.json")"
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"

    assert_eq "$RUN_EXIT_CODE" "0" "sandbox readiness should exit 0 with blocked verdict"
    assert_valid_json "$RUN_STDOUT" "sandbox readiness stdout should be valid JSON"
    assert_valid_json "$summary_payload" "sandbox readiness summary.json should be valid JSON"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "sandbox readiness should set run verdict blocked"
    assert_contains "$RUN_STDOUT" "sandbox" "sandbox readiness output should include stable sandbox blocker detail"
    assert_contains "$RUN_STDOUT" "ProductionAccessEnabled=false" "sandbox readiness should include remediation detail"
    assert_not_contains "$calls" "cargo|" "sandbox without recipient preflight should not run cargo live-send seam"
}

test_blocked_input_states_contract() {
    setup_workspace
    require_wrapper_for_contract "blocked input states contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_FORCE_CREDENTIAL_ERROR=1"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "missing AWS credentials should report blocked verdict"

    setup_workspace
    require_wrapper_for_contract "blocked sender identity contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_FROM_ADDRESS="
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "missing sender identity should report blocked verdict"

    setup_workspace
    require_wrapper_for_contract "blocked unverified recipient contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_RECIPIENT_MODE=unverified"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "unverified recipient should report blocked verdict"

    setup_workspace
    require_wrapper_for_contract "blocked sandbox recipient-limit contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=sandbox" \
        "SES_DELIV_AWS_RECIPIENT_MODE=unverified"
    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" "sandbox recipient limits should report blocked verdict"
    assert_not_contains "$RUN_STDOUT" "live send failed" "blocked input states should not be labeled as failed live sends"
}

test_live_send_delegation_to_canonical_ignored_test() {
    setup_workspace
    require_wrapper_for_contract "live-send delegation contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_domain" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"

    local cargo_line
    cargo_line="$(grep '^cargo|' "$TEST_CALL_LOG" | head -1 || true)"
    if [ -n "$cargo_line" ]; then
        pass "wrapper should invoke cargo for live-send seam when readiness and recipient preflight pass"
    else
        fail "wrapper should invoke cargo for live-send seam when readiness and recipient preflight pass"
    fi
    assert_contains "$cargo_line" "SES_LIVE_TEST=1" "wrapper must set SES_LIVE_TEST=1 for delegated cargo run"
    assert_contains "$cargo_line" "SES_FROM_ADDRESS=noreply-contract@flapjack.foo" "wrapper must pass SES_FROM_ADDRESS to cargo"
    assert_contains "$cargo_line" "SES_REGION=us-east-1" "wrapper must pass SES_REGION to cargo"
    assert_contains "$cargo_line" "SES_TEST_RECIPIENT=deliverability-recipient@flapjack.foo" "wrapper must pass SES_TEST_RECIPIENT to cargo"
    assert_contains "$cargo_line" "test -p api --test email_test ses_live_smoke_sends_verification_email -- --ignored" "wrapper must target canonical ignored live smoke seam"
    assert_not_contains "$RUN_STDOUT" "MessageId" "wrapper contract must not require MessageId proof"
}

test_live_send_false_positive_contract() {
    setup_workspace
    require_wrapper_for_contract "live-send false-positive contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=SES_LIVE_TEST not set — skipping live SES smoke test"
    assert_verdict_is_blocked_or_fail "$(json_field "$RUN_STDOUT" "overall_verdict")" "skip marker must produce blocked or fail verdict"

    setup_workspace
    require_wrapper_for_contract "live-send running-zero false-positive contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=running 0 tests"
    assert_verdict_is_blocked_or_fail "$(json_field "$RUN_STDOUT" "overall_verdict")" "running 0 tests must produce blocked or fail verdict"

    setup_workspace
    require_wrapper_for_contract "live-send missing named-test false-positive contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=test another_ignored_case ... ok"
    assert_verdict_is_blocked_or_fail "$(json_field "$RUN_STDOUT" "overall_verdict")" "missing named ignored test must produce blocked or fail verdict"

    setup_workspace
    require_wrapper_for_contract "live-send zero-exit marker false-positive contract" || return 0
    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=cargo exited 0 without send marker"
    assert_verdict_is_blocked_or_fail "$(json_field "$RUN_STDOUT" "overall_verdict")" "zero-exit cargo without positive marker must produce blocked or fail verdict"
}

test_missing_explicit_ses_region_blocks_before_cargo() {
    setup_workspace
    require_wrapper_for_contract "missing explicit ses region contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_REGION=" \
        "AWS_REGION=us-east-1" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_domain" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email"

    local calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"

    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "blocked" \
        "missing explicit SES_REGION should report blocked verdict before live-send seam"
    assert_eq "$(json_field "$RUN_STDOUT" "account_status.status")" "blocked" \
        "missing explicit SES_REGION should block readiness delegation instead of relying on defaults"
    assert_eq "$(json_field "$RUN_STDOUT" "recipient_preflight.status")" "blocked" \
        "missing explicit SES_REGION should block recipient preflight before wrapper-owned AWS identity lookups"
    assert_eq "$(json_field "$RUN_STDOUT" "send_attempt.status")" "blocked" \
        "missing explicit SES_REGION should block the live-send seam"
    assert_contains "$(json_field "$RUN_STDOUT" "account_status.detail")" "SES_REGION is missing" \
        "missing explicit SES_REGION should surface explicit readiness blocker detail"
    assert_contains "$(json_field "$RUN_STDOUT" "recipient_preflight.detail")" "SES_REGION is missing" \
        "missing explicit SES_REGION should surface explicit recipient preflight blocker detail"
    assert_contains "$(json_field "$RUN_STDOUT" "send_attempt.detail")" "SES_REGION is missing" \
        "missing explicit SES_REGION should surface explicit blocker detail"
    assert_not_contains "$calls" "readiness|" \
        "missing explicit SES_REGION must not delegate readiness without canonical region input"
    assert_not_contains "$calls" "aws|CALLER=wrapper|AWS_PAGER=<empty>|sesv2 get-email-identity" \
        "missing explicit SES_REGION must not perform wrapper-owned recipient identity AWS lookups"
    assert_not_contains "$calls" "cargo|" \
        "missing explicit SES_REGION must not invoke cargo with an empty SES region"
    assert_not_contains "$calls" "readiness|AWS_PAGER=<empty>|--identity noreply-contract@flapjack.foo --region " \
        "readiness owner should not receive an explicit empty region argument"
}

test_ambient_env_overrides_env_file_for_canonical_inputs() {
    setup_workspace
    require_wrapper_for_contract "ambient canonical input precedence contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_FROM_ADDRESS=ambient-sender@flapjack.foo" \
        "SES_REGION=us-west-2" \
        "SES_TEST_RECIPIENT=ambient-recipient@flapjack.foo" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_email" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"

    local calls readiness_line cargo_line
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"
    readiness_line="$(grep '^readiness|' "$TEST_CALL_LOG" | head -1 || true)"
    cargo_line="$(grep '^cargo|' "$TEST_CALL_LOG" | head -1 || true)"

    assert_eq "$(json_field "$RUN_STDOUT" "overall_verdict")" "pass" \
        "ambient canonical SES inputs should keep wrapper verdict passing"
    assert_contains "$readiness_line" "--identity ambient-sender@flapjack.foo" \
        "readiness delegation should prefer ambient SES_FROM_ADDRESS over env-file value"
    assert_contains "$readiness_line" "--region us-west-2" \
        "readiness delegation should prefer ambient SES_REGION over env-file value"
    assert_not_contains "$readiness_line" "--identity noreply-contract@flapjack.foo" \
        "readiness delegation should not fall back to env-file SES_FROM_ADDRESS when ambient value is exported"
    assert_not_contains "$readiness_line" "--region us-east-1" \
        "readiness delegation should not fall back to env-file SES_REGION when ambient value is exported"
    assert_contains "$cargo_line" "SES_FROM_ADDRESS=ambient-sender@flapjack.foo" \
        "live-send delegation should use ambient SES_FROM_ADDRESS"
    assert_contains "$cargo_line" "SES_REGION=us-west-2" \
        "live-send delegation should use ambient SES_REGION"
    assert_contains "$cargo_line" "SES_TEST_RECIPIENT=ambient-recipient@flapjack.foo" \
        "live-send delegation should use ambient SES_TEST_RECIPIENT"
    assert_not_contains "$cargo_line" "SES_TEST_RECIPIENT=deliverability-recipient@flapjack.foo" \
        "live-send delegation should not use env-file SES_TEST_RECIPIENT when ambient value is exported"
    assert_eq "$(json_field "$RUN_STDOUT" "recipient_preflight.source")" "explicit" \
        "ambient SES_TEST_RECIPIENT should remain explicit recipient source"
    assert_eq "$(json_field "$RUN_STDOUT" "recipient_preflight.recipient")" "REDACTED" \
        "summary recipient field should remain redacted in stdout"
    assert_contains "$calls" "readiness|" \
        "ambient canonical input precedence should still delegate to readiness owner"
}

test_summary_schema_and_proof_boundaries_contract() {
    setup_workspace
    require_wrapper_for_contract "summary schema boundaries contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=running 0 tests"

    assert_eq "$(json_has_field "$RUN_STDOUT" "account_status")" "true" "summary must include account_status"
    assert_eq "$(json_has_field "$RUN_STDOUT" "identity_status")" "true" "summary must include identity_status"
    assert_eq "$(json_has_field "$RUN_STDOUT" "recipient_preflight")" "true" "summary must include recipient_preflight"
    assert_eq "$(json_has_field "$RUN_STDOUT" "send_attempt")" "true" "summary must include send_attempt"
    assert_eq "$(json_has_field "$RUN_STDOUT" "suppression_check")" "true" "summary must include suppression_check"
    assert_eq "$(json_has_field "$RUN_STDOUT" "deliverability_boundaries")" "true" "summary must include deliverability_boundaries"
    assert_contains "$RUN_STDOUT" "SPF" "summary boundaries must keep SPF unproven"
    assert_contains "$RUN_STDOUT" "MAIL FROM" "summary boundaries must keep MAIL FROM unproven"
    assert_contains "$RUN_STDOUT" "bounce/complaint" "summary boundaries must keep bounce/complaint handling unproven"
    assert_contains "$RUN_STDOUT" "first-send" "summary boundaries must keep first-send evidence unproven"
    assert_contains "$RUN_STDOUT" "inbox-receipt" "summary boundaries must keep inbox-receipt evidence unproven"
    assert_contains "$RUN_STDOUT" "not_checked" "suppression should remain not_checked unless explicit suppression check runs"
}

test_noninteractive_aws_contract_for_wrapper_and_readiness_calls() {
    setup_workspace
    require_wrapper_for_contract "noninteractive aws contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_domain" \
        "SES_DELIV_AWS_RECIPIENT_MODE=verified_email"

    local aws_lines readiness_lines wrapper_lines line
    aws_lines="$(grep '^aws|' "$TEST_CALL_LOG" || true)"
    if [ -n "$aws_lines" ]; then
        pass "wrapper and readiness paths should execute AWS CLI calls in this contract test"
    else
        fail "wrapper and readiness paths should execute AWS CLI calls in this contract test"
    fi
    readiness_lines="$(printf '%s\n' "$aws_lines" | grep 'CALLER=readiness_owner' || true)"
    if [ -n "$readiness_lines" ]; then
        pass "noninteractive contract should include delegated readiness-owner AWS calls"
    else
        fail "noninteractive contract should include delegated readiness-owner AWS calls"
    fi
    wrapper_lines="$(printf '%s\n' "$aws_lines" | grep 'CALLER=wrapper' || true)"
    if [ -n "$wrapper_lines" ]; then
        pass "noninteractive contract should include wrapper-owned AWS calls"
    else
        fail "noninteractive contract should include wrapper-owned AWS calls"
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        assert_contains "$line" "AWS_PAGER=<empty>" "aws calls should run with AWS_PAGER empty"
        assert_contains "$line" "--no-cli-pager" "aws calls should include --no-cli-pager"
    done <<< "$readiness_lines"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        assert_contains "$line" "AWS_PAGER=<empty>" "wrapper aws calls should run with AWS_PAGER empty"
        assert_contains "$line" "--no-cli-pager" "wrapper aws calls should include --no-cli-pager"
    done <<< "$wrapper_lines"
}

test_redaction_contract_for_stdout_summary_and_logs() {
    setup_workspace
    require_wrapper_for_contract "redaction contract" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok\nraw-body=This is the full email body payload\nfake-ses-secret-value"

    local run_dir summary_payload logs_payload
    run_dir="$(find_single_run_dir "$TEST_WORKSPACE/artifacts")"
    summary_payload="$(read_file_or_empty "$run_dir/summary.json")"
    logs_payload="$(cat "$run_dir"/logs/* 2>/dev/null || true)"

    assert_valid_json "$RUN_STDOUT" "redaction contract should emit valid stdout JSON"
    assert_valid_json "$summary_payload" "redaction contract should emit valid summary.json"
    assert_not_contains "$RUN_STDOUT" "fake-ses-secret-value" "stdout JSON should redact AWS secret value"
    assert_not_contains "$RUN_STDOUT" "fake-ses-session-token" "stdout JSON should redact AWS session token"
    assert_not_contains "$summary_payload" "fake-ses-secret-value" "summary.json should redact AWS secret value"
    assert_not_contains "$summary_payload" "fake-ses-session-token" "summary.json should redact AWS session token"
    assert_not_contains "$logs_payload" "fake-ses-secret-value" "delegated logs should redact AWS secret value"
    assert_not_contains "$logs_payload" "This is the full email body payload" "delegated logs should not include full email bodies"
    assert_contains "$RUN_STDOUT" "REDACTED" "stdout JSON should use stable redaction marker"
    assert_contains "$summary_payload" "REDACTED" "summary.json should use stable redaction marker"
}

test_explicit_self_recipient_does_not_duplicate_sender_readiness() {
    setup_workspace
    require_wrapper_for_contract "self-recipient no sender duplication" || return 0

    _run_ses_deliverability \
        --args "--artifact-dir $TEST_WORKSPACE/artifacts --env-file $TEST_WORKSPACE/fixtures/ses_contract.env" \
        "SES_TEST_RECIPIENT=noreply-contract@flapjack.foo" \
        "SES_FROM_ADDRESS=noreply-contract@flapjack.foo" \
        "SES_DELIV_AWS_ACCOUNT_MODE=production" \
        "SES_DELIV_AWS_SENDER_MODE=verified_domain" \
        "SES_DELIV_CARGO_STDOUT=test ses_live_smoke_sends_verification_email ... ok"

    local calls
    calls="$(read_file_or_empty "$TEST_CALL_LOG")"

    assert_no_wrapper_sender_readiness_call "$calls" "noreply-contract@flapjack.foo" \
        "explicit self-recipient must not trigger wrapper-owned sender identity lookup"
    assert_eq "$(json_field "$RUN_STDOUT" "recipient_preflight.status")" "pass" \
        "self-recipient should pass preflight via readiness-owner delegation"
    assert_contains "$calls" "cargo|" \
        "self-recipient with passing readiness should allow live-send seam"
}

echo "=== ses_deliverability_evidence contract tests ==="
test_contract_suite_requires_wrapper_script
test_readiness_delegation_runs_before_live_send_and_preserves_artifact
test_explicit_self_recipient_does_not_duplicate_sender_readiness
test_recipient_preflight_contract_states
test_sandbox_readiness_reports_blocked_without_live_send
test_blocked_input_states_contract
test_live_send_delegation_to_canonical_ignored_test
test_live_send_false_positive_contract
test_missing_explicit_ses_region_blocks_before_cargo
test_ambient_env_overrides_env_file_for_canonical_inputs
test_summary_schema_and_proof_boundaries_contract
test_noninteractive_aws_contract_for_wrapper_and_readiness_calls
test_redaction_contract_for_stdout_summary_and_logs
run_test_summary
