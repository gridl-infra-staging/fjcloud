#!/usr/bin/env bash
# Hermetic stub writers for run_ses_coverage_a1_in_vpc_test.sh.
#
# These functions emit throwaway executables (aws, git, python3,
# ssm_exec_staging.sh) and a credential env file so the runner contract tests
# exercise the real script with zero external calls. Extracted from the test
# body to keep that file under the source-size limit; sourced by the test.

# TODO: Document write_ssm_exec_stub.
# TODO: Document write_ssm_exec_stub.
# TODO: Document write_ssm_exec_stub.
# TODO: Document write_ssm_exec_stub.
# TODO: Document write_ssm_exec_stub.
# Write a hermetic SSM executor that records commands and emits scenario-specific probe receipts.
# The optional scenario selects structural, semantic, or successful runner behavior.
# TODO: Document write_ssm_exec_stub.
# TODO: Document write_ssm_exec_stub.
write_ssm_exec_stub() {
    local stub_path="$1" scenario="${2:-green}"
    cat > "$stub_path" <<'STUB_HEAD'
#!/usr/bin/env bash
set -euo pipefail
COMMAND="$1"
mkdir -p "${HOME:-/tmp}/tmp"
printf '%s\n' "$COMMAND" >> "${HOME:-/tmp}/tmp/ssm_commands.log"
STUB_HEAD

    cat >> "$stub_path" <<STUB_BODY
SCENARIO="$scenario"
STUB_BODY

    cat >> "$stub_path" <<'STUB_TAIL'
if [[ "$SCENARIO" == "structural_failed" ]]; then
    echo "ERROR: SSM target offline" >&2
    exit 1
fi
if [[ "$SCENARIO" == "remote_verdict_download_fail" && "$COMMAND" == *"deployable_currency.json"* ]]; then
    echo "ERROR: verdict materialization failed" >&2
    exit 1
fi
if [[ "$SCENARIO" == "remote_verdict_tamper" && "$COMMAND" == *"deployable_currency.json"* && "$COMMAND" == *"sha256"* ]]; then
    echo "ERROR: verdict digest mismatch" >&2
    exit 1
fi

probe_id=""
if [[ "$COMMAND" == *"probe_ses_bounce_complaint"*" bounce"* ]]; then probe_id="ses_bounce"
elif [[ "$COMMAND" == *"probe_ses_bounce_complaint"*" complaint"* ]]; then probe_id="ses_complaint"
elif [[ "$COMMAND" == *"probe_verify_email_clickthrough"* ]]; then probe_id="verify_email_clickthrough"
elif [[ "$COMMAND" == *"probe_password_reset_clickthrough"* ]]; then probe_id="password_reset_clickthrough"
elif [[ "$COMMAND" == *"probe_dunning_email_inbox"* ]]; then probe_id="dunning_email_inbox"
elif [[ "$COMMAND" == *"validate_staging_dunning_delivery"* ]]; then probe_id="staging_dunning_delivery"
fi

if [ -z "$probe_id" ]; then
    exit 0
fi

case "$SCENARIO" in
    green)
        case "$probe_id" in
            verify_email_clickthrough)
                printf 'Step 1: sending verification email\nTERMINUS: email_verified=true\n'; exit 0 ;;
            password_reset_clickthrough)
                printf 'Step 1: sending password reset\nTERMINUS: login succeeded with new password\n'; exit 0 ;;
            dunning_email_inbox)
                printf 'Step 1: checking inbox\nTERMINUS: body contains hosted invoice url\n{"result":"passed","detail":"dunning email found"}\n'; exit 0 ;;
            ses_bounce)
                printf '{"passed":true,"detail":"bounce suppression verified"}\n'; exit 0 ;;
            ses_complaint)
                printf '{"passed":true,"detail":"complaint suppression verified"}\n'; exit 0 ;;
            staging_dunning_delivery)
                printf '{"result":"passed","detail":"dunning delivery verified"}\n'; exit 0 ;;
        esac ;;
    complete_red)
        case "$probe_id" in
            staging_dunning_delivery)
                printf '{"result":"failed","classification":"invoice_email_ses_query_failed","detail":"SES query failed"}\n'; exit 1 ;;
            dunning_email_inbox)
                printf 'Step 1: checking inbox\n{"result":"failed","classification":"rehearsal_failed","detail":"Rehearsal owner failed."}\n'; exit 1 ;;
            verify_email_clickthrough)
                printf 'Step 1: sending verification email\nTERMINUS: email_verified=true\n'; exit 0 ;;
            password_reset_clickthrough)
                printf 'Step 1: sending password reset\nTERMINUS: login succeeded with new password\n'; exit 0 ;;
            ses_bounce)
                printf '{"passed":true,"detail":"bounce suppression verified"}\n'; exit 0 ;;
            ses_complaint)
                printf '{"passed":true,"detail":"complaint suppression verified"}\n'; exit 0 ;;
        esac ;;
esac
STUB_TAIL
    chmod +x "$stub_path"
}

