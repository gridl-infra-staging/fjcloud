#!/usr/bin/env bash
# TDD test for local-ci.sh --summary-only mode.
# Asserts: exits 0, prints summary header, runs no gates, completes fast.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$SCRIPT_DIR/lib/test_runner.sh"
source "$SCRIPT_DIR/lib/assertions.sh"

write_mock_deploy_status_script() {
    local script_path="$1"
    cat > "$script_path" <<'MOCK_DEPLOY_STATUS'
#!/usr/bin/env bash
set -euo pipefail
cat <<'JSON'
{"dev_main_sha":"1234567890abcdef1234567890abcdef12345678","envs":{"prod":{"dev_sha":"abcdef0123456789abcdef0123456789abcdef01","build_time":"2026-06-01T00:00:00Z","commits_behind_main":"3"}}}
JSON
MOCK_DEPLOY_STATUS
    chmod +x "$script_path"
}

test_summary_only_exits_zero_fast() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh"

    local start_epoch end_epoch elapsed
    start_epoch=$(date +%s)

    local output exit_code=0
    output=$(POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$REPO_ROOT/scripts/local-ci.sh" --summary-only 2>&1) || exit_code=$?

    end_epoch=$(date +%s)
    elapsed=$((end_epoch - start_epoch))

    assert_eq "$exit_code" "0" "--summary-only should exit 0"

    if [ "$elapsed" -le 5 ]; then
        pass "--summary-only completes in <= 5s (took ${elapsed}s)"
    else
        fail "--summary-only completes in <= 5s (took ${elapsed}s)"
    fi

    assert_contains "$output" "=== local-ci summary (summary-only)" \
        "--summary-only should print summary header"

    assert_not_contains "$output" "PASS" \
        "--summary-only should not execute any gate (no PASS rows)"
    assert_not_contains "$output" "FAIL" \
        "--summary-only should not execute any gate (no FAIL rows)"
    assert_not_contains "$output" "SKIP" \
        "--summary-only should not execute any gate (no SKIP rows)"

    rm -rf "$tmp_dir"
}

test_summary_only_includes_drift_block() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    write_mock_deploy_status_script "$tmp_dir/deploy_status.sh"

    local output exit_code=0
    output=$(POST_WAVE_DEPLOY_STATUS_SCRIPT="$tmp_dir/deploy_status.sh" \
        bash "$REPO_ROOT/scripts/local-ci.sh" --summary-only 2>&1) || exit_code=$?

    assert_eq "$exit_code" "0" "--summary-only exits 0 (drift block test)"
    assert_contains "$output" "Prod deploy drift" \
        "--summary-only should include drift section header"
    assert_contains "$output" "dev_sha" \
        "--summary-only drift block should show dev_sha"
    assert_contains "$output" "commits_behind" \
        "--summary-only drift block should show commits_behind"

    rm -rf "$tmp_dir"
}

echo "=== local-ci --summary-only tests ==="
test_summary_only_exits_zero_fast
test_summary_only_includes_drift_block
run_test_summary
