#!/usr/bin/env bash
# Canonical local seed data contract shared by seed and audit scripts.
#
# This file is source-only: it defines stable values and tuple builders, and
# must not touch API, Flapjack, Docker, or Postgres when loaded.

LOCAL_SEED_SHARED_USER_NAME="Test Developer"
LOCAL_SEED_SHARED_USER_EMAIL="dev@example.com"
LOCAL_SEED_SHARED_USER_PASSWORD="localdev-password-1234"
LOCAL_SEED_FREE_USER_NAME="Free Plan User"
LOCAL_SEED_FREE_USER_EMAIL="free@example.com"
LOCAL_SEED_FREE_USER_PASSWORD="localdev-password-1234"

LOCAL_SEED_PRIMARY_INDEX_NAME="test-index"
LOCAL_SEED_PRIMARY_INDEX_REGION="us-east-1"
LOCAL_SEED_SHARED_EXPECTED_TENANTS="3"
LOCAL_SEED_FREE_EXPECTED_TENANTS="1"
LOCAL_SEED_TENANT_WIGGLE="50"
LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE="e2e-seed-%"
LOCAL_SEED_SYNTHETIC_VM_ACTIVE_LIMIT="0"
LOCAL_SEED_VM_CAPACITY_JSON='{"cpu_weight":4.0,"mem_rss_bytes":8589934592,"disk_bytes":107374182400,"query_rps":500.0,"indexing_rps":200.0}'
LOCAL_SEED_VM_CURRENT_LOAD_JSON='{"cpu_weight":0.0,"mem_rss_bytes":0,"disk_bytes":0,"query_rps":0.0,"indexing_rps":0.0}'

local_seed_index_targets() {
    local primary_index_name="$1"
    local primary_index_region="$2"

    printf '%s\n' \
        "shared|${primary_index_name}|${primary_index_region}" \
        "shared|test-index-eu|eu-west-1" \
        "shared|test-index-eu2|eu-central-1" \
        "free|free-test-index|us-east-1"
}

local_seed_replica_targets() {
    local primary_index_name="$1"
    local primary_index_region="$2"

    printf '%s\n' \
        "shared|${primary_index_name}|${primary_index_region}|eu-west-1" \
        "shared|test-index-eu|eu-west-1|us-east-1" \
        "shared|test-index-eu2|eu-central-1|us-east-1"
}
