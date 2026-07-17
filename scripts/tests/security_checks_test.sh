#!/usr/bin/env bash
# Tests for scripts/reliability/lib/security_checks.sh: Security validation checks.
# Validates security check logic with seeded fixtures and mock tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0

fail() {
    echo "FAIL: $*" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

assert_eq() {
    local actual="$1" expected="$2" msg="$3"
    if [ "$actual" != "$expected" ]; then
        fail "$msg (expected='$expected' actual='$actual')"
    else
        pass "$msg"
    fi
}

assert_contains() {
    local actual="$1" expected_substr="$2" msg="$3"
    if [[ "$actual" != *"$expected_substr"* ]]; then
        fail "$msg (expected substring '$expected_substr' in '$actual')"
    else
        pass "$msg"
    fi
}

assert_not_contains() {
    local actual="$1" unexpected_substr="$2" msg="$3"
    if [[ "$actual" == *"$unexpected_substr"* ]]; then
        fail "$msg (unexpected substring '$unexpected_substr' found in '$actual')"
    else
        pass "$msg"
    fi
}

with_mock_cargo_audit() {
    local mode="$1" command="$2"
    local mock_dir
    mock_dir="$(mktemp -d)"

    case "$mode" in
        pass)
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
echo '{"vulnerabilities":{"count":0,"list":[]}}'
exit 0
MOCK
            ;;
        advisory|warn)
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2024-0001","severity":"low","package":"test"}}]}}
JSON
exit 1
MOCK
            ;;
        advisory_with_stderr)
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
echo 'updating advisory index...' >&2
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2024-0003","severity":"low","package":"test"}}]}}
JSON
exit 1
MOCK
            ;;
        critical|fail)
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2024-0002","severity":"high","package":"test"}}]}}
JSON
exit 1
MOCK
            ;;
        *)
            rm -rf "$mock_dir"
            echo "unknown cargo-audit mock mode: $mode" >&2
            return 2
            ;;
    esac

    chmod +x "$mock_dir/cargo-audit"

    BACKEND_LIVE_GATE=1 PATH="$mock_dir:$PATH" bash -c "$command"
    local status=$?
    rm -rf "$mock_dir"
    return $status
}

test_check_secret_scan_finds_fake_aws_key() {
    local fixture_path="$REPO_ROOT/scripts/reliability/fixtures/security"
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$fixture_path' true
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_secret_scan should fail on fixture with AWS key"
    assert_contains "$output" "SECURITY_SECRET_FOUND" "output should contain SECURITY_SECRET_FOUND"
}

test_check_secret_scan_finds_stripe_key() {
    local fixture_path="$REPO_ROOT/scripts/reliability/fixtures/security"
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$fixture_path' true
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_secret_scan should fail on fixture with Stripe test key"
    assert_contains "$output" "SECURITY_SECRET_FOUND" "output should contain SECURITY_SECRET_FOUND for Stripe key"
}

test_check_secret_scan_finds_fj_prefix_secret() {
    local fixture_path="$REPO_ROOT/scripts/reliability/fixtures/security"
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$fixture_path' true
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_secret_scan should fail on fixture with fj_ key"
    assert_contains "$output" "SECURITY_SECRET_FOUND" "output should contain SECURITY_SECRET_FOUND for fj_ key"
}

test_check_secret_scan_clean_repo() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$REPO_ROOT/scripts/reliability/lib'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_secret_scan should pass on clean paths"
    assert_contains "$output" "SECURITY_SECRET_CLEAN" "output should contain SECURITY_SECRET_CLEAN"
}

test_check_secret_scan_excludes_secret_dir() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$REPO_ROOT'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_secret_scan should pass on full repo (excludes .secret)"
    assert_contains "$output" "SECURITY_SECRET_CLEAN" "output should contain SECURITY_SECRET_CLEAN"
}

