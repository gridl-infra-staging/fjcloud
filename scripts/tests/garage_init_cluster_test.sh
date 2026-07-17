#!/usr/bin/env bash
# Tests for ops/garage/scripts/init-cluster.sh helper functions.

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

# shellcheck source=../../ops/garage/scripts/init-cluster.sh
source "$REPO_ROOT/ops/garage/scripts/init-cluster.sh"

test_wait_for_admin_api_retries_until_healthy() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/curl" <<'MOCK'
#!/usr/bin/env bash
count_file="$TMP_COUNT_FILE"
count="$(cat "$count_file" 2>/dev/null || echo 0)"
count=$((count + 1))
printf '%s' "$count" > "$count_file"

if [[ "$count" -lt 3 ]]; then
  printf '503'
else
  printf '200'
fi
MOCK

    cat > "$tmp_dir/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/curl" "$tmp_dir/sleep"
    : > "$tmp_dir/curl-count"

    ADMIN_ADDR="http://127.0.0.1:3903"
    ADMIN_HEALTH_ATTEMPTS=5
    ADMIN_HEALTH_INTERVAL_SECS=0
    CURL_TIMEOUT=1

    PATH="$tmp_dir:$PATH" TMP_COUNT_FILE="$tmp_dir/curl-count" wait_for_admin_api

    local curl_count
    curl_count="$(cat "$tmp_dir/curl-count")"
    assert_eq "$curl_count" "3" "wait_for_admin_api should retry until the health endpoint returns 200"
}

test_resolve_s3_key_output_reuses_existing_key() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/garage" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$MOCK_LOG"
if [[ "$1" == "-c" && "$3" == "key" && "$4" == "info" ]]; then
  cat <<'EOF'
==== ACCESS KEY INFORMATION ====
Key ID:	GKexisting
Key name:	griddle-cold-storage
Secret key:	existing-secret
EOF
  exit 0
fi
if [[ "$1" == "-c" && "$3" == "key" && "$4" == "create" ]]; then
  echo "unexpected create" >&2
  exit 99
fi
exit 1
MOCK

    chmod +x "$tmp_dir/garage"
    : > "$tmp_dir/mock.log"

    GARAGE_BIN="$tmp_dir/garage"
    GARAGE_CONF="$tmp_dir/garage.toml"
    KEY_NAME="griddle-cold-storage"
    : > "$GARAGE_CONF"

    local output
    output="$(MOCK_LOG="$tmp_dir/mock.log" resolve_s3_key_output)"

    assert_contains "$output" "Key ID:" "resolve_s3_key_output should return existing key details"
    assert_contains "$output" "Secret key:" "resolve_s3_key_output should request the secret key"

    local log_output
    log_output="$(cat "$tmp_dir/mock.log")"
    if [[ "$log_output" == *" key create "* ]]; then
        fail "resolve_s3_key_output should not create a duplicate named key when one already exists"
    else
        pass "resolve_s3_key_output reuses an existing named key"
    fi
}

test_resolve_s3_key_output_fails_on_duplicate_names() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/garage" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-c" && "$3" == "key" && "$4" == "info" ]]; then
  echo "2 matching keys" >&2
  exit 1
fi
exit 1
MOCK

    chmod +x "$tmp_dir/garage"
    GARAGE_BIN="$tmp_dir/garage"
    GARAGE_CONF="$tmp_dir/garage.toml"
    KEY_NAME="griddle-cold-storage"
    : > "$GARAGE_CONF"

    local output exit_code=0
    output="$(resolve_s3_key_output 2>&1)" || exit_code=$?

    if [[ "$exit_code" -ne 0 ]]; then
        pass "resolve_s3_key_output returns non-zero when duplicate key names exist"
    else
        fail "resolve_s3_key_output should fail when multiple keys match the configured name"
    fi

    assert_contains "$output" "Multiple Garage keys match" "resolve_s3_key_output should explain duplicate-key remediation"
}

test_write_env_file_writes_via_temp_file_before_replace() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/cat" <<'MOCK'
#!/usr/bin/env bash
if [[ -e "$ENV_FILE" ]]; then
  printf 'present' > "$OBS_FILE"
