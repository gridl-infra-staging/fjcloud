#!/usr/bin/env bash
# Tests for scripts/seed_local.sh: valid defaults and local email verification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

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
# shellcheck source=lib/test_helpers.sh
source "$SCRIPT_DIR/lib/test_helpers.sh"

# shellcheck source=lib/seed_local_mocks.sh
source "$SCRIPT_DIR/lib/seed_local_mocks.sh"
# shellcheck source=../lib/flapjack_regions.sh
source "$REPO_ROOT/scripts/lib/flapjack_regions.sh"

# Keep topology-dependent tests hermetic even if the caller exported local-dev
# multi-region toggles in their shell session.
unset FLAPJACK_REGIONS
unset FLAPJACK_SINGLE_INSTANCE

test_uses_valid_default_email_and_verifies_seed_user() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should seed successfully with local verification enabled"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" '"email":"dev@example.com"' \
        "should register the seeded user with a valid default email"
    assert_contains "$curl_calls" '"flapjack_url":"http://localhost:7701"' \
        "should attach the reachable local flapjack URL when seeding the default index"

    local psql_calls
    psql_calls=$(cat "$psql_log")
    assert_contains "$psql_calls" "seed_email=dev@example.com" \
        "should verify the seeded user email in the local database"

    local sql
    sql=$(cat "$psql_stdin" 2>/dev/null || true)
    assert_contains "$sql" "UPDATE customers" \
        "should run the customer email verification update"
    assert_contains "$output" "Verified user email: dev@example.com" \
        "should log successful local email verification"
}

