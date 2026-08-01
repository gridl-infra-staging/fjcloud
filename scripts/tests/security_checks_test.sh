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
        # The four modes below reproduce the REAL cargo-audit JSON advisory
        # shape: no `severity` key at all, severity carried only by a `cvss`
        # vector string (verified against cargo-audit output 2026-07-30). The
        # `severity`-bearing modes above are a legacy/mock shape; only these
        # exercise the path the production classifier actually takes.
        cvss_critical)
            # AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H — base score 9.8 (critical).
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9001","package":"mockcrate","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H","withdrawn":null}}]}}
JSON
exit 1
MOCK
            ;;
        cvss_high)
            # AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H — base score 7.5 (high).
            # This is the exact vector carried by the live quick-xml and
            # quinn-proto advisories in infra/Cargo.lock.
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9002","package":"mockcrate","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H","withdrawn":null}}]}}
JSON
exit 1
MOCK
            ;;
        cvss_medium)
            # AV:N/AC:L/PR:N/UI:R/S:U/C:N/I:N/A:L — base score 4.3 (medium),
            # i.e. just below the high band. Pins the 7.0 boundary from below.
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9003","package":"mockcrate","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:N/I:N/A:L","withdrawn":null}}]}}
JSON
exit 1
MOCK
            ;;
        cvss_absent)
            # A real vulnerability with neither severity nor CVSS — the shape
            # of the live crossbeam-epoch and rustls-webpki advisories.
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9004","package":"mockcrate","cvss":null,"withdrawn":null}}]}}
JSON
exit 1
MOCK
            ;;
        withdrawn)
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9005","package":"mockcrate","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H","withdrawn":"2026-01-01"}}]}}
JSON
exit 1
MOCK
            ;;
        cvss_unknown_severity)
            # An UNRECOGNIZED severity label ("unknown") beside a scorable 9.8
            # critical vector. A declared label off the CVSS qualitative scale
            # must not short-circuit to warn — the vector still rates critical.
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9006","package":"mockcrate","severity":"unknown","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H","withdrawn":null}}]}}
JSON
exit 1
MOCK
            ;;
        cvss_none_severity_critical_vector)
            # A declared "none" severity beside a scorable 9.8 critical vector.
            # More information (a low label AND a critical vector) must never be
            # treated more leniently than less — take the more severe of the two.
            cat > "$mock_dir/cargo-audit" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"vulnerabilities":{"count":1,"list":[{"advisory":{"id":"RUSTSEC-2026-9007","package":"mockcrate","severity":"none","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H","withdrawn":null}}]}}
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

# Relocated from the deleted scripts/tests/security_checks_lib_test.sh, which
# was the only test file that exercised the git-index branch of
# check_secret_scan (_git_tracked_secret_matches). Every other
# check_secret_scan case above scans a NON-git tmpdir and therefore only
# reaches the `grep -r` branch, so without this case the tracked-file scan —
# the branch that actually runs in production — has no coverage.
# Asserts the survivor's contract (exit 1 + REASON on stderr), not the deleted
# library's JSON-on-stdout shape.
test_check_secret_scan_finds_tracked_markdown_secret() {
    local tmpdir
    # pwd -P: git reports the physical path for the toplevel, so a /var ->
    # /private/var symlinked mktemp dir would not match and the pathspec the
    # helper builds would fall outside the repo.
    tmpdir="$(cd "$(mktemp -d)" && pwd -P)"
    (
        cd "$tmpdir"
        git init -q
        git config user.email "security-test@example.com"
        git config user.name "Security Test"
        mkdir -p docs
        printf 'Leaked key: AKIA%s\n' '1234567890ABCDEF' > docs/leaked-key.md
        git add docs/leaked-key.md
    )

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "1" \
        "check_secret_scan should fail when tracked markdown contains a key"
    assert_contains "$output" "SECURITY_SECRET_FOUND" \
        "tracked-markdown secret should trigger SECURITY_SECRET_FOUND"
    assert_contains "$output" "docs/leaked-key.md" \
        "tracked-markdown finding should name the offending file"
}

