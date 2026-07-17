#!/usr/bin/env bash
# Regression harness for the future scripts/purge_dev_state.sh operator script.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PURGE_SCRIPT="$REPO_ROOT/scripts/purge_dev_state.sh"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

TARGET_TENANTS=(
    "e2e-retro-old"
    "dash-retro-old"
    "smoke-retro-old"
    "searchauthidx-retro-old"
    "lifecycidx-retro-old"
    "idxfilterretro"
    "stage5retro"
    "idxdetail-retro-old"
)

PROTECTED_DEV_TENANTS=(
    "test-index"
    "customer-owned"
)

BASE_DATABASE_URL="${DATABASE_URL:-postgres://griddle:griddle_local@127.0.0.1:5432/fjcloud_test}"
TEST_DATABASE_URL=""

cleanup_isolated_database() {
    if [ -n "$TEST_DATABASE_URL" ]; then
        sqlx database drop --database-url "$TEST_DATABASE_URL" -y >/dev/null 2>&1 || true
    fi
}

setup_isolated_database() {
    if ! command -v sqlx >/dev/null 2>&1; then
        echo "ERROR: sqlx-cli is required for purge_dev_state_test.sh" >&2
        exit 1
    fi
    if ! command -v psql >/dev/null 2>&1; then
        echo "ERROR: psql is required for purge_dev_state_test.sh" >&2
        exit 1
    fi

    local db_url_without_query db_url_query db_url_prefix db_name
    db_url_without_query="${BASE_DATABASE_URL%%\?*}"
    db_url_query=""
    if [[ "$BASE_DATABASE_URL" == *\?* ]]; then
        db_url_query="?${BASE_DATABASE_URL#*\?}"
    fi
    db_url_prefix="${db_url_without_query%/*}"
    if [[ "$db_url_prefix" == "$db_url_without_query" ]]; then
        echo "ERROR: could not parse database name from DATABASE_URL: $BASE_DATABASE_URL" >&2
        exit 1
    fi

    db_name="fjcloud_purge_dev_state_test_${RANDOM}_$$"
    TEST_DATABASE_URL="${db_url_prefix}/${db_name}${db_url_query}"

    sqlx database drop --database-url "$TEST_DATABASE_URL" -y >/dev/null 2>&1 || true
    sqlx database create --database-url "$TEST_DATABASE_URL"
    sqlx migrate run --source "$REPO_ROOT/infra/migrations" --database-url "$TEST_DATABASE_URL" >/dev/null
}

psql_query() {
    PSQLRC=/dev/null psql "$TEST_DATABASE_URL" -v ON_ERROR_STOP=1 -At "$@"
}

