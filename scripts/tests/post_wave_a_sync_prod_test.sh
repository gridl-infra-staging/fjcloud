#!/usr/bin/env bash
# TDD tests for scripts/launch/post_wave_a_sync_prod.sh helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/scripts/launch/post_wave_a_sync_prod.sh"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

# write_mock_deploy_status_script <script_path> [deployable_drift] [doc_only_ahead]
# Emits a stub deploy_status.sh that prints a fixed prod-drift envelope. The two
# optional args set the classifier booleans in the mocked envs.prod JSON; both
# default to "false" so existing callers keep their prior (fully-current) pass
# semantics.
write_mock_deploy_status_script() {
    local script_path="$1"
    local deployable_drift="${2:-false}"
    local doc_only_ahead="${3:-false}"
    cat > "$script_path" <<MOCK_DEPLOY_STATUS
#!/usr/bin/env bash
set -euo pipefail
if [ -n "\${DEPLOY_STATUS_ARGS_LOG:-}" ]; then
    printf '%s\n' "\$*" > "\$DEPLOY_STATUS_ARGS_LOG"
fi
cat <<'JSON'
{"dev_main_sha":"1234567890abcdef1234567890abcdef12345678","envs":{"prod":{"dev_sha":"abcdef0123456789abcdef0123456789abcdef01","build_time":"2026-06-01T00:00:00Z","commits_behind_main":"3","deployable_drift":"${deployable_drift}","doc_only_ahead":"${doc_only_ahead}"}}}
JSON
MOCK_DEPLOY_STATUS
    chmod +x "$script_path"
}

test_executable_bit() {
    if [ -x "$HELPER" ]; then
        pass "post_wave_a_sync_prod.sh has executable bit"
    else
        fail "post_wave_a_sync_prod.sh has executable bit (missing +x)"
    fi
}

test_help_prints_usage() {
    local output exit_code=0
    output=$(bash "$HELPER" --help 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--help exits 0"
    assert_contains "$output" "--check-only" "--help mentions --check-only mode"
    assert_contains "$output" "--execute" "--help mentions --execute mode"
}

test_check_only_exits_zero_and_prints_drift() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh"

    local output exit_code=0
    output=$(POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$HELPER" --check-only 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-only exits 0"
    assert_contains "$output" "dev_sha" "--check-only prints dev_sha"
    assert_contains "$output" "build_time" "--check-only prints build_time"
    assert_contains "$output" "commits_behind" "--check-only prints commits_behind"

    rm -rf "$tmp_dir"
}

test_check_only_requests_prod_only_status() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh"

    local args_log="$tmp_dir/deploy_status_args.log"
    local output exit_code=0
    output=$(DEPLOY_STATUS_ARGS_LOG="$args_log" \
        POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$HELPER" --check-only 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-only exits 0 when deploy-status is stubbed"

    local called_args
    called_args="$(cat "$args_log")"
    assert_contains "$called_args" "--json" "--check-only should request deploy-status JSON"
    assert_contains "$called_args" "--env prod" "--check-only should restrict deploy-status to prod"

    rm -rf "$tmp_dir"
}

test_check_only_treats_doc_only_ahead_as_converged() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # deployable_drift=false, doc_only_ahead=true: the ahead range touches only
    # doc-comment / chat paths, so the prod artifact is byte-identical => converged.
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh" "false" "true"

    local output exit_code=0
    output=$(POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$HELPER" --check-only 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-only exits 0 for doc-only-ahead JSON"
    assert_contains "$output" "deployable_drift:   false" \
        "--check-only prints deployable_drift false"
    assert_contains "$output" "converged (doc-only ahead)" \
        "--check-only labels a doc-only-ahead env as converged"
    assert_not_contains "$output" "(behind)" \
        "--check-only must not label a doc-only-ahead env as behind"

    rm -rf "$tmp_dir"
}

test_check_only_reports_deployable_drift_as_behind() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    # deployable_drift=true: the ahead range touches release-artifact inputs, so
    # the deployed prod SHA is genuinely behind.
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh" "true" "false"

    local output exit_code=0
    output=$(POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$HELPER" --check-only 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--check-only exits 0 for deployable-drift JSON"
    assert_contains "$output" "deployable_drift:   true" \
        "--check-only prints deployable_drift true"
    assert_contains "$output" "(behind)" \
        "--check-only labels a deployable-drift env as behind"

    rm -rf "$tmp_dir"
}

test_check_only_is_read_only() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local debbie_log="$tmp_dir/debbie_calls.log"
    # Mock the deploy-status owner so this test is hermetic (no live /version
    # probe) — required now that this suite runs in CI's shell-hygiene job.
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh"

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
echo "debbie:$*" >> "${DEBBIE_CALL_LOG:?}"
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    DEBBIE_CALL_LOG="$debbie_log" \
    POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --check-only >/dev/null 2>&1 || true

    if [ -f "$debbie_log" ] && [ -s "$debbie_log" ]; then
        fail "--check-only should not invoke debbie (found: $(cat "$debbie_log"))"
    else
        pass "--check-only does not invoke debbie (read-only)"
    fi

    rm -rf "$tmp_dir"
}

