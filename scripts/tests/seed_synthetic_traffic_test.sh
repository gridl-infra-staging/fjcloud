#!/usr/bin/env bash
# Red-first contract tests for scripts/launch/seed_synthetic_traffic.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
RUN_OUTPUT=""
RUN_EXIT_CODE=0
TENANT_A_MAPPING_PATH="/tmp/seed-synthetic-demo-shared-free.json"

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

read_file_or_empty() {
    local path="$1"
    if [ -f "$path" ]; then
        cat "$path"
    fi
}

line_count_or_zero() {
    local path="$1"
    if [ ! -f "$path" ]; then
        printf '0'
        return 0
    fi
    wc -l < "$path" | tr -d '[:space:]'
}

read_counter_file_or_zero() {
    local path="$1"
    if [ ! -f "$path" ]; then
        printf '0'
        return 0
    fi
    cat "$path"
}

setup_mock_workspace() {
    local tmp_dir="$1"
    local curl_log="$2"
    local psql_log="$3"
    local psql_stdin="$4"
    local sleep_log="${5:-$tmp_dir/sleep.log}"

    mkdir -p "$tmp_dir/bin"
    write_mock_curl "$tmp_dir/bin/curl" "$curl_log"
    write_mock_psql "$tmp_dir/bin/psql" "$psql_log" "$psql_stdin"

    # Keep traffic-driver contract tests bounded while preserving sleep-arg observability.
    : > "$sleep_log"
    cat > "$tmp_dir/bin/sleep" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$sleep_log"
if [ -n "\${MOCK_SYNTHETIC_SLEEP_DELAY_ARG:-}" ] && [ "\$*" = "\${MOCK_SYNTHETIC_SLEEP_DELAY_ARG}" ] && [ -n "\${MOCK_SYNTHETIC_SLEEP_DELAY_SECONDS:-}" ]; then
    python3 - "\${MOCK_SYNTHETIC_SLEEP_DELAY_SECONDS}" <<'PY'
import sys
import time

time.sleep(float(sys.argv[1]))
PY
fi
exit 0
EOF
    chmod +x "$tmp_dir/bin/sleep"
}

clear_mock_logs() {
    local curl_log="$1"
    local psql_log="$2"
    local psql_stdin="$3"
    : > "$curl_log"
    : > "$psql_log"
    : > "$psql_stdin"
}

stash_tenant_a_mapping_artifact() {
    local backup_path="$1"
    rm -f "$backup_path"
    if [ -f "$TENANT_A_MAPPING_PATH" ]; then
        cp "$TENANT_A_MAPPING_PATH" "$backup_path"
    fi
    rm -f "$TENANT_A_MAPPING_PATH"
}

restore_tenant_a_mapping_artifact() {
    local backup_path="$1"
    if [ -f "$backup_path" ]; then
        cp "$backup_path" "$TENANT_A_MAPPING_PATH"
    else
        rm -f "$TENANT_A_MAPPING_PATH"
    fi
}

mapping_json_field_or_empty() {
    local field_name="$1"
    if [ ! -f "$TENANT_A_MAPPING_PATH" ]; then
        printf ''
        return 0
    fi
    python3 - "$TENANT_A_MAPPING_PATH" "$field_name" <<'PY'
import json
import sys
path = sys.argv[1]
field = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    payload = json.load(f)
value = payload.get(field, "")
if value is None:
    print("")
else:
    print(value)
PY
}

capture_run_start_utc() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

require_tenant_a_mapping_artifact() {
    if [ ! -f "$TENANT_A_MAPPING_PATH" ]; then
        fail "live execute must persist tenant A mapping artifact at $TENANT_A_MAPPING_PATH"
        return 1
    fi
    return 0
}

mapping_json_field_or_fail() {
    local field_name="$1"
    local context="$2"
    local value
    value="$(mapping_json_field_or_empty "$field_name")"
    if [ -z "$value" ]; then
        fail "$context missing required mapping field '$field_name' in $TENANT_A_MAPPING_PATH"
        return 1
    fi
    printf '%s' "$value"
}

handle_stage5_optional_usage_daily_follow_on() {
    local usage_daily_exit="$1"
    local usage_daily_rows="$2"
    local usage_daily_row_count

    if [ "$usage_daily_exit" -ne 0 ]; then
        pass "stage5 optional usage_daily follow-on query is unavailable; this is non-gating evidence only"
        printf '%s\n' "stage5 usage_daily evidence unavailable (non-gating): exit=$usage_daily_exit output=$usage_daily_rows" >&2
        return 0
    fi

    usage_daily_row_count="$(printf '%s\n' "$usage_daily_rows" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    if [ "$usage_daily_row_count" -gt 0 ]; then
        pass "stage5 optional usage_daily follow-on evidence already exists (rows=$usage_daily_row_count)"
        printf '%s\n' "stage5 usage_daily evidence (customer_id|tenant_id|usage_date|event_type|sum_value):"
        printf '%s\n' "$usage_daily_rows"
    else
        pass "stage5 optional usage_daily follow-on evidence is absent; this is not a pass/fail gate"
    fi
}

write_tenant_a_mapping_artifact() {
    local customer_id="$1"
    local tenant_id="$2"
    local flapjack_uid="$3"
    local flapjack_url="$4"
    cat > "$TENANT_A_MAPPING_PATH" <<EOF
{"customer_id":"$customer_id","tenant_id":"$tenant_id","flapjack_uid":"$flapjack_uid","flapjack_url":"$flapjack_url"}
EOF
}

run_seed_synthetic_dry_run() {
    local tmp_dir="$1"
    local selector="$2"

    RUN_EXIT_CODE=0
    RUN_OUTPUT=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" --tenant "$selector" --dry-run 2>&1
    ) || RUN_EXIT_CODE=$?
}