test_check_secret_scan_finds_tracked_webhook_secret() {
    local tmpdir
    tmpdir="$(cd "$(mktemp -d)" && pwd -P)"
    (
        cd "$tmpdir"
        git init -q
        git config user.email "security-test@example.com"
        git config user.name "Security Test"
        mkdir -p docs
        printf 'Leaked webhook secret: whsec_1234567890ABCDEFGHIJKLMN\n' > docs/leaked-webhook.md
        git add docs/leaked-webhook.md
    )

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "1" \
        "check_secret_scan should fail when tracked markdown contains a webhook secret"
    assert_contains "$output" "SECURITY_SECRET_FOUND" \
        "tracked webhook secret should trigger SECURITY_SECRET_FOUND"
    assert_contains "$output" "docs/leaked-webhook.md" \
        "tracked webhook secret should name the offending file"
}

test_check_secret_scan_finds_tracked_restricted_key() {
    local tmpdir
    tmpdir="$(cd "$(mktemp -d)" && pwd -P)"
    (
        cd "$tmpdir"
        git init -q
        git config user.email "security-test@example.com"
        git config user.name "Security Test"
        mkdir -p docs
        # Prefix and body are held apart on purpose. A contiguous `rk_test_<24+ chars>`
        # literal in a tracked file trips GitHub push protection on the public mirrors:
        # it rejected every `debbie sync staging` push and left fjcloud mirror parity 406
        # commits behind on 2026-08-01. Neither half matches SECURITY_SECRET_PATTERN
        # (`scripts/reliability/lib/security_checks.sh:95`) alone; the string written into
        # the throwaway repo below is still a full pattern-matching key, so
        # check_secret_scan must still find it. Only the source spelling changed.
        local fake_key_prefix='rk_test_'
        local fake_key_body='1234567890ABCDEFGHIJKLMN'
        printf 'Leaked restricted key: %s%s\n' "$fake_key_prefix" "$fake_key_body" \
            > docs/leaked-restricted-key.md
        git add docs/leaked-restricted-key.md
    )

    local output exit_code
    output="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan '$tmpdir'
    " 2>&1)" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "${exit_code:-0}" "1" \
        "check_secret_scan should fail when tracked markdown contains a restricted Stripe key"
    assert_contains "$output" "SECURITY_SECRET_FOUND" \
        "tracked restricted key should trigger SECURITY_SECRET_FOUND"
    assert_contains "$output" "docs/leaked-restricted-key.md" \
        "tracked restricted key should name the offending file"
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

# Missing cargo-audit FAILS the check; it is not a pass.
# The previous assertion here was `assert_eq ... "0"` — it asserted that an
# audit which never ran reports success, i.e. a guard that could not fail.
# Do not "restore" it. The SKIP_TOOL_MISSING reason code is still asserted
# below, because "install the tool" must stay distinguishable from
# "you have a live CVE"; only the exit status changed.
test_check_dep_audit_fails_closed_when_tool_missing() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local output exit_code

    output="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "${exit_code:-0}" "1" "check_dep_audit should fail closed when missing cargo-audit is an actionable guard failure"
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
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL_ADVISORIES" \
        "critical/high advisory failures should carry the advisory-specific fail reason"
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

# Known-answer tests for the CVSS-vector severity classifier.
#
# Real cargo-audit JSON has NO `severity` key — severity is only derivable from
# the `cvss` vector string. Before this coverage existed the classifier read
# `advisory.severity`, found nothing, and downgraded EVERY real advisory to
# warn, so check_dep_audit could not fail on a live CVE. The mock-`severity`
# tests above passed throughout, because their fixture was not the shape
# cargo-audit actually emits. Expected scores below are hand-computed from the
# CVSS v3.1 base-score formula.
test_check_dep_audit_cvss_critical_vector_fails() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_critical "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "CVSS 9.8 vector with no severity key should fail the check"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" "critical CVSS vector should report SECURITY_DEP_AUDIT_FAIL"
    assert_contains "$output" "RUSTSEC-2026-9001(critical)" \
        "failure output should name the blocking advisory and its derived band"
}