test_execute_requires_confirmation() {
    local output exit_code=0
    output=$(POST_WAVE_CONFIRM=0 bash "$HELPER" --execute 2>&1) || exit_code=$?

    assert_ne "$exit_code" "0" "--execute without confirmation should fail"
    assert_contains "$output" "confirm" \
        "--execute without confirmation should print confirmation message"
}

test_execute_with_yes_flag_bypasses_confirm_prompt() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local head_sha
    head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
echo "debbie:$*" >> "${DEBBIE_CALL_LOG:-/dev/null}"
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    cat > "$tmp_dir/gh" <<MOCK_GH
#!/usr/bin/env bash
echo '[{"conclusion":"success","headSha":"${head_sha}","createdAt":"2026-06-01T00:00:00Z"}]'
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"

    local exit_code=0
    DEBBIE_CALL_LOG="$tmp_dir/debbie_calls.log" \
    POST_WAVE_STAGING_GATE_SCRIPT="true" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$head_sha" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$head_sha" \
    POST_WAVE_VERIFY_SCRIPT="true" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$head_sha" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/receipt.json" >/dev/null 2>&1 || exit_code=$?

    assert_eq "$exit_code" "0" "--execute --yes should proceed without prompt"
    rm -rf "$tmp_dir"
}

test_execute_skips_stale_headsha_ci_result() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local head_sha
    head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    local stale_sha="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    local call_count_file="$tmp_dir/gh_call_count"
    echo "0" > "$call_count_file"

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    cat > "$tmp_dir/gh" <<MOCK_GH
#!/usr/bin/env bash
count=\$(cat "${call_count_file}")
count=\$((count + 1))
echo "\$count" > "${call_count_file}"
if [ "\$count" -le 2 ]; then
    echo '[{"conclusion":"success","headSha":"${stale_sha}","createdAt":"2026-06-01T00:00:00Z"}]'
else
    echo '[{"conclusion":"success","headSha":"${head_sha}","createdAt":"2026-06-01T00:01:00Z"}]'
fi
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"

    cat > "$tmp_dir/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$tmp_dir/sleep"

    local output exit_code=0
    CI_POLL_TIMEOUT_SEC=300 \
    POST_WAVE_STAGING_GATE_SCRIPT="true" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$head_sha" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$head_sha" \
    POST_WAVE_VERIFY_SCRIPT="true" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$head_sha" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/receipt.json" 2>&1 | tee "$tmp_dir/output.txt" || exit_code=$?
    output=$(cat "$tmp_dir/output.txt")

    assert_eq "$exit_code" "0" "should succeed after finding matching headSha"

    local final_count
    final_count=$(cat "$call_count_file")
    if [ "$final_count" -lt 3 ]; then
        fail "should have polled past stale headSha (calls: $final_count, expected >= 3)"
    else
        pass "correctly waited past stale headSha responses (calls: $final_count)"
    fi

    rm -rf "$tmp_dir"
}

test_execute_uses_matching_headsha_from_recent_run_list() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local head_sha
    head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    local newer_sha="1111111111111111111111111111111111111111"
    local call_count_file="$tmp_dir/gh_call_count"
    echo "0" > "$call_count_file"

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    cat > "$tmp_dir/gh" <<MOCK_GH
#!/usr/bin/env bash
count=\$(cat "${call_count_file}")
count=\$((count + 1))
echo "\$count" > "${call_count_file}"
echo '[{"conclusion":"in_progress","headSha":"${newer_sha}","createdAt":"2026-06-01T00:02:00Z"},{"conclusion":"success","headSha":"${head_sha}","createdAt":"2026-06-01T00:01:00Z"}]'
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"

    cat > "$tmp_dir/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$tmp_dir/sleep"

    local output exit_code=0
    CI_POLL_TIMEOUT_SEC=30 \
    POST_WAVE_STAGING_GATE_SCRIPT="true" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$head_sha" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$head_sha" \
    POST_WAVE_VERIFY_SCRIPT="true" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$head_sha" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/receipt.json" 2>&1 | tee "$tmp_dir/output.txt" || exit_code=$?
    output=$(cat "$tmp_dir/output.txt")

    assert_eq "$exit_code" "0" "should accept a matching headSha already present in recent CI results"
    assert_contains "$output" "Prod mirror CI passed" "should report success for the matching headSha"

    local final_count
    final_count=$(cat "$call_count_file")
    assert_eq "$final_count" "1" "should not wait when the matching headSha is already in the recent run list"

    rm -rf "$tmp_dir"
}

