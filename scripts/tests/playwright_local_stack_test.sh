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

test_playwright_stack_static_contracts() {
	local script_text harness_text logic_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"
	harness_text="$(cat "$REPO_ROOT/scripts/tests/playwright_local_stack_test.sh")"
	logic_text="$(grep -v 'run: cargo build -p flapjack-server' "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" 'FLAPJACK_PORT="$(parse_port_from_http_url "$FLAPJACK_URL")"' \
		"playwright stack should derive the Flapjack port before choosing a data directory"
	assert_contains "$script_text" 'FLAPJACK_DATA_DIR="${PLAYWRIGHT_FLAPJACK_DATA_DIR:-$LOCAL_DIR/flapjack-data-playwright-$FLAPJACK_PORT}"' \
		"playwright stack should isolate default Flapjack data directories per port"
	assert_contains "$harness_text" 'mkdir -p "$REPO_ROOT/.local"' \
		"playwright stack harness should create its repo-local scratch parent before mktemp"
	assert_contains "$harness_text" 'mktemp -d "$REPO_ROOT/.local/playwright-stack-test.XXXXXX"' \
		"playwright stack harness should keep scratch data under repo-local .local"
	assert_contains "$script_text" "handle_shutdown() {" \
		"playwright stack should define an explicit shutdown trap handler"
	assert_contains "$script_text" "trap cleanup EXIT" \
		"playwright stack should still clean up on normal shell exit"
	assert_contains "$script_text" "trap handle_shutdown INT TERM" \
		"playwright stack should exit instead of resuming after INT/TERM cleanup"
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
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

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
flapjack_export_required_artifact_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
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
	cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
	if [ "$arg" = "%{http_code}" ]; then
		printf '200'
		exit 0
	fi
done
exit 0
SH
	chmod +x "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
	: > "$temp_dir/flapjack-server"
	chmod +x "$temp_dir/flapjack-server"

	output=$(
		TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$fake_bin:/usr/bin:/bin" \
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
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

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
	write_exit_zero_stub "$fake_bin/curl"

	output=$(
		PATH="$fake_bin:/usr/bin:/bin" \
		FLAPJACK_DEV_DIR="$temp_dir/selected-source" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a healthy runtime when selected-source resolution fails"
	assert_contains "$output" "selected FLAPJACK_DEV_DIR source build or provenance validation failed" \
		"playwright stack should surface the authoritative source-resolution failure"
}

test_playwright_stack_rejects_healthy_runtime_without_exact_identity_evidence() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

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
	cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
	if [ "$arg" = "%{http_code}" ]; then
		printf '200'
		exit 0
	fi
done
exit 0
SH
	chmod +x "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output=$(
		PATH="$fake_bin:/usr/bin:/bin" \
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

write_exit_zero_stub() {
	cat > "$1" <<'SH'
#!/usr/bin/env bash
exit 0
SH
	chmod +x "$1"
}

prepare_playwright_stack_harness() {
	mkdir -p "$REPO_ROOT/.local"
	temp_dir="$(mktemp -d "$REPO_ROOT/.local/playwright-stack-test.XXXXXX")"
	fake_bin="$temp_dir/bin"
	mkdir -p "$fake_bin" "$temp_dir/scripts/lib" "$temp_dir/.local"
	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	cp "$REPO_ROOT/scripts/lib/local_stack_contract.sh" "$temp_dir/scripts/lib/local_stack_contract.sh"
	cp "$REPO_ROOT/scripts/lib/compose_project.sh" "$temp_dir/scripts/lib/compose_project.sh"
	cp "$REPO_ROOT/scripts/lib/local_url.sh" "$temp_dir/scripts/lib/local_url.sh"
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
flapjack_export_required_artifact_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
flapjack_export_required_runtime_identity() {
	export FJCLOUD_FLAPJACK_REQUIRED_REVISION="test-revision"
	export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="test-digest"
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256="test-sha"
}
SH
	write_exit_zero_stub "$fake_bin/lsof"
	write_stack_harness_sleeping_service "$temp_dir/flapjack-server" "flapjack"
}

run_playwright_stack_harness() {
	local path_value="$1"
	shift

	env \
		TEST_STACK_RUN_DIR="$temp_dir" \
		PATH="$path_value" \
		DATABASE_URL="postgresql://playwright:secret@127.0.0.1:5432/fjcloud" \
		FLAPJACK_URL="http://127.0.0.1:7715" \
		API_BASE_URL="http://127.0.0.1:3205" \
		API_URL="http://127.0.0.1:3205" \
		LISTEN_ADDR="127.0.0.1:3205" \
		"$@" bash "$temp_dir/scripts/playwright_local_stack.sh"
}

test_playwright_stack_applies_migrations_before_api_start() {
	local temp_dir fake_bin output remote_output remote_exit_code=0 exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
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
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	remote_output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			DATABASE_URL="postgresql://playwright:secret@db.production.example:5432/fjcloud" \
			PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="3" 2>&1
	) || remote_exit_code=$?

	assert_eq "$remote_exit_code" "1" \
		"playwright stack should reject automatic migrations for a non-loopback database"
	assert_contains "$remote_output" "refusing to apply local Playwright migrations to a non-loopback DATABASE_URL" \
		"playwright stack should explain the database safety rejection without printing credentials"
	[ ! -f "$temp_dir/migrations_applied" ] || \
		fail "playwright stack must reject a remote database before invoking migrations"

	output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="3" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "0" \
		"playwright stack should apply local migrations before API startup"
	assert_file_eventually_exists "$temp_dir/migrations_applied" \
		"playwright stack should invoke the local migration script"
	assert_not_contains "$output" "api started before migrations" \
		"API should not start before the migration prerequisite"
}

test_verification_required_mode_starts_mailpit_and_requires_message_json() {
	local temp_dir fake_bin output preexisting_output exit_code=0 preexisting_exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_STACK_RUN_DIR:?}/docker_calls.log"
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
	if [ -f "$TEST_STACK_RUN_DIR/mailpit_ps_failure" ]; then
		exit 42
	fi
	if [ -f "$TEST_STACK_RUN_DIR/mailpit_preexisting" ]; then
		printf '%s\n' "mailpit"
	fi
	exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "up" ] && [ "$3" = "-d" ] && [ "$4" = "mailpit" ]; then
	touch "$TEST_STACK_RUN_DIR/mailpit_compose_started"
	exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "stop" ] && [ "$3" = "mailpit" ]; then
	touch "$TEST_STACK_RUN_DIR/mailpit_compose_stopped"
	exit 0
