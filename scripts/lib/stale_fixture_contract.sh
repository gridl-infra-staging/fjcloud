#!/usr/bin/env bash
# Source-only stale fixture contract shared by Playwright fixtures and local DB cleanup.
#
# These prefixes are the fixture-owned index/tenant names that may be cleaned
# after a failed local E2E run. Do not add proof/log prefixes here unless their
# owners also opt into automated stale cleanup.

STALE_FIXTURE_INDEX_PREFIXES=(
    "e2e-"
    "dash-"
    "onboard-"
)

PURGE_DEV_TENANT_TARGETS=(
    "e2e-retro-old"
    "dash-retro-old"
    "smoke-retro-old"
    "searchauthidx-retro-old"
    "lifecycidx-retro-old"
    "idxfilterretro"
    "stage5retro"
    "idxdetail-retro-old"
)

stale_fixture_prefix_sql_values() {
    local prefix
    for prefix in "${STALE_FIXTURE_INDEX_PREFIXES[@]}"; do
        printf "('%s')\n" "${prefix//\'/\'\'}"
    done
}

purge_dev_tenant_target_sql_values() {
    local tenant_id
    for tenant_id in "${PURGE_DEV_TENANT_TARGETS[@]}"; do
        printf "('%s')\n" "${tenant_id//\'/\'\'}"
    done
}