run_seed_synthetic_execute() {
    local tmp_dir="$1"
    local selector="$2"
    local duration_minutes="${MOCK_SYNTHETIC_DURATION_MINUTES:-1}"

    RUN_EXIT_CODE=0
    RUN_OUTPUT=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://synthetic-api.test" \
        ADMIN_KEY="synthetic-admin-key" \
        DATABASE_URL="postgres://griddle:griddle_local@127.0.0.1:15432/fjcloud_dev" \
        FLAPJACK_URL="http://synthetic-flapjack.test" \
        FLAPJACK_API_KEY="synthetic-flapjack-api-key" \
        MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="${MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE:-}" \
        MOCK_SYNTHETIC_STORAGE_MB="${MOCK_SYNTHETIC_STORAGE_MB:-}" \
        MOCK_SYNTHETIC_STORAGE_UID="${MOCK_SYNTHETIC_STORAGE_UID:-}" \
        MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_MB="${MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_MB:-}" \
        MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_UID="${MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_UID:-}" \
        MOCK_SYNTHETIC_CREATE_STATUS_CODE="${MOCK_SYNTHETIC_CREATE_STATUS_CODE:-}" \
        MOCK_SYNTHETIC_CREATE_409_INCLUDE_ID="${MOCK_SYNTHETIC_CREATE_409_INCLUDE_ID:-}" \
        MOCK_SYNTHETIC_INDEX_STATUS="${MOCK_SYNTHETIC_INDEX_STATUS:-}" \
        MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH="${MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH:-}" \
        MOCK_SYNTHETIC_DIRECT_QUERY_COUNT_PATH="${MOCK_SYNTHETIC_DIRECT_QUERY_COUNT_PATH:-}" \
        MOCK_SYNTHETIC_FAIL_QUERY_ON_CALL="${MOCK_SYNTHETIC_FAIL_QUERY_ON_CALL:-}" \
        MOCK_SYNTHETIC_SLEEP_DELAY_ARG="${MOCK_SYNTHETIC_SLEEP_DELAY_ARG:-}" \
        MOCK_SYNTHETIC_SLEEP_DELAY_SECONDS="${MOCK_SYNTHETIC_SLEEP_DELAY_SECONDS:-}" \
        bash "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" \
            --tenant "$selector" \
            --execute \
            --i-know-this-hits-staging \
            --duration-minutes "$duration_minutes" 2>&1
    ) || RUN_EXIT_CODE=$?
}

run_seed_synthetic_execute_without_ack() {
    local tmp_dir="$1"
    local selector="$2"

    RUN_EXIT_CODE=0
    RUN_OUTPUT=$(
        PATH="$tmp_dir/bin:$PATH" \
        bash "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" \
            --tenant "$selector" \
            --execute \
            --duration-minutes 1 2>&1
    ) || RUN_EXIT_CODE=$?
}

assert_tenant_description() {
    local output="$1"
    local tenant_letter="$2"

    case "$tenant_letter" in
        A)
            assert_contains "$output" "=== Tenant A ===" "tenant A selector should print tenant A heading"
            assert_contains "$output" "name:              demo-shared-free" "tenant A selector should print tenant A name"
            assert_contains "$output" "plan:              shared" "tenant A selector should print tenant A billing plan"
            assert_contains "$output" "target_storage_mb: 100" "tenant A selector should print tenant A storage target"
            assert_contains "$output" "writes_per_minute: 10" "tenant A selector should print tenant A write rate"
            assert_contains "$output" "searches_per_min:  1" "tenant A selector should print tenant A search rate"
            ;;
        B)
            assert_contains "$output" "=== Tenant B ===" "tenant B selector should print tenant B heading"
            assert_contains "$output" "name:              demo-small-dedicated" "tenant B selector should print tenant B name"
            assert_contains "$output" "plan:              dedicated" "tenant B selector should print tenant B billing plan"
            assert_contains "$output" "target_storage_mb: 2048" "tenant B selector should print tenant B storage target"
            assert_contains "$output" "writes_per_minute: 100" "tenant B selector should print tenant B write rate"
            assert_contains "$output" "searches_per_min:  10" "tenant B selector should print tenant B search rate"
            ;;
        C)
            assert_contains "$output" "=== Tenant C ===" "tenant C selector should print tenant C heading"
            assert_contains "$output" "name:              demo-medium-dedicated" "tenant C selector should print tenant C name"
            assert_contains "$output" "plan:              dedicated" "tenant C selector should print tenant C billing plan"
            assert_contains "$output" "target_storage_mb: 20480" "tenant C selector should print tenant C storage target"
            assert_contains "$output" "writes_per_minute: 1000" "tenant C selector should print tenant C write rate"
            assert_contains "$output" "searches_per_min:  50" "tenant C selector should print tenant C search rate"
            ;;
        *)
            fail "unknown tenant selector for assertions: $tenant_letter"
            ;;
    esac
}

test_dry_run_contracts_cover_A_B_C_and_all_without_mutation_calls() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    local selector curl_calls psql_calls
    for selector in A B C all; do
        clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
        run_seed_synthetic_dry_run "$tmp_dir" "$selector"

        assert_eq "$RUN_EXIT_CODE" "0" "dry-run selector $selector should exit cleanly"
        assert_contains "$RUN_OUTPUT" "this was a dry run. Re-run with --execute --i-know-this-hits-staging to mutate staging." \
            "dry-run selector $selector should print execute re-run hint"

        case "$selector" in
            A)
                assert_tenant_description "$RUN_OUTPUT" "A"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant B ===" "tenant A dry-run should not include tenant B"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant C ===" "tenant A dry-run should not include tenant C"
                ;;
            B)
                assert_tenant_description "$RUN_OUTPUT" "B"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant A ===" "tenant B dry-run should not include tenant A"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant C ===" "tenant B dry-run should not include tenant C"
                ;;
            C)
                assert_tenant_description "$RUN_OUTPUT" "C"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant A ===" "tenant C dry-run should not include tenant A"
                assert_not_contains "$RUN_OUTPUT" "=== Tenant B ===" "tenant C dry-run should not include tenant B"
                ;;
            all)
                assert_tenant_description "$RUN_OUTPUT" "A"
                assert_tenant_description "$RUN_OUTPUT" "B"
                assert_tenant_description "$RUN_OUTPUT" "C"
                ;;
        esac

        curl_calls="$(read_file_or_empty "$curl_log")"
        psql_calls="$(read_file_or_empty "$psql_log")"
        assert_eq "$(line_count_or_zero "$curl_log")" "0" "dry-run selector $selector should make zero curl calls"
        assert_eq "$(line_count_or_zero "$psql_log")" "0" "dry-run selector $selector should make zero psql calls"
        assert_eq "$(line_count_or_zero "$psql_stdin")" "0" "dry-run selector $selector should not write SQL"
        assert_eq "$curl_calls" "" "dry-run selector $selector should leave curl log empty"
        assert_eq "$psql_calls" "" "dry-run selector $selector should leave psql log empty"
    done
}

test_execute_requires_staging_ack_before_preflight_or_mutation_calls() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    run_seed_synthetic_execute_without_ack "$tmp_dir" "B"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "execute without staging acknowledgement should fail closed"
    assert_contains "$RUN_OUTPUT" "--execute requires --i-know-this-hits-staging" \
        "execute without staging acknowledgement should emit explicit guard message"
    assert_not_contains "$RUN_OUTPUT" "missing required env vars:" \
        "execute without staging acknowledgement should fail before preflight env validation"

    assert_eq "$(line_count_or_zero "$curl_log")" "0" \
        "execute without staging acknowledgement should produce zero curl calls"
    assert_eq "$(line_count_or_zero "$psql_log")" "0" \
        "execute without staging acknowledgement should produce zero psql calls"
    assert_eq "$(line_count_or_zero "$psql_stdin")" "0" \
        "execute without staging acknowledgement should not write SQL"
}

