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

# --- web-audit named-advisory exception mechanism ---------------------------
# gate_web_audit now makes TWO npm invocations and delegates classification to
# scripts/lib/npm_audit_exceptions.py: a production-only reachability guard
# (--omit=dev, empty policy) that runs first, then the full-tree audit filtered
# through the committed web/npm_audit_exceptions.txt. These arms drive the real
# gate against the tracked fixture web root with a mocked npm that serves a
# caller-chosen JSON payload for each invocation.

# Real-shaped npm audit v2 payloads (severity + via[] objects/strings + a
# metadata cross-check block), matched to the live 2026-08-04 web/ shape.
WEB_AUDIT_CLEAN_PROD='{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'
# undici high with the five committed GHSA ids; miniflare/wrangler moderate
# string edges — the live dev-only shape the exception list is written for.
WEB_AUDIT_EXCEPTED_FULL='{"vulnerabilities":{"undici":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"},{"url":"https://github.com/advisories/GHSA-4cwx-7wf7-3272"},{"url":"https://github.com/advisories/GHSA-m8rv-5g2x-5cg5"},{"url":"https://github.com/advisories/GHSA-jr45-8vmc-qm54"},{"url":"https://github.com/advisories/GHSA-v3r7-h72x-cjcm"}]},"miniflare":{"severity":"moderate","via":["undici"]},"wrangler":{"severity":"moderate","via":["miniflare"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":2,"high":1,"critical":0,"total":3}}}'
# A high advisory whose GHSA is NOT on the exception list — must block.
WEB_AUDIT_UNLISTED_FULL='{"vulnerabilities":{"foo":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-zzzz-zzzz-zzzz"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}'
# A high entry whose via[] is only strings resolving to a package with no
# advisory id anywhere — no extractable GHSA, so it can never be excepted.
WEB_AUDIT_STRVIA_FULL='{"vulnerabilities":{"foo":{"severity":"high","via":["bar"]},"bar":{"severity":"moderate","via":["baz"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":1,"critical":0,"total":2}}}'
# Schema drift: no `vulnerabilities` key at all (distinct from clean `{}`).
WEB_AUDIT_DRIFT_FULL='{"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}'
# A high advisory present in the PRODUCTION (--omit=dev) tree. It carries a
# committed GHSA on purpose: the production guard uses an empty policy, so an
# excepted advisory reaching production must still fail.
WEB_AUDIT_HIGH_PROD='{"vulnerabilities":{"undici":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}'

WEB_AUDIT_OUTPUT=""
WEB_AUDIT_EXIT=0

# Drive `bash scripts/local-ci.sh --gate web-audit` against the tracked fixture
# web root with an npm mock that serves $1 for the full-tree invocation and $2
# for the --omit=dev invocation, rejecting any other argv. Results land in
# WEB_AUDIT_OUTPUT / WEB_AUDIT_EXIT.
run_web_audit_gate() {
    local full_json="$1" prod_json="$2"
    local full_status="${3:-1}" prod_status="${4:-0}"
    local tmpdir fixture_root
    tmpdir="$(mktemp -d)"
    fixture_root="$REPO_ROOT/scripts/reliability/fixtures/security/web_audit_vulnerable"

    printf '%s' "$full_json" > "$tmpdir/full.json"
    printf '%s' "$prod_json" > "$tmpdir/prod.json"

    cat > "$tmpdir/npm" <<'MOCK'
#!/usr/bin/env bash
if [ "$PWD" != "$EXPECTED_WEB_AUDIT_ROOT" ]; then
    echo "fake npm: wrong working directory: $PWD" >&2
    exit 91
fi
# Full dependency-tree audit: audit --audit-level=high --package-lock-only --json
if [ "$#" -eq 4 ] \
    && [ "$1" = "audit" ] && [ "$2" = "--audit-level=high" ] \
    && [ "$3" = "--package-lock-only" ] && [ "$4" = "--json" ]; then
    cat "$MOCK_FULL_REPORT"
    exit "$MOCK_FULL_STATUS"
fi
# Production-only audit: ... --omit=dev --json
if [ "$#" -eq 5 ] \
    && [ "$1" = "audit" ] && [ "$2" = "--audit-level=high" ] \
    && [ "$3" = "--package-lock-only" ] && [ "$4" = "--omit=dev" ] \
    && [ "$5" = "--json" ]; then
    cat "$MOCK_PROD_REPORT"
    exit "$MOCK_PROD_STATUS"
fi
echo "fake npm: wrong arguments: $*" >&2
exit 92
MOCK
    chmod +x "$tmpdir/npm"

    WEB_AUDIT_EXIT=0
    WEB_AUDIT_OUTPUT="$(
        EXPECTED_WEB_AUDIT_ROOT="$fixture_root" \
        FJCLOUD_WEB_AUDIT_ROOT="$fixture_root" \
        MOCK_FULL_REPORT="$tmpdir/full.json" \
        MOCK_PROD_REPORT="$tmpdir/prod.json" \
        MOCK_FULL_STATUS="$full_status" \
        MOCK_PROD_STATUS="$prod_status" \
        PATH="$tmpdir:$PATH" \
        bash "$REPO_ROOT/scripts/local-ci.sh" --gate web-audit 2>&1
    )" || WEB_AUDIT_EXIT=$?

    rm -rf "$tmpdir"
}

