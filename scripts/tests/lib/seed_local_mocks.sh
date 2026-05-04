#!/usr/bin/env bash
# Mock curl and psql for seed_local_test.sh.
#
# Sourced by the test file — not executed directly.
# Callers must set REPO_ROOT before sourcing.

# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
# TODO: Document write_mock_curl.
write_mock_curl() {
    local path="$1" log_path="$2"
    local state_dir
    state_dir="$(dirname "$log_path")/curl_state"
    mkdir -p "$state_dir"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "curl $*" >> "__LOG_PATH__"
method="GET"
url=""
request_body=""
auth_header=""
for ((i=1; i<=$#; i++)); do
    arg="${!i}"
    case "$arg" in
        -X)
            i=$((i + 1))
            method="${!i}"
            ;;
        -d)
            i=$((i + 1))
            request_body="${!i}"
            ;;
        -H)
            i=$((i + 1))
            header_value="${!i}"
            if [[ "$header_value" == Authorization:* ]]; then
                auth_header="${header_value#Authorization: Bearer }"
            fi
            ;;
        -w|-o)
            i=$((i + 1))
            ;;
        http://*|https://*)
            url="$arg"
            ;;
    esac
done
STATE_DIR="__STATE_DIR__"
stateful_http_code() {
    local state_key="$1"
    local first_code="$2"
    local next_code="$3"
    local state_file="${STATE_DIR}/${state_key}"
    local seen_count=0
    if [ -f "$state_file" ]; then
        seen_count=$(cat "$state_file")
    fi
    seen_count=$((seen_count + 1))
    echo "$seen_count" > "$state_file"
    if [ "$seen_count" -eq 1 ]; then
        printf '%s' "$first_code"
    else
        printf '%s' "$next_code"
    fi
}
synthetic_tenant_name_from_request() {
    if [[ "$request_body" == *'"name":"demo-shared-free"'* ]]; then
        printf '%s' "demo-shared-free"
    elif [[ "$request_body" == *'"name":"demo-small-dedicated"'* ]]; then
        printf '%s' "demo-small-dedicated"
    elif [[ "$request_body" == *'"name":"demo-medium-dedicated"'* ]]; then
        printf '%s' "demo-medium-dedicated"
    else
        printf '%s' "demo-shared-free"
    fi
}
synthetic_tenant_id_for_name() {
    case "$1" in
        demo-shared-free) printf '%s' "11111111-1111-1111-1111-111111111111" ;;
        demo-small-dedicated) printf '%s' "22222222-2222-2222-2222-222222222222" ;;
        demo-medium-dedicated) printf '%s' "33333333-3333-3333-3333-333333333333" ;;
        *) printf '%s' "11111111-1111-1111-1111-111111111111" ;;
    esac
}
synthetic_tenant_name_for_id() {
    case "$1" in
        11111111-1111-1111-1111-111111111111) printf '%s' "demo-shared-free" ;;
        22222222-2222-2222-2222-222222222222) printf '%s' "demo-small-dedicated" ;;
        33333333-3333-3333-3333-333333333333) printf '%s' "demo-medium-dedicated" ;;
        *) printf '%s' "demo-shared-free" ;;
    esac
}
synthetic_endpoint_for_tenant_name() {
    case "$1" in
        demo-shared-free) printf '%s' "http://synthetic-node-a.test" ;;
        demo-small-dedicated) printf '%s' "http://synthetic-node-b.test" ;;
        demo-medium-dedicated) printf '%s' "http://synthetic-node-c.test" ;;
        *) printf '%s' "http://synthetic-node-a.test" ;;
    esac
}
next_synthetic_storage_mb() {
    local sequence="${MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE:-}"
    local default_value="${MOCK_SYNTHETIC_STORAGE_MB:-0}"
    if [ -z "$sequence" ]; then
        printf '%s' "$default_value"
        return 0
    fi

    local state_file="${STATE_DIR}/synthetic_storage.count"
    local call_count=0
    if [ -f "$state_file" ]; then
        call_count="$(cat "$state_file")"
    fi
    call_count=$((call_count + 1))
    printf '%s' "$call_count" > "$state_file"

    local selected
    selected="$(printf '%s' "$sequence" | tr ',' '\n' | sed -n "${call_count}p")"
    if [ -z "$selected" ]; then
        selected="$(printf '%s' "$sequence" | awk -F',' '{print $NF}')"
    fi
    if [ -z "$selected" ]; then
        selected="$default_value"
    fi
    printf '%s' "$selected"
}
increment_counter_file() {
    local counter_path="$1"
    if [ -z "$counter_path" ]; then
        return 0
    fi

    local current_count=0
    if [ -f "$counter_path" ]; then
        current_count="$(cat "$counter_path")"
    fi
    current_count=$((current_count + 1))
    printf '%s' "$current_count" > "$counter_path"
}
next_state_counter() {
    local state_key="$1"
    local state_file="${STATE_DIR}/${state_key}"
    local current_count=0
    if [ -f "$state_file" ]; then
        current_count="$(cat "$state_file")"
    fi
    current_count=$((current_count + 1))
    printf '%s' "$current_count" > "$state_file"
    printf '%s' "$current_count"
}
case "$url" in
    http://synthetic-api.test/health)
        echo '{"status":"ok"}'
        exit 0
        ;;
    http://synthetic-api.test/admin/tenants)
        if [ "$method" = "GET" ]; then
            printf '[{"id":"11111111-1111-1111-1111-111111111111","name":"demo-shared-free","email":"demo-shared-free@synthetic-seed.invalid","status":"active","billing_plan":"shared"},{"id":"22222222-2222-2222-2222-222222222222","name":"demo-small-dedicated","email":"demo-small-dedicated@synthetic-seed.invalid","status":"active","billing_plan":"dedicated"},{"id":"33333333-3333-3333-3333-333333333333","name":"demo-medium-dedicated","email":"demo-medium-dedicated@synthetic-seed.invalid","status":"active","billing_plan":"dedicated"}]\n200'
            exit 0
        fi
        tenant_name="$(synthetic_tenant_name_from_request)"
        tenant_id="$(synthetic_tenant_id_for_name "$tenant_name")"
        synthetic_create_code="${MOCK_SYNTHETIC_CREATE_STATUS_CODE:-}"
        if [ -z "$synthetic_create_code" ]; then
            synthetic_create_code="$(stateful_http_code "synthetic_create_${tenant_name}.count" "201" "409")"
        fi
        if [ "$synthetic_create_code" = "201" ]; then
            printf '{"id":"%s","name":"%s","email":"%s@synthetic-seed.invalid","status":"active","billing_plan":"free","created_at":"2026-04-24T00:00:00Z","updated_at":"2026-04-24T00:00:00Z"}\n201' \
                "$tenant_id" \
                "$tenant_name" \
                "$tenant_name"
        else
            if [ "${MOCK_SYNTHETIC_CREATE_409_INCLUDE_ID:-1}" = "1" ]; then
                printf '{"error":"tenant already exists","id":"%s"}\n409' "$tenant_id"
            else
                printf '{"error":"tenant already exists"}\n409'
            fi
        fi
        exit 0
        ;;
    http://synthetic-api.test/admin/tenants/*/indexes)
        synthetic_tenant_id="${url##*/admin/tenants/}"
        synthetic_tenant_id="${synthetic_tenant_id%%/indexes*}"
        synthetic_tenant_name="$(synthetic_tenant_name_for_id "$synthetic_tenant_id")"
        synthetic_endpoint="$(synthetic_endpoint_for_tenant_name "$synthetic_tenant_name")"
        # Tests can override the seed-index status to exercise the
        # idempotent 200-OK rerun path (post-c4a83033). The default 201
        # remains for first-create coverage.
        synthetic_index_status="${MOCK_SYNTHETIC_INDEX_STATUS:-201}"
        printf '{"name":"%s","region":"us-east-1","status":"healthy","endpoint":"%s"}\n%s' \
            "$synthetic_tenant_name" \
            "$synthetic_endpoint" \
            "$synthetic_index_status"
        exit 0
        ;;
    http://synthetic-api.test/admin/tenants/*)
        if [ "$method" = "PUT" ]; then
            synthetic_tenant_id="${url##*/admin/tenants/}"
            synthetic_tenant_id="${synthetic_tenant_id%%\?*}"
            synthetic_tenant_name="$(synthetic_tenant_name_for_id "$synthetic_tenant_id")"
            printf '{"id":"%s","name":"%s","email":"%s@synthetic-seed.invalid","status":"active","billing_plan":"dedicated","created_at":"2026-04-24T00:00:00Z","updated_at":"2026-04-24T00:00:00Z"}\n200' \
                "$synthetic_tenant_id" \
                "$synthetic_tenant_name" \
                "$synthetic_tenant_name"
            exit 0
        fi
        ;;
    http://synthetic-flapjack.test/internal/storage*|http://synthetic-node-a.test/internal/storage*|http://synthetic-node-b.test/internal/storage*|http://synthetic-node-c.test/internal/storage*)
        synthetic_storage_mb="$(next_synthetic_storage_mb)"
        synthetic_storage_bytes=$((synthetic_storage_mb * 1048576))
        # Default mirrors the live flapjack engine's `{customer_hex}_{name}`
        # tenant id contract: the mocked admin/tenants response uses
        # customer_id `11111111-1111-1111-1111-111111111111`, so the
        # canonical default uid is its dash-stripped form prefixed to the
        # tenant A index name. Tests that pre-write fixture mappings with a
        # different customer_id can override via MOCK_SYNTHETIC_STORAGE_UID.
        synthetic_storage_uid="${MOCK_SYNTHETIC_STORAGE_UID:-11111111111111111111111111111111_demo-shared-free}"
        synthetic_other_uid="${MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_UID:-unrelated-tenant}"
        synthetic_other_mb="${MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_MB:-0}"
        synthetic_other_bytes=$((synthetic_other_mb * 1048576))
        printf '{"tenants":[{"id":"%s","bytes":%s},{"id":"%s","bytes":%s}]}\n200' \
            "$synthetic_other_uid" \
            "$synthetic_other_bytes" \
            "$synthetic_storage_uid" \
            "$synthetic_storage_bytes"
        exit 0
        ;;
    http://synthetic-flapjack.test/1/indexes/*/documents|http://synthetic-node-a.test/1/indexes/*/documents|http://synthetic-node-b.test/1/indexes/*/documents|http://synthetic-node-c.test/1/indexes/*/documents)
        increment_counter_file "${MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH:-}"
        printf '{"taskUid":"synthetic-seed"}\n200'
        exit 0
        ;;
    http://synthetic-flapjack.test/1/indexes/*/batch|http://synthetic-node-a.test/1/indexes/*/batch|http://synthetic-node-b.test/1/indexes/*/batch|http://synthetic-node-c.test/1/indexes/*/batch)
        increment_counter_file "${MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH:-}"
        printf '{"taskUid":"synthetic-seed"}\n200'
        exit 0
        ;;
    http://synthetic-flapjack.test/1/indexes/*/query|http://synthetic-node-a.test/1/indexes/*/query|http://synthetic-node-b.test/1/indexes/*/query|http://synthetic-node-c.test/1/indexes/*/query)
        synthetic_query_call="$(next_state_counter "synthetic_query.count")"
        increment_counter_file "${MOCK_SYNTHETIC_DIRECT_QUERY_COUNT_PATH:-}"
        synthetic_fail_query_on_call="${MOCK_SYNTHETIC_FAIL_QUERY_ON_CALL:-0}"
        if [ "$synthetic_fail_query_on_call" -gt 0 ] && [ "$synthetic_query_call" -eq "$synthetic_fail_query_on_call" ]; then
            printf '{"error":"synthetic query failure"}\n500'
            exit 0
        fi
        printf '{"taskUid":"synthetic-seed"}\n200'
        exit 0
        ;;
    http://synthetic-flapjack.test/health|http://synthetic-node-a.test/health|http://synthetic-node-b.test/health|http://synthetic-node-c.test/health)
        echo '{"status":"ok"}'
        exit 0
        ;;
    http://localhost:3001/health|http://127.0.0.1:3001/health)
        echo '{"status":"ok"}'
        exit 0
        ;;
    http://localhost:3001/auth/register|http://127.0.0.1:3001/auth/register)
        register_code="201"
        register_token='{"token":"seed-token"}'
        if [[ "$request_body" == *'"email":"dev@example.com"'* ]]; then
            register_code=$(stateful_http_code "register_dev.count" "201" "409")
            register_token='{"token":"dev-token"}'
        elif [[ "$request_body" == *'"email":"free@example.com"'* ]]; then
            register_code=$(stateful_http_code "register_free.count" "201" "409")
            register_token='{"token":"free-token"}'
        fi
        if [ "$register_code" = "201" ]; then
            printf '%s\n201' "$register_token"
        else
            printf '{"error":"already exists"}\n409'
        fi
        exit 0
        ;;
    http://localhost:3001/auth/login|http://127.0.0.1:3001/auth/login)
        # Return body-only (no HTTP code suffix) so the first login attempt
        # with -w "\n%{http_code}" fails the login_code check and falls
        # through to the register path on first run.
        if [[ "$request_body" == *'"email":"dev@example.com"'* ]]; then
            printf '{"token":"dev-token"}'
        elif [[ "$request_body" == *'"email":"free@example.com"'* ]]; then
            printf '{"token":"free-token"}'
        else
            printf '{"token":"seed-token"}'
        fi
        exit 0
        ;;
    http://localhost:3001/account|http://127.0.0.1:3001/account)
        if [ "$auth_header" = "dev-token" ]; then
            printf '{"id":"customer-dev","billing_plan":"shared"}'
        elif [ "$auth_header" = "free-token" ]; then
            printf '{"id":"customer-free","billing_plan":"free"}'
        else
            printf '{"id":"customer-1","billing_plan":"shared"}'
        fi
        exit 0
        ;;
    http://localhost:3001/indexes|http://127.0.0.1:3001/indexes)
        if [ "$auth_header" = "dev-token" ]; then
            printf '{"indexes":[{"name":"test-index"},{"name":"test-index-eu"},{"name":"test-index-eu2"},{"name":"folder/name"}]}'
        elif [ "$auth_header" = "free-token" ]; then
            printf '{"indexes":[{"name":"free-test-index"}]}'
        else
            printf '{"indexes":[{"name":"test-index"}]}'
        fi
        exit 0
        ;;
    http://localhost:3001/billing/estimate*|http://127.0.0.1:3001/billing/estimate*)
        estimate_month="${url##*month=}"
        if [ "$estimate_month" = "$url" ] || [ -z "$estimate_month" ]; then
            estimate_month="$(date -u +%Y-%m)"
        fi
        estimate_month="${estimate_month%%&*}"
        if [ "$auth_header" = "dev-token" ]; then
            printf '{"month":"%s","subtotal_cents":725,"total_cents":725,"line_items":[{"description":"Hot storage","quantity":"1","unit":"mb_months","unit_price_cents":"725","amount_cents":725,"region":"us-east-1"}],"minimum_applied":false}\n200' "$estimate_month"
        else
            printf '{"month":"%s","subtotal_cents":0,"total_cents":200,"line_items":[],"minimum_applied":true}\n200' "$estimate_month"
        fi
        exit 0
        ;;
    http://localhost:3001/admin/tenants/customer-1|http://127.0.0.1:3001/admin/tenants/customer-1|http://localhost:3001/admin/tenants/customer-dev|http://127.0.0.1:3001/admin/tenants/customer-dev)
        if [ "$method" = "PUT" ]; then
            printf '{}\n200'
            exit 0
        fi
        ;;
    http://localhost:3001/admin/tenants/customer-1/indexes|http://127.0.0.1:3001/admin/tenants/customer-1/indexes|http://localhost:3001/admin/tenants/customer-dev/indexes|http://127.0.0.1:3001/admin/tenants/customer-dev/indexes|http://localhost:3001/admin/tenants/customer-free/indexes|http://127.0.0.1:3001/admin/tenants/customer-free/indexes)
        index_state_hash=$(printf '%s|%s' "$url" "$request_body" | shasum | awk '{print $1}')
        index_code=$(stateful_http_code "index_${index_state_hash}.count" "201" "409")
        printf '{}\n%s' "$index_code"
        exit 0
        ;;
    http://localhost:3001/admin/customers/*/sync-stripe|http://127.0.0.1:3001/admin/customers/*/sync-stripe)
        sync_customer="${url##*/admin/customers/}"
        sync_customer="${sync_customer%%/sync-stripe*}"
        if [ "${MOCK_STRIPE_SYNC_FAIL:-0}" = "1" ]; then
            printf '{"error":"stripe sync failed"}\n500'
            exit 0
        fi
        sync_state=$(stateful_http_code "stripe_sync_${sync_customer}.count" "first" "repeat")
        if [ "$sync_state" = "first" ]; then
            printf '{"message":"stripe customer created and linked","stripe_customer_id":"cus_mock_%s"}\n200' "$sync_customer"
        else
            printf '{"message":"customer already linked to stripe","stripe_customer_id":"cus_mock_%s"}\n200' "$sync_customer"
        fi
        exit 0
        ;;
    http://localhost:3001/indexes/*/documents|http://127.0.0.1:3001/indexes/*/documents)
        printf '{}'
        exit 0
        ;;
    http://localhost:7701/health)
        echo '{"status":"ok"}'
        exit 0
        ;;
    http://localhost:7799/health|http://localhost:7700/health|http://localhost:7711/health)
        exit 1
        ;;
esac
echo "unexpected curl url: $url" >&2
exit 1
MOCK
    perl -0pi -e "s|__LOG_PATH__|$log_path|g; s|__STATE_DIR__|$state_dir|g" "$path"
    chmod +x "$path"
}

write_mock_psql() {
    local path="$1" log_path="$2" stdin_path="$3"
    cat > "$path" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
echo "psql $*" >> "__LOG_PATH__"
sql_input="$(cat)"
printf '%s\n--SQL-END--\n' "$sql_input" >> "__STDIN_PATH__"
if [ "${MOCK_PSQL_FAIL_USAGE_DAILY:-0}" = "1" ] && [[ "$sql_input" == *"INSERT INTO usage_daily"* ]]; then
    echo "mock usage_daily failure" >&2
    exit 1
fi
if [[ "$sql_input" == *"SELECT COUNT(*) FROM updated;"* ]]; then
    echo "1"
fi
MOCK
    perl -0pi -e "s|__LOG_PATH__|$log_path|g; s|__STDIN_PATH__|$stdin_path|g" "$path"
    chmod +x "$path"
}