seed_fixture_state() {
    psql_query <<'SQL' >/dev/null
SET client_min_messages TO WARNING;
TRUNCATE index_replicas, customer_tenants, customer_deployments, customers, vm_inventory RESTART IDENTITY CASCADE;

WITH dev_customer AS (
    INSERT INTO customers (name, email)
    VALUES ('Dev Fixture Customer', 'dev@example.com')
    RETURNING id
),
other_customer AS (
    INSERT INTO customers (name, email)
    VALUES ('Other Fixture Customer', 'other@example.com')
    RETURNING id
),
dev_deployment AS (
    INSERT INTO customer_deployments (customer_id, node_id, region, vm_type, vm_provider, status)
    SELECT id, 'dev-retro-node', 'us-east-1', 'local-dev', 'local', 'running'
    FROM dev_customer
    RETURNING id, customer_id
),
other_deployment AS (
    INSERT INTO customer_deployments (customer_id, node_id, region, vm_type, vm_provider, status)
    SELECT id, 'other-retro-node', 'us-east-1', 'local-dev', 'local', 'running'
    FROM other_customer
    RETURNING id, customer_id
),
primary_vm AS (
    INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url)
    VALUES (
        '11111111-1111-4111-8111-111111111111',
        'us-east-1',
        'local',
        'purge-test-primary',
        'http://127.0.0.1:7700'
    )
    RETURNING id
),
replica_vm AS (
    INSERT INTO vm_inventory (id, region, provider, hostname, flapjack_url)
    VALUES (
        '22222222-2222-4222-8222-222222222222',
        'us-west-2',
        'local',
        'purge-test-replica',
        'http://127.0.0.1:7701'
    )
    RETURNING id
),
seeded_tenants AS (
    INSERT INTO customer_tenants (customer_id, tenant_id, deployment_id)
    SELECT dev_deployment.customer_id, tenant_id, dev_deployment.id
    FROM dev_deployment
    CROSS JOIN (
        VALUES
            ('e2e-retro-old'),
            ('dash-retro-old'),
            ('smoke-retro-old'),
            ('searchauthidx-retro-old'),
            ('lifecycidx-retro-old'),
            ('idxfilterretro'),
            ('stage5retro'),
            ('idxdetail-retro-old'),
            ('test-index'),
            ('customer-owned')
    ) AS dev_tenants(tenant_id)
    UNION ALL
    SELECT other_deployment.customer_id, tenant_id, other_deployment.id
    FROM other_deployment
    CROSS JOIN (
        VALUES
            ('e2e-retro-other')
    ) AS other_tenants(tenant_id)
    RETURNING customer_id, tenant_id
)
INSERT INTO index_replicas (customer_id, tenant_id, primary_vm_id, replica_vm_id, replica_region, status)
SELECT seeded_tenants.customer_id,
       seeded_tenants.tenant_id,
       primary_vm.id,
       replica_vm.id,
       'us-west-2',
       'active'
FROM seeded_tenants
CROSS JOIN primary_vm
CROSS JOIN replica_vm
JOIN (
    VALUES
        ('e2e-retro-old'),
        ('customer-owned'),
        ('e2e-retro-other')
) AS replica_tenants(tenant_id)
  ON replica_tenants.tenant_id = seeded_tenants.tenant_id;
SQL
}

tenant_snapshot() {
    psql_query <<'SQL'
SELECT customers.email || '|' || customer_tenants.tenant_id
FROM customer_tenants
JOIN customers ON customers.id = customer_tenants.customer_id
ORDER BY customers.email, customer_tenants.tenant_id;
SQL
}

replica_snapshot() {
    psql_query <<'SQL'
SELECT customers.email || '|' || index_replicas.tenant_id || '|' || index_replicas.replica_region
FROM index_replicas
JOIN customers ON customers.id = index_replicas.customer_id
ORDER BY customers.email, index_replicas.tenant_id, index_replicas.replica_region;
SQL
}

assert_target_lines_present() {
    local output="$1" verb="$2" expected_lines actual_lines tenant
    expected_lines="$(
        for tenant in "${TARGET_TENANTS[@]}"; do
            printf '%s|%s|dev@example.com\n' "$verb" "$tenant"
        done | LC_ALL=C sort
    )"
    actual_lines="$(printf '%s\n' "$output" | grep -E "^${verb}\\|" | LC_ALL=C sort || true)"

    assert_eq "$actual_lines" "$expected_lines" \
        "${verb} output should exactly match targeted dev@example.com structured lines"

    for tenant in "${TARGET_TENANTS[@]}"; do
        assert_exact_line_present "$output" "${verb}|${tenant}|dev@example.com" \
            "${verb} output should include exact ${tenant} line for dev@example.com"
    done
}

assert_exact_line_present() {
    local output="$1" expected_line="$2" msg="$3"
    if printf '%s\n' "$output" | grep -Fx -- "$expected_line" >/dev/null; then
        pass "$msg"
    else
        fail "$msg (expected exact line '$expected_line')"
    fi
}