# LOAD-BEARING ARM 1: an excepted high GHSA in via[] lets the gate pass. This
# reads the REAL committed web/npm_audit_exceptions.txt, so it also proves the
# committed policy actually covers the five undici advisories.
test_web_audit_excepted_advisory_passes() {
    run_web_audit_gate "$WEB_AUDIT_EXCEPTED_FULL" "$WEB_AUDIT_CLEAN_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "0" "an excepted high GHSA in via[] should let web-audit pass"
    assert_contains "$WEB_AUDIT_OUTPUT" "PASS" "excepted web-audit should report a passing gate"
    assert_not_contains "$WEB_AUDIT_OUTPUT" "FAIL" "excepted web-audit should not report a failure"
}

# LOAD-BEARING ARM 2 (the reason this lane exists): an unlisted high GHSA still
# fails the gate and names the blocking advisory id in the summary output.
test_web_audit_unlisted_advisory_fails_and_names_it() {
    run_web_audit_gate "$WEB_AUDIT_UNLISTED_FULL" "$WEB_AUDIT_CLEAN_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "1" "an unlisted high GHSA should fail web-audit"
    assert_contains "$WEB_AUDIT_OUTPUT" "GHSA-zzzz-zzzz-zzzz" \
        "web-audit should name the blocking unlisted advisory in its output"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "an unlisted advisory should be a failed gate"
}

# FAIL-CLOSED ARM: unparsable audit JSON must fail the gate, never pass.
test_web_audit_unparsable_report_fails_closed() {
    run_web_audit_gate 'not valid json at all' "$WEB_AUDIT_CLEAN_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "1" "unparsable audit JSON should fail web-audit closed"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "unparsable audit should be a failed gate"
}

# FAIL-CLOSED ARM: a report missing the `vulnerabilities` key entirely (schema
# drift, distinct from a clean `"vulnerabilities": {}`) must fail closed.
test_web_audit_schema_drift_fails_closed() {
    run_web_audit_gate "$WEB_AUDIT_DRIFT_FULL" "$WEB_AUDIT_CLEAN_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "1" "a report with no vulnerabilities key should fail web-audit closed"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "schema drift should be a failed gate"
}

# FAIL-CLOSED ARM: a high entry whose via[] holds only strings and yields no
# GHSA id must block — an advisory with no extractable id can never be on the
# exception list and must not vanish.
test_web_audit_stringonly_via_high_blocks() {
    run_web_audit_gate "$WEB_AUDIT_STRVIA_FULL" "$WEB_AUDIT_CLEAN_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "1" "a high entry with no extractable GHSA id must block"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "a no-extractable-id high entry should be a failed gate"
}

# GUARD RED PATH: the full-tree report is fully excepted, but a high advisory
# reaches PRODUCTION (--omit=dev). The gate must still fail, attributed to the
# production audit — proving the exception list can never cover a production dep.
test_local_ci_web_audit_production_guard_blocks_high_advisory() {
    run_web_audit_gate "$WEB_AUDIT_EXCEPTED_FULL" "$WEB_AUDIT_HIGH_PROD"
    assert_eq "$WEB_AUDIT_EXIT" "1" \
        "a high production advisory must fail web-audit even when excepted in the full tree"
    assert_contains "$WEB_AUDIT_OUTPUT" "production" \
        "the failure must be attributed to the production audit, not exception filtering"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "the production guard failure should be a failed gate"
}

