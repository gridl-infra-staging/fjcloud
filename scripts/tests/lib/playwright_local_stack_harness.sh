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
	mkdir -p "$fake_bin" "$temp_dir/scripts/lib" "$temp_dir/.local" "$temp_dir/web"
	cp "$REPO_ROOT/scripts/playwright_local_stack.sh" "$temp_dir/scripts/playwright_local_stack.sh"
	cp "$REPO_ROOT/scripts/lib/local_stack_contract.sh" "$temp_dir/scripts/lib/local_stack_contract.sh"
	# The stack's web-port fallback reads the TypeScript contract through the Bash
	# mirror, so the harness tree carries both owners: without them the fallback
	# branch cannot execute here and would go untested.
	cp "$REPO_ROOT/scripts/lib/playwright_port_plan.sh" "$temp_dir/scripts/lib/playwright_port_plan.sh"
	cp "$REPO_ROOT/web/playwright.config.contract.ts" "$temp_dir/web/playwright.config.contract.ts"
	cp "$REPO_ROOT/scripts/lib/compose_project.sh" "$temp_dir/scripts/lib/compose_project.sh"
	cp "$REPO_ROOT/scripts/lib/local_url.sh" "$temp_dir/scripts/lib/local_url.sh"
	cp "$REPO_ROOT/scripts/lib/db_url.sh" "$temp_dir/scripts/lib/db_url.sh"
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
	cat > "$fake_bin/psql" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${PGHOST:-}" = "127.0.0.1" ] \
	&& [ "${PGPORT:-}" = "5432" ] \
	&& [ "${PGUSER:-}" = "playwright" ] \
	&& [ "${PGPASSWORD:-}" = "secret" ] \
	&& [ "${PGDATABASE:-}" = "fjcloud" ] || {
	echo "psql must receive parsed libpq connection fields" >&2
	exit 1
}
printf '%s\n' "$*" > "${TEST_STACK_RUN_DIR:?}/psql_args.log"
printf 'PGHOST=%s\nPGPORT=%s\nPGUSER=%s\nPGDATABASE=%s\n' \
	"$PGHOST" "$PGPORT" "$PGUSER" "$PGDATABASE" \
	> "${TEST_STACK_RUN_DIR:?}/psql_env.log"
cat > "$TEST_STACK_RUN_DIR/psql_stdin.sql"
# Simulate the bootstrap-admin reconciliation rewriting its single row. The stack reads
# this token to tell a real reconciliation from a silent no-op, so tests that want the
# other outcomes override this stub. Emitted only for that statement, so the stub cannot
# fake a healthy result for any other query.
if grep -q "bootstrap-admin-key" "$TEST_STACK_RUN_DIR/psql_stdin.sql"; then
	printf '%s\n' "${TEST_STACK_ADMIN_RECONCILE_STATE:-reconciled}"
fi
SH
	chmod +x "$fake_bin/psql"
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
		ADMIN_KEY="playwright-local-admin-test-key" \
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
		# The engine's deliberately-limited public projection: version, profile
		# and capabilities only, with no revision/workspaceDigest/dirty. This is
		# what a pre-existing runtime serves, so any caller that requires private
		# identity before the public compare classifies legacy_malformed_health.
		if [ -f "$run_dir/flapjack_public_health_only" ]; then
			printf '%s' '{"status":"ok","version":"1.0.10","build":{"schemaVersion":1,"version":"1.0.10","profile":"debug","capabilities":{"preview_events_v1":true}},"capabilities":{"preview_events_v1":true}}'
			exit 0
		fi
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

# Start a fake service script: shebang, run_dir, and one `<KEY>=<value>` line
# per requested env key appended to `<state_prefix>_env.log` (`__absent__` when
# the key is unset). Callers append their own body, then the shared tail.
write_stack_harness_service_header() {
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
${env_dump}
SH
}

# The shared long-running tail every fake stack service ends with: publish the
# child pid, announce readiness, and translate TERM/INT into a terminated marker.
append_stack_harness_service_tail() {
	local service_path="$1" state_prefix="$2"

	cat >> "$service_path" <<SH
echo "\$\$" > "\$run_dir/${state_prefix}_child.pid"
touch "\$run_dir/${state_prefix}_ready"
trap 'touch "\$run_dir/${state_prefix}_terminated"; exit 0' TERM INT
while true; do sleep 1; done
SH
	chmod +x "$service_path"
}

write_stack_harness_sleeping_service() {
	local service_path="$1" state_prefix="$2"
	shift 2

	write_stack_harness_service_header "$service_path" "$state_prefix" "$@"
	append_stack_harness_service_tail "$service_path" "$state_prefix"
}

# Fake `api-dev.sh` that only trusts inherited environment: it fails fast with a
# comma-separated missing/mismatch diagnostic unless the three private Flapjack
# identity variables match `<run_dir>/expected_identity.env`, which
# write_stack_harness_selected_identity_fixture owns. Requires that fixture.
write_stack_harness_identity_asserting_api() {
	local service_path="$1"

	write_stack_harness_service_header "$service_path" "api" \
		FJCLOUD_FLAPJACK_REQUIRED_REVISION \
		FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID \
		FJCLOUD_FLAPJACK_REQUIRED_SHA256
	cat >> "$service_path" <<'SH'
touch "$run_dir/api_launch_reached"
# shellcheck source=/dev/null
. "$run_dir/expected_identity.env"
diagnostics=""
for field in FJCLOUD_FLAPJACK_REQUIRED_REVISION FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID FJCLOUD_FLAPJACK_REQUIRED_SHA256; do
	eval "field_set=\"\${${field}+set}\""
	eval "field_value=\"\${${field}-}\""
	case "$field" in
		*_REVISION) expected="$EXPECTED_FLAPJACK_REVISION" ;;
		*_BUILD_ID) expected="$EXPECTED_FLAPJACK_BUILD_ID" ;;
		*_SHA256) expected="$EXPECTED_FLAPJACK_SHA256" ;;
	esac
	if [ -z "$field_set" ]; then
		diagnostics="${diagnostics:+$diagnostics,}missing:$field"
	elif [ "$field_value" != "$expected" ]; then
		diagnostics="${diagnostics:+$diagnostics,}mismatch:$field"
	fi