test_execute_guard_fails_closed_for_all_selectors_before_mutations() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    local selector curl_calls
    for selector in B C all; do
        clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
        run_seed_synthetic_execute "$tmp_dir" "$selector"

        assert_eq "$RUN_EXIT_CODE" "1" \
            "execute selector $selector should fail closed before preflight or staging mutations"
        assert_contains "$RUN_OUTPUT" "execute mode supports only --tenant A in Stage 2" \
            "execute selector $selector should be rejected by the Stage 2 unsupported-selector guard"
        assert_not_contains "$RUN_OUTPUT" "missing required env vars:" \
            "execute selector $selector should fail before preflight env validation"

        curl_calls="$(read_file_or_empty "$curl_log")"
        assert_not_contains "$curl_calls" "/admin/tenants" \
            "execute selector $selector guard should block admin provisioning"
        assert_not_contains "$curl_calls" "/internal/storage" \
            "execute selector $selector guard should block storage polling"
        assert_not_contains "$curl_calls" "/1/indexes/" \
            "execute selector $selector guard should block direct flapjack traffic"

        assert_eq "$(line_count_or_zero "$curl_log")" "0" \
            "execute selector $selector guard should produce zero curl calls"
        assert_eq "$(line_count_or_zero "$psql_log")" "0" \
            "execute selector $selector guard should produce zero psql calls"
        assert_eq "$(line_count_or_zero "$psql_stdin")" "0" \
            "execute selector $selector guard should not write SQL"
    done

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    run_seed_synthetic_dry_run "$tmp_dir" "all"
    assert_eq "$RUN_EXIT_CODE" "0" "dry-run tenant all should remain descriptive"
    assert_tenant_description "$RUN_OUTPUT" "A"
    assert_tenant_description "$RUN_OUTPUT" "B"
    assert_tenant_description "$RUN_OUTPUT" "C"
}

test_provisioning_contract_first_run_pins_create_update_and_index_fields() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" "tenant A execute should complete when provisioning path is implemented"

    local curl_calls
    curl_calls="$(read_file_or_empty "$curl_log")"
    assert_contains "$curl_calls" "http://synthetic-api.test/admin/tenants" \
        "provisioning should call create tenant endpoint"
    assert_contains "$curl_calls" '"name":"demo-shared-free"' \
        "provisioning create payload should include tenant name"
    assert_contains "$curl_calls" '"email":"' \
        "provisioning create payload should include tenant email"
    assert_contains "$curl_calls" "http://synthetic-api.test/admin/tenants/11111111-1111-1111-1111-111111111111" \
        "provisioning should consume created tenant id for follow-up admin calls"
    assert_contains "$curl_calls" '"billing_plan":"shared"' \
        "provisioning update payload should pin billing plan"
    assert_contains "$curl_calls" "http://synthetic-api.test/admin/tenants/11111111-1111-1111-1111-111111111111/indexes" \
        "provisioning should seed index using resolved tenant id"
    assert_contains "$curl_calls" '"name":"demo-shared-free"' \
        "seed-index payload should pin tenant A index name"
    assert_contains "$curl_calls" '"region":"us-east-1"' \
        "seed-index payload should include region"
    assert_contains "$curl_calls" '"flapjack_url":"http://synthetic-flapjack.test"' \
        "seed-index payload should include flapjack url"
}

test_provisioning_contract_rerun_is_idempotent_without_duplicate_create_calls() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    run_seed_synthetic_execute "$tmp_dir" "A"
    local first_exit="$RUN_EXIT_CODE"
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" run_seed_synthetic_execute "$tmp_dir" "A"
    local second_exit="$RUN_EXIT_CODE"

    assert_eq "$first_exit" "0" "first tenant A execute should succeed"
    assert_eq "$second_exit" "0" "second tenant A execute should succeed idempotently"

    local create_count update_count index_count
    create_count=$(grep -c "http://synthetic-api.test/admin/tenants -H" "$curl_log" || true)
    update_count=$(grep -c "http://synthetic-api.test/admin/tenants/11111111-1111-1111-1111-111111111111" "$curl_log" || true)
    index_count=$(grep -c "http://synthetic-api.test/admin/tenants/11111111-1111-1111-1111-111111111111/indexes" "$curl_log" || true)

    assert_eq "$create_count" "1" "rerun should not repeat tenant create after first successful mapping"
    if [ "$update_count" -ge 2 ]; then
        pass "rerun should continue verifying/updating tenant contract state"
    else
        fail "rerun should verify/update tenant contract state on both runs (found $update_count)"
    fi
    if [ "$index_count" -ge 1 ]; then
        pass "rerun should keep index seed contract idempotent"
    else
        fail "rerun should still hit index seed contract (found $index_count)"
    fi

    if [ -f "$TENANT_A_MAPPING_PATH" ]; then
        local mapping_payload
        mapping_payload="$(cat "$TENANT_A_MAPPING_PATH")"
        assert_contains "$mapping_payload" '"customer_id"' "tenant mapping artifact should include customer id"
        assert_contains "$mapping_payload" '"tenant_id"' "tenant mapping artifact should include tenant id"
        assert_contains "$mapping_payload" '"flapjack_uid"' "tenant mapping artifact should include flapjack uid"
        assert_contains "$mapping_payload" '"flapjack_url"' "tenant mapping artifact should include flapjack url"
        assert_not_contains "$mapping_payload" '"tenant_uid"' "tenant mapping artifact should stop using deprecated tenant_uid key"
    else
        fail "tenant mapping artifact should be written for rerun idempotency"
    fi
}

