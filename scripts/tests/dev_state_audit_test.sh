#!/usr/bin/env bash
# Tests for scripts/dev_state_audit.sh: local seed-state drift detection.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

write_mock_psql_for_audit() {
    local path="$1" log_path="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat >> "__LOG_PATH__"
case "${MOCK_DEV_AUDIT_SCENARIO:-pass}" in
    pass)
        printf 'dev@example.com|3\nfree@example.com|1\n__synthetic_vm_active__|0\n'
        ;;
    canonical_clean_seed_rows)
        printf '%s\n' \
            'vm|61a2d4d3-a473-42fb-9d62-5a9b45c0c7b6|e2e-seed-4f9942c0|bare_metal|us-east-1|http://127.0.0.1:17700|decommissioned|2026-06-04 23:45:33.669853+00|2026-06-04 23:45:33.668015+00|2026-06-04 23:45:35.112381+00' \
            'vm|f7b5d193-130c-4d96-8940-83d74255c79b|e2e-seed-6ed57b10|bare_metal|eu-west-1|http://127.0.0.1:17701|decommissioned|2026-06-04 23:45:33.806621+00|2026-06-04 23:45:33.805291+00|2026-06-04 23:45:35.112381+00' \
            'vm|f14bafa6-355c-423b-accc-0cae5cd4a26e|e2e-seed-a543215a|bare_metal|eu-central-1|http://127.0.0.1:17702|decommissioned|2026-06-04 23:45:33.960905+00|2026-06-04 23:45:33.959013+00|2026-06-04 23:45:35.112381+00' \
            'vm|f731c824-46cb-4ee4-8e2d-bc37467d857b|local-dev-eu-central-1|local|eu-central-1|http://127.0.0.1:17702|active|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00' \
            'vm|a5bc391f-c3ff-440b-b002-6b269c2527c4|local-dev-eu-west-1|local|eu-west-1|http://127.0.0.1:17701|active|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00' \
            'vm|a3c93b87-6422-4d84-8c9a-3b3aa592c1ca|local-dev-us-east-1|local|us-east-1|http://127.0.0.1:17700|active|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00|2026-06-04 23:45:31.948604+00' \
            'tenant_ref_count|0'
        ;;
    dev_over)
        printf 'dev@example.com|54\nfree@example.com|1\n__synthetic_vm_active__|0\n'
        ;;
    free_over)
        printf 'dev@example.com|3\nfree@example.com|52\n__synthetic_vm_active__|0\n'
        ;;
    vm_over)
        printf 'dev@example.com|3\nfree@example.com|1\n__synthetic_vm_active__|1\n'
        ;;
    stale_fixture_over)
        printf 'dev@example.com|3\nfree@example.com|1\n__synthetic_vm_active__|0\n__stale_fixture_tenants__|2\n'
        ;;
esac
MOCK
    sed -i.bak "s|__LOG_PATH__|$log_path|g" "$path"
    rm -f "$path.bak"
    chmod +x "$path"
}

run_audit_with_mock_psql() {
    local scenario="$1" tmp_dir="$2"
    mkdir -p "$tmp_dir/bin"
    write_mock_psql_for_audit "$tmp_dir/bin/psql" "$tmp_dir/psql.stdin"

    PATH="$tmp_dir/bin:$PATH" \
    DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
    MOCK_DEV_AUDIT_SCENARIO="$scenario" \
        bash "$REPO_ROOT/scripts/dev_state_audit.sh" 2>&1
}

test_audit_passes_at_canonical_counts() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql pass "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "0" "audit should pass at canonical local seed counts"
    assert_contains "$output" "dev@example.com tenants: 3 <= 53" \
        "audit should report the shared seed tenant threshold"
    assert_contains "$output" "free@example.com tenants: 1 <= 51" \
        "audit should report the free seed tenant threshold"
    assert_contains "$output" "active e2e-seed-% VM rows: 0 <= 0" \
        "audit should report the synthetic VM active-row threshold"
}

test_audit_passes_observed_canonical_clean_seed_rows() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql canonical_clean_seed_rows "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "0" \
        "audit should pass the observed canonical clean seed VM inventory rows"
    assert_contains "$output" "Local dev state audit passed" \
        "audit should accept clean seed rows with decommissioned e2e-seed VMs and active local-dev VMs"
}

test_audit_fails_when_shared_seed_exceeds_threshold() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql dev_over "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "1" "audit should fail when shared seed tenants exceed threshold"
    assert_contains "$output" "dev@example.com tenants: 54 > 53" \
        "audit should show the shared seed failure threshold"
    assert_contains "$output" "scripts/local-dev-down.sh --clean && scripts/local_demo.sh" \
        "audit failure should include the current-stage reset path"
}

test_audit_fails_when_free_seed_exceeds_threshold() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql free_over "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "1" "audit should fail when free seed tenants exceed threshold"
    assert_contains "$output" "free@example.com tenants: 52 > 51" \
        "audit should show the free seed failure threshold"
}

