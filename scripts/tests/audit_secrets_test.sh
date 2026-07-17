#!/usr/bin/env bash
# Contract tests for scripts/audit_secrets.sh.
# Focus: shared parser seam reuse, structured output contract, and false-positive guards.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUDIT_SCRIPT="$REPO_ROOT/scripts/audit_secrets.sh"
SHARED_PARSER_SCRIPT="$REPO_ROOT/scripts/lib/secret_audit_parsing.sh"
TF_AUDIT_SCRIPT="$REPO_ROOT/ops/terraform/audit_no_secrets.sh"

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

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

write_inventory_fixture() {
    local path="$1"
    shift

    mkdir -p "$(dirname "$path")"
    {
        echo "# Fixture Inventory"
        echo ""
        echo "## Inventory Table"
        echo "| Secret source | Owner | Load/mapping path | Notes |"
        echo "| --- | --- | --- | --- |"
        for name in "$@"; do
            printf '| `%s` | fixture | fixture | fixture |\n' "$name"
        done
    } > "$path"
}

run_audit() {
    local output_file="$1"
    shift

    set +e
    bash "$AUDIT_SCRIPT" "$@" >"$output_file" 2>&1
    local status=$?
    set -e
    echo "$status"
}

assert_structured_finding_lines() {
    local output_file="$1"
    local message="$2"

    if awk -F'|' 'NF != 4 || $1 == "" || $2 == "" || $3 == "" || $4 == "" { exit 1 }' "$output_file"; then
        pass "$message"
    else
        fail "$message"
    fi
}

test_shared_parser_seam_is_reused() {
    if [[ -f "$SHARED_PARSER_SCRIPT" ]]; then
        pass "shared parser library exists"
    else
        fail "shared parser library exists"
    fi

    if [[ -f "$AUDIT_SCRIPT" ]]; then
        pass "audit_secrets.sh exists"
    else
        fail "audit_secrets.sh exists"
    fi

    if rg -q "scripts/lib/secret_audit_parsing.sh" "$AUDIT_SCRIPT" 2>/dev/null; then
        pass "audit_secrets.sh sources shared parser"
    else
        fail "audit_secrets.sh sources shared parser"
    fi

    if rg -q "scripts/lib/secret_audit_parsing.sh" "$TF_AUDIT_SCRIPT"; then
        pass "audit_no_secrets.sh sources shared parser"
    else
        fail "audit_no_secrets.sh sources shared parser"
    fi

    if rg -q "parse_env_assignment_line" "$AUDIT_SCRIPT" 2>/dev/null; then
        pass "audit_secrets.sh reuses parse_env_assignment_line"
    else
        fail "audit_secrets.sh reuses parse_env_assignment_line"
    fi

    if rg -q "is_secret_bearing_name" "$SHARED_PARSER_SCRIPT"; then
        pass "shared parser owns secret-bearing classifier"
    else
        fail "shared parser owns secret-bearing classifier"
    fi

    if rg -q "^is_secret_bearing_name\\(\\)" "$AUDIT_SCRIPT"; then
        fail "audit_secrets.sh does not define secret-bearing classifier inline"
    else
        pass "audit_secrets.sh does not define secret-bearing classifier inline"
    fi

    if rg -q "function is_secret_bearing\\(" "$AUDIT_SCRIPT"; then
        fail "scan_c_like_file does not duplicate secret-bearing classifier"
    else
        pass "scan_c_like_file does not duplicate secret-bearing classifier"
    fi
}

test_missing_default_inventory_emits_single_structured_finding() {
    local tmpdir output_file status line_count content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/scripts"
    cat > "$tmpdir/scripts/consumer.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "${UNLISTED_SECRET_TOKEN}"
SCRIPT

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "1" "audit exits non-zero when default inventory is missing"

    line_count="$(grep -cve '^[[:space:]]*$' "$output_file" || true)"
    assert_eq "$line_count" "1" "missing inventory emits exactly one finding line"

    content="$(cat "$output_file")"
    assert_eq "$content" "inventory_missing|inventory|docs/private/secrets_inventory.md|inventory_missing" \
        "missing inventory emits public-safe structured finding"

    rm -rf "$tmpdir"
}