test_execute_polls_prod_mirror_commit_sha_not_dev_source_sha() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    local source_sha mirror_sha
    source_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    mirror_sha="2222222222222222222222222222222222222222"

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    cat > "$tmp_dir/gh" <<MOCK_GH
#!/usr/bin/env bash
echo '[{"conclusion":"success","headSha":"${mirror_sha}","createdAt":"2026-06-01T00:00:00Z"}]'
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"

    cat > "$tmp_dir/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$tmp_dir/sleep"

    local output exit_code=0
    CI_POLL_TIMEOUT_SEC=30 \
    POST_WAVE_STAGING_GATE_SCRIPT="true" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$mirror_sha" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$source_sha" \
    POST_WAVE_VERIFY_SCRIPT="true" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$source_sha" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/receipt.json" 2>&1 | tee "$tmp_dir/output.txt" || exit_code=$?
    output=$(cat "$tmp_dir/output.txt")

    assert_eq "$exit_code" "0" "should poll the prod mirror commit SHA after debbie sync"
    assert_contains "$output" "Expected prod source SHA: ${source_sha:0:12}" \
        "should still log the dev source SHA for traceability"
    assert_contains "$output" "Expected prod mirror headSha: ${mirror_sha:0:12}" \
        "should wait for the prod mirror commit SHA used by GitHub Actions"
    assert_contains "$output" "Prod mirror CI passed (headSha: ${mirror_sha:0:12})" \
        "should accept CI success for the mirror commit"

    rm -rf "$tmp_dir"
}

# Mock gh for staging-gate tests. Branches on invocation shape:
#   gh api .../contents/.debbie/sync_manifest.json -> prints the manifest JSON
#     (raw media type; the gate pipes it to `jq -r .dev_sha`)
#   gh run list -R gridl-infra-staging/...          -> staging run-list JSON
#   gh run list -R gridl-infra-prod/...             -> prod run-list JSON
write_mock_gh_with_gate() {
    local path="$1"
    local staging_runs_json="$2"
    local synced_dev_sha="$3"
    local prod_runs_json="$4"

    cat > "$path" <<MOCK_GH
#!/usr/bin/env bash
if [ "\$1" = "api" ]; then
    echo '{"schema_version":1,"dev_sha":"${synced_dev_sha}","dev_repo":"gridl-infra-dev/fjcloud_dev","synced_at":"2026-07-08T00:00:00Z"}'
    exit 0
fi
if [[ "\$*" == *"gridl-infra-staging/fjcloud"* ]]; then
    echo '${staging_runs_json}'
else
    echo '${prod_runs_json}'
fi
exit 0
MOCK_GH
    chmod +x "$path"
}

# Shared scaffolding for the four staging-gate tests: debbie call log + verify
# stub + prod-poll fixtures so the only variable is the staging gate input.
# synced_dev_sha is the dev SHA the mock manifest reports staging was synced
# from; the gate compares it (exact) against the real dev-repo HEAD.
run_execute_with_gate_fixtures() {
    local tmp_dir="$1"
    local staging_runs_json="$2"
    local synced_dev_sha="$3"

    local dev_head_sha staging_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    dev_head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
echo "debbie:$*" >> "${DEBBIE_CALL_LOG:?}"
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    write_mock_gh_with_gate "$tmp_dir/gh" \
        "$staging_runs_json" \
        "$synced_dev_sha" \
        "[{\"conclusion\":\"success\",\"headSha\":\"${dev_head_sha}\",\"createdAt\":\"2026-06-01T00:00:00Z\"}]"

    local exit_code=0
    DEBBIE_CALL_LOG="$tmp_dir/debbie_calls.log" \
    POST_WAVE_STAGING_MIRROR_HEAD_SHA="$staging_sha" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$dev_head_sha" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$dev_head_sha" \
    POST_WAVE_VERIFY_SCRIPT="true" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$dev_head_sha" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/receipt.json" > "$tmp_dir/output.txt" 2>&1 || exit_code=$?
    return "$exit_code"
}

