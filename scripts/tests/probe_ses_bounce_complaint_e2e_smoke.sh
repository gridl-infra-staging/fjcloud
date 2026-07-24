#!/usr/bin/env bash
# Smoke tests for scripts/probe_ses_bounce_complaint_e2e.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROBE_SCRIPT="$REPO_ROOT/scripts/probe_ses_bounce_complaint_e2e.sh"

# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/test_helpers.sh
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

RUN_STDOUT=""
RUN_STDERR=""
RUN_EXIT_CODE=0

json_get_top_field() {
    local json="$1" field="$2"
    python3 - "$json" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
value = payload.get(sys.argv[2], "")
if isinstance(value, bool):
    print("true" if value else "false")
else:
    print(str(value))
PY
}

json_get_step_field() {
    local json="$1" step_name="$2" field="$3"
    python3 - "$json" "$step_name" "$field" <<'PY' 2>/dev/null || echo ""
import json
import sys
payload = json.loads(sys.argv[1])
step_name = sys.argv[2]
field = sys.argv[3]
for step in payload.get("steps", []):
    if step.get("name") == step_name:
        value = step.get(field, "")
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(str(value))
        break
else:
    print("")
PY
}

mock_psql_body() {
    cat <<'MOCK'
set -euo pipefail
: "${PROBE_TEST_PSQL_LOG:?missing PROBE_TEST_PSQL_LOG}"
printf '%s\n' "$*" >> "$PROBE_TEST_PSQL_LOG"

query="${*: -1}"
mode="${PROBE_TEST_PSQL_MODE:-success}"

if [[ "$query" == *"INSERT INTO customers"* ]]; then
    echo "11111111-1111-1111-1111-111111111111"
    exit 0
fi

if [[ "$query" == *"DELETE FROM email_log"* || "$query" == *"DELETE FROM email_suppression"* || "$query" == *"DELETE FROM audit_log"* ]]; then
    echo "DELETE 1"
    exit 0
fi

if [[ "$query" == *"UPDATE customers"* && "$query" == *"status = 'deleted'"* ]]; then
    echo "1"
    exit 0
fi

if [[ "$query" == *"FROM email_suppression"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        exit 0
    fi
    if [[ "$query" == *"suppression_reason"* ]]; then
        if [[ "${PROBE_TEST_MODE:-bounce}" == "bounce" ]]; then
            echo "bounce_permanent_general"
        else
            echo "complaint"
        fi
    elif [[ "$query" == *"source"* ]]; then
        echo "ses_sns_webhook"
    fi
    exit 0
fi

if [[ "$query" == *"COUNT(*)::BIGINT FROM audit_log"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        echo "0"
    else
        echo "1"
    fi
    exit 0
fi

if [[ "$query" == *"FROM email_log"* && "$query" == *"delivery_status = 'suppressed'"* ]]; then
    if [[ "$mode" == "timeout" ]]; then
        echo "0"
    else
        echo "1"
    fi
    exit 0
fi

if [[ "$mode" == "db_fail" ]]; then
    echo "simulated psql failure" >&2
    exit 1
fi

echo ""
MOCK
}

mock_staging_db_body() {
    cat <<'MOCK'
staging_db_run_sql() {
    local database_url="$1"
    local query="$2"

    if [ -n "${PROBE_TEST_STAGING_DB_LOG:-}" ]; then
        printf '%s\n' "$database_url" >> "$PROBE_TEST_STAGING_DB_LOG"
    fi
    if [ "${PROBE_TEST_FAIL_ON_STAGING_DB_RUN_SQL:-false}" = "true" ]; then
        echo "staging_db_run_sql should not be used for this fixture" >&2
        return 1
    fi

    psql -v ON_ERROR_STOP=1 -X -t -A "$database_url" -c "$query"
}
MOCK
}

mock_customer_broadcast_body() {
    cat <<'MOCK'
set -euo pipefail
: "${PROBE_TEST_BROADCAST_LOG:?missing PROBE_TEST_BROADCAST_LOG}"
: "${PROBE_TEST_BROADCAST_ENV_LOG:?missing PROBE_TEST_BROADCAST_ENV_LOG}"
printf '%s\n' "$*" >> "$PROBE_TEST_BROADCAST_LOG"

subject=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --subject)
            subject="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

admin_key_present=false
if [ -n "${ADMIN_KEY:-}" ]; then
    admin_key_present=true
fi
admin_key_sha256="$(python3 - <<'PY'
import hashlib
import os

print(hashlib.sha256(os.environ.get("ADMIN_KEY", "").encode("utf-8")).hexdigest())
PY
)"
printf 'subject=%s admin_key_present=%s admin_key_sha256=%s\n' "$subject" "$admin_key_present" "$admin_key_sha256" >> "$PROBE_TEST_BROADCAST_ENV_LOG"

    if [[ "${PROBE_TEST_BROADCAST_MODE:-success}" == "bad_json" ]]; then
        echo "not-json"
        exit 0
    fi

    if [[ "${PROBE_TEST_BROADCAST_MODE:-success}" == "bad_json_second_only" && "$subject" == *"-second"* ]]; then
        echo "not-json"
        exit 0
    fi

    if [[ "$subject" == *"-second"* ]]; then
        echo '{"mode":"live_send","suppressed_count":1,"attempted_count":2,"success_count":1,"failure_count":0}'
    else
    echo '{"mode":"live_send","suppressed_count":0,"attempted_count":2,"success_count":2,"failure_count":0}'
fi
MOCK
}

setup_mock_env() {
    local tmp_dir="$1"
    mkdir -p "$tmp_dir/bin"
    write_mock_script "$tmp_dir/bin/psql" "$(mock_psql_body)"
    write_mock_script "$tmp_dir/mock_customer_broadcast.sh" "$(mock_customer_broadcast_body)"
}

make_env_file() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL=postgres://user:pass@localhost:5432/fjcloud
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF_ENV
}

make_env_file_with_ssm_db_param() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF_ENV
}

