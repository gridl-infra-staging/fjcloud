#!/usr/bin/env bash
# cleanup_dev_orphans.sh — targeted cleanup for stale local E2E fixture DB rows.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/env.sh
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck source=lib/local_db_access.sh
source "$SCRIPT_DIR/lib/local_db_access.sh"
# shellcheck source=lib/local_seed_contract.sh
source "$SCRIPT_DIR/lib/local_seed_contract.sh"
# shellcheck source=lib/stale_fixture_contract.sh
source "$SCRIPT_DIR/lib/stale_fixture_contract.sh"

log() { echo "[cleanup-dev-orphans] $*"; }
die() { echo "[cleanup-dev-orphans] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: scripts/cleanup_dev_orphans.sh [--apply]

Dry-run is the default. Use --apply to delete only stale fixture-owned local
tenant rows and their exclusive dependents, then verify with:
  bash scripts/dev_state_audit.sh
USAGE
}

sql_values_csv() {
    stale_fixture_prefix_sql_values | paste -sd, -
}

cleanup_dev_orphans_target_sql() {
    local prefix_values
    prefix_values="$(sql_values_csv)"

    cat <<SQL
-- source scripts/lib/stale_fixture_contract.sh
-- source scripts/lib/local_seed_contract.sh
CREATE TEMP TABLE cleanup_stale_prefixes(prefix text PRIMARY KEY) ON COMMIT DROP;
INSERT INTO cleanup_stale_prefixes(prefix)
VALUES ${prefix_values};

CREATE TEMP TABLE cleanup_target_tenants ON COMMIT DROP AS
SELECT
    ct.customer_id,
    ct.tenant_id,
    ct.deployment_id,
    ct.vm_id,
    ct.cold_snapshot_id
FROM customer_tenants ct
WHERE EXISTS (
    SELECT 1
    FROM cleanup_stale_prefixes prefix_owner
    WHERE ct.tenant_id LIKE prefix || '%'
);

CREATE TEMP TABLE cleanup_target_vms ON COMMIT DROP AS
SELECT id, hostname
FROM vm_inventory
WHERE hostname LIKE :'synthetic_vm_hostname_like';

CREATE TEMP TABLE cleanup_target_snapshots ON COMMIT DROP AS
SELECT DISTINCT cs.id
FROM cold_snapshots cs
LEFT JOIN cleanup_target_tenants tt
  ON tt.customer_id = cs.customer_id
 AND tt.tenant_id = cs.tenant_id
WHERE tt.tenant_id IS NOT NULL
   OR cs.source_vm_id IN (SELECT id FROM cleanup_target_vms);

CREATE TEMP TABLE cleanup_exclusive_deployments ON COMMIT DROP AS
SELECT DISTINCT cd.id, cd.node_id
FROM customer_deployments cd
JOIN cleanup_target_tenants tt ON tt.deployment_id = cd.id
WHERE NOT EXISTS (
    SELECT 1
    FROM customer_tenants other_tenant
    WHERE other_tenant.deployment_id = cd.id
      AND NOT EXISTS (
          SELECT 1
          FROM cleanup_target_tenants target_tenant
          WHERE target_tenant.customer_id = other_tenant.customer_id
            AND target_tenant.tenant_id = other_tenant.tenant_id
      )
);

SELECT 'mode', CASE WHEN :'apply_cleanup' = '1' THEN 'apply' ELSE 'dry-run' END;
SELECT 'stale_tenant', tenant_id, customer_id::text, deployment_id::text
FROM cleanup_target_tenants
ORDER BY tenant_id;
SELECT 'protected_tenant', ct.tenant_id, ct.customer_id::text, ct.deployment_id::text
FROM customer_tenants ct
WHERE ct.tenant_id IN ('logs-keep', 'stage5syn-proof-keep')
  AND NOT EXISTS (
      SELECT 1
      FROM cleanup_target_tenants tt
      WHERE tt.customer_id = ct.customer_id
        AND tt.tenant_id = ct.tenant_id
  )
ORDER BY ct.tenant_id;
SELECT 'non_target_tenant', ct.tenant_id, ct.customer_id::text, ct.deployment_id::text
FROM customer_tenants ct
WHERE NOT EXISTS (
    SELECT 1
    FROM cleanup_target_tenants tt
    WHERE tt.customer_id = ct.customer_id
      AND tt.tenant_id = ct.tenant_id
)
ORDER BY ct.tenant_id
LIMIT 20;
SELECT 'exclusive_deployment', id::text, node_id
FROM cleanup_exclusive_deployments
ORDER BY node_id;
SELECT 'synthetic_vm', id::text, hostname
FROM cleanup_target_vms
ORDER BY hostname;
SQL
}

cleanup_dev_orphans_summary_sql() {
    cat <<'SQL'
SELECT
    CASE WHEN :'apply_cleanup' = '1' THEN 'apply_plan' ELSE 'would_delete' END,
    'targeted_tenants',
    COUNT(*)::text
FROM cleanup_target_tenants;
SELECT
    CASE WHEN :'apply_cleanup' = '1' THEN 'apply_plan' ELSE 'would_delete' END,
    'exclusive_deployments',
    COUNT(*)::text
FROM cleanup_exclusive_deployments;
SELECT
    CASE WHEN :'apply_cleanup' = '1' THEN 'apply_plan' ELSE 'would_delete' END,
    'synthetic_vms',
    COUNT(*)::text
FROM cleanup_target_vms;
SQL
}

