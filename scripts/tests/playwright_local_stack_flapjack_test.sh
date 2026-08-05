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

test_flapjack_bootstrap_initializes_experiment_storage() {
	local script_text
	script_text="$(cat "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" "ensure_flapjack_experiments_api_ready" \
		"playwright stack should define an experiments storage bootstrap seam"
	assert_contains "$script_text" 'wait_for_health "$FLAPJACK_HEALTH_URL" "playwright flapjack"' \
		"playwright stack should wait for Flapjack health before bootstrapping system indexes"
	assert_contains "$script_text" 'ensure_flapjack_experiments_api_ready' \
		"playwright stack should invoke the experiments bootstrap before starting the API"
	assert_contains "$script_text" 'reconcile_playwright_bootstrap_admin_user' \
		"playwright stack should define a local bootstrap-admin credential reconciliation seam"
	assert_contains "$script_text" 'reconcile_playwright_bootstrap_admin_user
	if [ "$REQUIRE_EMAIL_VERIFICATION" = "1" ]; then' \
		"playwright stack should reconcile persisted bootstrap admin credentials after migrations and before API launch"
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
	harness_text="$(cat "$REPO_ROOT/scripts/tests/lib/playwright_local_stack_harness.sh")"
	logic_text="$(grep -v 'run: cargo build -p flapjack-server' "$REPO_ROOT/scripts/playwright_local_stack.sh")"

	assert_contains "$script_text" 'FLAPJACK_PORT="$(parse_port_from_http_url "$FLAPJACK_URL")"' \
			"playwright stack should derive the Flapjack port before choosing a data directory"
	assert_contains "$script_text" 'FLAPJACK_URL must be a loopback HTTP URL' \
			"playwright stack should reject remote Flapjack URLs before sending admin-keyed requests"
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
api_public_infrastructure_is_ready() { return 0; }
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

test_playwright_stack_hands_selected_private_identity_to_api() {
	local temp_dir fake_bin output exit_code=0 binary_sha expected_revision expected_build_id
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	expected_revision="fixture-revision-private-api"
	expected_build_id="fixture-workspace-digest-private-api"
	binary_sha="$(write_stack_harness_selected_identity_fixture \
		"$temp_dir" "$expected_revision" "$expected_build_id")"
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"

	output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="1" 2>&1
	) || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2

	assert_file_exists "$temp_dir/api_launch_reached" \
		"playwright stack should reach the fake API launcher for selected-binary private identity"
	assert_eq "$(grep '^FJCLOUD_FLAPJACK_REQUIRED_REVISION=' "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"FJCLOUD_FLAPJACK_REQUIRED_REVISION=$expected_revision" \
		"selected binary private revision should be inherited by api-dev"
	assert_eq "$(grep '^FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=' "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID=$expected_build_id" \
		"selected binary private build/workspace digest should be inherited by api-dev"
	assert_eq "$(grep '^FJCLOUD_FLAPJACK_REQUIRED_SHA256=' "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"FJCLOUD_FLAPJACK_REQUIRED_SHA256=$binary_sha" \
		"selected binary artifact SHA should be inherited by api-dev"
	assert_eq "$exit_code" "0" \
		"playwright stack should launch API with complete selected-binary private identity"
}

