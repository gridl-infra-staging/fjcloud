#!/usr/bin/env bash
# Red contract tests for scripts/lib/deployable_currency.sh.
#
# Deployable paths are derived from the deploy-staging/deploy-prod release
# artifact jobs in .github/workflows/ci.yml. A change is deployable when it
# touches these source or artifact-owner paths:
#   infra/api/src, infra/billing/src, infra/metering-agent/src,
#   infra/aggregation-job/src, infra/retention-job/src,
#   infra/pricing-calculator/src, infra/*/Cargo.toml, infra/Cargo.toml,
#   infra/Cargo.lock, infra/migrations/, ops/scripts/migrate.sh,
#   ops/scripts/lib/generate_ssm_env.sh,
#   ops/systemd/fj-metering-agent.service.
#
# Exclusion rule: **/*.md, docs/**, chats/**, and chatting/** never count as
# deployable drift. Any touched file under a deployable path does count, even
# if the hunk only changes Rust doc comments.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$REPO_ROOT/scripts/lib/deployable_currency.sh"
TEST_SOURCE_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
TEST_DEV_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

write_fixture_file() {
    local repo="$1"
    local path="$2"
    local content="$3"

    mkdir -p "$(dirname "$repo/$path")"
    printf '%s\n' "$content" > "$repo/$path"
}

commit_fixture_change() {
    local repo="$1"
    local message="$2"

    git -C "$repo" add .
    git -C "$repo" commit -m "$message" >/dev/null
    git -C "$repo" rev-parse HEAD
}

commit_deployable_path_fixture() {
    local repo="$1"
    local branch="$2"
    local path="$3"

    git -C "$repo" checkout -b "$branch" "$BASE_SHA" >/dev/null 2>&1
    write_fixture_file "$repo" "$path" "deployable drift for $path"
    commit_fixture_change "$repo" "deployable ahead: $path"
}

write_deployable_currency_verdict_file() {
    local path="$1"
    local source_sha="$2"
    local dev_sha="$3"
    local deployable_drift="$4"
    local doc_only_ahead="$5"

    cat > "$path" <<JSON
{"schema_version":"1","source_sha":"$source_sha","dev_sha":"$dev_sha","deployable_drift":$deployable_drift,"doc_only_ahead":$doc_only_ahead}
JSON
}

create_path_with_bash_python_no_git() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    ln -s "$(command -v bash)" "$bin_dir/bash"
    ln -s "$(command -v python3)" "$bin_dir/python3"
}

write_status_script_stub() {
    local path="$1"
    local body="$2"

    printf '%s\n' '#!/usr/bin/env bash' "$body" > "$path"
}

probe_with_capture() {
    local status_script="$1"
    local path_dir="$2"
    local json_path="${3:-}"
    local source_sha="${4:-}"

    local output exit_code=0
    output="$(PATH="$path_dir" \
        FJCLOUD_DEPLOYABLE_CURRENCY_JSON="$json_path" \
        FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA="$source_sha" \
        probe_staging_deployable_currency "$status_script" 2>&1)" || exit_code=$?

    printf '%s\n%s\n' "$exit_code" "$output"
}

assert_probe_result() {
    local status_script="$1"
    local path_dir="$2"
    local json_path="$3"
    local source_sha="$4"
    local expected_exit="$5"
    local expected_output="$6"
    local msg="$7"

    if ! load_classifier; then
        return
    fi

    local captured exit_code output
    captured="$(probe_with_capture "$status_script" "$path_dir" "$json_path" "$source_sha")"
    exit_code="${captured%%$'\n'*}"
    output="${captured#*$'\n'}"

    assert_eq "$exit_code" "$expected_exit" "$msg exit status"
    assert_eq "$output" "$expected_output" "$msg stdout"
}

assert_probe_failure_shape() {
    local status_script="$1"
    local path_dir="$2"
    local json_path="$3"
    local source_sha="$4"
    local msg="$5"

    if ! load_classifier; then
        return
    fi

    local captured exit_code output detail
    captured="$(probe_with_capture "$status_script" "$path_dir" "$json_path" "$source_sha")"
    exit_code="${captured%%$'\n'*}"
    output="${captured#*$'\n'}"
    detail="${output#unknown|unknown|unknown|}"

    assert_ne "$exit_code" "0" "$msg returns nonzero"
    assert_ne "$exit_code" "127" "$msg does not leak shell command-not-found status"
    assert_contains "$output" "unknown|unknown|unknown|" "$msg returns unknown sentinel"
    assert_ne "$detail" "$output" "$msg includes diagnostic field"
    assert_ne "$detail" "" "$msg diagnostic is nonempty"
    assert_not_contains "$output" "git: command not found" "$msg hides bare git command failure"
    assert_not_contains "$output" "deployable_drift=false" "$msg never defaults false on failure"
    assert_not_contains "$output" "doc_only_ahead=false" "$msg never defaults doc-only false on failure"
}