test_seeds_multi_region_inventory_and_multi_user_indexes() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should seed local dataset end-to-end for Stage 2 defaults"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    local current_month
    current_month="$(date -u +%Y-%m)"
    assert_contains "$curl_calls" '"email":"dev@example.com"' \
        "should seed the shared-plan user"
    assert_contains "$curl_calls" '"email":"free@example.com"' \
        "should seed the free-plan user"
    assert_contains "$curl_calls" "/admin/tenants/customer-dev" \
        "should call the shared user plan-upgrade endpoint"
    assert_contains "$curl_calls" '{"billing_plan":"shared"}' \
        "should upgrade only the shared-plan seed user"
    assert_contains "$curl_calls" '/admin/tenants/customer-dev/indexes' \
        "should call shared user index seeding"
    assert_contains "$curl_calls" '{"name":"test-index","region":"us-east-1","flapjack_url":"http://127.0.0.1:7700"}' \
        "should create the shared user us-east-1 index against the region-specific flapjack URL"
    assert_contains "$curl_calls" '{"name":"test-index-eu","region":"eu-west-1","flapjack_url":"http://127.0.0.1:7701"}' \
        "should create the shared user eu-west-1 index against the region-specific flapjack URL"
    assert_contains "$curl_calls" '{"name":"test-index-eu2","region":"eu-central-1","flapjack_url":"http://127.0.0.1:7702"}' \
        "should create the shared user eu-central-1 index against the region-specific flapjack URL"
    assert_contains "$curl_calls" '/admin/tenants/customer-free/indexes' \
        "should call free user index seeding"
    assert_contains "$curl_calls" '{"name":"free-test-index","region":"us-east-1","flapjack_url":"http://127.0.0.1:7700"}' \
        "should create the free user index in us-east-1 against the region-specific flapjack URL"
    assert_contains "$curl_calls" "/indexes/test-index/documents" \
        "should seed docs for shared us-east-1 index"
    assert_contains "$curl_calls" "/indexes/test-index-eu/documents" \
        "should seed docs for shared eu-west-1 index"
    assert_contains "$curl_calls" "/indexes/test-index-eu2/documents" \
        "should seed docs for shared eu-central-1 index"
    assert_contains "$curl_calls" "/indexes/free-test-index/documents" \
        "should seed docs for the free-plan index"
    assert_contains "$curl_calls" "http://127.0.0.1:3001/indexes -H Content-Type: application/json -H Authorization: Bearer dev-token" \
        "should verify seeded indexes for the shared user"
    assert_contains "$curl_calls" "http://127.0.0.1:3001/indexes -H Content-Type: application/json -H Authorization: Bearer free-token" \
        "should verify seeded indexes for the free user"
    assert_contains "$curl_calls" "http://127.0.0.1:3001/billing/estimate?month=${current_month} -H Content-Type: application/json -H Authorization: Bearer dev-token" \
        "should run a shared-plan estimate smoke check for the current UTC month"

    local sql
    sql=$(cat "$psql_stdin" 2>/dev/null || true)
    assert_contains "$sql" "INSERT INTO vm_inventory" \
        "should pre-seed vm inventory before index creation"
    assert_contains "$sql" "ON CONFLICT (hostname) DO UPDATE" \
        "should upsert vm inventory hostnames"
    assert_contains "$sql" "provider = EXCLUDED.provider" \
        "should reconcile provider on hostname conflicts"
    assert_contains "$sql" "region = EXCLUDED.region" \
        "should reconcile region on hostname conflicts"
    assert_contains "$sql" "capacity = EXCLUDED.capacity" \
        "should reconcile capacity on hostname conflicts"
    assert_contains "$sql" '"cpu_weight":4.0' \
        "should seed the runtime shared-VM cpu_weight capacity contract"
    assert_contains "$sql" '"query_rps":500.0' \
        "should seed the runtime shared-VM throughput capacity contract"
    assert_contains "$sql" "current_load" \
        "should seed fresh current_load metadata for pre-seeded VMs"
    assert_contains "$sql" "load_scraped_at" \
        "should mark pre-seeded VMs as freshly scraped for placement"
    assert_contains "$sql" '"cpu_weight":0.0' \
        "should initialize pre-seeded VM load to the zero resource vector"
    assert_contains "$sql" "local-dev-us-east-1" \
        "should seed vm inventory for us-east-1"
    assert_contains "$sql" "local-dev-eu-west-1" \
        "should seed vm inventory for eu-west-1"
    assert_contains "$sql" "local-dev-eu-central-1" \
        "should seed vm inventory for eu-central-1"
    assert_not_contains "$sql" "local-dev-eu-north-1" \
        "should not seed unconfigured eu-north-1 when FLAPJACK_REGIONS is authoritative"
    assert_not_contains "$sql" "local-dev-us-east-2" \
        "should not seed unconfigured us-east-2 when FLAPJACK_REGIONS is authoritative"
    assert_not_contains "$sql" "local-dev-us-west-1" \
        "should not seed unconfigured us-west-1 when FLAPJACK_REGIONS is authoritative"
    assert_contains "$sql" "status = 'decommissioned'" \
        "should decommission stale local-dev VM rows outside the configured topology"
    assert_contains "$sql" "hostname LIKE 'local-dev-%'" \
        "should limit stale VM cleanup to local-dev seed rows"
    assert_contains "$sql" "INSERT INTO usage_daily" \
        "should seed synthetic daily usage rows for local billing estimates"
    assert_contains "$sql" "ON CONFLICT (customer_id, date, region) DO UPDATE" \
        "should keep daily usage seeding idempotent across reruns"
    assert_contains "$sql" "date_trunc('month', timezone('UTC', now()))::date" \
        "should target the current UTC month for usage_daily seed rows"
    assert_contains "$sql" "WITH seed_replicas(customer_id, tenant_id, primary_region, replica_region) AS" \
        "should scope replica reset to canonical seed replicas"
    assert_contains "$sql" "UPDATE customer_tenants" \
        "should restore seeded HA tenants to their canonical primary VM"
    assert_contains "$sql" "customer_tenants.tenant_id = canonical_seed_vms.tenant_id" \
        "should only move the canonical seeded tenants during HA reset"
    assert_contains "$sql" "primary_vm.hostname = 'local-dev-' || seed_replicas.primary_region" \
        "should resolve the canonical primary VM by seeded primary region"
    assert_contains "$sql" "replica_vm.hostname = 'local-dev-' || seed_replicas.replica_region" \
        "should resolve the canonical replica VM by seeded replica region"
    assert_contains "$sql" "index_replicas.status IN ('provisioning', 'syncing', 'failed', 'suspended')" \
        "should revive failed or consumed seed replicas for repeatable HA signoff"
    assert_contains "$sql" "index_replicas.replica_region = canonical_seed_vms.replica_region" \
        "should avoid resetting unrelated replicas outside the seed targets"

    assert_contains "$output" "Verified seeded index names for dev@example.com" \
        "should validate seeded indexes for shared-plan user"
    assert_contains "$output" "Verified seeded index names for free@example.com" \
        "should validate seeded indexes for free-plan user"
    assert_contains "$output" "Verified /billing/estimate for dev@example.com (${current_month})" \
        "should verify that seeded current-month usage produces a bill estimate"
}