test_check_secret_scan_ignores_metrics_local_dev_placeholder() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$REPO_ROOT/scripts/reliability/lib/metrics.sh'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_secret_scan should ignore local-dev placeholder in metrics.sh"
    assert_contains "$output" "SECURITY_SECRET_CLEAN" "metrics.sh placeholder should not trigger SECURITY_SECRET_FOUND"
}

test_check_secret_scan_ignores_env_local_example_placeholder() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$REPO_ROOT/.env.local.example'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_secret_scan should ignore local-dev placeholder in .env.local.example"
    assert_contains "$output" "SECURITY_SECRET_CLEAN" ".env.local.example placeholder should not trigger SECURITY_SECRET_FOUND"
}

test_check_secret_scan_ignores_fj_inside_identifier_chain() {
    # Regression guard for the false-positive class where the `fj_` regex
    # matches inside a longer identifier chain (filename slug or roadmap
    # reference like `apr29_pm_8_fj_metering_agent_architectural_cleanup`).
    # The word-boundary anchor on `\<fj_` should prevent these matches while
    # still catching real fj-prefixed secrets that begin at a word boundary.
    local tmpdir
    tmpdir="$(mktemp -d)"
    # Embed the slug inside prose plus inside a markdown table cell — both
    # positions previously matched the loose `fj_[A-Za-z0-9_]{20,}` regex.
    printf 'See chats/icg/apr29_pm_8_fj_metering_agent_architectural_cleanup.md for context.\n' \
        > "$tmpdir/checklist_reference.md"
    printf '| `apr29_pm_8_fj_metering_agent_architectural_cleanup` | Removed dormant agent | path |\n' \
        > "$tmpdir/implemented_table.md"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "0" \
        "check_secret_scan should ignore fj_ inside an identifier chain (filename slug, not a secret)"
    assert_contains "$output" "SECURITY_SECRET_CLEAN" \
        "filename-slug references should not trigger SECURITY_SECRET_FOUND"
}

test_check_secret_scan_still_finds_word_boundary_fj_secret() {
    # Companion to the identifier-chain guard above: a true-positive `fj_*`
    # secret that DOES sit at a word boundary must still be detected.
    # Without this assertion, a future overcorrection could silently disable
    # the fj_ branch of the secret regex.
    local tmpdir
    tmpdir="$(mktemp -d)"
    # Real-shape secret: starts at line begin (word boundary), 20+ body chars,
    # contains an underscore so it exercises the underscore-allowed body class.
    printf 'FLAPJACK_API_KEY=fj_real_production_key_abc123def456\n' \
        > "$tmpdir/leaked.env"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "1" \
        "check_secret_scan should still detect a real fj_ secret at a word boundary"
    assert_contains "$output" "SECURITY_SECRET_FOUND" \
        "word-boundary fj_ secret should trigger SECURITY_SECRET_FOUND"
}

test_check_secret_scan_does_not_exclude_arbitrary_fixtures_dirs() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/fixtures"
    printf 'AKIA%s\n' '1234567890ABCDEF' > "$tmpdir/fixtures/leaked_key.txt"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "1" "check_secret_scan should fail for non-security fixture dirs containing keys"
    assert_contains "$output" "SECURITY_SECRET_FOUND" "output should contain SECURITY_SECRET_FOUND for non-security fixtures"
}

test_check_cmd_injection_finds_unsafe_patterns() {
    local fixture_path="$REPO_ROOT/scripts/reliability/fixtures/security"
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_cmd_injection '$fixture_path' true
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_cmd_injection should fail on fixture with unsafe Command::new usage"
    assert_contains "$output" "SECURITY_CMD_INJECTION_FOUND" "output should contain SECURITY_CMD_INJECTION_FOUND"
}

test_check_cmd_injection_clean_repo() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_cmd_injection '$REPO_ROOT/infra/api/src'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_cmd_injection should pass on infra/api/src"
    assert_contains "$output" "SECURITY_CMD_CLEAN" "output should contain SECURITY_CMD_CLEAN"
}

test_check_cmd_injection_allows_raw_string_literals() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    cat > "$tmpdir/raw_literal.rs" <<'RS'
use std::process::Command;