test_missing_option_values_fail_with_usage_instead_of_unbound_variable() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    status="$(run_audit "$output_file" --scan-root)"
    assert_eq "$status" "2" "--scan-root without a value exits with usage error"
    content="$(cat "$output_file")"
    assert_contains "$content" "Missing value for --scan-root" \
        "--scan-root without a value reports the missing operand"
    assert_not_contains "$content" "unbound variable" \
        "--scan-root without a value does not crash via set -u"

    status="$(run_audit "$output_file" --inventory)"
    assert_eq "$status" "2" "--inventory without a value exits with usage error"
    content="$(cat "$output_file")"
    assert_contains "$content" "Missing value for --inventory" \
        "--inventory without a value reports the missing operand"
    assert_not_contains "$content" "unbound variable" \
        "--inventory without a value does not crash via set -u"

    rm -rf "$tmpdir"
}

test_scan_root_override_reports_unlisted_consumer() {
    local tmpdir output_file status
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/scripts" "$tmpdir/docs/private"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/scripts/consumer.sh" <<'SCRIPT'
#!/usr/bin/env bash
echo "${UNLISTED_SECRET_TOKEN}"
SCRIPT

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "1" "audit exits non-zero for unlisted observed consumers"
    assert_contains "$(cat "$output_file")" "consumer|UNLISTED_SECRET_TOKEN|scripts/consumer.sh:2|drift_unlisted_consumer" \
        "unlisted shell consumer is reported with structured status"
    assert_structured_finding_lines "$output_file" "all findings use category|name|location|status format"

    rm -rf "$tmpdir"
}

test_allow_deferred_skips_inventory_rows_backed_by_gap_specs() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/docs/gaps" "$tmpdir/scripts"
    cat > "$tmpdir/docs/private/secrets_inventory.md" <<'MD'
# Fixture Inventory

| Secret source | Owner | Load/mapping path | Notes |
| --- | --- | --- | --- |
| `ORPHAN_SECRET_KEY` | fixture | fixture | deferred_to_wave2a:docs/gaps/orphan_secret_key.md |
MD
    : > "$tmpdir/docs/gaps/orphan_secret_key.md"

    status="$(run_audit "$output_file" --scan-root "$tmpdir" --allow-deferred)"
    assert_eq "$status" "0" "--allow-deferred exits zero when every finding maps to a gap spec"
    content="$(cat "$output_file")"
    assert_eq "$content" "" "--allow-deferred suppresses fully deferred finding output"

    rm -rf "$tmpdir"
}

test_allow_deferred_keeps_unbacked_findings_failing() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts"
    cat > "$tmpdir/docs/private/secrets_inventory.md" <<'MD'
# Fixture Inventory

| Secret source | Owner | Load/mapping path | Notes |
| --- | --- | --- | --- |
| `ORPHAN_SECRET_KEY` | fixture | fixture | deferred_to_wave2a:docs/gaps/missing_gap.md |
MD

    status="$(run_audit "$output_file" --scan-root "$tmpdir" --allow-deferred)"
    assert_eq "$status" "1" "--allow-deferred stays non-zero when the deferred gap spec is absent"
    content="$(cat "$output_file")"
    assert_contains "$content" "inventory|ORPHAN_SECRET_KEY|docs/private/secrets_inventory.md:5|drift_orphan_inventory_row" \
        "--allow-deferred keeps orphan findings visible when the gap spec file is missing"

    rm -rf "$tmpdir"
}

test_allow_deferred_rejects_path_traversal_gap_specs() {
    local tmpdir output_file status content outside_gap
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"
    outside_gap="$(dirname "$tmpdir")/outside_gap.md"

    mkdir -p "$tmpdir/docs/private"
    : > "$outside_gap"
    cat > "$tmpdir/docs/private/secrets_inventory.md" <<'MD'
# Fixture Inventory

| Secret source | Owner | Load/mapping path | Notes |
| --- | --- | --- | --- |
| `ORPHAN_SECRET_KEY` | fixture | fixture | deferred_to_wave2a:../outside_gap.md |
MD

    status="$(run_audit "$output_file" --scan-root "$tmpdir" --allow-deferred)"
    assert_eq "$status" "1" "--allow-deferred rejects traversal-style deferred gap paths"
    content="$(cat "$output_file")"
    assert_contains "$content" "inventory|ORPHAN_SECRET_KEY|docs/private/secrets_inventory.md:5|drift_orphan_inventory_row" \
        "traversal-style deferred gap paths do not suppress orphan inventory findings"

    rm -f "$outside_gap"
    rm -rf "$tmpdir"
}