test_check_dep_audit_cvss_high_vector_fails() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_high "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "CVSS 7.5 vector with no severity key should fail the check"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" "high CVSS vector should report SECURITY_DEP_AUDIT_FAIL"
    assert_contains "$output" "RUSTSEC-2026-9002(high)" \
        "failure output should name the blocking advisory and its derived band"
}

test_check_dep_audit_cvss_medium_vector_warns() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_medium "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "CVSS 4.3 vector sits below the high band and should only warn"
    assert_contains "$output" "SECURITY_DEP_AUDIT_WARN" "medium CVSS vector should report SECURITY_DEP_AUDIT_WARN"
    assert_not_contains "$output" "Blocking advisories" \
        "a medium advisory must not be listed as blocking"
}

test_check_dep_audit_unrated_vulnerability_fails_closed() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_absent "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" \
        "a vulnerability with neither severity nor CVSS has unknown severity and must fail closed"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" "unrated advisory should report SECURITY_DEP_AUDIT_FAIL"
    assert_contains "$output" "RUSTSEC-2026-9004(unrated)" \
        "failure output should mark the advisory as unrated rather than silently downgrading it"
}

test_check_dep_audit_withdrawn_advisory_is_ignored() {
    local output exit_code=0
    output="$(with_mock_cargo_audit withdrawn "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "a withdrawn advisory should not fail the check"
    assert_contains "$output" "SECURITY_DEP_AUDIT_PASS" "withdrawn-only output should report SECURITY_DEP_AUDIT_PASS"
}

# An unrecognized declared severity string must not short-circuit the CVSS
# derivation. Before the fix, any non-empty severity outside {critical,high}
# skipped the vector entirely and fell through to warn, so an advisory with
# MORE information (a label plus a scorable critical vector) was treated more
# leniently than one with none. The classifier now takes the more severe of
# the declared and CVSS-derived bands.
test_check_dep_audit_unknown_severity_with_critical_vector_fails() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_unknown_severity "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" \
        "an unrecognized severity label beside a 9.8 CVSS vector must fail closed on the vector"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" \
        "unknown-severity + critical-vector advisory should report SECURITY_DEP_AUDIT_FAIL"
    assert_contains "$output" "RUSTSEC-2026-9006(critical)" \
        "the vector-derived critical band should drive classification, not the unknown label"
}

# A declared low/none severity must never mask a scorable critical vector.
test_check_dep_audit_none_severity_with_critical_vector_fails() {
    local output exit_code=0
    output="$(with_mock_cargo_audit cvss_none_severity_critical_vector "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_dep_audit
    " 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" \
        "a declared 'none' severity beside a 9.8 CVSS vector must fail closed on the vector"
    assert_contains "$output" "SECURITY_DEP_AUDIT_FAIL" \
        "none-severity + critical-vector advisory should report SECURITY_DEP_AUDIT_FAIL"
    assert_contains "$output" "RUSTSEC-2026-9007(critical)" \
        "the vector-derived critical band should override the declared 'none' label"
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

    local stdout exit_code=0
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

    # With cargo-audit missing: dependency audit must be a failed guard, not a suite pass.
    assert_eq "$exit_code" "1" "run_security_suite should fail closed when dependency audit tooling is missing"
    assert_eq "$checks_run" "3" "checks_run should be 3 (secret_scan + sql_guard + cmd_injection)"
    assert_eq "$passed" "false" "passed should be false when dependency audit tooling is missing"
}

test_run_security_suite_cli_streams_json_stdout() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout exit_code=0
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" \
        bash "$REPO_ROOT/scripts/reliability/run_security_suite.sh" 2>/dev/null)" || exit_code=$?

    local valid
    valid="$(printf '%s' "$stdout" | python3 -m json.tool >/dev/null 2>&1 && echo "yes" || echo "no")"
    assert_eq "$valid" "yes" "security-suite CLI stdout should be one parseable JSON document"
    assert_eq "$exit_code" "1" "security-suite CLI should preserve the fail-closed suite exit status"

    local passed missing_tool_reason
    passed="$(json_field "$stdout" passed)"
    missing_tool_reason="$(python3 -c "