write_git_stub() {
    local stub_path="$1" repo_root="$2" mode="${3:-success}"
    cat > "$stub_path" <<GITSTUB
#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT_MOCK="$repo_root"
MODE="$mode"
GITSTUB
    cat >> "$stub_path" <<'GITSTUB_TAIL'
mkdir -p "${HOME:-/tmp}/tmp"
printf '%s\n' "$*" >> "${HOME:-/tmp}/tmp/git_commands.log"
if [[ "${1:-}" == "-C" ]]; then
    shift 2
fi
SOURCE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DEV_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
AMBIENT_SHA="cccccccccccccccccccccccccccccccccccccccc"

case "$1" in
    rev-parse)
        if [[ "${2:-}" == "--show-toplevel" ]]; then
            echo "$REPO_ROOT_MOCK"
            exit 0
        fi
        if [[ "${2:-}" == "--verify" ]]; then
            echo "${3:-}"
            exit 0
        fi
        echo "unknown rev-parse" >&2; exit 1 ;;
    cat-file)
        exit 0 ;;
    rev-list)
        if [[ "$MODE" == "currency_unclassifiable" ]]; then
            echo "fatal: bad revision" >&2
            exit 128
        fi
        case "${3:-}" in
            "$DEV_SHA..$SOURCE_SHA"|"$AMBIENT_SHA..$SOURCE_SHA") echo "1"; exit 0 ;;
            *) echo "0"; exit 0 ;;
        esac ;;
    diff)
        case "${3:-}" in
            "$DEV_SHA..$SOURCE_SHA") printf 'infra/api/src/main.rs\n'; exit 0 ;;
            "$AMBIENT_SHA..$SOURCE_SHA") printf 'docs/runbooks/staging.md\n'; exit 0 ;;
            *) exit 0 ;;
        esac ;;
    archive)
        if [[ "$MODE" == "archive_fail" ]]; then
            echo "fatal: not a valid object name" >&2
            exit 128
        fi
        shift
        output_file=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --output=*) output_file="${1#--output=}"; shift ;;
                -o) output_file="$2"; shift 2 ;;
                --prefix=*) shift ;;
                *) shift ;;
            esac
        done
        if [ -n "$output_file" ]; then
            tar cf "$output_file" --files-from=/dev/null 2>/dev/null || true
        fi
        exit 0 ;;
    *)
        echo "git stub: unhandled $*" >&2; exit 1 ;;
esac
GITSTUB_TAIL
    chmod +x "$stub_path"
}

write_aws_stub() {
    local stub_path="$1" mode="${2:-success}"
    cat > "$stub_path" <<AWSSTUB
#!/usr/bin/env bash
MODE="$mode"
AWSSTUB
    cat >> "$stub_path" <<'AWSSTUB_TAIL'
mkdir -p "${HOME:-/tmp}/tmp"
printf '%s\n' "$*" >> "${HOME:-/tmp}/tmp/aws_commands.log"
case "$1" in
    ec2)
        if [[ "${2:-}" == "describe-instances" ]]; then
            echo "i-0abc123def456"
            exit 0
        fi ;;
    s3)
        if [[ "$MODE" == "verdict_upload_fail" && "${2:-}" == "cp" && "${4:-}" == *"deployable_currency.json" ]]; then
            echo "ERROR: failed to upload verdict" >&2
            exit 1
        fi
        if [[ "${2:-}" == "cp" && "${4:-}" == *"deployable_currency.json" && -f "${3:-}" ]]; then
            cp "$3" "${HOME:-/tmp}/tmp/uploaded_deployable_currency.json"
        fi
        if [[ "$MODE" == "cleanup_fail" && "${2:-}" == "rm" ]]; then
            echo "ERROR: failed to delete" >&2
            exit 1
        fi
        exit 0 ;;
    sts)
        echo '{"Account":"123456789012","Arn":"arn:aws:iam::123456789012:user/test","UserId":"u"}'
        exit 0 ;;
esac
exit 0
AWSSTUB_TAIL
    chmod +x "$stub_path"
}

write_python3_stub() {
    local stub_path="$1" real_python3="$2"
    cat > "$stub_path" <<PYSTUB
#!/usr/bin/env bash
exec "$real_python3" "\$@"
PYSTUB
    chmod +x "$stub_path"
}

write_credential_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
AWS_ACCESS_KEY_ID=AKIATESTRUNNERCONTRACT
AWS_SECRET_ACCESS_KEY=fixture-secret-key
AWS_DEFAULT_REGION=us-east-1
ENVFILE
}

write_deploy_status_fixture() {
    local stub_path="$1" mode="${2:-green}"
    cat > "$stub_path" <<STATUSSTUB
#!/usr/bin/env bash
set -euo pipefail
MODE="$mode"
STATUSSTUB
    cat >> "$stub_path" <<'STATUSSTUB_TAIL'
mkdir -p "${HOME:-/tmp}/tmp"
printf '%s\n' "$*" >> "${HOME:-/tmp}/tmp/deploy_status_commands.log"
case "$MODE" in
    status_nonzero)
        echo "deploy status unavailable" >&2
        exit 17 ;;
    status_malformed)
        printf '{not json}\n'
        exit 0 ;;
    status_missing_dev_sha)
        printf '{"envs":{"staging":{"deployable_drift":false,"doc_only_ahead":true}}}\n'
        exit 0 ;;
    status_uppercase_dev_sha)
        printf '{"envs":{"staging":{"dev_sha":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","dev_main_sha":"cccccccccccccccccccccccccccccccccccccccc","deployable_drift":false,"doc_only_ahead":true}}}\n'
        exit 0 ;;
    status_delimiter_dev_sha)
        printf '{"envs":{"staging":{"dev_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb|forged","dev_main_sha":"cccccccccccccccccccccccccccccccccccccccc","deployable_drift":false,"doc_only_ahead":true}}}\n'
        exit 0 ;;
    status_ref_dev_sha)
        printf '{"envs":{"staging":{"dev_sha":"HEAD","dev_main_sha":"cccccccccccccccccccccccccccccccccccccccc","deployable_drift":false,"doc_only_ahead":true}}}\n'
        exit 0 ;;
    *)
        printf '{"envs":{"staging":{"dev_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","dev_main_sha":"cccccccccccccccccccccccccccccccccccccccc","deployable_drift":false,"doc_only_ahead":true}}}\n'
        exit 0 ;;
esac
STATUSSTUB_TAIL
    chmod +x "$stub_path"
}