test_inventory_override_reports_orphan_inventory_row() {
    local tmpdir output_file status
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/scripts"
    write_inventory_fixture "$tmpdir/fixture_inventory.md" "ORPHAN_SECRET_KEY"

    status="$(run_audit "$output_file" --scan-root "$tmpdir" --inventory "$tmpdir/fixture_inventory.md")"
    assert_eq "$status" "1" "audit exits non-zero for orphan inventory rows"
    assert_contains "$(cat "$output_file")" "inventory|ORPHAN_SECRET_KEY|fixture_inventory.md:" \
        "orphan inventory row includes override inventory location"
    assert_contains "$(cat "$output_file")" "|drift_orphan_inventory_row" \
        "orphan inventory row uses drift_orphan_inventory_row status"

    rm -rf "$tmpdir"
}

test_comment_only_mentions_do_not_create_findings() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/ops/terraform" "$tmpdir/.github/workflows" "$tmpdir/scripts" "$tmpdir/infra/api/src"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/ops/terraform/main.tf" <<'TF'
# db_password = "comment-only-secret"
/*
api_token = "comment-only-token"
*/
TF

    cat > "$tmpdir/.github/workflows/ci.yml" <<'WF'
name: CI
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      # - run: echo "${{ secrets.COMMENT_ONLY_WORKFLOW_SECRET }}"
      - run: echo "safe"
WF

    cat > "$tmpdir/scripts/commented.sh" <<'SH'
#!/usr/bin/env bash
# echo "${COMMENT_ONLY_SHELL_SECRET}"
SH

    cat > "$tmpdir/infra/api/src/comment_only.rs" <<'RS'
// std::env::var("COMMENT_ONLY_RUST_SECRET");
/*
std::env::var("COMMENT_ONLY_RUST_BLOCK_SECRET");
*/
fn main() {}
RS

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "0" "comment-only references across families do not fail audit"
    content="$(cat "$output_file")"
    assert_eq "$content" "" "comment-only references produce no findings"

    rm -rf "$tmpdir"
}

test_positive_shell_and_web_consumers_remain_detected() {
    local tmpdir output_file status content line_count
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts" "$tmpdir/web/src/lib"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/scripts/consume.sh" <<'SH'
#!/usr/bin/env bash
echo "${SHELL_PRIVATE_TOKEN}"
SH

    cat > "$tmpdir/web/src/lib/private_env.ts" <<'TS'
const token = import.meta.env.VITE_PRIVATE_API_TOKEN;
console.log(token);
TS

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "1" "real shell/web consumers are still detected"

    content="$(cat "$output_file")"
    assert_contains "$content" "consumer|SHELL_PRIVATE_TOKEN|scripts/consume.sh:2|drift_unlisted_consumer" \
        "shell variable read remains detectable"
    assert_contains "$content" "consumer|VITE_PRIVATE_API_TOKEN|web/src/lib/private_env.ts:1|drift_unlisted_consumer" \
        "web private env consumer remains detectable"

    line_count="$(grep -cve '^[[:space:]]*$' "$output_file" || true)"
    assert_eq "$line_count" "2" "each finding is emitted on exactly one line"
    assert_structured_finding_lines "$output_file" "positive findings keep the structured output format"

    rm -rf "$tmpdir"
}

test_local_shell_vars_and_non_secret_c_like_reads_stay_clean() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts" "$tmpdir/infra/api/src"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/scripts/local_var.sh" <<'SH'
#!/usr/bin/env bash
TOKEN='not-an-env-secret'
echo "${TOKEN}"
SH

    cat > "$tmpdir/infra/api/src/config.rs" <<'RS'
fn port() -> String {
    std::env::var("PORT").unwrap_or_else(|_| "8080".to_string())
}
RS

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "0" "local shell variables and non-secret config reads do not fail audit"

    content="$(cat "$output_file")"
    assert_eq "$content" "" "local shell variables and PORT config reads produce no findings"

    rm -rf "$tmpdir"
}

test_plain_dollar_shell_secret_reads_are_detected() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/scripts/plain_dollar.sh" <<'SH'
#!/usr/bin/env bash
echo "$PLAIN_DOLLAR_SECRET"
SH

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "1" "plain dollar shell secret reads fail audit when unlisted"

    content="$(cat "$output_file")"
    assert_contains "$content" "consumer|PLAIN_DOLLAR_SECRET|scripts/plain_dollar.sh:2|drift_unlisted_consumer" \
        "plain dollar shell secret reads are emitted as structured findings"
    assert_structured_finding_lines "$output_file" "plain dollar findings keep structured output format"

    rm -rf "$tmpdir"
}