test_playwright_stack_reconciles_bootstrap_admin_before_api_launch() {
	local temp_dir fake_bin output exit_code=0 real_python3
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN
	real_python3="$(command -v python3)"
	cat > "$fake_bin/python3" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\${TEST_STACK_RUN_DIR:?}/python_args.log"
exec "$real_python3" "\$@"
SH
	chmod +x "$fake_bin/python3"

	write_stack_harness_selected_identity_fixture \
		"$temp_dir" "fixture-revision-bootstrap-admin" "fixture-digest-bootstrap-admin" > /dev/null
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2

	assert_eq "$exit_code" "0" \
		"playwright stack should still launch after reconciling bootstrap admin credentials"
	assert_file_exists "$temp_dir/psql_args.log" \
		"playwright stack should invoke psql for bootstrap-admin credential reconciliation"
	assert_not_contains "$(cat "$temp_dir/psql_args.log")" "postgresql://playwright:secret@127.0.0.1:5432/fjcloud" \
		"bootstrap-admin reconciliation should not expose DATABASE_URL through psql process arguments"
	assert_eq "$(cat "$temp_dir/psql_env.log")" \
		$'PGHOST=127.0.0.1\nPGPORT=5432\nPGUSER=playwright\nPGDATABASE=fjcloud' \
		"bootstrap-admin reconciliation should map DATABASE_URL to libpq connection fields"
	assert_contains "$(cat "$temp_dir/psql_args.log")" "-v credential_prefix=playwright-local" \
		"bootstrap-admin reconciliation should pass the ADMIN_KEY prefix to psql"
	assert_contains "$(cat "$temp_dir/psql_args.log")" "-v credential_sha256=21e050d9388d3961c2100630603c3fa6cec03546f0c0a56f3dfa4476a7ef1150" \
		"bootstrap-admin reconciliation should pass the ADMIN_KEY SHA-256 to psql"
	assert_not_contains "$(cat "$temp_dir/python_args.log")" "playwright-local-admin-test-key" \
		"bootstrap-admin reconciliation should not expose ADMIN_KEY through Python process arguments"
	assert_contains "$(cat "$temp_dir/psql_stdin.sql")" "WHERE identifier = 'bootstrap-admin-key'" \
		"bootstrap-admin reconciliation should target the bootstrap-admin row"
	assert_contains "$(cat "$temp_dir/psql_stdin.sql")" "AND (SELECT COUNT(*) FROM admin_users) = 1" \
		"bootstrap-admin reconciliation should only rewrite single-user local admin tables"
	assert_contains "$(cat "$temp_dir/psql_stdin.sql")" "RETURNING identifier" \
		"bootstrap-admin reconciliation should report which row it updated so a no-op cannot pass silently"
}

# Rows exist but none was rewritten — an extra admin row, or a row another stack
# repointed at its own key. The API does not re-bootstrap a non-empty admin_users table,
# so it would boot holding a credential the database does not have and 401 every
# admin-authenticated request. That surfaces only as mass browser-test failures far from
# the cause (it cost one run 37 of its 50 failures), so the stack must refuse to launch.
test_playwright_stack_fails_when_bootstrap_admin_row_is_not_reconciled() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	write_stack_harness_selected_identity_fixture \
		"$temp_dir" "fixture-revision-unreconciled-admin" "fixture-digest-unreconciled-admin" > /dev/null
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" \
		TEST_STACK_ADMIN_RECONCILE_STATE=unreconciled 2>&1)" || exit_code=$?

	assert_ne "$exit_code" "0" \
		"playwright stack should refuse to launch when the bootstrap-admin row was not reconciled"
	assert_contains "$output" "bootstrap-admin" \
		"unreconciled bootstrap-admin failure should name the row it could not update"
	assert_contains "$output" "ADMIN_KEY" \
		"unreconciled bootstrap-admin failure should name the credential that would have been rejected"
	assert_eq "$([ -e "$temp_dir/api_env.log" ] && printf 'started' || printf 'not-started')" \
		"not-started" \
		"playwright stack should not start the API after a failed bootstrap-admin reconciliation"
}

# An empty admin_users table is the legitimate no-op: there is no row to rewrite yet, and
# api-dev's bootstrap_admin_user_if_empty (infra/api/src/auth/admin.rs) inserts one from
# the same ADMIN_KEY at startup. Treating this like the unreconciled case would break
# every first run against a freshly migrated database.
test_playwright_stack_launches_when_admin_table_is_empty_for_api_bootstrap() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	write_stack_harness_selected_identity_fixture \
		"$temp_dir" "fixture-revision-empty-admin" "fixture-digest-empty-admin" > /dev/null
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" \
		TEST_STACK_ADMIN_RECONCILE_STATE=empty-api-will-bootstrap 2>&1)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2

	assert_eq "$exit_code" "0" \
		"playwright stack should launch against an empty admin_users table so the API can bootstrap it"
	assert_eq "$([ -e "$temp_dir/api_env.log" ] && printf 'started' || printf 'not-started')" \
		"started" \
		"playwright stack should start the API so bootstrap_admin_user_if_empty can seed the admin row"
}

test_playwright_stack_rejects_incomplete_selected_private_identity_before_api() {
	local temp_dir fake_bin output exit_code=0 receipt_path
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	write_stack_harness_selected_identity_fixture \
		"$temp_dir" "fixture-revision-missing-build" "fixture-digest-missing-build" > /dev/null
	receipt_path="$temp_dir/receipts/source.receipt"
	grep -v '^source_digest=' "$receipt_path" > "$receipt_path.tmp"
	mv "$receipt_path.tmp" "$receipt_path"
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"

	output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="stale-shell-build-id" \
			PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="1" 2>&1
	) || exit_code=$?

	assert_eq "$exit_code" "1" \
		"playwright stack should reject incomplete selected-binary private identity"
	assert_contains "$output" "incomplete selected Flapjack runtime identity: FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID" \
		"incomplete selected-binary private identity diagnostic should name the missing build variable"
	if [ -f "$temp_dir/api_launch_reached" ]; then
		fail "playwright stack must reject incomplete selected-binary private identity before API launch"
	else
		pass "playwright stack must reject incomplete selected-binary private identity before API launch"
	fi
}

