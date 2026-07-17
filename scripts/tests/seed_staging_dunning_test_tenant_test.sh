#!/usr/bin/env bash
# Smoke tests for scripts/seed_staging_dunning_test_tenant.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEED_SCRIPT="$REPO_ROOT/scripts/seed_staging_dunning_test_tenant.sh"

source "$SCRIPT_DIR/lib/assertions.sh"
source "$SCRIPT_DIR/lib/test_helpers.sh"

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

RUN_OUTPUT=""
RUN_EXIT_CODE=0

write_secret_file() {
    local path="$1"
    cat > "$path" <<'EOF_SECRET'
FJCLOUD_TEST_TENANT_IDS=11111111-1111-1111-1111-111111111111,22222222-2222-2222-2222-222222222222
AWS_ACCESS_KEY_ID=seed-script-aws-access
AWS_SECRET_ACCESS_KEY=seed-script-aws-secret
EOF_SECRET
}

write_mock_hydrator() {
    local path="$1"
    cat > "$path" <<'EOF_HYDRATOR'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' 'export DATABASE_URL=postgres://staging.example/fjcloud'
printf '%s\n' 'export API_URL=https://api.staging.flapjack.foo'
printf '%s\n' 'export ADMIN_KEY=hydrated-staging-admin-key'
EOF_HYDRATOR
    chmod +x "$path"
}

write_mock_ssm_exec() {
    local path="$1"
    cat > "$path" <<'EOF_SSM'
#!/usr/bin/env bash
set -euo pipefail
: "${SEED_TENANT_TEST_SSM_SQL_LOG:?missing SEED_TENANT_TEST_SSM_SQL_LOG}"
: "${SEED_TENANT_ONE_STATE:?missing SEED_TENANT_ONE_STATE}"
: "${SEED_TENANT_ONE_PLAN_STATE:?missing SEED_TENANT_ONE_PLAN_STATE}"
: "${SEED_TENANT_TWO_PLAN_STATE:?missing SEED_TENANT_TWO_PLAN_STATE}"

command_text="${1:-}"
printf '%s\n' "$command_text" >> "$SEED_TENANT_TEST_SSM_SQL_LOG"

tenant_one="11111111-1111-1111-1111-111111111111"
tenant_two="22222222-2222-2222-2222-222222222222"

if [[ "$command_text" == *"$tenant_one"* ]]; then
    state="$(cat "$SEED_TENANT_ONE_STATE")"
    plan="$(cat "$SEED_TENANT_ONE_PLAN_STATE")"
    if [ "$state" = "linked" ]; then
        printf '%s\n' "${tenant_one}|alpha@example.test|active|${plan}|cus_seed_alpha"
    else
        printf '%s\n' "${tenant_one}|alpha@example.test|active|${plan}|"
    fi
    exit 0
fi

if [[ "$command_text" == *"$tenant_two"* ]]; then
    plan="$(cat "$SEED_TENANT_TWO_PLAN_STATE")"
    printf '%s\n' "${tenant_two}|beta@example.test|active|${plan}|cus_existing_beta"
    exit 0
fi

exit 0
EOF_SSM
    chmod +x "$path"
}

write_missing_tenant_ssm_exec() {
    local path="$1"
    cat > "$path" <<'EOF_SSM'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF_SSM
    chmod +x "$path"
}

write_inactive_tenant_ssm_exec() {
    local path="$1"
    cat > "$path" <<'EOF_SSM'
#!/usr/bin/env bash
set -euo pipefail
command_text="${1:-}"
tenant_one="11111111-1111-1111-1111-111111111111"
if [[ "$command_text" == *"$tenant_one"* ]]; then
    printf '%s\n' "${tenant_one}|alpha@example.test|suspended|free|"
    exit 0
fi
exit 0
EOF_SSM
    chmod +x "$path"
}

write_mock_curl() {
    local path="$1"
    cat > "$path" <<'EOF_CURL'
#!/usr/bin/env bash
set -euo pipefail
: "${SEED_TENANT_TEST_CURL_LOG:?missing SEED_TENANT_TEST_CURL_LOG}"
: "${SEED_TENANT_ONE_STATE:?missing SEED_TENANT_ONE_STATE}"

admin_key=""
request_url=""
method="GET"
request_body=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -X)
            method="$2"
            shift 2
            ;;
        -H)
            if [[ "${2:-}" == x-admin-key:* ]]; then
                admin_key="${2#x-admin-key: }"
            fi
            shift 2
            ;;
        -d|--data|--data-raw)
            request_body="$2"
            shift 2
            ;;
        http://*|https://*)
            request_url="$1"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

printf 'method=%s url=%s admin_key=%s body=%s\n' "$method" "$request_url" "$admin_key" "$request_body" >> "$SEED_TENANT_TEST_CURL_LOG"