fi
exit 1
SH
	chmod +x "$fake_bin/docker"
cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
run_dir="${TEST_STACK_RUN_DIR:?}"
args="$*"
output_path=""
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
		output_path="$2"
		shift 2
		continue
	fi
	shift
done
if [[ "$args" == *":8025/api/v1/messages"* ]]; then
	if [ -n "$output_path" ]; then
		printf '%s' '{"total":0}' > "$output_path"
	else
		printf '%s' '{"total":0}'
	fi
	exit 0
fi
if [[ "$args" == *":3205/health"* ]]; then
	exit 1
fi
if [[ "$args" == *":7715/health"* ]]; then
	if [ -f "$run_dir/flapjack_ready" ]; then
		printf '{"status":"ok","version":"1.0.10","build":{"schemaVersion":1,"version":"1.0.10","revision":"test-revision","revisionKnown":true,"dirty":false,"dirtyKnown":true,"workspaceDigest":"test-digest","binary_sha256":"test-sha","profile":"debug","target":"test-target","features":[],"capabilities":{"vectorSearch":true,"vectorSearchLocal":true}}}'
		exit 0
	fi
	exit 1
fi
exit 1
SH
	chmod +x "$fake_bin/curl"
	output=$(
		run_playwright_stack_harness "$fake_bin:/usr/bin:/bin" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" \
			PLAYWRIGHT_MAILPIT_READY_TIMEOUT_SECONDS="1" 2>&1
	) || exit_code=$?
	assert_eq "$exit_code" "1" \
		"verification-required stack should fail closed when Mailpit messages JSON is malformed"
	assert_file_exists "$temp_dir/mailpit_compose_started" \
		"verification-required stack should start or verify the compose-owned Mailpit service"
	assert_contains "$output" "Mailpit" \
		"verification-required stack should name Mailpit in readiness failures"
	assert_contains "$output" "/api/v1/messages" \
		"verification-required stack should report the message-store readiness endpoint"
	assert_file_exists "$temp_dir/mailpit_compose_stopped" \
		"verification-required stack should stop Mailpit when this invocation started it"

	rm -f "$temp_dir/docker_calls.log" "$temp_dir/mailpit_compose_started" \
		"$temp_dir/mailpit_compose_stopped"
	touch "$temp_dir/mailpit_preexisting"
	preexisting_output=$(
		run_playwright_stack_harness "$fake_bin:/usr/bin:/bin" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" \
			PLAYWRIGHT_MAILPIT_READY_TIMEOUT_SECONDS="1" 2>&1
	) || preexisting_exit_code=$?
	assert_eq "$preexisting_exit_code" "1" \
		"verification-required stack should still fail malformed pre-existing Mailpit readiness"
	assert_not_contains "$(cat "$temp_dir/docker_calls.log")" "compose up -d mailpit" \
		"verification-required stack should not start a Mailpit service that was already running"
	assert_not_contains "$(cat "$temp_dir/docker_calls.log")" "compose stop mailpit" \
		"verification-required stack should preserve a Mailpit service that was already running"
	assert_contains "$preexisting_output" "Mailpit" \
		"pre-existing Mailpit readiness failures should remain actionable"

	assert_indeterminate_mailpit_ownership_fails_closed "$temp_dir" "$fake_bin"
	assert_remote_mailpit_url_is_rejected "$temp_dir" "$fake_bin"
}