# Regression guard: post-c4a83033 the API's POST /admin/tenants/:id/indexes
# returns 200 OK (not 201, not 409) on rerun against an existing
# (customer_id, tenant_id) pair. Until commit 27571c15 the seeder rejected
# anything other than 201|409, so the first live Stage D capture against the
# new staging API binary failed at seed_index with status=200. This test
# pins the 200-OK contract at the seeder boundary so a future revert of
# the case-statement update fails loudly. Tested separately from the
# rerun-idempotency test above because that one always sees 201 from the
# default mock — masking this exact regression.
test_seed_index_accepts_200_ok_from_idempotent_rerun_path() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    # Force the indexes mock to return 200 OK (rerun path) instead of the
    # default 201. Everything else (mapping artifact, sustained traffic)
    # should still complete normally.
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_INDEX_STATUS="200" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
        run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "seed_index returning 200 (idempotent rerun) must NOT fail the seeder"
    if [ -f "$TENANT_A_MAPPING_PATH" ]; then
        local mapping_payload
        mapping_payload="$(cat "$TENANT_A_MAPPING_PATH")"
        # The mapping artifact is the operational signal that the seeder
        # accepted the rerun and wrote downstream-usable state, not just
        # that the script returned 0.
        assert_contains "$mapping_payload" '"flapjack_uid"' \
            "200-OK rerun must still produce a tenant mapping artifact for sustained traffic"
    else
        fail "200-OK rerun should still write the tenant mapping artifact"
    fi
}

test_provisioning_contract_recovers_when_create_409_omits_customer_id() {
    local tmp_dir
    tmp_dir=$(mktemp -d)

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_CREATE_STATUS_CODE="409" \
    MOCK_SYNTHETIC_CREATE_409_INCLUDE_ID="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "tenant A execute should resolve customer_id via tenant lookup when create 409 omits id"

    local curl_calls mapping_customer_id
    curl_calls="$(read_file_or_empty "$curl_log")"
    mapping_customer_id="$(mapping_json_field_or_empty "customer_id")"
    assert_contains "$curl_calls" "-X POST http://synthetic-api.test/admin/tenants" \
        "provisioning should still attempt tenant create before fallback lookup"
    assert_contains "$curl_calls" "-X GET http://synthetic-api.test/admin/tenants" \
        "provisioning should query tenants to resolve existing customer id after a 409 without id"
    assert_eq "$mapping_customer_id" "11111111-1111-1111-1111-111111111111" \
        "fallback lookup should persist resolved customer_id in tenant mapping artifact"
}

test_storage_floor_contract_skips_backfill_when_target_already_met() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage2-a" \
        "tenant-stage2-a" \
        "11111111111111111111111111111111_demo-shared-free" \
        "http://synthetic-flapjack.test"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" "tenant A execute should finish when storage already exceeds floor"

    local curl_calls mapped_flapjack_uid mapped_flapjack_url batch_write_count
    curl_calls="$(read_file_or_empty "$curl_log")"
    mapped_flapjack_uid="$(mapping_json_field_or_empty "flapjack_uid")"
    mapped_flapjack_url="$(mapping_json_field_or_empty "flapjack_url")"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/internal/storage" \
        "storage-floor contract should poll internal storage before deciding to backfill"
    batch_write_count=$(grep -c "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/batch" "$curl_log" || true)
    assert_eq "$batch_write_count" "10" \
        "storage-floor contract should skip pre-floor backfill and run only sustained execute traffic writes"
    assert_not_contains "$curl_calls" "-X DELETE" \
        "storage-floor contract should avoid delete/reset branches"
}

test_storage_floor_contract_polls_until_usage_converges() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage2-a" \
        "tenant-stage2-a" \
        "11111111111111111111111111111111_demo-shared-free" \
        "http://synthetic-flapjack.test"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="40,70,95" \
    MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_MB="5000" \
    MOCK_SYNTHETIC_STORAGE_OTHER_TENANT_UID="tenant-b-unrelated" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" "tenant A execute should finish once storage converges into tolerance"

    local mapped_flapjack_uid mapped_flapjack_url storage_poll_count write_count
    mapped_flapjack_uid="$(mapping_json_field_or_empty "flapjack_uid")"
    mapped_flapjack_url="$(mapping_json_field_or_empty "flapjack_url")"
    storage_poll_count=$(grep -c "${mapped_flapjack_url}/internal/storage" "$curl_log" || true)
    write_count=$(grep -c "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/batch" "$curl_log" || true)

    if [ "$storage_poll_count" -ge 3 ]; then
        pass "storage-floor contract should keep polling until target tolerance is reached"
    else
        fail "storage-floor contract should poll repeatedly before converging (found $storage_poll_count)"
    fi

    if [ "$write_count" -gt 0 ]; then
        pass "storage-floor contract should backfill documents while below floor"
    else
        fail "storage-floor contract should issue document writes before convergence"
    fi

    local curl_calls
    curl_calls="$(read_file_or_empty "$curl_log")"
    assert_not_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/tenant-b-unrelated/batch" \
        "storage-floor contract should select mapped flapjack_uid instead of unrelated tenants from /internal/storage"
    assert_not_contains "$curl_calls" "-X DELETE" \
        "storage-floor contract should avoid delete/reset branches while converging"
}

test_storage_floor_contract_stops_after_above_tolerance_overshoot() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage2-a" \
        "tenant-stage2-a" \
        "11111111111111111111111111111111_demo-shared-free" \
        "http://synthetic-flapjack.test"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="80,130,130" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "tenant A execute should stop once a post-write poll shows the storage floor is safely met, even if the batch overshoots the upper tolerance"

    local mapped_flapjack_uid mapped_flapjack_url storage_poll_count write_count
    mapped_flapjack_uid="$(mapping_json_field_or_empty "flapjack_uid")"
    mapped_flapjack_url="$(mapping_json_field_or_empty "flapjack_url")"
    storage_poll_count=$(grep -c "${mapped_flapjack_url}/internal/storage" "$curl_log" || true)
    write_count=$(grep -c "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/batch" "$curl_log" || true)

    if [ "$storage_poll_count" -eq 2 ]; then
        pass "storage-floor contract should stop after the first post-write poll confirms the floor is already exceeded"
    else
        fail "storage-floor contract should not keep polling after an uncorrectable overshoot (polls=$storage_poll_count)"
    fi

    if [ "$write_count" -eq 1 ]; then
        pass "storage-floor contract should stop issuing writes once the post-write poll shows the floor is already exceeded"
    else
        fail "storage-floor contract should not keep writing after an overshoot it cannot correct (writes=$write_count)"
    fi

    assert_not_contains "$RUN_OUTPUT" "did not converge" \
        "storage-floor contract should not fail closed after an overshoot when the storage floor is already satisfied"
}

