#!/usr/bin/env bash
# Hermetic classifier and live-state integration contract for mirror CI currency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE="$REPO_ROOT/scripts/probe_mirror_ci_currency.sh"
LIVE_STATE_PROBE="$REPO_ROOT/scripts/probe_live_state.sh"
MIRROR_HEAD="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
OTHER_HEAD="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
PASS_COUNT=0
FAIL_COUNT=0
TMP_PATHS=()
OUTPUT=""
RC=0

cleanup() {
    if [ "${#TMP_PATHS[@]}" -gt 0 ]; then
        rm -rf "${TMP_PATHS[@]}"
    fi
}
trap cleanup EXIT

new_temp_dir() {
    local result_var="$1" path
    path="$(mktemp -d)"
    TMP_PATHS+=("$path")
    printf -v "$result_var" '%s' "$path"
}

pass() {
    printf 'PASS: %s\n' "$1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
    local actual="$1" expected="$2" message="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$message"
    else
        fail "$message (expected '$expected', got '$actual')"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        pass "$message"
    else
        fail "$message (missing '$needle' in '$haystack')"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" message="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        fail "$message (unexpected '$needle' in '$haystack')"
    else
        pass "$message"
    fi
}

assert_matches() {
    local actual="$1" pattern="$2" message="$3"
    if [[ "$actual" =~ $pattern ]]; then
        pass "$message"
    else
        fail "$message ('$actual' does not match '$pattern')"
    fi
}

run_command() {
    set +e
    OUTPUT="$("$@" 2>&1)"
    RC=$?
    set -e
}

write_fixture() {
    local path="$1" scenario="$2"
    case "$scenario" in
        green)
            printf '%s\n' '[{"name":"CI","event":"push","conclusion":"failure","createdAt":"2026-08-01T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":100,"status":"completed"},{"name":"Other","event":"push","conclusion":"success","createdAt":"2026-08-03T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":999,"status":"completed"},{"name":"CI","event":"push","conclusion":"success","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":101,"status":"completed"}]' > "$path"
            ;;
        failure)
            printf '%s\n' '[{"name":"CI","event":"push","conclusion":"failure","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":102,"status":"completed"}]' > "$path"
            ;;
        cancelled)
            printf '%s\n' '[{"name":"CI","event":"push","conclusion":"cancelled","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":103,"status":"completed"}]' > "$path"
            ;;
        queued)
            printf '%s\n' '[{"name":"CI","event":"push","conclusion":"","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":104,"status":"queued"}]' > "$path"
            ;;
        no_matching_run)
            printf '%s\n' '[{"name":"CI","event":"pull_request","conclusion":"success","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":105,"status":"completed"},{"name":"Other","event":"push","conclusion":"success","createdAt":"2026-08-03T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":106,"status":"completed"}]' > "$path"
            ;;
        head_mismatch)
            printf '%s\n' '[{"name":"CI","event":"push","conclusion":"success","createdAt":"2026-08-02T10:00:00Z","headSha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","databaseId":107,"status":"completed"}]' > "$path"
            ;;
        empty_array)
            printf '%s\n' '[]' > "$path"
            ;;
        malformed)
            printf '%s\n' '{not-json' > "$path"
            ;;
        empty_json)
            : > "$path"
            ;;
        *)
            fail "unknown fixture scenario $scenario"
            ;;
    esac
}

run_fixture() {
    local scenario="$1" fixture_dir fixture_path
    new_temp_dir fixture_dir
    fixture_path="$fixture_dir/runs.json"
    write_fixture "$fixture_path" "$scenario"
    run_command env GH_TOKEN= bash "$PROBE" --fixture "$fixture_path" --fixture-head-sha "$MIRROR_HEAD"
}

assert_fixture_result() {
    local scenario="$1" expected_rc="$2" expected_fields="$3"
    run_fixture "$scenario"
    assert_eq "$RC" "$expected_rc" "$scenario aggregate exit status"
    assert_contains "$OUTPUT" "repo=fixture/fjcloud mirror_head=$MIRROR_HEAD" "$scenario reports fixture mirror HEAD"
    assert_contains "$OUTPUT" "$expected_fields" "$scenario reports exact classifier fields"
}

run_fixture_classifier_contracts() {
    assert_fixture_result green 0 "run_id=101 status=completed conclusion=success run_head_sha=$MIRROR_HEAD"
    assert_contains "$OUTPUT" "reason=green" "green fixture is current-HEAD green"
    assert_matches "$OUTPUT" 'age_seconds=[0-9]+' "green fixture reports run age"

    assert_fixture_result failure 1 "run_id=102 status=completed conclusion=failure run_head_sha=$MIRROR_HEAD"
    assert_contains "$OUTPUT" "reason=ci_non_success" "failed run is non-green"
    assert_fixture_result cancelled 1 "run_id=103 status=completed conclusion=cancelled run_head_sha=$MIRROR_HEAD"
    assert_contains "$OUTPUT" "reason=ci_non_success" "cancelled run is non-green"
    assert_fixture_result queued 1 "run_id=104 status=queued conclusion=none run_head_sha=$MIRROR_HEAD"
    assert_contains "$OUTPUT" "reason=ci_not_completed" "non-completed run is non-green"
    assert_fixture_result no_matching_run 1 "run_id=none status=none conclusion=none run_head_sha=none age_seconds=unknown reason=ci_run_missing"
    assert_fixture_result empty_array 1 "reason=ci_run_missing"
    assert_fixture_result head_mismatch 1 "run_id=107 status=completed conclusion=success run_head_sha=$OTHER_HEAD"
    assert_contains "$OUTPUT" "reason=ci_head_mismatch" "newest matching run must equal mirror HEAD"
    assert_fixture_result malformed 1 "reason=malformed_output"
    assert_fixture_result empty_json 1 "reason=malformed_output"
}

