#!/usr/bin/env bash
# Tests for scripts/playwright_local_stack.sh local Flapjack bootstrap behavior.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export REPO_ROOT

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"
# shellcheck source=lib/playwright_local_stack_harness.sh
source "$SCRIPT_DIR/lib/playwright_local_stack_harness.sh"
# shellcheck source=lib/playwright_port_oracle.sh
source "$SCRIPT_DIR/lib/playwright_port_oracle.sh"

# PLAYWRIGHT_WEB_PORT is deliberately left alone here: exporting it suite-wide
# would mask the stack's TypeScript-contract derivation branch in every case.
# Cases that need the env-owned branch pass the variable themselves.

write_stack_harness_web_port_holder_stubs() {
	local fake_bin="$1" held_port="$2" held_pid="$3" command_line="$4"
	local cwd="${5:-}"

	write_stack_harness_web_port_multi_holder_stubs "$fake_bin" "$held_port" \
		"$held_pid|$cwd|$command_line"
}

# How many LISTEN probes a TERMed holder keeps answering before it releases the
# port, modelling a stale web server that does not close its socket instantly.
# `never` models a holder that never releases. Default is an instant release.
set_stack_harness_web_port_release_delay() {
	printf '%s\n' "$1" > "$temp_dir/web_port_release_probe_delay"
}

# Stub lsof/ps/kill for an arbitrary set of listeners on one port. Each holder
# spec is `pid|cwd|command line` (empty cwd when the holder needs no cwd
# answer), and the generated stubs read the holder table at run time so the same
# port can present a mixed owned/foreign set in a caller-controlled pid order.
write_stack_harness_web_port_multi_holder_stubs() {
	local fake_bin="$1" held_port="$2"
	shift 2
	local spec holder_table="$temp_dir/web_port_holders.txt"

	# `|` is not IFS whitespace, so an empty cwd field survives the stubs' read
	# instead of collapsing into the command-line field.
	: > "$holder_table"
	for spec in "$@"; do
		printf '%s\n' "$spec" >> "$holder_table"
	done

	cat > "$fake_bin/lsof" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\${TEST_STACK_RUN_DIR:?}/lsof_calls.log"
run_dir="\${TEST_STACK_RUN_DIR:?}"
holder_table="\$run_dir/web_port_holders.txt"
if [ "\$*" = "-tiTCP:${held_port} -sTCP:LISTEN" ]; then
	# A TERMed holder keeps answering until its release budget is spent, so the
	# reclaim's post-TERM wait is observable: without it the next probe — the
	# web server's own bind — still sees the stale listener.
	while IFS='|' read -r pid cwd command_line; do
		if [ ! -f "\$run_dir/killed_pid.\$pid" ]; then
			printf '%s\n' "\$pid"
			continue
		fi
		remaining="\$(cat "\$run_dir/release_budget.\$pid" 2>/dev/null \
			|| cat "\$run_dir/web_port_release_probe_delay" 2>/dev/null || echo 0)"
		if [ "\$remaining" = "never" ]; then
			printf '%s\n' "\$pid"
			continue
		fi
		if [ "\$remaining" -le 0 ]; then
			continue
		fi
		printf '%s\n' "\$(( remaining - 1 ))" > "\$run_dir/release_budget.\$pid"
		printf '%s\n' "\$pid"
	done < "\$holder_table"
	exit 0
fi
while IFS='|' read -r pid cwd command_line; do
	if [ -n "\$cwd" ] && [ "\$*" = "-a -p \$pid -d cwd -Fn" ]; then
		printf 'p%s\nfcwd\nn%s\n' "\$pid" "\$cwd"
	fi
done < "\$holder_table"
SH
	chmod +x "$fake_bin/lsof"
	cat > "$fake_bin/ps" <<SH
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> "\${TEST_STACK_RUN_DIR:?}/ps_calls.log"
holder_table="\${TEST_STACK_RUN_DIR:?}/web_port_holders.txt"
while IFS='|' read -r pid cwd command_line; do
	if [ "\$*" = "-p \$pid -o command=" ]; then
		printf '%s\n' "\$command_line"
	fi
done < "\$holder_table"
SH
	chmod +x "$fake_bin/ps"
	cat > "$fake_bin/kill" <<SH
#!/usr/bin/env bash
set -euo pipefail
holder_table="\${TEST_STACK_RUN_DIR:?}/web_port_holders.txt"
while IFS='|' read -r pid cwd command_line; do
	if [ "\${1:-}" = "\$pid" ]; then
		printf '%s\n' "\$*" >> "\${TEST_STACK_RUN_DIR:?}/kill_calls.log"
		touch "\${TEST_STACK_RUN_DIR:?}/killed_pid.\$pid"
		exit 0
	fi
done < "\$holder_table"
exec /bin/kill "\$@"
SH
	chmod +x "$fake_bin/kill"
	cat > "$temp_dir/bash_env_disable_kill_builtin.sh" <<'SH'
enable -n kill
SH
}

