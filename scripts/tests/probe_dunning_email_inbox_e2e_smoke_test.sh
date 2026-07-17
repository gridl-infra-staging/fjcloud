#!/usr/bin/env bash
# Smoke regression for scripts/probe_dunning_email_inbox_e2e.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_dunning_email_inbox_e2e.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"
# shellcheck source=../../scripts/lib/validation_json.sh
source "$REPO_ROOT/scripts/lib/validation_json.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

write_fixture_env_file() {
    local path="$1"
    cat > "$path" <<'ENVFILE'
STAGING_API_URL=https://api.flapjack.foo
INBOUND_ROUNDTRIP_S3_URI=s3://flapjack-cloud-releases/e2e-emails/run-001/
SES_REGION=us-east-1
ENVFILE
}

write_empty_log_shape_validator() {
    local path="$1"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
artifact_dir="${TMPDIR:-/tmp}/probe_dunning_empty_log_${RANDOM}"
mkdir -p "$artifact_dir"
cat <<JSON
{"result":"passed","classification":"dunning_delivery_verified","artifact_dir":"$artifact_dir","transitions":[]}
JSON
MOCK
    chmod +x "$path"
}

run_empty_log_shape_probe() {
    local tmp_dir="$1"
    local env_file="$tmp_dir/staging.env"
    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    mkdir -p "$tmp_dir/bin"
    write_fixture_env_file "$env_file"
    write_empty_log_shape_validator "$tmp_dir/mock_validator.sh"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        STAGING_DUNNING_VALIDATOR_SCRIPT="$tmp_dir/mock_validator.sh" \
        bash "$PROBE_SCRIPT" "$env_file" --month 2026-05 >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

json_field() {
    local payload="$1"
    local field="$2"
    validation_json_get_field "$payload" "$field"
}

test_empty_log_shape_emits_structured_probe_result() {
    local tmp_dir final_line result classification
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    run_empty_log_shape_probe "$tmp_dir"
    final_line="$(final_stdout_json_line "$RUN_STDOUT" 2>/dev/null || true)"
    result="$(json_field "$final_line" "result" 2>/dev/null || true)"
    classification="$(json_field "$final_line" "classification" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_ne "$RUN_EXIT_CODE" "0" "empty-log fixture should stay a failing probe path"
    assert_ne "$RUN_STDOUT" "" "failing probe path should not leave stdout empty"
    assert_valid_json "$final_line" "failing probe path should emit exactly one parseable final JSON line"
    assert_eq "$result" "failed" "empty-log fixture should map to the failed result bucket"
    assert_eq "$classification" "inbound_scope_artifact_missing" "empty-log fixture should emit a stable wrapper classification"
}

test_final_json_line_rejects_trailing_stdout() {
    local final_line
    final_line="$(
        final_stdout_json_line $'{"result":"failed","classification":"fixture"}\ntrailing text' 2>/dev/null || true
    )"

    assert_eq "$final_line" "" "final JSON helper should reject trailing non-JSON stdout"
}

main() {
    echo "=== probe_dunning_email_inbox_e2e smoke tests ==="

    test_final_json_line_rejects_trailing_stdout
    test_empty_log_shape_emits_structured_probe_result

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