import json, sys
data = json.load(sys.stdin)
print(any(
    result.get('name') == 'check_dep_audit'
    and result.get('reason') == 'SECURITY_DEP_AUDIT_SKIP_TOOL_MISSING'
    for result in data.get('check_results', [])
))
" <<< "$stdout")"
    assert_eq "$passed" "false" "security-suite CLI JSON should preserve the failed suite verdict"
    assert_eq "$missing_tool_reason" "True" "security-suite CLI JSON should preserve the missing-tool reason"
}

test_tracked_security_checks_has_single_owner() {
    local tracked_paths tracked_count
    tracked_paths="$(git -C "$REPO_ROOT" ls-files '*/security_checks.sh')"
    tracked_count="$(printf '%s\n' "$tracked_paths" | sed '/^$/d' | wc -l | tr -d ' ')"

    assert_eq "$tracked_count" "1" "repo should track exactly one security_checks.sh owner"
}

test_local_ci_known_gates_include_security_gates() {
    local tmpdir
    tmpdir="$(mktemp -d)"

    bash "$REPO_ROOT/scripts/local-ci.sh" --gate __nope__ > "$tmpdir/known_gates.txt" 2>&1 || true

    local output
    output="$(cat "$tmpdir/known_gates.txt")"
    rm -rf "$tmpdir"

    assert_contains "$output" "Known gates:" "unknown-gate probe should print the known gate roster"
    assert_contains "$output" "dep-audit" "local-ci known gate roster should include dep-audit"
    assert_contains "$output" "web-audit" "local-ci known gate roster should include web-audit"
    assert_contains "$output" "security-suite" "local-ci known gate roster should include security-suite"
}

# local-ci.sh prints the gate roster from two separate literals (the
# --summary-only banner and the unknown-gate error path). The behavioural probe
# above only exercises the second one, so pin the first by source inspection —
# otherwise dep-audit could silently drop out of `--summary-only`. Mirrors the
# per-gate roster guards in scripts/tests/probe_test_reachability_test.sh:382.
test_local_ci_security_gate_rosters_and_execution_root() {
    local local_ci="$REPO_ROOT/scripts/local-ci.sh"

    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc 'dep-audit' || true)" \
        "1" \
        "local-ci summary-only roster names dep-audit exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc 'dep-audit' || true)" \
        "1" \
        "local-ci unknown-gate roster names dep-audit exactly once"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc 'web-audit' || true)" \
        "1" \
        "local-ci summary-only roster names web-audit exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc 'web-audit' || true)" \
        "1" \
        "local-ci unknown-gate roster names web-audit exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_web_audit() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines exactly one web-audit execution root"
    assert_eq \
        "$(grep -Fc 'web-audit)       run_gate web-audit       gate_web_audit ;;' "$local_ci" || true)" \
        "1" \
        "web-audit has exactly one dispatch arm"
    assert_eq \
        "$(grep -Fxc 'schedule dep-audit' "$local_ci" || true)" \
        "1" \
        "dep-audit is scheduled by the default gate block"
    assert_eq \
        "$(grep -Fc 'if [ "$SINGLE_GATE" = "dep-audit" ]; then' "$local_ci" || true)" \
        "0" \
        "dep-audit is not isolated behind a single-gate opt-in block"
    assert_eq \
        "$(grep -F "    printf 'Known gates:" "$local_ci" | grep -Fc 'security-suite' || true)" \
        "1" \
        "local-ci summary-only roster names security-suite exactly once"
    assert_eq \
        "$(grep -F '        echo "Known gates:' "$local_ci" | grep -Fc 'security-suite' || true)" \
        "1" \
        "local-ci unknown-gate roster names security-suite exactly once"
    assert_eq \
        "$(grep -Fxc 'gate_security_suite() {' "$local_ci" || true)" \
        "1" \
        "local-ci defines exactly one security-suite execution root"
    assert_eq \
        "$(grep -Fc '    bash "$REPO_ROOT/scripts/reliability/run_security_suite.sh"' "$local_ci" || true)" \
        "1" \
        "local-ci security-suite gate delegates to the raw JSON CLI"
    assert_eq \
        "$(grep -Fc 'if [ "$SINGLE_GATE" = "security-suite" ]; then' "$local_ci" || true)" \
        "1" \
        "security-suite is explicitly opt-in"
    assert_eq \
        "$(grep -Fc 'security-suite)  run_gate security-suite  gate_security_suite ;;' "$local_ci" || true)" \
        "1" \
        "security-suite has a dispatch arm"
}