run_playwright_stack_harness_with_web_args() {
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
		PLAYWRIGHT_WEB_PORT= \
		BASH_ENV="$temp_dir/bash_env_disable_kill_builtin.sh" \
		bash "$temp_dir/scripts/playwright_local_stack.sh" "$@"
}
test_playwright_stack_reclaims_owned_vite_listener_on_invoked_web_port() {
	local temp_dir fake_bin output kill_calls web_args exit_code=0 web_port=6123 stale_pid=4321
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_STACK_RUN_DIR:?}/web_args.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"
	web_args="$(cat "$temp_dir/web_args.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed after reclaiming an owned stale web listener"
	assert_eq "$kill_calls" "$stale_pid" \
		"playwright stack should TERM-kill the owned stale vite listener"
	assert_eq "$web_args" "--host localhost --port $web_port --strictPort" \
		"playwright stack should start web after reclaiming the invoked port"
}

test_playwright_stack_reclaims_owned_npm_web_listener_on_invoked_web_port() {
	local temp_dir fake_bin output kill_calls web_args exit_code=0 web_port=6126 stale_pid=4324
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"npm run dev -- --host localhost --port $web_port --strictPort" \
		"$temp_dir/web"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_STACK_RUN_DIR:?}/web_args.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"
	web_args="$(cat "$temp_dir/web_args.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed after reclaiming an owned stale npm web listener"
	assert_eq "$kill_calls" "$stale_pid" \
		"playwright stack should TERM-kill the owned stale npm web listener"
	assert_eq "$web_args" "--host localhost --port $web_port --strictPort" \
		"playwright stack should start web after reclaiming the owned npm holder"
}

test_playwright_stack_reclaims_owned_npm_web_listener_on_equals_invoked_web_port() {
	local temp_dir fake_bin output kill_calls web_args exit_code=0 web_port=6128 stale_pid=4326
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"npm run dev --host localhost --port=$web_port --strictPort" \
		"$temp_dir/web"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_STACK_RUN_DIR:?}/web_args.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port="$web_port" --strictPort 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"
	web_args="$(cat "$temp_dir/web_args.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed after reclaiming an owned npm web listener with --port=<port>"
	assert_eq "$kill_calls" "$stale_pid" \
		"playwright stack should TERM-kill the owned npm web listener with --port=<port>"
	assert_eq "$web_args" "--host localhost --port=$web_port --strictPort" \
		"playwright stack should preserve equals-form web args after reclaiming the owned npm holder"
}