test_lowercase_terraform_secret_refs_are_detected() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/ops/terraform"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/ops/terraform/main.tf" <<'TF'
resource "aws_ssm_parameter" "jwt_secret" {
  value = var.jwt_secret
}
TF

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "1" "lowercase terraform secret refs fail audit when unlisted"

    content="$(cat "$output_file")"
    assert_contains "$content" "consumer|jwt_secret|ops/terraform/main.tf:2|drift_unlisted_consumer" \
        "lowercase terraform secret refs are emitted as structured findings"
    assert_structured_finding_lines "$output_file" "lowercase terraform findings keep structured output format"

    rm -rf "$tmpdir"
}

test_terraform_non_secret_var_refs_do_not_crash_or_emit_findings() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/ops/terraform"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/ops/terraform/main.tf" <<'TF'
resource "aws_instance" "web" {
  instance_type = var.instance_type
}
TF

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "0" "non-secret terraform var refs do not fail audit"

    content="$(cat "$output_file")"
    assert_eq "$content" "" "non-secret terraform var refs produce no findings"

    rm -rf "$tmpdir"
}

test_shell_parser_errors_do_not_leak_to_output() {
    local tmpdir output_file status content
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md"

    cat > "$tmpdir/scripts/non_env_syntax.sh" <<'SH'
#!/usr/bin/env bash
broken='
echo "still-valid-shell-later"
SH

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "0" "non-env shell syntax does not break audit execution"

    content="$(cat "$output_file")"
    assert_not_contains "$content" "substring expression < 0" \
        "raw helper parser stderr is suppressed from structured output"
    assert_eq "$content" "" "no findings are emitted for non-secret malformed shell assignment syntax"

    rm -rf "$tmpdir"
}

test_admin_key_and_database_url_consumers_are_detected() {
    local tmpdir output_file status content line_count
    tmpdir="$(mktemp -d)"
    output_file="$tmpdir/output.log"

    mkdir -p "$tmpdir/docs/private" "$tmpdir/scripts" "$tmpdir/infra/api/src"
    write_inventory_fixture "$tmpdir/docs/private/secrets_inventory.md" "FLAPJACK_ADMIN_KEY" "DATABASE_URL"

    cat > "$tmpdir/scripts/admin_consumer.sh" <<'SH'
#!/usr/bin/env bash
echo "$FLAPJACK_ADMIN_KEY"
SH

    cat > "$tmpdir/infra/api/src/database_consumer.rs" <<'RS'
fn db_url() -> Result<String, std::env::VarError> {
    std::env::var("DATABASE_URL")
}
RS

    status="$(run_audit "$output_file" --scan-root "$tmpdir")"
    assert_eq "$status" "0" "inventory-listed ADMIN_KEY and DATABASE_URL consumers stay observed"

    content="$(cat "$output_file")"
    assert_eq "$content" "" "ADMIN_KEY and DATABASE_URL consumers do not emit orphan or unlisted findings"

    line_count="$(grep -cve '^[[:space:]]*$' "$output_file" || true)"
    assert_eq "$line_count" "0" "ADMIN_KEY and DATABASE_URL fixture emits no finding lines"

    rm -rf "$tmpdir"
}

main() {
    echo "=== audit_secrets.sh contract tests ==="
    echo ""

    test_shared_parser_seam_is_reused
    test_missing_default_inventory_emits_single_structured_finding
    test_missing_option_values_fail_with_usage_instead_of_unbound_variable
    test_scan_root_override_reports_unlisted_consumer
    test_allow_deferred_skips_inventory_rows_backed_by_gap_specs
    test_allow_deferred_keeps_unbacked_findings_failing
    test_allow_deferred_rejects_path_traversal_gap_specs
    test_inventory_override_reports_orphan_inventory_row
    test_comment_only_mentions_do_not_create_findings
    test_positive_shell_and_web_consumers_remain_detected
    test_local_shell_vars_and_non_secret_c_like_reads_stay_clean
    test_plain_dollar_shell_secret_reads_are_detected
    test_lowercase_terraform_secret_refs_are_detected
    test_terraform_non_secret_var_refs_do_not_crash_or_emit_findings
    test_shell_parser_errors_do_not_leak_to_output
    test_admin_key_and_database_url_consumers_are_detected

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