assert_indeterminate_mailpit_ownership_fails_closed() {
	local temp_dir="$1" fake_bin="$2" output exit_code=0

	rm -f "$temp_dir/docker_calls.log" "$temp_dir/mailpit_preexisting"
	touch "$temp_dir/mailpit_ps_failure"
	output=$(
		run_playwright_stack_harness "$fake_bin:/usr/bin:/bin" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" 2>&1
	) || exit_code=$?
	assert_eq "$exit_code" "1" \
		"verification-required stack should fail closed when Mailpit ownership is indeterminate"
	assert_contains "$output" "could not determine whether Mailpit is already running" \
		"Mailpit ownership-probe failures should explain why startup was refused"
	assert_not_contains "$(cat "$temp_dir/docker_calls.log")" "compose up -d mailpit" \
		"an indeterminate ownership probe must not start or adopt Mailpit"
	assert_not_contains "$(cat "$temp_dir/docker_calls.log")" "compose stop mailpit" \
		"an indeterminate ownership probe must not stop Mailpit"
}

assert_remote_mailpit_url_is_rejected() {
	local temp_dir="$1" fake_bin="$2" output exit_code=0

	rm -f "$temp_dir/docker_calls.log" "$temp_dir/mailpit_ps_failure"
	output=$(
		run_playwright_stack_harness "$fake_bin:/usr/bin:/bin" \
			MAILPIT_API_URL="http://mail.example.test:8025" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" 2>&1
	) || exit_code=$?
	assert_eq "$exit_code" "1" \
		"verification-required stack should reject non-loopback Mailpit URLs"
	assert_contains "$output" "loopback HTTP MAILPIT_API_URL" \
		"non-loopback Mailpit rejection should state the local-only contract"
	[ ! -f "$temp_dir/docker_calls.log" ] || \
		fail "non-loopback Mailpit rejection must happen before any compose operation"
}

test_verification_required_mode_removes_api_skip_env_but_default_preserves_it() {
	local temp_dir fake_bin healthy_output required_output default_output healthy_exit_code=0
	local required_exit_code=0 default_exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "compose" ] && [ "$2" = "up" ] && [ "$3" = "-d" ] && [ "$4" = "mailpit" ]; then
	exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
	exit 0
