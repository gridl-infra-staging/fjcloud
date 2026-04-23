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
case "$url" in
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
