-- Read replicas: persistent, continuously-replicated copies of an index on a
-- different VM (typically in a different region).  Writes always go to the
-- primary; reads can be served by any healthy replica.

CREATE TABLE IF NOT EXISTS index_replicas (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id     UUID NOT NULL REFERENCES customers(id),
    tenant_id       TEXT NOT NULL,
    primary_vm_id   UUID NOT NULL REFERENCES vm_inventory(id),
    replica_vm_id   UUID NOT NULL REFERENCES vm_inventory(id),
    replica_region  TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'provisioning'
                        CHECK (status IN ('provisioning', 'replicating', 'active', 'stale', 'removing', 'failed')),
    lag_ops         BIGINT NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- A given index can only have one replica per VM
    UNIQUE (customer_id, tenant_id, replica_vm_id),
    -- Foreign key to the owning index
    FOREIGN KEY (customer_id, tenant_id) REFERENCES customer_tenants(customer_id, tenant_id)
);

CREATE INDEX IF NOT EXISTS idx_index_replicas_tenant
    ON index_replicas (customer_id, tenant_id);

CREATE INDEX IF NOT EXISTS idx_index_replicas_status
    ON index_replicas (status) WHERE status NOT IN ('removing', 'failed');