fi
exit 1
SH
	chmod +x "$fake_bin/docker"
	write_stack_harness_curl "$fake_bin/curl"
	write_stack_harness_sleeping_service "$temp_dir/scripts/api-dev.sh" "api"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf 'SKIP_EMAIL_VERIFICATION=%s\n' "${SKIP_EMAIL_VERIFICATION-__absent__}"
printf 'API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=%s\n' "${API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION-__absent__}"
exit 0
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"
	touch "$temp_dir/api_ready"
	healthy_output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" 2>&1
	) || healthy_exit_code=$?
	assert_eq "$healthy_exit_code" "1" \
		"verification-required stack should reject an already-healthy API with unknown email mode"
	assert_contains "$healthy_output" "cannot reuse the already-healthy API" \
		"healthy API mode mismatch should explain why reuse is unsafe"
	assert_contains "$healthy_output" "--force-api-restart" \
		"healthy API mode mismatch should identify the owned restart path"
	[ ! -f "$temp_dir/api_child.pid" ] || \
		fail "verification-required stack must not accept or replace a healthy API unchanged"
	rm -f "$temp_dir/api_ready"

	required_output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" 2>&1
	) || required_exit_code=$?
	rm -f "$temp_dir/api_ready" "$temp_dir/api_child.pid" "$temp_dir/api_terminated"

	default_output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || default_exit_code=$?

	assert_eq "$required_exit_code" "0" \
		"verification-required stack should complete with mocked Mailpit readiness"
	assert_contains "$required_output" "SKIP_EMAIL_VERIFICATION=__absent__" \
		"verification-required stack should start web/API environment without SKIP_EMAIL_VERIFICATION"
	assert_contains "$required_output" "API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=__absent__" \
		"verification-required stack should start web/API environment without the skip-verification allow flag"
	assert_eq "$default_exit_code" "0" \
		"default stack should complete with mocked local startup"
	assert_contains "$default_output" "SKIP_EMAIL_VERIFICATION=1" \
		"default stack path should preserve auto-verification for routine fixtures"
	assert_contains "$default_output" "API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=1" \
		"default stack path should preserve the API dev allow flag for routine fixtures"
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

if [[ "$args" == *":8025/api/v1/messages"* ]]; then
	output_path=""
	while [ "$#" -gt 0 ]; do
		if [ "$1" = "-o" ] && [ "$#" -ge 2 ]; then
			output_path="$2"
			shift 2
			continue
		fi
		shift
	done
	if [ -n "$output_path" ]; then
		printf '%s' '{"messages":[]}' > "$output_path"
	else
		printf '%s' '{"messages":[]}'
	fi
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

# Scaffold the shared Mailpit, API, migration, and web stubs.
write_verification_required_stack_stubs() {
	local temp_dir="$1" fake_bin="$2"
	shift 2

	cat > "$fake_bin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${TEST_STACK_RUN_DIR:?}/docker_calls.log"
if [ "$1" = "compose" ] && [ "$2" = "ps" ]; then
	exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "up" ] && [ "$3" = "-d" ] && [ "$4" = "mailpit" ]; then
	exit 0
fi
if [ "$1" = "compose" ] && [ "$2" = "stop" ] && [ "$3" = "mailpit" ]; then
	exit 0
fi
exit 1
SH
	chmod +x "$fake_bin/docker"
	write_stack_harness_curl "$fake_bin/curl"
	write_stack_harness_sleeping_service "$temp_dir/scripts/api-dev.sh" "api" "$@"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
}

