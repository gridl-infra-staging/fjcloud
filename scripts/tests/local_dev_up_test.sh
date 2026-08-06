#!/usr/bin/env bash
# Tests for scripts/local-dev-up.sh: postgres startup, migrations, flapjack,
# startup instructions. Uses mock binaries — does NOT start real services.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_ROOT="$SCRIPT_DIR/fixtures/source-migration"

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
# shellcheck source=lib/local_dev_test_state.sh
source "$SCRIPT_DIR/lib/local_dev_test_state.sh"
# shellcheck source=lib/source_provider_harness.sh
source "$SCRIPT_DIR/lib/source_provider_harness.sh"
# shellcheck source=lib/playwright_port_oracle.sh
source "$SCRIPT_DIR/lib/playwright_port_oracle.sh"

LOCAL_DEV_TEST_DB_URL="postgres://local-test:local-pass@localhost:5432/local_dev_test"
LOCAL_DEV_ALT_PORT_DB_URL="postgres://local-test:local-pass@localhost:15432/local_dev_test"
LOCAL_DEV_REMOTE_HOST_DB_URL="postgres://local-test:local-pass@example.com:5432/local_dev_test"
LOCAL_DEV_INVALID_PORT_DB_URL="postgres://local-test:local-pass@localhost:notaport/local_dev_test"
LOCAL_DEV_OUT_OF_RANGE_PORT_DB_URL="postgres://local-test:local-pass@localhost:70000/local_dev_test"
LOCAL_DEV_TEST_REPO_ROOT=""
LOCAL_DEV_COMPOSE_PROJECT_NAME=""

setup_local_dev_test_migrations() {
    local migrations_dir="$1"
    mkdir -p "$migrations_dir"
    printf '%s\n' '-- local-dev-up hermetic migration fixture' > "$migrations_dir/001_local_dev_up_test.sql"
    export FJCLOUD_HOST_MIGRATIONS_DIR="$migrations_dir"
    export FJCLOUD_DOCKER_MIGRATIONS_DIR="/migrations"
}

setup_local_dev_repo_state() {
    local tmp_dir="$1"
    LOCAL_DEV_TEST_REPO_ROOT="$(create_local_dev_fixture_repo_root "$tmp_dir" "$LOCAL_DEV_TEST_DB_URL")"
    LOCAL_DEV_COMPOSE_PROJECT_NAME="fjcloud_local_dev_up_$$_${RANDOM}"
    mkdir -p "$tmp_dir/bin"
    if [ ! -e "$tmp_dir/bin/lsof" ]; then
        write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    fi
    mkdir -p "$LOCAL_DEV_TEST_REPO_ROOT/infra"
    cp -R "$REPO_ROOT/infra/migrations" "$LOCAL_DEV_TEST_REPO_ROOT/infra/"
    cp "$REPO_ROOT/.env.local.example" "$LOCAL_DEV_TEST_REPO_ROOT/.env.local.example"
    setup_local_dev_test_migrations "$tmp_dir/migrations"
}

restore_local_dev_repo_state() {
    unset FJCLOUD_HOST_MIGRATIONS_DIR
    unset FJCLOUD_DOCKER_MIGRATIONS_DIR
    LOCAL_DEV_TEST_REPO_ROOT=""
    LOCAL_DEV_COMPOSE_PROJECT_NAME=""
}

run_local_dev_up() {
    FJCLOUD_REPO_ROOT="$LOCAL_DEV_TEST_REPO_ROOT" \
    COMPOSE_PROJECT_NAME="$LOCAL_DEV_COMPOSE_PROJECT_NAME" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh"
}

write_mock_script() {
    local path="$1" body="$2"
    cat > "$path" << MOCK
#!/usr/bin/env bash
$body
MOCK
    chmod +x "$path"
}

write_healthy_mock_curl() {
    local path="$1" call_log="$2"
    write_mock_script "$path" \
        'args="$*"
echo "curl $args" >> "'"$call_log"'"
output="/dev/null"
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o)
            output="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done
if [ -n "${SOURCE_PROVIDER_CAPTURE_ROOT:-}" ] && [ "$output" != "/dev/null" ]; then
    output_basename="$(basename "$output")"
    if [ -f "${SOURCE_PROVIDER_CAPTURE_ROOT}/$output_basename" ]; then
        cat "${SOURCE_PROVIDER_CAPTURE_ROOT}/$output_basename" > "$output"
        exit 0
    fi
fi
if [[ "$args" == *"%{http_code}"* ]]; then
    echo 200
fi
if [[ "$args" == *"/health"* ]]; then
    revision="${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-test-revision}"
    digest="${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-test-digest}"
    sha="${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-test-sha}"
    printf '\''{"status":"ok","version":"1.0.10","build":{"schemaVersion":1,"version":"1.0.10","revision":"%s","revisionKnown":true,"dirty":false,"dirtyKnown":true,"workspaceDigest":"%s","binary_sha256":"%s","profile":"debug","target":"test-target","features":[],"capabilities":{"vectorSearch":true,"vectorSearchLocal":true}}}'\'' "$revision" "$digest" "$sha"
fi
exit 0'
}

mock_applied_migration_queries_body() {
    cat <<'MOCK'
if [[ "$*" == *"-tAc"*"SELECT count(*) FROM _schema_migrations"* ]]; then
    echo "1"
    exit 0
fi
if [[ "$*" == *"-tAc"*"SELECT 1 FROM _schema_migrations WHERE filename="* ]]; then
    echo "1"
    exit 0
fi
MOCK
}

# Mock lsof: report every port as available (exit 1 = no listener found).
# Port ownership is real host state, so any test that builds its own mock bin
# must declare it too — otherwise the developer's own Postgres or Meilisearch
# decides whether the port preflights in local-dev-up.sh pass.
write_available_ports_mock() {
    local mock_dir="$1" call_log="$2"

    write_mock_script "$mock_dir/lsof" \
        'echo "lsof $@" >> "'"$call_log"'"; exit 1'
}

# Create a standard mock bin directory with all required mocks.
# Writes all docker/curl/psql calls to $call_log for assertion.
setup_mock_bin() {
    local mock_dir="$1" call_log="$2"

    # Mock docker: log calls and, when called as `compose ps ... --format
    # json`, emit a synthetic JSON row with Health=healthy so the new
    # `compose_service_health` SSOT (scripts/local-dev-up.sh, anchored
    # 2026-05-31) sees healthy services in the healthy-test path. Without
    # this, the seaweedfs probe waits the full 60s timeout while the test
    # holds the real /bin/sleep (which the healthy test doesn't mock),
    # turning a fast unit test into a 60s+ hang per script invocation.
    write_mock_script "$mock_dir/docker" \
        'echo "LOCAL_DB_PORT=${LOCAL_DB_PORT:-} docker $@" >> "'"$call_log"'"
case "$*" in
    "compose ps "*"--format json"*)
        printf "%s\n" "[{\"Service\":\"$3\",\"Health\":\"healthy\"}]"
        ;;
