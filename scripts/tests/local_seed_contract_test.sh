#!/usr/bin/env bash
# Tests for scripts/lib/local_seed_contract.sh: canonical local seed values.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=lib/test_runner.sh
source "$SCRIPT_DIR/lib/test_runner.sh"
# shellcheck source=lib/assertions.sh
source "$SCRIPT_DIR/lib/assertions.sh"

test_contract_file_exists_and_is_sourceable() {
    assert_file_exists "$REPO_ROOT/scripts/lib/local_seed_contract.sh" \
        "local seed contract library should exist"

    # shellcheck source=../lib/local_seed_contract.sh
    source "$REPO_ROOT/scripts/lib/local_seed_contract.sh"

    assert_eq "$LOCAL_SEED_SHARED_USER_EMAIL" "dev@example.com" \
        "contract should expose the canonical shared seed email"
    assert_eq "$LOCAL_SEED_FREE_USER_EMAIL" "free@example.com" \
        "contract should expose the canonical free seed email"
    assert_eq "$LOCAL_SEED_SHARED_EXPECTED_TENANTS" "3" \
        "contract should expose the expected shared seed tenant count"
    assert_eq "$LOCAL_SEED_FREE_EXPECTED_TENANTS" "1" \
        "contract should expose the expected free seed tenant count"
    assert_eq "$LOCAL_SEED_TENANT_WIGGLE" "50" \
        "contract should expose the allowed in-flight tenant wiggle"
    assert_eq "$LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE" "e2e-seed-%" \
        "contract should expose the synthetic VM hostname pattern"
    assert_eq "$LOCAL_SEED_SYNTHETIC_VM_ACTIVE_LIMIT" "0" \
        "contract should expose the synthetic VM active-row limit"
    assert_contains "$LOCAL_SEED_VM_CAPACITY_JSON" '"cpu_weight":4.0' \
        "contract should expose the shared-VM capacity JSON used by local seed helpers"
    assert_contains "$LOCAL_SEED_VM_CAPACITY_JSON" '"mem_rss_bytes":8589934592' \
        "contract should expose the shared-VM memory capacity JSON used by local seed helpers"
    assert_contains "$LOCAL_SEED_VM_CURRENT_LOAD_JSON" '"cpu_weight":0.0' \
        "contract should expose the shared-VM current-load JSON used by local seed helpers"
}

test_contract_builds_canonical_target_tuples() {
    # shellcheck source=../lib/local_seed_contract.sh
    source "$REPO_ROOT/scripts/lib/local_seed_contract.sh"

    local index_targets replica_targets
    index_targets="$(local_seed_index_targets "test-index" "us-east-1")"
    replica_targets="$(local_seed_replica_targets "test-index" "us-east-1")"

    assert_contains "$index_targets" "shared|test-index|us-east-1" \
        "contract should include the primary shared seed index target"
    assert_contains "$index_targets" "shared|test-index-eu|eu-west-1" \
        "contract should include the shared eu-west-1 seed index target"
    assert_contains "$index_targets" "shared|test-index-eu2|eu-central-1" \
        "contract should include the shared eu-central-1 seed index target"
    assert_contains "$index_targets" "free|free-test-index|us-east-1" \
        "contract should include the free seed index target"

    assert_contains "$replica_targets" "shared|test-index|us-east-1|eu-west-1" \
        "contract should include the primary shared seed replica target"
    assert_contains "$replica_targets" "shared|test-index-eu|eu-west-1|us-east-1" \
        "contract should include the eu-west-1 shared seed replica target"
    assert_contains "$replica_targets" "shared|test-index-eu2|eu-central-1|us-east-1" \
        "contract should include the eu-central-1 shared seed replica target"
}

test_contract_is_source_only() {
    local output exit_code=0
    output="$(bash -c "source '$REPO_ROOT/scripts/lib/local_seed_contract.sh'" 2>&1)" || exit_code=$?

    assert_eq "$exit_code" "0" "contract library should source without side effects"
    assert_eq "$output" "" "contract library should not print when sourced"
}

test_contract_file_exists_and_is_sourceable
test_contract_builds_canonical_target_tuples
test_contract_is_source_only

run_test_summary