assert_structured_lines_absent_for_verb() {
    local output="$1" verb="$2" msg="$3"
    if printf '%s\n' "$output" | grep -E "^${verb}\\|" >/dev/null; then
        fail "$msg (unexpected ${verb}| structured line found)"
    else
        pass "$msg"
    fi
}

assert_protected_lines_absent() {
    local output="$1" verb="$2" tenant
    for tenant in "${PROTECTED_DEV_TENANTS[@]}"; do
        assert_not_contains "$output" "${verb}|${tenant}|dev@example.com" \
            "${verb} output should not include protected ${tenant}"
    done
    assert_not_contains "$output" "${verb}|e2e-retro-other|other@example.com" \
        "${verb} output should not include same-prefix tenant for another customer"
}

run_purge() {
    DATABASE_URL="$TEST_DATABASE_URL" bash "$PURGE_SCRIPT" "$@" 2>&1
}

run_purge_without_database_env() {
    DATABASE_URL="" bash "$PURGE_SCRIPT" "$@" 2>&1
}

test_default_dry_run_reports_targets_without_mutating_rows() {
    local before after before_replicas after_replicas output exit_code=0
    seed_fixture_state
    before="$(tenant_snapshot)"
    before_replicas="$(replica_snapshot)"

    output="$(run_purge)" || exit_code=$?

    assert_eq "$exit_code" "0" "purge dry-run should exit 0"
    if [ "$exit_code" != "0" ]; then
        return
    fi

    after="$(tenant_snapshot)"
    after_replicas="$(replica_snapshot)"
    assert_target_lines_present "$output" "would-prune"
    assert_structured_lines_absent_for_verb "$output" "pruned" \
        "purge dry-run should not emit execute-mode structured output"
    assert_protected_lines_absent "$output" "would-prune"
    assert_eq "$after" "$before" "purge dry-run should leave exact tenant rows unchanged"
    assert_eq "$after_replicas" "$before_replicas" \
        "purge dry-run should leave exact replica rows unchanged"
}

test_execute_prunes_only_targeted_dev_rows() {
    local output exit_code=0 remaining expected_remaining remaining_replicas expected_replicas
    seed_fixture_state

    output="$(run_purge --execute)" || exit_code=$?
    expected_remaining="$(cat <<'EOF'
dev@example.com|customer-owned
dev@example.com|test-index
other@example.com|e2e-retro-other
EOF
)"
    expected_replicas="$(cat <<'EOF'
dev@example.com|customer-owned|us-west-2
other@example.com|e2e-retro-other|us-west-2
EOF
)"

    assert_eq "$exit_code" "0" "purge execute should exit 0"
    if [ "$exit_code" != "0" ]; then
        return
    fi

    remaining="$(tenant_snapshot)"
    remaining_replicas="$(replica_snapshot)"
    assert_target_lines_present "$output" "pruned"
    assert_structured_lines_absent_for_verb "$output" "would-prune" \
        "purge execute should not emit dry-run structured output"
    assert_protected_lines_absent "$output" "pruned"
    assert_eq "$remaining" "$expected_remaining" \
        "purge execute should delete only targeted dev@example.com fixture tenants"
    assert_eq "$remaining_replicas" "$expected_replicas" \
        "purge execute should delete only replica rows owned by targeted dev@example.com tenants"
}

test_execute_is_idempotent_after_first_prune() {
    local first second exit_code=0 remaining expected_remaining remaining_replicas expected_replicas
    seed_fixture_state

    first="$(run_purge --execute)" || exit_code=$?
    assert_eq "$exit_code" "0" "first purge execute should exit 0"
    if [ "$exit_code" != "0" ]; then
        return
    fi
    assert_target_lines_present "$first" "pruned"

    exit_code=0
    second="$(run_purge --execute)" || exit_code=$?
    remaining="$(tenant_snapshot)"
    expected_remaining="$(cat <<'EOF'
dev@example.com|customer-owned
dev@example.com|test-index
other@example.com|e2e-retro-other
EOF
)"
    expected_replicas="$(cat <<'EOF'