esac
'"$(mock_applied_migration_queries_body)"'
exit 0'

    # Mock curl: succeed (services healthy)
    write_healthy_mock_curl "$mock_dir/curl" "$call_log"

    # Mock psql: succeed (migrations pass)
    write_mock_script "$mock_dir/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'

    write_available_ports_mock "$mock_dir" "$call_log"

    # Mock nohup: run the command directly (no backgrounding)
    write_mock_script "$mock_dir/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    # Mock sleep: instant exit. wait_until_success now polls docker
    # compose health (which the docker mock answers immediately), so
    # without an instant sleep the inner script's 60s timeout × 2s
    # interval blocks for 60s per script invocation under the real
    # /bin/sleep. Adding a mock sleep here keeps healthy-path tests fast.
    write_mock_script "$mock_dir/sleep" \
        'exit 0'
}

# ============================================================================
# Tests
# ============================================================================

test_compose_leaves_api_startup_to_component_scripts() {
    local compose_files=(
        "$REPO_ROOT/docker-compose.yml"
        "$REPO_ROOT/docker-compose.override.yml.example"
    )

    if rg -q '^[[:space:]]{2}(api|web):[[:space:]]*$' "${compose_files[@]}"; then
        fail "Compose configuration should leave API and web startup to component scripts"
    else
        pass "Compose configuration leaves API and web startup to component scripts"
    fi
}

test_source_provider_ports_bind_to_loopback() {
    local compose
    compose="$(cat "$REPO_ROOT/docker-compose.yml")"

    # Assert the loopback binding and the container-side port only. The HOST-side
    # default is owned by test_source_provider_defaults_cannot_collide_with_flapjack,
    # which reads it from local-dev-up.sh and requires the two files agree; naming
    # the number here too would give the same fact two owners that can drift.
    assert_contains "$compose" \
        '- "127.0.0.1:${LOCAL_MEILISEARCH_PORT:-' \
        "Meilisearch should not expose its predictable local development key beyond loopback"
    assert_contains "$compose" \
        ':7700"' \
        "Meilisearch should keep publishing its container-side 7700"
    assert_contains "$compose" \
        '- "127.0.0.1:${LOCAL_TYPESENSE_PORT:-8108}:8108"' \
        "Typesense should not expose its predictable local development key beyond loopback"
}

# A bare "${LOCAL_DB_PORT:-5432}:5432" publish binds every host interface and
# only the IPv4 one, so on a host that already runs its own PostgreSQL the
# compose database and the foreign server can each own one loopback family.
# `localhost` then resolves to whichever family the resolver prefers and the
# API silently reads and writes an unrelated database. Loopback-qualifying the
# publish turns that ambiguity into a hard bind collision the preflight below
# reports.
test_postgres_port_binds_to_loopback() {
    local compose
    compose="$(cat "$REPO_ROOT/docker-compose.yml")"

    assert_contains "$compose" \
        '- "127.0.0.1:${LOCAL_DB_PORT:-5432}:5432"' \
        "Postgres should publish its predictable local development credentials on loopback only"
}

test_env_example_database_url_names_an_unambiguous_loopback_host() {
    local db_url
    db_url="$(grep '^DATABASE_URL=' "$REPO_ROOT/.env.local.example" | head -1 | cut -d= -f2-)"

    assert_eq "$db_url" "postgres://griddle:griddle_local@127.0.0.1:5432/fjcloud_dev" \
        "DATABASE_URL template should name the loopback address compose publishes, not a resolver-dependent alias"
}

test_calls_down_before_starting() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    # Verify local-dev-down.sh was invoked (it calls docker compose down)
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose down" \
        "should call local-dev-down.sh (which runs docker compose down)"
}

test_starts_only_postgres_service() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose up -d postgres" \
        "should start only the postgres service"
}

test_waits_for_postgres_with_superuser_probe() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec -T postgres pg_isready -U postgres -d postgres" \
        "should wait for postgres using a server-ready probe that survives stale app roles"
}

test_starts_flapjack_with_shared_local_admin_key_default() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local mock_flapjack_dir="$tmp_dir/flapjack/target/debug"
    mkdir -p "$mock_flapjack_dir"
    write_mock_script "$mock_flapjack_dir/flapjack" 'exit 0'

    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "FLAPJACK_ADMIN_KEY=${FLAPJACK_ADMIN_KEY:-}" >> "'"$call_log"'"; exec "$@"'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack" \
        FLAPJACK_PORT=7797 \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully with a mock flapjack binary"

    local calls wait_attempt
    calls=""
    for wait_attempt in $(seq 1 50); do
        calls=$(cat "$call_log" 2>/dev/null || true)
        [[ "$calls" == *"FLAPJACK_ADMIN_KEY="* ]] && break
        /bin/sleep 0.1
    done
    assert_contains "$calls" "FLAPJACK_ADMIN_KEY=fj_local_dev_admin_key_000000000000" \
        "should start local flapjack with the shared default admin key when none is configured"
}

test_summary_includes_flapjack_binary_path() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local flapjack_bin="$tmp_dir/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$flapjack_bin")"
    write_mock_script "$flapjack_bin" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when a flapjack binary is available"
    assert_contains "$output" "$flapjack_bin" \
        "startup summary should include the resolved flapjack binary path"
}

test_discovers_alternate_flapjack_checkout_when_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local first_candidate_bin="$tmp_dir/gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local second_candidate_bin="$tmp_dir/gridl-dev/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$first_candidate_bin")" "$(dirname "$second_candidate_bin")"
    write_mock_script "$first_candidate_bin" 'exit 0'
    write_mock_script "$second_candidate_bin" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/missing $tmp_dir/gridl-dev/flapjack_dev/engine $tmp_dir/gridl-dev/flapjack_dev" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when alternate Flapjack checkout is discoverable"
    assert_contains "$output" "$first_candidate_bin" \
        "startup summary should include the first discovered alternate Flapjack binary path"
    assert_not_contains "$output" "$second_candidate_bin" \
        "should prefer the earliest existing candidate directory in FLAPJACK_DEV_DIR_CANDIDATES order"
    assert_not_contains "$output" "skipping flapjack startup" \
        "should not skip Flapjack when an alternate checkout candidate has a binary"
}

test_discovers_default_repo_relative_fresh_host_candidates_when_unset() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local fixture_repo_root="$tmp_dir/workspaces/fjcloud_dev"
    mkdir -p "$fixture_repo_root/scripts/lib" "$fixture_repo_root/web"
    cp "$REPO_ROOT/scripts/local-dev-up.sh" "$fixture_repo_root/scripts/"
    cp "$REPO_ROOT/scripts/local-dev-down.sh" "$fixture_repo_root/scripts/"
    cp "$REPO_ROOT/scripts/lib/env.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/migrate.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/db_url.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/health.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/flapjack_binary.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/local_stack_contract.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/compose_project.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/process.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/docker.sh" "$fixture_repo_root/scripts/lib/"
    cp "$REPO_ROOT/scripts/lib/local_source_providers.sh" "$fixture_repo_root/scripts/lib/"
    if [ -f "$REPO_ROOT/scripts/lib/playwright_port_plan.sh" ]; then
        cp "$REPO_ROOT/scripts/lib/playwright_port_plan.sh" "$fixture_repo_root/scripts/lib/"
    fi
    cp "$REPO_ROOT/web/playwright.config.contract.ts" "$fixture_repo_root/web/"
    mkdir -p "$fixture_repo_root/infra"
    cp -R "$REPO_ROOT/infra/migrations" "$fixture_repo_root/infra/"
    write_local_dev_env_file "$fixture_repo_root/.env.local" "$LOCAL_DEV_TEST_DB_URL"

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"

    local expected_flapjack_bin="$fixture_repo_root/../../gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local later_flapjack_bin="$fixture_repo_root/../../gridl-dev/flapjack_dev/target/debug/flapjack"
    local expected_flapjack_bin_real="$tmp_dir/gridl-dev/flapjack_dev/engine/target/debug/flapjack"
    local later_flapjack_bin_real="$tmp_dir/gridl-dev/flapjack_dev/target/debug/flapjack"
    mkdir -p "$(dirname "$expected_flapjack_bin_real")" "$(dirname "$later_flapjack_bin_real")"
    write_mock_script "$expected_flapjack_bin_real" 'exit 0'
    write_mock_script "$later_flapjack_bin_real" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="" \
        FLAPJACK_DEV_DIR_CANDIDATES="" \
        FLAPJACK_ADMIN_KEY="" \
        bash "$fixture_repo_root/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should discover flapjack from default repo-relative fresh-host candidates when candidate env vars are unset"
    assert_contains "$output" "$expected_flapjack_bin" \
        "startup summary should include the selected default fresh-host candidate binary path"
    assert_not_contains "$output" "$later_flapjack_bin" \
        "should prefer ../../gridl-dev/flapjack_dev/engine before ../../gridl-dev/flapjack_dev in default candidate order"
    assert_not_contains "$output" "skipping flapjack startup" \
        "should not skip Flapjack when default repo-relative fresh-host candidates resolve a binary"
}