case "$request_url" in
    */admin/tenants/11111111-1111-1111-1111-111111111111)
        printf '%s\n' 'shared' > "$SEED_TENANT_ONE_PLAN_STATE"
        printf '{"id":"11111111-1111-1111-1111-111111111111","billing_plan":"shared"}\n200'
        ;;
    */admin/tenants/22222222-2222-2222-2222-222222222222)
        printf '%s\n' 'shared' > "$SEED_TENANT_TWO_PLAN_STATE"
        printf '{"id":"22222222-2222-2222-2222-222222222222","billing_plan":"shared"}\n200'
        ;;
    */11111111-1111-1111-1111-111111111111/sync-stripe)
        printf '%s\n' 'linked' > "$SEED_TENANT_ONE_STATE"
        printf '{"message":"stripe customer created and linked","stripe_customer_id":"cus_seed_alpha"}\n200'
        ;;
    *)
        printf '{"error":"unexpected sync target"}\n500'
        ;;
esac
EOF_CURL
    chmod +x "$path"
}

run_seed_script() {
    local tmp_dir="$1"
    local secret_file="$tmp_dir/.env.secret"
    local hydrator="$tmp_dir/mock_hydrator.sh"
    local ssm_exec="$tmp_dir/mock_ssm_exec.sh"

    write_secret_file "$secret_file"
    write_mock_hydrator "$hydrator"
    write_mock_ssm_exec "$ssm_exec"
    write_mock_curl "$tmp_dir/bin/curl"
    printf '%s\n' 'missing' > "$tmp_dir/tenant_one.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_one_plan.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_two_plan.state"

    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            SEED_TENANT_TEST_SSM_SQL_LOG="$tmp_dir/sql.log" \
            SEED_TENANT_TEST_CURL_LOG="$tmp_dir/curl.log" \
            SEED_TENANT_ONE_STATE="$tmp_dir/tenant_one.state" \
            SEED_TENANT_ONE_PLAN_STATE="$tmp_dir/tenant_one_plan.state" \
            SEED_TENANT_TWO_PLAN_STATE="$tmp_dir/tenant_two_plan.state" \
            STAGING_ENV_HYDRATOR_SCRIPT="$hydrator" \
            STAGING_DB_QUERY_SCRIPT="$ssm_exec" \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$SEED_SCRIPT" --secret-file "$secret_file" 2>&1
    )" || RUN_EXIT_CODE=$?
}

test_links_only_missing_allowlisted_tenants() {
    local tmp_dir sql_log curl_log
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"

    run_seed_script "$tmp_dir"
    sql_log="$(cat "$tmp_dir/sql.log" 2>/dev/null || true)"
    curl_log="$(cat "$tmp_dir/curl.log" 2>/dev/null || true)"

    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "seed script should succeed for mixed linked/missing allowlist tenants"
    assert_contains "$RUN_OUTPUT" "tenant_id=11111111-1111-1111-1111-111111111111 email=alpha@example.test action=billing_plan_updated billing_plan=shared" "seed script should move missing allowlisted tenant onto shared billing"
    assert_contains "$RUN_OUTPUT" "tenant_id=11111111-1111-1111-1111-111111111111 email=alpha@example.test action=linked stripe_customer_id=cus_seed_alpha" "seed script should link the missing allowlisted tenant"
    assert_contains "$RUN_OUTPUT" "tenant_id=22222222-2222-2222-2222-222222222222 email=beta@example.test action=billing_plan_updated billing_plan=shared" "seed script should move already-linked allowlisted tenant onto shared billing"
    assert_contains "$RUN_OUTPUT" "tenant_id=22222222-2222-2222-2222-222222222222 email=beta@example.test action=already_linked stripe_customer_id=cus_existing_beta" "seed script should skip already-linked allowlisted tenants"
    assert_contains "$RUN_OUTPUT" "summary total=2 linked=1 already_linked=1 plan_updated=2" "seed script should emit an exact summary"
    assert_contains "$curl_log" "method=PUT url=https://api.staging.flapjack.foo/admin/tenants/11111111-1111-1111-1111-111111111111 admin_key=hydrated-staging-admin-key body={\"billing_plan\":\"shared\"}" "seed script should update the missing tenant billing plan through the admin owner"
    assert_contains "$curl_log" "method=PUT url=https://api.staging.flapjack.foo/admin/tenants/22222222-2222-2222-2222-222222222222 admin_key=hydrated-staging-admin-key body={\"billing_plan\":\"shared\"}" "seed script should update the already-linked tenant billing plan through the admin owner"
    assert_contains "$curl_log" "method=POST url=https://api.staging.flapjack.foo/admin/customers/11111111-1111-1111-1111-111111111111/sync-stripe admin_key=hydrated-staging-admin-key" "seed script should call sync-stripe with hydrated staging admin credentials"
    assert_not_contains "$curl_log" "22222222-2222-2222-2222-222222222222/sync-stripe" "seed script must not call sync-stripe for already-linked tenants"
    assert_contains "$sql_log" "11111111-1111-1111-1111-111111111111" "seed script should query the missing tenant before and after sync"
    assert_contains "$sql_log" "22222222-2222-2222-2222-222222222222" "seed script should query the already-linked tenant"
}

