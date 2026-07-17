#!/usr/bin/env bash
# Contract test for algolia_invalid_credentials_contract.sh helper ownership.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONTRACT_SCRIPT="$SCRIPT_DIR/algolia_invalid_credentials_contract.sh"

# shellcheck disable=SC1091
# shellcheck source=../../tests/lib/test_runner.sh
source "$REPO_ROOT/scripts/tests/lib/test_runner.sh"
# shellcheck disable=SC1091
# shellcheck source=../../tests/lib/assertions.sh
source "$REPO_ROOT/scripts/tests/lib/assertions.sh"

test_self_test_still_exercises_shared_helpers() {
	local output
	output="$(bash "$CONTRACT_SCRIPT" --self-test 2>&1)"
	assert_contains "$output" "self-test PASS: algolia invalid-credentials contract helpers" "self-test should keep helper coverage"
}

test_live_modes_are_retired_without_curling() {
	local stub_dir output exit_code
	stub_dir="$(mktemp -d)"
	cat > "$stub_dir/curl" <<'CURL_STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "unexpected curl invocation: $*" >&2
exit 43
CURL_STUB
	chmod +x "$stub_dir/curl"

	set +e
	output="$(PATH="$stub_dir:$PATH" bash "$CONTRACT_SCRIPT" staging 2>&1)"
	exit_code=$?
	set -e

	rm -rf "$stub_dir"

	assert_eq "$exit_code" "2" "retired live mode should fail with a distinct status"
	assert_contains "$output" "live Algolia invalid-credentials migration contract is retired" "retired live mode explains replacement"
	assert_contains "$output" "scripts/algolia_migration_safety_probe.sh" "retired live mode points to safety probe"
	assert_not_contains "$output" "unexpected curl invocation" "retired live mode should not call curl"
}

test_source_safe_for_shared_helper_reuse() {
	local output
	output="$(bash -c ". scripts/canary/contracts/algolia_invalid_credentials_contract.sh; api_origin_for staging; printf '\\n'; web_origin_for prod" 2>&1)"
	assert_eq "$output" "https://api.staging.flapjack.foo
https://cloud.flapjack.foo" "contract script should be source-safe and expose origin helpers"
}

assert_file_exists "$CONTRACT_SCRIPT" "contract script should exist"
test_self_test_still_exercises_shared_helpers
test_live_modes_are_retired_without_curling
test_source_safe_for_shared_helper_reuse
run_test_summary