test_prefers_engine_debug_over_root_release_when_both_exist() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/lsof" 'exit 1'
    setup_local_dev_repo_state "$tmp_dir"

    local flapjack_checkout="$tmp_dir/gridl-dev/flapjack_dev"
    local preferred_engine_debug="$flapjack_checkout/engine/target/debug/flapjack"
    local lower_priority_root_release="$flapjack_checkout/target/release/flapjack"
    mkdir -p "$(dirname "$preferred_engine_debug")" "$(dirname "$lower_priority_root_release")"
    write_mock_script "$preferred_engine_debug" 'exit 0'
    write_mock_script "$lower_priority_root_release" 'exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR_CANDIDATES="$tmp_dir/missing $flapjack_checkout" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "startup should succeed when both engine debug and root release binaries exist"
    assert_contains "$output" "$preferred_engine_debug" \
        "shared binary contract should prefer engine target/debug/flapjack before checkout-root target/release/flapjack"
    assert_not_contains "$output" "$lower_priority_root_release" \
        "startup summary should not resolve to checkout-root release when higher-priority engine debug exists"
}

test_summary_includes_effective_admin_key() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when flapjack startup is skipped"
    # Script truncates admin key to first 8 chars in summary for security
    # Summary uses column-aligned spacing (6 spaces after "key:").
    assert_contains "$output" "Admin key:" \
        "startup summary should include the admin key line"
    assert_contains "$output" "fj_local" \
        "startup summary should include the effective FLAPJACK_ADMIN_KEY value"
    assert_not_contains "$output" "fj_local_dev_admin_key" \
        "startup summary should not leak the full admin key"
}

test_preserves_explicit_flapjack_admin_key_override() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    cat >> "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" <<'EOF'
FLAPJACK_ADMIN_KEY=file-admin-key
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="explicit-admin-key" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should start successfully when flapjack startup is skipped"
    # Script truncates admin key to first 8 chars in summary for security
    # Summary uses column-aligned spacing (6 spaces after "key:").
    assert_contains "$output" "Admin key:" \
        "startup summary should include the admin key line"
    assert_contains "$output" "explicit" \
        "startup summary should preserve explicit FLAPJACK_ADMIN_KEY over .env.local values"
    assert_not_contains "$output" "explicit-admin-key" \
        "startup summary should not leak the full overridden admin key"
}

test_recreates_incompatible_postgres_volume_once() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"compose down -v"* ]]; then
    echo 1 > "'"$tmp_dir"'/volume_recreated"
    exit 0
fi
'"$(mock_applied_migration_queries_body)"'
if [[ "$*" == *"psql -h 127.0.0.1 -U local-test -d local_dev_test"* ]]; then
    if [ ! -f "'"$tmp_dir"'/volume_recreated" ]; then
        exit 1
    fi
fi
exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should recover from an incompatible postgres volume"
    assert_contains "$output" "incompatible with" \
        "should explain when an existing postgres volume must be recreated"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose down -v" \
        "should clean the docker postgres volume before retrying"

    local up_count
    up_count=$(grep -c "docker compose up -d postgres" "$call_log" 2>/dev/null || true)
    assert_eq "$up_count" "2" "should restart postgres once after cleaning the stale volume"
}

test_waits_for_fresh_volume_initialization_before_recreating() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"psql -h 127.0.0.1 -U local-test -d local_dev_test"* ]]; then
    attempts_file="'"$tmp_dir"'/psql_attempts"
    attempts=0
    if [ -f "$attempts_file" ]; then
        attempts=$(cat "$attempts_file")
    fi
    attempts=$((attempts + 1))
    echo "$attempts" > "$attempts_file"
    if [ "$attempts" -lt 3 ]; then
        exit 1
    fi
fi
'"$(mock_applied_migration_queries_body)"'
exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should tolerate brief app-role initialization lag on a fresh volume"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    if [[ "$calls" == *"docker compose down -v"* ]]; then
        fail "should not recreate the volume when app credentials become available shortly after startup"
    else
        pass "should not recreate the volume when app credentials become available shortly after startup"
    fi

    local up_count
    up_count=$(grep -c "docker compose up -d postgres" "$call_log" 2>/dev/null || true)
    assert_eq "$up_count" "1" "should keep the original postgres startup when the fresh volume finishes initializing"
}

test_rejects_executable_env_local_content() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    local marker_path="$tmp_dir/should-not-exist"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    cat > "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" <<EOF
DATABASE_URL=$LOCAL_DEV_TEST_DB_URL
touch "$marker_path"
EOF

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
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

test_missing_env_local_auto_bootstraps() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    rm -f "$LOCAL_DEV_TEST_REPO_ROOT/.env.local"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed after auto-bootstrapping .env.local"
    assert_contains "$output" "Bootstrap created .env.local" \
        "should log bootstrap success when .env.local was auto-created"

    if [ -f "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" ]; then
        pass "auto-bootstrap should create .env.local"
    else
        fail "auto-bootstrap should create .env.local (file not found)"
    fi
}

test_missing_env_local_and_example_fails() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    rm -f "$LOCAL_DEV_TEST_REPO_ROOT/.env.local"
    rm -f "$LOCAL_DEV_TEST_REPO_ROOT/.env.local.example"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should fail when both .env.local and .env.local.example are missing"
    assert_contains "$output" "bootstrap failed" \
        "should mention bootstrap failure when template is also missing"
}

test_runs_migrations() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "LOCAL_DB_PORT=${LOCAL_DB_PORT:-} docker $@" >> "'"$call_log"'"
case "$*" in
    "compose ps "*"--format json"*)
        printf "%s\n" "[{\"Service\":\"$3\",\"Health\":\"healthy\"}]"
        ;;
esac
exit 0'
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    # run_migrations calls psql for each .sql file
    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose exec -T postgres env PGPASSWORD=local-pass psql -h 127.0.0.1 -U local-test -d local_dev_test -f" \
        "should run migrations through the postgres container client"
    assert_contains "$output" "Applying:" \
        "log should mention applying migrations"
}