# The tracked fixture pins lodash@4.17.20, affected by GHSA-35jh-r3h4-6jhm.
# npm's live advisory response is validated separately; this contract keeps the
# local-ci dispatch and fixture-root behavior hermetic.
test_local_ci_web_audit_uses_fixture_root_and_preserves_failure() {
    local tmpdir fixture_root
    tmpdir="$(mktemp -d)"
    fixture_root="$REPO_ROOT/scripts/reliability/fixtures/security/web_audit_vulnerable"

    cat > "$tmpdir/npm" <<'MOCK'
#!/usr/bin/env bash
if [ "$PWD" != "$EXPECTED_WEB_AUDIT_ROOT" ]; then
    echo "fake npm: wrong working directory: $PWD" >&2
    exit 91
fi
if [ "$#" -ne 3 ] \
    || [ "$1" != "audit" ] \
    || [ "$2" != "--audit-level=high" ] \
    || [ "$3" != "--package-lock-only" ]; then
    echo "fake npm: wrong arguments: $*" >&2
    exit 92
fi
echo "lodash command injection advisory GHSA-35jh-r3h4-6jhm"
exit 1
MOCK
    chmod +x "$tmpdir/npm"

    local output exit_code=0
    output="$(
        EXPECTED_WEB_AUDIT_ROOT="$fixture_root" \
        FJCLOUD_WEB_AUDIT_ROOT="$fixture_root" \
        PATH="$tmpdir:$PATH" \
        bash "$REPO_ROOT/scripts/local-ci.sh" --gate web-audit 2>&1
    )" || exit_code=$?

    rm -rf "$tmpdir"

    assert_eq "$exit_code" "1" "web-audit should preserve npm advisory failure status"
    assert_contains "$output" "lodash command injection advisory GHSA-35jh-r3h4-6jhm" \
        "web-audit should preserve npm advisory output"
    assert_contains "$output" "web-audit" "web-audit failure should be named in local-ci output"
    assert_contains "$output" "FAIL" "web-audit advisory should be reported as a failed gate"
    assert_not_contains "$output" "did not match any known gate" \
        "web-audit should be registered as a known local-ci gate"
    assert_not_contains "$output" "package.json" \
        "tracked web-audit fixture should satisfy the manifest precondition"
    assert_not_contains "$output" "package-lock.json" \
        "tracked web-audit fixture should satisfy the lockfile precondition"
    assert_not_contains "$output" "node_modules" \
        "web-audit should not require installed node_modules"
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

