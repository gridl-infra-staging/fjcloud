#!/usr/bin/env bash
# Audit local development state after canonical seed data is applied.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/local_seed_contract.sh
source "$SCRIPT_DIR/lib/local_seed_contract.sh"
# shellcheck source=lib/stale_fixture_contract.sh
source "$SCRIPT_DIR/lib/stale_fixture_contract.sh"
# shellcheck source=lib/local_db_access.sh
source "$SCRIPT_DIR/lib/local_db_access.sh"

log() { echo "[dev-state-audit] $*"; }
die() { echo "[dev-state-audit] ERROR: $*" >&2; exit 1; }

load_env_file "$REPO_ROOT/.env.local"

remediation_message() {
    if [ -f "$SCRIPT_DIR/cleanup_dev_orphans.sh" ]; then
        printf '%s' "Remove stale local fixture rows with: bash scripts/cleanup_dev_orphans.sh --apply; "
    fi
    printf '%s' "if broader reset is needed: scripts/local-dev-down.sh --clean && scripts/local_demo.sh"
    printf '\n'
}

audit_stale_fixture_prefix_sql_values_csv() {
    stale_fixture_prefix_sql_values | paste -sd, -
}

audit_seed_state_rows() {
    local stale_prefix_values
    stale_prefix_values="$(audit_stale_fixture_prefix_sql_values_csv)"

    run_local_psql -v ON_ERROR_STOP=1 -tA -F '|' \
        -v shared_email="$LOCAL_SEED_SHARED_USER_EMAIL" \
        -v free_email="$LOCAL_SEED_FREE_USER_EMAIL" \
        -v synthetic_vm_hostname_like="$LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE" <<SQL
-- source scripts/lib/stale_fixture_contract.sh
WITH seed_customers(email) AS (
    VALUES (:'shared_email'), (:'free_email')
),
stale_prefixes(prefix) AS (
    VALUES ${stale_prefix_values}
),
tenant_counts AS (
    SELECT
        seed_customers.email,
        COUNT(customer_tenants.tenant_id)::bigint AS tenant_count
    FROM seed_customers
    LEFT JOIN customers
      ON customers.email = seed_customers.email
     AND customers.status = 'active'
    LEFT JOIN customer_tenants
      ON customer_tenants.customer_id = customers.id
     AND customer_tenants.tier = 'active'
    GROUP BY seed_customers.email
),
synthetic_vm_active AS (
    SELECT COUNT(*)::bigint AS active_count
    FROM vm_inventory
    WHERE hostname LIKE :'synthetic_vm_hostname_like'
      AND status = 'active'
),
stale_fixture_tenants AS (
    SELECT COUNT(*)::bigint AS stale_count
    FROM customer_tenants ct
    WHERE EXISTS (
        SELECT 1
        FROM stale_prefixes prefix_owner
        WHERE ct.tenant_id LIKE prefix || '%'
    )
)
SELECT email, tenant_count FROM tenant_counts
UNION ALL
SELECT '__synthetic_vm_active__', active_count FROM synthetic_vm_active
UNION ALL
SELECT '__stale_fixture_tenants__', stale_count FROM stale_fixture_tenants
ORDER BY 1;
SQL
}

assert_count_within_limit() {
    local label="$1"
    local actual="$2"
    local limit="$3"

    if [ "$actual" -le "$limit" ]; then
        log "${label}: ${actual} <= ${limit}"
        return 0
    fi

    log "${label}: ${actual} > ${limit}"
    return 1
}

sql_like_to_shell_glob() {
    local sql_like="$1"

    printf '%s' "${sql_like//%/*}"
}

main() {
    if ! require_local_database_access "local dev state audit"; then
        die "Local database access unavailable; $(remediation_message)"
    fi

    local shared_limit free_limit vm_limit
    local shared_count="" free_count="" synthetic_vm_active_count="" stale_fixture_tenant_count=""
    shared_limit=$((LOCAL_SEED_SHARED_EXPECTED_TENANTS + LOCAL_SEED_TENANT_WIGGLE))
    free_limit=$((LOCAL_SEED_FREE_EXPECTED_TENANTS + LOCAL_SEED_TENANT_WIGGLE))
    vm_limit="$LOCAL_SEED_SYNTHETIC_VM_ACTIVE_LIMIT"

    local rows row key value
    local vm_rows_seen=0 tenant_count_rows_seen=0
    local synthetic_vm_active_count_from_rows=0
    local synthetic_vm_hostname_glob
    synthetic_vm_hostname_glob="$(sql_like_to_shell_glob "$LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE")"
    rows="$(audit_seed_state_rows)"
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        key="${row%%|*}"
        value="${row#*|}"
        case "$key" in
            vm)
                vm_rows_seen=1
                IFS='|' read -r _vm_kind _vm_id vm_hostname _vm_kind_name _vm_region _vm_endpoint vm_status _vm_rest <<< "$row"
                if [[ "$vm_hostname" == $synthetic_vm_hostname_glob && "$vm_status" == "active" ]]; then
                    synthetic_vm_active_count_from_rows=$((synthetic_vm_active_count_from_rows + 1))
                fi
                ;;
            tenant_ref_count)
                # Row-level VM inventory output may include this as supporting
                # evidence. Tenant count validation remains owned by the
                # aggregate rows and seed_local_test.sh.
                ;;
            "$LOCAL_SEED_SHARED_USER_EMAIL")
                shared_count="$value"
                tenant_count_rows_seen=1
                ;;
            "$LOCAL_SEED_FREE_USER_EMAIL")
                free_count="$value"
                tenant_count_rows_seen=1
                ;;
            __synthetic_vm_active__)
                synthetic_vm_active_count="$value"
                ;;
            __stale_fixture_tenants__)
                stale_fixture_tenant_count="$value"
                ;;
        esac
    done <<< "$rows"

    if [ -z "$synthetic_vm_active_count" ] && [ "$vm_rows_seen" -eq 1 ]; then
        synthetic_vm_active_count="$synthetic_vm_active_count_from_rows"
    fi

    if [ "$tenant_count_rows_seen" -eq 1 ]; then
        [ -n "$shared_count" ] || die "Audit query returned no row for ${LOCAL_SEED_SHARED_USER_EMAIL}"
        [ -n "$free_count" ] || die "Audit query returned no row for ${LOCAL_SEED_FREE_USER_EMAIL}"
    fi
    [ -n "$synthetic_vm_active_count" ] || die "Audit query returned no synthetic VM active-row count"
    if [ -z "$stale_fixture_tenant_count" ]; then
        stale_fixture_tenant_count=0
    fi

    local failed=0
    if [ "$tenant_count_rows_seen" -eq 1 ]; then
        assert_count_within_limit "${LOCAL_SEED_SHARED_USER_EMAIL} tenants" "$shared_count" "$shared_limit" || failed=1
        assert_count_within_limit "${LOCAL_SEED_FREE_USER_EMAIL} tenants" "$free_count" "$free_limit" || failed=1
    fi
    assert_count_within_limit "active ${LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE} VM rows" "$synthetic_vm_active_count" "$vm_limit" || failed=1
    assert_count_within_limit "stale fixture tenants" "$stale_fixture_tenant_count" 0 || failed=1

    if [ "$failed" -ne 0 ]; then
        log "$(remediation_message)"
        exit 1
    fi

    log "Local dev state audit passed"
}

main "$@"