test_does_not_require_host_psql_when_container_client_is_available() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "LOCAL_DB_PORT=${LOCAL_DB_PORT:-} docker $@" >> "'"$call_log"'"
'"$(mock_applied_migration_queries_body)"'
exit 0'
    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" 'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should not require host psql when docker compose can exec the postgres client"
    assert_contains "$output" "Local dev infrastructure is up!" \
        "startup should complete without a host psql binary"
}

test_uses_database_url_port_for_postgres_bind_and_summary() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_local_dev_env_file "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" "$LOCAL_DEV_ALT_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should support non-default host Postgres ports from DATABASE_URL"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "LOCAL_DB_PORT=15432 docker compose up -d postgres" \
        "should pass the DATABASE_URL host port through to docker compose"
    # Summary uses column-aligned spacing for the Postgres line.
    assert_contains "$output" "Postgres:" \
        "should print the Postgres line in the startup summary"
    assert_contains "$output" "localhost:15432" \
        "should print the configured host Postgres port in the startup summary"
}

test_exported_local_db_port_beats_derivation_and_rewrites_database_url() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        LOCAL_DB_PORT=25432 \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?
    calls="$(cat "$call_log" 2>/dev/null || true)"

    assert_eq "$exit_code" "0" "an exported LOCAL_DB_PORT should remain a valid override"
    assert_contains "$calls" "LOCAL_DB_PORT=25432 docker compose up -d postgres" \
        "the exported LOCAL_DB_PORT should flow into Postgres Compose startup"
    assert_contains "$calls" "lsof -i :25432 -sTCP:LISTEN -P" \
        "DB_PORT should match the exported LOCAL_DB_PORT before availability checks"
    assert_contains "$output" "localhost:25432" \
        "the Postgres summary should use the exported LOCAL_DB_PORT"
    assert_contains "$output" "@localhost:25432/local_dev_test" \
        "DATABASE_URL should be rewritten to the exported LOCAL_DB_PORT"
}

test_nonlegacy_database_url_port_beats_derivation_without_local_db_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_local_dev_env_file "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" "$LOCAL_DEV_ALT_PORT_DB_URL"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?
    calls="$(cat "$call_log" 2>/dev/null || true)"

    assert_eq "$exit_code" "0" "a non-legacy DATABASE_URL port should remain a valid override"
    assert_contains "$calls" "LOCAL_DB_PORT=15432 docker compose up -d postgres" \
        "a non-legacy DATABASE_URL port should flow unchanged into Compose"
    assert_contains "$output" "localhost:15432" \
        "the Postgres summary should retain the non-legacy DATABASE_URL port"
    assert_contains "$output" "@localhost:15432/local_dev_test" \
        "DATABASE_URL should retain its explicit non-legacy port"
}

test_legacy_database_url_port_is_rewritten_to_derived_local_db_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local plan derived_db_port
    if ! plan="$(manual_port_plan_for_workspace "$LOCAL_DEV_TEST_REPO_ROOT")"; then
        fail "manual port-plan helper should derive the legacy DATABASE_URL replacement"
        return
    fi
    derived_db_port="$(manual_port_plan_value "$plan" LOCAL_DB_PORT)"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?
    calls="$(cat "$call_log" 2>/dev/null || true)"

    assert_eq "$exit_code" "0" "a legacy DATABASE_URL port should resolve to a derived local port"
    assert_contains "$calls" "LOCAL_DB_PORT=$derived_db_port docker compose up -d postgres" \
        "the derived Postgres port should flow into Compose"
    assert_contains "$calls" "lsof -i :$derived_db_port -sTCP:LISTEN -P" \
        "DB_PORT should consume the rewritten derived Postgres port"
    assert_contains "$output" "localhost:$derived_db_port" \
        "the Postgres summary should use the derived Postgres port"
    assert_contains "$output" "@localhost:$derived_db_port/local_dev_test" \
        "DATABASE_URL should be rewritten before later consumers inspect it"
}

test_rejects_database_url_port_held_by_host_process() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_mock_script "$tmp_dir/bin/lsof" \
        'echo "lsof $@" >> "'"$call_log"'"; exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        LOCAL_DB_PORT=5432 \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "should reject a DATABASE_URL port already held by a host process"
    assert_contains "$output" "port 5432 is already in use" \
        "should explain that the configured Postgres port is occupied"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "docker compose up -d postgres" \
        "should fail before starting a Docker database hidden behind the occupied host port"
}

test_rejects_non_loopback_database_url_host() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_local_dev_env_file "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" "$LOCAL_DEV_REMOTE_HOST_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject non-loopback DATABASE_URL hosts"
    assert_contains "$output" "DATABASE_URL host must be loopback for local-dev-up" \
        "should explain why remote DATABASE_URL hosts are invalid for the local stack"
    assert_contains "$output" "example.com" \
        "should surface the rejected DATABASE_URL host"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "docker compose" \
        "should fail before invoking docker compose when DATABASE_URL points at a non-loopback host"
}

test_rejects_non_numeric_database_url_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_local_dev_env_file "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" "$LOCAL_DEV_INVALID_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject non-numeric DATABASE_URL ports"
    assert_contains "$output" "DATABASE_URL must include a valid port" \
        "should explain why malformed ports are rejected"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "docker compose" \
        "should fail before invoking docker compose when the port is malformed"
}

test_rejects_out_of_range_database_url_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_local_dev_env_file "$LOCAL_DEV_TEST_REPO_ROOT/.env.local" "$LOCAL_DEV_OUT_OF_RANGE_PORT_DB_URL"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should reject out-of-range DATABASE_URL ports"
    assert_contains "$output" "DATABASE_URL must include a valid port" \
        "should explain why out-of-range ports are rejected"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "docker compose" \
        "should fail before invoking docker compose when the port exceeds TCP limits"
}

# The stale-state cleanup above stops this stack's own Postgres, so anything
# still listening on the DATABASE_URL port belongs to a foreign server. Starting
# compose anyway leaves the published port owned by that foreign server, and
# every later probe in this script — readiness, migrations, row counts — reports
# healthy against a database fjcloud does not own.
test_rejects_foreign_listener_on_database_url_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    # Report a listener on the DATABASE_URL port only, so the failure cannot be
    # confused with the flapjack port checks later in the script.
    write_mock_script "$tmp_dir/bin/lsof" \
        'echo "lsof $@" >> "'"$call_log"'"
case "$*" in
    *":5432"*) exit 0 ;;
esac
exit 1'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        LOCAL_DB_PORT=5432 \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" "should refuse to start when a foreign server owns the DATABASE_URL port"
    assert_contains "$output" "port 5432 is already in use (needed for postgres from DATABASE_URL)" \
        "should name the colliding Postgres port instead of proceeding against an unowned database"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "docker compose up -d postgres" \
        "should fail before starting compose Postgres behind a foreign listener"
}

test_starts_flapjack_on_derived_port() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    # The harness mocks health separately, so this process must not keep the
    # command substitution open or make the suite wait on a long-lived daemon.
    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    write_mock_script "$fj_dir/flapjack-http" 'exit 0'

    local plan derived_flapjack_port
    plan="$(manual_port_plan_for_workspace "$LOCAL_DEV_TEST_REPO_ROOT")"
    derived_flapjack_port="$(manual_port_plan_value "$plan" FLAPJACK_PORT)"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_contains "$output" "port $derived_flapjack_port" \
        "should start flapjack on the workspace-derived port"

    local flapjack_pid_file="$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack.pid"
    if [ -f "$flapjack_pid_file" ]; then
        local pid
        pid=$(cat "$flapjack_pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
}