fn main() {
    Command::new(r##"echo"##);
}
RS

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_cmd_injection '$tmpdir' true
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "0" "check_cmd_injection should allow raw string literal command names"
    assert_contains "$output" "SECURITY_CMD_CLEAN" "raw string literal command names should report SECURITY_CMD_CLEAN"
}

test_check_sql_guard_finds_unsafe_patterns() {
    local fixture_path="$REPO_ROOT/scripts/reliability/fixtures/security"
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_sql_guard '$fixture_path' true
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_sql_guard should fail on fixture with unsafe SQL"
    assert_contains "$output" "SECURITY_SQL_UNSAFE" "output should contain SECURITY_SQL_UNSAFE"
}

test_check_sql_guard_clean_repo() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_sql_guard '$REPO_ROOT/infra/api/src'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_sql_guard should pass on clean Rust source paths"
    assert_contains "$output" "SECURITY_SQL_CLEAN" "output should contain SECURITY_SQL_CLEAN"
}

test_check_sql_guard_full_infra_repo_clean() {
    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_sql_guard '$REPO_ROOT/infra'
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_sql_guard should pass on full infra tree (test fixtures must not trigger prod guard)"
    assert_contains "$output" "SECURITY_SQL_CLEAN" "full infra scan should report SECURITY_SQL_CLEAN"
}

test_include_fixtures_flag_rejects_shell_payloads() {
    local tmp_marker
    tmp_marker="$(mktemp)"
    rm -f "$tmp_marker"

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$REPO_ROOT/scripts/reliability/lib' 'false; touch $tmp_marker'
    " 2>&1)" || exit_code=$?

    local marker_exists="no"
    if [ -e "$tmp_marker" ]; then
        marker_exists="yes"
    fi
    rm -f "$tmp_marker"

    assert_eq "${exit_code:-0}" "2" "invalid include_fixtures values should be rejected"
    assert_contains "$output" "SECURITY_CHECK_ERROR" "invalid include_fixtures values should report SECURITY_CHECK_ERROR"
    assert_eq "$marker_exists" "no" "invalid include_fixtures values must not execute shell payloads"
}

test_check_dep_audit_skip_when_tool_missing() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "0" "check_dep_audit should pass (skip) when cargo-audit missing"
    assert_contains "$output" "SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING" "output should contain SKIP_TOOL_MISSING"
}

test_check_dep_audit_mock_fail() {
    local output exit_code=0
    output="$(with_mock_cargo_audit fail "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "check_dep_audit should fail when mock returns vulnerabilities"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" "output should contain SECURITY_DEP_AUDIT_FAIL"
}

test_check_dep_audit_mock_advisory_only_warns() {
    local output exit_code=0
    output="$(with_mock_cargo_audit advisory "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "check_dep_audit should pass with advisory-only findings"
    assert_contains "$output" "SECURITY_DEP_AUDIT_WARN" "output should contain SECURITY_DEP_AUDIT_WARN"
}

test_check_dep_audit_mock_advisory_with_stderr_warns() {
    local output exit_code=0
    output="$(with_mock_cargo_audit advisory_with_stderr "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "check_dep_audit should pass when advisory JSON is on stdout and logs are on stderr"
    assert_contains "$output" "SECURITY_DEP_AUDIT_WARN" "output should contain SECURITY_DEP_AUDIT_WARN when stderr logs are present"
}

test_check_dep_audit_mock_critical_fails() {
    local output exit_code=0
    output="$(with_mock_cargo_audit critical "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "check_dep_audit should fail when mock returns critical/high vulnerabilities"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" "output should contain SECURITY_DEP_AUDIT_FAIL for critical/high severity"
}

test_check_dep_audit_mock_pass() {
    local output exit_code=0
    output="$(with_mock_cargo_audit pass "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "check_dep_audit should pass when no vulnerabilities"
    assert_contains "$output" "SECURITY_DEP_AUDIT_PASS" "output should contain SECURITY_DEP_AUDIT_PASS"
}