make_env_file_with_prod_ssm_db_param() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
ADMIN_KEY=admin_prod_key
DATABASE_URL_SSM_PARAM=/fjcloud/prod/database_url
SES_REGION=us-east-1
EOF_ENV
}

make_env_file_with_direct_db_and_ssm_db_param() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL=postgres://user:pass@localhost:5432/fjcloud
DATABASE_URL_SSM_PARAM=/fjcloud/staging/database_url
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF_ENV
}

make_env_file_with_noncanonical_ssm_db_param() {
    local path="$1"
    cat > "$path" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL_SSM_PARAM=/fjcloud/staging/replica_database_url
SES_FROM_ADDRESS=system@flapjack.foo
SES_REGION=us-east-1
EOF_ENV
}

setup_hydration_probe_repo() {
    local tmp_dir="$1"
    local probe_repo="$tmp_dir/probe_repo"
    mkdir -p "$probe_repo/scripts/lib" "$probe_repo/scripts/launch"
    cp "$REPO_ROOT/scripts/probe_ses_bounce_complaint_e2e.sh" "$probe_repo/scripts/probe_ses_bounce_complaint_e2e.sh"
    cp "$REPO_ROOT/scripts/lib/env.sh" \
        "$REPO_ROOT/scripts/lib/validation_json.sh" \
        "$REPO_ROOT/scripts/lib/psql_path.sh" \
        "$REPO_ROOT/scripts/lib/hydrate_staging_env.sh" \
        "$REPO_ROOT/scripts/lib/db_url.sh" \
        "$REPO_ROOT/scripts/lib/staging_db.sh" \
        "$probe_repo/scripts/lib/"
    cat >> "$probe_repo/scripts/lib/staging_db.sh" <<MOCK
$(mock_staging_db_body)
MOCK
    cat > "$probe_repo/scripts/launch/hydrate_seeder_env_from_ssm.sh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
target="${1:-}"
case "$target" in
    staging|prod)
        ;;
    *)
        echo "unexpected hydrate target: $target" >&2
        exit 1
        ;;
esac
printf '%s\n' "$target" > "$HOME/hydrate_target.log"
if [ "$target" = "prod" ]; then
    database_url="postgres://prod-stub"
    api_url="https://api.flapjack.foo"
else
    database_url="postgres://stub"
    api_url="https://staging.flapjack.foo"
fi
if [ "${PROBE_TEST_HYDRATE_PAYLOAD_MODE:-safe}" = "malicious_single_quote" ]; then
    cat <<'EOF_EXPORTS'
export DATABASE_URL='postgres://stub';printf hacked > "$HOME/hydrate_pwned";#'
export API_URL=https://staging.flapjack.foo
export SES_FROM_ADDRESS=system@flapjack.foo
EOF_EXPORTS
    exit 0
