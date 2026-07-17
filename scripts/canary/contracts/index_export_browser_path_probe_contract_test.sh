#!/usr/bin/env bash
# Contract test for index_export_browser_path_probe.sh artifact ownership.
# Ensures summary.json is the only machine-readable verdict artifact in run dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# shellcheck source=../../tests/lib/test_runner.sh
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck source=../../tests/lib/assertions.sh
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

run_probe_with_stubbed_playwright() {
    local stub_dir
    stub_dir="$(mktemp -d)"
    local stub_npx="$stub_dir/npx"

    cat > "$stub_npx" <<'NPX_STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${OVERVIEW_EXPORT_PROBE_VERDICT_PATH:-}" ]]; then
  cat > "$OVERVIEW_EXPORT_PROBE_VERDICT_PATH" <<'VERDICT_JSON'
{
  "export_filename_verdict": true,
  "export_payload_verdict": true,
  "import_banner_verdict": true
}
VERDICT_JSON
fi
printf 'stub playwright run\n'
NPX_STUB
    chmod +x "$stub_npx"

    local output
    output="$(PATH="$stub_dir:$PATH" bash "$REPO_ROOT/scripts/canary/contracts/index_export_browser_path_probe.sh")"

    local summary_path
    summary_path="$(printf '%s\n' "$output" | awk -F= '/^summary_json=/{print $2}' | tail -n1)"
    assert_ne "$summary_path" "" "probe output should expose summary_json path"
    assert_file_exists "$summary_path" "probe should write summary.json"

    local run_dir
    run_dir="$(dirname "$summary_path")"
    local summary_payload
    summary_payload="$(cat "$summary_path")"

    assert_contains "$summary_payload" '"playwright_exit_status": 0' "summary should record playwright success"
    assert_contains "$summary_payload" '"export_filename_verdict": true' "summary should record export filename verdict"
    assert_contains "$summary_payload" '"export_payload_verdict": true' "summary should record export payload verdict"
    assert_contains "$summary_payload" '"import_banner_verdict": true' "summary should record import banner verdict"

    local json_artifacts
    json_artifacts="$(ls "$run_dir"/*.json 2>/dev/null | wc -l | tr -d ' ')"
    assert_eq "$json_artifacts" "1" "run dir should contain only one machine-readable verdict JSON"

    assert_file_exists "$run_dir/summary.json" "run dir should keep summary.json"
    if [[ -f "$run_dir/playwright_verdict.json" ]]; then
        fail "run dir should not persist playwright_verdict.json"
    else
        pass "run dir does not persist playwright_verdict.json"
    fi

    assert_not_contains "$summary_payload" '"playwright_verdict_path"' "summary.json should not advertise a second verdict artifact"

    rm -rf "$run_dir" "$stub_dir"
}

run_probe_with_stubbed_playwright
run_test_summary