test_is_idempotent_on_second_run() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local first_output second_output first_exit=0 second_exit=0
    first_output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || first_exit=$?
    second_output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || second_exit=$?

    assert_eq "$first_exit" "0" "first seed run should succeed"
    assert_eq "$second_exit" "0" "second seed run should also succeed with conflicts"
    assert_contains "$second_output" "User already exists: dev@example.com" \
        "second run should handle existing shared user via login"
    assert_contains "$second_output" "User already exists: free@example.com" \
        "second run should handle existing free user via login"
    assert_contains "$second_output" "Index already exists: test-index" \
        "second run should tolerate index conflicts without failing"

    local current_month
    current_month="$(date -u +%Y-%m)"
    local usage_seed_count estimate_call_count
    usage_seed_count=$(grep -c "INSERT INTO usage_daily" "$psql_stdin" || true)
    estimate_call_count=$(grep -c "/billing/estimate?month=${current_month}" "$curl_log" || true)
    assert_eq "$usage_seed_count" "2" \
        "both runs should execute idempotent current-month usage_daily upserts"
    assert_eq "$estimate_call_count" "2" \
        "both runs should perform the shared-plan estimate smoke check"
}

test_fails_when_usage_daily_seed_sql_fails() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        MOCK_PSQL_FAIL_USAGE_DAILY="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when usage_daily seeding cannot write to the database"
    assert_contains "$output" "usage_daily seed failed for dev@example.com" \
        "should surface the usage_daily seed failure instead of continuing"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    if [[ "$curl_calls" == *"/billing/estimate?month="* ]]; then
        fail "should not run the estimate smoke check after usage_daily seeding fails"
    else
        pass "should not run the estimate smoke check after usage_daily seeding fails"
    fi
}

test_warns_when_local_email_verification_is_unavailable() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        FLAPJACK_URL="http://localhost:7700" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should continue when local email verification cannot run"
    assert_contains "$output" "WARNING: DATABASE_URL is not set" \
        "should explain why email verification was skipped"
}

test_defaults_flapjack_url_from_local_dev_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should keep seeding when flapjack is unavailable"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "http://localhost:7700/health" \
        "should probe flapjack on the local-dev default port when FLAPJACK_URL is unset"
}

test_defaults_vm_inventory_to_shared_flapjack_url_without_region_map() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$tmp_dir/psql.log" "$psql_stdin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7700" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should seed vm inventory even when FLAPJACK_REGIONS is not set explicitly"

    local sql
    sql=$(cat "$psql_stdin" 2>/dev/null || true)
    assert_contains "$sql" "local-dev-us-east-1','http://localhost:7700'" \
        "should seed us-east-1 with the shared flapjack URL in the default single-instance topology"
    assert_contains "$sql" "local-dev-eu-west-1','http://localhost:7700'" \
        "should seed eu-west-1 with the shared flapjack URL in the default single-instance topology"
    assert_contains "$sql" "local-dev-eu-central-1','http://localhost:7700'" \
        "should seed eu-central-1 with the shared flapjack URL in the default single-instance topology"
}

test_single_instance_override_ignores_region_specific_vm_inventory_urls() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$tmp_dir/psql.log" "$psql_stdin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7799" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701 eu-central-1:7702" \
        FLAPJACK_SINGLE_INSTANCE="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should keep seeding vm inventory when single-instance mode overrides FLAPJACK_REGIONS"

    local sql
    sql=$(cat "$psql_stdin")
    assert_contains "$sql" "local-dev-us-east-1','http://localhost:7799'" \
        "single-instance mode should keep us-east-1 on the shared flapjack URL"
    assert_contains "$sql" "local-dev-eu-west-1','http://localhost:7799'" \
        "single-instance mode should keep eu-west-1 on the shared flapjack URL"
    assert_contains "$sql" "local-dev-eu-central-1','http://localhost:7799'" \
        "single-instance mode should keep eu-central-1 on the shared flapjack URL"
}