gate_staging_sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# For the identity check to PASS, the mock manifest must report the real
# dev-repo HEAD (the gate reads it live via `git rev-parse HEAD`).
gate_dev_head() { git -C "$REPO_ROOT" rev-parse HEAD; }

test_execute_blocks_when_staging_ci_red() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Identity OK (staging synced current dev HEAD) but CI failed -> block on CI.
    local exit_code=0
    run_execute_with_gate_fixtures "$tmp_dir" \
        "[{\"status\":\"completed\",\"conclusion\":\"failure\",\"headSha\":\"${gate_staging_sha}\"}]" \
        "$(gate_dev_head)" || exit_code=$?

    assert_ne "$exit_code" "0" "red staging CI should block prod promotion"
    assert_contains "$(cat "$tmp_dir/output.txt")" "staging CI is not green" \
        "block message should name the CI verdict as the reason"
    # The load-bearing assertion: a blocked gate must mean prod was NEVER
    # synced — exit code alone could pass while the sync still happened.
    if [ -s "$tmp_dir/debbie_calls.log" ]; then
        fail "red staging CI must prevent debbie sync prod (found: $(cat "$tmp_dir/debbie_calls.log"))"
    else
        pass "red staging CI prevented debbie sync prod"
    fi

    rm -rf "$tmp_dir"
}

test_execute_blocks_when_staging_ci_pending() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Identity OK but CI still running (the common state right after a sync).
    local exit_code=0
    run_execute_with_gate_fixtures "$tmp_dir" \
        "[{\"status\":\"in_progress\",\"conclusion\":null,\"headSha\":\"${gate_staging_sha}\"}]" \
        "$(gate_dev_head)" || exit_code=$?

    assert_ne "$exit_code" "0" "in-progress staging CI should block prod promotion"
    if [ -s "$tmp_dir/debbie_calls.log" ]; then
        fail "pending staging CI must prevent debbie sync prod (found: $(cat "$tmp_dir/debbie_calls.log"))"
    else
        pass "pending staging CI prevented debbie sync prod"
    fi

    rm -rf "$tmp_dir"
}

test_execute_blocks_when_staging_synced_different_dev_sha() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Staging CI is green, but its manifest reports a DIFFERENT dev SHA than the
    # one this promotion would ship — staging validated other content. The
    # bogus SHA is a valid-shaped 40-char hex that is not the real dev HEAD.
    local exit_code=0
    run_execute_with_gate_fixtures "$tmp_dir" \
        "[{\"status\":\"completed\",\"conclusion\":\"success\",\"headSha\":\"${gate_staging_sha}\"}]" \
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" || exit_code=$?

    assert_ne "$exit_code" "0" "a staging sync of a different dev SHA should block prod promotion"
    assert_contains "$(cat "$tmp_dir/output.txt")" "debbie sync staging" \
        "identity-mismatch block message should tell the operator to sync staging first"
    if [ -s "$tmp_dir/debbie_calls.log" ]; then
        fail "identity mismatch must prevent debbie sync prod (found: $(cat "$tmp_dir/debbie_calls.log"))"
    else
        pass "identity mismatch prevented debbie sync prod"
    fi

    rm -rf "$tmp_dir"
}

test_execute_proceeds_when_staging_green_and_current() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    # Manifest reports the real dev HEAD (identity OK) and CI is green -> promote.
    local exit_code=0
    run_execute_with_gate_fixtures "$tmp_dir" \
        "[{\"status\":\"completed\",\"conclusion\":\"success\",\"headSha\":\"${gate_staging_sha}\"}]" \
        "$(gate_dev_head)" || exit_code=$?

    assert_eq "$exit_code" "0" "green+current staging should allow prod promotion"
    assert_contains "$(cat "$tmp_dir/debbie_calls.log" 2>/dev/null || true)" "debbie:sync prod" \
        "passing gate should proceed to debbie sync prod"

    rm -rf "$tmp_dir"
}

