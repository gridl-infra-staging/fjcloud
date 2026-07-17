#!/usr/bin/env bash
# Fixture and stub helpers for scripts/tests/validate_customer_quickstart_test.sh.
# Extracted to keep the test file under the 800-line hard limit; the test file
# remains the single owner of test cases and assertions.
#
# Callers must define `fail` (used by write_fixture_docs to report unknown variants).

# Writes a curl stub that logs redacted requests and returns the requested
# HTTP status, with an optional success override for health/doc probes.
# TODO: Document write_curl_stub_with_status.
# TODO: Document write_curl_stub_with_status.
# TODO: Document write_curl_stub_with_status.
# TODO: Document write_curl_stub_with_status.
# TODO: Document write_curl_stub_with_status.
# Write a curl stub that logs redacted requests and returns the configured HTTP status.
# Optionally force health and documentation probes to succeed independently of API calls.
# TODO: Document write_curl_stub_with_status.
# TODO: Document write_curl_stub_with_status.
write_curl_stub_with_status() {
    local path="$1"
    local status_code="$2"
    local health_success_status="${3:-0}"

    case "$status_code" in
        [0-9][0-9][0-9]) ;;
        *)
            printf 'write_curl_stub_with_status: status_code must be a 3-digit HTTP code\n' >&2
            return 1
            ;;
    esac
    case "$health_success_status" in
        0|1) ;;
        *)
            printf 'write_curl_stub_with_status: health_success_status must be 0 or 1\n' >&2
            return 1
            ;;
    esac

    cat > "$path" <<CURL
#!/usr/bin/env bash
set -euo pipefail
: "\${CURL_CALL_LOG:?CURL_CALL_LOG is required}"
redacted_args=()
is_safe_logged_test_credential() {
    case "\$1" in
        dev-token|free-token|stub-token|file-admin-key|test-admin-key|commented-env-admin-key|staging-admin-contract)
            return 0
            ;;
    esac
    return 1
}
sanitize_request_body() {
    printf '%s' "\$1" | sed -E \
        -e 's/("(token|access_?token|refresh_?token|id_?token|session_?token|password|current_password|new_password|confirm_password|client_?secret|admin_?key|api_?key|webhook_?secret)"[[:space:]]*:[[:space:]]*")[^"]*"/\1[REDACTED]"/g' \
        -e 's/((^|[?&])(token|access_?token|refresh_?token|id_?token|session_?token|password|current_password|new_password|confirm_password|client_?secret|admin_?key|api_?key|webhook_?secret)=)[^&]*/\1[REDACTED]/gI'
}
sanitize_url() {
    printf '%s' "\$1" | sed -E \
        -e 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#g' \
        -e 's/((^|[?&])(token|access_?token|refresh_?token|id_?token|session_?token|password|current_password|new_password|confirm_password|client_?secret|admin_?key|api_?key|webhook_?secret)=)[^&]*/\1[REDACTED]/gI'
}
sanitize_header_value() {
    local header_value="\$1"
    local header_name="\${header_value%%:*}"
    local header_name_lower auth_value header_secret
    header_name_lower="\$(printf '%s' "\$header_name" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

    case "\$header_name_lower" in
        authorization)
            auth_value="\${header_value#*: }"
            if [[ "\$auth_value" == Bearer\ * ]]; then
                auth_value="\${auth_value#Bearer }"
            fi
            if is_safe_logged_test_credential "\$auth_value"; then
                printf '%s' "\$header_value"
            else
                printf '%s: [REDACTED]' "\$header_name"
            fi
            ;;
        x-admin-key|x-api-key|api-key|x-auth-key|x-client-secret|client-secret|x-webhook-secret|webhook-secret|x-access-token|access-token|x-refresh-token|refresh-token|x-session-token|session-token|cookie|set-cookie)
            header_secret="\${header_value#*: }"
            if is_safe_logged_test_credential "\$header_secret"; then
                printf '%s' "\$header_value"
            else
                printf '%s: [REDACTED]' "\$header_name"
            fi
            ;;
        *)
            printf '%s' "\$header_value"
            ;;
    esac
}
for ((i=1; i<=\$#; i++)); do
    arg="\${!i}"
    case "\$arg" in
        -d|--data|--data-raw|--data-binary|--data-urlencode)
            i=\$((i + 1))
            redacted_args+=("\$arg" "\$(sanitize_request_body "\${!i}")")
            ;;
        -H|--header)
            i=\$((i + 1))
            header_value="\${!i}"
            if [[ "\$header_value" == Authorization:* ]]; then
                token_value="\${header_value#*: }"
                if [[ "\$token_value" == Bearer\ * ]]; then
                    token_value="\${token_value#Bearer }"
                fi
            fi
            redacted_args+=("\$arg" "\$(sanitize_header_value "\$header_value")")
            ;;
        -u|--user)
            i=\$((i + 1))
            redacted_args+=("\$arg" "[REDACTED_USERPASS]")
            ;;
        *)
            if [[ "\$arg" == http://* || "\$arg" == https://* ]]; then
                redacted_args+=("\$(sanitize_url "\$arg")")
            else
                redacted_args+=("\$arg")
            fi
            ;;
    esac
done
{
    printf 'curl'
    for arg in "\${redacted_args[@]}"; do
        printf ' %s' "\$arg"
    done
    printf '\n'
} >> "\$CURL_CALL_LOG"
url="\${*: -1}"

for arg in "\$@"; do
    if [ "\$arg" = "%{http_code}" ]; then
        if [ "${health_success_status}" = "1" ]; then
            case "\$url" in
                */health|*/docs)
                    printf '200'
                    ;;
                *)
                    printf '${status_code}'
                    ;;
            esac
        else
            printf '${status_code}'
        fi
        exit 0
    fi