test_starts_flapjack_with_current_binary_name() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    write_mock_script "$fj_dir/flapjack" 'exit 0'

    local plan derived_flapjack_port
    plan="$(manual_port_plan_for_workspace "$LOCAL_DEV_TEST_REPO_ROOT")"
    derived_flapjack_port="$(manual_port_plan_value "$plan" FLAPJACK_PORT)"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_contains "$output" "port $derived_flapjack_port" \
        "should start flapjack when the current binary name is present"

    local flapjack_pid_file="$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack.pid"
    if [ -f "$flapjack_pid_file" ]; then
        local pid
        pid=$(cat "$flapjack_pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    fi
}

test_migrations_skip_already_applied_on_rerun() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_local_dev_repo_state "$tmp_dir"

    # Smart docker mock: simulates a Postgres volume that already has all
    # migrations tracked in _schema_migrations (rerun scenario).
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
if [[ "$*" == *"-tAc"*"SELECT 1 FROM _schema_migrations"* ]]; then
    echo "1"
fi
exit 0'

    write_healthy_mock_curl "$tmp_dir/bin/curl" "$call_log"
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" 'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "rerun should succeed when all migrations are already applied"
    assert_contains "$output" "skipped" \
        "should report that already-applied migrations were skipped on rerun"

    # No migration files should have been re-applied (no -f flags for migration SQL)
    local apply_calls
    apply_calls=$(grep -c "\-f /migrations/" "$call_log" 2>/dev/null || true)
    assert_eq "$apply_calls" "0" "should not re-apply migrations that are already tracked"
}

test_flapjack_missing_warns_and_skips() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed even when flapjack binary is missing"
    assert_contains "$output" "WARNING" \
        "should warn about missing flapjack binary"
    assert_contains "$output" "skipping flapjack startup" \
        "should keep warning-only behavior and skip flapjack startup when no binary resolves"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_not_contains "$calls" "nohup /" \
        "should not attempt to launch flapjack when binary lookup fails"
}

test_selected_flapjack_source_build_failure_is_fatal() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    local checkout="$tmp_dir/flapjack_dev"
    mkdir -p "$tmp_dir/bin" "$checkout/engine/flapjack-server/src"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    printf '[workspace]\nmembers = ["flapjack-server"]\n' > "$checkout/engine/Cargo.toml"
    printf 'fn main() {}\n' > "$checkout/engine/flapjack-server/src/main.rs"
    write_mock_script "$tmp_dir/bin/cargo" 'exit 17'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$checkout" \
        FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "1" \
        "local-dev startup should fail when the selected Flapjack source cannot build"
    assert_contains "$output" "selected FLAPJACK_DEV_DIR source build or provenance validation failed" \
        "local-dev startup should surface the selected-source failure"
    assert_not_contains "$output" "skipping flapjack startup" \
        "selected source failures must not be downgraded to optional missing-binary warnings"
    assert_not_contains "$(cat "$call_log" 2>/dev/null || true)" "nohup" \
        "selected source failures should fail before launching any Flapjack binary"
}

test_selected_flapjack_source_success_prints_helper_provenance() {
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    local checkout="$tmp_dir/flapjack_dev"
    mkdir -p "$tmp_dir/bin" "$checkout/engine/flapjack-server/src"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    printf '[workspace]\nmembers = ["flapjack-server"]\n' > "$checkout/engine/Cargo.toml"
    printf 'fn main() {}\n' > "$checkout/engine/flapjack-server/src/main.rs"
    write_mock_script "$tmp_dir/bin/cargo" '
echo "cargo $@" >> "'"$call_log"'"
mkdir -p target/debug
{
    printf "#!/usr/bin/env bash\n"
    printf "if [ \"\${1:-}\" = \"build-info\" ] && [ \"\${2:-}\" = \"--json\" ]; then\n"
    printf "    printf '\''{\"build\":{\"workspaceDigest\":\"mock-workspace-digest\"}}\\\\n'\''\n"
    printf "    exit 0\n"
    printf "fi\n"
    printf "exit 0\n"
} > target/debug/flapjack
chmod +x target/debug/flapjack
exit 0
'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$checkout" \
        FLAPJACK_SOURCE_RECEIPT_DIR="$tmp_dir/receipts" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "local-dev startup should succeed when the selected source checkout builds"
    assert_contains "$output" "Flapjack provenance: source-build:" \
        "local-dev startup should print shared helper provenance for source-backed binaries"
    assert_contains "$output" "$tmp_dir/receipts" \
        "local-dev startup should surface the helper-owned receipt path"
    assert_contains "$(cat "$call_log")" "cargo build -p flapjack-server" \
        "source-backed local-dev startup should delegate the Cargo build to the helper"
}

test_local_dev_up_uses_shared_flapjack_helper_only() {
    local script_text
    script_text="$(cat "$REPO_ROOT/scripts/local-dev-up.sh")"

    assert_contains "$script_text" 'find_flapjack_binary "$FLAPJACK_DEV_DIR"' \
        "local-dev startup should resolve Flapjack through the shared helper"
    assert_contains "$script_text" "flapjack_source_provenance_summary" \
        "local-dev startup should print shared Flapjack provenance"
    assert_not_contains "$script_text" "cargo build -p flapjack-http" \
        "local-dev startup should not carry a caller-owned legacy Flapjack build path"
    assert_not_contains "$script_text" "cargo build -p flapjack-server" \
        "local-dev startup should not carry a caller-owned current Flapjack build path"
}

test_prints_startup_instructions() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_contains "$output" "scripts/api-dev.sh" \
        "should print API startup instructions that work from the repo root"
    assert_contains "$output" "scripts/web-dev.sh" \
        "should print the repo-owned web startup wrapper"
}

test_starts_seaweedfs_and_mailpit() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "should succeed with optional services"

    local calls
    calls=$(cat "$call_log" 2>/dev/null || true)
    assert_contains "$calls" "docker compose up -d seaweedfs" \
        "should always start seaweedfs"
    assert_contains "$calls" "docker compose up -d mailpit" \
        "should always start mailpit"
}

test_source_providers_are_default_off() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?
    calls=$(cat "$call_log" 2>/dev/null || true)

    assert_eq "$exit_code" "0" "default startup should succeed without source providers"
    assert_not_contains "$calls" "docker compose up -d meilisearch typesense" \
        "default startup should not start profile-gated source providers"
    assert_not_contains "$output" "Meilisearch:" \
        "default summary should omit Meilisearch"
    assert_not_contains "$output" "Typesense:" \
        "default summary should omit Typesense"
}

test_source_provider_profile_starts_and_reports_healthy_services() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    local capture_root="$tmp_dir/source-provider-captures"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_mock_provider_capture_payloads "$capture_root"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        COMPOSE_PROFILES="source-providers" \
        LOCAL_MEILISEARCH_PORT=17700 \
        LOCAL_TYPESENSE_PORT=18108 \
        SOURCE_PROVIDER_CAPTURE_ROOT="$capture_root" \
        SOURCE_PROVIDER_EVIDENCE_ROOT="$tmp_dir/evidence" \
        SOURCE_PROVIDER_CREDENTIAL_ROOT="$tmp_dir/credentials" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?
    calls=$(cat "$call_log" 2>/dev/null || true)

    assert_eq "$exit_code" "0" "source-provider profile startup should succeed"
    assert_contains "$calls" "docker compose up -d meilisearch typesense" \
        "source-provider profile should start both providers together"
    assert_contains "$calls" "http://127.0.0.1:17700/health" \
        "source-provider startup should probe the configured Meilisearch port"
    assert_contains "$calls" "http://127.0.0.1:18108/health" \
        "source-provider startup should probe the configured Typesense port"
    assert_contains "$output" "Meilisearch:    http://localhost:17700" \
        "healthy source-provider summary should include Meilisearch"
    assert_contains "$output" "Typesense:      http://localhost:18108" \
        "healthy source-provider summary should include Typesense"
}