fi
cat <<'EOF_EXPORTS'
export SES_FROM_ADDRESS=system@flapjack.foo
EOF_EXPORTS
printf 'export DATABASE_URL=%q\n' "$database_url"
printf 'export API_URL=%q\n' "$api_url"
MOCK
    chmod +x "$probe_repo/scripts/launch/hydrate_seeder_env_from_ssm.sh"
    echo "$probe_repo/scripts/probe_ses_bounce_complaint_e2e.sh"
}

run_probe() {
    local tmp_dir="$1"
    local mode="$2"
    local env_file="$3"
    shift 3

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"

    RUN_EXIT_CODE=0
    env -i \
        HOME="$tmp_dir" \
        PATH="$tmp_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        PROBE_TEST_PSQL_LOG="$tmp_dir/psql.log" \
        PROBE_TEST_STAGING_DB_LOG="$tmp_dir/staging_db.log" \
        PROBE_TEST_BROADCAST_LOG="$tmp_dir/broadcast.log" \
        PROBE_TEST_BROADCAST_ENV_LOG="$tmp_dir/broadcast_env.log" \
        CUSTOMER_BROADCAST_SCRIPT="$tmp_dir/mock_customer_broadcast.sh" \
        SES_PROBE_POLL_MAX_ATTEMPTS=2 \
        SES_PROBE_POLL_SLEEP_SEC=1 \
        "$@" \
        bash "$PROBE_SCRIPT" "$mode" "$env_file" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?

    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
    RUN_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

sha256_text() {
    python3 - "$1" <<'PY'
import hashlib
import sys

print(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())
PY
}

test_probe_script_exists() {
    if [ -f "$PROBE_SCRIPT" ]; then
        pass "probe script should exist"
    else
        fail "probe script should exist at $PROBE_SCRIPT"
    fi
}

test_probe_script_avoids_predictable_assert_temp_paths() {
    if rg -n '/tmp/probe_broadcast_(first|second)_assert\.err' "$PROBE_SCRIPT" >/dev/null; then
        fail "probe script should not use predictable /tmp paths for broadcast response assertion stderr"
    else
        pass "probe script should avoid predictable /tmp paths for broadcast response assertion stderr"
    fi
}

test_missing_mode_and_env_file_fails_with_usage_json() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN

    local stdout_file="$tmp_dir/stdout.log"
    local stderr_file="$tmp_dir/stderr.log"
    RUN_EXIT_CODE=0
    env -i HOME="$tmp_dir" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$PROBE_SCRIPT" >"$stdout_file" 2>"$stderr_file" || RUN_EXIT_CODE=$?
    RUN_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing args should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "missing args should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "missing args JSON should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "Usage" "missing args detail should include usage guidance"
}

test_invalid_mode_fails_before_external_calls() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "hard-bounce" "$env_file" "PROBE_TEST_MODE=bounce"

    local psql_calls="0"
    if [ -f "$tmp_dir/psql.log" ]; then
        psql_calls="$(wc -l < "$tmp_dir/psql.log" | tr -d "[:space:]")"
    fi

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "invalid mode should fail with usage exit code"
    assert_valid_json "$RUN_STDOUT" "invalid mode should emit machine-readable JSON"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "Invalid mode" "invalid mode detail should be explicit"
    assert_eq "$psql_calls" "0" "invalid mode should not execute DB calls"
}

test_missing_required_env_fails_preflight() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    cat > "$env_file" <<'EOF_ENV'
API_URL=https://staging.flapjack.foo
ADMIN_KEY=admin_stage_key
DATABASE_URL=postgres://user:pass@localhost:5432/fjcloud
SES_REGION=us-east-1
EOF_ENV
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "missing SES_FROM_ADDRESS should fail preflight"
    assert_valid_json "$RUN_STDOUT" "preflight failure should emit machine-readable JSON"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "SES_FROM_ADDRESS" "missing env detail should name SES_FROM_ADDRESS"
}