test_execute_fails_fast_when_gh_missing() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    # A PATH of "/bin:/usr/bin" does NOT simulate a missing gh on GitHub
    # runners: ubuntu images preinstall gh at /usr/bin/gh (and usr-merge makes
    # /bin an alias of /usr/bin). Build a minimal PATH containing only the
    # tools the script needs BEFORE its gh presence check — dirname (used by
    # the SCRIPT_DIR resolution; everything else up to the check is a shell
    # builtin) plus the debbie mock — so gh is genuinely absent everywhere.
    mkdir "$tmp_dir/minbin"
    ln -s "$(command -v dirname)" "$tmp_dir/minbin/dirname"

    # Resolve bash's absolute path with the normal PATH still in effect: the
    # overridden PATH below deliberately excludes gh, but the interpreter that
    # launches the helper must still be found, so invoke it by absolute path
    # rather than relying on the stripped PATH to locate `bash`.
    local bash_bin
    bash_bin="$(command -v bash)"

    # The three required flags must be present (they are validated before the
    # gh prerequisite check) so this test exercises the gh-missing path, not the
    # missing-flag path. Values only need to be well-formed; the dev-HEAD match
    # runs after the gh check and is never reached here.
    local output exit_code=0
    output=$(PATH="$tmp_dir:$tmp_dir/minbin" \
        POST_WAVE_VERIFY_SCRIPT="true" \
        "$bash_bin" "$HELPER" --execute --yes \
        --expected-dev-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --expected-staging-pages-sha "dddddddddddddddddddddddddddddddddddddddd" \
        --receipt "$tmp_dir/receipt.json" 2>&1) || exit_code=$?

    assert_ne "$exit_code" "0" "--execute should fail when gh is missing"
    assert_contains "$output" "gh CLI not found" \
        "--execute should print clear error when gh missing"
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Group 1: caller-supplied exact identities + secret-safe receipt contract.
# The three flags are validated after the confirm gate but before the
# debbie/gh prerequisite checks, so a missing/malformed flag fails loud without
# touching any external tool. All three tests share one debbie no-op mock; no
# execute path is reached, so gh/verify mocks are unnecessary.
# ---------------------------------------------------------------------------

# Run --execute --yes with an overridable set of the three identity flags and a
# debbie no-op mock, capturing exit code + combined output. flags_* default to
# well-formed values; pass "" to omit a flag entirely.
run_execute_flag_contract() {
    local tmp_dir="$1" dev_flag="$2" pages_flag="$3" receipt_flag="$4"
    local args=(--execute --yes)
    [ -n "$dev_flag" ] && args+=(--expected-dev-sha "$dev_flag")
    [ -n "$pages_flag" ] && args+=(--expected-staging-pages-sha "$pages_flag")
    [ -n "$receipt_flag" ] && args+=(--receipt "$receipt_flag")

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
echo "debbie:$*" >> "${DEBBIE_CALL_LOG:-/dev/null}"
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"

    RUN_FLAG_EXIT=0
    RUN_FLAG_OUTPUT=$(DEBBIE_CALL_LOG="$tmp_dir/debbie_calls.log" \
        POST_WAVE_STAGING_GATE_SCRIPT="true" \
        POST_WAVE_VERIFY_SCRIPT="true" \
        PATH="$tmp_dir:$PATH" \
        bash "$HELPER" "${args[@]}" 2>&1) || RUN_FLAG_EXIT=$?
}

test_execute_requires_expected_dev_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    run_execute_flag_contract "$tmp_dir" "" \
        "cccccccccccccccccccccccccccccccccccccccc" "$tmp_dir/r.json"
    assert_ne "$RUN_FLAG_EXIT" "0" "--execute without --expected-dev-sha must fail"
    assert_contains "$RUN_FLAG_OUTPUT" "--expected-dev-sha" \
        "missing --expected-dev-sha names the flag"
    [ -s "$tmp_dir/debbie_calls.log" ] && fail "missing flag must not reach debbie sync" || pass "missing flag blocked before debbie sync"
    rm -rf "$tmp_dir"
}

test_execute_requires_expected_pages_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    run_execute_flag_contract "$tmp_dir" "$head_sha" "" "$tmp_dir/r.json"
    assert_ne "$RUN_FLAG_EXIT" "0" "--execute without --expected-staging-pages-sha must fail"
    assert_contains "$RUN_FLAG_OUTPUT" "--expected-staging-pages-sha" \
        "missing --expected-staging-pages-sha names the flag"
    rm -rf "$tmp_dir"
}

test_execute_requires_receipt() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    run_execute_flag_contract "$tmp_dir" "$head_sha" \
        "cccccccccccccccccccccccccccccccccccccccc" ""
    assert_ne "$RUN_FLAG_EXIT" "0" "--execute without --receipt must fail"
    assert_contains "$RUN_FLAG_OUTPUT" "--receipt" "missing --receipt names the flag"
    rm -rf "$tmp_dir"
}

