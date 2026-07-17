#!/usr/bin/env bash
# Tests for scripts/cleanup_dev_orphans.sh: local-only stale fixture row cleanup.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLEANUP_SCRIPT="$REPO_ROOT/scripts/cleanup_dev_orphans.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

write_mock_psql_for_cleanup() {
    local path="$1" log_path="$2"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cat >> "__LOG_PATH__"
printf '\n--ARGS:%s\n' "$*" >> "__LOG_PATH__"
case " $* " in
    *" apply_cleanup=1 "*)
        count_file="${MOCK_CLEANUP_COUNT_FILE:?}"
        count=0
        if [ -f "$count_file" ]; then
            count="$(cat "$count_file")"
        fi
        if [ "$count" = "0" ]; then
            printf 'mode|apply\nstale_tenant|dash-old|customer-a|deployment-shared\nstale_tenant|e2e-old|customer-a|deployment-stale\nstale_tenant|onboard-old|customer-a|deployment-onboard\nprotected_tenant|logs-keep|customer-a|deployment-logs\nprotected_tenant|stage5syn-proof-keep|customer-a|deployment-proof\nnon_target_tenant|admin-quota-index-old|customer-b|deployment-shared\nnon_target_tenant|cold-customer-old|customer-b|deployment-shared\nnon_target_tenant|customer-owned|customer-b|deployment-shared\nnon_target_tenant|free-test-index|customer-b|deployment-shared\nnon_target_tenant|journey-old|customer-b|deployment-shared\nnon_target_tenant|manual-iso-old|customer-b|deployment-shared\nnon_target_tenant|test-index|customer-b|deployment-shared\nnon_target_tenant|test-index-eu|customer-b|deployment-shared\nexclusive_deployment|deployment-stale|node-stale\nsynthetic_vm|vm-stale|e2e-seed-old\napplied|targeted_tenants|3\napplied|exclusive_deployments|1\napplied|synthetic_vms|1\n'
            printf '1' > "$count_file"
        else
            printf 'mode|apply\napplied|targeted_tenants|0\napplied|exclusive_deployments|0\napplied|synthetic_vms|0\n'
        fi
        ;;
    *)
        printf 'mode|dry-run\nstale_tenant|dash-old|customer-a|deployment-shared\nstale_tenant|e2e-old|customer-a|deployment-stale\nstale_tenant|onboard-old|customer-a|deployment-onboard\nprotected_tenant|logs-keep|customer-a|deployment-logs\nprotected_tenant|stage5syn-proof-keep|customer-a|deployment-proof\nnon_target_tenant|admin-quota-index-old|customer-b|deployment-shared\nnon_target_tenant|cold-customer-old|customer-b|deployment-shared\nnon_target_tenant|customer-owned|customer-b|deployment-shared\nnon_target_tenant|free-test-index|customer-b|deployment-shared\nnon_target_tenant|journey-old|customer-b|deployment-shared\nnon_target_tenant|manual-iso-old|customer-b|deployment-shared\nnon_target_tenant|test-index|customer-b|deployment-shared\nnon_target_tenant|test-index-eu|customer-b|deployment-shared\nexclusive_deployment|deployment-stale|node-stale\nsynthetic_vm|vm-stale|e2e-seed-old\nwould_delete|targeted_tenants|3\nwould_delete|exclusive_deployments|1\nwould_delete|synthetic_vms|1\n'
        ;;
esac
MOCK
    sed -i.bak "s|__LOG_PATH__|$log_path|g" "$path"
    rm -f "$path.bak"
    chmod +x "$path"
}

run_cleanup_with_mock_psql() {
    local tmp_dir="$1"
    shift
    mkdir -p "$tmp_dir/bin"
    write_mock_psql_for_cleanup "$tmp_dir/bin/psql" "$tmp_dir/psql.stdin"

    PATH="$tmp_dir/bin:$PATH" \
    DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
    MOCK_CLEANUP_COUNT_FILE="$tmp_dir/apply-count" \
        bash "$CLEANUP_SCRIPT" "$@" 2>&1
}