done
printf 'stub response\n'
CURL
    chmod +x "$path"
}

write_curl_stub_health_success_other_status() {
    write_curl_stub_with_status "$1" "$2" "1"
}

write_roundtrip_stub() {
    local path="$1"
    cat > "$path" <<'ROUNDTRIP'
#!/usr/bin/env bash
set -euo pipefail
: "${ROUNDTRIP_CALL_LOG:?ROUNDTRIP_CALL_LOG is required}"
printf 'roundtrip|%s\n' "$*" >> "$ROUNDTRIP_CALL_LOG"
exit 0
ROUNDTRIP
    chmod +x "$path"
}

write_quickstart_fixture_doc() {
    local quickstart_doc="$1"
    cat > "$quickstart_doc" <<'QUICKSTART'
# Fixture Customer Quickstart

<!-- validate_customer_quickstart: auth_register -->
```bash
curl -X POST "$API_BASE_URL/auth/register"
```

<!-- validate_customer_quickstart: auth_verify_email -->
```bash
curl -X POST "$API_BASE_URL/auth/verify-email"
```

<!-- validate_customer_quickstart: indexes_create -->
```bash
curl -X POST "$API_BASE_URL/indexes"
```

<!-- validate_customer_quickstart: indexes_batch_add_object -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch"
```

<!-- validate_customer_quickstart: indexes_search -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/search"
```
QUICKSTART
}