test_execute_rejects_non_40hex_dev_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    # 39 chars + a non-hex char: neither length nor alphabet is valid.
    run_execute_flag_contract "$tmp_dir" "zz34567890abcdef1234567890abcdef12345678" \
        "cccccccccccccccccccccccccccccccccccccccc" "$tmp_dir/r.json"
    assert_ne "$RUN_FLAG_EXIT" "0" "non-40hex --expected-dev-sha must fail"
    assert_contains "$RUN_FLAG_OUTPUT" "40 hex" "rejects non-40hex dev sha with a clear message"
    rm -rf "$tmp_dir"
}

test_execute_rejects_short_pages_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    run_execute_flag_contract "$tmp_dir" "$head_sha" "abc123" "$tmp_dir/r.json"
    assert_ne "$RUN_FLAG_EXIT" "0" "short --expected-staging-pages-sha must fail"
    assert_contains "$RUN_FLAG_OUTPUT" "40 hex" "rejects short pages sha with a clear message"
    rm -rf "$tmp_dir"
}

test_execute_rejects_existing_receipt() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    printf 'pre-existing\n' > "$tmp_dir/r.json"
    run_execute_flag_contract "$tmp_dir" "$head_sha" \
        "cccccccccccccccccccccccccccccccccccccccc" "$tmp_dir/r.json"
    assert_ne "$RUN_FLAG_EXIT" "0" "an existing --receipt path must fail (no clobber)"
    assert_contains "$RUN_FLAG_OUTPUT" "already exists" "no-clobber message names the collision"
    assert_eq "$(cat "$tmp_dir/r.json")" "pre-existing" "existing receipt file must be left untouched"
    rm -rf "$tmp_dir"
}

test_execute_rejects_mismatched_dev_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    # A well-formed 40hex that is NOT the real dev HEAD: the promotion must
    # ship exactly HEAD, so a mismatched expectation is rejected (after the
    # gh/debbie prereqs, so we mock both and a green gate).
    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
echo "debbie:$*" >> "${DEBBIE_CALL_LOG:-/dev/null}"
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"
    cat > "$tmp_dir/gh" <<'MOCK_GH'
#!/usr/bin/env bash
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"

    local exit_code=0 output
    output=$(DEBBIE_CALL_LOG="$tmp_dir/debbie_calls.log" \
        POST_WAVE_STAGING_GATE_SCRIPT="true" \
        POST_WAVE_VERIFY_SCRIPT="true" \
        PATH="$tmp_dir:$PATH" \
        bash "$HELPER" --execute --yes \
        --expected-dev-sha "abcdef0123456789abcdef0123456789abcdef01" \
        --expected-staging-pages-sha "cccccccccccccccccccccccccccccccccccccccc" \
        --receipt "$tmp_dir/r.json" 2>&1) || exit_code=$?
    assert_ne "$exit_code" "0" "--expected-dev-sha not equal to dev HEAD must fail"
    assert_contains "$output" "does not match dev HEAD" "mismatch message names the dev HEAD guard"
    [ -s "$tmp_dir/debbie_calls.log" ] && fail "mismatched dev sha must not reach debbie sync" || pass "mismatched dev sha blocked before debbie sync"
    rm -rf "$tmp_dir"
}

# ---------------------------------------------------------------------------
# Group 1 item 5 + Group 2: drive the REAL terminal verifier via the helper's
# POST_WAVE_VERIFY_SCRIPT seam plus a hermetic deploy-status fixture. This
# proves (a) execute_sync plumbs the caller-supplied + derived identities into
# the verifier, (b) the verifier enforces EXACT identity, and (c) the success
# path writes a secret-safe receipt.
# ---------------------------------------------------------------------------

# Served-identity deploy-status stub: prints .envs.prod.dev_sha / .mirror_sha.
write_mock_served_deploy_status() {
    local path="$1" served_dev_sha="$2" served_mirror_sha="$3"
    cat > "$path" <<MOCK_DS
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"dev_main_sha":"${served_dev_sha}","envs":{"prod":{"dev_sha":"${served_dev_sha}","mirror_sha":"${served_mirror_sha}","build_time":"2026-06-01T00:00:00Z","commits_behind_main":"0"}}}
JSON
MOCK_DS
    chmod +x "$path"
}