assert_status_script_not_invoked() {
    local marker="$1"
    local msg="$2"

    if [ -e "$marker" ]; then
        fail "$msg (status-script marker exists at '$marker')"
    else
        pass "$msg"
    fi
}

create_currency_fixture_repo() {
    local repo="$1"

    git init "$repo" >/dev/null
    git -C "$repo" config user.email "deployable-currency-test@example.invalid"
    git -C "$repo" config user.name "Deployable Currency Test"

    write_fixture_file "$repo" "README.md" "fixture root"
    BASE_SHA="$(commit_fixture_change "$repo" "base")"

    git -C "$repo" checkout -b doc-only "$BASE_SHA" >/dev/null 2>&1
    write_fixture_file "$repo" "docs/x.md" "docs drift"
    write_fixture_file "$repo" "some/DIRMAP.md" "generated map drift"
    DOC_ONLY_SHA="$(commit_fixture_change "$repo" "doc-only ahead")"

    API_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-api-src "infra/api/src/foo.rs")"
    BILLING_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-billing-src "infra/billing/src/lib.rs")"
    METERING_AGENT_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-metering-agent-src "infra/metering-agent/src/main.rs")"
    AGGREGATION_JOB_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-aggregation-job-src "infra/aggregation-job/src/main.rs")"
    RETENTION_JOB_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-retention-job-src "infra/retention-job/src/main.rs")"
    PRICING_CALCULATOR_SRC_SHA="$(commit_deployable_path_fixture "$repo" deployable-pricing-calculator-src "infra/pricing-calculator/src/lib.rs")"
    CRATE_CARGO_TOML_SHA="$(commit_deployable_path_fixture "$repo" deployable-crate-cargo-toml "infra/api/Cargo.toml")"
    ROOT_CARGO_TOML_SHA="$(commit_deployable_path_fixture "$repo" deployable-root-cargo-toml "infra/Cargo.toml")"
    CARGO_LOCK_SHA="$(commit_deployable_path_fixture "$repo" deployable-cargo-lock "infra/Cargo.lock")"
    MIGRATION_SHA="$(commit_deployable_path_fixture "$repo" deployable-migration "infra/migrations/20260710000000_currency_fixture.sql")"
    MIGRATE_SCRIPT_SHA="$(commit_deployable_path_fixture "$repo" deployable-migrate-script "ops/scripts/migrate.sh")"
    GENERATE_SSM_ENV_SHA="$(commit_deployable_path_fixture "$repo" deployable-generate-ssm-env "ops/scripts/lib/generate_ssm_env.sh")"
    SYSTEMD_UNIT_SHA="$(commit_deployable_path_fixture "$repo" deployable-systemd-unit "ops/systemd/fj-metering-agent.service")"
}

load_classifier() {
    if [ ! -f "$CLASSIFIER" ]; then
        fail "classifier owner seam exists at scripts/lib/deployable_currency.sh"
        return 1
    fi

    # shellcheck source=/dev/null
    source "$CLASSIFIER"
    if ! declare -F classify_deployable_currency >/dev/null 2>&1; then
        fail "classifier exposes classify_deployable_currency"
        return 1
    fi
}

assert_exact_assignment_line() {
    local output="$1"
    local key="$2"
    local expected_value="$3"
    local msg="$4"
    local expected_line="$key=$expected_value"
    local actual_lines

    actual_lines="$(printf '%s\n' "$output" | grep -E "^${key}=" || true)"
    if [ "$actual_lines" = "$expected_line" ]; then
        pass "$msg"
    else
        fail "$msg (expected exact line '$expected_line' but found '$actual_lines')"
    fi
}