test_playwright_stack_refuses_npm_web_listener_outside_repo_on_invoked_web_port() {
	local temp_dir fake_bin output kill_calls exit_code=0 web_port=6127 stale_pid=4325
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"npm run dev -- --host localhost --port $web_port --strictPort" \
		"/tmp/other-workspace/web"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"playwright stack should reject an npm web holder outside this repo"
	assert_contains "$output" "web port $web_port" \
		"foreign npm web-port holder refusal should name the selected port"
	assert_contains "$output" "pid $stale_pid: npm run dev -- --host localhost --port $web_port --strictPort" \
		"foreign npm web-port holder refusal should name the offending pid and command"
	assert_eq "$kill_calls" "" \
		"playwright stack should not kill an npm web holder outside this repo"
}

test_playwright_stack_refuses_prefix_lookalike_npm_web_holder() {
	local temp_dir fake_bin output kill_calls exit_code=0 web_port=6129 stale_pid=4327
	local holder_command
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	holder_command="npm run developer --host localhost --port $web_port --strictPort"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" "$holder_command" "$temp_dir/web"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"playwright stack should reject an npm script whose name merely starts with dev"
	assert_contains "$output" "pid $stale_pid: $holder_command" \
		"prefix-lookalike npm refusal should name the offending pid and command"
	assert_eq "$kill_calls" "" \
		"playwright stack should not kill an npm script whose name merely starts with dev"
}

test_playwright_stack_refuses_prefix_lookalike_vite_web_holder() {
	local temp_dir fake_bin output kill_calls exit_code=0 web_port=6130 stale_pid=4328
	local holder_command
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	holder_command="$temp_dir/web/node_modules/.bin/vite-helper --port $web_port"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" "$holder_command"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a repo-local executable that merely starts with vite"
	assert_contains "$output" "pid $stale_pid: $holder_command" \
		"prefix-lookalike vite refusal should name the offending pid and command"
	assert_eq "$kill_calls" "" \
		"playwright stack should not kill a repo-local executable that merely starts with vite"
}

# Ownership is a property of the whole listener set: one foreign holder must
# refuse the reclaim without killing anything, whichever order lsof reports.
# `first_holder_role` selects which of the two holders lsof lists first.
assert_mixed_web_holder_set_refuses_without_killing() {
	local web_port="$1" owned_pid="$2" foreign_pid="$3" first_holder_role="$4"
	local temp_dir fake_bin output kill_calls exit_code=0 owned_spec foreign_spec
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	owned_spec="$owned_pid||$temp_dir/web/node_modules/.bin/vite --port $web_port"
	foreign_spec="$foreign_pid||/usr/bin/python3 -m http.server $web_port"
	if [ "$first_holder_role" = "owned" ]; then
		write_stack_harness_web_port_multi_holder_stubs \
			"$fake_bin" "$web_port" "$owned_spec" "$foreign_spec"
	else
		write_stack_harness_web_port_multi_holder_stubs \
			"$fake_bin" "$web_port" "$foreign_spec" "$owned_spec"
	fi
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"mixed web holders ($first_holder_role first) should refuse the reclaim"
	assert_contains "$output" "pid $foreign_pid: /usr/bin/python3 -m http.server $web_port" \
		"mixed web holders ($first_holder_role first) refusal should name the foreign holder"
	assert_eq "$kill_calls" "" \
		"mixed web holders ($first_holder_role first) must not kill owned pid $owned_pid"
}

test_playwright_stack_refuses_mixed_web_holders_with_owned_pid_listed_first() {
	assert_mixed_web_holder_set_refuses_without_killing 6131 4329 4330 owned
}

test_playwright_stack_refuses_mixed_web_holders_with_foreign_pid_listed_first() {
	assert_mixed_web_holder_set_refuses_without_killing 6132 4331 4332 foreign
}

test_playwright_stack_refuses_foreign_listener_on_invoked_web_port() {
	local temp_dir fake_bin output kill_calls exit_code=0 web_port=6124 stale_pid=4322
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"/usr/bin/python3 -m http.server $web_port"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a foreign process on the web port"
	assert_contains "$output" "web port $web_port" \
		"foreign web-port holder refusal should name the selected port"
	assert_contains "$output" "pid $stale_pid: /usr/bin/python3 -m http.server $web_port" \
		"foreign web-port holder refusal should name the offending pid and command"
	assert_eq "$kill_calls" "" \
		"playwright stack should not kill a foreign web-port holder"
}