# Run the full promotion path with the real verifier wired in.
#   $2 served_dev_sha  $3 served_mirror_sha  $4 expected_pages_sha
#   $5 prod_mirror_head (derived head the poll matches + verifier expects)
# expected_dev_sha is always the real dev HEAD (the promotion). Sets
# RUN_VERIFY_EXIT and leaves output in $tmp_dir/output.txt.
run_execute_with_real_verifier() {
    local tmp_dir="$1" served_dev_sha="$2" served_mirror_sha="$3"
    local expected_pages_sha="$4" prod_mirror_head="$5"
    local expected_dev_sha; expected_dev_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)

    cat > "$tmp_dir/debbie" <<'MOCK_DEBBIE'
#!/usr/bin/env bash
exit 0
MOCK_DEBBIE
    chmod +x "$tmp_dir/debbie"
    cat > "$tmp_dir/gh" <<MOCK_GH
#!/usr/bin/env bash
echo '[{"conclusion":"success","headSha":"${prod_mirror_head}","createdAt":"2026-06-01T00:00:00Z","databaseId":123456}]'
exit 0
MOCK_GH
    chmod +x "$tmp_dir/gh"
    cat > "$tmp_dir/sleep" <<'MOCK_SLEEP'
#!/usr/bin/env bash
exit 0
MOCK_SLEEP
    chmod +x "$tmp_dir/sleep"
    write_mock_served_deploy_status "$tmp_dir/deploy_status.sh" "$served_dev_sha" "$served_mirror_sha"

    RUN_VERIFY_EXIT=0
    CI_POLL_TIMEOUT_SEC=30 \
    POST_WAVE_STAGING_GATE_SCRIPT="true" \
    POST_WAVE_PROD_MIRROR_HEAD_SHA="$prod_mirror_head" \
    POST_WAVE_PROD_MIRROR_MANIFEST_DEV_SHA="$expected_dev_sha" \
    POST_WAVE_VERIFY_SCRIPT="$REPO_ROOT/scripts/tests/post_wave_sync_to_prod_verify_test.sh" \
    POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
    PATH="$tmp_dir:$PATH" \
    bash "$HELPER" --execute --yes \
        --expected-dev-sha "$expected_dev_sha" \
        --expected-staging-pages-sha "$expected_pages_sha" \
        --receipt "$tmp_dir/receipt.json" > "$tmp_dir/output.txt" 2>&1 || RUN_VERIFY_EXIT=$?
}

test_verifier_fails_on_unchanged_head() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # Served mirror_sha is the OLD prod head, not the derived one -> prod never
    # redeployed. Exact-identity must reject this (a freshness window would not).
    run_execute_with_real_verifier "$tmp_dir" \
        "$head_sha" "8888888888888888888888888888888888888888" \
        "cccccccccccccccccccccccccccccccccccccccc" \
        "9999999999999999999999999999999999999999"
    assert_ne "$RUN_VERIFY_EXIT" "0" "unchanged prod mirror head must fail verification"
    assert_contains "$(cat "$tmp_dir/output.txt")" "mirror_sha" \
        "unchanged-head failure names the mirror_sha mismatch"
    [ -e "$tmp_dir/receipt.json" ] && fail "no receipt on failed verification" || pass "no receipt written on failed verification"
    rm -rf "$tmp_dir"
}

test_verifier_fails_on_stale_ancestor_dev_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    # Served dev_sha is a valid-shaped but DIFFERENT commit (a stale ancestor
    # would have passed the old is-ancestor window). Exact-identity rejects it.
    run_execute_with_real_verifier "$tmp_dir" \
        "abcdef0123456789abcdef0123456789abcdef01" \
        "9999999999999999999999999999999999999999" \
        "cccccccccccccccccccccccccccccccccccccccc" \
        "9999999999999999999999999999999999999999"
    assert_ne "$RUN_VERIFY_EXIT" "0" "stale/ancestor dev_sha must fail verification"
    assert_contains "$(cat "$tmp_dir/output.txt")" "dev_sha" \
        "stale-dev failure names the dev_sha mismatch"
    rm -rf "$tmp_dir"
}

test_verifier_fails_on_prod_derived_pages_sha() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # Pages SHA == derived prod mirror head -> Pages would be prod-derived, but
    # deploy-staging is the sole Pages deployer. Must fail even when dev+mirror
    # identities match exactly.
    run_execute_with_real_verifier "$tmp_dir" \
        "$head_sha" "9999999999999999999999999999999999999999" \
        "9999999999999999999999999999999999999999" \
        "9999999999999999999999999999999999999999"
    assert_ne "$RUN_VERIFY_EXIT" "0" "a prod-derived Pages SHA must fail verification"
    assert_contains "$(cat "$tmp_dir/output.txt")" "prod-derived" \
        "prod-derived Pages failure is named"
    rm -rf "$tmp_dir"
}