test_source_provider_defaults_cannot_collide_with_flapjack() {
    # Regression guard for the 2026-08-03 defect: FLAPJACK_PORT and
    # LOCAL_MEILISEARCH_PORT both defaulted to 7700, so the three-provider
    # local stack — which needs flapjack as the migration DESTINATION and
    # Meilisearch as a migration SOURCE at the same time — could not come up
    # on defaults at all. Every pre-existing source-provider test in this file
    # passes explicit 17700/18108 overrides, which is exactly why the broken
    # default was never exercised. Assert the declared defaults, not a
    # runtime path, so the contract holds even when no stack is running.
    local plan flapjack_default meili_default
    plan="$(manual_port_plan_for_workspace "$LOCAL_DEV_TEST_REPO_ROOT")"
    flapjack_default="$(manual_port_plan_value "$plan" FLAPJACK_PORT)"
    meili_default="$(manual_port_plan_value "$plan" LOCAL_MEILISEARCH_PORT)"

    if [ "$flapjack_default" = "$meili_default" ]; then
        fail "FLAPJACK_PORT and LOCAL_MEILISEARCH_PORT must not share the default $flapjack_default; the three-provider local stack needs both bound at once"
    else
        pass "Flapjack ($flapjack_default) and Meilisearch ($meili_default) declare distinct default host ports"
    fi

    assert_contains "$(cat "$REPO_ROOT/scripts/local-dev-up.sh")" \
        'playwright_apply_manual_stack_port_defaults' \
        "local-dev-up.sh should obtain defaults from the shared port-plan seam"
}

test_manual_port_defaults_are_deterministic_and_disjoint_per_workspace() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local workspace_a workspace_b plan_a_first plan_a_second plan_b
    workspace_a="$(create_local_dev_fixture_repo_root "$tmp_dir/workspace_a")"
    workspace_b="$(create_local_dev_fixture_repo_root "$tmp_dir/workspace_b")"

    if ! plan_a_first="$(manual_port_plan_for_workspace "$workspace_a")"; then
        fail "manual port-plan helper should derive defaults for a fixture workspace"
        return
    fi
    if ! plan_a_second="$(manual_port_plan_for_workspace "$workspace_a")"; then
        fail "manual port-plan helper should repeat derivation for the same fixture workspace"
        return
    fi
    if ! plan_b="$(manual_port_plan_for_workspace "$workspace_b")"; then
        fail "manual port-plan helper should derive defaults for a second fixture workspace"
        return
    fi

    assert_eq "$plan_a_first" "$plan_a_second" \
        "the same workspace path should derive the same manual stack defaults twice"

    local port_names=(
        FLAPJACK_PORT
        LOCAL_MEILISEARCH_PORT
        LOCAL_TYPESENSE_PORT
        LOCAL_MAILPIT_UI_PORT
        LOCAL_SMTP_PORT
        LOCAL_S3_PORT
        LOCAL_DB_PORT
    )
    local name value all_ports=""
    for name in "${port_names[@]}"; do
        value="$(manual_port_plan_value "$plan_a_first" "$name")"
        [ -n "$value" ] || fail "$name should be present in the first workspace port plan"
        all_ports="${all_ports}${value}"$'\n'
        value="$(manual_port_plan_value "$plan_b" "$name")"
        [ -n "$value" ] || fail "$name should be present in the second workspace port plan"
        all_ports="${all_ports}${value}"$'\n'
    done

    local unique_port_count
    unique_port_count="$(printf '%s' "$all_ports" | sed '/^$/d' | sort -n -u | wc -l | tr -d ' ')"
    assert_eq "$unique_port_count" "14" \
        "two distinct fixture workspaces should derive disjoint values for all seven host ports"
}

test_all_manual_defaults_match_typescript_resolvers() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "'"$tmp_dir"'"' RETURN

    local workspace_path plan typescript_plan web_port api_port flapjack_port
    local workspace_paths=(
        ""
        "/tmp/fq6_blocked_46"
        "$(create_local_dev_fixture_repo_root "$tmp_dir/plain_workspace")"
        "$(create_local_dev_fixture_repo_root "$tmp_dir/non_bmp_😀_workspace")"
    )

    for workspace_path in "${workspace_paths[@]}"; do
        if ! plan="$(manual_port_plan_for_workspace "$workspace_path")"; then
            fail "manual port-plan helper should derive all defaults for anti-drift coverage"
            return
        fi
        typescript_plan="$(typescript_port_plan_for_workspace "$workspace_path" "$tmp_dir")"
        web_port="$(manual_port_plan_value "$typescript_plan" WEB_PORT)"
        api_port="$(manual_port_plan_value "$typescript_plan" API_PORT)"
        flapjack_port="$(manual_port_plan_value "$typescript_plan" FLAPJACK_PORT)"

        local expected_manual_plan
        expected_manual_plan=$(printf '%s\n' \
            "LOCAL_MEILISEARCH_PORT=$web_port" \
            "LOCAL_TYPESENSE_PORT=$api_port" \
            "FLAPJACK_PORT=$flapjack_port" \
            "LOCAL_SMTP_PORT=$((flapjack_port + 2000))" \
            "LOCAL_MAILPIT_UI_PORT=$((flapjack_port + 4000))" \
            "LOCAL_S3_PORT=$((flapjack_port + 6000))" \
            "LOCAL_DB_PORT=$((flapjack_port + 8000))")

        local variable_name expected_value actual_value
        while IFS='=' read -r variable_name expected_value; do
            actual_value="$(manual_port_plan_value "$plan" "$variable_name")"
            assert_eq "$actual_value" "$expected_value" \
                "$variable_name should match the TypeScript-owned port plan for $workspace_path"
        done <<< "$expected_manual_plan"
    done
}

