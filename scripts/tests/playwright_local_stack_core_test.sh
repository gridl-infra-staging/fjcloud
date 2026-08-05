#!/usr/bin/env bash
# Tests for scripts/playwright_local_stack.sh local Flapjack bootstrap behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/playwright_local_stack_harness.sh
source "$SCRIPT_DIR/lib/playwright_local_stack_harness.sh"
# shellcheck source=lib/playwright_port_oracle.sh
source "$SCRIPT_DIR/lib/playwright_port_oracle.sh"

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

test_playwright_stack_rejects_unserved_public_infrastructure_before_web_start() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/public_infrastructure_unserved"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
touch "${TEST_STACK_RUN_DIR:?}/web_started"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject an API whose public infrastructure route is unserved"
	assert_contains "$output" "http://127.0.0.1:3205/public/infrastructure" \
		"public route readiness failure should name the selected stack-owned API route"
	assert_contains "$output" "status=404" \
		"public route readiness failure should report the HTTP status"
	assert_contains "$output" 'body_tail={"error":"public route unavailable"}' \
		"public route readiness failure should report the bounded response body tail"
	[ ! -f "$temp_dir/web_started" ] || \
		fail "playwright stack must reject public route mismatch before web-dev.sh starts"
}

test_playwright_stack_exports_ready_public_api_to_web() {
	local temp_dir fake_bin output requests web_env exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf 'API_BASE_URL=%s\nAPI_URL=%s\n' "$API_BASE_URL" "$API_URL" \
	> "${TEST_STACK_RUN_DIR:?}/web_env.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || exit_code=$?
	requests="$(cat "$temp_dir/api_requests.log")"
	web_env="$(cat "$temp_dir/web_env.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" "playwright stack should accept the ready public API"
	assert_contains "$requests" "http://127.0.0.1:3205/health" \
		"playwright stack should check health on the selected API"
	assert_contains "$requests" "http://127.0.0.1:3205/version" \
		"playwright stack should check capabilities on the selected API"
	assert_contains "$requests" "http://127.0.0.1:3205/public/infrastructure" \
		"playwright stack should check the anonymous public route on the selected API"
	assert_eq "$web_env" $'API_BASE_URL=http://127.0.0.1:3205\nAPI_URL=http://127.0.0.1:3205' \
		"web-dev.sh should inherit the exact ready stack-owned API URL"
}

test_playwright_stack_settles_public_cache_before_web_start() {
	local temp_dir fake_bin events output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready"
	cat > "$fake_bin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "17" ]; then
	printf '%s\n' "cache_settled" >> "${TEST_STACK_RUN_DIR:?}/events.log"
	exit 0
fi
exec /bin/sleep "$@"
SH
	chmod +x "$fake_bin/sleep"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "web_started" >> "${TEST_STACK_RUN_DIR:?}/events.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS="17" 2>&1
	)" || exit_code=$?
	events="$(cat "$temp_dir/events.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should accept a ready API before settling its public cache"
	assert_eq "$events" $'public_infrastructure\ncache_settled\nweb_started' \
		"playwright stack should let readiness cache data expire before web startup"
}

test_playwright_stack_rejects_invalid_public_cache_settle_seconds() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS="invalid" 2>&1
	)" || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject an invalid public cache settle interval"
	assert_contains "$output" \
			"PLAYWRIGHT_PUBLIC_INFRASTRUCTURE_CACHE_SETTLE_SECONDS must be a non-negative integer" \
			"invalid public cache settle intervals should have an actionable diagnostic"
}

test_playwright_stack_rejects_non_loopback_flapjack_url() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			FLAPJACK_URL="http://flapjack.example.test:7715" 2>&1
	)" || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a non-loopback Flapjack URL before startup"
	assert_contains "$output" "FLAPJACK_URL must be a loopback HTTP URL" \
		"remote Flapjack rejection should explain the local-only contract"
		[ ! -f "$temp_dir/api_requests.log" ] || \
			fail "remote Flapjack rejection must happen before any API readiness requests"
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

test_dispatcher_runs_every_child_suite_after_a_failure() {
	local temp_dir exit_code=0
	temp_dir="$(mktemp -d)"
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	cp "$SCRIPT_DIR/playwright_local_stack_test.sh" "$temp_dir/playwright_local_stack_test.sh"

	cat > "$temp_dir/playwright_local_stack_flapjack_test.sh" <<'SH'
printf '%s\n' flapjack >> "${TEST_DISPATCH_LOG:?}"
exit 17
SH
	cat > "$temp_dir/playwright_local_stack_web_reclaim_test.sh" <<'SH'
printf '%s\n' web_reclaim >> "${TEST_DISPATCH_LOG:?}"
SH
	cat > "$temp_dir/playwright_local_stack_core_test.sh" <<'SH'
printf '%s\n' core >> "${TEST_DISPATCH_LOG:?}"
SH

	TEST_DISPATCH_LOG="$temp_dir/dispatch.log" \
		bash "$temp_dir/playwright_local_stack_test.sh" \
		> "$temp_dir/dispatcher.output" 2>&1 || exit_code=$?

	assert_eq "$exit_code" "1" \
		"dispatcher should return non-zero after any child suite fails"
	assert_eq "$(cat "$temp_dir/dispatch.log" 2>/dev/null || true)" \
		$'flapjack\nweb_reclaim\ncore' \
		"dispatcher should run every child suite after the first suite fails"
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
		ADMIN_KEY="playwright-local-admin-test-key" \
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

test_playwright_stack_applies_migrations_before_api_start

test_playwright_stack_rejects_unserved_public_infrastructure_before_web_start

test_playwright_stack_exports_ready_public_api_to_web

test_playwright_stack_settles_public_cache_before_web_start

test_playwright_stack_rejects_invalid_public_cache_settle_seconds

test_playwright_stack_rejects_non_loopback_flapjack_url

test_verification_required_mode_starts_mailpit_and_requires_message_json

test_verification_required_mode_removes_api_skip_env_but_default_preserves_it

test_verification_required_mode_hands_local_email_delivery_contract_to_api_dev

test_verification_required_mode_can_be_enabled_by_env_file

test_dispatcher_runs_every_child_suite_after_a_failure

test_stack_pid_termination_cleans_children_after_web_start



run_test_summary