test_prefers_normalized_local_dev_flapjack_url_for_local_vm_contract() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$tmp_dir/psql.log" "$psql_stdin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7799" \
        LOCAL_DEV_FLAPJACK_URL=$'  http://localhost:7701/  ' \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should seed successfully when LOCAL_DEV_FLAPJACK_URL supplies the local shared-VM endpoint"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "http://localhost:7701/health" \
        "should probe the normalized local-dev flapjack URL"
    if [[ "$curl_calls" == *"http://localhost:7799/health"* ]]; then
        fail "should ignore FLAPJACK_URL when LOCAL_DEV_FLAPJACK_URL is configured for local seeding"
    else
        pass "should ignore FLAPJACK_URL when LOCAL_DEV_FLAPJACK_URL is configured for local seeding"
    fi
    assert_contains "$curl_calls" '{"name":"test-index","region":"us-east-1","flapjack_url":"http://localhost:7701"}' \
        "should seed index payloads with the canonical local-dev flapjack URL"

    local sql
    sql=$(cat "$psql_stdin")
    assert_contains "$sql" "INSERT INTO vm_inventory" \
        "should pre-seed vm inventory rows"
    assert_contains "$sql" "'http://localhost:7701'" \
        "should seed vm inventory with the canonical local-dev flapjack URL"
    if [[ "$sql" == *"http://localhost:7701/"* ]]; then
        fail "should trim trailing slash from the local shared-VM flapjack URL before seeding vm inventory"
    else
        pass "should trim trailing slash from the local shared-VM flapjack URL before seeding vm inventory"
    fi
    assert_contains "$sql" "local-dev-us-east-1" \
        "should keep hostname contract aligned with auto_provision_shared_vm for us-east-1"
    assert_contains "$sql" "local-dev-us-west-1" \
        "should keep hostname contract aligned with auto_provision_shared_vm for us-west-1"
    assert_contains "$sql" '"cpu_weight":4.0' \
        "should seed shared-VM capacity cpu_weight aligned with API defaults"
    assert_contains "$sql" '"mem_rss_bytes":8589934592' \
        "should seed shared-VM capacity mem_rss_bytes aligned with API defaults"
    assert_contains "$output" "Flapjack reachable at http://localhost:7701" \
        "should report the canonical local flapjack URL after normalization"
}

test_preserves_api_url_override_while_loading_other_env_local_values() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    cat > "$REPO_ROOT/.env.local" <<'EOF'
API_URL=http://localhost:3998
ADMIN_KEY=file-admin-key
FLAPJACK_PORT=7711
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should allow an explicit API_URL override without dropping other .env.local values"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "http://127.0.0.1:3001/health" \
        "should preserve explicit API_URL over conflicting .env.local API_URL values"
    assert_contains "$curl_calls" "x-admin-key: file-admin-key" \
        "should still load ADMIN_KEY from .env.local when API_URL is overridden explicitly"
    assert_contains "$curl_calls" "http://localhost:7711/health" \
        "should still load FLAPJACK_PORT from .env.local when API_URL is overridden explicitly"
}

test_derives_api_url_from_env_local_api_base_url() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    cat > "$REPO_ROOT/.env.local" <<'EOF'
API_BASE_URL=http://localhost:3999
ADMIN_KEY=base-url-admin-key
EOF

    # The script will fail at the health check because the mock doesn't handle
    # port 3999 — that's fine; we only need to verify the URL derivation path.
    local output
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || true

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "http://localhost:3999/health" \
        "should derive API_URL from API_BASE_URL in .env.local when API_URL is not set"
}

test_accepts_env_local_with_comments_and_blank_lines() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    cat > "$REPO_ROOT/.env.local" <<'EOF'
# This is a comment at the top of the file

ADMIN_KEY=commented-env-admin-key
# Another comment in between assignments

FLAPJACK_PORT=7722

EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should accept .env.local files with comments and blank lines"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "x-admin-key: commented-env-admin-key" \
        "should load ADMIN_KEY from .env.local with comments"
    assert_contains "$curl_calls" "http://localhost:7722/health" \
        "should load FLAPJACK_PORT from .env.local with comments"
}

test_rejects_executable_env_local_content() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local marker_path="$tmp_dir/should-not-exist"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    cat > "$REPO_ROOT/.env.local" <<EOF
ADMIN_KEY=file-admin-key
touch "$marker_path"
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject executable shell syntax in .env.local"
    assert_contains "$output" "Unsupported syntax" \
        "should explain that only env assignments are accepted from .env.local"

    if [ -e "$marker_path" ]; then
        fail "should not execute shell commands from .env.local"
    else
        pass "should not execute shell commands from .env.local"
    fi
}