test_tenant_a_execute_starts_sustained_traffic_after_floor_is_met() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local sleep_log="$tmp_dir/sleep.log"
    local direct_documents_count_path="$tmp_dir/direct-documents.count"
    local direct_query_count_path="$tmp_dir/direct-query.count"
    local mapped_flapjack_uid="mapped-node-a-uid"
    local mapped_flapjack_url="http://synthetic-node-a.test"

    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage4-a" \
        "tenant-stage4-a" \
        "$mapped_flapjack_uid" \
        "$mapped_flapjack_url"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin" "$sleep_log"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    : > "$direct_documents_count_path"
    : > "$direct_query_count_path"
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    MOCK_SYNTHETIC_STORAGE_UID="$mapped_flapjack_uid" \
    MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH="$direct_documents_count_path" \
    MOCK_SYNTHETIC_DIRECT_QUERY_COUNT_PATH="$direct_query_count_path" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "tenant A execute should start direct-node sustained traffic only after storage floor checks pass"

    local curl_calls direct_documents_count direct_query_count unexpected_sleep_args
    curl_calls="$(read_file_or_empty "$curl_log")"
    direct_documents_count="$(read_counter_file_or_zero "$direct_documents_count_path")"
    direct_query_count="$(read_counter_file_or_zero "$direct_query_count_path")"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/internal/storage" \
        "tenant A execute should poll storage on the mapped node before sustained traffic starts"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/internal/storage -H X-Algolia-API-Key: synthetic-flapjack-api-key -H X-Algolia-Application-Id: flapjack" \
        "tenant A execute should send the required Application-Id header when polling mapped-node storage"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/batch" \
        "tenant A execute should send sustained writes to mapped node URL plus mapped flapjack_uid via the direct batch route"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/batch -H Content-Type: application/json -H X-Algolia-API-Key: synthetic-flapjack-api-key -H X-Algolia-Application-Id: flapjack" \
        "tenant A execute should include the required Application-Id header on direct mapped-node batch writes"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/query" \
        "tenant A execute should send searches to /query using mapped node URL plus mapped flapjack_uid"
    assert_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/query -H Content-Type: application/json -H X-Algolia-API-Key: synthetic-flapjack-api-key -H X-Algolia-Application-Id: flapjack" \
        "tenant A execute should include the required Application-Id header on direct mapped-node searches"
    assert_not_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/demo-shared-free/" \
        "tenant A execute should not re-derive direct-node UID from tenant name"
    assert_not_contains "$curl_calls" "${mapped_flapjack_url}/1/indexes/${mapped_flapjack_uid}/search" \
        "tenant A execute should never call /search when driving direct-node traffic"
    assert_eq "$direct_documents_count" "10" \
        "tenant A execute should issue exactly ten direct /batch writes for --duration-minutes 1"
    assert_eq "$direct_query_count" "1" \
        "tenant A execute should issue exactly one direct /query search for --duration-minutes 1"
    assert_eq "$(line_count_or_zero "$sleep_log")" "9" \
        "tenant A execute should perform nine fractional write-pacing sleeps between ten write requests"
    unexpected_sleep_args="$(grep -Ev '^6\.000000$' "$sleep_log" || true)"
    assert_eq "$unexpected_sleep_args" "" \
        "tenant A execute should use per-minute fractional sleep seconds for write pacing"

    if [ -f "${TENANT_A_MAPPING_PATH}.writes.count" ] || [ -f "${TENANT_A_MAPPING_PATH}.searches.count" ]; then
        fail "tenant A execute should clean up short-lived sustained-traffic count files"
    else
        pass "tenant A execute should clean up short-lived sustained-traffic count files"
    fi
}

test_tenant_a_execute_cleans_count_files_when_search_loop_fails() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local mapped_flapjack_uid="mapped-node-a-uid"
    local mapped_flapjack_url="http://synthetic-node-a.test"

    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage4-a" \
        "tenant-stage4-a" \
        "$mapped_flapjack_uid" \
        "$mapped_flapjack_url"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    MOCK_SYNTHETIC_STORAGE_UID="$mapped_flapjack_uid" \
    MOCK_SYNTHETIC_FAIL_QUERY_ON_CALL="1" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "tenant A execute should fail closed when the direct /query loop returns an error"
    assert_contains "$RUN_OUTPUT" "sustained search failed" \
        "tenant A execute should report the mapped direct-node /query failure"
    assert_not_contains "$RUN_OUTPUT" "BrokenPipeError" \
        "tenant A execute should not leak payload-generator tracebacks while cleaning up failed sustained traffic"

    if [ -f "${TENANT_A_MAPPING_PATH}.writes.count" ] || [ -f "${TENANT_A_MAPPING_PATH}.searches.count" ]; then
        fail "failed sustained traffic should still clean up short-lived count files"
    else
        pass "failed sustained traffic should still clean up short-lived count files"
    fi
}

test_tenant_a_execute_stops_writes_when_search_loop_fails() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    local direct_documents_count_path="$tmp_dir/direct-documents.count"
    local mapped_flapjack_uid="mapped-node-a-uid"
    local mapped_flapjack_url="http://synthetic-node-a.test"

    stash_tenant_a_mapping_artifact "$mapping_backup"
    write_tenant_a_mapping_artifact \
        "customer-stage4-a" \
        "tenant-stage4-a" \
        "$mapped_flapjack_uid" \
        "$mapped_flapjack_url"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    : > "$direct_documents_count_path"
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    MOCK_SYNTHETIC_STORAGE_UID="$mapped_flapjack_uid" \
    MOCK_SYNTHETIC_DIRECT_DOCUMENTS_COUNT_PATH="$direct_documents_count_path" \
    MOCK_SYNTHETIC_FAIL_QUERY_ON_CALL="1" \
    MOCK_SYNTHETIC_SLEEP_DELAY_ARG="6.000000" \
    MOCK_SYNTHETIC_SLEEP_DELAY_SECONDS="0.2" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    local direct_documents_count
    direct_documents_count="$(read_counter_file_or_zero "$direct_documents_count_path")"

    assert_eq "$RUN_EXIT_CODE" "1" \
        "tenant A execute should fail closed when sustained traffic search routing fails"
    if [ "$direct_documents_count" -lt 10 ]; then
        pass "tenant A execute should stop the write loop instead of waiting for all writes after search failure"
    else
        fail "tenant A execute should stop sibling writes promptly after search failure (writes=$direct_documents_count)"
    fi
}

