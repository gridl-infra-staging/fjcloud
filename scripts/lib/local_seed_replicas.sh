#!/usr/bin/env bash
# Canonical local seed replica repair flow.
#
# Source after seed_local.sh defines its HTTP, JSON, SQL, and user-context
# helpers. Keeping the replica SQL here prevents the top-level seed script
# from becoming the catch-all owner for every local-dev invariant.

# Create the configured replica indexes through the API and mirror them into
# the SQL reset state used by the local seed harness.
# TODO: Document seed_replicas.
# TODO: Document seed_replicas.
# TODO: Document seed_replicas.
# TODO: Document seed_replicas.
# TODO: Document seed_replicas.
# Create configured replicas through the API and persist their reset-state rows in SQL.
# Treat unavailable local database access as an intentional no-op for caller portability.
# TODO: Document seed_replicas.
# TODO: Document seed_replicas.
seed_replicas() {
    if ! require_local_database_access "replica seed"; then
        log "Skipping replica seed — no database access"
        return 0
    fi

    local replicas_created=0
    local replica_create_failures=0
    local replica_reset_values=""
    local replica_target replica_targets
    replica_targets="$(local_seed_replica_targets "$SEED_INDEX_NAME" "$SEED_INDEX_REGION")"
    while IFS= read -r replica_target; do
        [ -n "$replica_target" ] || continue
        IFS='|' read -r ruser_key rindex_name rprimary_region rtarget_region <<<"$replica_target"

        local ruser_token=""
        local rcustomer_id=""
        local ruser_email=""
        resolve_seed_user_context "$ruser_key" "ruser_token" "rcustomer_id" "ruser_email"

        local index_path
        index_path="$(urlencode_path_component "$rindex_name")"

        # Create the replica via API. 409 = already exists, which is fine.
        local replica_request_payload replica_response replica_code
        replica_request_payload="$(python3 - "$rtarget_region" <<'PY'
import json
import sys

print(json.dumps({"region": sys.argv[1]}))
PY
        )" || die "Unable to encode replica region for ${rindex_name} -> ${rtarget_region}"
        replica_response=$(api_call_with_token POST "/indexes/${index_path}/replicas" "$ruser_token" \
            -d "$replica_request_payload" \
            -w "\n%{http_code}" 2>/dev/null) || true

        replica_code="$(http_response_status "$replica_response")"
        if [ "$replica_code" = "201" ] || [ "$replica_code" = "200" ]; then
            log "Created replica: ${rindex_name} -> ${rtarget_region}"
            replicas_created=$((replicas_created + 1))
        elif [ "$replica_code" = "409" ]; then
            log "Replica already exists: ${rindex_name} -> ${rtarget_region}"
        else
            log "WARNING: replica creation returned HTTP ${replica_code} for ${rindex_name} -> ${rtarget_region}"
            replica_create_failures=$((replica_create_failures + 1))
            continue
        fi

        local escaped_customer_id escaped_index_name escaped_primary_region escaped_replica_region
        escaped_customer_id="$(sql_escape_literal "$rcustomer_id")"
        escaped_index_name="$(sql_escape_literal "$rindex_name")"
        escaped_primary_region="$(sql_escape_literal "$rprimary_region")"
        escaped_replica_region="$(sql_escape_literal "$rtarget_region")"
        if [ -n "$replica_reset_values" ]; then
            replica_reset_values+=$',\n'
        fi
        replica_reset_values+="('${escaped_customer_id}'::uuid, '${escaped_index_name}', '${escaped_primary_region}', '${escaped_replica_region}')"
    done <<< "$replica_targets"

    if [ "$replica_create_failures" -gt 0 ]; then
        die "Replica seed failed for ${replica_create_failures} target(s); refusing to mark replicas active after API errors"
    fi

    # Restore the canonical local HA topology via SQL.
    # In production, the replication orchestrator would do this after data sync.
    # In local dev, we skip actual replication and just mark them ready so the
    # region failover monitor can promote them.
    # Scope this reset to the canonical seed triples so rerunning seed_local.sh
    # repairs failed/suspended replicas and tenant placements from prior local
    # HA proof attempts without touching unrelated operator-created indexes.
    [ -n "$replica_reset_values" ] || die "No seed replicas resolved for reset"
    run_local_psql -v ON_ERROR_STOP=1 \
        -v synthetic_vm_hostname_like="$LOCAL_SEED_SYNTHETIC_VM_HOSTNAME_LIKE" <<SQL
WITH seed_replicas(customer_id, tenant_id, primary_region, replica_region) AS (
    VALUES
${replica_reset_values}
),
canonical_seed_vms AS (
    SELECT
        seed_replicas.customer_id,
        seed_replicas.tenant_id,
        seed_replicas.primary_region,
        seed_replicas.replica_region,
        primary_vm.id AS primary_vm_id,
        replica_vm.id AS replica_vm_id
    FROM seed_replicas
    JOIN vm_inventory primary_vm
      ON primary_vm.hostname = 'local-dev-' || seed_replicas.primary_region
     AND primary_vm.provider = 'local'
     AND primary_vm.region = seed_replicas.primary_region
    JOIN vm_inventory replica_vm
      ON replica_vm.hostname = 'local-dev-' || seed_replicas.replica_region
     AND replica_vm.provider = 'local'
     AND replica_vm.region = seed_replicas.replica_region
),
reset_seed_tenants AS (
    UPDATE customer_tenants
    SET vm_id = canonical_seed_vms.primary_vm_id,
        tier = 'active',
        cold_snapshot_id = NULL
    FROM canonical_seed_vms
    WHERE customer_tenants.customer_id = canonical_seed_vms.customer_id
      AND customer_tenants.tenant_id = canonical_seed_vms.tenant_id
    RETURNING customer_tenants.customer_id, customer_tenants.tenant_id
)
UPDATE index_replicas
SET primary_vm_id = canonical_seed_vms.primary_vm_id,
    replica_vm_id = canonical_seed_vms.replica_vm_id,
    status = 'active',
    lag_ops = 0,
    updated_at = NOW()
FROM canonical_seed_vms
WHERE index_replicas.customer_id = canonical_seed_vms.customer_id
  AND index_replicas.tenant_id = canonical_seed_vms.tenant_id
  AND index_replicas.replica_region = canonical_seed_vms.replica_region
  AND index_replicas.status IN ('provisioning', 'syncing', 'failed', 'suspended');

WITH temporary_seed_vms AS (
    SELECT id
    FROM vm_inventory
    WHERE hostname LIKE :'synthetic_vm_hostname_like'
      AND status = 'active'
),
cleared_tenant_refs AS (
    UPDATE customer_tenants
    SET vm_id = NULL
    WHERE customer_tenants.vm_id IN (SELECT id FROM temporary_seed_vms)
    RETURNING 1
)
UPDATE vm_inventory
SET status = 'decommissioned',
    updated_at = NOW()
WHERE id IN (SELECT id FROM temporary_seed_vms);
SQL

    log "Marked seed replicas as active (${replicas_created} new)"
}