test_missing_db_url_hydrates_and_reaches_sns_poll_contract() {
    local tmp_dir env_file original_probe_script
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file_with_ssm_db_param "$env_file"
    setup_mock_env "$tmp_dir"

    original_probe_script="$PROBE_SCRIPT"
    PROBE_SCRIPT="$(setup_hydration_probe_repo "$tmp_dir")"
    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce"
    PROBE_SCRIPT="$original_probe_script"

    local broadcast_calls broadcast_log psql_log staging_db_log
    broadcast_calls="0"
    if [ -f "$tmp_dir/broadcast.log" ]; then
        broadcast_calls="$(wc -l < "$tmp_dir/broadcast.log" | tr -d "[:space:]")"
    fi
    broadcast_log="$(cat "$tmp_dir/broadcast.log" 2>/dev/null || true)"
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"
    staging_db_log="$(cat "$tmp_dir/staging_db.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    local broadcast_invoked db_url_used staging_db_runner_used actual_contract expected_contract
    broadcast_invoked=false
    if [[ "$broadcast_log" == *"--live-send"* ]]; then
        broadcast_invoked=true
    fi
    db_url_used=false
    if [[ "$psql_log" == *"postgres://stub"* ]]; then
        db_url_used=true
    fi
    staging_db_runner_used=false
    if [[ "$staging_db_log" == *"postgres://stub"* ]]; then
        staging_db_runner_used=true
    fi
    actual_contract="exit=$RUN_EXIT_CODE passed=$(json_get_top_field "$RUN_STDOUT" "passed") preflight=$(json_get_step_field "$RUN_STDOUT" "preflight" "passed") poll=$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "passed") broadcasts=$broadcast_calls broadcast_invoked=$broadcast_invoked db_url_used=$db_url_used staging_db_runner_used=$staging_db_runner_used"
    expected_contract="exit=0 passed=true preflight=true poll=true broadcasts=2 broadcast_invoked=true db_url_used=true staging_db_runner_used=true"
    assert_eq "$actual_contract" "$expected_contract" "SSM-hydrated DB URL contract should continue through mocked suppression polling"
    assert_valid_json "$RUN_STDOUT" "SSM-hydrated DB URL probe should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "second_live_send" "passed")" "true" "SSM-hydrated DB URL contract should complete the second send"
}

test_malicious_ssm_export_line_is_rejected_before_source() {
    local tmp_dir env_file original_probe_script
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file_with_ssm_db_param "$env_file"
    setup_mock_env "$tmp_dir"

    original_probe_script="$PROBE_SCRIPT"
    PROBE_SCRIPT="$(setup_hydration_probe_repo "$tmp_dir")"
    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce" "PROBE_TEST_HYDRATE_PAYLOAD_MODE=malicious_single_quote"
    PROBE_SCRIPT="$original_probe_script"

    local staging_db_log broadcast_log hydrate_payload_executed
    staging_db_log="$(cat "$tmp_dir/staging_db.log" 2>/dev/null || true)"
    broadcast_log="$(cat "$tmp_dir/broadcast.log" 2>/dev/null || true)"
    hydrate_payload_executed=false
    if [ -e "$tmp_dir/hydrate_pwned" ]; then
        hydrate_payload_executed=true
    fi

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "malicious SSM export line should fail preflight"
    assert_valid_json "$RUN_STDOUT" "malicious SSM export line failure should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "preflight" "passed")" "false" "malicious SSM export line should fail preflight"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "unexpected export line" "malicious SSM export line should be rejected explicitly"
    assert_eq "$staging_db_log" "" "malicious SSM export line should stop before staging DB reads"
    assert_eq "$broadcast_log" "" "malicious SSM export line should stop before broadcasts"
    if [ "$hydrate_payload_executed" = true ]; then
        fail "malicious SSM export line must not execute shell commands while hydrating env"
    else
        pass "malicious SSM export line must not execute shell commands while hydrating env"
    fi
}

test_prod_ssm_db_param_hydrates_prod_env() {
    local tmp_dir env_file original_probe_script
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/prod.env"
    make_env_file_with_prod_ssm_db_param "$env_file"
    setup_mock_env "$tmp_dir"

    original_probe_script="$PROBE_SCRIPT"
    PROBE_SCRIPT="$(setup_hydration_probe_repo "$tmp_dir")"
    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce"
    PROBE_SCRIPT="$original_probe_script"

    local hydrate_target psql_log staging_db_log
    hydrate_target="$(cat "$tmp_dir/hydrate_target.log" 2>/dev/null || true)"
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"
    staging_db_log="$(cat "$tmp_dir/staging_db.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "prod SSM-hydrated DB URL probe should exit 0 in mocked fixture"
    assert_valid_json "$RUN_STDOUT" "prod SSM-hydrated DB URL probe should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "preflight" "passed")" "true" "prod SSM-hydrated DB URL probe should pass preflight"
    assert_eq "$hydrate_target" "prod" "prod SSM DB param should hydrate prod env values"
    assert_contains "$psql_log" "postgres://prod-stub" "prod SSM DB param should use the prod hydrated DB URL"
    assert_contains "$staging_db_log" "postgres://prod-stub" "prod SSM DB param should read through staging_db_run_sql"
}