test_staging_execute_seam_is_explicitly_gated() {
    # Stage 5 hypothesis: a tenant A execute run writes fresh usage_records rows
    # attributed to the persisted customer_id and canonical tenant_id mapping.
    if [ "${RUN_SYNTHETIC_STAGING_LIVE_TESTS:-0}" != "1" ]; then
        pass "staging execute seam is gated behind RUN_SYNTHETIC_STAGING_LIVE_TESTS=1"
        return 0
    fi

    if [ -z "${SYNTHETIC_STAGING_ENV_FILE:-}" ]; then
        fail "live staging seam requires SYNTHETIC_STAGING_ENV_FILE when RUN_SYNTHETIC_STAGING_LIVE_TESTS=1"
        return 0
    fi

    if [ ! -f "$SYNTHETIC_STAGING_ENV_FILE" ]; then
        fail "live staging seam env file does not exist: $SYNTHETIC_STAGING_ENV_FILE"
        return 0
    fi

    if [ "${SYNTHETIC_STAGING_LIVE_ACK:-}" != "i-know-this-hits-staging" ]; then
        fail "live staging seam requires SYNTHETIC_STAGING_LIVE_ACK=i-know-this-hits-staging"
        return 0
    fi

    local run_start
    run_start="$(capture_run_start_utc)"

    local live_output live_exit=0
    live_output=$(
        set -a
        # shellcheck disable=SC1090
        source "$SYNTHETIC_STAGING_ENV_FILE"
        set +a
        bash "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" \
            --tenant A \
            --execute \
            --i-know-this-hits-staging \
            --duration-minutes "${SYNTHETIC_STAGING_DURATION_MINUTES:-5}" 2>&1
    ) || live_exit=$?

    if [ "$live_exit" -ne 0 ]; then
        fail "live staging seam should be reusable after explicit opt-in (exit=$live_exit output=$live_output)"
        return 0
    fi
    pass "live staging seam executes tenant A only after explicit opt-in and env-file gate"

    if ! require_tenant_a_mapping_artifact; then
        return 0
    fi

    local mapped_customer_id mapped_tenant_id mapped_flapjack_uid mapped_flapjack_url
    mapped_customer_id="$(mapping_json_field_or_fail "customer_id" "stage5 live proof")" || return 0
    mapped_tenant_id="$(mapping_json_field_or_fail "tenant_id" "stage5 live proof")" || return 0
    mapped_flapjack_uid="$(mapping_json_field_or_fail "flapjack_uid" "stage5 live proof")" || return 0
    mapped_flapjack_url="$(mapping_json_field_or_fail "flapjack_url" "stage5 live proof")" || return 0

    local usage_rows usage_rows_exit=0 usage_row_count
    usage_rows=$(
        set -a
        # shellcheck disable=SC1090
        source "$SYNTHETIC_STAGING_ENV_FILE"
        set +a
        psql "$DATABASE_URL" \
            -v ON_ERROR_STOP=1 \
            -v customer_id="$mapped_customer_id" \
            -v tenant_id="$mapped_tenant_id" \
            -v run_start="$run_start" \
            -A -F '|' -t \
            -c "SELECT customer_id::text,
                       tenant_id::text,
                       event_type,
                       value::text,
                       to_char(recorded_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"') AS recorded_at
                FROM usage_records
                WHERE customer_id = :'customer_id'::uuid
                  AND tenant_id = :'tenant_id'::uuid
                  AND recorded_at >= TIMESTAMPTZ :'run_start'
                ORDER BY recorded_at DESC
                LIMIT 20;" 2>&1
    ) || usage_rows_exit=$?
    if [ "$usage_rows_exit" -ne 0 ]; then
        fail "stage5 live proof usage_records query should succeed (exit=$usage_rows_exit output=$usage_rows)"
        return 0
    fi
    usage_row_count="$(printf '%s\n' "$usage_rows" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]')"
    if [ "$usage_row_count" -lt 1 ]; then
        fail "stage5 live proof expected fresh usage_records rows for mapped customer/tenant since run_start=$run_start (customer_id=$mapped_customer_id tenant_id=$mapped_tenant_id flapjack_uid=$mapped_flapjack_uid flapjack_url=$mapped_flapjack_url)"
        printf '%s\n' "stage5 usage_records evidence: no rows" >&2
        return 0
    fi
    pass "stage5 live proof found fresh usage_records attribution rows after run_start=$run_start (rows=$usage_row_count)"
    printf '%s\n' "stage5 usage_records evidence (customer_id|tenant_id|event_type|value|recorded_at_utc):"
    printf '%s\n' "$usage_rows"

    local usage_daily_rows usage_daily_exit=0
    usage_daily_rows=$(
        set -a
        # shellcheck disable=SC1090
        source "$SYNTHETIC_STAGING_ENV_FILE"
        set +a
        psql "$DATABASE_URL" \
            -v ON_ERROR_STOP=1 \
            -v customer_id="$mapped_customer_id" \
            -v tenant_id="$mapped_tenant_id" \
            -A -F '|' -t \
            -c "SELECT customer_id::text,
                       tenant_id::text,
                       usage_date::text,
                       event_type,
                       sum_value::text
                FROM usage_daily
                WHERE customer_id = :'customer_id'::uuid
                  AND tenant_id = :'tenant_id'::uuid
                ORDER BY usage_date DESC, event_type
                LIMIT 20;" 2>&1
    ) || usage_daily_exit=$?
    handle_stage5_optional_usage_daily_follow_on "$usage_daily_exit" "$usage_daily_rows"
}

test_stage5_optional_usage_daily_query_error_is_non_gating() {
    local baseline_fail
    baseline_fail="$FAIL_COUNT"

    local helper_output helper_exit=0
    helper_output="$(handle_stage5_optional_usage_daily_follow_on "1" "ERROR: relation \\\"usage_daily\\\" does not exist" 2>&1)" || helper_exit=$?

    assert_eq "$helper_exit" "0" \
        "stage5 optional usage_daily follow-on helper should return success when query errors"
    assert_eq "$FAIL_COUNT" "$baseline_fail" \
        "stage5 optional usage_daily follow-on helper should not gate on query errors"
    assert_not_contains "$helper_output" "FAIL:" \
        "stage5 optional usage_daily follow-on helper should not emit FAIL output on query errors"
    assert_contains "$helper_output" "PASS: stage5 optional usage_daily follow-on query is unavailable" \
        "stage5 optional usage_daily follow-on helper should emit PASS output on query errors"
    assert_contains "$helper_output" "usage_daily follow-on" \
        "stage5 optional usage_daily follow-on helper should emit evidence text on query errors"
    pass "stage5 optional usage_daily follow-on helper should contribute positive evidence when query errors"
}