run_fixture_argument_contracts() {
    local fixture_dir fixture_path
    new_temp_dir fixture_dir
    fixture_path="$fixture_dir/runs.json"
    write_fixture "$fixture_path" green

    run_command bash "$PROBE" --fixture "$fixture_path"
    assert_eq "$RC" "2" "fixture without fixture HEAD is rejected"
    assert_contains "$OUTPUT" "reason=invalid_arguments" "unpaired fixture reports stable reason"

    run_command bash "$PROBE" --fixture-head-sha "$MIRROR_HEAD"
    assert_eq "$RC" "2" "fixture HEAD without fixture is rejected"
    assert_contains "$OUTPUT" "reason=invalid_arguments" "unpaired fixture HEAD reports stable reason"
}

write_live_gh_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ -n "${GH_STUB_LOG:-}" ]; then
    printf '%s\n' "$*" >> "$GH_STUB_LOG"
fi
if [ "${1:-}" = "auth" ] && [ "${2:-}" = "status" ]; then
    [ "${GH_STUB_SCENARIO:-green}" != "unauthenticated" ]
    exit $?
fi
if [ "${1:-}" = "api" ]; then
    if [ "${GH_STUB_SCENARIO:-green}" = "api_failure" ] && [[ "${2:-}" == *gridl-infra-staging* ]]; then
        exit 9
    fi
    printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    exit 0
fi
if [ "${1:-}" = "run" ] && [ "${2:-}" = "list" ]; then
    printf '%s\n' '[{"name":"CI","event":"push","conclusion":"success","createdAt":"2026-08-02T10:00:00Z","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","databaseId":201,"status":"completed"}]'
    exit 0
fi
exit 8
STUB
    chmod +x "$path"
}

run_live_auth_and_aggregate_contracts() {
    local stub_dir gh_log
    new_temp_dir stub_dir
    gh_log="$stub_dir/gh.log"
    write_live_gh_stub "$stub_dir/gh"

    : > "$gh_log"
    run_command env GH_TOKEN= GH_STUB_LOG="$gh_log" PATH="$stub_dir:$PATH" bash "$PROBE"
    assert_eq "$RC" "1" "explicitly empty GH_TOKEN fails"
    assert_contains "$OUTPUT" "reason=auth_missing" "empty token reports auth_missing"
    assert_not_contains "$OUTPUT" "reason=green" "empty token cannot report a mirror green"
    assert_eq "$(wc -l < "$gh_log" | tr -d ' ')" "0" "empty token fails before invoking gh"

    run_command env -u GH_TOKEN GH_STUB_SCENARIO=unauthenticated PATH="$stub_dir:$PATH" bash "$PROBE"
    assert_eq "$RC" "1" "unauthenticated gh credential store fails"
    assert_contains "$OUTPUT" "reason=auth_missing" "unauthenticated gh reports auth_missing"
    assert_not_contains "$OUTPUT" "reason=green" "unauthenticated gh cannot report green"

    run_command env GH_TOKEN=rejected-token GH_STUB_SCENARIO=unauthenticated PATH="$stub_dir:$PATH" bash "$PROBE"
    assert_eq "$RC" "1" "rejected explicit GH_TOKEN fails"
    assert_contains "$OUTPUT" "reason=auth_missing" "rejected explicit GH_TOKEN reports auth_missing"
    assert_not_contains "$OUTPUT" "reason=api_failure" "rejected explicit GH_TOKEN is not misclassified as an API failure"

    run_command env GH_TOKEN=test-token GH_STUB_SCENARIO=api_failure PATH="$stub_dir:$PATH" bash "$PROBE"
    assert_eq "$RC" "1" "one GitHub failure makes aggregate non-green"
    assert_contains "$OUTPUT" "repo=gridl-infra-staging/fjcloud mirror_head=unknown run_id=none status=none conclusion=none run_head_sha=none age_seconds=unknown reason=api_failure" "staging API failure is named"
    assert_contains "$OUTPUT" "repo=gridl-infra-prod/fjcloud mirror_head=$MIRROR_HEAD run_id=201 status=completed conclusion=success run_head_sha=$MIRROR_HEAD" "prod evidence survives staging failure"
    assert_contains "$OUTPUT" "reason=green" "healthy prod verdict is retained"
}

write_always_fail_stub() {
    local path="$1"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$path"
    chmod +x "$path"
}