dev@example.com|customer-owned|us-west-2
other@example.com|e2e-retro-other|us-west-2
EOF
)"

    assert_eq "$exit_code" "0" "second purge execute should exit 0"
    assert_not_contains "$second" "pruned|" \
        "second purge execute should report no additional pruned tenant rows"
    assert_structured_lines_absent_for_verb "$second" "would-prune" \
        "second purge execute should not emit dry-run structured output"
    assert_eq "$remaining" "$expected_remaining" \
        "second purge execute should leave protected tenants intact"
    remaining_replicas="$(replica_snapshot)"
    assert_eq "$remaining_replicas" "$expected_replicas" \
        "second purge execute should leave protected replica rows intact"
}

test_database_url_override_feeds_shared_access_seam() {
    local before after output exit_code=0
    seed_fixture_state
    before="$(tenant_snapshot)"

    output="$(run_purge_without_database_env --database-url "$TEST_DATABASE_URL" --dry-run)" || exit_code=$?

    assert_eq "$exit_code" "0" "purge --database-url dry-run should exit 0 without DATABASE_URL env"
    if [ "$exit_code" != "0" ]; then
        return
    fi

    after="$(tenant_snapshot)"
    assert_target_lines_present "$output" "would-prune"
    assert_eq "$after" "$before" "purge --database-url dry-run should not mutate rows"
}

test_unknown_or_malformed_arguments_exit_2() {
    local output exit_code=0

    output="$(run_purge --wat)" || exit_code=$?
    assert_eq "$exit_code" "2" "purge unknown flag should exit 2"
    assert_contains "$output" "Unknown argument: --wat" \
        "purge unknown flag should name rejected argument"

    exit_code=0
    output="$(run_purge --database-url)" || exit_code=$?
    assert_eq "$exit_code" "2" "purge missing database URL value should exit 2"
    assert_contains "$output" "Missing value for --database-url" \
        "purge missing database URL value should explain malformed argument"
}

assert_conflicting_mode_flags_rejected() {
    local first_flag="$1" second_flag="$2" label="$3"
    local before after output exit_code=0

    seed_fixture_state
    before="$(tenant_snapshot)"

    output="$(run_purge "$first_flag" "$second_flag")" || exit_code=$?
    after="$(tenant_snapshot)"

    assert_eq "$exit_code" "2" "purge conflicting mode flags should exit 2 (${label})"
    assert_contains "$output" "Conflicting mode flags: --dry-run and --execute" \
        "purge conflicting mode flags should explain rejected mode combination (${label})"
    assert_eq "$after" "$before" \
        "purge conflicting mode flags should leave tenant rows unchanged (${label})"
}

test_conflicting_mode_flags_exit_2_without_mutating_rows() {
    assert_conflicting_mode_flags_rejected "--dry-run" "--execute" "dry-run then execute"
    assert_conflicting_mode_flags_rejected "--execute" "--dry-run" "execute then dry-run"
}

test_missing_database_url_fails_with_shared_diagnostic() {
    local output exit_code=0

    output="$(run_purge_without_database_env)" || exit_code=$?

    assert_ne "$exit_code" "0" "purge should fail when DATABASE_URL is empty"
    assert_contains "$output" "DATABASE_URL is not set" \
        "purge should reuse shared database-access missing-DATABASE_URL diagnostic"
}

setup_isolated_database
trap cleanup_isolated_database EXIT

test_default_dry_run_reports_targets_without_mutating_rows
test_execute_prunes_only_targeted_dev_rows
test_execute_is_idempotent_after_first_prune
test_database_url_override_feeds_shared_access_seam
test_unknown_or_malformed_arguments_exit_2
test_conflicting_mode_flags_exit_2_without_mutating_rows
test_missing_database_url_fails_with_shared_diagnostic

run_test_summary