test_stage6_docs_publish_verified_contract_and_blocker_state() {
    local env_doc="$REPO_ROOT/docs/env-vars.md"
    local plan_doc="$REPO_ROOT/docs/launch/synthetic_traffic_seeder_plan.md"
    local env_text plan_text

    env_text="$(cat "$env_doc")"
    plan_text="$(cat "$plan_doc")"

    assert_contains "$env_text" "synthetic traffic seeder" \
        "env vars doc should include a synthetic traffic seeder subsection"
    assert_contains "$env_text" "DATABASE_URL" \
        "env vars doc should list DATABASE_URL in the synthetic execute contract"
    assert_contains "$env_text" "API_URL" \
        "env vars doc should list API_URL in the synthetic execute contract"
    assert_contains "$env_text" "ADMIN_KEY" \
        "env vars doc should list ADMIN_KEY in the synthetic execute contract"
    assert_contains "$env_text" "FLAPJACK_URL" \
        "env vars doc should list FLAPJACK_URL in the synthetic execute contract"
    assert_contains "$env_text" "FLAPJACK_API_KEY" \
        "env vars doc should list FLAPJACK_API_KEY in the synthetic execute contract"
    assert_contains "$env_text" "RUN_SYNTHETIC_STAGING_LIVE_TESTS" \
        "env vars doc should list the live seam opt-in gate"
    assert_contains "$env_text" "SYNTHETIC_STAGING_LIVE_ACK" \
        "env vars doc should list the live seam acknowledgement gate"
    assert_contains "$env_text" "SYNTHETIC_STAGING_ENV_FILE" \
        "env vars doc should list the live seam env-file gate"
    assert_contains "$env_text" "SYNTHETIC_STAGING_DURATION_MINUTES" \
        "env vars doc should list the optional live seam duration override"
    assert_contains "$env_text" "--tenant A" \
        "env vars doc should publish that execute mode supports tenant A only"
    assert_contains "$env_text" "--tenant B, --tenant C, and --tenant all" \
        "env vars doc should publish unsupported execute selectors explicitly"

    assert_contains "$plan_text" "ensure_customer_and_tenant" \
        "seeder plan doc should describe the implemented provisioning flow"
    assert_contains "$plan_text" "seed_documents_to_target_size" \
        "seeder plan doc should describe the implemented storage convergence flow"
    assert_contains "$plan_text" "drive_sustained_writes_and_searches" \
        "seeder plan doc should describe the implemented sustained-traffic flow"
    assert_contains "$plan_text" "/tmp/seed-synthetic-demo-shared-free.json" \
        "seeder plan doc should anchor evidence to the persisted tenant A mapping artifact"
    assert_contains "$plan_text" "Latest recorded outcome" \
        "seeder plan doc should publish the latest staging blocker text when still failing"
    assert_contains "$plan_text" "status=403" \
        "seeder plan doc should include the current 403 blocker details from the latest live evidence"
    assert_contains "$plan_text" "Invalid Application-ID or API key" \
        "seeder plan doc should include the current direct-node auth blocker detail"
    assert_contains "$plan_text" "usage_records" \
        "seeder plan doc should include usage_records evidence status"
    assert_contains "$plan_text" "usage_daily" \
        "seeder plan doc should mark usage_daily as optional follow-on evidence"
    assert_contains "$plan_text" "sync-stripe" \
        "seeder plan doc should keep sync-stripe readiness claims evidence-bound"
    assert_contains "$plan_text" "unproven" \
        "seeder plan doc should label unevidenced readiness as unproven or blocked"
    pass "stage6 docs publish the verified synthetic contract and current blocker state"
}

# Source the seeder so the under-test functions are addressable as bash
# functions inside this test process. Guard against the script's top-level
# argument parser by passing --tenant A --dry-run and immediately preempting
# main execution via SEEDER_TEST_MODE. The seeder does not honor that env var
# yet — these tests therefore source the file inside a subshell that exits
# before run_tenant fires, by interposing a dummy argv that prints help and
# exits cleanly.
load_seed_synthetic_functions() {
    # We only need the function definitions; suppress the script's main flow
    # by trapping the entry into "case "${TENANT_SELECTOR}"" via a no-op
    # subshell and explicit return. The cleanest approach in bash 3.2 is to
    # source under `set +e` and rely on the seeder's preflight gate.
    set +e
    # shellcheck disable=SC1091
    SEED_SYNTHETIC_NO_AUTO_RUN=1 source "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" --tenant A --dry-run >/dev/null 2>&1
    set -e
}

test_node_api_key_for_url_returns_env_override_when_flapjack_api_key_is_set() {
    (
        load_seed_synthetic_functions
        local resolved
        FLAPJACK_API_KEY="env-override-key" \
            resolved="$(node_api_key_for_url "http://synthetic-flapjack.test:7700")"
        assert_eq "$resolved" "env-override-key" \
            "node_api_key_for_url should honor FLAPJACK_API_KEY env override (test/local seam)"
    )
}

test_node_api_key_for_url_caches_per_host_to_avoid_repeat_lookups() {
    (
        load_seed_synthetic_functions

        # In-process cache lives on the current shell; we must not stage
        # function invocations through a subshell ($(...)). Capture stdout
        # via a temp file instead, so the dynamic cache-var assignment
        # persists between calls in the same shell.
        local cache_probe="$REPO_ROOT/.test-node-key-cache-probe"
        : > "$cache_probe"
        FLAPJACK_API_KEY="cached-key"
        node_api_key_for_url "http://vm-shared-cache.flapjack.foo:7700" > "$cache_probe"
        local first
        first="$(cat "$cache_probe")"
        : > "$cache_probe"
        unset FLAPJACK_API_KEY
        # Second call must succeed even with FLAPJACK_API_KEY unset, because
        # the per-host result was cached in-process during the first call.
        node_api_key_for_url "http://vm-shared-cache.flapjack.foo:7700" > "$cache_probe"
        local second
        second="$(cat "$cache_probe")"
        rm -f "$cache_probe"
        assert_eq "$first" "cached-key" \
            "first node_api_key_for_url call should return the override value"
        assert_eq "$second" "cached-key" \
            "second node_api_key_for_url call should return the cached value without falling back to SSM"
    )
}

test_node_api_key_for_url_dies_when_url_has_no_host() {
    (
        load_seed_synthetic_functions
        local exit_code=0
        local output
        output="$(FLAPJACK_API_KEY="any-key" node_api_key_for_url "not-a-url" 2>&1)" || exit_code=$?
        if [ "$exit_code" -eq 0 ]; then
            fail "node_api_key_for_url should fail closed when the flapjack_url has no host (got exit_code=0, output=$output)"
        else
            pass "node_api_key_for_url fails closed when the flapjack_url has no host"
        fi
        assert_contains "$output" "failed to parse host" \
            "node_api_key_for_url failure should explain that host parsing failed"
    )
}

test_duration_minutes_zero_is_a_supported_provisioning_only_seam() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    # --duration-minutes 0 is a legitimate seam: provision tenant + converge
    # storage but skip sustained traffic. Used by every stage2/stage3 contract
    # test that wants to verify earlier stages without paying for the loop.
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200,200" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    assert_eq "$RUN_EXIT_CODE" "0" \
        "--duration-minutes 0 should succeed (provisioning-only seam used by contract tests and operational provisioning runs)"
    assert_not_contains "$RUN_OUTPUT" "must be greater than zero" \
        "--duration-minutes 0 should not be rejected as invalid; it is a supported skip-sustained-traffic mode"
}