write_migration_fixture_doc() {
    local migration_doc="$1"
    cat > "$migration_doc" <<'MIGRATION'
# Fixture Migration Guide

```bash
export OBJECT_ID_PRIMARY="obj-1"
export OBJECT_ID_SECONDARY="obj-2"
export SYNONYM_ID="laptop-syn"
export RULE_ID="boost-shoes"
```

<!-- validate_customer_quickstart: migration_indexes_list -->
```bash
curl -X GET "$API_BASE_URL/indexes"
```

<!-- validate_customer_quickstart: migration_indexes_create -->
```bash
curl -X POST "$API_BASE_URL/indexes"
```

<!-- validate_customer_quickstart: migration_indexes_batch_add_object -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch"
```

<!-- validate_customer_quickstart: migration_indexes_search -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/search"
```

<!-- validate_customer_quickstart: migration_indexes_get_object -->
```bash
curl -X GET "$API_BASE_URL/indexes/$INDEX_NAME/objects/$OBJECT_ID_PRIMARY"
```

<!-- validate_customer_quickstart: migration_indexes_batch_update_object -->
```bash
curl -X POST "$API_BASE_URL/indexes/$INDEX_NAME/batch"
```

<!-- validate_customer_quickstart: migration_indexes_delete_object -->
```bash
curl -X DELETE "$API_BASE_URL/indexes/$INDEX_NAME/objects/$OBJECT_ID_SECONDARY"
```

<!-- validate_customer_quickstart: migration_indexes_save_synonym -->
```bash
curl -X PUT "$API_BASE_URL/indexes/$INDEX_NAME/synonyms/$SYNONYM_ID"
```

<!-- validate_customer_quickstart: migration_indexes_save_rule -->
```bash
curl -X PUT "$API_BASE_URL/indexes/$INDEX_NAME/rules/$RULE_ID"
```

```json
{"appId":"not-executable","apiKey":"not-executable"}
```
MIGRATION
}

write_fixture_docs() {
    local tmp_dir="$1"
    local variant="${2:-complete}"
    local quickstart_doc="$tmp_dir/customer_quickstart.md"
    local migration_doc="$tmp_dir/migrating_from_algolia.md"

    write_quickstart_fixture_doc "$quickstart_doc"
    write_migration_fixture_doc "$migration_doc"

    case "$variant" in
        unexpected)
            printf '\n<!-- validate_customer_quickstart: unexpected_marker -->\n' >> "$migration_doc"
            ;;
        duplicate_quickstart_marker)
            printf '\n<!-- validate_customer_quickstart: indexes_search -->\n' >> "$quickstart_doc"
            ;;
        duplicate_migration_marker)
            printf '\n<!-- validate_customer_quickstart: migration_indexes_search -->\n' >> "$migration_doc"
            ;;
        missing_migration_rule)
            sed -i.bak '/migration_indexes_save_rule/d' "$migration_doc"
            rm -f "$migration_doc.bak"
            ;;
        complete)
            ;;
        *)
            fail "unknown fixture doc variant: $variant"
            ;;
    esac
}