test_explicit_flapjack_port_flows_through_startup_summary_and_checks() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local flapjack_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$flapjack_dir"
    write_mock_script "$flapjack_dir/flapjack" 'exit 0'
    mkdir -p "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data"
    printf '%s\n' "stale-admin-key-from-prior-run" \
        > "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/.admin_key"
    printf '%s\n' "stale-keys-from-prior-run" \
        > "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/keys.json"
    printf '%s\n' "stale-key-material-from-prior-run" \
        > "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/key_material.json"

    local output exit_code=0 calls wait_attempt
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_ADMIN_KEY="" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_PORT=17800 \
        run_local_dev_up 2>&1
    ) || exit_code=$?
    calls=""
    for wait_attempt in $(seq 1 50); do
        calls="$(cat "$call_log" 2>/dev/null || true)"
        [[ "$calls" == *"nohup $flapjack_dir/flapjack --port 17800"* ]] && break
        /bin/sleep 0.1
    done

    assert_eq "$exit_code" "0" "an explicit FLAPJACK_PORT should remain a valid startup override"
    assert_contains "$calls" "lsof -i :17800 -sTCP:LISTEN -P" \
        "the explicit FLAPJACK_PORT should flow into host-port availability checks"
    assert_contains "$calls" "nohup $flapjack_dir/flapjack --port 17800" \
        "the explicit FLAPJACK_PORT should flow into Flapjack startup"
    assert_contains "$output" "Flapjack default: http://localhost:17800" \
        "the explicit FLAPJACK_PORT should flow into the startup summary"
    assert_contains "$output" "Algolia source:  http://127.0.0.1:17800" \
        "the explicit FLAPJACK_PORT should surface as the lane-local Algolia source URL"
    assert_contains "$(cat "$LOCAL_DEV_TEST_REPO_ROOT/infra/.cargo/config.toml" 2>/dev/null || true)" \
        'FJCLOUD_ALGOLIA_SOURCE_BASE_URL = "http://127.0.0.1:17800"' \
        "local-dev-up should persist the lane-local Algolia source URL for later standalone cargo test invocations"
    assert_contains "$(cat "$LOCAL_DEV_TEST_REPO_ROOT/infra/.cargo/config.toml" 2>/dev/null || true)" \
        'FLAPJACK_ADMIN_KEY = "fj_local_dev_admin_key_000000000000"' \
        "local-dev-up should persist the shared default Flapjack admin key for later standalone cargo test invocations"
    assert_eq "$(cat "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/.admin_key" 2>/dev/null || true)" \
        "fj_local_dev_admin_key_000000000000" \
        "local-dev-up should reset stale lane-local Flapjack admin-key state before standalone cargo test invocations"
    assert_eq "$(cat "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/keys.json" 2>/dev/null || true)" \
        "stale-keys-from-prior-run" \
        "local-dev-up should preserve persisted Flapjack API-key hashes while rotating the admin key"
    assert_eq "$(cat "$LOCAL_DEV_TEST_REPO_ROOT/.local/flapjack-data/key_material.json" 2>/dev/null || true)" \
        "stale-key-material-from-prior-run" \
        "local-dev-up should preserve persisted encrypted Flapjack API-key material while rotating the admin key"
}

test_all_manual_host_ports_fail_collisions_before_teardown_or_startup() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local collision_variable output exit_code calls
    local collision_variables=(
        LOCAL_MEILISEARCH_PORT
        LOCAL_TYPESENSE_PORT
        LOCAL_MAILPIT_UI_PORT
        LOCAL_SMTP_PORT
        LOCAL_S3_PORT
        LOCAL_DB_PORT
    )
    for collision_variable in "${collision_variables[@]}"; do
        : > "$call_log"
        exit_code=0
        output=$(
            env \
                PATH="$tmp_dir/bin:$PATH" \
                FJCLOUD_REPO_ROOT="$LOCAL_DEV_TEST_REPO_ROOT" \
                COMPOSE_PROJECT_NAME="$LOCAL_DEV_COMPOSE_PROJECT_NAME" \
                COMPOSE_PROFILES="source-providers" \
                FLAPJACK_DEV_DIR="/nonexistent" \
                FLAPJACK_PORT=17800 \
                LOCAL_MEILISEARCH_PORT=17801 \
                LOCAL_TYPESENSE_PORT=17802 \
                LOCAL_MAILPIT_UI_PORT=17803 \
                LOCAL_SMTP_PORT=17804 \
                LOCAL_S3_PORT=17805 \
                LOCAL_DB_PORT=17806 \
                "$collision_variable=17800" \
                bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
        ) || exit_code=$?
        calls="$(cat "$call_log" 2>/dev/null || true)"

        assert_eq "$exit_code" "1" \
            "$collision_variable should collide with FLAPJACK_PORT before startup"
        assert_contains "$output" "FLAPJACK_PORT" \
            "$collision_variable collision should identify FLAPJACK_PORT"
        assert_contains "$output" "$collision_variable" \
            "$collision_variable collision should identify both owners"
        assert_not_contains "$calls" "docker compose down" \
            "$collision_variable collision should fail before local-dev-down.sh"
        assert_not_contains "$calls" "docker compose up" \
            "$collision_variable collision should fail before any compose service starts"
    done
}

test_rejects_colliding_flapjack_and_source_provider_ports() {
    # The default is now safe, but an operator can still point two services at
    # one port by hand. Without a pre-flight guard the failure surfaces late
    # and misleadingly: Meilisearch binds first, then flapjack's own
    # check_port_available reports "port 7700 already in use (needed for
    # flapjack-default)" without ever naming the Meilisearch override that
    # took it. Require a fail-fast that names BOTH variables.
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0 calls
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        COMPOSE_PROFILES="source-providers" \
        FLAPJACK_PORT=17700 \
        LOCAL_MEILISEARCH_PORT=17700 \
        LOCAL_TYPESENSE_PORT=18108 \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?
    calls=$(cat "$call_log" 2>/dev/null || true)

    assert_eq "$exit_code" "1" "colliding host ports should fail fast, not start a partial stack"
    assert_contains "$output" "FLAPJACK_PORT" \
        "the collision diagnostic must name FLAPJACK_PORT so the operator knows which override to move"
    assert_contains "$output" "LOCAL_MEILISEARCH_PORT" \
        "the collision diagnostic must name LOCAL_MEILISEARCH_PORT, not just the bare port number"
    assert_contains "$output" "17700" \
        "the collision diagnostic must name the colliding port"
    assert_not_contains "$calls" "docker compose up -d meilisearch typesense" \
        "no source-provider container may start once a port collision is known"
}

test_source_provider_health_failure_is_nonfatal() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
case "$*" in
    "compose ps meilisearch "*|"compose ps typesense "*)
        printf "%s\n" "[{\"Service\":\"$3\",\"Health\":\"unhealthy\"}]"
        ;;
    "compose ps "*"--format json"*)
        printf "%s\n" "[{\"Service\":\"$3\",\"Health\":\"healthy\"}]"
        ;;
esac
'"$(mock_applied_migration_queries_body)"'
exit 0'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        COMPOSE_PROFILES="source-providers" \
        SOURCE_PROVIDER_HEALTH_TIMEOUT_SECONDS=2 \
        SOURCE_PROVIDER_EVIDENCE_ROOT="$tmp_dir/evidence" \
        SOURCE_PROVIDER_CREDENTIAL_ROOT="$tmp_dir/credentials" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        bash "$REPO_ROOT/scripts/local-dev-up.sh" 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "source-provider health failure should not fail the core local stack"
    assert_contains "$output" "source providers failed health checks" \
        "source-provider health failure should be reported"
    assert_not_contains "$output" "Meilisearch:" \
        "unhealthy source-provider summary should omit Meilisearch"
    assert_not_contains "$output" "Typesense:" \
        "unhealthy source-provider summary should omit Typesense"
}

test_optional_service_health_failure_nonfatal() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    # Docker mock: log calls, succeed on compose up/exec/down
    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log"'"
'"$(mock_applied_migration_queries_body)"'
exit 0'
    # Curl mock: always fail (health checks fail for optional services)
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log"'"; exit 1'
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'
    # Mock sleep to no-op so wait_for_health retries don't block
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log"

    setup_local_dev_repo_state "$tmp_dir"

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" \
        "should exit 0 even when optional service health checks fail"
    assert_contains "$output" "failed health check" \
        "should log health-failure warning for optional services"
}