test_storage_floor_treats_absent_tenant_uid_as_zero_mb() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local mapping_backup="$tmp_dir/tenant_a_mapping.backup"
    trap 'restore_tenant_a_mapping_artifact "'"$mapping_backup"'"; rm -rf "'"$tmp_dir"'"' RETURN

    local curl_log="$tmp_dir/curl.log"
    local psql_log="$tmp_dir/psql.log"
    local psql_stdin="$tmp_dir/psql.stdin"
    stash_tenant_a_mapping_artifact "$mapping_backup"
    setup_mock_workspace "$tmp_dir" "$curl_log" "$psql_log" "$psql_stdin"

    clear_mock_logs "$curl_log" "$psql_log" "$psql_stdin"
    # Force the mock /internal/storage to return a tenants array that does
    # NOT contain our mapped flapjack_uid. This mirrors the live state on a
    # freshly-created index where flapjack hasn't recorded any bytes yet.
    # The seeder must treat the missing entry as 0 MB rather than failing.
    MOCK_SYNTHETIC_DURATION_MINUTES="0" \
    MOCK_SYNTHETIC_STORAGE_MB_SEQUENCE="200" \
    MOCK_SYNTHETIC_STORAGE_UID="some-other-tenant-uid-not-in-the-mapping" \
    run_seed_synthetic_execute "$tmp_dir" "A"

    if [ "$RUN_EXIT_CODE" -ne 0 ] && printf '%s' "$RUN_OUTPUT" | grep -q "storage poll missing mapped tenant"; then
        fail "seeder must NOT die when /internal/storage omits the mapped tenant uid (was: $RUN_OUTPUT)"
    else
        pass "seeder treats absent tenant in /internal/storage as 0 MB (live freshly-created-index contract)"
    fi
}

test_preflight_env_does_not_require_flapjack_api_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    setup_mock_workspace "$tmp_dir" "$tmp_dir/curl.log" "$tmp_dir/psql.log" "$tmp_dir/psql.stdin"

    # Run execute with FLAPJACK_API_KEY explicitly UNSET. preflight_env should
    # no longer fail closed on its absence; the script may fail later on the
    # first SSM lookup, but the failure must NOT be the legacy
    # "missing required env vars: FLAPJACK_API_KEY" path.
    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        API_URL="http://synthetic-api.test" \
        ADMIN_KEY="synthetic-admin-key" \
        DATABASE_URL="postgres://synthetic" \
        FLAPJACK_URL="http://synthetic-flapjack.test" \
        env -u FLAPJACK_API_KEY \
        bash "$REPO_ROOT/scripts/launch/seed_synthetic_traffic.sh" \
            --tenant A --execute --i-know-this-hits-staging --duration-minutes 1 2>&1
    ) || exit_code=$?

    if printf '%s' "$output" | grep -q "missing required env vars:.*FLAPJACK_API_KEY"; then
        fail "preflight_env should not require FLAPJACK_API_KEY anymore (per-VM SSM lookup is the canonical path); got: $output"
    else
        pass "preflight_env no longer requires FLAPJACK_API_KEY (per-VM SSM resolution is the canonical path)"
    fi
}

main() {
    echo "=== seed_synthetic_traffic.sh tests ==="
    echo ""

    local test_slice="${SEED_SYNTHETIC_TRAFFIC_TEST_SLICE:-full}"
    case "$test_slice" in
        stage2)
            test_dry_run_contracts_cover_A_B_C_and_all_without_mutation_calls
            test_execute_requires_staging_ack_before_preflight_or_mutation_calls
            test_execute_guard_fails_closed_for_all_selectors_before_mutations
            test_provisioning_contract_first_run_pins_create_update_and_index_fields
            test_provisioning_contract_rerun_is_idempotent_without_duplicate_create_calls
            test_seed_index_accepts_200_ok_from_idempotent_rerun_path
            test_provisioning_contract_recovers_when_create_409_omits_customer_id
            ;;
        stage3)
            test_storage_floor_contract_skips_backfill_when_target_already_met
            test_storage_floor_contract_polls_until_usage_converges
            test_storage_floor_contract_stops_after_above_tolerance_overshoot
            ;;
        stage4)
            test_tenant_a_execute_starts_sustained_traffic_after_floor_is_met
            test_tenant_a_execute_cleans_count_files_when_search_loop_fails
            test_tenant_a_execute_stops_writes_when_search_loop_fails
            ;;
        stage5)
            test_stage5_optional_usage_daily_query_error_is_non_gating
            test_staging_execute_seam_is_explicitly_gated
            ;;
        stage6)
            test_stage6_docs_publish_verified_contract_and_blocker_state
            ;;
        full)
            test_dry_run_contracts_cover_A_B_C_and_all_without_mutation_calls
            test_execute_requires_staging_ack_before_preflight_or_mutation_calls
            test_execute_guard_fails_closed_for_all_selectors_before_mutations
            test_provisioning_contract_first_run_pins_create_update_and_index_fields
            test_provisioning_contract_rerun_is_idempotent_without_duplicate_create_calls
            test_seed_index_accepts_200_ok_from_idempotent_rerun_path
            test_provisioning_contract_recovers_when_create_409_omits_customer_id
            test_storage_floor_contract_skips_backfill_when_target_already_met
            test_storage_floor_contract_polls_until_usage_converges
            test_storage_floor_contract_stops_after_above_tolerance_overshoot
            test_tenant_a_execute_starts_sustained_traffic_after_floor_is_met
            test_tenant_a_execute_cleans_count_files_when_search_loop_fails
            test_tenant_a_execute_stops_writes_when_search_loop_fails
            test_stage5_optional_usage_daily_query_error_is_non_gating
            test_staging_execute_seam_is_explicitly_gated
            test_stage6_docs_publish_verified_contract_and_blocker_state
            test_node_api_key_for_url_returns_env_override_when_flapjack_api_key_is_set
            test_node_api_key_for_url_caches_per_host_to_avoid_repeat_lookups
            test_node_api_key_for_url_dies_when_url_has_no_host
            test_preflight_env_does_not_require_flapjack_api_key
            test_storage_floor_treats_absent_tenant_uid_as_zero_mb
            test_duration_minutes_zero_is_a_supported_provisioning_only_seam
            ;;
        *)
            fail "unknown SEED_SYNTHETIC_TRAFFIC_TEST_SLICE: $test_slice (expected: full, stage2, stage3, stage4, stage5, or stage6)"
            ;;
    esac

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