write_customer_loop_stub() {
    local path="$1"
    cat > "$path" <<'CANARY'
#!/usr/bin/env bash
set -euo pipefail
log() { :; }
mark_failure() { FLOW_FAILED=1; FLOW_FAILURE_STEP="$1"; FLOW_FAILURE_DETAIL="$2"; }
load_canary_env() { :; }
json_quote() { python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$1"; }
run_signup_step() {
    CANARY_NONCE="stubnonce"
    CANARY_TOKEN="stub-token"
    CANARY_CUSTOMER_ID="stub-customer"
    printf 'flow|signup\n' >> "${QUICKSTART_FLOW_LOG:?}"
}
run_verify_email_step() {
    printf 'flow|verify_email\n' >> "${QUICKSTART_FLOW_LOG:?}"
    printf 'verify_env|domain=%s|s3=%s\n' "${CANARY_TEST_INBOX_DOMAIN:-}" "${CANARY_TEST_INBOX_S3_URI:-}" >> "${QUICKSTART_FLOW_LOG:?}"
}
run_index_create_step() {
    CANARY_INDEX_NAME="canary-index"
    CANARY_INDEX_CREATED=1
    printf 'flow|index_create\n' >> "${QUICKSTART_FLOW_LOG:?}"
}
run_index_batch_step() { printf 'flow|index_batch\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_index_search_step() { printf 'flow|index_search\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_delete_index_step() { printf 'flow|delete_index\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_delete_account_step() { printf 'flow|delete_account\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
run_admin_cleanup_step() { printf 'flow|admin_cleanup\n' >> "${QUICKSTART_FLOW_LOG:?}"; }
tenant_call() {
    local method="$1"
    local path="$2"
    shift 3
    local payload=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -d)
                payload="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
    printf 'http|%s|%s\n' "$method" "$path" >> "${QUICKSTART_FLOW_LOG:?}"
    case "${method}|${path}" in
        "GET|/indexes")
            HTTP_RESPONSE_CODE=200
            HTTP_RESPONSE_BODY='[{"name":"canary-index"}]'
            ;;
        "POST|/indexes/canary-index/batch")
            HTTP_RESPONSE_CODE=200
            HTTP_RESPONSE_BODY='{"results":[{"objectID":"obj-1","status":200}]}'
            ;;
        "POST|/indexes/canary-index/search")
            HTTP_RESPONSE_CODE=200
            if [ "${QUICKSTART_SEARCH_LAG_ONCE:-0}" = "1" ] && [[ "$payload" == *"First updated"* ]] && [ ! -f "${QUICKSTART_FLOW_LOG}.updated_visible" ]; then
                : > "${QUICKSTART_FLOW_LOG}.updated_visible"
                HTTP_RESPONSE_BODY='{"hits":[],"nbHits":0}'
            elif [ "${QUICKSTART_SEARCH_LAG_ONCE:-0}" = "1" ] && [[ "$payload" == *"First"* ]] && [ ! -f "${QUICKSTART_FLOW_LOG}.added_visible" ]; then
                : > "${QUICKSTART_FLOW_LOG}.added_visible"
                HTTP_RESPONSE_BODY='{"hits":[],"nbHits":0}'
            else
                HTTP_RESPONSE_BODY='{"hits":[{"objectID":"obj-1","title":"First updated"}],"nbHits":1}'
            fi
            ;;
        "GET|/indexes/canary-index/objects/obj-1")
            HTTP_RESPONSE_CODE=200
            if [ "${QUICKSTART_STALE_GET_OBJECT:-0}" = "1" ]; then
                HTTP_RESPONSE_BODY='{"objectID":"obj-1","title":"Stale"}'
            else
                HTTP_RESPONSE_BODY='{"objectID":"obj-1","title":"First"}'
            fi
            ;;
        "GET|/indexes/canary-index/objects/obj-2")
            if [ "${QUICKSTART_NOOP_DELETE_OBJECT:-0}" = "1" ]; then
                HTTP_RESPONSE_CODE=200
                HTTP_RESPONSE_BODY='{"objectID":"obj-2","title":"Second"}'
            else
                HTTP_RESPONSE_CODE=404
                HTTP_RESPONSE_BODY='{"error":"not found"}'
            fi
            ;;
        "DELETE|/indexes/canary-index/objects/obj-2")
            HTTP_RESPONSE_CODE=200
            if [ "${QUICKSTART_NOOP_DELETE_OBJECT:-0}" = "1" ]; then
                HTTP_RESPONSE_BODY='{"taskID":101}'
            else
                HTTP_RESPONSE_BODY='{"objectID":"obj-2","deleted":true}'
            fi
            ;;
        "PUT|/indexes/canary-index/synonyms/laptop-syn")
            HTTP_RESPONSE_CODE=200
            HTTP_RESPONSE_BODY='{"id":"laptop-syn"}'
            ;;
        "PUT|/indexes/canary-index/rules/boost-shoes")
            HTTP_RESPONSE_CODE=200
            HTTP_RESPONSE_BODY='{"id":"boost-shoes"}'
            ;;
        *)
            HTTP_RESPONSE_CODE=404
            HTTP_RESPONSE_BODY='{"error":"unexpected stub route"}'
            ;;
    esac
}
capture_json_response() {
    "$@"
}
cleanup_after_flow() { :; }
CANARY
    chmod +x "$path"
}