json_field() {
    local json="$1" field="$2"
    python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(json.dumps(d['$field']))" <<< "$json"
}

# Build a PATH that excludes any directory containing cargo-audit,
# so command -v cargo-audit fails even if the tool is installed.
_path_without_cargo_audit() {
    local safe_path=""
    local IFS=':'
    for dir in $PATH; do
        if [ ! -x "$dir/cargo-audit" ]; then
            safe_path="${safe_path:+$safe_path:}$dir"
        fi
    done
    echo "$safe_path"
}

test_run_security_suite_produces_valid_json() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout exit_code
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    # Validate JSON is parseable
    local valid
    valid="$(echo "$stdout" | python3 -m json.tool >/dev/null 2>&1 && echo "yes" || echo "no")"
    assert_eq "$valid" "yes" "run_security_suite should produce valid JSON"

    # Validate structure
    local checks_run passed
    checks_run="$(json_field "$stdout" checks_run)"
    passed="$(json_field "$stdout" passed)"

    # With cargo-audit missing: 3 checks run (secret_scan, sql_guard, cmd_injection pass), 1 skipped (dep_audit)
    assert_eq "$checks_run" "3" "checks_run should be 3 (secret_scan + sql_guard + cmd_injection)"
    assert_eq "$passed" "true" "passed should be true when skips do not prevent success"
}

test_run_security_suite_check_results_has_all_entries() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || true

    local result_count
    result_count="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(len(d.get('check_results', [])))
" <<< "$stdout")"

    assert_eq "$result_count" "4" "check_results should have 4 entries (secret_scan + dep_audit + sql_guard + cmd_injection)"
}

test_run_security_suite_reports_sql_guard_clean_for_repo() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || true

    local sql_status sql_reason
    sql_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_sql_guard':
        print(r.get('status', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    sql_reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_sql_guard':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"

    assert_eq "$sql_status" "pass" "run_security_suite should report passing sql_guard on real repo paths"
    assert_eq "$sql_reason" "SECURITY_SQL_CLEAN" "run_security_suite should report SECURITY_SQL_CLEAN for sql_guard"
}

test_run_security_suite_includes_cmd_injection() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || true

    local has_cmd_injection check_results_count
    has_cmd_injection="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(any(item.get('name') == 'check_cmd_injection' for item in d.get('check_results', [])))
" <<< "$stdout")"
    check_results_count="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(len(d.get('check_results', [])))
" <<< "$stdout")"

    assert_eq "$has_cmd_injection" "True" "run_security_suite should include check_cmd_injection"
    assert_eq "$check_results_count" "4" "run_security_suite should run 4 security checks"
}

test_run_security_suite_records_error_class_semantics() {
    local stdout exit_code=0
    stdout="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan() { echo 'REASON: SECURITY_SECRET_CLEAN' >&2; return 0; }
        check_dep_audit() { echo 'REASON: SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING' >&2; return 0; }
        check_sql_guard() { echo 'REASON: SECURITY_SQL_UNSAFE' >&2; return 1; }
        check_cmd_injection() { echo 'REASON: SECURITY_CMD_CLEAN' >&2; return 0; }
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    local dep_error_class sql_error_class secret_error_class cmd_error_class has_error_class has_details
    dep_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_dep_audit':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"
    sql_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_sql_guard':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"
    secret_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_secret_scan':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"
    cmd_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_cmd_injection':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"
    has_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(any('error_class' in item for item in d.get('check_results', [])))
" <<< "$stdout")"
    has_details="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(any('details' in item for item in d.get('check_results', [])))
" <<< "$stdout")"

    assert_eq "$exit_code" "1" "run_security_suite should fail when a check fails"
    assert_eq "$secret_error_class" "" "pass checks should emit empty error_class"
    assert_eq "$dep_error_class" "precondition" "skip due missing tool should map to error_class=precondition"
    assert_eq "$sql_error_class" "runtime" "runtime failures should map to error_class=runtime"
    assert_eq "$cmd_error_class" "" "pass checks should emit empty error_class"
    assert_eq "$has_error_class" "True" "check_results should include error_class for applicable checks"
    assert_eq "$has_details" "False" "run_security_suite should not emit legacy details field"
}