test_requires_explicit_admin_key_configuration() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should require an explicit ADMIN_KEY instead of falling back to a guessable default"
    assert_contains "$output" "ADMIN_KEY is required" \
        "should explain how to configure the admin key securely"
}

test_escapes_seed_payload_fields_and_index_path() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="test-admin-key" \
        FLAPJACK_URL="http://localhost:7701" \
        SEED_USER_NAME='Injected","billing_plan":"dedicated' \
        SEED_INDEX_NAME='folder/name' \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should continue when seed values contain JSON and path metacharacters"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    if [[ "$curl_calls" == *'"billing_plan":"dedicated"'* ]]; then
        fail "should not allow quoted seed values to inject extra JSON fields"
    else
        pass "should not allow quoted seed values to inject extra JSON fields"
    fi
    assert_contains "$curl_calls" "http://127.0.0.1:3001/indexes/folder%2Fname/documents" \
        "should URL-encode seeded index names before inserting them into request paths"
}

test_rejects_invalid_flapjack_regions_port_mapping() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="test-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701@evil.test" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject FLAPJACK_REGIONS entries that are not plain numeric ports"
    assert_contains "$output" "FLAPJACK_REGIONS entry for eu-west-1 must use a numeric TCP port" \
        "should fail closed instead of accepting a URL-injecting region mapping"

    local sql
    sql=$(cat "$psql_stdin" 2>/dev/null || true)
    if [[ "$sql" == *"evil.test"* ]]; then
        fail "should not pass an injected FLAPJACK_REGIONS host through to SQL seed data"
    else
        pass "should not pass an injected FLAPJACK_REGIONS host through to SQL seed data"
    fi
}

test_omits_flapjack_url_when_local_flapjack_is_unreachable() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="test-admin-key" \
        FLAPJACK_URL="http://localhost:7799" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should keep seeding when the local flapjack endpoint is unavailable"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    if [[ "$curl_calls" == *'"flapjack_url":"http://localhost:7799"'* ]]; then
        fail "should not send flapjack_url in the admin seed payload when flapjack health is failing"
    else
        pass "should not send flapjack_url in the admin seed payload when flapjack health is failing"
    fi
    assert_contains "$output" "Flapjack not reachable at http://localhost:7799" \
        "should still explain that search data seeding was skipped"
}

test_syncs_stripe_for_seeded_users_when_stripe_local_mode_enabled() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        STRIPE_LOCAL_MODE="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should seed successfully with STRIPE_LOCAL_MODE=1"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_contains "$curl_calls" "/admin/customers/customer-dev/sync-stripe" \
        "should call sync-stripe for the shared-plan user"
    assert_contains "$curl_calls" "/admin/customers/customer-free/sync-stripe" \
        "should call sync-stripe for the free-plan user"
    assert_contains "$output" "Stripe-synced dev@example.com" \
        "should log successful Stripe sync for the shared-plan user"
    assert_contains "$output" "Stripe-synced free@example.com" \
        "should log successful Stripe sync for the free-plan user"
}

test_skips_stripe_sync_when_stripe_local_mode_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should seed successfully without STRIPE_LOCAL_MODE"

    local curl_calls
    curl_calls=$(cat "$curl_log")
    assert_not_contains "$curl_calls" "sync-stripe" \
        "should not call sync-stripe when STRIPE_LOCAL_MODE is unset"
}

test_stripe_sync_idempotent_on_rerun() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local first_output second_output first_exit=0 second_exit=0
    first_output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        STRIPE_LOCAL_MODE="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || first_exit=$?
    second_output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        STRIPE_LOCAL_MODE="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || second_exit=$?

    assert_eq "$first_exit" "0" "first seed with Stripe sync should succeed"
    assert_eq "$second_exit" "0" "second seed with Stripe sync should succeed (already-linked path)"

    local sync_stripe_count
    sync_stripe_count=$(grep -c "sync-stripe" "$curl_log" || true)
    if [ "$sync_stripe_count" -ge 4 ]; then
        pass "both runs should call sync-stripe for both users (found $sync_stripe_count calls)"
    else
        fail "both runs should call sync-stripe for both users (expected >= 4, found $sync_stripe_count)"
    fi
}