cleanup_dev_orphans_apply_sql() {
    cat <<'SQL'
\if :apply_cleanup
WITH deleted AS (
    DELETE FROM index_replicas ir
    WHERE EXISTS (
        SELECT 1
        FROM cleanup_target_tenants tt
        WHERE ir.customer_id = tt.customer_id
          AND ir.tenant_id = tt.tenant_id
    )
       OR ir.primary_vm_id IN (SELECT id FROM cleanup_target_vms)
       OR ir.replica_vm_id IN (SELECT id FROM cleanup_target_vms)
    RETURNING 1
)
SELECT 'applied', 'index_replicas', COUNT(*)::text FROM deleted;

WITH deleted AS (
    DELETE FROM restore_jobs rj
    WHERE rj.snapshot_id IN (SELECT id FROM cleanup_target_snapshots)
       OR rj.dest_vm_id IN (SELECT id FROM cleanup_target_vms)
    RETURNING 1
)
SELECT 'applied', 'restore_jobs', COUNT(*)::text FROM deleted;

WITH cleared AS (
    UPDATE customer_tenants ct
    SET cold_snapshot_id = NULL,
        vm_id = NULL
    WHERE (
        EXISTS (
            SELECT 1
            FROM cleanup_target_tenants tt
            WHERE ct.customer_id = tt.customer_id
              AND ct.tenant_id = tt.tenant_id
        )
        OR ct.cold_snapshot_id IN (SELECT id FROM cleanup_target_snapshots)
        OR ct.vm_id IN (SELECT id FROM cleanup_target_vms)
    )
      AND (ct.cold_snapshot_id IS NOT NULL OR ct.vm_id IS NOT NULL)
    RETURNING 1
)
SELECT 'applied', 'cleared_target_tenant_refs', COUNT(*)::text FROM cleared;

WITH deleted AS (
    DELETE FROM cold_snapshots cs
    USING cleanup_target_snapshots ts
    WHERE cs.id = ts.id
    RETURNING 1
)
SELECT 'applied', 'cold_snapshots', COUNT(*)::text FROM deleted;

WITH deleted AS (
    DELETE FROM index_migrations im
    USING cleanup_target_vms tv
    WHERE im.source_vm_id = tv.id
       OR im.dest_vm_id = tv.id
    RETURNING 1
)
SELECT 'applied', 'index_migrations', COUNT(*)::text FROM deleted;

WITH deleted AS (
    DELETE FROM customer_tenants ct
    USING cleanup_target_tenants tt
    WHERE ct.customer_id = tt.customer_id
      AND ct.tenant_id = tt.tenant_id
    RETURNING 1
)
SELECT 'applied', 'targeted_tenants', COUNT(*)::text FROM deleted;

WITH deleted AS (
    DELETE FROM customer_deployments cd
    USING cleanup_exclusive_deployments ed
    WHERE cd.id = ed.id
    RETURNING 1
)
SELECT 'applied', 'exclusive_deployments', COUNT(*)::text FROM deleted;

WITH cleared AS (
    UPDATE customer_tenants ct
    SET vm_id = NULL
    FROM cleanup_target_vms tv
    WHERE ct.vm_id = tv.id
    RETURNING 1
),
deleted AS (
    DELETE FROM vm_inventory vm
    USING cleanup_target_vms tv
    WHERE vm.id = tv.id
    RETURNING 1
)
SELECT 'applied', 'synthetic_vms', COUNT(*)::text FROM deleted;
\endif
SQL
}

cleanup_dev_orphans_sql() {
    echo "BEGIN;"
    cleanup_dev_orphans_target_sql
    cleanup_dev_orphans_summary_sql
    cleanup_dev_orphans_apply_sql
    echo "COMMIT;"
}

run_cleanup_plan() {
    local apply_cleanup="$1"

    cleanup_dev_orphans_sql | run_local_psql -v ON_ERROR_STOP=1 -tA -F '|' \
        -v apply_cleanup="$apply_cleanup" \
        -v synthetic_vm_hostname_like="$LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE"
}

main() {
    local apply_cleanup=0 mode_label="dry-run"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --apply)
                apply_cleanup=1
                mode_label="apply"
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "[cleanup-dev-orphans] ERROR: Unknown argument: $1" >&2
                usage >&2
                exit 2
                ;;
        esac
        shift
    done

    load_env_file "$REPO_ROOT/.env.local"

    if ! require_local_database_access "local dev orphan cleanup"; then
        die "Local database access unavailable; set DATABASE_URL or start Docker Postgres"
    fi

    log "Mode: ${mode_label}"
    run_cleanup_plan "$apply_cleanup"
    if [ "$apply_cleanup" -eq 0 ]; then
        log "Dry-run only; rerun with --apply to delete these rows"
    else
        log "Apply complete; verify with: bash scripts/dev_state_audit.sh"
    fi
}

main "$@"