test_verification_required_mode_hands_local_email_delivery_contract_to_api_dev() {
	local temp_dir fake_bin required_output default_output required_exit_code=0 default_exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_verification_required_stack_stubs "$temp_dir" "$fake_bin" \
		API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY MAILPIT_API_URL

	required_output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION="1" \
			API_DEV_ALLOW_SES_EMAIL="1" 2>&1
	) || required_exit_code=$?
	assert_eq "$required_exit_code" "0" \
		"verification-required stack should complete with mocked Mailpit readiness"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1" \
		"verification-required stack should require local email delivery across the api-dev env-file reload"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"MAILPIT_API_URL=http://127.0.0.1:8025" \
		"verification-required stack should hand api-dev the loopback Mailpit endpoint"
	rm -f "$temp_dir/api_ready" "$temp_dir/api_child.pid" "$temp_dir/api_env.log"

	default_output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || default_exit_code=$?
	assert_eq "$default_exit_code" "0" \
		"default stack should complete with mocked local startup"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=__absent__" \
		"default stack path should leave api-dev email routing at its documented defaults"
}

test_verification_required_mode_can_be_enabled_by_env_file() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	cp "$REPO_ROOT/scripts/lib/env.sh" "$temp_dir/scripts/lib/env.sh"
	write_verification_required_stack_stubs "$temp_dir" "$fake_bin" \
		API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY MAILPIT_API_URL SKIP_EMAIL_VERIFICATION API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION
	cat > "$temp_dir/.env.local" <<'EOF'
PLAYWRIGHT_REQUIRE_EMAIL_VERIFICATION=1
EOF

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || exit_code=$?

	assert_eq "$exit_code" "0" \
		"verification-required stack should complete when .env.local enables the mode"
	assert_contains "$(cat "$temp_dir/docker_calls.log" 2>/dev/null || true)" \
		"compose up -d mailpit" \
		".env.local verification-required mode should own Mailpit readiness"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"API_DEV_REQUIRE_LOCAL_EMAIL_DELIVERY=1" \
		".env.local verification-required mode should hand local-email delivery to api-dev"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"MAILPIT_API_URL=http://127.0.0.1:8025" \
		".env.local verification-required mode should use the default loopback Mailpit URL"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"SKIP_EMAIL_VERIFICATION=__absent__" \
		".env.local verification-required mode should remove the auto-verification bypass"
	assert_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"API_DEV_ALLOW_SKIP_EMAIL_VERIFICATION=__absent__" \
		".env.local verification-required mode should remove the api-dev bypass allow flag"
	assert_not_contains "$(cat "$temp_dir/api_env.log" 2>/dev/null || true)" "SKIP_EMAIL_VERIFICATION=1" \
		".env.local verification-required mode should not fall back to the routine auto-verification path"
}

# Write a stub service that records lifecycle state and selected environment.
write_stack_harness_sleeping_service() {
	local service_path="$1" state_prefix="$2"
	shift 2
	local env_dump="" env_key

	for env_key in "$@"; do
		env_dump+="printf '${env_key}=%s\\n' \"\${${env_key}-__absent__}\" >> \"\$run_dir/${state_prefix}_env.log\"
"
	done

	cat > "$service_path" <<SH
#!/usr/bin/env bash
set -euo pipefail
run_dir="\${TEST_STACK_RUN_DIR:?}"
${env_dump}echo "\$\$" > "\$run_dir/${state_prefix}_child.pid"
touch "\$run_dir/${state_prefix}_ready"
trap 'touch "\$run_dir/${state_prefix}_terminated"; exit 0' TERM INT
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
	prepare_playwright_stack_harness
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_stack_harness_sleeping_service "$temp_dir/scripts/api-dev.sh" "api"
	write_stack_harness_sleeping_service "$temp_dir/scripts/web-dev.sh" "web"

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
	test_playwright_stack_static_contracts
	test_playwright_stack_surfaces_helper_source_provenance
	test_playwright_stack_rejects_healthy_runtime_when_source_resolution_fails
	test_playwright_stack_rejects_healthy_runtime_without_exact_identity_evidence
	test_playwright_stack_applies_migrations_before_api_start
	test_verification_required_mode_starts_mailpit_and_requires_message_json
	test_verification_required_mode_removes_api_skip_env_but_default_preserves_it
	test_verification_required_mode_hands_local_email_delivery_contract_to_api_dev
	test_verification_required_mode_can_be_enabled_by_env_file
	test_stack_pid_termination_cleans_children_after_web_start

run_test_summary
