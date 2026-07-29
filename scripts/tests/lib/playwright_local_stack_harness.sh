#!/usr/bin/env bash
# Shared hermetic service stubs for playwright_local_stack_test.sh.
#
# Callers define REPO_ROOT and source the shared test runner/assertions first.

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
		PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS="0" \
		"$@" bash "$temp_dir/scripts/playwright_local_stack.sh"
}

write_stack_harness_curl() {
	local curl_path="$1"

	cat > "$curl_path" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

run_dir="${TEST_STACK_RUN_DIR:?}"
args="$*"

if [[ "$args" == *":3205/"* ]]; then
	printf '%s\n' "$args" >> "$run_dir/api_requests.log"
fi

if [[ "$args" == *"/2/abtests"* ]]; then
	for arg in "$@"; do
		if [ "$arg" = "%{http_code}" ]; then
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

if [[ "$args" == *":3205/public/infrastructure"* ]]; then
	printf '%s\n' "public_infrastructure" >> "$run_dir/events.log"
	if [ -f "$run_dir/public_infrastructure_unserved" ]; then
		printf '%s\n%s' '{"error":"public route unavailable"}' '404'
	else
		printf '%s\n%s' \
			'{"regions":[],"overall":{"availability_pct":null,"total_regions":0,"total_vms":0}}' \
			'200'
	fi
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
	if [ -f "$run_dir/flapjack_ready" ]; then
		printf '{"status":"ok","version":"1.0.10","build":{"schemaVersion":1,"version":"1.0.10","revision":"%s","revisionKnown":true,"dirty":false,"dirtyKnown":true,"workspaceDigest":"%s","binary_sha256":"%s","profile":"debug","target":"test-target","features":[],"capabilities":{"vectorSearch":true,"vectorSearchLocal":true}}}' "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-test-revision}" "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-test-digest}" "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-test-sha}"
		exit 0
	fi
	exit 1
fi

exit 1
SH
	chmod +x "$curl_path"
}

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
