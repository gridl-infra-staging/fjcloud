#!/usr/bin/env bash
# Tests for scripts/playwright_local_stack.sh local Flapjack bootstrap behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

test_flapjack_bootstrap_initializes_experiment_storage() {
	local script_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" "ensure_flapjack_experiments_api_ready" \
		"playwright stack should define an experiments storage bootstrap seam"
	assert_contains "$script_text" 'wait_for_health "$FLAPJACK_HEALTH_URL" "playwright flapjack"' \
		"playwright stack should wait for Flapjack health before bootstrapping system indexes"
	assert_contains "$script_text" 'ensure_flapjack_experiments_api_ready' \
		"playwright stack should invoke the experiments bootstrap before starting the API"
	assert_contains "$script_text" '/2/abtests' \
		"experiments bootstrap should use the Flapjack experiments API endpoint"
	assert_not_contains "$script_text" '"uid":".experiments"' \
		"experiments bootstrap should not create the hidden experiments store as a tenant index"
	assert_contains "$script_text" 'X-Algolia-API-Key: ${FLAPJACK_ADMIN_KEY}' \
		"experiments bootstrap should authenticate with the local Flapjack admin key"
	assert_contains "$script_text" "200)" \
		"experiments bootstrap should accept a successful experiments API readiness response"
	assert_contains "$script_text" 'rm -rf "$FLAPJACK_EXPERIMENTS_DATA_DIR"' \
		"experiments bootstrap should clear Playwright-owned stale experiments storage before readiness"
}

test_default_flapjack_data_dir_is_port_scoped() {
	local script_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" 'FLAPJACK_PORT="$(parse_port_from_http_url "$FLAPJACK_URL")"' \
		"playwright stack should derive the Flapjack port before choosing a data directory"
	assert_contains "$script_text" 'FLAPJACK_DATA_DIR="${PLAYWRIGHT_FLAPJACK_DATA_DIR:-$LOCAL_DIR/flapjack-data-playwright-$FLAPJACK_PORT}"' \
		"playwright stack should isolate default Flapjack data directories per port"
}

test_stack_harness_creates_repo_local_scratch_parent() {
	local script_text
	script_text="$(cat "$REPO_ROOT/scripts/tests/playwright_local_stack_test.sh")"

	assert_contains "$script_text" 'mkdir -p "$REPO_ROOT/.local"' \
		"playwright stack harness should create its repo-local scratch parent before mktemp"
	assert_contains "$script_text" 'mktemp -d "$REPO_ROOT/.local/playwright-stack-test.XXXXXX"' \
		"playwright stack harness should keep scratch data under repo-local .local"
}