test_direct_db_url_with_ssm_param_uses_local_psql() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file_with_direct_db_and_ssm_db_param "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce" "PROBE_TEST_FAIL_ON_STAGING_DB_RUN_SQL=true"

    local hydrate_target psql_log staging_db_log
    hydrate_target="$(cat "$tmp_dir/hydrate_target.log" 2>/dev/null || true)"
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"
    staging_db_log="$(cat "$tmp_dir/staging_db.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "direct DB URL with ambient SSM param should exit 0 through local psql"
    assert_valid_json "$RUN_STDOUT" "direct DB URL with ambient SSM param should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "preflight" "passed")" "true" "direct DB URL with ambient SSM param should pass preflight"
    assert_contains "$psql_log" "postgres://user:pass@localhost:5432/fjcloud" "direct DB URL with ambient SSM param should use the direct local DB URL"
    assert_eq "$staging_db_log" "" "direct DB URL with ambient SSM param should not call staging_db_run_sql"
    assert_eq "$hydrate_target" "" "direct DB URL with ambient SSM param should not hydrate from SSM"
}

test_noncanonical_ssm_param_without_direct_db_fails_preflight() {
    local tmp_dir env_file original_probe_script
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file_with_noncanonical_ssm_db_param "$env_file"
    setup_mock_env "$tmp_dir"

    original_probe_script="$PROBE_SCRIPT"
    PROBE_SCRIPT="$(setup_hydration_probe_repo "$tmp_dir")"
    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce"
    PROBE_SCRIPT="$original_probe_script"

    local hydrate_target psql_log staging_db_log broadcast_log
    hydrate_target="$(cat "$tmp_dir/hydrate_target.log" 2>/dev/null || true)"
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"
    staging_db_log="$(cat "$tmp_dir/staging_db.log" 2>/dev/null || true)"
    broadcast_log="$(cat "$tmp_dir/broadcast.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "2" "non-canonical SSM DB param without a direct DB URL should fail preflight"
    assert_valid_json "$RUN_STDOUT" "non-canonical SSM DB param failure should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "false" "non-canonical SSM DB param failure should report passed=false"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "preflight" "passed")" "false" "non-canonical SSM DB param failure should fail preflight"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "preflight" "detail")" "DATABASE_URL_SSM_PARAM must be /fjcloud/staging/database_url or /fjcloud/prod/database_url" "non-canonical SSM DB param failure should name the canonical owner requirement"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "passed")" "" "non-canonical SSM DB param failure should stop before SNS side-effect polling"
    assert_eq "$hydrate_target" "" "non-canonical SSM DB param should not hydrate from SSM"
    assert_eq "$psql_log" "" "non-canonical SSM DB param should not fall back to local psql"
    assert_eq "$staging_db_log" "" "non-canonical SSM DB param should not call staging_db_run_sql"
    assert_eq "$broadcast_log" "" "non-canonical SSM DB param should not send broadcasts"
}

test_poll_timeout_emits_machine_readable_failure() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce" "PROBE_TEST_PSQL_MODE=timeout"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "poll timeout should fail with runtime exit code"
    assert_valid_json "$RUN_STDOUT" "poll timeout should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "passed")" "false" "poll_sns_side_effects should report passed=false"
    assert_contains "$(json_get_step_field "$RUN_STDOUT" "poll_sns_side_effects" "detail")" "Timed out" "poll timeout detail should be explicit"
    assert_contains "$psql_log" "UPDATE customers" "poll timeout should still soft-delete seeded probe customer"
    assert_contains "$psql_log" "status = 'deleted'" "poll timeout cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "poll timeout cleanup should target only the seeded probe customer id"
}

test_first_response_contract_failure_still_cleans_probe_customer() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "complaint" "$env_file" "PROBE_TEST_MODE=complaint" "PROBE_TEST_BROADCAST_MODE=bad_json"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "first response contract failure should exit with runtime code"
    assert_valid_json "$RUN_STDOUT" "response contract failure should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "first_live_send" "passed")" "false" "first_live_send should report passed=false on contract failure"
    assert_contains "$psql_log" "UPDATE customers" "response contract failure should still soft-delete seeded probe customer"
    assert_contains "$psql_log" "status = 'deleted'" "response contract cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "response contract cleanup should target only the seeded probe customer id"
}