test_audit_fails_when_synthetic_vm_rows_are_active() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql vm_over "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "1" "audit should fail when synthetic VM rows remain active"
    assert_contains "$output" "active e2e-seed-% VM rows: 1 > 0" \
        "audit should show the synthetic VM active-row failure threshold"
}

test_audit_fails_when_stale_fixture_tenants_exist() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql stale_fixture_over "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "1" \
        "audit should fail when exact stale fixture tenants exist despite canonical seed counts"
    assert_contains "$output" "stale fixture tenants: 2 > 0" \
        "audit should distinguish stale fixture tenant drift from canonical seed drift"
}

test_audit_fails_with_shared_db_access_message_when_database_unavailable() {
    local output exit_code=0

    output="$(DATABASE_URL="" bash "$REPO_ROOT/scripts/dev_state_audit.sh" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "audit should fail when database access is unavailable"
    assert_contains "$output" "DATABASE_URL is not set" \
        "audit should use the shared local DB access missing-DATABASE_URL convention"
}

assert_cleanup_remediation_precedes_reset() {
    local output="$1"

    python3 - "$output" <<'PY'
import sys

output = sys.argv[1]
cleanup = output.find("bash scripts/cleanup_dev_orphans.sh --apply")
reset = output.find("scripts/local-dev-down.sh --clean && scripts/local_demo.sh")
if cleanup == -1 or reset == -1 or cleanup >= reset:
    raise SystemExit(1)
PY
}

test_audit_failure_prefers_targeted_cleanup_before_reset() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql dev_over "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "1" "audit should fail for remediation-order probe"
    if assert_cleanup_remediation_precedes_reset "$output"; then
        pass "audit failure should recommend targeted stale cleanup before full reset"
    else
        fail "audit failure should recommend cleanup_dev_orphans --apply before local reset"
    fi
}

test_audit_queries_contract_owned_tables_and_hostname_pattern() {
    local tmp_dir output sql
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql pass "$tmp_dir")"
    sql="$(cat "$tmp_dir/psql.stdin")"

    assert_contains "$sql" "JOIN customers" \
        "audit should query customers for canonical seed emails"
    assert_contains "$sql" "JOIN customer_tenants" \
        "audit should query customer_tenants for seed tenant counts"
    assert_contains "$sql" "COUNT(customer_tenants.tenant_id)::bigint" \
        "audit should count tenant rows using the schema-owned tenant_id column"
    assert_not_contains "$sql" "customer_tenants.id" \
        "audit should not count a nonexistent customer_tenants.id column"
    assert_contains "$sql" "customer_tenants.tier = 'active'" \
        "audit should count only active seed tenants using the schema-owned tier column"
    assert_not_contains "$sql" "customer_tenants.status" \
        "audit should not query a nonexistent customer_tenants.status column"
    assert_contains "$sql" "FROM vm_inventory" \
        "audit should query vm_inventory for synthetic VM active rows"
    assert_contains "$sql" "hostname LIKE :'synthetic_vm_hostname_like'" \
        "audit should query the contract synthetic VM hostname pattern via psql variable"
    assert_contains "$output" "Local dev state audit passed" \
        "audit should report success after checking all rows"
}

test_audit_queries_stale_fixture_contract_without_parallel_prefix_owner() {
    local tmp_dir output sql script_text
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_audit_with_mock_psql pass "$tmp_dir")"
    sql="$(cat "$tmp_dir/psql.stdin")"
    script_text="$(cat "$REPO_ROOT/scripts/dev_state_audit.sh")"

    assert_contains "$sql" "source scripts/lib/stale_fixture_contract.sh" \
        "audit SQL should identify the stale fixture prefix source owner"
    assert_contains "$sql" "tenant_id LIKE prefix || '%'" \
        "audit SQL should match stale fixture tenants through the prefix contract"
    assert_contains "$sql" "VALUES ('e2e-'),('dash-'),('onboard-')" \
        "audit SQL should receive the current Stage 1 prefix contract values"
    assert_contains "$script_text" "stale_fixture_prefix_sql_values" \
        "audit script should consume stale_fixture_prefix_sql_values instead of owning a prefix list"
    assert_not_contains "$script_text" "STALE_FIXTURE_INDEX_PREFIXES=(" \
        "audit script should not define a parallel stale fixture prefix array"
    assert_contains "$output" "Local dev state audit passed" \
        "audit should report success after checking contract-owned stale prefix SQL"
}

test_audit_passes_at_canonical_counts
test_audit_passes_observed_canonical_clean_seed_rows
test_audit_fails_when_shared_seed_exceeds_threshold
test_audit_fails_when_free_seed_exceeds_threshold
test_audit_fails_when_synthetic_vm_rows_are_active
test_audit_fails_when_stale_fixture_tenants_exist
test_audit_fails_with_shared_db_access_message_when_database_unavailable
test_audit_failure_prefers_targeted_cleanup_before_reset
test_audit_queries_contract_owned_tables_and_hostname_pattern
test_audit_queries_stale_fixture_contract_without_parallel_prefix_owner

run_test_summary