else
  printf 'missing' > "$OBS_FILE"
fi
/bin/cat
MOCK

    cat > "$tmp_dir/chown" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/cat" "$tmp_dir/chown" "$tmp_dir/logger"

    ENV_FILE="$tmp_dir/garage.env"
    GARAGE_GROUP="garage"
    BUCKET_NAME="cold-storage"
    ADMIN_ADDR="http://127.0.0.1:3903"

    (
        PATH="$tmp_dir:$PATH"
        hash -r
        OBS_FILE="$tmp_dir/observation" \
            write_env_file "GK123" "secret123" "admin123" "rpc123" "/meta/path" "/data/path"
    )

    local observation
    observation="$(cat "$tmp_dir/observation")"
    assert_eq "$observation" "missing" "write_env_file should keep the final env path untouched until the atomic replace step"
}

test_write_env_file_exports_stage_one_contract_variables() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/chown" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/chown" "$tmp_dir/logger"

    ENV_FILE="$tmp_dir/garage.env"
    GARAGE_GROUP="garage"
    BUCKET_NAME="cold-storage"
    ADMIN_ADDR="http://127.0.0.1:3903"

    (
        PATH="$tmp_dir:$PATH"
        hash -r
        write_env_file "GK123" "secret123" "admin123" "rpc123" "/meta/path" "/data/path"
    )

    local env_output
    env_output="$(cat "$ENV_FILE")"
    assert_contains "$env_output" "GARAGE_RPC_SECRET=rpc123" "write_env_file should export the Garage RPC secret"
    assert_contains "$env_output" "GARAGE_META_DIR=/meta/path" "write_env_file should export the Garage metadata directory"
    assert_contains "$env_output" "GARAGE_DATA_DIR=/data/path" "write_env_file should export the Garage data directory"
}

test_write_env_file_uses_endpoints_and_region_from_garage_toml() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap "rm -rf '$tmp_dir'" RETURN

    cat > "$tmp_dir/garage.toml" <<'EOF'
metadata_dir = "/meta/path"
data_dir = "/data/path"
rpc_secret = "rpc123"

[s3_api]
api_bind_addr = "0.0.0.0:4900"
s3_region = "garage-stage"

[admin]
api_bind_addr = "127.0.0.1:4903"
admin_token = "admin123"
EOF

    cat > "$tmp_dir/chown" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    cat > "$tmp_dir/logger" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

    chmod +x "$tmp_dir/chown" "$tmp_dir/logger"

    GARAGE_CONF="$tmp_dir/garage.toml"
    ENV_FILE="$tmp_dir/garage.env"
    GARAGE_GROUP="garage"
    BUCKET_NAME="cold-storage"

    (
        PATH="$tmp_dir:$PATH"
        hash -r
        load_contract_config
        write_env_file "GK123" "secret123" "$CONFIG_ADMIN_TOKEN" "$CONFIG_RPC_SECRET" "$CONFIG_META_DIR" "$CONFIG_DATA_DIR"
    )

    local env_output
    env_output="$(cat "$ENV_FILE")"
    assert_contains "$env_output" "GARAGE_ADMIN_ENDPOINT=http://127.0.0.1:4903" "write_env_file should export the configured admin endpoint"
    assert_contains "$env_output" "GARAGE_S3_ENDPOINT=http://127.0.0.1:4900" "write_env_file should export the configured S3 endpoint"
    assert_contains "$env_output" "GARAGE_S3_REGION=garage-stage" "write_env_file should export the configured S3 region"
}

main() {
    echo "=== garage init tests ==="
    echo ""

    test_wait_for_admin_api_retries_until_healthy
    test_resolve_s3_key_output_reuses_existing_key
    test_resolve_s3_key_output_fails_on_duplicate_names
    test_write_env_file_writes_via_temp_file_before_replace
    test_write_env_file_exports_stage_one_contract_variables
    test_write_env_file_uses_endpoints_and_region_from_garage_toml

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