test_playwright_stack_reclaims_web_port_from_env_owned_value() {
	local temp_dir fake_bin output lsof_calls kill_calls exit_code=0 web_port=6234 stale_pid=4323
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			BASH_ENV="$temp_dir/bash_env_disable_kill_builtin.sh" \
			PLAYWRIGHT_WEB_PORT="$web_port" 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	lsof_calls="$(cat "$temp_dir/lsof_calls.log" 2>/dev/null || true)"
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed after reclaiming the env-owned web port"
	assert_contains "$lsof_calls" "-tiTCP:$web_port -sTCP:LISTEN" \
		"playwright stack should probe the PLAYWRIGHT_WEB_PORT-owned port"
	assert_eq "$kill_calls" "$stale_pid" \
		"playwright stack should reclaim the listener on the env-owned web port"
}

# With neither a --port argument nor PLAYWRIGHT_WEB_PORT, the stack must derive
# the same port web/playwright.config.ts derives — the TypeScript resolver is the
# oracle here so a changed derivation cannot leave the reclaim on a stale port.
test_playwright_stack_reclaims_typescript_contract_derived_web_port() {
	local temp_dir fake_bin output lsof_calls kill_calls exit_code=0
	local typescript_plan web_port stale_pid=4333
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	typescript_plan="$(typescript_port_plan_for_workspace "$temp_dir/web" "$temp_dir")"
	web_port="$(manual_port_plan_value "$typescript_plan" WEB_PORT)"
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	lsof_calls="$(cat "$temp_dir/lsof_calls.log" 2>/dev/null || true)"
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed after reclaiming the contract-derived web port"
	assert_contains "$lsof_calls" "-tiTCP:$web_port -sTCP:LISTEN" \
		"playwright stack should probe the web port resolveDefaultPlaywrightWebPort derives for web/"
	assert_eq "$kill_calls" "$stale_pid" \
		"playwright stack should reclaim the listener on the contract-derived web port"
}

test_playwright_stack_hands_derived_web_port_to_manual_web_start() {
	local temp_dir fake_bin output kill_calls web_args exit_code=0
	local typescript_plan web_port stale_pid=4336
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	typescript_plan="$(typescript_port_plan_for_workspace "$temp_dir/web" "$temp_dir")"
	web_port="$(manual_port_plan_value "$typescript_plan" WEB_PORT)"
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${TEST_STACK_RUN_DIR:?}/web_args.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	kill_calls="$(cat "$temp_dir/kill_calls.log" 2>/dev/null || true)"
	web_args="$(cat "$temp_dir/web_args.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"manual playwright stack start should proceed after reclaiming the derived web port"
	assert_eq "$kill_calls" "$stale_pid" \
		"manual playwright stack start should reclaim the stale holder on the derived web port"
	assert_eq "$web_args" "--port $web_port" \
		"manual playwright stack start should bind web-dev.sh to the reclaimed derived web port"
}

test_playwright_stack_waits_for_web_port_release_before_starting_web() {
	local temp_dir fake_bin output holders_at_web_start exit_code=0
	local web_port=6133 stale_pid=4334
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	set_stack_harness_web_port_release_delay 2
	cat > "$temp_dir/scripts/web-dev.sh" <<SH
#!/usr/bin/env bash
# Stands in for --strictPort vite: record who still holds the port at bind time.
lsof -tiTCP:$web_port -sTCP:LISTEN > "\${TEST_STACK_RUN_DIR:?}/web_start_holders.log" 2>&1 || true
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2
	holders_at_web_start="$(cat "$temp_dir/web_start_holders.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "0" \
		"playwright stack should proceed once the reclaimed web port is released"
	assert_eq "$holders_at_web_start" "" \
		"playwright stack should wait for the TERMed holder to release the web port before starting web"
}