assert_currency() {
    local repo="$1"
    local deployed_sha="$2"
    local target_sha="$3"
    local expected_deployable="$4"
    local expected_doc_only="$5"
    local msg="$6"

    if ! load_classifier; then
        return
    fi

    local output exit_code=0
    output="$(classify_deployable_currency "$repo" "$deployed_sha" "$target_sha" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "$msg returns without crashing"
    assert_exact_assignment_line "$output" "deployable_drift" "$expected_deployable" \
        "$msg reports deployable_drift=$expected_deployable"
    assert_exact_assignment_line "$output" "doc_only_ahead" "$expected_doc_only" \
        "$msg reports doc_only_ahead=$expected_doc_only"
}

test_doc_only_ahead_is_not_deployable() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_currency_fixture_repo "$tmp_dir/repo"

    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$DOC_ONLY_SHA" \
        "false" "true" "doc-only ahead range"

    rm -rf "$tmp_dir"
}

test_workflow_allowlist_paths_are_deployable() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_currency_fixture_repo "$tmp_dir/repo"

    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$API_SRC_SHA" \
        "true" "false" "infra/api/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$BILLING_SRC_SHA" \
        "true" "false" "infra/billing/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$METERING_AGENT_SRC_SHA" \
        "true" "false" "infra/metering-agent/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$AGGREGATION_JOB_SRC_SHA" \
        "true" "false" "infra/aggregation-job/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$RETENTION_JOB_SRC_SHA" \
        "true" "false" "infra/retention-job/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$PRICING_CALCULATOR_SRC_SHA" \
        "true" "false" "infra/pricing-calculator/src deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$CRATE_CARGO_TOML_SHA" \
        "true" "false" "infra/*/Cargo.toml deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$ROOT_CARGO_TOML_SHA" \
        "true" "false" "infra/Cargo.toml deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$CARGO_LOCK_SHA" \
        "true" "false" "infra/Cargo.lock deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$MIGRATION_SHA" \
        "true" "false" "infra/migrations deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$MIGRATE_SCRIPT_SHA" \
        "true" "false" "ops/scripts/migrate.sh deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$GENERATE_SSM_ENV_SHA" \
        "true" "false" "ops/scripts/lib/generate_ssm_env.sh deployable range"
    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$SYSTEMD_UNIT_SHA" \
        "true" "false" "ops/systemd/fj-metering-agent.service deployable range"

    rm -rf "$tmp_dir"
}

test_identical_shas_have_no_drift() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_currency_fixture_repo "$tmp_dir/repo"

    assert_currency "$tmp_dir/repo" "$BASE_SHA" "$BASE_SHA" \
        "false" "false" "identical SHA range"

    rm -rf "$tmp_dir"
}

test_unknown_deployed_sha_is_unknown_without_crash() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_currency_fixture_repo "$tmp_dir/repo"
    local absent_sha="1111111111111111111111111111111111111111"

    assert_currency "$tmp_dir/repo" "local-dev" "$API_SRC_SHA" \
        "unknown" "unknown" "local-dev deployed SHA range"
    assert_currency "$tmp_dir/repo" "$absent_sha" "$API_SRC_SHA" \
        "unknown" "unknown" "absent deployed SHA range"

    rm -rf "$tmp_dir"
}

test_injected_currency_file_works_without_git_or_checkout() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_path_with_bash_python_no_git "$tmp_dir/bin"
    write_deployable_currency_verdict_file "$tmp_dir/verdict.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" true false
    write_status_script_stub "$tmp_dir/deploy_status.sh" "printf invoked > '$tmp_dir/status_invoked'; exit 42"

    (
        cd "$tmp_dir"
        assert_probe_result "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "$tmp_dir/verdict.json" "$TEST_SOURCE_SHA" \
            "0" "$TEST_DEV_SHA|true|false" \
            "injected verdict returns exact deployable triple without git checkout"
    )
    assert_status_script_not_invoked "$tmp_dir/status_invoked" \
        "injected verdict does not invoke deploy_status fallback"

    rm -rf "$tmp_dir"
}

test_no_injection_without_git_fails_closed() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_path_with_bash_python_no_git "$tmp_dir/bin"
    write_status_script_stub "$tmp_dir/deploy_status.sh" "git rev-parse HEAD"

    (
        cd "$tmp_dir"
        assert_probe_failure_shape "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "" "" \
            "no injected verdict and no git fails closed"
    )

    rm -rf "$tmp_dir"
}

test_unset_injection_preserves_status_json_fallback() {
    local tmp_dir fixture_json expected_triple fixture_triple
    tmp_dir="$(mktemp -d)"
    fixture_json='{"envs":{"staging":{"dev_sha":"cccccccccccccccccccccccccccccccccccccccc","deployable_drift":"false","doc_only_ahead":"true"}}}'
    expected_triple="cccccccccccccccccccccccccccccccccccccccc|false|true"
    create_path_with_bash_python_no_git "$tmp_dir/bin"
    write_deployable_currency_verdict_file "$tmp_dir/ambient.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" true false
    write_status_script_stub "$tmp_dir/deploy_status.sh" "if [ \"\$#\" -ne 3 ] || [ \"\$1\" != '--json' ] || [ \"\$2\" != '--env' ] || [ \"\$3\" != 'staging' ]; then printf 'unexpected argv: %s\n' \"\$*\" >&2; exit 64; fi
printf '%s\n' '$fixture_json'"

    fixture_triple="$(python3 - "$fixture_json" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
staging = payload["envs"]["staging"]
print(f'{staging["dev_sha"]}|{staging["deployable_drift"]}|{staging["doc_only_ahead"]}')
PY
)"
    assert_eq "$fixture_triple" "$expected_triple" \
        "fallback fixture independently encodes expected staging triple"
    (
        export FJCLOUD_DEPLOYABLE_CURRENCY_JSON="$tmp_dir/ambient.json"
        export FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA="$TEST_SOURCE_SHA"
        assert_probe_result "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "" "" "0" "$expected_triple" \
            "unset injection preserves deploy_status JSON fallback despite ambient injection env"
    )

    rm -rf "$tmp_dir"
}

assert_injection_failure_does_not_fallback() {
    local tmp_dir="$1"
    local name="$2"
    local json_path="$3"
    local source_sha="$4"

    rm -f "$tmp_dir/status_invoked"
    assert_probe_failure_shape "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "$json_path" "$source_sha" \
        "invalid injected verdict fails closed: $name"
    assert_status_script_not_invoked "$tmp_dir/status_invoked" \
        "invalid injected verdict does not fallback: $name"
}

test_injected_currency_fail_closed_matrix() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_path_with_bash_python_no_git "$tmp_dir/bin"
    write_status_script_stub "$tmp_dir/deploy_status.sh" "printf invoked > '$tmp_dir/status_invoked'; exit 0"

    printf '%s\n' 'not json' > "$tmp_dir/malformed.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "malformed JSON" "$tmp_dir/malformed.json" "$TEST_SOURCE_SHA"

    printf '%s\n' '{"schema_version":"1",' > "$tmp_dir/truncated.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "truncated JSON" "$tmp_dir/truncated.json" "$TEST_SOURCE_SHA"

    printf '%s\n' '{"schema_version":"1","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","dev_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deployable_drift":false}' > "$tmp_dir/missing_key.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "missing key" "$tmp_dir/missing_key.json" "$TEST_SOURCE_SHA"

    printf '%s\n' '{"schema_version":"1","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","dev_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deployable_drift":false,"doc_only_ahead":false,"extra":false}' > "$tmp_dir/extra_key.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "extra key" "$tmp_dir/extra_key.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/wrong_schema.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false false
    sed -i.bak 's/"schema_version":"1"/"schema_version":"2"/' "$tmp_dir/wrong_schema.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "wrong schema_version" "$tmp_dir/wrong_schema.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/source_upper.json" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" "$TEST_DEV_SHA" false false
    assert_injection_failure_does_not_fallback "$tmp_dir" "uppercase source_sha" "$tmp_dir/source_upper.json" "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    write_deployable_currency_verdict_file "$tmp_dir/source_short.json" "aaaaaaaa" "$TEST_DEV_SHA" false false
    assert_injection_failure_does_not_fallback "$tmp_dir" "short source_sha" "$tmp_dir/source_short.json" "aaaaaaaa"

    write_deployable_currency_verdict_file "$tmp_dir/dev_upper.json" "$TEST_SOURCE_SHA" "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" false false
    assert_injection_failure_does_not_fallback "$tmp_dir" "uppercase dev_sha" "$tmp_dir/dev_upper.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/dev_short.json" "$TEST_SOURCE_SHA" "bbbbbbbb" false false
    assert_injection_failure_does_not_fallback "$tmp_dir" "short dev_sha" "$tmp_dir/dev_short.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/deployable_string.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" '"false"' false
    assert_injection_failure_does_not_fallback "$tmp_dir" "string deployable_drift" "$tmp_dir/deployable_string.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/deployable_null.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" null false
    assert_injection_failure_does_not_fallback "$tmp_dir" "null deployable_drift" "$tmp_dir/deployable_null.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/doc_string.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false '"true"'
    assert_injection_failure_does_not_fallback "$tmp_dir" "string doc_only_ahead" "$tmp_dir/doc_string.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/doc_null.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false null
    assert_injection_failure_does_not_fallback "$tmp_dir" "null doc_only_ahead" "$tmp_dir/doc_null.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/illegal_true_true.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" true true
    assert_injection_failure_does_not_fallback "$tmp_dir" "illegal true true currency" "$tmp_dir/illegal_true_true.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/valid.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false false
    write_deployable_currency_verdict_file "$tmp_dir/ambient.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" true false
    (
        export FJCLOUD_DEPLOYABLE_CURRENCY_JSON="$tmp_dir/ambient.json"
        export FJCLOUD_DEPLOYABLE_CURRENCY_SOURCE_SHA="$TEST_SOURCE_SHA"
        assert_injection_failure_does_not_fallback "$tmp_dir" "only JSON env configured" "$tmp_dir/valid.json" ""
        assert_injection_failure_does_not_fallback "$tmp_dir" "only source SHA env configured" "" "$TEST_SOURCE_SHA"
    )

    cat > "$tmp_dir/duplicate_source_sha.json" <<JSON
{"schema_version":"1","source_sha":"dddddddddddddddddddddddddddddddddddddddd","source_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","dev_sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deployable_drift":false,"doc_only_ahead":false}
JSON
    assert_injection_failure_does_not_fallback "$tmp_dir" "duplicate source_sha key" "$tmp_dir/duplicate_source_sha.json" "$TEST_SOURCE_SHA"

    assert_injection_failure_does_not_fallback "$tmp_dir" "missing payload file" "$tmp_dir/missing.json" "$TEST_SOURCE_SHA"

    write_deployable_currency_verdict_file "$tmp_dir/unreadable.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false false
    chmod 000 "$tmp_dir/unreadable.json"
    assert_injection_failure_does_not_fallback "$tmp_dir" "unreadable payload file" "$tmp_dir/unreadable.json" "$TEST_SOURCE_SHA"
    chmod 600 "$tmp_dir/unreadable.json"

    assert_injection_failure_does_not_fallback "$tmp_dir" "source SHA mismatch" "$tmp_dir/valid.json" "dddddddddddddddddddddddddddddddddddddddd"

    rm -rf "$tmp_dir"
}

test_injected_currency_success_matrix() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    create_path_with_bash_python_no_git "$tmp_dir/bin"
    write_status_script_stub "$tmp_dir/deploy_status.sh" "printf invoked > '$tmp_dir/status_invoked'; exit 0"

    write_deployable_currency_verdict_file "$tmp_dir/deployable.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" true false
    assert_probe_result "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "$tmp_dir/deployable.json" "$TEST_SOURCE_SHA" \
        "0" "$TEST_DEV_SHA|true|false" "injected true false currency succeeds"
    assert_status_script_not_invoked "$tmp_dir/status_invoked" "true false success does not fallback"

    write_deployable_currency_verdict_file "$tmp_dir/doc_only.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false true
    assert_probe_result "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "$tmp_dir/doc_only.json" "$TEST_SOURCE_SHA" \
        "0" "$TEST_DEV_SHA|false|true" "injected false true currency succeeds"
    assert_status_script_not_invoked "$tmp_dir/status_invoked" "false true success does not fallback"

    write_deployable_currency_verdict_file "$tmp_dir/current.json" "$TEST_SOURCE_SHA" "$TEST_DEV_SHA" false false
    assert_probe_result "$tmp_dir/deploy_status.sh" "$tmp_dir/bin" "$tmp_dir/current.json" "$TEST_SOURCE_SHA" \
        "0" "$TEST_DEV_SHA|false|false" "injected false false currency succeeds"
    assert_status_script_not_invoked "$tmp_dir/status_invoked" "false false success does not fallback"

    rm -rf "$tmp_dir"
}

echo "=== deployable currency tests ==="
test_doc_only_ahead_is_not_deployable
test_workflow_allowlist_paths_are_deployable
test_identical_shas_have_no_drift
test_unknown_deployed_sha_is_unknown_without_crash
test_injected_currency_file_works_without_git_or_checkout
test_no_injection_without_git_fails_closed
test_unset_injection_preserves_status_json_fallback
test_injected_currency_fail_closed_matrix
test_injected_currency_success_matrix
run_test_summary