done
if [ -n "$diagnostics" ]; then
	printf 'api identity env mismatch: %s\n' "$diagnostics" >&2
	exit 42
fi
SH
	append_stack_harness_service_tail "$service_path" "api"
}

# Single owner of `<run_dir>/expected_identity.env`, the file
# write_stack_harness_identity_asserting_api compares the inherited environment
# against. Both identity lanes (selected local binary, operator-supplied
# environment) publish their expectation through here.
write_stack_harness_expected_identity_env() {
	local run_dir="$1" revision="$2" build_id="$3" binary_sha="$4"

	cat > "$run_dir/expected_identity.env" <<SH
EXPECTED_FLAPJACK_REVISION=$revision
EXPECTED_FLAPJACK_BUILD_ID=$build_id
EXPECTED_FLAPJACK_SHA256=$binary_sha
SH
}

# The no-selected-binary lane: `find_restart_ready_flapjack_binary` fails, so the
# launcher must fall back to identity the operator exported by hand. The contract
# stub reads that evidence straight from the environment, which is what makes an
# accidental exit-instead-of-fallthrough in the launcher observable.
write_stack_harness_unselected_binary_fixture() {
	local run_dir="$1"

	cat > "$run_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { return 1; }
flapjack_source_provenance_summary() { printf 'none\n'; }
SH
	cat > "$run_dir/scripts/lib/local_stack_contract.sh" <<'SH'
flapjack_required_runtime_identity_evidence_available() {
	[ -n "${FJCLOUD_FLAPJACK_REQUIRED_REVISION:-}" ] &&
		[ -n "${FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID:-}" ] &&
		[ -n "${FJCLOUD_FLAPJACK_REQUIRED_SHA256:-}" ]
}
flapjack_runtime_identity_reason() { printf 'match\n'; }
api_supports_capability() { return 0; }
api_public_infrastructure_is_ready() { return 0; }
FJCLOUD_API_PREVIEW_EVENTS_CAPABILITY="preview_events_v1"
SH
}

# Single owner of the selected-binary identity fixture: one source receipt, one
# expected-identity env file, and a flapjack_binary.sh stub that mirrors the real
# helper's artifact-vs-runtime exporter split (artifact = SHA only and clears the
# private fields; runtime = SHA plus receipt-derived revision/build digest).
# Receipt interpretation stays behind the helper stub so callers never parse it.
write_stack_harness_selected_identity_fixture() {
	local run_dir="$1" revision="$2" build_id="$3" binary_sha

	binary_sha="$(shasum -a 256 "$run_dir/flapjack-server" | awk '{print $1}')"
	mkdir -p "$run_dir/receipts"
	cat > "$run_dir/receipts/source.receipt" <<SH
git_revision=$revision
source_digest=$build_id
dirty=clean
binary_sha256=$binary_sha
SH
	write_stack_harness_expected_identity_env "$run_dir" "$revision" "$build_id" "$binary_sha"
	cat > "$run_dir/scripts/lib/flapjack_binary.sh" <<'SH'
FJCLOUD_FLAPJACK_VERSION="1.0.10"
FJCLOUD_FLAPJACK_SOURCE_RESOLUTION_FAILURE_STATUS=2
find_restart_ready_flapjack_binary() { printf '%s\n' "$TEST_STACK_RUN_DIR/flapjack-server"; }
flapjack_source_provenance_summary() { printf 'source-build:%s\n' "$TEST_STACK_RUN_DIR/receipts/source.receipt"; }
flapjack_binary_sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
flapjack_receipt_value() { awk -F= -v key="$2" '$1 == key { print $2 }' "$1"; }
flapjack_export_required_artifact_identity() {
	unset FJCLOUD_FLAPJACK_REQUIRED_REVISION
	unset FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID
	export FJCLOUD_FLAPJACK_REQUIRED_SHA256
	FJCLOUD_FLAPJACK_REQUIRED_SHA256="$(flapjack_binary_sha256 "$1")"
}
flapjack_export_required_runtime_identity() {
	local provenance receipt_path
	flapjack_export_required_artifact_identity "$1"
	provenance="$(flapjack_source_provenance_summary)"
	case "$provenance" in
		source-build:*) receipt_path="${provenance#source-build:}" ;;
		*) return 1 ;;
	esac
	export FJCLOUD_FLAPJACK_REQUIRED_REVISION
	export FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID
	FJCLOUD_FLAPJACK_REQUIRED_REVISION="$(flapjack_receipt_value "$receipt_path" "git_revision")"
	FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="$(flapjack_receipt_value "$receipt_path" "source_digest")"
}
SH
	printf '%s\n' "$binary_sha"
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