test_startup_summary_reflects_health_status() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    # --- Run 1: healthy optional services (curl succeeds) ---
    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    local output_healthy exit_code=0
    output_healthy=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_contains "$output_healthy" "SeaweedFS S3:" \
        "summary should include SeaweedFS when healthy"
    assert_contains "$output_healthy" "Mailpit UI:" \
        "summary should include Mailpit when healthy"

    restore_local_dev_repo_state

    # --- Run 2: unhealthy optional services (curl fails) ---
    rm -rf "$tmp_dir"
    tmp_dir=$(mktemp -d)
    local call_log2="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"

    write_mock_script "$tmp_dir/bin/docker" \
        'echo "docker $@" >> "'"$call_log2"'"
'"$(mock_applied_migration_queries_body)"'
exit 0'
    write_mock_script "$tmp_dir/bin/curl" \
        'echo "curl $@" >> "'"$call_log2"'"; exit 1'
    write_mock_script "$tmp_dir/bin/psql" \
        'echo "psql $@" >> "'"$call_log2"'"; exit 0'
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log2"'"; "$@" &'
    write_mock_script "$tmp_dir/bin/sleep" \
        'exit 0'
    write_available_ports_mock "$tmp_dir/bin" "$call_log2"

    setup_local_dev_repo_state "$tmp_dir"

    local output_unhealthy exit_code2=0
    output_unhealthy=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="/nonexistent" \
        run_local_dev_up 2>&1
    ) || exit_code2=$?

    assert_not_contains "$output_unhealthy" "SeaweedFS S3:" \
        "summary should omit SeaweedFS when unhealthy"
    assert_not_contains "$output_unhealthy" "Mailpit UI:" \
        "summary should omit Mailpit when unhealthy"
    assert_contains "$(cat "$call_log2")" "lsof" \
        "run-2 port preflight should record lsof in the active call log"
}

test_multi_region_flapjack_starts_one_per_region() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'restore_local_dev_repo_state; rm -rf "'"$tmp_dir"'"' RETURN

    local call_log="$tmp_dir/calls.log"
    mkdir -p "$tmp_dir/bin"
    setup_mock_bin "$tmp_dir/bin" "$call_log"
    setup_local_dev_repo_state "$tmp_dir"

    # Create a fake flapjack binary.
    local fj_dir="$tmp_dir/flapjack_dev/target/debug"
    mkdir -p "$fj_dir"
    # Health is mocked independently; this fixture only needs to record args.
    write_mock_script "$fj_dir/flapjack" \
        'echo "flapjack $@" >> "'"$call_log"'"; exit 0'

    # Override nohup to log the FLAPJACK_ADMIN_KEY and args, then background.
    write_mock_script "$tmp_dir/bin/nohup" \
        'echo "nohup $@" >> "'"$call_log"'"; "$@" &'

    local output exit_code=0
    output=$(
        PATH="$tmp_dir/bin:$PATH" \
        FLAPJACK_DEV_DIR="$tmp_dir/flapjack_dev" \
        FLAPJACK_REGIONS="us-east-1:7700 eu-west-1:7701" \
        run_local_dev_up 2>&1
    ) || exit_code=$?

    assert_eq "$exit_code" "0" "multi-region flapjack startup should succeed"

    # Verify start_one_flapjack used the configured region/port pairs.
    assert_contains "$output" "Starting flapjack (us-east-1) on port 7700" \
        "should start flapjack on port 7700 for us-east-1"
    assert_contains "$output" "Starting flapjack (eu-west-1) on port 7701" \
        "should start flapjack on port 7701 for eu-west-1"

    # Verify PID files were created for each region.
    local pid_dir="$LOCAL_DEV_TEST_REPO_ROOT/.local"
    if [ -f "$pid_dir/flapjack-us-east-1.pid" ]; then
        pass "flapjack-us-east-1.pid was created"
    else
        fail "flapjack-us-east-1.pid should be created"
    fi
    if [ -f "$pid_dir/flapjack-eu-west-1.pid" ]; then
        pass "flapjack-eu-west-1.pid was created"
    else
        fail "flapjack-eu-west-1.pid should be created"
    fi

    # Clean up background flapjack processes.
    for pid_file in "$pid_dir"/flapjack-*.pid; do
        [ -f "$pid_file" ] || continue
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
        fi
    done
}

# ============================================================================
# Run all tests
# ============================================================================

main() {
    echo "=== local-dev-up.sh tests ==="
    echo ""

    test_compose_leaves_api_startup_to_component_scripts
    test_source_provider_ports_bind_to_loopback
    test_postgres_port_binds_to_loopback
    test_env_example_database_url_names_an_unambiguous_loopback_host
    test_calls_down_before_starting
    test_starts_only_postgres_service
    test_waits_for_postgres_with_superuser_probe
    test_starts_flapjack_with_shared_local_admin_key_default
    test_summary_includes_flapjack_binary_path
    test_discovers_alternate_flapjack_checkout_when_unset
    test_discovers_default_repo_relative_fresh_host_candidates_when_unset
    test_prefers_engine_debug_over_root_release_when_both_exist
    test_summary_includes_effective_admin_key
    test_preserves_explicit_flapjack_admin_key_override
    test_recreates_incompatible_postgres_volume_once
    test_waits_for_fresh_volume_initialization_before_recreating
    test_rejects_executable_env_local_content
    test_missing_env_local_auto_bootstraps
    test_missing_env_local_and_example_fails
    test_runs_migrations
    test_does_not_require_host_psql_when_container_client_is_available
    test_uses_database_url_port_for_postgres_bind_and_summary
    test_exported_local_db_port_beats_derivation_and_rewrites_database_url
    test_nonlegacy_database_url_port_beats_derivation_without_local_db_port
    test_legacy_database_url_port_is_rewritten_to_derived_local_db_port
    test_rejects_database_url_port_held_by_host_process
    test_rejects_non_loopback_database_url_host
    test_rejects_non_numeric_database_url_port
    test_rejects_out_of_range_database_url_port
    test_rejects_foreign_listener_on_database_url_port
    test_starts_flapjack_on_derived_port
    test_starts_flapjack_with_current_binary_name
    test_migrations_skip_already_applied_on_rerun
    test_flapjack_missing_warns_and_skips
    test_selected_flapjack_source_build_failure_is_fatal
    test_selected_flapjack_source_success_prints_helper_provenance
    test_local_dev_up_uses_shared_flapjack_helper_only
    test_prints_startup_instructions
    test_starts_seaweedfs_and_mailpit
    test_source_providers_are_default_off
    test_source_provider_profile_starts_and_reports_healthy_services
    test_source_provider_defaults_cannot_collide_with_flapjack
    test_manual_port_defaults_are_deterministic_and_disjoint_per_workspace
    test_all_manual_defaults_match_typescript_resolvers
    test_explicit_flapjack_port_flows_through_startup_summary_and_checks
    test_all_manual_host_ports_fail_collisions_before_teardown_or_startup
    test_rejects_colliding_flapjack_and_source_provider_ports
    test_source_provider_health_failure_is_nonfatal
    test_optional_service_health_failure_nonfatal
    test_startup_summary_reflects_health_status
    test_multi_region_flapjack_starts_one_per_region

    echo ""
    echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
    if [ "$FAIL_COUNT" -gt 0 ]; then
        exit 1
    fi
}

main "$@"