test_run_security_suite_preserves_advisory_failure_reason() {
    local stdout exit_code=0
    stdout="$(BACKEND_LIVE_GATE=1 bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        check_secret_scan() { echo 'REASON: SECURITY_SECRET_CLEAN' >&2; return 0; }
        check_dep_audit() { echo 'REASON: SECURITY_DEP_AUDIT_FAIL_ADVISORIES' >&2; return 1; }
        check_sql_guard() { echo 'REASON: SECURITY_SQL_CLEAN' >&2; return 0; }
        check_cmd_injection() { echo 'REASON: SECURITY_CMD_CLEAN' >&2; return 0; }
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    local dep_reason dep_error_class
    dep_reason="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_dep_audit':
        print(r.get('reason', ''))
        break
" <<< "$stdout")"
    dep_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_dep_audit':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"

    assert_eq "$exit_code" "1" "run_security_suite should fail when dependency audit finds blocking advisories"
    assert_eq "$dep_reason" "SECURITY_DEP_AUDIT_FAIL_ADVISORIES" \
        "run_security_suite JSON should identify live advisory failures distinctly from parse failures"
    assert_eq "$dep_error_class" "runtime" "advisory failures should remain runtime failures"
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

# A blocking skip (cargo-audit absent) must be reported with status="fail", not
# status="skipped". The suite's status vocabulary is aligned to
# live-backend-gate.sh, where "skipped" is a NON-failing outcome; labelling a
# suite-failing check "skipped" would read as non-failing to any consumer that
# keys on status. error_class="precondition" carries the "never ran" fact, and
# the retired `blocking` JSON key must not reappear.
test_run_security_suite_blocking_skip_reports_fail_status() {
    local safe_path
    safe_path="$(_path_without_cargo_audit)"

    local stdout exit_code=0
    stdout="$(BACKEND_LIVE_GATE=1 PATH="$safe_path" bash -c "
        source '$REPO_ROOT/scripts/reliability/lib/security_checks.sh'
        run_security_suite
    " 2>/dev/null)" || exit_code=$?

    local dep_status dep_error_class any_blocking checks_blocked checks_skipped checks_failed
    dep_status="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_dep_audit':
        print(r.get('status', 'MISSING'))
        break
else:
    print('NOT_FOUND')
" <<< "$stdout")"
    dep_error_class="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
for r in d.get('check_results', []):
    if r.get('name') == 'check_dep_audit':
        print(r.get('error_class', ''))
        break
" <<< "$stdout")"
    any_blocking="$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(any('blocking' in item for item in d.get('check_results', [])))
" <<< "$stdout")"
    checks_skipped="$(json_field "$stdout" checks_skipped)"
    checks_blocked="$(json_field "$stdout" checks_blocked)"
    checks_failed="$(json_field "$stdout" checks_failed)"

    assert_eq "$exit_code" "1" "blocking skip should fail the suite"
    assert_eq "$dep_status" "fail" "blocking skip (tool absent) should report status=fail, not skipped"
    assert_eq "$dep_error_class" "precondition" "blocking skip should carry error_class=precondition"
    assert_eq "$any_blocking" "False" "retired 'blocking' JSON key must not reappear"
    assert_eq "$checks_blocked" "1" "a blocking precondition failure has its own counter"
    assert_eq "$checks_skipped" "0" "a failing precondition is not a non-failing skip"
    assert_eq "$checks_failed" "1" "the blocking skip is the single failure"
}

# Direct known-answer coverage for the extracted TSV/JSON counter owner. This
# pins exact values so the shell exit code and JSON verdict cannot drift.
test_security_suite_summary_script_known_answers() {
    local script="$REPO_ROOT/scripts/lib/security_suite_summary.py"
    local tmp stdout exit_code=0
    tmp="$(mktemp)"
    printf '%s\n' \
        $'pass_check\tpass\t10\tSECURITY_PASS\t' \
        $'blocked_check\tfail\t20\tSECURITY_TOOL_MISSING\tprecondition' \
        $'runtime_check\tfail\t30\tSECURITY_RUNTIME\truntime' \
        $'skip_check\tskipped\t40\tSECURITY_OPTIONAL_SKIP\tprecondition' > "$tmp"

    stdout="$(python3 "$script" "$tmp" 100)" || exit_code=$?

    assert_eq "$exit_code" "1" "security suite summary exits non-zero when any check failed"
    assert_eq "$(json_field "$stdout" checks_run)" "2" "summary counts pass and runtime failure as run"
    assert_eq "$(json_field "$stdout" checks_failed)" "2" "summary counts both failed checks"
    assert_eq "$(json_field "$stdout" checks_blocked)" "1" "summary counts failed preconditions separately"
    assert_eq "$(json_field "$stdout" checks_skipped)" "1" "summary counts only non-failing skips as skipped"
    assert_eq "$(json_field "$stdout" elapsed_ms)" "100" "summary preserves suite elapsed time"
    assert_eq "$(json_field "$stdout" passed)" "false" "summary verdict is false on failures"
    assert_eq "$(json_field "$stdout" failures)" '["blocked_check", "runtime_check"]' \
        "summary names failures in source order"
    rm -f "$tmp"
}

# Direct unit coverage for the extracted CVSS classifier
# (scripts/lib/cvss_severity.py). The mock-based check_dep_audit tests above
# exercise it end to end; these pin the script's own contract at the seam so a
# regression is attributable without going through the shell wrapper.
test_cvss_severity_script_known_answers() {
    local script="$REPO_ROOT/scripts/lib/cvss_severity.py"
    local tmp
    tmp="$(mktemp)"

    local out err_out ec

    # 9.8 critical vector, no severity key -> fail + named blocking band.
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-A","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    err_out="$(python3 "$script" "$tmp" 2>&1 >/dev/null)"
    assert_eq "$out" "fail" "9.8 critical vector should classify as fail"
    assert_contains "$err_out" "RUSTSEC-A(critical)" "critical vector should name the blocking band"

    # 7.5 high vector -> fail.
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-B","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:N/I:N/A:H"}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "fail" "7.5 high vector should classify as fail"

    # 4.3 medium vector -> warn (below the high band).
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-C","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:U/C:N/I:N/A:L"}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "warn" "4.3 medium vector should classify as warn"

    # Neither severity nor CVSS -> unrated, fail closed.
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-D","cvss":null}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "fail" "an unrated vulnerability should fail closed, not warn"

    # An invalid scope must not be treated as scope-unchanged and downgraded.
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-SCOPE","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:R/S:X/C:N/I:N/A:L"}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "fail" "an invalid CVSS scope should fail closed as unrated"

    # Withdrawn advisory -> ignored, clean pass.
    printf '%s' '{"vulnerabilities":{"list":[{"advisory":{"id":"RUSTSEC-E","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H","withdrawn":"2026-01-01"}}]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "pass" "a withdrawn advisory should be ignored"

    # No vulnerabilities -> pass.
    printf '%s' '{"vulnerabilities":{"list":[]}}' > "$tmp"
    out="$(python3 "$script" "$tmp" 2>/dev/null)"
    assert_eq "$out" "pass" "an empty advisory list should pass"

    # Unparsable report -> exit 2 so the caller fails closed.
    printf '%s' 'not json at all' > "$tmp"
    ec=0
    python3 "$script" "$tmp" >/dev/null 2>&1 || ec=$?
    assert_eq "$ec" "2" "an unparsable report should exit 2 (caller fails closed)"

    # Invalid UTF-8 must not be discarded into an apparently valid report.
    python3 - "$tmp" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(
    b'{"vulnerabilities":{"found":false,"count":0,"list":[]}}\xff'
)
PY
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "invalid UTF-8 audit evidence should exit 2, not be decoded lossily"
    assert_eq "$out" "parse_error" "invalid UTF-8 audit evidence should not yield a verdict"

    # --- schema-drift cross-checks -------------------------------------------
    # Real cargo audit emits vulnerabilities as {count, found, list}. Reading
    # `list` alone let a rename read as a clean report while count/found in the
    # SAME object said otherwise. Any disagreement must be a loud exit 2, not a
    # pass.

    # `list` renamed away, count/found still report 5 vulnerabilities.
    printf '%s' '{"vulnerabilities":{"found":true,"count":5,"advisories":[{"advisory":{"id":"RUSTSEC-F","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}}]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a renamed advisory list should exit 2, not pass"
    assert_eq "$out" "parse_error" "a renamed advisory list should not yield a verdict"

    # count disagrees with the list length.
    printf '%s' '{"vulnerabilities":{"count":5,"list":[{"advisory":{"id":"RUSTSEC-G","cvss":null}}]}}' > "$tmp"
    ec=0
    python3 "$script" "$tmp" >/dev/null 2>&1 || ec=$?
    assert_eq "$ec" "2" "count disagreeing with the list length should exit 2"

    # found=true with an empty list.
    printf '%s' '{"vulnerabilities":{"found":true,"list":[]}}' > "$tmp"
    ec=0
    python3 "$script" "$tmp" >/dev/null 2>&1 || ec=$?
    assert_eq "$ec" "2" "found=true with an empty list should exit 2"

    # The `vulnerabilities` object itself gone.
    printf '%s' '{"warnings":{}}' > "$tmp"
    ec=0
    python3 "$script" "$tmp" >/dev/null 2>&1 || ec=$?
    assert_eq "$ec" "2" "a report without a vulnerabilities object should exit 2"

    # Element/type drift must not bypass the cardinality cross-checks. A
    # non-object list entry was previously skipped by classify(), while
    # string-typed corroborators were silently ignored; both malformed reports
    # therefore produced a clean pass.
    printf '%s' '{"vulnerabilities":{"found":true,"count":1,"list":[null]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a non-object vulnerability entry should exit 2, not pass"
    assert_eq "$out" "parse_error" "a non-object vulnerability entry should not yield a verdict"

    printf '%s' '{"vulnerabilities":{"found":"true","count":"1","list":[]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "string-typed count/found fields should exit 2, not pass"
    assert_eq "$out" "parse_error" "string-typed count/found fields should not yield a verdict"

    printf '%s' '{"vulnerabilities":{"found":true,"count":1,"list":[{"advisory":{"id":"RUSTSEC-I","withdrawn":true}}]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a non-date withdrawn value should exit 2, not suppress an advisory"
    assert_eq "$out" "parse_error" "a malformed withdrawn value should not yield a verdict"

    printf '%s' '{"vulnerabilities":{"found":true,"count":1,"list":[{"advisory":{"id":"RUSTSEC-I","withdrawn":"not-a-date"}}]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "an invalid withdrawn date should exit 2, not suppress an advisory"
    assert_eq "$out" "parse_error" "an invalid withdrawn date should not yield a verdict"

    # The cross-check must not false-alarm on the real, self-consistent shape:
    # count/found agreeing with the list still classifies normally.
    printf '%s' '{"vulnerabilities":{"found":true,"count":1,"list":[{"advisory":{"id":"RUSTSEC-H","cvss":"CVSS:3.1/AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H"}}]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "0" "a self-consistent report should classify, not error"
    assert_eq "$out" "fail" "a self-consistent critical report should classify as fail"

    printf '%s' '{"vulnerabilities":{"found":false,"count":0,"list":[]}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "0" "a self-consistent clean report should classify, not error"
    assert_eq "$out" "pass" "a self-consistent clean report should pass"

    rm -f "$tmp"
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
test_check_secret_scan_finds_tracked_markdown_secret
test_check_secret_scan_finds_tracked_webhook_secret
test_check_secret_scan_finds_tracked_restricted_key
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
test_check_dep_audit_fails_closed_when_tool_missing
test_check_dep_audit_mock_advisory_only_warns
test_check_dep_audit_mock_advisory_with_stderr_warns
test_check_dep_audit_mock_critical_fails
test_check_dep_audit_mock_fail
test_check_dep_audit_mock_pass
test_check_dep_audit_cvss_critical_vector_fails
test_check_dep_audit_cvss_high_vector_fails
test_check_dep_audit_cvss_medium_vector_warns
test_check_dep_audit_unrated_vulnerability_fails_closed
test_check_dep_audit_withdrawn_advisory_is_ignored
test_check_dep_audit_unknown_severity_with_critical_vector_fails
test_check_dep_audit_none_severity_with_critical_vector_fails
echo ""
echo "--- run_security_suite tests ---"
test_run_security_suite_produces_valid_json
test_run_security_suite_cli_streams_json_stdout
test_run_security_suite_check_results_has_all_entries
test_run_security_suite_reports_sql_guard_clean_for_repo
test_run_security_suite_includes_cmd_injection
test_run_security_suite_records_error_class_semantics
test_run_security_suite_preserves_advisory_failure_reason
test_run_security_suite_maps_unexpected_exit_to_check_error
test_run_security_suite_all_pass_when_dep_audit_present
test_run_security_suite_blocking_skip_reports_fail_status
test_security_suite_summary_script_known_answers
test_cvss_severity_script_known_answers
echo ""
echo "--- consolidation contract tests ---"
test_tracked_security_checks_has_single_owner
test_local_ci_known_gates_include_security_gates
test_local_ci_security_gate_rosters_and_execution_root
test_local_ci_web_audit_uses_fixture_root_and_preserves_failure
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