test_run_security_suite_maps_unexpected_exit_to_check_error() {
    local stdout exit_code=0
    stdout="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan() { echo 'unexpected non-standard failure' >&2; return 2; }
        check_dep_audit() { echo 'REASON: SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING' >&2; return 0; }
        check_sql_guard() { echo 'REASON: SECURITY_SQL_CLEAN' >&2; return 0; }
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    local secret_status secret_reason
    secret_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_secret_scan':
        print(r.get('status', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    secret_reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_secret_scan':
        print(r.get('reason', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"

    assert_eq "$exit_code" "1" "run_security_suite should fail when a check exits with unexpected non-zero code"
    assert_eq "$secret_status" "fail" "unexpected check exit should map to fail status"
    assert_eq "$secret_reason" "SECURITY_CHECK_ERROR" "unexpected check exit should map to SECURITY_CHECK_ERROR"
}

test_run_security_suite_all_pass_when_dep_audit_present() {
    local stdout exit_code=0
    stdout="$(with_mock_cargo_audit pass "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    local passed checks_run checks_skipped checks_failed
    passed="$(json_field "$stdout" passed)"
    checks_run="$(json_field "$stdout" checks_run)"
    checks_skipped="$(json_field "$stdout" checks_skipped)"
    checks_failed="$(json_field "$stdout" checks_failed)"

    assert_eq "$exit_code" "0" "run_security_suite should exit 0 when all checks pass"
    assert_eq "$passed" "true" "passed should be true when all checks pass"
    assert_eq "$checks_run" "4" "checks_run should be 4 (secret_scan + dep_audit + sql_guard + cmd_injection)"
    assert_eq "$checks_skipped" "0" "checks_skipped should be 0 when dep_audit is present"
    assert_eq "$checks_failed" "0" "checks_failed should be 0 when all pass"
}

echo "=== security_checks.sh tests ==="
echo ""
echo "--- check_secret_scan tests ---"
test_check_secret_scan_finds_fake_aws_key
test_check_secret_scan_finds_stripe_key
test_check_secret_scan_finds_fj_prefix_secret
test_check_secret_scan_clean_repo
test_check_secret_scan_excludes_secret_dir
test_check_secret_scan_ignores_metrics_local_dev_placeholder
test_check_secret_scan_ignores_env_local_example_placeholder
test_check_secret_scan_ignores_fj_inside_identifier_chain
test_check_secret_scan_still_finds_word_boundary_fj_secret
test_check_secret_scan_does_not_exclude_arbitrary_fixtures_dirs
echo ""
echo "--- check_cmd_injection tests ---"
test_check_cmd_injection_finds_unsafe_patterns
test_check_cmd_injection_clean_repo
test_check_cmd_injection_allows_raw_string_literals
echo ""
echo "--- check_sql_guard tests ---"
test_check_sql_guard_finds_unsafe_patterns
test_check_sql_guard_clean_repo
test_check_sql_guard_full_infra_repo_clean
test_include_fixtures_flag_rejects_shell_payloads
echo ""
echo "--- check_dep_audit tests ---"
test_check_dep_audit_skip_when_tool_missing
test_check_dep_audit_mock_advisory_only_warns
test_check_dep_audit_mock_advisory_with_stderr_warns
test_check_dep_audit_mock_critical_fails
test_check_dep_audit_mock_fail
test_check_dep_audit_mock_pass
echo ""
echo "--- run_security_suite tests ---"
test_run_security_suite_produces_valid_json
test_run_security_suite_check_results_has_all_entries
test_run_security_suite_reports_sql_guard_clean_for_repo
test_run_security_suite_includes_cmd_injection
test_run_security_suite_records_error_class_semantics
test_run_security_suite_maps_unexpected_exit_to_check_error
test_run_security_suite_all_pass_when_dep_audit_present
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
