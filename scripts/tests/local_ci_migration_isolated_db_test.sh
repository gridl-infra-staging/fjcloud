#!/usr/bin/env bash
# Regression test: migration gate must run against a fresh isolated
# database to avoid false failures from stale local migration history.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCAL_CI="$REPO_ROOT/scripts/local-ci.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }

extract_migration_gate_block() {
	awk '
		/^gate_migration_test\(\) \{/ { in_block=1; print; next }
		in_block { print }
		in_block && /^}/ { exit }
	' "$LOCAL_CI"
}

test_migration_gate_uses_isolated_database_url() {
	local gate_block
	gate_block="$(extract_migration_gate_block)"

	if [[ "$gate_block" != *'migration_test_db_name='* ]]; then
		fail "gate_migration_test is missing an isolated migration_test_db_name owner"
		return
	fi

	if [[ "$gate_block" != *'migration_db_url='* ]]; then
		fail "gate_migration_test is missing migration_db_url construction for isolated DB"
		return
	fi

	if [[ "$gate_block" != *'sqlx database create --database-url "$migration_db_url"'* ]]; then
		fail "gate_migration_test does not create the isolated migration database"
		return
	fi

	if [[ "$gate_block" != *'sqlx migrate run --source "$REPO_ROOT/infra/migrations" --database-url "$migration_db_url"'* ]]; then
		fail "gate_migration_test is not running migrations against the isolated migration_db_url"
		return
	fi

	if [[ "$gate_block" != *'sqlx database drop --database-url "$migration_db_url" -y'* ]]; then
		fail "gate_migration_test does not clean up the isolated migration database"
		return
	fi

	pass "gate_migration_test provisions and tears down an isolated migration DB"
}

main() {
	echo "=== local_ci_migration_isolated_db_test ==="
	test_migration_gate_uses_isolated_database_url
	echo
	echo "=== Results: $PASS_COUNT passed, $FAIL_COUNT failed ==="
	if [[ "$FAIL_COUNT" -ne 0 ]]; then
		exit 1
	fi
}

main "$@"