test_default_dry_run_prints_targeted_plan_without_apply() {
    local tmp_dir output exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_cleanup_with_mock_psql "$tmp_dir")" || exit_code=$?

    assert_eq "$exit_code" "0" "cleanup dry-run should exit 0"
    assert_contains "$output" "[cleanup-dev-orphans] Mode: dry-run" \
        "dry-run should report mode"
    assert_contains "$output" "stale_tenant|e2e-old|customer-a|deployment-stale" \
        "dry-run should print exact stale tenant rows"
    assert_contains "$output" "stale_tenant|dash-old|customer-a|deployment-shared" \
        "dry-run should print dash stale tenant rows"
    assert_contains "$output" "stale_tenant|onboard-old|customer-a|deployment-onboard" \
        "dry-run should print onboarding stale tenant rows"
    assert_contains "$output" "would_delete|targeted_tenants|3" \
        "dry-run should print targeted tenant count"
    assert_not_contains "$output" "applied|" \
        "dry-run should not execute apply summaries"
}

test_apply_is_explicit_and_second_apply_is_idempotent() {
    local tmp_dir first second exit_code=0
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    first="$(run_cleanup_with_mock_psql "$tmp_dir" --apply)" || exit_code=$?
    assert_eq "$exit_code" "0" "first apply should exit 0"
    assert_contains "$first" "[cleanup-dev-orphans] Mode: apply" \
        "apply should report explicit apply mode"
    assert_contains "$first" "applied|targeted_tenants|3" \
        "first apply should delete targeted tenants"
    assert_contains "$first" "applied|exclusive_deployments|1" \
        "first apply should delete only exclusive deployments"

    exit_code=0
    second="$(run_cleanup_with_mock_psql "$tmp_dir" --apply)" || exit_code=$?
    assert_eq "$exit_code" "0" "second apply should exit 0"
    assert_contains "$second" "applied|targeted_tenants|0" \
        "second apply should be idempotent"
    assert_contains "$second" "applied|exclusive_deployments|0" \
        "second apply should leave no exclusive deployments after first apply"
}

test_unknown_flag_exits_2() {
    local output exit_code=0

    output="$(bash "$CLEANUP_SCRIPT" --wat 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "2" "unknown flag should exit 2"
    assert_contains "$output" "Unknown argument: --wat" \
        "unknown flag should name the rejected flag"
}

test_missing_database_uses_shared_db_access_diagnostics() {
    local output exit_code=0

    output="$(DATABASE_URL="" bash "$CLEANUP_SCRIPT" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" "cleanup should fail when database access is unavailable"
    assert_contains "$output" "DATABASE_URL is not set" \
        "cleanup should reuse shared local DB access missing-DATABASE_URL message"
}