test_second_response_contract_failure_still_cleans_probe_customer() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "bounce" "$env_file" "PROBE_TEST_MODE=bounce" "PROBE_TEST_BROADCAST_MODE=bad_json_second_only"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "1" "second response contract failure should exit with runtime code"
    assert_valid_json "$RUN_STDOUT" "second response contract failure should emit machine-readable JSON"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "first_live_send" "passed")" "true" "first_live_send should pass before second response contract failure"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "second_live_send" "passed")" "false" "second_live_send should report passed=false on contract failure"
    assert_contains "$psql_log" "UPDATE customers" "second response contract failure should still soft-delete seeded probe customer"
    assert_contains "$psql_log" "status = 'deleted'" "second response contract cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "second response cleanup should target only the seeded probe customer id"
}

test_successful_probe_runs_two_broadcasts_and_emits_passing_json() {
    local tmp_dir env_file
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "'$tmp_dir'"' RETURN
    env_file="$tmp_dir/staging.env"
    make_env_file "$env_file"
    setup_mock_env "$tmp_dir"

    run_probe "$tmp_dir" "complaint" "$env_file" "PROBE_TEST_MODE=complaint"

    local broadcast_calls
    broadcast_calls="$(wc -l < "$tmp_dir/broadcast.log" | tr -d "[:space:]")"
    local psql_log
    psql_log="$(cat "$tmp_dir/psql.log" 2>/dev/null || true)"
    local broadcast_env_log expected_admin_hash
    broadcast_env_log="$(cat "$tmp_dir/broadcast_env.log" 2>/dev/null || true)"
    expected_admin_hash="$(sha256_text "admin_stage_key")"

    trap - RETURN
    rm -rf "$tmp_dir"

    assert_eq "$RUN_EXIT_CODE" "0" "successful probe should exit 0"
    assert_valid_json "$RUN_STDOUT" "successful probe should emit machine-readable JSON"
    assert_eq "$(json_get_top_field "$RUN_STDOUT" "passed")" "true" "successful probe JSON should report passed=true"
    assert_eq "$broadcast_calls" "2" "successful probe should execute two broadcast calls"
    assert_eq "$(printf '%s\n' "$broadcast_env_log" | sed '/^$/d' | wc -l | tr -d "[:space:]")" "2" "successful probe should record admin-key state for both broadcasts"
    assert_contains "$broadcast_env_log" "admin_key_present=true" "broadcast env log should show admin key present without printing it"
    assert_contains "$broadcast_env_log" "admin_key_sha256=$expected_admin_hash" "broadcast env log should fingerprint the effective admin key"
    assert_not_contains "$broadcast_env_log" "admin_stage_key" "broadcast env log must not print the admin key value"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "first_live_send" "passed")" "true" "first_live_send step should pass"
    assert_eq "$(json_get_step_field "$RUN_STDOUT" "second_live_send" "passed")" "true" "second_live_send step should pass"
    assert_contains "$psql_log" "UPDATE customers" "successful probe should soft-delete probe customer after assertions"
    assert_contains "$psql_log" "status = 'deleted'" "cleanup should set probe customer status to deleted"
    assert_contains "$psql_log" "WHERE id = '11111111-1111-1111-1111-111111111111'" "cleanup should target only the seeded probe customer id"
}

main() {
    echo "=== probe_ses_bounce_complaint_e2e smoke tests ==="

    test_probe_script_exists
    test_probe_script_avoids_predictable_assert_temp_paths
    test_missing_mode_and_env_file_fails_with_usage_json
    test_invalid_mode_fails_before_external_calls
    test_missing_required_env_fails_preflight
    test_missing_db_url_hydrates_and_reaches_sns_poll_contract
    test_malicious_ssm_export_line_is_rejected_before_source
    test_prod_ssm_db_param_hydrates_prod_env
    test_direct_db_url_with_ssm_param_uses_local_psql
    test_noncanonical_ssm_param_without_direct_db_fails_preflight
    test_poll_timeout_emits_machine_readable_failure
    test_first_response_contract_failure_still_cleans_probe_customer
    test_second_response_contract_failure_still_cleans_probe_customer
    test_successful_probe_runs_two_broadcasts_and_emits_passing_json

    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    [ "$FAIL_COUNT" -eq 0 ]
}

main "$@"