test_verifier_fails_on_ambient_auto_discovery() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # Drive the verifier DIRECTLY with NO expected-identity env vars: a verifier
    # that discovers its own expectation can never fail closed. Must FAIL.
    write_mock_served_deploy_status "$tmp_dir/deploy_status.sh" \
        "$head_sha" "9999999999999999999999999999999999999999"
    local exit_code=0 output
    output=$(env -u POST_WAVE_EXPECTED_DEV_SHA -u POST_WAVE_EXPECTED_MIRROR_SHA \
        -u POST_WAVE_EXPECTED_PAGES_SHA \
        POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$REPO_ROOT/scripts/tests/post_wave_sync_to_prod_verify_test.sh" 2>&1) || exit_code=$?
    assert_ne "$exit_code" "0" "verifier with no expected identities must fail (no auto-discovery)"
    assert_contains "$output" "required" "ambient run names the missing required expectation"
    rm -rf "$tmp_dir"
}

test_execute_writes_secret_safe_receipt() {
    local tmp_dir; tmp_dir="$(mktemp -d)"
    local head_sha; head_sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
    # All identities match -> verifier passes -> receipt is written.
    run_execute_with_real_verifier "$tmp_dir" \
        "$head_sha" "9999999999999999999999999999999999999999" \
        "cccccccccccccccccccccccccccccccccccccccc" \
        "9999999999999999999999999999999999999999"
    assert_eq "$RUN_VERIFY_EXIT" "0" "matched identities pass verification and write a receipt"
    assert_file_exists "$tmp_dir/receipt.json" "receipt JSON is written on success"

    local receipt; receipt=$(cat "$tmp_dir/receipt.json")
    assert_valid_json "$receipt" "receipt is valid JSON"
    assert_contains "$receipt" "$head_sha" "receipt binds the expected dev SHA"
    assert_contains "$receipt" "cccccccccccccccccccccccccccccccccccccccc" \
        "receipt binds the expected staging Pages SHA"
    assert_contains "$receipt" "9999999999999999999999999999999999999999" \
        "receipt binds the derived prod mirror head"
    assert_contains "$receipt" "123456" "receipt binds the green CI run id"
    assert_contains "$receipt" "debbie sync prod" "receipt records the commands run"

    # Secret-safe: the receipt must carry SHAs/run-ids/command names only, never
    # token or credential material. Grep the file for common secret markers.
    if grep -Eiq 'ghp_|gho_|ghs_|github_pat_|AKIA|whsec_|sk_live|sk_test|-----BEGIN|bearer[[:space:]]|authorization|password|api[_-]?key|access[_-]?token' "$tmp_dir/receipt.json"; then
        fail "receipt must not contain secret/token material"
    else
        pass "receipt contains no secret/token material"
    fi
    rm -rf "$tmp_dir"
}

echo "=== post_wave_a_sync_prod tests ==="
test_executable_bit
test_help_prints_usage
test_check_only_exits_zero_and_prints_drift
test_check_only_treats_doc_only_ahead_as_converged
test_check_only_reports_deployable_drift_as_behind
test_check_only_is_read_only
test_execute_requires_confirmation
test_execute_with_yes_flag_bypasses_confirm_prompt
test_execute_fails_fast_when_gh_missing
test_check_only_requests_prod_only_status
test_execute_skips_stale_headsha_ci_result
test_execute_uses_matching_headsha_from_recent_run_list
test_execute_polls_prod_mirror_commit_sha_not_dev_source_sha
test_execute_blocks_when_staging_ci_red
test_execute_blocks_when_staging_ci_pending
test_execute_blocks_when_staging_synced_different_dev_sha
test_execute_proceeds_when_staging_green_and_current
test_execute_requires_expected_dev_sha
test_execute_requires_expected_pages_sha
test_execute_requires_receipt
test_execute_rejects_non_40hex_dev_sha
test_execute_rejects_short_pages_sha
test_execute_rejects_existing_receipt
test_execute_rejects_mismatched_dev_sha
test_verifier_fails_on_unchanged_head
test_verifier_fails_on_stale_ancestor_dev_sha
test_verifier_fails_on_prod_derived_pages_sha
test_verifier_fails_on_ambient_auto_discovery
test_execute_writes_secret_safe_receipt
run_test_summary