test_term_trap_exits_after_cleanup() {
	local script_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" "handle_shutdown() {" \
		"playwright stack should define an explicit shutdown trap handler"
	assert_contains "$script_text" "trap cleanup EXIT" \
		"playwright stack should still clean up on normal shell exit"
	assert_contains "$script_text" "trap handle_shutdown INT TERM" \
		"playwright stack should exit instead of resuming after INT/TERM cleanup"
}

test_playwright_stack_logs_shared_flapjack_provenance() {
	local script_text logic_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"
	logic_text="$(grep -v 'run: cargo build -p flapjack-server' "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" "find_restart_ready_flapjack_binary" \
		"playwright stack should resolve Flapjack through the shared helper"
	assert_contains "$script_text" "flapjack_source_provenance_summary" \
		"playwright stack should log shared Flapjack resolver provenance"
	assert_not_contains "$logic_text" "cargo build -p flapjack-http" \
		"playwright stack should not grow a caller-owned legacy Flapjack build path"
	assert_not_contains "$logic_text" "cargo build -p flapjack-server" \
		"playwright stack should not grow a caller-owned current Flapjack build path"
}

test_playwright_stack_surfaces_helper_source_provenance() {
	local temp_dir output exit_code=0
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	mkdir -p "$temp_dir/scripts/lib" "$temp_dir/bin"
	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	chmod +x "$temp_dir/scripts/playwright_local_stack.sh"

	cat > "$temp_dir/scripts/lib/env.sh" <<'SH'
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="local-test-key"
load_env_file() { :; }
SH
	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() { return 0; }
SH
	cat > "$temp_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { printf '%s\n' "$TEST_STACK_RUN_DIR/flapjack-server"; }
flapjack_source_provenance_summary() { printf 'source-build:%s\n' "$TEST_STACK_RUN_DIR/receipts/source.receipt"; }
flapjack_export_required_runtime_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_REVISION="test-revision"
	export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="test-digest"
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
SH
cat > "$temp_dir/scripts/lib/local_stack_contract.sh" <<'SH'
flapjack_runtime_identity_reason() { printf 'match\n'; }
flapjack_runtime_matches_required_version() { return 0; }
api_supports_capability() { return 0; }
FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY="preview_events_v1"
SH
	cat > "$temp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
	if [ "$arg" = "%{http_code}" ]; then
		printf '200'
		exit 0
	fi
done
exit 0
SH
	chmod +x "$temp_dir/bin/curl"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"
	: > "$temp_dir/flapjack-server"
	chmod +x "$temp_dir/flapjack-server"

	output=$(
		TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$temp_dir/bin:/usr/bin:/bin" \
		FLAPJACK_DEV_DIR="$temp_dir/selected-source" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "0" \
		"playwright stack should complete with mocked source-backed helper resolution"
	assert_contains "$output" "Flapjack provenance: source-build:" \
		"playwright stack should surface helper source-build provenance"
	assert_contains "$output" "$temp_dir/receipts/source.receipt" \
		"playwright stack should surface the helper-owned receipt path"
}

test_playwright_stack_rejects_healthy_runtime_when_source_resolution_fails() {
	local temp_dir output exit_code=0
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	mkdir -p "$temp_dir/scripts/lib"
	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	chmod +x "$temp_dir/scripts/playwright_local_stack.sh"

	cat > "$temp_dir/scripts/lib/env.sh" <<'SH'
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="local-test-key"
load_env_file() { :; }
SH
	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() { return 0; }
SH
	cat > "$temp_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() {
	echo "selected source build failed" >&2
	return 2
}
SH
	: > "$temp_dir/scripts/lib/local_stack_contract.sh"
	mkdir -p "$temp_dir/bin"
	cat > "$temp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$temp_dir/bin/curl"

	output=$(
		PATH="$temp_dir/bin:/usr/bin:/bin" \
		FLAPJACK_DEV_DIR="$temp_dir/selected-source" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a healthy runtime when selected-source resolution fails"
	assert_contains "$output" "selected FLAPJACK_DEV_DIR source build or provenance validation failed" \
		"playwright stack should surface the authoritative source-resolution failure"
}

test_playwright_stack_rejects_healthy_runtime_without_exact_identity_evidence() {
	local temp_dir output exit_code=0
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	mkdir -p "$temp_dir/scripts/lib" "$temp_dir/bin"
	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	chmod +x "$temp_dir/scripts/playwright_local_stack.sh"

	cat > "$temp_dir/scripts/lib/env.sh" <<'SH'
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="local-test-key"
load_env_file() { :; }
SH
	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() { return 0; }
SH
	cat > "$temp_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { return 1; }
flapjack_source_provenance_summary() { printf 'none\n'; }
SH
	cat > "$temp_dir/scripts/lib/local_stack_contract.sh" <<'SH'
flapjack_required_runtime_identity_evidence_available() {
	[ -n "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" ] &&
		[ -n "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" ] &&
		[ -n "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" ]
}
flapjack_runtime_identity_reason() { printf 'match\n'; }
api_supports_capability() { return 0; }
FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY="preview_events_v1"
SH
	cat > "$temp_dir/bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
	if [ "$arg" = "%{http_code}" ]; then
		printf '200'
		exit 0
	fi
done
exit 0
SH
	chmod +x "$temp_dir/bin/curl"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output=$(
		PATH="$temp_dir/bin:/usr/bin:/bin" \
		env -u FJCLOUD_FLAPJACK_REQUIRED_REVISION \
			-u FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID \
			-u FJCLOUD_FLAPJACK_REQUIRED_SHA256 \
			bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a healthy runtime without exact identity evidence"
	assert_contains "$output" "has no selected local Flapjack binary and no exact required identity evidence" \
		"playwright stack should explain the missing exact identity evidence"
}

test_playwright_stack_applies_migrations_before_api_start() {
	local temp_dir fake_bin output remote_output remote_exit_code=0 exit_code=0
	mkdir -p "$REPO_ROOT/.local"
	temp_dir="$(mktemp -d "$REPO_ROOT/.local/playwright-stack-test.XXXXXX")"
	fake_bin="$temp_dir/bin"
	mkdir -p "$fake_bin" "$temp_dir/scripts/lib" "$temp_dir/.local"
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	cp "$REPO_ROOT/scripts/lib/local_stack_contract.sh" "$temp_dir/scripts/lib/local_stack_contract.sh"
	chmod +x "$temp_dir/scripts/playwright_local_stack.sh"

	cat > "$temp_dir/scripts/lib/env.sh" <<'SH'
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="local-test-key"
load_env_file() { :; }
SH
	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() {
	for _ in $(seq 1 400); do
		curl -fsS "$1" >/dev/null 2>&1 && return 0
		sleep 0.05
	done
	return 1
}
SH
	cat > "$temp_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { printf '%s\n' "$TEST_STACK_RUN_DIR/flapjack-server"; }
flapjack_source_provenance_summary() { printf 'test-source\n'; }
flapjack_export_required_runtime_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_REVISION="test-revision"
	export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="test-digest"
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
SH
	cat > "$fake_bin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$fake_bin/lsof"
	write_stack_harness_curl "$fake_bin/curl"
	write_stack_harness_sleeping_service "$temp_dir/flapjack-server" \
		"flapjack_child.pid" "flapjack_ready" "flapjack_terminated"
	cat > "$temp_dir/scripts/local-dev-migrate.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
touch "${TEST_STACK_RUN_DIR:?}/migrations_applied"
SH
	chmod +x "$temp_dir/scripts/local-dev-migrate.sh"
	cat > "$temp_dir/scripts/api-dev.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
run_dir="${TEST_STACK_RUN_DIR:?}"
if [ ! -f "$run_dir/migrations_applied" ]; then
	echo "api started before migrations" >&2
	exit 1
fi
echo "$$" > "$run_dir/api_child.pid"
touch "$run_dir/api_ready"
trap 'touch "$run_dir/api_terminated"; exit 0' TERM INT
while true; do sleep 1; done
SH
	chmod +x "$temp_dir/scripts/api-dev.sh"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	remote_output=$(
		TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$fake_bin:$PATH" \
		DATABASE_URL="postgresql://playwright:secret@db.production.example:5432/fjcloud" \
		FLAPJACK_URL="http://127.0.0.1:7715" \
		API_BASE_URL="http://127.0.0.1:3205" \
		API_URL="http://127.0.0.1:3205" \
		LISTEN_ADDR="127.0.0.1:3205" \
		PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="3" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || remote_exit_code=$?

	assert_eq "$remote_exit_code" "1" \
		"playwright stack should reject automatic migrations for a non-loopback database"
	assert_contains "$remote_output" "refusing to apply local Playwright migrations to a non-loopback DATABASE_URL" \
		"playwright stack should explain the database safety rejection without printing credentials"
	[ ! -f "$temp_dir/migrations_applied" ] || \
		fail "playwright stack must reject a remote database before invoking migrations"

	output=$(
		TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$fake_bin:$PATH" \
		DATABASE_URL="postgresql://playwright:secret@127.0.0.1:5432/fjcloud" \
		FLAPJACK_URL="http://127.0.0.1:7715" \
		API_BASE_URL="http://127.0.0.1:3205" \
		API_URL="http://127.0.0.1:3205" \
		LISTEN_ADDR="127.0.0.1:3205" \
		PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="3" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "0" \
		"playwright stack should apply local migrations before API startup"
	assert_file_eventually_exists "$temp_dir/migrations_applied" \
		"playwright stack should invoke the local migration script"
	assert_not_contains "$output" "api started before migrations" \
		"API should not start before the migration prerequisite"
}

write_stack_harness_curl() {
	local curl_path="$1"

	cat > "$curl_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

run_dir="${TEST_STACK_RUN_DIR:?}"
args="$*"

if [[ "$args" == *"/2/abtests"* ]]; then
	for i in "$@"; do
		if [ "$i" = "%{http_code}" ]; then
			printf '200'
			exit 0
		fi
	done
	exit 0
fi

if [[ "$args" == *":3205/health"* ]]; then
	[ -f "$run_dir/api_ready" ]
	exit $?
fi

if [[ "$args" == *":3205/version"* ]]; then
	printf '%s' '{"capabilities":["preview_events_v1"]}'
	exit 0
fi

if [[ "$args" == *":7715/health"* ]]; then
	if [ -f "$run_dir/flapjack_ready" ]; then printf '{"status":"ok","version":"1.0.10","build":{"schemaVersion":1,"version":"1.0.10","revision":"%s","revisionKnown":true,"dirty":false,"dirtyKnown":true,"workspaceDigest":"%s","binary_sha256":"%s","profile":"debug","target":"test-target","features":[],"capabilities":{"vectorSearch":true,"vectorSearchLocal":true}}}' "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-test-revision}" "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-test-digest}" "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-test-sha}"; exit 0; fi
	exit 1
fi

exit 1
SH
	chmod +x "$curl_path"
}

write_stack_harness_sleeping_service() {
	local service_path="$1" pid_file="$2" ready_file="$3" terminated_file="$4"

	cat > "$service_path" <<SH
#!/usr/bin/env bash
set -euo pipefail
run_dir="\${TEST_STACK_RUN_DIR:?}"
echo "\$\$" > "\$run_dir/$pid_file"
touch "\$run_dir/$ready_file"
trap 'touch "\$run_dir/$terminated_file"; exit 0' TERM INT
while true; do sleep 1; done
SH
	chmod +x "$service_path"
}

kill_stack_harness_pid() {
	local pid="$1"

	if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
		kill "$pid" 2>/dev/null || true
		wait "$pid" 2>/dev/null || true
	fi
}

assert_file_eventually_exists() {
	local abs_path="$1" msg="$2"
	local attempts="${3:-40}"

	for _ in $(seq 1 "$attempts"); do
		if [ -f "$abs_path" ]; then
			pass "$msg"
			return
		fi
		sleep 0.1
	done

	fail "$msg (missing '$abs_path')"
}

test_stack_pid_termination_cleans_children_after_web_start() {
	local temp_dir fake_bin wrapper_pid api_pid flapjack_pid web_pid
	mkdir -p "$REPO_ROOT/.local"
	temp_dir="$(mktemp -d "$REPO_ROOT/.local/playwright-stack-test.XXXXXX")"
	fake_bin="$temp_dir/bin"
	mkdir -p "$fake_bin" "$temp_dir/scripts/lib" "$temp_dir/.local"

	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	cp "$REPO_ROOT/scripts/lib/local_stack_contract.sh" "$temp_dir/scripts/lib/local_stack_contract.sh"
	chmod +x "$temp_dir/scripts/playwright_local_stack.sh"

	cat > "$temp_dir/scripts/lib/env.sh" <<'SH'
DEFAULT_LOCAL_FLAPJACK_ADMIN_KEY="local-test-key"
load_env_file() { :; }
SH
	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() {
	for _ in $(seq 1 400); do
		curl -fsS "$1" >/dev/null 2>&1 && return 0
		sleep 0.05
	done
	return 1
}
SH
	cat > "$temp_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { printf '%s\n' "$TEST_STACK_RUN_DIR/flapjack-server"; }
flapjack_source_provenance_summary() { printf 'test-source\n'; }
flapjack_export_required_runtime_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_REVISION="test-revision"
	export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="test-digest"
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
SH
	cat > "$fake_bin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$fake_bin/lsof"
	write_stack_harness_curl "$fake_bin/curl"
	write_stack_harness_sleeping_service "$temp_dir/flapjack-server" \
		"flapjack_child.pid" "flapjack_ready" "flapjack_terminated"
	cat > "$temp_dir/scripts/local-dev-migrate.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$temp_dir/scripts/local-dev-migrate.sh"
	write_stack_harness_sleeping_service "$temp_dir/scripts/api-dev.sh" \
		"api_child.pid" "api_ready" "api_terminated"
	write_stack_harness_sleeping_service "$temp_dir/scripts/web-dev.sh" \
		"web_child.pid" "web_ready" "web_terminated"

	TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$fake_bin:$PATH" \
		DATABASE_URL="postgresql://playwright:secret@127.0.0.1:5432/fjcloud" \
		FLAPJACK_URL="http://127.0.0.1:7715" \
		API_BASE_URL="http://127.0.0.1:3205" \
		API_URL="http://127.0.0.1:3205" \
		LISTEN_ADDR="127.0.0.1:3205" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" >"$temp_dir/stack.log" 2>&1 &
	wrapper_pid="$!"

	assert_file_eventually_exists "$temp_dir/flapjack_child.pid" \
		"playwright stack harness should start the Flapjack child before lifecycle cleanup assertion" \
		200
	assert_file_eventually_exists "$temp_dir/api_child.pid" \
		"playwright stack harness should start the API child before lifecycle cleanup assertion" \
		200
	assert_file_eventually_exists "$temp_dir/web_ready" \
		"playwright stack harness should reach web startup before lifecycle cleanup assertion" \
		200

	if [ ! -f "$temp_dir/web_ready" ] || \
		[ ! -f "$temp_dir/api_child.pid" ] || \
		[ ! -f "$temp_dir/flapjack_child.pid" ]; then
		kill_stack_harness_pid "$wrapper_pid"
		cat "$temp_dir/stack.log" >&2 2>/dev/null || true
		fail "playwright stack harness should reach web startup before lifecycle cleanup assertion"
		rm -rf "$temp_dir"
		return
	fi

	api_pid="$(cat "$temp_dir/api_child.pid")"
	flapjack_pid="$(cat "$temp_dir/flapjack_child.pid")"
	web_pid="$(cat "$temp_dir/web_child.pid")"
	kill_stack_harness_pid "$wrapper_pid"

	assert_file_eventually_exists "$temp_dir/api_terminated" \
		"terminating the stack PID after web startup should terminate the API child"
	assert_file_eventually_exists "$temp_dir/flapjack_terminated" \
		"terminating the stack PID after web startup should terminate the Flapjack child"
	assert_file_eventually_exists "$temp_dir/web_terminated" \
		"terminating the stack PID after web startup should terminate the Playwright web child"

	kill_stack_harness_pid "$api_pid"
	kill_stack_harness_pid "$flapjack_pid"
	kill_stack_harness_pid "$web_pid"
	rm -rf "$temp_dir"
}

test_flapjack_bootstrap_initializes_experiment_storage
	test_default_flapjack_data_dir_is_port_scoped
	test_stack_harness_creates_repo_local_scratch_parent
	test_term_trap_exits_after_cleanup
	test_playwright_stack_logs_shared_flapjack_provenance
	test_playwright_stack_surfaces_helper_source_provenance
	test_playwright_stack_rejects_healthy_runtime_when_source_resolution_fails
	test_playwright_stack_rejects_healthy_runtime_without_exact_identity_evidence
	test_playwright_stack_applies_migrations_before_api_start
	test_stack_pid_termination_cleans_children_after_web_start

run_test_summary