test_fails_when_allowlisted_tenant_is_missing() {
    local tmp_dir secret_file hydrator
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    secret_file="$tmp_dir/.env.secret"
    hydrator="$tmp_dir/mock_hydrator.sh"
    local ssm_exec="$tmp_dir/mock_ssm_exec.sh"

    write_secret_file "$secret_file"
    write_mock_hydrator "$hydrator"
    write_missing_tenant_ssm_exec "$ssm_exec"
    write_mock_curl "$tmp_dir/bin/curl"
    printf '%s\n' 'missing' > "$tmp_dir/tenant_one.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_one_plan.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_two_plan.state"

    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            SEED_TENANT_TEST_SSM_SQL_LOG="$tmp_dir/sql.log" \
            SEED_TENANT_TEST_CURL_LOG="$tmp_dir/curl.log" \
            SEED_TENANT_ONE_STATE="$tmp_dir/tenant_one.state" \
            SEED_TENANT_ONE_PLAN_STATE="$tmp_dir/tenant_one_plan.state" \
            SEED_TENANT_TWO_PLAN_STATE="$tmp_dir/tenant_two_plan.state" \
            STAGING_ENV_HYDRATOR_SCRIPT="$hydrator" \
            STAGING_DB_QUERY_SCRIPT="$ssm_exec" \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$SEED_SCRIPT" --secret-file "$secret_file" 2>&1
    )" || RUN_EXIT_CODE=$?

    rm -rf "$tmp_dir"

    assert_ne "$RUN_EXIT_CODE" "0" "seed script should fail when an allowlisted tenant is missing from staging customers"
    assert_contains "$RUN_OUTPUT" "allowlisted tenant 11111111-1111-1111-1111-111111111111 was not found in staging customers" "missing tenant failure should name the exact allowlisted tenant"
}

test_fails_when_allowlisted_tenant_is_inactive() {
    local tmp_dir secret_file hydrator
    tmp_dir="$(mktemp -d)"
    mkdir -p "$tmp_dir/bin"
    secret_file="$tmp_dir/.env.secret"
    hydrator="$tmp_dir/mock_hydrator.sh"
    local ssm_exec="$tmp_dir/mock_ssm_exec.sh"

    write_secret_file "$secret_file"
    write_mock_hydrator "$hydrator"
    write_inactive_tenant_ssm_exec "$ssm_exec"
    write_mock_curl "$tmp_dir/bin/curl"
    printf '%s\n' 'missing' > "$tmp_dir/tenant_one.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_one_plan.state"
    printf '%s\n' 'free' > "$tmp_dir/tenant_two_plan.state"

    RUN_EXIT_CODE=0
    RUN_OUTPUT="$(
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
            SEED_TENANT_TEST_SSM_SQL_LOG="$tmp_dir/sql.log" \
            SEED_TENANT_TEST_CURL_LOG="$tmp_dir/curl.log" \
            SEED_TENANT_ONE_STATE="$tmp_dir/tenant_one.state" \
            SEED_TENANT_ONE_PLAN_STATE="$tmp_dir/tenant_one_plan.state" \
            SEED_TENANT_TWO_PLAN_STATE="$tmp_dir/tenant_two_plan.state" \
            STAGING_ENV_HYDRATOR_SCRIPT="$hydrator" \
            STAGING_DB_QUERY_SCRIPT="$ssm_exec" \
            FJCLOUD_SECRET_FILE="$secret_file" \
            bash "$SEED_SCRIPT" --secret-file "$secret_file" 2>&1
    )" || RUN_EXIT_CODE=$?

    local curl_log
    curl_log="$(cat "$tmp_dir/curl.log" 2>/dev/null || true)"

    rm -rf "$tmp_dir"

    assert_ne "$RUN_EXIT_CODE" "0" "seed script must fail when an allowlisted tenant is not active"
    assert_contains "$RUN_OUTPUT" "allowlisted tenant 11111111-1111-1111-1111-111111111111 must be active for sync-stripe; found status=suspended" \
        "inactive tenant failure must name the tenant and the observed non-active status"
    assert_not_contains "$curl_log" "11111111-1111-1111-1111-111111111111/sync-stripe" \
        "seed script must not call sync-stripe for an inactive tenant"
}

main() {
    echo "=== seed_staging_dunning_test_tenant tests ==="

    test_links_only_missing_allowlisted_tenants
    test_fails_when_allowlisted_tenant_is_missing
    test_fails_when_allowlisted_tenant_is_inactive

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