test_local_ci_web_audit_rejects_unexpected_npm_exit_statuses() {
    run_web_audit_gate "$WEB_AUDIT_CLEAN_PROD" "$WEB_AUDIT_CLEAN_PROD" 1 2
    assert_eq "$WEB_AUDIT_EXIT" "1" \
        "an unexpected production npm audit exit status must fail web-audit"
    assert_contains "$WEB_AUDIT_OUTPUT" "unexpected status 2" \
        "production audit operational failure should name the unexpected status"
    assert_contains "$WEB_AUDIT_OUTPUT" "production" \
        "production audit operational failure should be attributed to the production audit"

    run_web_audit_gate "$WEB_AUDIT_CLEAN_PROD" "$WEB_AUDIT_CLEAN_PROD" 2 0
    assert_eq "$WEB_AUDIT_EXIT" "1" \
        "an unexpected full-tree npm audit exit status must fail web-audit"
    assert_contains "$WEB_AUDIT_OUTPUT" "unexpected status 2" \
        "full-tree audit operational failure should name the unexpected status"
    assert_contains "$WEB_AUDIT_OUTPUT" "full dependency" \
        "full-tree audit operational failure should be attributed to the full dependency audit"
}

# The gate captures npm stdout to a temp file and classifies it, so raw npm
# output no longer reaches the summary; the preserved failure now surfaces as
# the blocking GHSA id the classifier names. The tracked fixture root is
# exercised via EXPECTED_WEB_AUDIT_ROOT in the npm mock (wrong cwd -> exit 91),
# and the precondition-message arms must stay absent under the new gate.
test_local_ci_web_audit_uses_fixture_root_and_preserves_failure() {
    run_web_audit_gate "$WEB_AUDIT_UNLISTED_FULL" "$WEB_AUDIT_CLEAN_PROD"

    assert_eq "$WEB_AUDIT_EXIT" "1" "web-audit should preserve an advisory failure status"
    assert_contains "$WEB_AUDIT_OUTPUT" "GHSA-zzzz-zzzz-zzzz" \
        "web-audit should preserve the failure as the blocking advisory the classifier names"
    assert_contains "$WEB_AUDIT_OUTPUT" "web-audit" "web-audit failure should be named in local-ci output"
    assert_contains "$WEB_AUDIT_OUTPUT" "FAIL" "web-audit advisory should be reported as a failed gate"
    assert_not_contains "$WEB_AUDIT_OUTPUT" "did not match any known gate" \
        "web-audit should be registered as a known local-ci gate"
    assert_not_contains "$WEB_AUDIT_OUTPUT" "package.json" \
        "tracked web-audit fixture should satisfy the manifest precondition"
    assert_not_contains "$WEB_AUDIT_OUTPUT" "package-lock.json" \
        "tracked web-audit fixture should satisfy the lockfile precondition"
    assert_not_contains "$WEB_AUDIT_OUTPUT" "node_modules" \
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

# Known-answer unit arms for scripts/lib/npm_audit_exceptions.py invoked
# directly, mirroring test_cvss_severity_script_known_answers. These pin the
# classifier's blocking rule independently of the shell gate wiring: verdict on
# stdout, blocking ids on stderr, exit 2 on unreadable/schema-drifted input.
test_npm_audit_exceptions_script_known_answers() {
    local script="$REPO_ROOT/scripts/lib/npm_audit_exceptions.py"
    local tmp exc
    tmp="$(mktemp)"
    exc="$(mktemp)"
    printf '%s\n' '# committed-style exception list' \
        'GHSA-8xcm-r25x-g524' 'GHSA-4cwx-7wf7-3272' 'GHSA-m8rv-5g2x-5cg5' \
        'GHSA-jr45-8vmc-qm54' 'GHSA-v3r7-h72x-cjcm' > "$exc"

    local out err_out ec

    # Every implicated GHSA on the list -> pass.
    printf '%s' '{"vulnerabilities":{"undici":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"},{"url":"https://github.com/advisories/GHSA-4cwx-7wf7-3272"},{"url":"https://github.com/advisories/GHSA-m8rv-5g2x-5cg5"},{"url":"https://github.com/advisories/GHSA-jr45-8vmc-qm54"},{"url":"https://github.com/advisories/GHSA-v3r7-h72x-cjcm"}]},"miniflare":{"severity":"moderate","via":["undici"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":1,"critical":0,"total":2}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    assert_eq "$out" "pass" "a high entry whose every GHSA is excepted should pass"

    # One implicated GHSA off the list -> fail, named.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"},{"url":"https://github.com/advisories/GHSA-zzzz-zzzz-zzzz"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)"
    assert_eq "$out" "fail" "one uncovered GHSA in a high entry should fail"
    assert_contains "$err_out" "GHSA-zzzz-zzzz-zzzz" "the uncovered GHSA should be named on stderr"
    assert_not_contains "$err_out" "GHSA-8xcm-r25x-g524" "the covered GHSA should not be named as blocking"

    # A critical entry with an unlisted GHSA -> fail.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"critical","via":[{"url":"https://github.com/advisories/GHSA-crit-crit-crit"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":1,"total":1}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    assert_eq "$out" "fail" "an unlisted critical advisory should fail"

    # A high entry whose via[] is only strings -> no extractable id -> fail.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":["bar"]},"bar":{"severity":"moderate","via":["baz"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":1,"critical":0,"total":2}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)"
    assert_eq "$out" "fail" "a high entry with no extractable GHSA id should fail"
    assert_contains "$err_out" "foo" "the unresolvable high entry should be named by package"

    # A high entry with an empty via[] -> no id -> fail, named (no-advisory-id).
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":[]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)"
    assert_eq "$out" "fail" "a high entry with an empty via[] should fail"
    assert_contains "$err_out" "no-advisory-id" "an empty-via high entry should be named as having no advisory id"

    # Moderate-only findings are below the blocking band -> pass, even unlisted.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"moderate","via":[{"url":"https://github.com/advisories/GHSA-mod0-mod0-mod0"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":0,"critical":0,"total":1}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    assert_eq "$out" "pass" "a moderate-only unlisted advisory should not block"

    # A clean, explicitly-empty report -> pass.
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    assert_eq "$out" "pass" "a clean empty report should pass"

    # The `vulnerabilities` object entirely gone -> exit 2, fail closed.
    printf '%s' '{"metadata":{"vulnerabilities":{"high":0,"critical":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a report with no vulnerabilities object should exit 2"
    assert_eq "$out" "parse_error" "a report with no vulnerabilities object should not yield a verdict"

    # Enumerated high+critical disagrees with metadata -> schema drift, exit 2.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a high entry uncounted by metadata should exit 2"
    assert_eq "$out" "parse_error" "a metadata cross-check mismatch should not yield a verdict"

    # A negative metadata count must never cancel a positive one: an aggregate
    # of high=-1 + critical=1 equals the zero enumerated entries of an empty
    # report, so without a non-negative check the cross-check agrees and a
    # report that itself claims one critical vulnerability passes.
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":-1,"critical":1,"total":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)" || true
    assert_eq "$ec" "2" "a negative metadata count cancelling a positive one should exit 2"
    assert_eq "$out" "parse_error" "cross-band count cancellation should not yield a verdict"
    assert_contains "$err_out" "high" "the negative metadata band should be named on stderr"

    # The same rejection applies to a lone negative count with nothing to cancel.
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":-1,"total":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)" || true
    assert_eq "$ec" "2" "a negative critical count should exit 2 on its own"
    assert_contains "$err_out" "critical" "the negative critical band should be named on stderr"

    # Unparsable JSON -> exit 2.
    printf '%s' 'not json at all' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "an unparsable report should exit 2 (caller fails closed)"
    assert_eq "$out" "parse_error" "an unparsable report should not yield a verdict"

    # Invalid UTF-8 must not be discarded into an apparently valid report.
    python3 - "$tmp" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(
    b'{"vulnerabilities":{},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}\xff'
)
PY
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "invalid UTF-8 audit evidence should exit 2, not be decoded lossily"
    assert_eq "$out" "parse_error" "invalid UTF-8 audit evidence should not yield a verdict"

    # An unreadable exception list -> exit 2, fail closed (never treat as empty).
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"high":0,"critical":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$tmp.does-not-exist" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "an unreadable exception list should exit 2, not be treated as empty"
    assert_eq "$out" "parse_error" "an unreadable exception list should not yield a verdict"

    # A severity outside npm's closed set is undecidable, not "below the
    # blocking band": the metadata cross-check cannot catch it either, since an
    # unrecognised band is counted nowhere. It must exit 2, never pass.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"severe","via":[{"url":"https://github.com/advisories/GHSA-zzzz-zzzz-zzzz"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":1}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)" || ec=$?
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)" || true
    assert_eq "$ec" "2" "an unrecognised severity band should exit 2, not be treated as non-blocking"
    assert_eq "$out" "parse_error" "an unrecognised severity band should not yield a verdict"
    assert_contains "$err_out" "severe" "the unrecognised severity value should be named on stderr"

    # A `via` cycle must not let the unresolved edge disappear beside a readable
    # excepted advisory: foo's chain reaches bar, which points back at foo.
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"},"bar"]},"bar":{"severity":"moderate","via":["foo"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":1,"high":1,"critical":0,"total":2}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    err_out="$(python3 "$script" "$tmp" "$exc" 2>&1 >/dev/null)"
    assert_eq "$out" "fail" "a cyclic via edge beside an excepted GHSA should still block"
    assert_contains "$err_out" "foo" "the entry whose chain contains the cycle should be named"

    # ...but a diamond (the same package reached by two distinct paths) is NOT a
    # cycle, and must still resolve to its real, excepted advisory id.
    printf '%s' '{"vulnerabilities":{"top":{"severity":"high","via":["b","c"]},"b":{"severity":"moderate","via":["d"]},"c":{"severity":"moderate","via":["d"]},"d":{"severity":"moderate","via":[{"url":"https://github.com/advisories/GHSA-8xcm-r25x-g524"}]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":3,"high":1,"critical":0,"total":4}}}' > "$tmp"
    out="$(python3 "$script" "$tmp" "$exc" 2>/dev/null)"
    assert_eq "$out" "pass" "a re-converging (diamond) via chain should resolve, not read as a cycle"

    # The policy file authorises NAMED advisories only. A non-GHSA value —
    # including an internal classifier token such as `unresolved:foo` — must
    # fail the whole classification closed, never except an unnamed advisory.
    local bad_exc
    bad_exc="$(mktemp)"
    # `foo` names a package absent from the report, so its only implicated token
    # is the internal `unresolved:missing` label. Were the policy file to accept
    # that label, an advisory with no extractable id would be excepted outright.
    printf '%s\n' '# malformed policy' 'GHSA-8xcm-r25x-g524' 'unresolved:missing' > "$bad_exc"
    printf '%s' '{"vulnerabilities":{"foo":{"severity":"high","via":["missing"]}},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":1,"critical":0,"total":1}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$bad_exc" 2>/dev/null)" || ec=$?
    err_out="$(python3 "$script" "$tmp" "$bad_exc" 2>&1 >/dev/null)" || true
    assert_eq "$ec" "2" "an internal token in the policy file should exit 2, not except an unnamed advisory"
    assert_eq "$out" "parse_error" "a malformed policy line should not yield a verdict"
    assert_contains "$err_out" "unresolved:missing" "the malformed policy value should be named on stderr"

    # A lookalike that is not a full GHSA id is malformed too (no substring match).
    printf '%s\n' 'see GHSA-8xcm-r25x-g524 for details' > "$bad_exc"
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$bad_exc" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "2" "a policy line that merely contains a GHSA id should exit 2"
    assert_eq "$out" "parse_error" "a partially-matching policy line should not yield a verdict"

    # The committed policy itself must satisfy that validator.
    printf '%s' '{"vulnerabilities":{},"metadata":{"vulnerabilities":{"info":0,"low":0,"moderate":0,"high":0,"critical":0,"total":0}}}' > "$tmp"
    ec=0
    out="$(python3 "$script" "$tmp" "$REPO_ROOT/web/npm_audit_exceptions.txt" 2>/dev/null)" || ec=$?
    assert_eq "$ec" "0" "the committed web/npm_audit_exceptions.txt should parse cleanly"
    assert_eq "$out" "pass" "the committed policy against a clean report should pass"

    rm -f "$tmp" "$exc" "$bad_exc"
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
test_npm_audit_exceptions_script_known_answers
echo ""
echo "--- consolidation contract tests ---"
test_tracked_security_checks_has_single_owner
test_local_ci_known_gates_include_security_gates
test_local_ci_security_gate_rosters_and_execution_root
test_web_audit_excepted_advisory_passes
test_web_audit_unlisted_advisory_fails_and_names_it
test_web_audit_unparsable_report_fails_closed
test_web_audit_schema_drift_fails_closed
test_web_audit_stringonly_via_high_blocks
test_local_ci_web_audit_production_guard_blocks_high_advisory
test_local_ci_web_audit_rejects_unexpected_npm_exit_statuses
test_local_ci_web_audit_uses_fixture_root_and_preserves_failure
echo ""
echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
[ "$FAIL_COUNT" -eq 0 ]