test_playwright_stack_fails_closed_when_reclaimed_web_port_is_never_released() {
	local temp_dir fake_bin output web_started exit_code=0
	local web_port=6134 stale_pid=4335
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready" "$temp_dir/flapjack_ready"
	write_stack_harness_web_port_holder_stubs \
		"$fake_bin" "$web_port" "$stale_pid" \
		"$temp_dir/web/node_modules/.bin/vite --host localhost --port $web_port --strictPort"
	set_stack_harness_web_port_release_delay never
	cat > "$temp_dir/scripts/web-dev.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "web_started" > "${TEST_STACK_RUN_DIR:?}/web_started.log"
SH
	chmod +x "$temp_dir/scripts/web-dev.sh"

	output="$(
		PLAYWRIGHT_WEB_PORT_RELEASE_TIMEOUT_SECONDS=1 \
			run_playwright_stack_harness_with_web_args "$fake_bin:$PATH" \
			--host localhost --port "$web_port" --strictPort 2>&1
	)" || exit_code=$?
	web_started="$(cat "$temp_dir/web_started.log" 2>/dev/null || true)"

	assert_eq "$exit_code" "1" \
		"playwright stack should fail closed when the reclaimed web port stays held"
	assert_contains "$output" "web port $web_port" \
		"unreleased web-port failure should name the port"
	assert_contains "$output" "pid $stale_pid" \
		"unreleased web-port failure should name the holder it TERMed"
	assert_eq "$web_started" "" \
		"playwright stack should not start web on a still-held strict port"
}

test_playwright_stack_rejects_out_of_range_env_web_port() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	write_stack_harness_curl "$fake_bin/curl"
	touch "$temp_dir/api_ready"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_WEB_PORT="80" 2>&1
	)" || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject a web port outside the contract's 1024-65535 range"
	assert_contains "$output" "1024" \
		"out-of-range web-port refusal should name the contract's lower bound"
}

test_playwright_stack_rejects_invalid_web_port_release_timeout() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	output="$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_WEB_PORT_RELEASE_TIMEOUT_SECONDS="invalid" 2>&1
	)" || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject an invalid web-port release timeout"
	assert_contains "$output" \
		"PLAYWRIGHT_WEB_PORT_RELEASE_TIMEOUT_SECONDS must be a non-negative integer" \
		"invalid web-port release timeouts should have an actionable diagnostic"
}

test_playwright_stack_reclaims_owned_vite_listener_on_invoked_web_port

test_playwright_stack_reclaims_owned_npm_web_listener_on_invoked_web_port

test_playwright_stack_reclaims_owned_npm_web_listener_on_equals_invoked_web_port

test_playwright_stack_refuses_npm_web_listener_outside_repo_on_invoked_web_port

test_playwright_stack_refuses_prefix_lookalike_npm_web_holder

test_playwright_stack_refuses_prefix_lookalike_vite_web_holder

test_playwright_stack_refuses_mixed_web_holders_with_owned_pid_listed_first

test_playwright_stack_refuses_mixed_web_holders_with_foreign_pid_listed_first

test_playwright_stack_refuses_foreign_listener_on_invoked_web_port

test_playwright_stack_reclaims_web_port_from_env_owned_value

test_playwright_stack_reclaims_typescript_contract_derived_web_port

test_playwright_stack_hands_derived_web_port_to_manual_web_start

test_playwright_stack_waits_for_web_port_release_before_starting_web

test_playwright_stack_fails_closed_when_reclaimed_web_port_is_never_released

test_playwright_stack_rejects_out_of_range_env_web_port

test_playwright_stack_rejects_invalid_web_port_release_timeout



run_test_summary