test_playwright_stack_compares_preexisting_public_health_with_artifact_identity_only() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	write_stack_harness_selected_identity_fixture \
		"$temp_dir" "fixture-revision-preexisting" "fixture-digest-preexisting" > /dev/null
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
	touch "$temp_dir/flapjack_ready" "$temp_dir/flapjack_public_health_only" "$temp_dir/api_ready"

	output="$(run_playwright_stack_harness "$fake_bin:$PATH" 2>&1)" || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2

	assert_eq "$exit_code" "0" \
		"pre-existing Flapjack public health should pass the real identity classifier"
	assert_not_contains "$output" "identity rejected" \
		"artifact-only requirements must not make the public health projection fail identity"
	[ ! -f "$temp_dir/flapjack_child.pid" ] || \
		fail "launcher must not start Flapjack when a pre-existing runtime is already healthy"
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

	cat > "$temp_dir/scripts/lib/health.sh" <<'SH'
wait_for_health() { return 0; }
SH
	write_stack_harness_unselected_binary_fixture "$temp_dir"
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

# The complement of the rejection above: with no selected local binary the
# launcher owns no runtime identity of its own, so it must hand the operator's
# exported identity through to api-dev untouched rather than re-deriving or
# rejecting it.
test_playwright_stack_hands_operator_supplied_identity_to_api_without_selected_binary() {
	local temp_dir fake_bin output exit_code=0
	prepare_playwright_stack_harness
	trap 'rm -rf "'"$temp_dir"'"' RETURN

	write_stack_harness_unselected_binary_fixture "$temp_dir"
	write_stack_harness_expected_identity_env "$temp_dir" \
		"operator-revision" "operator-build-id" "operator-sha256"
	write_stack_harness_curl "$fake_bin/curl"
	write_exit_zero_stub "$temp_dir/scripts/local-dev-migrate.sh"
	write_exit_zero_stub "$temp_dir/scripts/web-dev.sh"
	write_stack_harness_identity_asserting_api "$temp_dir/scripts/api-dev.sh"
	touch "$temp_dir/flapjack_ready"

	output=$(
		run_playwright_stack_harness "$fake_bin:$PATH" \
			FJCLOUD_FLAPJACK_REQUIRED_REVISION="operator-revision" \
			FJCLOUD_FLAPJACK_REQUIRED_BUILD_ID="operator-build-id" \
			FJCLOUD_FLAPJACK_REQUIRED_SHA256="operator-sha256" \
			PLAYWRIGHT_API_READY_TIMEOUT_SECONDS="1" 2>&1
	) || exit_code=$?
	[ "$exit_code" -eq 0 ] || printf '%s\n' "$output" >&2

	assert_eq "$exit_code" "0" \
		"playwright stack should accept operator-supplied identity when no local binary is selected"
	assert_file_exists "$temp_dir/api_launch_reached" \
		"playwright stack should still reach the API launcher without a selected local binary"
	assert_eq "$(grep '^FJCLOUD_FLAPJACK_REQUIRED_REVISION=' "$temp_dir/api_env.log" 2>/dev/null || true)" \
		"FJCLOUD_FLAPJACK_REQUIRED_REVISION=operator-revision" \
		"operator-supplied revision must reach api-dev unrewritten"
}


test_flapjack_bootstrap_initializes_experiment_storage

test_playwright_stack_static_contracts

test_playwright_stack_surfaces_helper_source_provenance

test_playwright_stack_hands_selected_private_identity_to_api

test_playwright_stack_reconciles_bootstrap_admin_before_api_launch

test_playwright_stack_fails_when_bootstrap_admin_row_is_not_reconciled

test_playwright_stack_launches_when_admin_table_is_empty_for_api_bootstrap

test_playwright_stack_rejects_incomplete_selected_private_identity_before_api

test_playwright_stack_compares_preexisting_public_health_with_artifact_identity_only

test_playwright_stack_rejects_healthy_runtime_when_source_resolution_fails

test_playwright_stack_rejects_healthy_runtime_without_exact_identity_evidence

test_playwright_stack_hands_operator_supplied_identity_to_api_without_selected_binary



run_test_summary