test_fails_loudly_when_stripe_sync_returns_error() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_repo_env_file "'"$tmp_dir"'/.env.local.backup"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    mkdir -p "$tmp_dir/bin"
    backup_repo_env_file "$tmp_dir/.env.local.backup" || true
    rm -f "$REPO_ROOT/.env.local"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://127.0.0.1:3001" \
        ADMIN_KEY="local-dev-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://localhost:7701" \
        STRIPE_LOCAL_MODE="1" \
        MOCK_STRIPE_SYNC_FAIL="1" \
        bash "$REPO_ROOT/scripts/seed_local.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when Stripe sync returns an error"
    assert_contains "$output" "Stripe sync failed" \
        "should surface the Stripe sync failure with a descriptive error"
}

region_lines() {
    env -i \
        "PATH=/usr/bin:/bin:/usr/local/bin" \
        "FLAPJACK_REGIONS=${1:-}" \
        "FLAPJACK_SINGLE_INSTANCE=${2:-}" \
        bash -c '
            source "$0"
            resolve_seed_vm_regions
        ' "$REPO_ROOT/scripts/lib/flapjack_regions.sh"
}

test_seed_region_helper_keeps_legacy_single_instance_coverage() {
    local actual expected
    actual="$(region_lines "" "")"
    expected=$'us-east-1\neu-west-1\neu-central-1\neu-north-1\nus-east-2\nus-west-1'

    assert_eq "$actual" "$expected" \
        "default seed regions preserve the existing single-instance local topology"
}

test_seed_region_helper_follows_flapjack_regions_in_multi_region_mode() {
    local actual expected
    actual="$(region_lines "us-east-1:7700 eu-west-1:7701 eu-central-1:7702" "")"
    expected=$'us-east-1\neu-west-1\neu-central-1'

    assert_eq "$actual" "$expected" \
        "multi-region seed regions come only from FLAPJACK_REGIONS"
}

test_seed_region_helper_keeps_single_instance_override() {
    local actual expected
    actual="$(region_lines "us-east-1:7700 eu-west-1:7701" "1")"
    expected=$'us-east-1\neu-west-1\neu-central-1\neu-north-1\nus-east-2\nus-west-1'

    assert_eq "$actual" "$expected" \
        "FLAPJACK_SINGLE_INSTANCE keeps the legacy broad seed topology"
}

test_seed_region_helper_rejects_empty_region_entries() {
    local output exit_code=0
    output="$(region_lines ":7700" "" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "1" \
        "empty FLAPJACK_REGIONS region should fail"
    assert_contains "$output" "missing region" \
        "empty FLAPJACK_REGIONS region should explain the bad entry"
}

main() {
    echo "=== seed_local.sh tests ==="
    echo ""

    test_uses_valid_default_email_and_verifies_seed_user
    test_seeds_multi_region_inventory_and_multi_user_indexes
    test_is_idempotent_on_second_run
    test_fails_when_usage_daily_seed_sql_fails
    test_warns_when_local_email_verification_is_unavailable
    test_defaults_flapjack_url_from_local_dev_port
    test_defaults_vm_inventory_to_shared_flapjack_url_without_region_map
    test_single_instance_override_ignores_region_specific_vm_inventory_urls
    test_prefers_normalized_local_dev_flapjack_url_for_local_vm_contract
    test_preserves_api_url_override_while_loading_other_env_local_values
    test_derives_api_url_from_env_local_api_base_url
    test_accepts_env_local_with_comments_and_blank_lines
    test_rejects_executable_env_local_content
    test_requires_explicit_admin_key_configuration
    test_escapes_seed_payload_fields_and_index_path
    test_rejects_invalid_flapjack_regions_port_mapping
    test_omits_flapjack_url_when_local_flapjack_is_unreachable
    test_syncs_stripe_for_seeded_users_when_stripe_local_mode_enabled
    test_skips_stripe_sync_when_stripe_local_mode_unset
    test_stripe_sync_idempotent_on_rerun
    test_fails_loudly_when_stripe_sync_returns_error
    test_seed_region_helper_keeps_legacy_single_instance_coverage
    test_seed_region_helper_follows_flapjack_regions_in_multi_region_mode
    test_seed_region_helper_keeps_single_instance_override
    test_seed_region_helper_rejects_empty_region_entries

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