write_mirror_row_stub() {
    local path="$1"
    cat > "$path" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
green="run_id=301 status=completed conclusion=success run_head_sha=$head age_seconds=60 reason=green"
case "${MIRROR_STUB_SCENARIO:-green}" in
    green)
        printf 'repo=gridl-infra-staging/fjcloud mirror_head=%s %s\n' "$head" "$green"
        printf 'repo=gridl-infra-prod/fjcloud mirror_head=%s %s\n' "$head" "$green"
        exit 0
        ;;
    action_required)
        printf 'repo=gridl-infra-staging/fjcloud mirror_head=%s run_id=302 status=completed conclusion=failure run_head_sha=%s age_seconds=60 reason=ci_non_success\n' "$head" "$head"
        printf 'repo=gridl-infra-prod/fjcloud mirror_head=%s %s\n' "$head" "$green"
        exit 1
        ;;
    auth_missing)
        printf 'repo=gridl-infra-staging/fjcloud mirror_head=unknown run_id=none status=none conclusion=none run_head_sha=none age_seconds=unknown reason=auth_missing\n'
        printf 'repo=gridl-infra-prod/fjcloud mirror_head=unknown run_id=none status=none conclusion=none run_head_sha=none age_seconds=unknown reason=auth_missing\n'
        exit 1
        ;;
    probe_error)
        printf 'repo=gridl-infra-staging/fjcloud mirror_head=unknown run_id=none status=none conclusion=none run_head_sha=none age_seconds=unknown reason=api_failure\n'
        printf 'repo=gridl-infra-prod/fjcloud mirror_head=%s run_id=303 status=completed conclusion=failure run_head_sha=%s age_seconds=60 reason=ci_non_success\n' "$head" "$head"
        exit 1
        ;;
esac
STUB
    chmod +x "$path"
}

extract_live_state_status() {
    local summary="$1"
    awk '
        $0 == "### mirror_ci_currency" { found=1; next }
        found && /^- status: / { sub(/^- status: /, ""); print; exit }
    ' "$summary"
}

run_live_state_mapping() {
    local scenario="$1" expected_status="$2" temp_dir bin_dir summary mirror_stub secret_file
    new_temp_dir temp_dir
    bin_dir="$temp_dir/bin"
    summary="$temp_dir/bundle/SUMMARY.md"
    mirror_stub="$temp_dir/mirror_stub"
    secret_file="$temp_dir/env.secret"
    mkdir -p "$bin_dir" "$(dirname "$summary")"
    : > "$secret_file"
    write_always_fail_stub "$bin_dir/aws"
    write_always_fail_stub "$bin_dir/curl"
    write_always_fail_stub "$bin_dir/gh"
    write_mirror_row_stub "$mirror_stub"

    run_command env -u GH_TOKEN \
        PATH="$bin_dir:$PATH" \
        FJCLOUD_SECRET_FILE="$secret_file" \
        STRIPE_SECRET_KEY= \
        CLOUDFLARE_API_TOKEN= \
        CLOUDFLARE_GLOBAL_API_KEY= \
        PRIVACY_PRODUCTION_API_KEY= \
        LIVE_STATE_SKIP_STAGING_RDS=1 \
        LIVE_STATE_OUTPUT_PATH="$summary" \
        MIRROR_STUB_SCENARIO="$scenario" \
        MIRROR_CI_CURRENCY_PROBE="$mirror_stub" \
        bash "$LIVE_STATE_PROBE"
    assert_eq "$RC" "0" "$scenario live-state inventory preserves exit-zero contract"
    assert_eq "$(extract_live_state_status "$summary")" "$expected_status" "$scenario maps to $expected_status"
    assert_eq "$(grep -Fxc 'mirror_ci_currency.txt' "$(dirname "$summary")/manifest.txt")" "1" "$scenario registers one raw manifest entry"
    assert_contains "$(cat "$(dirname "$summary")/mirror_ci_currency.txt")" "reason=" "$scenario preserves raw classifier evidence"
}

run_live_state_integration_contracts() {
    run_live_state_mapping green OK
    run_live_state_mapping action_required ACTION_REQUIRED
    run_live_state_mapping auth_missing SKIP_NO_CREDS
    run_live_state_mapping probe_error PROBE_ERROR

    local temp_dir override_stub secret_file
    new_temp_dir temp_dir
    override_stub="$temp_dir/mirror_stub"
    secret_file="$temp_dir/env.secret"
    : > "$secret_file"
    write_mirror_row_stub "$override_stub"
    run_command env MIRROR_CI_CURRENCY_PROBE="$override_stub" FJCLOUD_SECRET_FILE="$secret_file" bash "$LIVE_STATE_PROBE"
    assert_eq "$RC" "2" "mirror probe override is rejected without isolated output"
    assert_contains "$OUTPUT" "FAIL_UNSAFE_PROBE_OVERRIDE" "unsafe override rejection is explicit"
}

run_fixture_classifier_contracts
run_fixture_argument_contracts
run_live_auth_and_aggregate_contracts
run_live_state_integration_contracts

printf '\nSummary: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [ "$FAIL_COUNT" -ne 0 ]; then
    exit 1
fi