test_sql_plan_is_narrow_fk_safe_and_contract_owned() {
    local tmp_dir output sql
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_cleanup_with_mock_psql "$tmp_dir" --apply)"
    sql="$(cat "$tmp_dir/psql.stdin")"

    assert_contains "$sql" "source scripts/lib/stale_fixture_contract.sh" \
        "SQL should identify the stale-prefix source owner"
    assert_contains "$sql" "source scripts/lib/local_seed_contract.sh" \
        "SQL should identify the synthetic VM hostname source owner"
    assert_contains "$sql" "tenant_id LIKE prefix || '%'" \
        "SQL should target only known stale fixture prefixes"
    assert_contains "$sql" "VALUES ('e2e-'),('dash-'),('onboard-');" \
        "SQL should allowlist only current stale fixture prefixes"
    assert_not_contains "$sql" "('manual-iso-')" \
        "SQL should not target stale prefixes without current shared fixture creators"
    assert_not_contains "$sql" "('test-index')" \
        "SQL should not target canonical local seed indexes"
    assert_not_contains "$sql" "('free-test-index')" \
        "SQL should not target free-plan canonical local seed indexes"
    assert_not_contains "$sql" "('journey-')" \
        "SQL should not target unique-user customer journey indexes"
    assert_not_contains "$sql" "('cold-customer-')" \
        "SQL should not target unique-user cold customer indexes"
    assert_not_contains "$sql" "('admin-quota-index-')" \
        "SQL should not target unique-user admin quota indexes"
    assert_contains "$sql" "hostname LIKE :'synthetic_vm_hostname_like'" \
        "SQL should use the local seed synthetic VM pattern"
    assert_contains "$sql" "NOT EXISTS" \
        "SQL should prove exclusive deployments before deleting them"
    assert_contains "$sql" "DELETE FROM index_replicas" \
        "SQL should clear index_replicas before tenant and VM deletion"
    assert_contains "$sql" "DELETE FROM restore_jobs" \
        "SQL should clear restore_jobs before snapshot deletion"
    assert_contains "$sql" "UPDATE customer_tenants" \
        "SQL should clear tenant snapshot and VM references before deletes"
    assert_contains "$sql" "DELETE FROM cold_snapshots" \
        "SQL should delete cold snapshots after references are cleared"
    assert_contains "$sql" "DELETE FROM index_migrations" \
        "SQL should clear migration VM references before VM deletion"
    assert_contains "$sql" "DELETE FROM customer_tenants" \
        "SQL should delete targeted tenants before deployments"
    assert_contains "$sql" "DELETE FROM customer_deployments" \
        "SQL should delete only exclusive targeted deployments"
    assert_contains "$sql" "DELETE FROM vm_inventory" \
        "SQL should delete synthetic VM rows after dependents are clear"
    assert_not_contains "$sql" "tenant_id LIKE '%e2e%'" \
        "SQL should avoid broad contains-match tenant deletion"
    assert_contains "$output" "protected_tenant|logs-keep" \
        "plan should show proof/log names remain non-target rows"
    assert_contains "$output" "non_target_tenant|customer-owned" \
        "plan should show non-matching customer rows remain untouched"
    assert_contains "$output" "non_target_tenant|test-index|customer-b" \
        "plan should keep canonical local seed primary index rows"
    assert_contains "$output" "non_target_tenant|test-index-eu|customer-b" \
        "plan should keep canonical local seed regional index rows"
    assert_contains "$output" "non_target_tenant|free-test-index|customer-b" \
        "plan should keep canonical local seed free-plan index rows"
    assert_contains "$output" "non_target_tenant|journey-old|customer-b" \
        "plan should keep unique-user journey index rows"
    assert_contains "$output" "non_target_tenant|cold-customer-old|customer-b" \
        "plan should keep unique-user cold-customer index rows"
    assert_contains "$output" "non_target_tenant|admin-quota-index-old|customer-b" \
        "plan should keep unique-user admin quota index rows"
    assert_contains "$output" "non_target_tenant|manual-iso-old|customer-b" \
        "plan should keep stale prefixes without current shared fixture creators"
}

test_sql_plan_keeps_temp_tables_alive_for_autocommit_psql() {
    local tmp_dir output sql
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    output="$(run_cleanup_with_mock_psql "$tmp_dir")"
    sql="$(cat "$tmp_dir/psql.stdin")"

    assert_contains "$sql" "BEGIN;" \
        "SQL should begin one transaction before ON COMMIT DROP temp tables"
    assert_contains "$sql" "COMMIT;" \
        "SQL should commit after all temp-table consumers have run"
    assert_contains "$sql" "CREATE TEMP TABLE cleanup_stale_prefixes(prefix text PRIMARY KEY) ON COMMIT DROP;" \
        "SQL should still drop the prefix table at transaction end"
    assert_contains "$output" "would_delete|targeted_tenants|3" \
        "dry-run should still execute the plan"
}

test_default_dry_run_prints_targeted_plan_without_apply
test_apply_is_explicit_and_second_apply_is_idempotent
test_unknown_flag_exits_2
test_missing_database_uses_shared_db_access_diagnostics
test_sql_plan_is_narrow_fk_safe_and_contract_owned
test_sql_plan_keeps_temp_tables_alive_for_autocommit_psql

run_test_summary
